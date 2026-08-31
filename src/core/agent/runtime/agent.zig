const std = @import("std");
const types = @import("../../shared/types.zig");
const checkpoint_codec = @import("checkpoint.zig");
const state_machine = @import("state_machine.zig");

const Allocator = std.mem.Allocator;
pub const Generation = state_machine.Generation;

pub const AdmissionError = error{
    AgentBusy,
    AgentClosed,
    InvalidGeneration,
    StaleGeneration,
};

pub const TransitionError = error{
    InvalidAgentTransition,
    StaleGeneration,
};

/// The provider-neutral state for one conversation. Product session metadata,
/// persistence, permissions, credentials, and host effects live outside it.
pub const Agent = struct {
    history: std.ArrayList(types.HistoryTurn) = .empty,
    lifecycle: state_machine.State = .{},
    turn_usage: types.Usage = .{},

    pub fn deinit(self: *Agent, alloc: Allocator) void {
        self.clearHistory(alloc);
        self.history.deinit(alloc);
        self.* = undefined;
    }

    pub fn beginPrompt(
        self: *Agent,
        generation: state_machine.Generation,
    ) AdmissionError!void {
        const decision = state_machine.decide(self.lifecycle, .{
            .begin_prompt = generation,
        });
        switch (decision.action) {
            .start_model => {
                self.lifecycle = decision.state;
                self.turn_usage = .{};
            },
            .reject_busy => return error.AgentBusy,
            .stale => |reason| return switch (reason) {
                .generation_reused => error.StaleGeneration,
                .phase_mismatch => error.AgentClosed,
                .generation_mismatch => error.StaleGeneration,
            },
            .invalid => return error.InvalidGeneration,
            else => return error.AgentBusy,
        }
    }

    pub fn beginNextPrompt(self: *Agent) AdmissionError!Generation {
        const generation = std.math.add(
            Generation,
            self.lifecycle.last_generation,
            1,
        ) catch return error.InvalidGeneration;
        try self.beginPrompt(generation);
        return generation;
    }

    pub fn beginToolBatch(
        self: *Agent,
        generation: state_machine.Generation,
        count: u32,
    ) TransitionError!void {
        const decision = state_machine.decide(self.lifecycle, .{
            .model_yielded_tools = .{
                .generation = generation,
                .count = count,
            },
        });
        switch (decision.action) {
            .start_tools => self.lifecycle = decision.state,
            .stale => return error.StaleGeneration,
            else => return error.InvalidAgentTransition,
        }
    }

    pub fn settleToolBatch(
        self: *Agent,
        generation: state_machine.Generation,
    ) TransitionError!void {
        const decision = state_machine.decide(self.lifecycle, .{
            .tools_settled = generation,
        });
        switch (decision.action) {
            .resume_model => self.lifecycle = decision.state,
            .stale => return error.StaleGeneration,
            else => return error.InvalidAgentTransition,
        }
    }

    pub fn cancel(self: *Agent) ?state_machine.Generation {
        const decision = state_machine.decide(self.lifecycle, .cancel);
        return switch (decision.action) {
            .cancel_active => |generation| blk: {
                self.lifecycle = decision.state;
                break :blk generation;
            },
            else => null,
        };
    }

    pub fn finishPrompt(
        self: *Agent,
        generation: state_machine.Generation,
        outcome: state_machine.Outcome,
    ) TransitionError!void {
        if (outcome == .cancelled) _ = self.cancel();
        const completed = state_machine.decide(self.lifecycle, .{
            .complete = .{ .generation = generation, .outcome = outcome },
        });
        switch (completed.action) {
            .publish_result => self.lifecycle = completed.state,
            .stale => return error.StaleGeneration,
            else => return error.InvalidAgentTransition,
        }
        const acknowledged = state_machine.decide(self.lifecycle, .{
            .acknowledge = generation,
        });
        switch (acknowledged.action) {
            .none => self.lifecycle = acknowledged.state,
            else => return error.InvalidAgentTransition,
        }
    }

    pub fn close(self: *Agent) ?state_machine.Generation {
        const decision = state_machine.decide(self.lifecycle, .close);
        return switch (decision.action) {
            .cancel_and_close => |generation| blk: {
                self.lifecycle = decision.state;
                break :blk generation;
            },
            .close => blk: {
                self.lifecycle = decision.state;
                break :blk null;
            },
            .none => null,
            else => unreachable,
        };
    }

    pub fn isBusy(self: *const Agent) bool {
        return state_machine.isBusy(self.lifecycle);
    }

    pub fn isClosed(self: *const Agent) bool {
        return self.lifecycle.phase == .closed;
    }

    pub fn checkpointEligible(self: *const Agent) bool {
        return self.lifecycle.phase == .idle;
    }

    pub fn checkpoint(self: *const Agent, alloc: Allocator) checkpoint_codec.Error![]u8 {
        if (!self.checkpointEligible()) return error.AgentBusy;
        return checkpoint_codec.encode(alloc, self.history.items, self.turn_usage);
    }

    pub fn restoreCheckpoint(
        self: *Agent,
        alloc: Allocator,
        bytes: []const u8,
    ) (checkpoint_codec.Error || error{AgentNotFresh})!void {
        if (!self.checkpointEligible() or
            self.lifecycle.last_generation != 0 or
            self.history.items.len != 0)
        {
            return error.AgentNotFresh;
        }
        var decoded = try checkpoint_codec.decode(alloc, bytes);
        defer decoded.deinit(alloc);
        var previous = self.history;
        self.history = .fromOwnedSlice(decoded.history);
        decoded.history = &.{};
        for (previous.items) |turn| types.freeHistoryTurn(alloc, turn);
        previous.deinit(alloc);
        self.turn_usage = decoded.usage;
    }

    pub fn observeUsage(self: *Agent, usage: types.Usage) void {
        addOptional(&self.turn_usage.input_tokens, usage.input_tokens);
        addOptional(&self.turn_usage.output_tokens, usage.output_tokens);
        addOptional(&self.turn_usage.cache_read_tokens, usage.cache_read_tokens);
        addOptional(&self.turn_usage.cache_write_tokens, usage.cache_write_tokens);
        addOptional(&self.turn_usage.reasoning_tokens, usage.reasoning_tokens);
    }

    pub fn appendHistoryEntry(
        self: *Agent,
        alloc: Allocator,
        turn: types.HistoryTurn,
    ) Allocator.Error!void {
        const copy = try types.dupeHistoryTurn(alloc, turn);
        errdefer types.freeHistoryTurn(alloc, copy);
        try self.history.append(alloc, copy);
    }

    pub fn clearHistory(self: *Agent, alloc: Allocator) void {
        for (self.history.items) |turn| types.freeHistoryTurn(alloc, turn);
        self.history.clearRetainingCapacity();
    }

    pub fn snapshotHistory(
        self: *const Agent,
        alloc: Allocator,
    ) Allocator.Error![]types.HistoryTurn {
        const copy = try alloc.alloc(types.HistoryTurn, self.history.items.len);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |turn| types.freeHistoryTurn(alloc, turn);
            alloc.free(copy);
        }
        for (self.history.items, 0..) |turn, index| {
            copy[index] = try types.dupeHistoryTurn(alloc, turn);
            copied += 1;
        }
        return copy;
    }

    pub fn restoreHistory(
        self: *Agent,
        alloc: Allocator,
        history: []const types.HistoryTurn,
    ) Allocator.Error!void {
        var replacement: std.ArrayList(types.HistoryTurn) = .empty;
        errdefer {
            for (replacement.items) |turn| types.freeHistoryTurn(alloc, turn);
            replacement.deinit(alloc);
        }
        try replacement.ensureTotalCapacity(alloc, history.len);
        for (history) |turn| {
            replacement.appendAssumeCapacity(try types.dupeHistoryTurn(alloc, turn));
        }

        var previous = self.history;
        self.history = replacement;
        for (previous.items) |turn| types.freeHistoryTurn(alloc, turn);
        previous.deinit(alloc);
    }
};

fn addOptional(total: *?u64, value: ?u64) void {
    const amount = value orelse return;
    total.* = std.math.add(u64, total.* orelse 0, amount) catch std.math.maxInt(u64);
}

test "Agent owns one lifecycle and rejects a concurrent prompt" {
    var agent: Agent = .{};
    try agent.beginPrompt(1);
    try std.testing.expect(agent.isBusy());
    try std.testing.expectError(error.AgentBusy, agent.beginPrompt(2));
    try agent.beginToolBatch(1, 2);
    try agent.settleToolBatch(1);
    try agent.finishPrompt(1, .completed);
    try std.testing.expect(agent.checkpointEligible());
    try agent.beginPrompt(2);
}

test "Agent allocates prompt generations independently from trace identity" {
    var agent: Agent = .{};
    const first = try agent.beginNextPrompt();
    try std.testing.expectEqual(@as(u64, 1), first);
    try agent.finishPrompt(first, .completed);
    const second = try agent.beginNextPrompt();
    try std.testing.expectEqual(@as(u64, 2), second);
    try agent.finishPrompt(second, .completed);
}

test "Agent cancellation and close are idempotent" {
    var agent: Agent = .{};
    try agent.beginPrompt(1);
    try std.testing.expectEqual(@as(?u64, 1), agent.cancel());
    try std.testing.expectEqual(@as(?u64, null), agent.cancel());
    try agent.finishPrompt(1, .cancelled);
    try std.testing.expectEqual(@as(?u64, null), agent.close());
    try std.testing.expect(agent.isClosed());
    try std.testing.expectEqual(@as(?u64, null), agent.close());
    try std.testing.expectError(error.AgentClosed, agent.beginPrompt(2));
}

test "Agent accumulates per-turn usage with saturation" {
    var agent: Agent = .{};
    try agent.beginPrompt(1);
    agent.observeUsage(.{ .input_tokens = 4, .output_tokens = 2 });
    agent.observeUsage(.{ .input_tokens = 3, .reasoning_tokens = 1 });
    try std.testing.expectEqual(@as(?u64, 7), agent.turn_usage.input_tokens);
    try std.testing.expectEqual(@as(?u64, 2), agent.turn_usage.output_tokens);
    try std.testing.expectEqual(@as(?u64, 1), agent.turn_usage.reasoning_tokens);

    agent.observeUsage(.{ .input_tokens = std.math.maxInt(u64) });
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        agent.turn_usage.input_tokens,
    );
}

test "Agent history restore is transactional" {
    const alloc = std.testing.allocator;
    var agent: Agent = .{};
    defer agent.deinit(alloc);

    try agent.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("old") },
        .assistant = @constCast("answer"),
    } });
    const replacement = [_]types.HistoryTurn{.{ .assistant = .{
        .user = .{ .text = @constCast("new") },
        .assistant = @constCast("response"),
    } }};
    var failing = std.testing.FailingAllocator.init(alloc, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        agent.restoreHistory(failing.allocator(), &replacement),
    );
    try std.testing.expectEqual(@as(usize, 1), agent.history.items.len);
    try std.testing.expectEqualStrings("old", agent.history.items[0].assistant.user.text);

    try agent.restoreHistory(alloc, &replacement);
    try std.testing.expectEqualStrings("new", agent.history.items[0].assistant.user.text);
}

test "Agent checkpoint restores only into a fresh idle owner" {
    const alloc = std.testing.allocator;
    var source: Agent = .{};
    defer source.deinit(alloc);
    try source.appendHistoryEntry(alloc, .{ .assistant = .{
        .user = .{ .text = @constCast("before") },
        .assistant = @constCast("after"),
    } });
    const bytes = try source.checkpoint(alloc);
    defer alloc.free(bytes);

    var restored: Agent = .{};
    defer restored.deinit(alloc);
    try restored.restoreCheckpoint(alloc, bytes);
    try std.testing.expectEqualStrings("before", restored.history.items[0].assistant.user.text);
    try std.testing.expectError(error.AgentNotFresh, restored.restoreCheckpoint(alloc, bytes));

    try source.beginPrompt(1);
    try std.testing.expectError(error.AgentBusy, source.checkpoint(alloc));
    try source.finishPrompt(1, .cancelled);
}
