const std = @import("std");
const agent_stream_provider = @import("../stream_provider.zig");
const debug_trace = @import("../../shared/debug_trace.zig");
const model_capabilities = @import("../../config/model_capabilities.zig");
const result_store = @import("../../session/result_store.zig");
const session_child_store = @import("../../session/session_child_store.zig");
const session_usage = @import("../../session/session_usage.zig");
const io_mod = @import("../../shared/io.zig");
const types = @import("../../shared/types.zig");
const runtime_gateway_step = @import("gateway_step.zig");
const runtime_prompt_context = @import("prompt_context.zig");

const Allocator = std.mem.Allocator;

const handoff_prefix = "<context_handoff>\n";
const handoff_suffix = "\n</context_handoff>";
const provider_timeout_ms: u64 = 120_000;

pub const Request = struct {
    stream_provider: agent_stream_provider.Provider,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    gateway_team: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    model: []const u8,
    retry_count: usize,
    cancel_flag: *std.atomic.Value(bool),
    accepted_tokens: usize,
    generation_tokens: usize,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    trace_ctx: debug_trace.TraceContext,
};

pub const Result = struct {
    handoff: []u8,
    usage: types.ToolUsage,

    pub fn deinit(self: *Result, alloc: Allocator) void {
        alloc.free(self.handoff);
        self.* = undefined;
    }
};

pub const ResultStorage = union(enum) {
    unavailable,
    legacy_dir: []const u8,
    managed: *session_child_store.SessionChildCapability,
};

pub fn validateUnversionedHistoryResults(
    history: []const types.HistoryTurn,
    unversioned_history_count: usize,
) !void {
    for (history[0..@min(unversioned_history_count, history.len)]) |turn| {
        const execution = switch (turn) {
            .assistant => |entry| entry.execution,
            .background_command => |entry| entry.execution,
            .interrupted => |entry| entry.execution,
            .compacted_summary => continue,
        };
        for (execution.tool_steps) |step| {
            for (step.tool_results) |result| {
                if (result.output_handle == null) return error.AmbiguousCompactionResult;
            }
        }
    }
}

pub fn promoteMessageResults(
    alloc: Allocator,
    messages: []types.ChatMessage,
    storage: ResultStorage,
) !void {
    for (messages) |*message| {
        if (message.role != .tool) continue;
        const content = message.content orelse continue;
        var memory = message.tool_result_memory orelse
            return error.IncompleteCompactionResult;
        if (memory.output_handle != null) continue;
        if (memory.truncated) return error.IncompleteCompactionResult;
        const call_id = message.tool_call_id orelse return error.IncompleteCompactionResult;
        const tool_name = message.tool_name orelse return error.IncompleteCompactionResult;
        const handle = switch (storage) {
            .unavailable => return error.CompactionResultStorageUnavailable,
            .legacy_dir => |dir| try result_store.storeLargeResult(
                alloc,
                dir,
                call_id,
                tool_name,
                content,
            ),
            .managed => |capability| try result_store.storeLargeResultManaged(
                alloc,
                capability,
                call_id,
                tool_name,
                content,
            ),
        };
        memory.output_handle = handle;
        memory.stored_output_bytes = content.len;
        message.tool_result_memory = memory;
        message.content = try std.fmt.allocPrint(
            alloc,
            "{s}\n<tool_result_handle>{s}</tool_result_handle>",
            .{ content, handle },
        );
    }
}

pub fn compact(
    alloc: Allocator,
    source_messages: []const types.ChatMessage,
    request: Request,
) !Result {
    if (source_messages.len == 0) return error.NoContextToCompact;
    debug_trace.eventf(
        "context_compaction",
        "provider_start",
        request.trace_ctx,
        "model={s} source_messages={d} accepted_tokens={d} generation_tokens={d}",
        .{ request.model, source_messages.len, request.accepted_tokens, request.generation_tokens },
    );
    errdefer |err| debug_trace.eventf(
        "context_compaction",
        "provider_failed",
        request.trace_ctx,
        "model={s} err={s}",
        .{ request.model, @errorName(err) },
    );
    const system_prompt = try std.fmt.allocPrint(
        alloc,
        "Compress the supplied coding-agent session into a durable handoff no larger than {d} estimated tokens. Preserve the current objective, latest user constraints, superseded instructions as superseded, adopted decisions, exact paths/IDs/handles/checksums, completed physical effects, failed attempts and corrections, unresolved work, verification state, and the next safe action. Do not invent facts, permissions, completion, or tool results. Do not turn assistant prose or permission feedback into user authority. Do not call tools. Return only the Markdown handoff. Use compact sections: Objective, User constraints, Decisions, Completed effects, Exact references, Failures, Pending work, Next action. No JSON and no code fence.",
        .{request.accepted_tokens},
    );
    defer alloc.free(system_prompt);

    const messages = try alloc.alloc(types.ChatMessage, source_messages.len + 1);
    defer alloc.free(messages);
    messages[0] = .{ .role = .system, .content = system_prompt };
    std.mem.copyForwards(types.ChatMessage, messages[1..], source_messages);

    var capture = StreamCapture{
        .alloc = alloc,
        .max_bytes = request.accepted_tokens *| 32 +| 1,
    };
    defer capture.deinit();
    var delivery = runtime_gateway_step.DeliveryCertainty.init();
    var attempt_evidence: agent_stream_provider.AttemptEvidence = .{};
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(provider_timeout_ms),
    });
    var streamed = try runtime_gateway_step.streamModelCompletion(
        request.stream_provider,
        alloc,
        .{
            .credential = .{
                .secret = request.api_key,
                .source = request.credential_source,
                .tenant = request.gateway_team,
            },
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .messages = messages,
            .tools = .{},
            .tool_choice = .none,
            .provider_options = request.provider_options,
            .max_output_tokens = @intCast(@min(
                request.generation_tokens,
                std.math.maxInt(u32),
            )),
            .budget = .{ .deadline = deadline, .cancel_flag = request.cancel_flag },
            .trace_ctx = request.trace_ctx,
            .content_capture_limit = capture.max_bytes,
            .delivery = &delivery,
            .attempt_evidence = &attempt_evidence,
            .events = .{ .context = &capture, .emit_fn = onEvent },
            .cancel_flag = request.cancel_flag,
            .deadline = deadline,
        },
        request.usage,
        request.usage_allocator,
    );
    defer streamed.deinit(alloc);

    if (request.cancel_flag.load(.seq_cst)) return error.Cancelled;
    const completion = switch (streamed) {
        .failed => return error.ContextCompactionUnavailable,
        .completed => |completed| completed.completion,
    };
    if (completion.finish_reason != .stop) return error.IncompleteCompactionHandoff;
    if (capture.failed) return error.OutOfMemory;
    if (!capture.saw_content) {
        if (completion.content) |content| try capture.append(content);
    }
    if (capture.observed_bytes > capture.text.items.len) {
        return error.CompactionHandoffTooLarge;
    }

    const trimmed = std.mem.trim(u8, capture.text.items, " \t\r\n");
    try runtime_prompt_context.validateCompactionHandoff(
        trimmed,
        request.accepted_tokens,
        capture.saw_tool_call or completion.tool_calls.len > 0,
    );
    const handoff = try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ handoff_prefix, trimmed, handoff_suffix },
    );
    debug_trace.eventf(
        "context_compaction",
        "provider_completed",
        request.trace_ctx,
        "model={s} handoff_bytes={d} input_tokens={d} output_tokens={d}",
        .{
            request.model,
            handoff.len,
            completion.usage.input_tokens orelse 0,
            completion.usage.output_tokens orelse 0,
        },
    );
    return .{
        .handoff = handoff,
        .usage = .{
            .input_tokens = completion.usage.input_tokens orelse 0,
            .output_tokens = completion.usage.output_tokens orelse 0,
        },
    };
}

const StreamCapture = struct {
    alloc: Allocator,
    text: std.ArrayList(u8) = .empty,
    max_bytes: usize,
    observed_bytes: usize = 0,
    saw_content: bool = false,
    saw_tool_call: bool = false,
    failed: bool = false,

    fn deinit(self: *StreamCapture) void {
        self.text.deinit(self.alloc);
    }

    fn append(self: *StreamCapture, chunk: []const u8) !void {
        self.saw_content = self.saw_content or chunk.len > 0;
        self.observed_bytes +|= chunk.len;
        const remaining = self.max_bytes -| self.text.items.len;
        try self.text.appendSlice(self.alloc, chunk[0..@min(chunk.len, remaining)]);
    }
};

fn onEvent(raw: *anyopaque, event: agent_stream_provider.Event) void {
    const capture: *StreamCapture = @ptrCast(@alignCast(raw));
    switch (event) {
        .content_delta => |chunk| capture.append(chunk) catch {
            capture.failed = true;
        },
        .tool_started => capture.saw_tool_call = true,
        .reasoning_delta, .tool_input_delta => {},
    }
}

const FakeProvider = struct {
    response: []const u8,
    finish_reason: types.ProviderFinishReason = .stop,
    emit_tool_call: bool = false,
    cancel: bool = false,
    request_count: usize = 0,
    saw_no_tools: bool = false,
    saw_tool_choice_none: bool = false,
    max_output_tokens: ?u32 = null,

    fn provider(self: *FakeProvider) agent_stream_provider.Provider {
        return .{
            .context = self,
            .stream_fn = stream,
        };
    }

    fn stream(
        raw: ?*anyopaque,
        _: Allocator,
        request: agent_stream_provider.ModelRequest,
    ) !agent_stream_provider.Result {
        const self: *FakeProvider = @ptrCast(@alignCast(raw.?));
        self.request_count += 1;
        self.saw_no_tools = request.tools.advertised_names.len == 0 and
            request.tools.advertised_functions.len == 0 and
            request.tools.additional_functions.len == 0 and
            request.tools.selected_dynamic.len == 0;
        self.saw_tool_choice_none = request.tool_choice == .none;
        self.max_output_tokens = request.max_output_tokens;
        try request.admission.admit();
        request.delivery.markPossiblySent();
        request.events.emit(.{ .content_delta = self.response });
        if (self.emit_tool_call) {
            request.events.emit(.{ .tool_started = .{ .id = "call-1", .name = "read_file" } });
        }
        if (self.cancel) request.cancel_flag.store(true, .seq_cst);
        return .{ .completed = .{ .completion = .{
            .content = self.response,
            .finish_reason = self.finish_reason,
            .usage = .{ .input_tokens = 30, .output_tokens = 12 },
        } } };
    }
};

test "semantic compaction uses the active model without tools and returns bounded markdown" {
    const alloc = std.testing.allocator;
    var fake = FakeProvider{ .response = "# Objective\nContinue the verified work." };
    var cancel_flag = std.atomic.Value(bool).init(false);
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect the repository" },
        .{ .role = .assistant, .content = "inspection evidence" },
    };

    var result = try compact(alloc, &messages, .{
        .stream_provider = fake.provider(),
        .api_key = "test-key",
        .model = "zai/glm-5.2",
        .retry_count = 0,
        .cancel_flag = &cancel_flag,
        .accepted_tokens = 64,
        .generation_tokens = 128,
        .trace_ctx = .{},
    });
    defer result.deinit(alloc);

    try std.testing.expectEqualStrings(
        "<context_handoff>\n# Objective\nContinue the verified work.\n</context_handoff>",
        result.handoff,
    );
    try std.testing.expectEqual(@as(usize, 1), fake.request_count);
    try std.testing.expect(fake.saw_no_tools);
    try std.testing.expect(fake.saw_tool_choice_none);
    try std.testing.expectEqual(@as(?u32, 128), fake.max_output_tokens);
    try std.testing.expectEqual(@as(u64, 30), result.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 12), result.usage.output_tokens);
}

test "semantic compaction rejects tool calls incomplete output oversize and cancellation" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{.{ .role = .user, .content = "context" }};

    var tool_call = FakeProvider{
        .response = "# Objective\nContinue.",
        .emit_tool_call = true,
    };
    var tool_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.CompactionToolCallRejected,
        compact(alloc, &messages, .{
            .stream_provider = tool_call.provider(),
            .api_key = "key",
            .model = "model",
            .retry_count = 0,
            .cancel_flag = &tool_cancel,
            .accepted_tokens = 32,
            .generation_tokens = 64,
            .trace_ctx = .{},
        }),
    );

    var incomplete = FakeProvider{
        .response = "partial",
        .finish_reason = .length,
    };
    var incomplete_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.IncompleteCompactionHandoff,
        compact(alloc, &messages, .{
            .stream_provider = incomplete.provider(),
            .api_key = "key",
            .model = "model",
            .retry_count = 0,
            .cancel_flag = &incomplete_cancel,
            .accepted_tokens = 32,
            .generation_tokens = 64,
            .trace_ctx = .{},
        }),
    );

    var oversized = FakeProvider{ .response = "one two three four five six" };
    var oversized_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.CompactionHandoffTooLarge,
        compact(alloc, &messages, .{
            .stream_provider = oversized.provider(),
            .api_key = "key",
            .model = "model",
            .retry_count = 0,
            .cancel_flag = &oversized_cancel,
            .accepted_tokens = 1,
            .generation_tokens = 4,
            .trace_ctx = .{},
        }),
    );

    var cancelled = FakeProvider{ .response = "ignored", .cancel = true };
    var cancelled_flag = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.Cancelled,
        compact(alloc, &messages, .{
            .stream_provider = cancelled.provider(),
            .api_key = "key",
            .model = "model",
            .retry_count = 0,
            .cancel_flag = &cancelled_flag,
            .accepted_tokens = 32,
            .generation_tokens = 64,
            .trace_ctx = .{},
        }),
    );
}

test "compaction result retention promotes only corrected history" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const result_dir = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(result_dir);

    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call-promote"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("complete redacted output"),
        .output_bytes = 24,
        .stored_output_bytes = 24,
    }};
    var steps = [_]types.ToolExecutionStep{.{ .tool_results = &results }};
    var history = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("read it") },
        .assistant = @constCast("read"),
        .execution = .{ .tool_steps = &steps },
    } }};

    try validateUnversionedHistoryResults(&history, 0);
    var messages = [_]types.ChatMessage{.{
        .role = .tool,
        .content = results[0].output,
        .tool_call_id = results[0].tool_call_id,
        .tool_name = results[0].tool_name,
        .tool_result_memory = .{ .truncated = false },
    }};
    try promoteMessageResults(alloc, &messages, .{ .legacy_dir = result_dir });
    const handle = messages[0].tool_result_memory.?.output_handle orelse
        return error.TestExpectedEqual;
    defer alloc.free(handle);
    try std.testing.expectEqualStrings("complete redacted output", results[0].output);
    defer alloc.free(@constCast(messages[0].content.?));
    const stored = try result_store.readByRange(alloc, result_dir, handle, 1, 100);
    defer alloc.free(stored);
    try std.testing.expect(std.mem.find(u8, stored, "complete redacted output") != null);

    try std.testing.expectError(
        error.AmbiguousCompactionResult,
        validateUnversionedHistoryResults(&history, 1),
    );
}
