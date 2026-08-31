const std = @import("std");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_item_text_bytes: usize = 160;
pub const max_item_sources: usize = 8;
pub const max_constraints: usize = 12;
pub const max_obligations: usize = 12;
const max_inline_arguments_bytes: usize = 1024;

pub const SourceRole = enum {
    user,
    assistant,
    tool,
    permission_feedback,
};

pub const SourceRecord = struct {
    id: usize,
    role: SourceRole,
    content: []const u8 = "",
    tool_calls: []const types.ToolCall = &.{},
    tool_call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    tool_result_status: ?types.PersistedToolStatus = null,
    tool_result_memory: ?types.ToolResultMemory = null,
};

pub const BlockRecord = struct {
    id: usize,
    source_ids: []const usize,
};

pub const OperationLineage = struct {
    current_call_id: []const u8,
    current_source_id: usize,
    resolves_call_id: []const u8,
    resolves_source_id: usize,
};

pub const UserFact = struct {
    source_id: usize,
    key: []const u8,
    value: []const u8,
};

pub const EvidenceText = struct {
    text: []const u8,
    source_ids: []const usize,
};

pub const ObligationStatus = enum {
    active,
    resolved,
};

pub const Obligation = struct {
    text: []const u8,
    status: ObligationStatus,
    source_ids: []const usize,
};

pub const NextActionKind = enum {
    repair_failure,
    perform_pending_action,
    await_authority,
    perform_verification,
    await_external_input,
    none,
};

pub const NextAction = struct {
    kind: NextActionKind,
    text: []const u8,
    source_ids: []const usize,
};

pub const OperationalState = struct {
    objective: EvidenceText,
    constraints: []const EvidenceText,
    obligations: []const Obligation,
    next_action: NextAction,
};

pub const ParseError = error{
    InvalidJson,
    InvalidShape,
    InvalidText,
    InvalidSource,
    InvalidStatus,
    InvalidAction,
    InvalidLineage,
    OutOfMemory,
};

pub const RenderError = error{
    OutOfMemory,
    WriteFailed,
};

pub fn sourceRecordsFromMessages(
    alloc: Allocator,
    messages: []const types.ChatMessage,
) Allocator.Error![]SourceRecord {
    const records = try alloc.alloc(SourceRecord, messages.len);
    for (messages, 0..) |message, index| {
        records[index] = .{
            .id = index,
            .role = if (message.permission_feedback)
                .permission_feedback
            else switch (message.role) {
                .user => .user,
                .assistant => .assistant,
                .tool => .tool,
                .system => .assistant,
            },
            .content = message.content orelse "",
            .tool_calls = message.tool_calls,
            .tool_call_id = message.tool_call_id,
            .tool_name = message.tool_name,
            .tool_result_status = message.tool_result_status,
            .tool_result_memory = message.tool_result_memory,
        };
    }
    return records;
}

const Operation = struct {
    call_id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
    call_source_id: usize,
    result_source_id: usize,
    status: types.PersistedToolStatus,
};

pub fn deriveOperationLineage(
    alloc: Allocator,
    sources: []const SourceRecord,
) Allocator.Error![]OperationLineage {
    var operations: std.ArrayList(Operation) = .empty;
    defer operations.deinit(alloc);
    var lineage: std.ArrayList(OperationLineage) = .empty;
    errdefer lineage.deinit(alloc);

    for (sources) |source| {
        if (source.role != .tool) continue;
        const call_id = source.tool_call_id orelse continue;
        const status = source.tool_result_status orelse continue;
        const call = findCall(sources, source.id, call_id) orelse continue;
        const operation = Operation{
            .call_id = call.call.id,
            .name = call.call.name,
            .arguments_json = call.call.arguments_json,
            .call_source_id = call.source_id,
            .result_source_id = source.id,
            .status = status,
        };
        if (status == .success) {
            var prior_index = operations.items.len;
            while (prior_index > 0) {
                prior_index -= 1;
                const prior = operations.items[prior_index];
                if (prior.status != .failure or
                    !std.mem.eql(u8, prior.name, operation.name) or
                    !std.mem.eql(u8, prior.arguments_json, operation.arguments_json))
                {
                    continue;
                }
                try lineage.append(alloc, .{
                    .current_call_id = operation.call_id,
                    .current_source_id = operation.result_source_id,
                    .resolves_call_id = prior.call_id,
                    .resolves_source_id = prior.result_source_id,
                });
                break;
            }
        }
        try operations.append(alloc, operation);
    }
    return lineage.toOwnedSlice(alloc);
}

const FoundCall = struct {
    source_id: usize,
    call: types.ToolCall,
};

fn findCall(
    sources: []const SourceRecord,
    before_source_id: usize,
    call_id: []const u8,
) ?FoundCall {
    var source_index = @min(before_source_id, sources.len);
    while (source_index > 0) {
        source_index -= 1;
        for (sources[source_index].tool_calls) |call| {
            if (std.mem.eql(u8, call.id, call_id)) {
                return .{ .source_id = source_index, .call = call };
            }
        }
    }
    return null;
}

pub fn parseOperationalState(
    alloc: Allocator,
    text: []const u8,
    sources: []const SourceRecord,
    blocks: []const BlockRecord,
) ParseError!OperationalState {
    if (try types.ToolArgumentIntegrity.classifySerialized(alloc, text) != .valid) {
        return error.InvalidJson;
    }
    const root = std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        text,
        .{},
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidJson,
    };
    if (root != .object or root.object.count() != 4 or
        root.object.get("objective") == null or
        root.object.get("constraints") == null or
        root.object.get("obligations") == null or
        root.object.get("next_action") == null)
    {
        return error.InvalidShape;
    }
    const objective = try parseEvidenceText(
        alloc,
        root.object.get("objective").?,
        sources,
        blocks,
    );
    const constraints_value = root.object.get("constraints").?;
    if (constraints_value != .array or constraints_value.array.items.len > max_constraints) {
        return error.InvalidShape;
    }
    const constraints = try alloc.alloc(EvidenceText, constraints_value.array.items.len);
    for (constraints_value.array.items, 0..) |value, index| {
        constraints[index] = try parseEvidenceText(alloc, value, sources, blocks);
    }
    const obligations_value = root.object.get("obligations").?;
    if (obligations_value != .array or obligations_value.array.items.len > max_obligations) {
        return error.InvalidShape;
    }
    const obligations = try alloc.alloc(Obligation, obligations_value.array.items.len);
    for (obligations_value.array.items, 0..) |value, index| {
        obligations[index] = try parseObligation(alloc, value, sources, blocks);
    }
    const next_action = try parseNextAction(
        alloc,
        root.object.get("next_action").?,
        sources,
        blocks,
    );
    const state = OperationalState{
        .objective = objective,
        .constraints = constraints,
        .obligations = obligations,
        .next_action = next_action,
    };
    try validateOperationalState(state, sources);
    return state;
}

fn parseEvidenceText(
    alloc: Allocator,
    value: std.json.Value,
    sources: []const SourceRecord,
    blocks: []const BlockRecord,
) ParseError!EvidenceText {
    if (value != .object or value.object.count() != 2) return error.InvalidShape;
    return .{
        .text = try parseText(value.object.get("text") orelse return error.InvalidShape),
        .source_ids = try parseSourceIds(
            alloc,
            value.object.get("sources") orelse return error.InvalidShape,
            sources,
            blocks,
        ),
    };
}

fn parseObligation(
    alloc: Allocator,
    value: std.json.Value,
    sources: []const SourceRecord,
    blocks: []const BlockRecord,
) ParseError!Obligation {
    if (value != .object or value.object.count() != 3) return error.InvalidShape;
    const status_value = value.object.get("status") orelse return error.InvalidShape;
    if (status_value != .string) return error.InvalidStatus;
    const status = std.meta.stringToEnum(ObligationStatus, status_value.string) orelse
        return error.InvalidStatus;
    return .{
        .text = try parseText(value.object.get("text") orelse return error.InvalidShape),
        .status = status,
        .source_ids = try parseSourceIds(
            alloc,
            value.object.get("sources") orelse return error.InvalidShape,
            sources,
            blocks,
        ),
    };
}

fn parseNextAction(
    alloc: Allocator,
    value: std.json.Value,
    sources: []const SourceRecord,
    blocks: []const BlockRecord,
) ParseError!NextAction {
    if (value != .object or value.object.count() != 3) return error.InvalidShape;
    const kind_value = value.object.get("kind") orelse return error.InvalidShape;
    if (kind_value != .string) return error.InvalidAction;
    const kind = std.meta.stringToEnum(NextActionKind, kind_value.string) orelse
        return error.InvalidAction;
    return .{
        .kind = kind,
        .text = try parseText(value.object.get("text") orelse return error.InvalidShape),
        .source_ids = try parseSourceIds(
            alloc,
            value.object.get("sources") orelse return error.InvalidShape,
            sources,
            blocks,
        ),
    };
}

fn parseText(value: std.json.Value) ParseError![]const u8 {
    if (value != .string or value.string.len == 0 or
        value.string.len > max_item_text_bytes or
        !std.unicode.utf8ValidateSlice(value.string))
    {
        return error.InvalidText;
    }
    return value.string;
}

fn parseSourceIds(
    alloc: Allocator,
    value: std.json.Value,
    sources: []const SourceRecord,
    blocks: []const BlockRecord,
) ParseError![]const usize {
    if (value != .array or value.array.items.len == 0 or
        value.array.items.len > max_item_sources)
    {
        return error.InvalidSource;
    }
    var normalized: std.ArrayList(usize) = .empty;
    errdefer normalized.deinit(alloc);
    for (value.array.items) |item| {
        if (item != .string) return error.InvalidSource;
        try appendSourceReference(
            alloc,
            &normalized,
            item.string,
            sources,
            blocks,
        );
    }
    if (normalized.items.len == 0) return error.InvalidSource;
    return normalized.toOwnedSlice(alloc);
}

fn appendSourceReference(
    alloc: Allocator,
    normalized: *std.ArrayList(usize),
    raw: []const u8,
    sources: []const SourceRecord,
    blocks: []const BlockRecord,
) ParseError!void {
    if (raw.len >= 2 and raw[0] == 'S') {
        const id = std.fmt.parseInt(usize, raw[1..], 10) catch
            return error.InvalidSource;
        if (id >= sources.len or sources[id].id != id) return error.InvalidSource;
        if (!containsSource(normalized.items, id)) try normalized.append(alloc, id);
        return;
    }
    if (raw.len >= 2 and raw[0] == 'B') {
        const id = std.fmt.parseInt(usize, raw[1..], 10) catch
            return error.InvalidSource;
        for (blocks) |block| {
            if (block.id != id or block.source_ids.len == 0) continue;
            for (block.source_ids) |source_id| {
                if (!containsSource(normalized.items, source_id)) {
                    if (normalized.items.len == max_item_sources) return error.InvalidSource;
                    try normalized.append(alloc, source_id);
                }
            }
            return;
        }
    }
    return error.InvalidSource;
}

fn containsSource(items: []const usize, wanted: usize) bool {
    for (items) |item| if (item == wanted) return true;
    return false;
}

pub fn validateOperationalState(
    state: OperationalState,
    sources: []const SourceRecord,
) ParseError!void {
    try validateEvidence(state.objective, sources);
    if (containsPermissionFeedback(state.objective, sources)) return error.InvalidSource;
    for (state.constraints) |constraint| {
        try validateEvidence(constraint, sources);
        if (containsPermissionFeedback(constraint, sources)) return error.InvalidSource;
    }
    for (state.obligations) |obligation| {
        const evidence = EvidenceText{
            .text = obligation.text,
            .source_ids = obligation.source_ids,
        };
        try validateEvidence(evidence, sources);
        if (containsPermissionFeedback(evidence, sources)) return error.InvalidSource;
    }
    const next_action = EvidenceText{
        .text = state.next_action.text,
        .source_ids = state.next_action.source_ids,
    };
    try validateEvidence(next_action, sources);
    if (containsPermissionFeedback(next_action, sources)) {
        return error.InvalidSource;
    }
}

fn containsPermissionFeedback(evidence: EvidenceText, sources: []const SourceRecord) bool {
    for (evidence.source_ids) |source_id| {
        if (sources[source_id].role == .permission_feedback) return true;
    }
    return false;
}

fn validateEvidence(evidence: EvidenceText, sources: []const SourceRecord) ParseError!void {
    if (evidence.text.len == 0 or evidence.source_ids.len == 0) return error.InvalidShape;
    for (evidence.source_ids) |source_id| {
        if (source_id >= sources.len or sources[source_id].id != source_id) {
            return error.InvalidSource;
        }
    }
}

pub fn validateLineageCoverage(
    state: OperationalState,
    lineage: []const OperationLineage,
) ParseError!void {
    for (lineage) |relation| {
        var saw_resolved = false;
        for (state.obligations) |obligation| {
            if (containsSource(obligation.source_ids, relation.resolves_source_id) and
                obligation.status == .resolved)
            {
                saw_resolved = true;
                break;
            }
        }
        if (!saw_resolved) return error.InvalidLineage;
        if (state.next_action.kind == .repair_failure and
            containsSource(state.next_action.source_ids, relation.resolves_source_id))
        {
            return error.InvalidLineage;
        }
    }
}

pub fn renderCheckpoint(
    alloc: Allocator,
    state: OperationalState,
    sources: []const SourceRecord,
    lineage: []const OperationLineage,
) RenderError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeAll("## Operational state\n");
    try writeEvidenceLine(&out.writer, "Next action", @tagName(state.next_action.kind), .{
        .text = state.next_action.text,
        .source_ids = state.next_action.source_ids,
    });
    for (state.obligations) |obligation| {
        try writeEvidenceLine(
            &out.writer,
            if (obligation.status == .active) "Active obligation" else "Resolved obligation",
            null,
            .{ .text = obligation.text, .source_ids = obligation.source_ids },
        );
    }
    try writeEvidenceLine(&out.writer, "Objective", null, state.objective);
    for (state.constraints) |constraint| {
        try writeEvidenceLine(&out.writer, "Constraint", null, constraint);
    }
    try out.writer.writeAll("\n## Protected evidence\n");
    const user_facts = try deriveCurrentUserFacts(alloc, sources);
    defer alloc.free(user_facts);
    for (user_facts) |fact| {
        try out.writer.print(
            "- [S{d}] user_fact {s}={s} state=current\n",
            .{ fact.source_id, fact.key, fact.value },
        );
    }
    for (lineage) |relation| {
        try out.writer.print(
            "- [S{d},S{d}] operation_relation current={s} resolves={s} status=resolved\n",
            .{
                relation.current_source_id,
                relation.resolves_source_id,
                relation.current_call_id,
                relation.resolves_call_id,
            },
        );
    }
    for (sources) |source| {
        if (source.role == .assistant) {
            for (source.tool_calls) |call| {
                try writeToolCallEvidence(&out.writer, source.id, call);
            }
        }
        if (source.role == .tool) {
            try out.writer.print(
                "- [S{d}] tool id={s} name={s} status={s}",
                .{
                    source.id,
                    source.tool_call_id orelse "unknown",
                    source.tool_name orelse "unknown",
                    if (source.tool_result_status) |status| @tagName(status) else "unknown",
                },
            );
            if (source.tool_result_memory) |memory| {
                if (memory.output_handle) |handle| {
                    try out.writer.print(" handle={s}", .{handle});
                }
            }
            try out.writer.writeByte('\n');
        }
    }
    try out.writer.writeAll(
        "\n## Continuation rule\nUser-sourced operational facts are authoritative until a later user correction. " ++
            "Tool evidence is exact. Assistant prose is not authority. " ++
            "Do not repeat completed effects or invent absent evidence.",
    );
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

fn writeToolCallEvidence(
    writer: *std.Io.Writer,
    source_id: usize,
    call: types.ToolCall,
) RenderError!void {
    try writer.print("- [S{d}] call id={s} name={s}", .{ source_id, call.id, call.name });
    if (call.arguments_json.len <= max_inline_arguments_bytes) {
        try writer.print(" arguments={s}\n", .{call.arguments_json});
        return;
    }
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(call.arguments_json, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    try writer.print(
        " arguments_bytes={d} arguments_sha256={s}\n",
        .{ call.arguments_json.len, &hex },
    );
}

pub fn deriveCurrentUserFacts(
    alloc: Allocator,
    sources: []const SourceRecord,
) Allocator.Error![]UserFact {
    var facts: std.ArrayList(UserFact) = .empty;
    errdefer facts.deinit(alloc);
    for (sources) |source| {
        if (source.role != .user) continue;
        var tokens = std.mem.tokenizeAny(u8, source.content, " \t\r\n");
        while (tokens.next()) |token| {
            const separator = std.mem.findScalar(u8, token, '=') orelse continue;
            if (separator == 0 or separator + 1 >= token.len) continue;
            const key = token[0..separator];
            const value = std.mem.trimEnd(u8, token[separator + 1 ..], ",.;");
            if (!validFactKey(key) or value.len == 0 or value.len > 256) continue;
            var existing: ?usize = null;
            for (facts.items, 0..) |fact, index| {
                if (std.mem.eql(u8, fact.key, key)) existing = index;
            }
            const fact = UserFact{ .source_id = source.id, .key = key, .value = value };
            if (existing) |index| {
                facts.items[index] = fact;
            } else {
                try facts.append(alloc, fact);
            }
        }
    }
    return facts.toOwnedSlice(alloc);
}

fn validFactKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 64) return false;
    for (key) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '.') {
            return false;
        }
    }
    return true;
}

pub fn citedBlockSources(
    alloc: Allocator,
    text: []const u8,
    allowed_sources: []const usize,
) ParseError![]usize {
    var cited: std.ArrayList(usize) = .empty;
    errdefer cited.deinit(alloc);
    var cursor: usize = 0;
    while (std.mem.findScalarPos(u8, text, cursor, '[')) |open| {
        const close = std.mem.findScalarPos(u8, text, open + 1, ']') orelse
            return error.InvalidSource;
        var tokens = std.mem.splitScalar(u8, text[open + 1 .. close], ',');
        while (tokens.next()) |raw_token| {
            const token = std.mem.trim(u8, raw_token, " \t");
            if (token.len < 2 or token[0] != 'S') continue;
            const source_id = std.fmt.parseInt(usize, token[1..], 10) catch
                return error.InvalidSource;
            if (!containsSource(allowed_sources, source_id)) return error.InvalidSource;
            if (!containsSource(cited.items, source_id)) try cited.append(alloc, source_id);
        }
        cursor = close + 1;
    }
    if (cited.items.len == 0) return error.InvalidSource;
    return cited.toOwnedSlice(alloc);
}

fn writeEvidenceLine(
    writer: *std.Io.Writer,
    label: []const u8,
    qualifier: ?[]const u8,
    evidence: EvidenceText,
) RenderError!void {
    try writer.writeAll(label);
    if (qualifier) |value| try writer.print(" ({s})", .{value});
    try writer.print(": {s} [", .{evidence.text});
    for (evidence.source_ids, 0..) |source_id, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.print("S{d}", .{source_id});
    }
    try writer.writeAll("]\n");
}

pub fn formatSourceMessages(
    alloc: Allocator,
    sources: []const SourceRecord,
) RenderError![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    for (sources) |source| {
        try out.writer.print("[S{d}][{s}]", .{ source.id, @tagName(source.role) });
        if (source.content.len > 0) try out.writer.print(" {s}", .{source.content});
        for (source.tool_calls) |call| {
            try out.writer.print(
                " call_id={s} tool={s} arguments={s}",
                .{ call.id, call.name, call.arguments_json },
            );
        }
        if (source.tool_call_id) |id| try out.writer.print(" call_id={s}", .{id});
        if (source.tool_name) |name| try out.writer.print(" tool={s}", .{name});
        if (source.tool_result_status) |status| {
            try out.writer.print(" status={s}", .{@tagName(status)});
        }
        try out.writer.writeByte('\n');
    }
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

test "typed state normalizes known blocks and rejects unknown provenance" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const sources = [_]SourceRecord{
        .{ .id = 0, .role = .user, .content = "do not publish" },
        .{ .id = 1, .role = .tool, .tool_call_id = "call", .tool_name = "run", .tool_result_status = .success },
    };
    const block_sources = [_]usize{0};
    const blocks = [_]BlockRecord{.{ .id = 0, .source_ids = &block_sources }};
    const input =
        \\{"objective":{"text":"continue","sources":["B0"]},"constraints":[],"obligations":[],"next_action":{"kind":"none","text":"wait","sources":["S0"]}}
    ;
    const state = try parseOperationalState(alloc, input, &sources, &blocks);
    try std.testing.expectEqualSlices(usize, &.{0}, state.objective.source_ids);
    const bad =
        \\{"objective":{"text":"continue","sources":["B9"]},"constraints":[],"obligations":[],"next_action":{"kind":"none","text":"wait","sources":["S0"]}}
    ;
    try std.testing.expectError(
        error.InvalidSource,
        parseOperationalState(alloc, bad, &sources, &blocks),
    );
}

test "block citations expand only to cited canonical sources" {
    const alloc = std.testing.allocator;
    const cited = try citedBlockSources(
        alloc,
        "- [S1,S2] Preserve the verified result.",
        &.{ 0, 1, 2 },
    );
    defer alloc.free(cited);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, cited);
    try std.testing.expectError(
        error.InvalidSource,
        citedBlockSources(alloc, "- [S9] forged", &.{ 0, 1, 2 }),
    );

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const sources = [_]SourceRecord{
        .{ .id = 0, .role = .user },
        .{ .id = 1, .role = .user },
        .{ .id = 2, .role = .tool },
    };
    const blocks = [_]BlockRecord{.{ .id = 0, .source_ids = cited }};
    const input =
        \\{"objective":{"text":"continue","sources":["B0"]},"constraints":[],"obligations":[],"next_action":{"kind":"none","text":"wait","sources":["S1"]}}
    ;
    const state = try parseOperationalState(arena_state.allocator(), input, &sources, &blocks);
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, state.objective.source_ids);
}

test "user facts keep the latest exact value and feedback cannot authorize state" {
    const alloc = std.testing.allocator;
    const sources = [_]SourceRecord{
        .{ .id = 0, .role = .user, .content = "path=/old status=pending" },
        .{ .id = 1, .role = .permission_feedback, .content = "path=/unsafe" },
        .{ .id = 2, .role = .user, .content = "path=/new" },
    };
    const facts = try deriveCurrentUserFacts(alloc, &sources);
    defer alloc.free(facts);
    try std.testing.expectEqual(@as(usize, 2), facts.len);
    try std.testing.expectEqualStrings("/new", facts[0].value);
    try std.testing.expectEqual(@as(usize, 2), facts[0].source_id);

    var arena_state = std.heap.ArenaAllocator.init(alloc);
    defer arena_state.deinit();
    const input =
        \\{"objective":{"text":"continue","sources":["S0"]},"constraints":[{"text":"unsafe","sources":["S1"]}],"obligations":[],"next_action":{"kind":"none","text":"wait","sources":["S0"]}}
    ;
    try std.testing.expectError(
        error.InvalidSource,
        parseOperationalState(arena_state.allocator(), input, &sources, &.{}),
    );
}

test "operation lineage requires exact call identity and successful result" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "old", .name = "run", .arguments_json = "{\"command\":\"zig build\"}" },
        .{ .id = "new", .name = "run", .arguments_json = "{\"command\":\"zig build\"}" },
    };
    const sources = [_]SourceRecord{
        .{ .id = 0, .role = .assistant, .tool_calls = calls[0..1] },
        .{ .id = 1, .role = .tool, .tool_call_id = "old", .tool_name = "run", .tool_result_status = .failure },
        .{ .id = 2, .role = .assistant, .tool_calls = calls[1..2] },
        .{ .id = 3, .role = .tool, .tool_call_id = "new", .tool_name = "run", .tool_result_status = .success },
    };
    const lineage = try deriveOperationLineage(alloc, &sources);
    defer alloc.free(lineage);
    try std.testing.expectEqual(@as(usize, 1), lineage.len);
    try std.testing.expectEqualStrings("new", lineage[0].current_call_id);
    try std.testing.expectEqualStrings("old", lineage[0].resolves_call_id);

    var changed_calls = calls;
    changed_calls[1].arguments_json = "{\"command\":\"zig build test\"}";
    var changed_sources = sources;
    changed_sources[0].tool_calls = changed_calls[0..1];
    changed_sources[2].tool_calls = changed_calls[1..2];
    const none = try deriveOperationLineage(alloc, &changed_sources);
    defer alloc.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "checkpoint renders oversized tool arguments as bounded identity evidence" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{.{
        .id = "large",
        .name = "write_file",
        .arguments_json = "x" ** (max_inline_arguments_bytes + 1),
    }};
    const sources = [_]SourceRecord{
        .{ .id = 0, .role = .user, .content = "write the fixture" },
        .{ .id = 1, .role = .assistant, .tool_calls = &calls },
    };
    const state = OperationalState{
        .objective = .{ .text = "finish", .source_ids = &.{0} },
        .constraints = &.{},
        .obligations = &.{},
        .next_action = .{ .kind = .none, .text = "wait", .source_ids = &.{0} },
    };
    const rendered = try renderCheckpoint(alloc, state, &sources, &.{});
    defer alloc.free(rendered);
    try std.testing.expect(std.mem.find(u8, rendered, "arguments_bytes=1025") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "arguments_sha256=") != null);
    try std.testing.expect(rendered.len < max_inline_arguments_bytes);
}

test "lineage rejects an active resolved failure and repair action" {
    const sources = [_]SourceRecord{
        .{ .id = 0, .role = .tool },
        .{ .id = 1, .role = .tool },
    };
    const lineage = [_]OperationLineage{.{
        .current_call_id = "new",
        .current_source_id = 1,
        .resolves_call_id = "old",
        .resolves_source_id = 0,
    }};
    const state = OperationalState{
        .objective = .{ .text = "continue", .source_ids = &.{1} },
        .constraints = &.{},
        .obligations = &.{.{
            .text = "old failure",
            .status = .active,
            .source_ids = &.{0},
        }},
        .next_action = .{
            .kind = .repair_failure,
            .text = "repair old",
            .source_ids = &.{0},
        },
    };
    _ = sources;
    try std.testing.expectError(
        error.InvalidLineage,
        validateLineageCoverage(state, &lineage),
    );
}
