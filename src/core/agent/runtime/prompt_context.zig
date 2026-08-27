const std = @import("std");
const model_capabilities = @import("../../config/model_capabilities.zig");
const token_estimate = @import("../../shared/token_estimate.zig");
const types = @import("../../shared/types.zig");
const session_runtime = @import("../../session/session.zig");

const runtime_config = @import("config.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;
const HistoryTurn = types.HistoryTurn;

const compaction_high_water_numerator: usize = 4;
const compaction_target_numerator: usize = 3;
const compaction_ratio_denominator: usize = 5;
const compacted_result_prefix = "<tool_result_compacted ";

pub const CompactionTrigger = enum {
    automatic,
    manual,
};

pub const RequestCost = struct {
    serialized_bytes: usize,
    estimated_input_tokens: usize,
};

pub const MessageLane = enum {
    durable_history,
    request_local,
};

pub const RequestLocalProvenance = enum {
    fresh,
    unversioned_history,
};

pub const CandidateKind = enum {
    existing_handle,
    promote_inline,
};

pub const ProjectionCandidate = struct {
    lane: MessageLane,
    message_index: usize,
    kind: CandidateKind,
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const u8,
    output_handle: ?[]const u8,
    stored_output_bytes: usize,
};

pub const ProjectionDecision = enum {
    no_op,
    project,
    capacity_failure,
};

pub const ProjectionPlan = struct {
    decision: ProjectionDecision,
    candidates: []ProjectionCandidate,
    usable_input_tokens: ?usize,
    high_water_tokens: ?usize,
    target_tokens: ?usize,

    pub fn deinit(self: *ProjectionPlan, alloc: Allocator) void {
        if (self.candidates.len > 0) alloc.free(self.candidates);
        self.* = undefined;
    }
};

pub const ProjectionInput = struct {
    trigger: CompactionTrigger,
    capabilities: model_capabilities.Capabilities,
    cost: RequestCost,
    durable_history: []const ChatMessage,
    request_local: []const ChatMessage,
    request_local_provenance: RequestLocalProvenance = .fresh,
};

pub fn measureProviderRequest(body: []const u8) RequestCost {
    var estimator = token_estimate.StreamingEstimator{};
    estimator.consume(body);
    return .{
        .serialized_bytes = body.len,
        .estimated_input_tokens = @intCast(@min(
            estimator.estimate(),
            std.math.maxInt(usize),
        )),
    };
}

pub fn planHybridProjection(
    alloc: Allocator,
    input: ProjectionInput,
) !ProjectionPlan {
    const usable = usableInputTokens(input.capabilities);
    const high_water = if (usable) |tokens|
        tokens * compaction_high_water_numerator / compaction_ratio_denominator
    else
        null;
    const target = if (usable) |tokens|
        tokens * compaction_target_numerator / compaction_ratio_denominator
    else
        null;
    const over_capacity = if (usable) |tokens|
        input.cost.estimated_input_tokens > tokens
    else
        false;
    const under_pressure = switch (input.trigger) {
        .manual => true,
        .automatic => if (high_water) |tokens|
            input.cost.estimated_input_tokens >= tokens
        else
            false,
    };
    if (!under_pressure) return .{
        .decision = .no_op,
        .candidates = &.{},
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .target_tokens = target,
    };

    var candidates: std.ArrayList(ProjectionCandidate) = .empty;
    errdefer candidates.deinit(alloc);
    try appendDurableCandidates(
        alloc,
        &candidates,
        input.durable_history,
    );
    try appendRequestLocalCandidates(
        alloc,
        &candidates,
        input.request_local,
        input.request_local_provenance,
    );
    const owned = try candidates.toOwnedSlice(alloc);
    return .{
        .decision = if (owned.len > 0)
            .project
        else if (over_capacity)
            .capacity_failure
        else
            .no_op,
        .candidates = owned,
        .usable_input_tokens = usable,
        .high_water_tokens = high_water,
        .target_tokens = target,
    };
}

fn usableInputTokens(
    capabilities: model_capabilities.Capabilities,
) ?usize {
    const context_window = capabilities.context_window orelse return null;
    const context_tokens: usize = @intCast(context_window);
    if (capabilities.max_output_tokens) |output| {
        const output_tokens: usize = @intCast(output);
        if (output_tokens < context_tokens) return context_tokens - output_tokens;
    }
    return context_tokens;
}

fn appendDurableCandidates(
    alloc: Allocator,
    candidates: *std.ArrayList(ProjectionCandidate),
    messages: []const ChatMessage,
) !void {
    var protected_start = messages.len;
    for (messages, 0..) |message, index| {
        if (message.role == .user) protected_start = index;
    }
    for (messages[0..protected_start], 0..) |message, index| {
        if (candidateForMessage(
            .durable_history,
            index,
            message,
            false,
        )) |candidate| {
            if (candidate.kind == .existing_handle) {
                try candidates.append(alloc, candidate);
            }
        }
    }
}

fn appendRequestLocalCandidates(
    alloc: Allocator,
    candidates: *std.ArrayList(ProjectionCandidate),
    messages: []const ChatMessage,
    provenance: RequestLocalProvenance,
) !void {
    var protected_start = messages.len;
    for (messages, 0..) |message, index| {
        if (message.role == .assistant and message.tool_calls.len > 0) {
            protected_start = index;
        }
    }
    for (messages[0..protected_start], 0..) |message, index| {
        if (candidateForMessage(
            .request_local,
            index,
            message,
            provenance == .fresh,
        )) |candidate| {
            try candidates.append(alloc, candidate);
        }
    }
}

fn candidateForMessage(
    lane: MessageLane,
    index: usize,
    message: ChatMessage,
    provenance_trusted: bool,
) ?ProjectionCandidate {
    if (message.role != .tool) return null;
    const content = message.content orelse return null;
    if (std.mem.startsWith(u8, content, compacted_result_prefix)) return null;
    const memory = message.tool_result_memory orelse return null;
    const call_id = message.tool_call_id orelse return null;
    const tool_name = message.tool_name orelse return null;
    if (memory.output_handle) |handle| return .{
        .lane = lane,
        .message_index = index,
        .kind = .existing_handle,
        .tool_call_id = call_id,
        .tool_name = tool_name,
        .content = content,
        .output_handle = handle,
        .stored_output_bytes = memory.stored_output_bytes,
    };
    if (lane == .durable_history or !provenance_trusted or memory.truncated) return null;
    return .{
        .lane = lane,
        .message_index = index,
        .kind = .promote_inline,
        .tool_call_id = call_id,
        .tool_name = tool_name,
        .content = content,
        .output_handle = null,
        .stored_output_bytes = content.len,
    };
}

pub fn projectToolResultMessage(
    alloc: Allocator,
    message: ChatMessage,
    handle: []const u8,
    stored_bytes: usize,
) !ChatMessage {
    var projected = message;
    projected.content = try std.fmt.allocPrint(
        alloc,
        "<tool_result_compacted handle=\"{s}\" stored_bytes=\"{d}\">Older settled result body removed from active context. Use read_tool_result for the complete redacted output.</tool_result_compacted>",
        .{ handle, stored_bytes },
    );
    var memory = message.tool_result_memory orelse types.ToolResultMemory{};
    memory.output_handle = handle;
    memory.preview = null;
    memory.stored_output_bytes = stored_bytes;
    memory.truncated = true;
    projected.tool_result_memory = memory;
    return projected;
}

pub fn historyContextBudgetTokensForCapabilities(capabilities: model_capabilities.Capabilities) usize {
    const context_window = capabilities.context_window orelse
        return runtime_config.default_history_context_budget_tokens;
    const context_tokens: usize = @intCast(context_window);
    const available_input_tokens = if (capabilities.max_output_tokens) |max_output_tokens|
        context_tokens -| @as(usize, @intCast(max_output_tokens))
    else
        context_tokens;
    return @max(
        @as(usize, 1),
        available_input_tokens / runtime_config.history_context_budget_window_divisor,
    );
}

pub fn buildGatewayMessages(
    alloc: Allocator,
    stable_prefix: []const ChatMessage,
    ephemeral_overlay: []const ChatMessage,
    durable_history: []const ChatMessage,
    current_user_message: ChatMessage,
    within_turn_suffix: []const ChatMessage,
) !std.ArrayList(ChatMessage) {
    var messages: std.ArrayList(ChatMessage) = .empty;
    errdefer messages.deinit(alloc);

    try messages.appendSlice(alloc, stable_prefix);
    try appendEphemeralOverlayMessages(alloc, &messages, ephemeral_overlay);
    try messages.appendSlice(alloc, durable_history);
    try messages.append(alloc, current_user_message);
    try messages.appendSlice(alloc, within_turn_suffix);
    return messages;
}

fn appendEphemeralOverlayMessages(alloc: Allocator, messages: *std.ArrayList(ChatMessage), ephemeral_overlay: []const ChatMessage) !void {
    for (ephemeral_overlay) |overlay_message| {
        var copy = overlay_message;
        copy.cache_policy = .no_cache;
        try messages.append(alloc, copy);
    }
}

test "history context budget reserves known output capacity from one capability snapshot" {
    const cases = [_]struct {
        capabilities: model_capabilities.Capabilities,
        expected: usize,
    }{
        .{ .capabilities = .{ .context_window = 128_000, .max_output_tokens = 32_000 }, .expected = 24_000 },
        .{ .capabilities = .{ .context_window = 256_000, .max_output_tokens = 64_000 }, .expected = 48_000 },
        .{ .capabilities = .{ .context_window = 1_000_000, .max_output_tokens = 128_000 }, .expected = 218_000 },
        .{ .capabilities = .{ .context_window = 512_000 }, .expected = 128_000 },
        .{ .capabilities = .{ .max_output_tokens = 32_000 }, .expected = runtime_config.default_history_context_budget_tokens },
        .{ .capabilities = .{ .context_window = 32_000, .max_output_tokens = 32_000 }, .expected = 1 },
        .{ .capabilities = .{ .context_window = 32_000, .max_output_tokens = 64_000 }, .expected = 1 },
        .{ .capabilities = .{}, .expected = runtime_config.default_history_context_budget_tokens },
    };

    for (cases) |case| {
        try std.testing.expectEqual(
            case.expected,
            historyContextBudgetTokensForCapabilities(case.capabilities),
        );
    }
}

test "budgeted history projection uses a million-token capability while remaining bounded" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const large_user = try arena.alloc(u8, 120_000);
    @memset(large_user, 'u');
    const large_assistant = try arena.alloc(u8, 120_000);
    @memset(large_assistant, 'a');

    var history: [5]HistoryTurn = undefined;
    for (&history) |*turn| {
        turn.* = try session_runtime.makeAssistantTurn(arena, large_user, large_assistant);
    }

    const exact_budget = historyContextBudgetTokensForCapabilities(
        .{ .context_window = 1_000_000 },
    );
    try std.testing.expectEqual(@as(usize, 250_000), exact_budget);

    var below_new_budget: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &below_new_budget,
        history[0..4],
        .{ .max_tokens = exact_budget },
    );
    try std.testing.expectEqual(@as(usize, 8), below_new_budget.items.len);
    try std.testing.expectEqualStrings(large_assistant, below_new_budget.items[below_new_budget.items.len - 1].content.?);

    var above_new_budget: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &above_new_budget,
        &history,
        .{ .max_tokens = exact_budget },
    );
    try std.testing.expectEqual(types.ChatRole.system, above_new_budget.items[0].role);
    try std.testing.expectEqual(@as(usize, 9), above_new_budget.items.len);
    try std.testing.expectEqualStrings(large_assistant, above_new_budget.items[above_new_budget.items.len - 1].content.?);

    var older_model_projection: std.ArrayList(ChatMessage) = .empty;
    try session_runtime.appendHistoryChatMessagesBudgeted(
        arena,
        &older_model_projection,
        history[0..4],
        .{ .max_tokens = historyContextBudgetTokensForCapabilities(.{ .context_window = 200_000 }) },
    );
    try std.testing.expectEqual(types.ChatRole.system, older_model_projection.items[0].role);
    try std.testing.expectEqual(@as(usize, 3), older_model_projection.items.len);
    try std.testing.expectEqualStrings(large_assistant, older_model_projection.items[older_model_projection.items.len - 1].content.?);
}

test "buildGatewayMessages orders transient overlay before history and current prompt" {
    const alloc = std.testing.allocator;
    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{
        .{ .role = .system, .content = "volatile runtime overlay" },
    };
    const history = [_]ChatMessage{
        .{ .role = .user, .content = "history user prompt" },
        .{ .role = .assistant, .content = "history assistant answer" },
    };
    const current = ChatMessage{ .role = .user, .content = "current user prompt" };
    const suffix = [_]ChatMessage{
        .{ .role = .assistant, .content = "within turn assistant" },
    };

    var messages = try buildGatewayMessages(alloc, &stable_prefix, &overlay, &history, current, &suffix);
    defer messages.deinit(alloc);

    try std.testing.expectEqual(@as(usize, 7), messages.items.len);
    try std.testing.expectEqualStrings("stable system prompt", messages.items[0].content.?);
    try std.testing.expectEqualStrings("stable project context", messages.items[1].content.?);
    try std.testing.expectEqualStrings("volatile runtime overlay", messages.items[2].content.?);
    try std.testing.expectEqualStrings("history user prompt", messages.items[3].content.?);
    try std.testing.expectEqualStrings("history assistant answer", messages.items[4].content.?);
    try std.testing.expectEqualStrings("current user prompt", messages.items[5].content.?);
    try std.testing.expectEqualStrings("within turn assistant", messages.items[6].content.?);
    try std.testing.expectEqual(types.ChatCachePolicy.no_cache, messages.items[2].cache_policy);
}

test "buildGatewayMessages preserves one system prefix for projected session history" {
    const alloc = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var calls = [_]types.ToolCall{.{
        .id = "call_read",
        .name = "read_file",
        .arguments_json = "{\"path\":\"src/portable.zig\"}",
    }};
    var results = [_]types.PersistedToolResult{.{
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .status = .success,
        .output = @constCast("portable contents"),
        .output_bytes = 17,
        .stored_output_bytes = 17,
    }};
    var steps = [_]types.ToolExecutionStep{.{
        .assistant = @constCast("Reading the file."),
        .tool_calls = calls[0..],
        .tool_results = results[0..],
    }};
    var files = [_]types.FileEvidence{.{
        .path = @constCast("src/portable.zig"),
        .tool_call_id = @constCast("call_read"),
        .tool_name = @constCast("read_file"),
        .action = .read,
        .status = .success,
        .model_view_covers_full_file = true,
    }};
    const history = [_]HistoryTurn{
        .{ .compacted_summary = .{
            .summary = @constCast("LEADING_SUMMARY_ONLY"),
            .removed_turn_count = 2,
            .compaction_count = 1,
        } },
        .{ .assistant = .{
            .user = .{ .text = @constCast("inspect portable history") },
            .assistant = @constCast("inspection complete"),
            .execution = .{ .tool_steps = steps[0..], .files = files[0..] },
        } },
        .{ .compacted_summary = .{
            .summary = @constCast("LATE_SUMMARY_ONLY"),
            .removed_turn_count = 1,
            .compaction_count = 2,
        } },
        .{ .background_command = .{
            .user = .{ .text = @constCast("run portable server") },
            .assistant = @constCast("server started"),
            .log_path = @constCast("/tmp/portable.log"),
            .expect_url = false,
        } },
        .{ .interrupted = .{
            .user = .{ .text = @constCast("stop portable work") },
            .assistant = @constCast("partial portable work"),
        } },
    };

    var projected_history: std.ArrayList(ChatMessage) = .empty;
    defer projected_history.deinit(arena);
    try session_runtime.appendHistoryChatMessages(arena, &projected_history, &history);

    const stable_prefix = [_]ChatMessage{
        .{ .role = .system, .content = "stable system prompt" },
        .{ .role = .system, .content = "stable project context" },
    };
    const overlay = [_]ChatMessage{.{ .role = .system, .content = "ephemeral overlay" }};
    const current = ChatMessage{ .role = .user, .content = "current portable prompt" };
    const suffix = [_]ChatMessage{.{ .role = .assistant, .content = "within-turn suffix" }};
    var messages = try buildGatewayMessages(
        arena,
        &stable_prefix,
        &overlay,
        projected_history.items,
        current,
        &suffix,
    );
    defer messages.deinit(arena);

    var saw_non_system = false;
    var leading_summary_count: usize = 0;
    var late_summary_count: usize = 0;
    var file_evidence_count: usize = 0;
    var background_count: usize = 0;
    var interruption_count: usize = 0;
    for (messages.items) |entry| {
        if (entry.role == .system) {
            try std.testing.expect(!saw_non_system);
        } else {
            saw_non_system = true;
        }
        const content = entry.content orelse continue;
        if (std.mem.find(u8, content, "LEADING_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.system, entry.role);
            leading_summary_count += 1;
        }
        if (std.mem.find(u8, content, "LATE_SUMMARY_ONLY") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            late_summary_count += 1;
        }
        if (std.mem.find(u8, content, "src/portable.zig") != null and
            std.mem.find(u8, content, "Session file evidence") != null)
        {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            file_evidence_count += 1;
        }
        if (std.mem.find(u8, content, "/tmp/portable.log") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            background_count += 1;
        }
        if (std.mem.find(u8, content, "<turn_aborted>") != null) {
            try std.testing.expectEqual(types.ChatRole.user, entry.role);
            interruption_count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), leading_summary_count);
    try std.testing.expectEqual(@as(usize, 1), late_summary_count);
    try std.testing.expectEqual(@as(usize, 1), file_evidence_count);
    try std.testing.expectEqual(@as(usize, 1), background_count);
    try std.testing.expectEqual(@as(usize, 1), interruption_count);
    try std.testing.expectEqualStrings("current portable prompt", messages.items[messages.items.len - 2].content.?);
    try std.testing.expectEqualStrings("within-turn suffix", messages.items[messages.items.len - 1].content.?);
}

test "hybrid projection plans only safe old tool-result bodies" {
    const alloc = std.testing.allocator;
    var old_calls = [_]types.ToolCall{.{
        .id = "old-active-call",
        .name = "read_file",
        .arguments_json = "{}",
    }};
    var recent_calls = [_]types.ToolCall{.{
        .id = "recent-active-call",
        .name = "read_file",
        .arguments_json = "{}",
    }};
    const durable = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "stored-call",
            .name = "read_file",
            .arguments_json = "{}",
        }} },
        .{
            .role = .tool,
            .content = "stored body",
            .tool_call_id = "stored-call",
            .tool_name = "read_file",
            .tool_result_memory = .{
                .output_handle = "result-stored.txt",
                .stored_output_bytes = 11,
                .truncated = true,
            },
        },
        .{
            .role = .tool,
            .content = "ambiguous legacy false",
            .tool_call_id = "legacy-false",
            .tool_name = "read_file",
            .tool_result_memory = .{ .truncated = false },
        },
        .{
            .role = .tool,
            .content = "ambiguous legacy true",
            .tool_call_id = "legacy-true",
            .tool_name = "read_file",
            .tool_result_memory = .{ .truncated = true },
        },
        .{ .role = .user, .content = "protect latest durable turn" },
        .{ .role = .assistant, .content = "latest durable answer" },
    };
    const request_local = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &old_calls },
        .{
            .role = .tool,
            .content = "complete active body",
            .tool_call_id = "old-active-call",
            .tool_name = "read_file",
            .tool_result_memory = .{ .truncated = false },
        },
        .{ .role = .assistant, .tool_calls = &recent_calls },
        .{
            .role = .tool,
            .content = "protect recent active body",
            .tool_call_id = "recent-active-call",
            .tool_name = "read_file",
            .tool_result_memory = .{ .truncated = false },
        },
    };

    var plan = try planHybridProjection(alloc, .{
        .trigger = .automatic,
        .capabilities = .{ .context_window = 100 },
        .cost = .{ .serialized_bytes = 360, .estimated_input_tokens = 90 },
        .durable_history = &durable,
        .request_local = &request_local,
    });
    defer plan.deinit(alloc);

    try std.testing.expectEqual(ProjectionDecision.project, plan.decision);
    try std.testing.expectEqual(@as(usize, 2), plan.candidates.len);
    try std.testing.expectEqual(MessageLane.durable_history, plan.candidates[0].lane);
    try std.testing.expectEqual(CandidateKind.existing_handle, plan.candidates[0].kind);
    try std.testing.expectEqualStrings("result-stored.txt", plan.candidates[0].output_handle.?);
    try std.testing.expectEqual(MessageLane.request_local, plan.candidates[1].lane);
    try std.testing.expectEqual(CandidateKind.promote_inline, plan.candidates[1].kind);
    try std.testing.expectEqualStrings("old-active-call", plan.candidates[1].tool_call_id);
}

test "hybrid projection is idempotent after installing a stored marker" {
    const alloc = std.testing.allocator;
    const source = ChatMessage{
        .role = .tool,
        .content = "complete body",
        .tool_call_id = "call-idempotent",
        .tool_name = "read_file",
        .tool_result_memory = .{ .truncated = false },
    };
    const projected = try projectToolResultMessage(
        alloc,
        source,
        "result-idempotent.txt",
        source.content.?.len,
    );
    defer alloc.free(@constCast(projected.content.?));
    const request_local = [_]ChatMessage{
        projected,
        .{ .role = .assistant, .tool_calls = &.{.{
            .id = "recent",
            .name = "read_file",
            .arguments_json = "{}",
        }} },
    };
    var plan = try planHybridProjection(alloc, .{
        .trigger = .manual,
        .capabilities = .{},
        .cost = .{ .serialized_bytes = 400, .estimated_input_tokens = 100 },
        .durable_history = &.{},
        .request_local = &request_local,
    });
    defer plan.deinit(alloc);

    try std.testing.expectEqual(ProjectionDecision.no_op, plan.decision);
    try std.testing.expectEqual(@as(usize, 0), plan.candidates.len);
}

test "hybrid projection reports physical capacity only after candidates are exhausted" {
    const alloc = std.testing.allocator;
    var plan = try planHybridProjection(alloc, .{
        .trigger = .automatic,
        .capabilities = .{ .context_window = 100, .max_output_tokens = 20 },
        .cost = .{ .serialized_bytes = 500, .estimated_input_tokens = 101 },
        .durable_history = &.{},
        .request_local = &.{},
    });
    defer plan.deinit(alloc);

    try std.testing.expectEqual(ProjectionDecision.capacity_failure, plan.decision);
    try std.testing.expectEqual(@as(?usize, 80), plan.usable_input_tokens);
    try std.testing.expectEqual(@as(?usize, 64), plan.high_water_tokens);
    try std.testing.expectEqual(@as(?usize, 48), plan.target_tokens);
}

test "hybrid projection treats resumed handle-free request-local memory conservatively" {
    const alloc = std.testing.allocator;
    var old_calls = [_]types.ToolCall{.{
        .id = "recovered-old",
        .name = "read_file",
        .arguments_json = "{}",
    }};
    var recent_calls = [_]types.ToolCall{.{
        .id = "recovered-recent",
        .name = "read_file",
        .arguments_json = "{}",
    }};
    const request_local = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = &old_calls },
        .{
            .role = .tool,
            .content = "ambiguous recovered body",
            .tool_call_id = "recovered-old",
            .tool_name = "read_file",
            .tool_result_memory = .{ .truncated = false },
        },
        .{ .role = .assistant, .tool_calls = &recent_calls },
    };
    var plan = try planHybridProjection(alloc, .{
        .trigger = .manual,
        .capabilities = .{},
        .cost = .{ .serialized_bytes = 400, .estimated_input_tokens = 100 },
        .durable_history = &.{},
        .request_local = &request_local,
        .request_local_provenance = .unversioned_history,
    });
    defer plan.deinit(alloc);

    try std.testing.expectEqual(ProjectionDecision.no_op, plan.decision);
    try std.testing.expectEqual(@as(usize, 0), plan.candidates.len);
}

test "provider request measurement includes serialized structure" {
    const compact = measureProviderRequest("{\"prompt\":[{\"role\":\"user\",\"content\":\"same\"}]}");
    const fragmented = measureProviderRequest(
        "{\"prompt\":[{\"role\":\"user\",\"content\":\"s\"},{\"role\":\"user\",\"content\":\"a\"},{\"role\":\"user\",\"content\":\"m\"},{\"role\":\"user\",\"content\":\"e\"}]}",
    );
    try std.testing.expect(fragmented.serialized_bytes > compact.serialized_bytes);
    try std.testing.expect(fragmented.estimated_input_tokens > compact.estimated_input_tokens);
}
