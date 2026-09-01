const std = @import("std");
const agent_config = @import("agent_config.zig");
const domain = @import("domain.zig");

const Allocator = std.mem.Allocator;

pub const initial_observe_ms: u64 = 1_000;
pub const wait_ms: u64 = 30_000;
const max_error_code_bytes: usize = 64;

pub const Action = enum { run, message, wait, stop };

pub const RunInput = struct { task: []const u8 };
pub const MessageInput = struct {
    agent: []const u8,
    message: []const u8,
};
pub const ChildInput = struct { child_id: []const u8 };

pub const RequestInput = union(Action) {
    run: RunInput,
    message: MessageInput,
    wait: ChildInput,
    stop: ChildInput,
};

pub const Request = union(Action) {
    run: struct { task: []u8 },
    message: struct {
        agent: []u8,
        message: []u8,
    },
    wait: struct { child_id: []u8 },
    stop: struct { child_id: []u8 },

    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .run => |value| alloc.free(value.task),
            .message => |value| {
                alloc.free(value.agent);
                alloc.free(value.message);
            },
            .wait => |value| alloc.free(value.child_id),
            .stop => |value| alloc.free(value.child_id),
        }
        self.* = undefined;
    }

    pub fn action(self: Request) Action {
        return std.meta.activeTag(self);
    }

    pub fn childId(self: Request) ?[]const u8 {
        return switch (self) {
            .run, .message => null,
            .wait => |value| value.child_id,
            .stop => |value| value.child_id,
        };
    }

    pub fn agentName(self: Request) ?[]const u8 {
        return switch (self) {
            .message => |value| value.agent,
            .run, .wait, .stop => null,
        };
    }
};

pub const ValidationError = error{
    OutOfMemory,
    InvalidTask,
    InvalidAgent,
    InvalidChildId,
    InvalidMessage,
};

pub fn validateRequest(
    alloc: Allocator,
    input: RequestInput,
) ValidationError!Request {
    return switch (input) {
        .run => |value| blk: {
            try validateText(value.task, domain.max_prompt_bytes, error.InvalidTask);
            break :blk .{ .run = .{ .task = try alloc.dupe(u8, value.task) } };
        },
        .message => |value| blk: {
            if (!agent_config.validName(value.agent)) return error.InvalidAgent;
            try validateText(value.message, domain.max_message_bytes, error.InvalidMessage);
            const agent = try alloc.dupe(u8, value.agent);
            errdefer alloc.free(agent);
            break :blk .{ .message = .{
                .agent = agent,
                .message = try alloc.dupe(u8, value.message),
            } };
        },
        .wait => |value| .{ .wait = .{
            .child_id = try validateChildIdAlloc(alloc, value.child_id),
        } },
        .stop => |value| .{ .stop = .{
            .child_id = try validateChildIdAlloc(alloc, value.child_id),
        } },
    };
}

fn validateText(
    value: []const u8,
    max_bytes: usize,
    invalid: ValidationError,
) ValidationError!void {
    if (value.len == 0 or value.len > max_bytes or
        !std.unicode.utf8ValidateSlice(value) or
        std.mem.findScalar(u8, value, 0) != null)
    {
        return invalid;
    }
}

fn validateChildIdAlloc(alloc: Allocator, value: []const u8) ValidationError![]u8 {
    domain.validateId(value) catch return error.InvalidChildId;
    var segments = std.mem.splitScalar(u8, value, '-');
    const millis = segments.next() orelse return alloc.dupe(u8, value);
    const nanos_suffix = segments.next() orelse return alloc.dupe(u8, value);
    const random = segments.next() orelse return alloc.dupe(u8, value);
    if (segments.next() != null or nanos_suffix.len != 6 or
        !asciiDigits(millis) or !asciiDigits(nanos_suffix) or
        !lowerHex(random, 16))
    {
        return alloc.dupe(u8, value);
    }
    const canonical = try std.fmt.allocPrint(
        alloc,
        "{s}-{s}{s}-{s}",
        .{ millis, millis, nanos_suffix, random },
    );
    domain.validateId(canonical) catch {
        alloc.free(canonical);
        return error.InvalidChildId;
    };
    return canonical;
}

pub fn modelChildIdAlloc(alloc: Allocator, value: []const u8) Allocator.Error![]u8 {
    var segments = std.mem.splitScalar(u8, value, '-');
    const millis = segments.next() orelse return alloc.dupe(u8, value);
    const nanos = segments.next() orelse return alloc.dupe(u8, value);
    const random = segments.next() orelse return alloc.dupe(u8, value);
    if (segments.next() != null or nanos.len != millis.len + 6 or
        !asciiDigits(millis) or !asciiDigits(nanos) or
        !lowerHex(random, 16) or !std.mem.startsWith(u8, nanos, millis))
    {
        return alloc.dupe(u8, value);
    }
    return std.fmt.allocPrint(
        alloc,
        "{s}-{s}-{s}",
        .{ millis, nanos[millis.len..], random },
    );
}

fn asciiDigits(value: []const u8) bool {
    if (value.len == 0) return false;
    for (value) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn lowerHex(value: []const u8, expected_len: usize) bool {
    if (value.len != expected_len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    }
    return true;
}

pub const Kind = enum { one_off, persistent };
pub const Phase = enum { idle, running, awaiting_approval, interrupted, finished };
pub const Snapshot = struct {
    kind: Kind,
    phase: Phase,
};

pub const RejectCode = enum {
    child_unavailable,
    child_busy,
    child_not_persistent,
};

pub const Plan = union(enum) {
    create_one_off,
    create_persistent,
    continue_persistent,
    observe,
    cancel,
    no_op,
    reject: RejectCode,
};

pub fn plan(request: Request, snapshot: ?Snapshot) Plan {
    return switch (request) {
        .run => .create_one_off,
        .message => if (snapshot) |child| switch (child.kind) {
            .one_off => .{ .reject = .child_not_persistent },
            .persistent => switch (child.phase) {
                .idle, .interrupted => .continue_persistent,
                .running, .awaiting_approval => .{ .reject = .child_busy },
                .finished => .{ .reject = .child_unavailable },
            },
        } else .create_persistent,
        .wait => .observe,
        .stop => if (snapshot) |child| switch (child.phase) {
            .running, .awaiting_approval, .interrupted => .cancel,
            .idle, .finished => .no_op,
        } else .{ .reject = .child_unavailable },
    };
}

pub fn requestFingerprint(request: Request) [32]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("fx.subagent.request.v1\x00");
    hash.update(@tagName(request.action()));
    hash.update("\x00");
    switch (request) {
        .run => |value| hash.update(value.task),
        .message => |value| {
            hash.update(value.agent);
            hash.update("\x00");
            hash.update(value.message);
        },
        .wait => |value| hash.update(value.child_id),
        .stop => |value| hash.update(value.child_id),
    }
    return hash.finalResult();
}

pub const Result = struct {
    ok: bool,
    operation_id: ?[]const u8 = null,
    child_id: ?[]const u8 = null,
    status: []const u8,
    result: ?[]const u8 = null,
    error_code: ?[]const u8 = null,
    retryable: bool = false,
};

pub fn encodeResultAlloc(alloc: Allocator, result: Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"ok\":{s},\"operation_id\":", .{
        if (result.ok) "true" else "false",
    });
    try writeOptionalString(&out.writer, result.operation_id);
    try out.writer.writeAll(",\"child_id\":");
    try writeOptionalString(&out.writer, result.child_id);
    try out.writer.writeAll(",\"status\":");
    try std.json.Stringify.value(result.status, .{}, &out.writer);
    try out.writer.writeAll(",\"result\":");
    try writeOptionalString(&out.writer, result.result);
    try out.writer.writeAll(",\"error_code\":");
    try writeOptionalString(
        &out.writer,
        if (result.error_code) |code| code[0..@min(code.len, max_error_code_bytes)] else null,
    );
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

test "minimal request validation owns one-off and persistent intent" {
    const alloc = std.testing.allocator;
    var run = try validateRequest(alloc, .{ .run = .{ .task = "review this" } });
    defer run.deinit(alloc);
    try std.testing.expectEqual(Action.run, run.action());
    try std.testing.expectEqual(Plan.create_one_off, plan(run, null));

    var message = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .message = "review this",
    } });
    defer message.deinit(alloc);
    try std.testing.expectEqual(Action.message, message.action());
    try std.testing.expectEqual(Plan.create_persistent, plan(message, null));
}

test "persistent planning derives continue busy and stop" {
    const alloc = std.testing.allocator;
    var message = try validateRequest(alloc, .{ .message = .{
        .agent = "reviewer",
        .message = "continue",
    } });
    defer message.deinit(alloc);
    try std.testing.expectEqual(
        Plan.continue_persistent,
        plan(message, .{ .kind = .persistent, .phase = .idle }),
    );
    const busy = plan(message, .{ .kind = .persistent, .phase = .running });
    try std.testing.expectEqual(RejectCode.child_busy, busy.reject);

    var stop = try validateRequest(alloc, .{ .stop = .{
        .child_id = "01J00000000000000000000000",
    } });
    defer stop.deinit(alloc);
    try std.testing.expectEqual(
        Plan.cancel,
        plan(stop, .{ .kind = .persistent, .phase = .interrupted }),
    );
    try std.testing.expectEqual(
        Plan.no_op,
        plan(stop, .{ .kind = .persistent, .phase = .idle }),
    );
}

test "child handle projection round trips canonical generated IDs" {
    const alloc = std.testing.allocator;
    const canonical = "1787307451427-1787307451427093000-eeb3173e6e16f798";
    const projected = try modelChildIdAlloc(alloc, canonical);
    defer alloc.free(projected);
    try std.testing.expectEqualStrings(
        "1787307451427-093000-eeb3173e6e16f798",
        projected,
    );
    const restored = try validateChildIdAlloc(alloc, projected);
    defer alloc.free(restored);
    try std.testing.expectEqualStrings(canonical, restored);
}

test "compact result encodes final text without manager fields" {
    const alloc = std.testing.allocator;
    const encoded = try encodeResultAlloc(alloc, .{
        .ok = true,
        .child_id = "child-1",
        .status = "completed",
        .result = "review complete",
    });
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "\"result\":\"review complete\"") != null);
    try std.testing.expect(std.mem.find(u8, encoded, "retryable") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "requested") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "cursor") == null);
}
