const std = @import("std");
const transcript_blocks = @import("../render_engine/transcript_blocks.zig");

pub const EntrySpan = transcript_blocks.EntryByteSpan;

pub const Cursor = union(enum) {
    start,
    after: struct {
        entry_id: u32,
        kind: transcript_blocks.TranscriptBlockKind,
        ends_with_newline: bool,
    },
    at: struct {
        entry_id: u32,
        entry_offset: usize,
        cols: u16,
    },
};

pub const Decision = union(enum) {
    hold,
    incompatible,
    append: struct {
        start: usize,
        end: usize,
        prefix_newlines: u16,
        next: Cursor,
    },
};

pub fn decide(
    cursor: Cursor,
    cols: u16,
    source_len: usize,
    finalized_end: usize,
    spans: []const EntrySpan,
) Decision {
    if (cols == 0 or finalized_end > source_len) return .incompatible;
    var prefix_newlines: u16 = 0;
    const start = switch (cursor) {
        .start => 0,
        .after => |after| blk: {
            if (findSpan(spans, after.entry_id)) |span| break :blk span.end;
            var recovery_index: ?usize = null;
            for (spans, 0..) |span, index| {
                if (span.entry_id > after.entry_id) {
                    recovery_index = index;
                    break;
                }
            }
            const index = recovery_index orelse return .incompatible;
            for (spans[0..index]) |span| {
                if (span.entry_id > after.entry_id) return .incompatible;
            }
            for (spans[index..]) |span| {
                if (span.entry_id <= after.entry_id) return .incompatible;
            }
            const first = spans[index];
            if (first.entry_id != after.entry_id +% 1) return .incompatible;
            prefix_newlines = transcript_blocks.blockSeparatorNewlineCount(
                after.kind,
                first.kind,
            ) -| @intFromBool(after.ends_with_newline);
            break :blk first.content_start;
        },
        .at => |at| blk: {
            if (at.cols != cols) return .incompatible;
            const span = findSpan(spans, at.entry_id) orelse return .incompatible;
            const span_len = span.end -| span.content_start;
            if (at.entry_offset > span_len) return .incompatible;
            break :blk span.content_start + at.entry_offset;
        },
    };
    if (finalized_end < start) return .incompatible;
    if (finalized_end == start) return .hold;
    if (spans.len == 0) return .incompatible;

    var endpoint: ?EntrySpan = null;
    for (spans) |span| {
        if (span.start > span.content_start or span.content_start > span.end or
            span.end > source_len)
        {
            return .incompatible;
        }
        if (finalized_end >= span.content_start and finalized_end <= span.end) {
            endpoint = span;
            break;
        }
    }
    const span = endpoint orelse return .incompatible;
    const next: Cursor = if (finalized_end == span.end and
        span.kind != .assistant_turn)
        .{ .after = .{
            .entry_id = span.entry_id,
            .kind = span.kind,
            .ends_with_newline = span.ends_with_newline,
        } }
    else
        .{ .at = .{
            .entry_id = span.entry_id,
            .entry_offset = finalized_end - span.content_start,
            .cols = cols,
        } };
    return .{ .append = .{
        .start = start,
        .end = finalized_end,
        .prefix_newlines = prefix_newlines,
        .next = next,
    } };
}

fn findSpan(spans: []const EntrySpan, entry_id: u32) ?EntrySpan {
    for (spans) |span| {
        if (span.entry_id == entry_id) return span;
    }
    return null;
}

test "presentation record cursor advances finalized entry bytes exactly once" {
    const spans = [_]EntrySpan{
        .{ .entry_id = 1, .kind = .assistant_turn, .start = 0, .content_start = 0, .end = 4 },
        .{ .entry_id = 2, .kind = .user_turn, .start = 4, .content_start = 4, .end = 10 },
    };
    const first = decide(.start, 80, 10, 4, &spans);
    try std.testing.expect(first == .append);
    try std.testing.expectEqual(@as(usize, 0), first.append.start);
    try std.testing.expectEqual(@as(usize, 4), first.append.end);
    try std.testing.expect(first.append.next == .at);
    try std.testing.expectEqual(@as(u32, 1), first.append.next.at.entry_id);

    const second = decide(first.append.next, 80, 10, 10, &spans);
    try std.testing.expect(second == .append);
    try std.testing.expectEqual(@as(usize, 4), second.append.start);
    try std.testing.expectEqual(@as(usize, 10), second.append.end);
    try std.testing.expect(decide(second.append.next, 80, 10, 10, &spans) == .hold);
    try std.testing.expect(decide(second.append.next, 40, 10, 10, &spans) == .hold);
    try std.testing.expect(decide(.{ .at = .{
        .entry_id = 2,
        .entry_offset = 1,
        .cols = 80,
    } }, 40, 10, 10, &spans) == .incompatible);
}

test "presentation record resumes when a finalized assistant entry grows" {
    const initial_spans = [_]EntrySpan{
        .{ .entry_id = 1, .kind = .assistant_turn, .start = 0, .content_start = 0, .end = 4 },
    };
    const initial = decide(.start, 80, 4, 4, &initial_spans);
    try std.testing.expect(initial == .append);
    try std.testing.expect(initial.append.next == .at);

    const grown_spans = [_]EntrySpan{
        .{ .entry_id = 1, .kind = .assistant_turn, .start = 0, .content_start = 0, .end = 8 },
    };
    const grown = decide(initial.append.next, 80, 8, 8, &grown_spans);
    try std.testing.expect(grown == .append);
    try std.testing.expectEqual(@as(usize, 4), grown.append.start);
    try std.testing.expectEqual(@as(usize, 8), grown.append.end);
}

test "presentation record resumes after a fully recorded cursor entry is pruned" {
    const spans = [_]EntrySpan{
        .{ .entry_id = 3, .kind = .system_notice, .start = 0, .content_start = 0, .end = 5 },
        .{ .entry_id = 9, .kind = .user_turn, .start = 5, .content_start = 5, .end = 10 },
    };
    const decision = decide(.{ .after = .{
        .entry_id = 8,
        .kind = .assistant_turn,
        .ends_with_newline = false,
    } }, 80, 10, 10, &spans);
    try std.testing.expect(decision == .append);
    try std.testing.expectEqual(@as(usize, 5), decision.append.start);
    try std.testing.expectEqual(@as(u16, 2), decision.append.prefix_newlines);
}

test "presentation record rejects an unrecorded pruned entry gap" {
    const spans = [_]EntrySpan{
        .{ .entry_id = 3, .kind = .system_notice, .start = 0, .content_start = 0, .end = 5 },
        .{ .entry_id = 10, .kind = .user_turn, .start = 5, .content_start = 5, .end = 10 },
    };
    const decision = decide(.{ .after = .{
        .entry_id = 8,
        .kind = .assistant_turn,
        .ends_with_newline = false,
    } }, 80, 10, 10, &spans);
    try std.testing.expect(decision == .incompatible);
}
