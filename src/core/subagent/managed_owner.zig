const std = @import("std");
const approval_registry = @import("approval_registry.zig");
const authority = @import("authority.zig");
const child_state = @import("child_state.zig");
const domain = @import("domain.zig");
const execution = @import("execution.zig");
const io_mod = @import("../shared/io.zig");
const session_store = @import("../session/session_store.zig");

const Allocator = std.mem.Allocator;

pub const StartResult = enum { started, already_running };
pub const StartError = error{ OutOfMemory, OwnerClosed, ChildUnavailable, ThreadSpawnFailed };
pub const WaitError = error{ OutOfMemory, ChildUnavailable, StateUnavailable };
pub const CancelError = error{ChildUnavailable};

pub const Observation = struct {
    phase: child_state.Phase,
    outcome: ?child_state.Outcome = null,
};

const Slot = struct {
    owner: *Owner,
    child_id: []u8,
    cancel: std.atomic.Value(bool) = .init(false),
    shutdown: std.atomic.Value(bool) = .init(false),
    worker: ?*@import("../agent/worker_runtime.zig").WorkerRuntime = null,
    thread: ?std.Thread = null,
    finished: bool = false,
    done: std.Io.Event = .unset,
};

pub const Owner = struct {
    alloc: Allocator,
    sessions: *session_store.Store,
    state_store: child_state.Store,
    services: execution.Services,
    authority_resolver: *authority.Resolver,
    approvals: *approval_registry.Registry,
    max_history_turns: usize = 8,
    mutex: std.Io.Mutex = .init,
    slots: std.ArrayList(*Slot) = .empty,
    closed: bool = false,

    pub fn start(self: *Owner, child_id: []const u8) StartError!StartResult {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        if (self.closed) return error.OwnerClosed;
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
            if (!slot.finished) return .already_running;
            return .already_running;
        }
        const slot = try self.alloc.create(Slot);
        errdefer self.alloc.destroy(slot);
        slot.* = .{
            .owner = self,
            .child_id = try self.alloc.dupe(u8, child_id),
        };
        errdefer self.alloc.free(slot.child_id);
        try self.slots.append(self.alloc, slot);
        errdefer _ = self.slots.pop();
        slot.thread = std.Thread.spawn(.{}, slotMain, .{slot}) catch
            return error.ThreadSpawnFailed;
        return .started;
    }

    pub fn wait(
        self: *Owner,
        child_id: []const u8,
        duration: std.Io.Clock.Duration,
    ) WaitError!Observation {
        const slot = self.findSlot(child_id);
        if (slot) |active| {
            active.done.waitTimeout(io_mod.getIo(), .{ .duration = duration }) catch |err| switch (err) {
                error.Timeout => return self.observe(child_id),
                error.Canceled => return self.observe(child_id),
            };
            self.reapSlot(active);
        }
        return self.observe(child_id);
    }

    pub fn cancel(self: *Owner, child_id: []const u8) CancelError!void {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (!std.mem.eql(u8, slot.child_id, child_id)) continue;
            if (slot.finished) return;
            slot.cancel.store(true, .seq_cst);
            if (slot.worker) |worker| worker.requestCancel();
            return;
        }
        return error.ChildUnavailable;
    }

    pub fn recoverInterrupted(self: *Owner) !void {
        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const generation = registry.generation;
        registry.interruptActive(self.alloc);
        if (registry.generation != generation) try self.state_store.save(self.alloc, registry);
    }

    pub fn deinit(self: *Owner) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        self.closed = true;
        for (self.slots.items) |slot| {
            slot.shutdown.store(true, .seq_cst);
            slot.cancel.store(true, .seq_cst);
            if (slot.worker) |worker| worker.requestShutdown();
        }
        self.mutex.unlock(io_mod.getIo());

        for (self.slots.items) |slot| {
            if (slot.thread) |thread| thread.join();
            self.alloc.free(slot.child_id);
            self.alloc.destroy(slot);
        }
        self.slots.deinit(self.alloc);
        self.* = undefined;
    }

    fn findSlot(self: *Owner, child_id: []const u8) ?*Slot {
        self.mutex.lockUncancelable(io_mod.getIo());
        defer self.mutex.unlock(io_mod.getIo());
        for (self.slots.items) |slot| {
            if (std.mem.eql(u8, slot.child_id, child_id)) return slot;
        }
        return null;
    }

    fn reapSlot(self: *Owner, slot: *Slot) void {
        self.mutex.lockUncancelable(io_mod.getIo());
        var index: ?usize = null;
        for (self.slots.items, 0..) |candidate, candidate_index| {
            if (candidate == slot and candidate.finished) {
                index = candidate_index;
                break;
            }
        }
        if (index == null) {
            self.mutex.unlock(io_mod.getIo());
            return;
        }
        _ = self.slots.swapRemove(index.?);
        self.mutex.unlock(io_mod.getIo());
        if (slot.thread) |thread| thread.join();
        self.alloc.free(slot.child_id);
        self.alloc.destroy(slot);
    }

    fn observe(self: *Owner, child_id: []const u8) WaitError!Observation {
        var lock = self.state_store.acquireLock(self.alloc) catch
            return error.StateUnavailable;
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.StateUnavailable,
        };
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        return .{ .phase = child.phase, .outcome = child.last_outcome };
    }

    fn phaseTransition(
        raw: *anyopaque,
        child_id: []const u8,
        work_id: []const u8,
        phase: child_state.Phase,
    ) !void {
        const self: *Owner = @ptrCast(@alignCast(raw));
        var lock = try self.state_store.acquireLock(self.alloc);
        defer lock.release();
        var registry = try self.state_store.load(self.alloc);
        defer registry.deinit(self.alloc);
        const child = registry.findById(child_id) orelse return error.ChildUnavailable;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        child.phase = phase;
        registry.generation +|= 1;
        try self.state_store.save(self.alloc, registry);
    }

    fn finish(
        self: *Owner,
        child_id: []const u8,
        work_id: []const u8,
        outcome: child_state.Outcome,
    ) void {
        var lock = self.state_store.acquireLock(self.alloc) catch |err| {
            debugFailure(child_id, "state_lock", err);
            return;
        };
        defer lock.release();
        var registry = self.state_store.load(self.alloc) catch |err| {
            debugFailure(child_id, "state_load", err);
            return;
        };
        defer registry.deinit(self.alloc);
        registry.finish(self.alloc, child_id, work_id, outcome) catch |err| {
            debugFailure(child_id, "state_finish", err);
            return;
        };
        self.state_store.save(self.alloc, registry) catch |err| {
            debugFailure(child_id, "state_save", err);
        };
    }
};

fn slotMain(slot: *Slot) void {
    const owner = slot.owner;
    const outcome = runOne(slot);
    owner.finish(slot.child_id, outcome.work_id, outcome.outcome);
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.worker = null;
    slot.finished = true;
    slot.done.set(io_mod.getIo());
    owner.mutex.unlock(io_mod.getIo());
    outcome.deinit(owner.alloc);
}

const OneOutcome = struct {
    work_id: []u8,
    outcome: child_state.Outcome,

    fn deinit(self: OneOutcome, alloc: Allocator) void {
        alloc.free(self.work_id);
    }
};

fn runOne(slot: *Slot) OneOutcome {
    const owner = slot.owner;
    var snapshot = loadRunSnapshot(owner, slot.child_id) catch {
        return fallbackOutcome(owner.alloc, "unknown", .failed);
    };
    defer snapshot.deinit(owner.alloc);
    const work_id = owner.alloc.dupe(u8, snapshot.active.id) catch
        return fallbackOutcome(owner.alloc, "unknown", .failed);

    var loaded = owner.sessions.resumeTargetForWrite(
        owner.alloc,
        .{ .id = slot.child_id },
        owner.sessions.workspace_root,
        .{},
    ) catch return .{ .work_id = work_id, .outcome = .failed };
    defer {
        loaded.log.park();
        loaded.deinit(owner.alloc);
    }
    var turn = execution.TurnContext.init(
        owner.alloc,
        &loaded,
        owner.max_history_turns,
    ) catch return .{ .work_id = work_id, .outcome = .failed };
    defer turn.deinit();
    turn.live_authority = owner.authority_resolver;
    turn.approval_registry = owner.approvals;
    turn.child_id = slot.child_id;
    turn.active_work_id = snapshot.active.id;
    turn.phase_context = owner;
    turn.phase_fn = Owner.phaseTransition;
    owner.mutex.lockUncancelable(io_mod.getIo());
    slot.worker = turn.workerRuntime();
    owner.mutex.unlock(io_mod.getIo());

    var message = snapshot.active.queuedMessage(
        owner.alloc,
        owner.state_store.parent_id,
        snapshot.instructions,
    ) catch
        return .{ .work_id = work_id, .outcome = .failed };
    defer message.deinit(owner.alloc);
    const admission = owner.services.capture(owner.alloc, .{
        .child_id = slot.child_id,
        .parent_id = owner.state_store.parent_id,
        .source_id = owner.state_store.parent_id,
        .preferences = .{
            .provider = loaded.state.preferences.provider,
            .model = loaded.state.preferences.model,
            .effort = loaded.state.preferences.effort,
        },
    }) catch |err| return .{
        .work_id = work_id,
        .outcome = if (err == error.Cancelled) .cancelled else .failed,
    };
    var owned_admission = admission;
    defer owned_admission.deinit(owner.alloc);
    const result = owner.services.run(
        &turn,
        message,
        admission,
        &slot.cancel,
    ) catch |err| return .{
        .work_id = work_id,
        .outcome = if (slot.shutdown.load(.seq_cst))
            .interrupted
        else if (slot.cancel.load(.seq_cst) or err == error.Cancelled)
            .cancelled
        else
            .failed,
    };
    if (slot.shutdown.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .interrupted,
    };
    if (slot.cancel.load(.seq_cst)) return .{
        .work_id = work_id,
        .outcome = .cancelled,
    };
    return .{
        .work_id = work_id,
        .outcome = switch (result) {
            .completed => .completed,
            .awaiting_approval, .paused => .interrupted,
        },
    };
}

const RunSnapshot = struct {
    active: child_state.ActiveWork,
    instructions: []u8,

    fn deinit(self: *RunSnapshot, alloc: Allocator) void {
        self.active.deinit(alloc);
        if (self.instructions.len > 0) alloc.free(self.instructions);
        self.* = undefined;
    }
};

fn loadRunSnapshot(owner: *Owner, child_id: []const u8) !RunSnapshot {
    var lock = try owner.state_store.acquireLock(owner.alloc);
    defer lock.release();
    var registry = try owner.state_store.load(owner.alloc);
    defer registry.deinit(owner.alloc);
    const child = registry.findById(child_id) orelse return error.ChildUnavailable;
    const active = child.active orelse return error.ChildUnavailable;
    const owned_active = try active.clone(owner.alloc);
    errdefer {
        var value = owned_active;
        value.deinit(owner.alloc);
    }
    const instructions: []u8 = if (child.instructions().len == 0)
        &.{}
    else
        try owner.alloc.dupe(u8, child.instructions());
    return .{
        .active = owned_active,
        .instructions = instructions,
    };
}

fn fallbackOutcome(alloc: Allocator, work_id: []const u8, outcome: child_state.Outcome) OneOutcome {
    return .{
        .work_id = alloc.dupe(u8, work_id) catch &.{},
        .outcome = outcome,
    };
}

fn debugFailure(child_id: []const u8, stage: []const u8, err: anyerror) void {
    @import("../shared/debug_trace.zig").logf(
        "subagent",
        "managed child state update failed child_id={s} stage={s} err={s}",
        .{ child_id, stage, @errorName(err) },
    );
}
