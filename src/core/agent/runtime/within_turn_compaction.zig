const std = @import("std");
const types = @import("../../shared/types.zig");

const Allocator = std.mem.Allocator;
const ChatMessage = types.ChatMessage;

pub const default_trigger_bytes: usize = 96 * 1024;
pub const default_trigger_messages: usize = 36;
pub const default_recent_tool_steps: usize = 8;
const max_summary_results: usize = 12;
const max_summary_preview_bytes: usize = 160;

pub const Projection = struct {
    messages: []const ChatMessage,
    compacted: bool = false,
    source_messages: usize = 0,
    projected_messages: usize = 0,
    source_bytes: usize = 0,
    projected_bytes: usize = 0,
    omitted_messages: usize = 0,
};

pub fn project(
    alloc: Allocator,
    messages: []const ChatMessage,
    enabled: bool,
) Allocator.Error!Projection {
    return projectWithLimits(
        alloc,
        messages,
        enabled,
        default_trigger_bytes,
        default_trigger_messages,
        default_recent_tool_steps,
    );
}

fn projectWithLimits(
    alloc: Allocator,
    messages: []const ChatMessage,
    enabled: bool,
    trigger_bytes: usize,
    trigger_messages: usize,
    recent_tool_steps: usize,
) Allocator.Error!Projection {
    const source_bytes = projectedBytes(messages);
    const unchanged = Projection{
        .messages = messages,
        .source_messages = messages.len,
        .projected_messages = messages.len,
        .source_bytes = source_bytes,
        .projected_bytes = source_bytes,
    };
    if (!enabled or
        (source_bytes < trigger_bytes and messages.len < trigger_messages))
    {
        return unchanged;
    }

    const boundary = recentToolStepBoundary(messages, recent_tool_steps) orelse
        return unchanged;
    if (boundary == 0) return unchanged;

    const summary = try buildSummary(alloc, messages[0..boundary]);
    var projected = try alloc.alloc(ChatMessage, messages.len - boundary + 1);
    projected[0] = .{
        .role = .system,
        .content = summary,
        .cache_policy = .no_cache,
    };
    @memcpy(projected[1..], messages[boundary..]);
    return .{
        .messages = projected,
        .compacted = true,
        .source_messages = messages.len,
        .projected_messages = projected.len,
        .source_bytes = source_bytes,
        .projected_bytes = projectedBytes(projected),
        .omitted_messages = boundary,
    };
}

fn projectedBytes(messages: []const ChatMessage) usize {
    var total: usize = 0;
    for (messages) |message| {
        total +|= if (message.content) |content| content.len else 0;
        total +|= if (message.provider_state_json) |state| state.len else 0;
        for (message.tool_calls) |call| {
            total +|= call.name.len;
            total +|= call.arguments_json.len;
        }
    }
    return total;
}

fn recentToolStepBoundary(
    messages: []const ChatMessage,
    recent_tool_steps: usize,
) ?usize {
    if (recent_tool_steps == 0) return null;
    var steps: usize = 0;
    var index = messages.len;
    while (index > 0) {
        index -= 1;
        const message = messages[index];
        if (message.role != .assistant or message.tool_calls.len == 0) continue;
        steps += 1;
        if (steps == recent_tool_steps) return index;
    }
    return null;
}

fn buildSummary(alloc: Allocator, omitted: []const ChatMessage) Allocator.Error![]u8 {
    var tool_results: usize = 0;
    var successful: usize = 0;
    var failed: usize = 0;
    for (omitted) |message| {
        if (message.role != .tool) continue;
        tool_results += 1;
        if (message.tool_result_status == .failure) {
            failed += 1;
        } else {
            successful += 1;
        }
    }

    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    out.writer.print(
        "Active-turn compaction replaced {d} older messages ({d} tool results: {d} successful, {d} failed). The current workspace is authoritative. Reread a file or stored result before relying on omitted details. Recent complete assistant/tool pairs follow.\n",
        .{ omitted.len, tool_results, successful, failed },
    ) catch return error.OutOfMemory;

    const skip_results = tool_results -| max_summary_results;
    var seen_results: usize = 0;
    for (omitted) |message| {
        if (message.role != .tool) continue;
        if (seen_results < skip_results) {
            seen_results += 1;
            continue;
        }
        seen_results += 1;
        const name = message.tool_name orelse "tool";
        const status = if (message.tool_result_status == .failure) "failed" else "succeeded";
        out.writer.print("- {s}: {s}", .{ name, status }) catch
            return error.OutOfMemory;
        if (message.content) |content| {
            if (content.len > 0) {
                out.writer.writeAll("; ") catch return error.OutOfMemory;
                try appendPreview(&out.writer, content);
            }
        }
        out.writer.writeByte('\n') catch return error.OutOfMemory;
    }
    return out.toOwnedSlice();
}

fn appendPreview(writer: *std.Io.Writer, content: []const u8) Allocator.Error!void {
    const limit = @min(content.len, max_summary_preview_bytes);
    for (content[0..limit]) |byte| {
        const safe = switch (byte) {
            '\n', '\r', '\t' => ' ',
            else => byte,
        };
        writer.writeByte(safe) catch return error.OutOfMemory;
    }
    if (content.len > limit) {
        writer.writeAll("...") catch return error.OutOfMemory;
    }
}

test "active-turn compaction preserves complete recent tool pairs" {
    const alloc = std.testing.allocator;
    const calls = [_]types.ToolCall{
        .{ .id = "one", .name = "read_file", .arguments_json = "{}" },
        .{ .id = "two", .name = "terminal", .arguments_json = "{}" },
        .{ .id = "three", .name = "edit_file", .arguments_json = "{}" },
    };
    const messages = [_]ChatMessage{
        .{ .role = .assistant, .tool_calls = calls[0..1] },
        .{ .role = .tool, .content = "old result", .tool_call_id = "one", .tool_name = "read_file", .tool_result_status = .success },
        .{ .role = .assistant, .tool_calls = calls[1..2] },
        .{ .role = .tool, .content = "test failed", .tool_call_id = "two", .tool_name = "terminal", .tool_result_status = .failure },
        .{ .role = .assistant, .tool_calls = calls[2..3] },
        .{ .role = .tool, .content = "edited", .tool_call_id = "three", .tool_name = "edit_file", .tool_result_status = .success },
    };
    const projection = try projectWithLimits(alloc, &messages, true, 1, 1, 2);
    defer {
        alloc.free(@constCast(projection.messages[0].content.?));
        alloc.free(@constCast(projection.messages));
    }
    try std.testing.expect(projection.compacted);
    try std.testing.expectEqual(@as(usize, 2), projection.omitted_messages);
    try std.testing.expectEqual(projectedBytes(projection.messages), projection.projected_bytes);
    try std.testing.expectEqual(types.ChatRole.system, projection.messages[0].role);
    try std.testing.expectEqualStrings("two", projection.messages[1].tool_calls[0].id);
    try std.testing.expectEqualStrings("two", projection.messages[2].tool_call_id.?);
    try std.testing.expectEqualStrings("three", projection.messages[3].tool_calls[0].id);
    try std.testing.expectEqualStrings("three", projection.messages[4].tool_call_id.?);
}

test "active-turn compaction is behavior neutral below its trigger" {
    const messages = [_]ChatMessage{.{ .role = .assistant, .content = "short" }};
    const projection = try project(std.testing.allocator, &messages, true);
    try std.testing.expect(!projection.compacted);
    try std.testing.expectEqual(projection.source_bytes, projection.projected_bytes);
    try std.testing.expect(projection.messages.ptr == messages[0..].ptr);
}
