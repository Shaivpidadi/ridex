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
const compaction_state = @import("context_compaction_state.zig");

const Allocator = std.mem.Allocator;

const handoff_prefix = "<context_handoff>\n";
const handoff_suffix = "\n</context_handoff>";
const provider_timeout_ms: u64 = 120_000;
const default_protected_tail_messages: usize = 2;
const one_shot_message_limit: usize = 12;
const block_message_limit: usize = compaction_state.max_item_sources;
const block_summary_word_limit: usize = 64;
const block_generation_token_limit: usize = 4096;
const max_parallel_blocks: usize = 4;
const response_format_name = "fx_context_compaction_state";
const response_format_description = "Evidence-grounded operational state for continuing an fx session.";
const response_schema_json =
    \\{"type":"object","additionalProperties":false,"required":["objective","constraints","obligations","next_action"],"properties":{"objective":{"$ref":"#/$defs/evidence"},"constraints":{"type":"array","maxItems":12,"items":{"$ref":"#/$defs/evidence"}},"obligations":{"type":"array","maxItems":12,"items":{"type":"object","additionalProperties":false,"required":["text","status","sources"],"properties":{"text":{"type":"string","minLength":1,"maxLength":160},"status":{"type":"string","enum":["active","resolved"]},"sources":{"$ref":"#/$defs/sources"}}}},"next_action":{"type":"object","additionalProperties":false,"required":["kind","text","sources"],"properties":{"kind":{"type":"string","enum":["repair_failure","perform_pending_action","await_authority","perform_verification","await_external_input","none"]},"text":{"type":"string","minLength":1,"maxLength":160},"sources":{"$ref":"#/$defs/sources"}}}},"$defs":{"sources":{"type":"array","minItems":1,"maxItems":8,"items":{"type":"string"}},"evidence":{"type":"object","additionalProperties":false,"required":["text","sources"],"properties":{"text":{"type":"string","minLength":1,"maxLength":160},"sources":{"$ref":"#/$defs/sources"}}}}}
;

pub const Request = struct {
    stream_provider: agent_stream_provider.Provider,
    model: []const u8,
    api_key: []const u8,
    credential_source: ?types.CredentialSource = null,
    account_id: ?[]const u8 = null,
    gateway_team: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    retry_count: usize,
    cancel_flag: *std.atomic.Value(bool),
    accepted_tokens: usize,
    generation_tokens: usize,
    provider_options: model_capabilities.ResolvedProviderOptions = .{},
    usage: ?*session_usage.Usage = null,
    usage_allocator: Allocator = std.heap.c_allocator,
    trace_ctx: debug_trace.TraceContext,
    protected_tail_messages: usize = default_protected_tail_messages,
    response_format: ?agent_stream_provider.StructuredResponseFormat = null,
};

pub const Result = struct {
    handoff: []u8,
    usage: types.ToolUsage,
    retained_message_count: usize,

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
    if (source_messages.len <= request.protected_tail_messages) {
        return error.NoContextToCompact;
    }
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();
    const parsed_schema = std.json.parseFromSliceLeaky(
        std.json.Value,
        scratch,
        response_schema_json,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCompactionSchema,
    };
    if (parsed_schema != .object) return error.InvalidCompactionSchema;
    var semantic_request = request;
    semantic_request.response_format = .{
        .name = response_format_name,
        .description = response_format_description,
        .schema = parsed_schema,
    };
    const prefix_len = source_messages.len - request.protected_tail_messages;
    const compactable = source_messages[0..prefix_len];
    debug_trace.eventf(
        "context_compaction",
        "provider_start",
        request.trace_ctx,
        "model={s} source_messages={d} compactable_messages={d} retained_messages={d} accepted_tokens={d} generation_tokens={d}",
        .{
            request.model,
            source_messages.len,
            compactable.len,
            request.protected_tail_messages,
            request.accepted_tokens,
            request.generation_tokens,
        },
    );
    errdefer |err| debug_trace.eventf(
        "context_compaction",
        "provider_failed",
        request.trace_ctx,
        "model={s} err={s}",
        .{ request.model, @errorName(err) },
    );
    const sources = try compaction_state.sourceRecordsFromMessages(scratch, compactable);
    const lineage = try compaction_state.deriveOperationLineage(scratch, sources);

    var total_usage: types.ToolUsage = .{};
    const typed_text, const blocks = if (sources.len <= one_shot_message_limit) blk: {
        const source_text = try compaction_state.formatSourceMessages(scratch, sources);
        const valid_sources = try formatValidSources(scratch, sources, 0);
        const valid_authority_sources = try formatAuthoritySources(scratch, sources);
        const user_prompt = try std.fmt.allocPrint(
            scratch,
            "<valid_sources>{s}</valid_sources>\n<valid_authority_sources>{s}</valid_authority_sources>\n<source_history>\n{s}</source_history>",
            .{ valid_sources, valid_authority_sources, source_text },
        );
        const call = try runSemanticCall(
            scratch,
            semantic_request,
            typedSystemPrompt(),
            user_prompt,
            request.generation_tokens,
            request.accepted_tokens *| 32 +| 1,
        );
        total_usage = call.usage;
        break :blk .{ call.text, @as([]const compaction_state.BlockRecord, &.{}) };
    } else blk: {
        const block_count = (sources.len + block_message_limit - 1) / block_message_limit;
        const block_records = try scratch.alloc(compaction_state.BlockRecord, block_count);
        const summaries = try scratch.alloc([]u8, block_count);
        var completed_blocks: usize = 0;
        errdefer {
            for (summaries[0..completed_blocks]) |summary| scratch.free(summary);
            scratch.free(summaries);
            scratch.free(block_records);
        }
        var next_block: usize = 0;
        while (next_block < block_count) {
            const batch_count = @min(max_parallel_blocks, block_count - next_block);
            var workers: [max_parallel_blocks]BlockWorker = undefined;
            var futures: [max_parallel_blocks]std.Io.Future(void) = undefined;
            var launched: usize = 0;
            var joined: usize = 0;
            errdefer while (joined < launched) {
                futures[joined].await(io_mod.getIo());
                if (workers[joined].result) |call| {
                    std.heap.c_allocator.free(call.text);
                } else |_| {}
                joined += 1;
            };
            while (launched < batch_count) : (launched += 1) {
                const block_index = next_block + launched;
                const start = block_index * block_message_limit;
                const end = @min(start + block_message_limit, sources.len);
                const block_sources = sources[start..end];
                const source_ids = try scratch.alloc(usize, block_sources.len);
                for (block_sources, 0..) |source, index| source_ids[index] = source.id;
                block_records[block_index] = .{
                    .id = block_index,
                    .source_ids = source_ids,
                };
                workers[launched] = .{
                    .request = request,
                    .sources = block_sources,
                    .block_index = block_index,
                };
                futures[launched] = try std.Io.concurrent(
                    io_mod.getIo(),
                    BlockWorker.runMain,
                    .{&workers[launched]},
                );
            }
            while (joined < batch_count) {
                futures[joined].await(io_mod.getIo());
                const worker = &workers[joined];
                joined += 1;
                const call = try worker.result;
                defer std.heap.c_allocator.free(call.text);
                const bounded_summary = boundedWordPrefix(
                    call.text,
                    block_summary_word_limit,
                );
                block_records[worker.block_index].source_ids =
                    try compaction_state.citedBlockSources(
                        scratch,
                        call.text,
                        block_records[worker.block_index].source_ids,
                    );
                summaries[worker.block_index] = try scratch.dupe(u8, bounded_summary);
                completed_blocks += 1;
                addUsage(&total_usage, call.usage);
            }
            next_block += batch_count;
        }
        var merge_source: std.Io.Writer.Allocating = .init(scratch);
        defer merge_source.deinit();
        for (summaries, 0..) |summary, index| {
            try merge_source.writer.print(
                "<episode_summary id=\"B{d}\">\n{s}\n</episode_summary>\n",
                .{ index, summary },
            );
        }
        const valid_sources = try formatValidSources(scratch, sources, block_count);
        const valid_authority_sources = try formatAuthoritySources(scratch, sources);
        try merge_source.writer.print("<valid_sources>{s}</valid_sources>\n", .{valid_sources});
        try merge_source.writer.print(
            "<valid_authority_sources>{s}</valid_authority_sources>\n",
            .{valid_authority_sources},
        );
        const call = try runSemanticCall(
            scratch,
            semantic_request,
            typedMergeSystemPrompt(),
            merge_source.written(),
            request.generation_tokens,
            request.accepted_tokens *| 32 +| 1,
        );
        addUsage(&total_usage, call.usage);
        for (summaries) |summary| scratch.free(summary);
        scratch.free(summaries);
        break :blk .{ call.text, block_records };
    };
    defer scratch.free(typed_text);
    defer if (blocks.len > 0) {
        for (blocks) |block| scratch.free(@constCast(block.source_ids));
        scratch.free(@constCast(blocks));
    };

    const state = try compaction_state.parseOperationalState(
        scratch,
        typed_text,
        sources,
        blocks,
    );
    try compaction_state.validateLineageCoverage(state, lineage);
    const rendered = try compaction_state.renderCheckpoint(
        scratch,
        state,
        sources,
        lineage,
    );
    defer scratch.free(rendered);
    try runtime_prompt_context.validateCompactionHandoff(
        rendered,
        request.accepted_tokens,
        false,
    );
    const handoff = try std.fmt.allocPrint(
        alloc,
        "{s}{s}{s}",
        .{ handoff_prefix, rendered, handoff_suffix },
    );
    debug_trace.eventf(
        "context_compaction",
        "provider_completed",
        request.trace_ctx,
        "model={s} handoff_bytes={d} input_tokens={d} output_tokens={d}",
        .{
            request.model,
            handoff.len,
            total_usage.input_tokens,
            total_usage.output_tokens,
        },
    );
    return .{
        .handoff = handoff,
        .usage = total_usage,
        .retained_message_count = request.protected_tail_messages,
    };
}

const SemanticCall = struct {
    text: []u8,
    usage: types.ToolUsage,
};

const BlockWorker = struct {
    request: Request,
    sources: []const compaction_state.SourceRecord,
    block_index: usize,
    result: anyerror!SemanticCall = undefined,

    fn runMain(self: *BlockWorker) void {
        self.result = execute(self);
    }

    fn execute(self: *BlockWorker) !SemanticCall {
        const alloc = std.heap.c_allocator;
        const source_text = try compaction_state.formatSourceMessages(
            alloc,
            self.sources,
        );
        defer alloc.free(source_text);
        const valid_sources = try formatValidSources(alloc, self.sources, 0);
        defer alloc.free(valid_sources);
        const valid_authority_sources = try formatAuthoritySources(alloc, self.sources);
        defer alloc.free(valid_authority_sources);
        const user_prompt = try std.fmt.allocPrint(
            alloc,
            "<valid_sources>{s}</valid_sources>\n<valid_authority_sources>{s}</valid_authority_sources>\n<episode id=\"B{d}\">\n{s}</episode>",
            .{ valid_sources, valid_authority_sources, self.block_index, source_text },
        );
        defer alloc.free(user_prompt);
        return runSemanticCall(
            alloc,
            self.request,
            blockSystemPrompt(),
            user_prompt,
            @min(self.request.generation_tokens, block_generation_token_limit),
            block_summary_word_limit * 32 + 1,
        );
    }
};

fn runSemanticCall(
    alloc: Allocator,
    request: Request,
    system_prompt: []const u8,
    user_prompt: []const u8,
    generation_tokens: usize,
    max_bytes: usize,
) !SemanticCall {
    const messages = [_]types.ChatMessage{
        .{ .role = .system, .content = system_prompt },
        .{ .role = .user, .content = user_prompt },
    };
    var capture = StreamCapture{ .alloc = alloc, .max_bytes = max_bytes };
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
                .account_id = request.account_id,
                .tenant = request.gateway_team,
            },
            .session_id = request.session_id,
            .model = request.model,
            .retry_count = request.retry_count,
            .messages = &messages,
            .tools = .{},
            .tool_choice = .none,
            .provider_options = request.provider_options,
            .max_output_tokens = @intCast(@min(generation_tokens, std.math.maxInt(u32))),
            .response_format = request.response_format,
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
    if (capture.saw_tool_call or completion.tool_calls.len > 0) {
        return error.CompactionToolCallRejected;
    }
    if (capture.observed_bytes > capture.text.items.len) {
        return error.CompactionHandoffTooLarge;
    }
    const trimmed = std.mem.trim(u8, capture.text.items, " \t\r\n");
    if (trimmed.len == 0 or !std.unicode.utf8ValidateSlice(trimmed)) {
        return error.InvalidCompactionHandoff;
    }
    return .{
        .text = try alloc.dupe(u8, trimmed),
        .usage = .{
            .input_tokens = completion.usage.input_tokens orelse 0,
            .output_tokens = completion.usage.output_tokens orelse 0,
        },
    };
}

fn addUsage(total: *types.ToolUsage, item: types.ToolUsage) void {
    total.input_tokens +|= item.input_tokens;
    total.output_tokens +|= item.output_tokens;
}

fn boundedWordPrefix(text: []const u8, max_words: usize) []const u8 {
    if (max_words == 0) return text[0..0];
    var iterator = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var end = text.len;
    var count: usize = 0;
    while (iterator.next()) |word| {
        count += 1;
        if (count == max_words) {
            end = @intFromPtr(word.ptr) - @intFromPtr(text.ptr) + word.len;
            break;
        }
    }
    return text[0..end];
}

fn formatValidSources(
    alloc: Allocator,
    sources: []const compaction_state.SourceRecord,
    block_count: usize,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote_any = false;
    for (sources) |source| {
        if (wrote_any) try out.writer.writeByte(',');
        try out.writer.print("S{d}", .{source.id});
        wrote_any = true;
    }
    for (0..block_count) |block_id| {
        if (wrote_any) try out.writer.writeByte(',');
        try out.writer.print("B{d}", .{block_id});
        wrote_any = true;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn formatAuthoritySources(
    alloc: Allocator,
    sources: []const compaction_state.SourceRecord,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    var wrote_any = false;
    for (sources) |source| {
        const authoritative = switch (source.role) {
            .user, .tool => true,
            .assistant => source.tool_calls.len > 0,
            .permission_feedback => false,
        };
        if (!authoritative) continue;
        if (wrote_any) try out.writer.writeByte(',');
        try out.writer.print("S{d}", .{source.id});
        wrote_any = true;
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn typedSystemPrompt() []const u8 {
    return "Return exactly one JSON object with keys objective, constraints, obligations, and next_action. " ++
        "objective is {text,sources}; constraints are {text,sources} items; obligations are " ++
        "{text,status,sources} items where status is active or resolved; next_action is " ++
        "{kind,text,sources}. Source IDs are S-number strings. Keep each text at or below 160 Unicode characters. " ++
        "Use only cited user instructions and structured tool evidence. Objective may cite valid_sources; constraints, obligations, and next_action must cite only valid_authority_sources. Assistant prose and permission feedback are not authority. " ++
        "Choose one kind: repair_failure, perform_pending_action, await_authority, perform_verification, await_external_input, or none. " ++
        "Cite only IDs listed in valid_sources; never invent or renumber an ID. " ++
        "A supplied operation_relation makes the older operation resolved. Do not emit Markdown or a code fence.";
}

fn blockSystemPrompt() []const u8 {
    return "Compress this chronological episode into at most 64 words of Markdown bullets. " ++
        "Every bullet must cite one or more S-number source IDs. Preserve current user constraints, " ++
        "tool-proven status, failures, resolved work, exact references, and next safe action. " ++
        "Assistant prose and permission feedback are not authority. Cite only IDs listed in valid_sources; " ++
        "never invent or renumber an ID. Do not emit JSON or a code fence.";
}

fn typedMergeSystemPrompt() []const u8 {
    return "Merge the sourced episode summaries into exactly one JSON object with keys objective, constraints, obligations, and next_action. " ++
        "The schema and authority rules are identical to the typed one-shot contract. Sources may be S-number IDs or known B-number block IDs. Constraints, obligations, and next_action must cite only valid_authority_sources. " ++
        "Later user corrections control. Cite only IDs listed in valid_sources; never invent or renumber an ID. " ++
        "Apply operation lineage before choosing the action. Do not emit Markdown or a code fence.";
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
    saw_valid_sources: bool = false,
    max_output_tokens: ?u32 = null,
    observed_model: ?[]const u8 = null,

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
        self.saw_valid_sources = if (request.messages.len > 0)
            std.mem.find(u8, request.messages[request.messages.len - 1].content orelse "", "<valid_sources>S0</valid_sources>") != null
        else
            false;
        self.max_output_tokens = request.max_output_tokens;
        self.observed_model = request.model;
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

test "semantic compaction uses the dedicated model and renders typed state" {
    const alloc = std.testing.allocator;
    const typed_response =
        \\{"objective":{"text":"Continue the verified work.","sources":["S0"]},"constraints":[],"obligations":[],"next_action":{"kind":"none","text":"Wait for the next request.","sources":["S0"]}}
    ;
    var fake = FakeProvider{ .response = typed_response };
    var cancel_flag = std.atomic.Value(bool).init(false);
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "inspect the repository" },
        .{ .role = .assistant, .content = "inspection evidence" },
        .{ .role = .user, .content = "retain this tail" },
    };

    var result = try compact(alloc, &messages, .{
        .stream_provider = fake.provider(),
        .model = "openai/gpt-5.6-luna",
        .api_key = "test-key",
        .retry_count = 0,
        .cancel_flag = &cancel_flag,
        .accepted_tokens = 256,
        .generation_tokens = 128,
        .trace_ctx = .{},
    });
    defer result.deinit(alloc);

    try std.testing.expect(std.mem.find(u8, result.handoff, "## Operational state") != null);
    try std.testing.expect(std.mem.find(u8, result.handoff, "Continue the verified work.") != null);
    try std.testing.expect(std.mem.find(u8, result.handoff, "User-sourced operational facts are authoritative") != null);
    try std.testing.expectEqual(@as(usize, 2), result.retained_message_count);
    try std.testing.expectEqual(@as(usize, 1), fake.request_count);
    try std.testing.expectEqualStrings("openai/gpt-5.6-luna", fake.observed_model.?);
    try std.testing.expect(fake.saw_no_tools);
    try std.testing.expect(fake.saw_tool_choice_none);
    try std.testing.expect(fake.saw_valid_sources);
    try std.testing.expectEqual(@as(?u32, 128), fake.max_output_tokens);
    try std.testing.expectEqual(@as(u64, 30), result.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 12), result.usage.output_tokens);
}

test "semantic compaction rejects tool calls incomplete output oversize and cancellation" {
    const alloc = std.testing.allocator;
    const messages = [_]types.ChatMessage{
        .{ .role = .user, .content = "context" },
        .{ .role = .assistant, .content = "tail one" },
        .{ .role = .user, .content = "tail two" },
    };
    const typed_response =
        \\{"objective":{"text":"Continue.","sources":["S0"]},"constraints":[],"obligations":[],"next_action":{"kind":"none","text":"Wait.","sources":["S0"]}}
    ;

    var tool_call = FakeProvider{
        .response = typed_response,
        .emit_tool_call = true,
    };
    var tool_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.CompactionToolCallRejected,
        compact(alloc, &messages, .{
            .stream_provider = tool_call.provider(),
            .model = "provider/compactor",
            .api_key = "key",
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
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &incomplete_cancel,
            .accepted_tokens = 32,
            .generation_tokens = 64,
            .trace_ctx = .{},
        }),
    );

    var oversized = FakeProvider{ .response = typed_response };
    var oversized_cancel = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.CompactionHandoffTooLarge,
        compact(alloc, &messages, .{
            .stream_provider = oversized.provider(),
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &oversized_cancel,
            .accepted_tokens = 1,
            .generation_tokens = 4,
            .trace_ctx = .{},
        }),
    );

    var cancelled = FakeProvider{ .response = typed_response, .cancel = true };
    var cancelled_flag = std.atomic.Value(bool).init(false);
    try std.testing.expectError(
        error.Cancelled,
        compact(alloc, &messages, .{
            .stream_provider = cancelled.provider(),
            .model = "provider/compactor",
            .api_key = "key",
            .retry_count = 0,
            .cancel_flag = &cancelled_flag,
            .accepted_tokens = 32,
            .generation_tokens = 64,
            .trace_ctx = .{},
        }),
    );
}

test "blockwise compaction bounds concurrency and canonicalizes merge provenance" {
    const Provider = struct {
        block_started: std.atomic.Value(usize) = .init(0),
        active: std.atomic.Value(usize) = .init(0),
        max_active: std.atomic.Value(usize) = .init(0),
        request_count: std.atomic.Value(usize) = .init(0),
        block_schema_seen: std.atomic.Value(bool) = .init(false),
        merge_schema_seen: std.atomic.Value(bool) = .init(false),
        block_max_output_tokens: std.atomic.Value(u32) = .init(0),

        fn provider(self: *@This()) agent_stream_provider.Provider {
            return .{ .context = self, .stream_fn = stream };
        }

        fn stream(
            raw: ?*anyopaque,
            _: Allocator,
            request: agent_stream_provider.ModelRequest,
        ) !agent_stream_provider.Result {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = self.request_count.fetchAdd(1, .seq_cst);
            const system = request.messages[0].content orelse "";
            const is_merge = std.mem.startsWith(u8, system, "Merge");
            if (is_merge) {
                self.merge_schema_seen.store(request.response_format != null, .seq_cst);
            } else if (request.response_format != null) {
                self.block_schema_seen.store(true, .seq_cst);
            } else {
                self.block_max_output_tokens.store(request.max_output_tokens orelse 0, .seq_cst);
            }
            const now_active = self.active.fetchAdd(1, .seq_cst) + 1;
            var observed = self.max_active.load(.seq_cst);
            while (now_active > observed) {
                observed = self.max_active.cmpxchgWeak(
                    observed,
                    now_active,
                    .seq_cst,
                    .seq_cst,
                ) orelse break;
            }
            if (!is_merge) {
                _ = self.block_started.fetchAdd(1, .seq_cst);
                var spins: usize = 0;
                while (self.block_started.load(.seq_cst) < 2 and spins < 1_000) : (spins += 1) {
                    io_mod.sleep(std.time.ns_per_ms);
                }
            }
            defer _ = self.active.fetchSub(1, .seq_cst);
            const user = request.messages[1].content orelse "";
            const response = if (is_merge)
                "{\"objective\":{\"text\":\"Continue blockwise work.\",\"sources\":[\"B0\"]},\"constraints\":[],\"obligations\":[],\"next_action\":{\"kind\":\"none\",\"text\":\"Wait.\",\"sources\":[\"B0\"]}}"
            else if (std.mem.find(u8, user, "S12") != null)
                "- [S12] Preserve the current work."
            else
                "word " ** 80 ++ "[S0]";
            try request.admission.admit();
            request.delivery.markPossiblySent();
            request.events.emit(.{ .content_delta = response });
            return .{ .completed = .{ .completion = .{
                .content = response,
                .finish_reason = .stop,
            } } };
        }
    };

    const alloc = std.testing.allocator;
    var provider = Provider{};
    var cancel = std.atomic.Value(bool).init(false);
    var messages: [15]types.ChatMessage = undefined;
    for (&messages, 0..) |*message, index| {
        message.* = .{
            .role = if (index % 2 == 0) .user else .assistant,
            .content = if (index < 13) "compactable" else "tail",
        };
    }
    var result = try compact(alloc, &messages, .{
        .stream_provider = provider.provider(),
        .model = "provider/compactor",
        .api_key = "key",
        .retry_count = 0,
        .cancel_flag = &cancel,
        .accepted_tokens = 512,
        .generation_tokens = 10_000,
        .trace_ctx = .{},
    });
    defer result.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 3), provider.request_count.load(.seq_cst));
    try std.testing.expect(provider.max_active.load(.seq_cst) >= 2);
    try std.testing.expect(!provider.block_schema_seen.load(.seq_cst));
    try std.testing.expect(provider.merge_schema_seen.load(.seq_cst));
    try std.testing.expectEqual(
        @as(u32, block_generation_token_limit),
        provider.block_max_output_tokens.load(.seq_cst),
    );
    try std.testing.expect(std.mem.find(u8, result.handoff, "B0") == null);
    try std.testing.expect(std.mem.find(u8, result.handoff, "S0") != null);
}

test "block summaries retain at most the configured word prefix" {
    const source = "word " ** 80;
    const bounded = boundedWordPrefix(source, block_summary_word_limit);
    var words = std.mem.tokenizeAny(u8, bounded, " \t\r\n");
    var count: usize = 0;
    while (words.next() != null) count += 1;
    try std.testing.expectEqual(block_summary_word_limit, count);
    try std.testing.expectEqual(@as(usize, 0), boundedWordPrefix(source, 0).len);
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
