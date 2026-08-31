const std = @import("std");
const domain = @import("domain.zig");
const text_utils = @import("../shared/text_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const initial_observe_ms: u64 = 1_000;
const wait_ms: u64 = 30_000;
const max_error_code_bytes: usize = 64;

pub const Action = enum {
    run,
    wait,
    send,
    stop,
};

pub const RunInput = struct {
    task: []const u8,
    model: ?[]const u8 = null,
    effort: ?types.ReasoningEffort = null,
};

pub const ChildInput = struct {
    child_id: []const u8,
};

pub const SendInput = struct {
    child_id: []const u8,
    message: []const u8,
};

pub const RequestInput = union(Action) {
    run: RunInput,
    wait: ChildInput,
    send: SendInput,
    stop: ChildInput,
};

pub const Request = union(Action) {
    run: struct {
        task: []u8,
        model: ?[]u8,
        effort: ?types.ReasoningEffort,
    },
    wait: struct { child_id: []u8 },
    send: struct {
        child_id: []u8,
        message: []u8,
    },
    stop: struct { child_id: []u8 },

    pub fn deinit(self: *Request, alloc: Allocator) void {
        switch (self.*) {
            .run => |value| {
                alloc.free(value.task);
                if (value.model) |model| alloc.free(model);
            },
            .wait => |value| alloc.free(value.child_id),
            .send => |value| {
                alloc.free(value.child_id);
                alloc.free(value.message);
            },
            .stop => |value| alloc.free(value.child_id),
        }
        self.* = undefined;
    }

    pub fn action(self: Request) Action {
        return std.meta.activeTag(self);
    }

    pub fn childId(self: Request) ?[]const u8 {
        return switch (self) {
            .run => null,
            .wait => |value| value.child_id,
            .send => |value| value.child_id,
            .stop => |value| value.child_id,
        };
    }

    /// Returns an owned internal command. The caller frees it with
    /// `domain.Command.deinit`.
    pub fn toDomainCommand(self: Request, alloc: Allocator) domain.ValidationError!domain.Command {
        var name_buffer: [domain.max_name_bytes]u8 = undefined;
        return domain.validateCommand(alloc, switch (self) {
            .run => |value| .{ .create = .{
                .name = generatedName(value.task, &name_buffer),
                .mode = .persistent,
                .prompt = value.task,
                .model = value.model,
                .effort = value.effort,
            } },
            .wait => |value| .{ .inspect = .{
                .id = value.child_id,
                .sections = &.{.status},
                .wait = .{
                    .until = .settled,
                    .timeout_ms = wait_ms,
                },
            } },
            .send => |value| .{ .message = .{ .send = .{
                .id = value.child_id,
                .content = value.message,
            } } },
            .stop => |value| .{ .lifecycle = .{
                .id = value.child_id,
                .action = .cancel,
            } },
        });
    }
};

fn generatedName(
    task: []const u8,
    buffer: *[domain.max_name_bytes]u8,
) []const u8 {
    const first_line = if (std.mem.indexOfScalar(u8, task, '\n')) |index|
        task[0..index]
    else
        task;
    const trimmed = std.mem.trim(u8, first_line, " \t\r");
    if (trimmed.len == 0) return "delegate";
    const prefix = text_utils.utf8PrefixByBytes(trimmed, buffer.len);
    @memcpy(buffer[0..prefix.len], prefix);
    for (buffer[0..prefix.len]) |*byte| {
        if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
    }
    const generated = std.mem.trimEnd(u8, buffer[0..prefix.len], " \t\r");
    return if (generated.len == 0) "delegate" else generated;
}

pub const ValidationError = error{
    OutOfMemory,
    InvalidTask,
    InvalidModel,
    InvalidChildId,
    InvalidMessage,
};

/// Validates and owns one model-facing request.
pub fn validateRequest(
    alloc: Allocator,
    input: RequestInput,
) ValidationError!Request {
    return switch (input) {
        .run => |value| blk: {
            try validateText(value.task, domain.max_prompt_bytes, error.InvalidTask);
            if (value.model) |model| {
                try validateText(model, domain.max_model_bytes, error.InvalidModel);
            }
            const task = try alloc.dupe(u8, value.task);
            errdefer alloc.free(task);
            const model = if (value.model) |model|
                try alloc.dupe(u8, model)
            else
                null;
            break :blk .{ .run = .{
                .task = task,
                .model = model,
                .effort = value.effort,
            } };
        },
        .wait => |value| .{ .wait = .{
            .child_id = try validateChildIdAlloc(alloc, value.child_id),
        } },
        .send => |value| blk: {
            domain.validateId(value.child_id) catch return error.InvalidChildId;
            try validateText(value.message, domain.max_message_bytes, error.InvalidMessage);
            const child_id = try alloc.dupe(u8, value.child_id);
            errdefer alloc.free(child_id);
            break :blk .{ .send = .{
                .child_id = child_id,
                .message = try alloc.dupe(u8, value.message),
            } };
        },
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
        !std.unicode.utf8ValidateSlice(value) or std.mem.findScalar(u8, value, 0) != null)
    {
        return invalid;
    }
}

fn validateChildIdAlloc(alloc: Allocator, value: []const u8) ValidationError![]u8 {
    domain.validateId(value) catch return error.InvalidChildId;
    return alloc.dupe(u8, value);
}

pub const Snapshot = struct {
    mode: domain.Mode,
    state: domain.State,
};

pub const RejectCode = enum {
    child_unavailable,
    child_not_messageable,
};

pub const Plan = union(enum) {
    create_and_observe,
    inspect_wait,
    send,
    cancel,
    no_op,
    reject: RejectCode,
};

/// Purely selects the effect to perform from a validated request and an
/// optional authoritative child snapshot.
pub fn plan(request: Request, snapshot: ?Snapshot) Plan {
    return switch (request) {
        .run => .create_and_observe,
        .wait => .inspect_wait,
        .send => if (snapshot) |child|
            if (child.mode == .persistent and switch (child.state) {
                .idle, .queued, .running, .awaiting_approval => true,
                .interrupted, .completed, .failed, .cancelled, .archived => false,
            })
                .send
            else
                .{ .reject = .child_not_messageable }
        else
            .{ .reject = .child_unavailable },
        .stop => if (snapshot) |child| switch (child.state) {
            .queued, .running, .awaiting_approval, .interrupted => .cancel,
            .idle, .completed, .failed, .cancelled, .archived => .no_op,
        } else .{ .reject = .child_unavailable },
    };
}

pub const Result = struct {
    ok: bool,
    operation_id: ?[]const u8 = null,
    child_id: ?[]const u8,
    status: []const u8,
    error_code: ?[]const u8 = null,
    retryable: bool = false,
};

pub fn encodeResultAlloc(alloc: Allocator, result: Result) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.print("{{\"ok\":{s},\"operation_id\":", .{if (result.ok) "true" else "false"});
    try writeOptionalString(&out.writer, result.operation_id);
    try out.writer.writeAll(",\"child_id\":");
    try writeOptionalString(&out.writer, result.child_id);
    try out.writer.writeAll(",\"status\":");
    try std.json.Stringify.value(result.status, .{}, &out.writer);
    try out.writer.writeAll(",\"error_code\":");
    try writeOptionalString(
        &out.writer,
        if (result.error_code) |code| code[0..@min(code.len, max_error_code_bytes)] else null,
    );
    try out.writer.print(",\"retryable\":{s}}}", .{if (result.retryable) "true" else "false"});
    return out.toOwnedSlice();
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| {
        try std.json.Stringify.value(text, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
}

test "managed request validation owns input and maps to internal commands" {
    const alloc = std.testing.allocator;
    var request = try validateRequest(alloc, .{ .run = .{
        .task = "inspect the failure",
        .model = "openai/gpt-5.6-sol",
        .effort = .literal("high"),
    } });
    defer request.deinit(alloc);
    var command = try request.toDomainCommand(alloc);
    defer command.deinit(alloc);
    try std.testing.expect(command == .create);
    try std.testing.expectEqual(domain.Mode.persistent, command.create.mode);
    try std.testing.expect(!command.create.permission_mode_explicit);
    try std.testing.expectEqualStrings("inspect the failure", command.create.prompt.?);
    try std.testing.expectEqualStrings("inspect the failure", command.create.configuration.name);
}

test "managed display names are deterministic bounded task summaries" {
    var buffer: [domain.max_name_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "first line",
        generatedName("  first line\nsecond line", &buffer),
    );
    try std.testing.expectEqualStrings("delegate", generatedName(" \nnext", &buffer));
    try std.testing.expectEqualStrings("delegate", generatedName("\x01", &buffer));
}

test "managed planner covers every child state without hidden lifecycle effects" {
    const alloc = std.testing.allocator;
    var send = try validateRequest(alloc, .{ .send = .{
        .child_id = "01J00000000000000000000000",
        .message = "continue",
    } });
    defer send.deinit(alloc);
    var stop = try validateRequest(alloc, .{ .stop = .{
        .child_id = "01J00000000000000000000000",
    } });
    defer stop.deinit(alloc);
    var wait = try validateRequest(alloc, .{ .wait = .{
        .child_id = "01J00000000000000000000000",
    } });
    defer wait.deinit(alloc);
    try std.testing.expect(plan(wait, null) == .inspect_wait);

    inline for (std.meta.tags(domain.State)) |state| {
        const snapshot = Snapshot{ .mode = .persistent, .state = state };
        const send_plan = plan(send, snapshot);
        const stop_plan = plan(stop, snapshot);
        switch (state) {
            .idle, .queued, .running, .awaiting_approval => try std.testing.expect(send_plan == .send),
            .interrupted, .completed, .failed, .cancelled, .archived => try std.testing.expect(send_plan == .reject),
        }
        switch (state) {
            .queued, .running, .awaiting_approval, .interrupted => try std.testing.expect(stop_plan == .cancel),
            .idle, .completed, .failed, .cancelled, .archived => try std.testing.expect(stop_plan == .no_op),
        }
    }
    try std.testing.expect(plan(send, .{ .mode = .one_off, .state = .running }) == .reject);
}

test "managed result encoding is compact and explicit" {
    const encoded = try encodeResultAlloc(std.testing.allocator, .{
        .ok = true,
        .child_id = "child-1",
        .status = "running",
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings(
        "{\"ok\":true,\"operation_id\":null,\"child_id\":\"child-1\",\"status\":\"running\",\"error_code\":null,\"retryable\":false}",
        encoded,
    );
}

fn checkValidationAllocationFailures(alloc: Allocator) !void {
    var request = try validateRequest(alloc, .{ .send = .{
        .child_id = "01J00000000000000000000000",
        .message = "continue",
    } });
    request.deinit(alloc);
}

test "managed request validation cleans partial allocation failures" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        checkValidationAllocationFailures,
        .{},
    );
}
