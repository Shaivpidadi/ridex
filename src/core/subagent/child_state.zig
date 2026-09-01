const std = @import("std");
const agent_config = @import("agent_config.zig");
const domain = @import("domain.zig");
const io_mod = @import("../shared/io.zig");
const session_child_store = @import("../session/session_child_store.zig");
const session_store = @import("../session/session_store.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;
const schema_version: u64 = 1;
const state_file = "children.json";
const lock_file = "children.lock";
const owner_marker_file = "owner.json";
const legacy_control_file = "control.json";
const lock_deadline_ms: u64 = 2_000;
const max_state_bytes: usize = 512 * 1024;
pub const max_children: usize = 256;

pub const Kind = enum { one_off, persistent };
pub const Phase = enum { idle, running, awaiting_approval, interrupted, finished };
pub const Outcome = enum { completed, failed, cancelled, interrupted };

pub const DefinitionSnapshot = struct {
    agent: []u8,
    instructions: []u8,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,

    pub fn deinit(self: *DefinitionSnapshot, alloc: Allocator) void {
        alloc.free(self.agent);
        alloc.free(self.instructions);
        if (self.model) |model| alloc.free(model);
        self.* = undefined;
    }

    pub fn clone(self: DefinitionSnapshot, alloc: Allocator) !DefinitionSnapshot {
        const agent = try alloc.dupe(u8, self.agent);
        errdefer alloc.free(agent);
        const instructions = try alloc.dupe(u8, self.instructions);
        errdefer alloc.free(instructions);
        return .{
            .agent = agent,
            .instructions = instructions,
            .model = if (self.model) |model| try alloc.dupe(u8, model) else null,
            .effort = self.effort,
        };
    }
};

pub const ActiveWork = struct {
    id: []u8,
    request_fingerprint: [32]u8 = [_]u8{0} ** 32,
    message: []u8,
    root_user_intent_context: []u8 = &.{},
    root_user_messages: [][]u8 = &.{},
    root_user_evidence_complete: bool = false,
    permission_mode: types.PermissionMode = .yolo,
    created_at_ms: i64,

    pub fn deinit(self: *ActiveWork, alloc: Allocator) void {
        alloc.free(self.id);
        alloc.free(self.message);
        if (self.root_user_intent_context.len > 0) {
            alloc.free(self.root_user_intent_context);
        }
        freeStrings(alloc, self.root_user_messages);
        self.* = undefined;
    }

    pub fn clone(self: ActiveWork, alloc: Allocator) !ActiveWork {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        const message = try alloc.dupe(u8, self.message);
        errdefer alloc.free(message);
        const context = try alloc.dupe(u8, self.root_user_intent_context);
        errdefer alloc.free(context);
        return .{
            .id = id,
            .request_fingerprint = self.request_fingerprint,
            .message = message,
            .root_user_intent_context = context,
            .root_user_messages = try cloneStrings(alloc, self.root_user_messages),
            .root_user_evidence_complete = self.root_user_evidence_complete,
            .permission_mode = self.permission_mode,
            .created_at_ms = self.created_at_ms,
        };
    }

    pub fn queuedMessage(self: ActiveWork, alloc: Allocator, parent_id: []const u8) !domain.QueuedMessage {
        return .{
            .id = try alloc.dupe(u8, self.id),
            .source_id = try alloc.dupe(u8, parent_id),
            .content = try alloc.dupe(u8, self.message),
            .root_user_intent_context = try alloc.dupe(u8, self.root_user_intent_context),
            .root_user_messages = try cloneStrings(alloc, self.root_user_messages),
            .root_user_evidence_complete = self.root_user_evidence_complete,
            .created_at_ms = self.created_at_ms,
        };
    }
};

pub const Child = struct {
    id: []u8,
    kind: Kind,
    definition: ?DefinitionSnapshot = null,
    phase: Phase,
    work_generation: u64 = 0,
    active: ?ActiveWork = null,
    last_work_id: ?[]u8 = null,
    last_request_fingerprint: ?[32]u8 = null,
    last_outcome: ?Outcome = null,

    pub fn deinit(self: *Child, alloc: Allocator) void {
        alloc.free(self.id);
        if (self.definition) |*definition| definition.deinit(alloc);
        if (self.active) |*active| active.deinit(alloc);
        if (self.last_work_id) |id| alloc.free(id);
        self.* = undefined;
    }

    fn clone(self: Child, alloc: Allocator) !Child {
        const id = try alloc.dupe(u8, self.id);
        errdefer alloc.free(id);
        var definition = if (self.definition) |value| try value.clone(alloc) else null;
        errdefer if (definition) |*value| value.deinit(alloc);
        var active = if (self.active) |value| try value.clone(alloc) else null;
        errdefer if (active) |*value| value.deinit(alloc);
        return .{
            .id = id,
            .kind = self.kind,
            .definition = definition,
            .phase = self.phase,
            .work_generation = self.work_generation,
            .active = active,
            .last_work_id = if (self.last_work_id) |value| try alloc.dupe(u8, value) else null,
            .last_request_fingerprint = self.last_request_fingerprint,
            .last_outcome = self.last_outcome,
        };
    }

    pub fn agentName(self: Child) ?[]const u8 {
        return if (self.definition) |definition| definition.agent else null;
    }
};

pub const Registry = struct {
    parent_id: []u8,
    generation: u64 = 0,
    children: []Child = &.{},

    pub fn init(alloc: Allocator, parent_id: []const u8) !Registry {
        domain.validateId(parent_id) catch return error.InvalidParentId;
        return .{ .parent_id = try alloc.dupe(u8, parent_id) };
    }

    pub fn deinit(self: *Registry, alloc: Allocator) void {
        alloc.free(self.parent_id);
        for (self.children) |*child| child.deinit(alloc);
        if (self.children.len > 0) alloc.free(self.children);
        self.* = undefined;
    }

    pub fn clone(self: Registry, alloc: Allocator) !Registry {
        const parent_id = try alloc.dupe(u8, self.parent_id);
        errdefer alloc.free(parent_id);
        const children = try alloc.alloc(Child, self.children.len);
        var built: usize = 0;
        errdefer {
            for (children[0..built]) |*child| child.deinit(alloc);
            alloc.free(children);
        }
        for (self.children) |child| {
            children[built] = try child.clone(alloc);
            built += 1;
        }
        return .{
            .parent_id = parent_id,
            .generation = self.generation,
            .children = children,
        };
    }

    pub fn findById(self: *Registry, child_id: []const u8) ?*Child {
        for (self.children) |*child| {
            if (std.mem.eql(u8, child.id, child_id)) return child;
        }
        return null;
    }

    pub fn findPersistent(self: *Registry, agent: []const u8) ?*Child {
        for (self.children) |*child| {
            if (child.kind != .persistent) continue;
            if (child.agentName()) |name| {
                if (std.mem.eql(u8, name, agent)) return child;
            }
        }
        return null;
    }

    pub fn findByOperation(
        self: *Registry,
        operation_id: []const u8,
    ) ?*Child {
        for (self.children) |*child| {
            if (child.active) |active| {
                if (std.mem.eql(u8, active.id, operation_id)) return child;
            }
            if (child.last_work_id) |work_id| {
                if (std.mem.eql(u8, work_id, operation_id)) return child;
            }
        }
        return null;
    }

    pub fn operationFingerprint(child: Child, operation_id: []const u8) ?[32]u8 {
        if (child.active) |active| {
            if (std.mem.eql(u8, active.id, operation_id)) {
                return active.request_fingerprint;
            }
        }
        if (child.last_work_id) |work_id| {
            if (std.mem.eql(u8, work_id, operation_id)) {
                return child.last_request_fingerprint;
            }
        }
        return null;
    }

    pub fn appendOneOff(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
        active: ActiveWork,
    ) !void {
        try self.appendChild(alloc, .{
            .id = try alloc.dupe(u8, child_id),
            .kind = .one_off,
            .phase = .running,
            .work_generation = 1,
            .active = try active.clone(alloc),
        });
    }

    pub fn appendPersistent(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
        definition: agent_config.Definition,
        active: ActiveWork,
    ) !void {
        if (self.findPersistent(definition.name) != null) return error.AgentAlreadyExists;
        var snapshot = DefinitionSnapshot{
            .agent = try alloc.dupe(u8, definition.name),
            .instructions = try alloc.dupe(u8, definition.instructions),
            .model = if (definition.model) |model| try alloc.dupe(u8, model) else null,
            .effort = definition.effort,
        };
        errdefer snapshot.deinit(alloc);
        try self.appendChild(alloc, .{
            .id = try alloc.dupe(u8, child_id),
            .kind = .persistent,
            .definition = snapshot,
            .phase = .running,
            .work_generation = 1,
            .active = try active.clone(alloc),
        });
    }

    fn appendChild(self: *Registry, alloc: Allocator, child: Child) !void {
        if (self.children.len >= max_children) return error.CapacityExceeded;
        if (self.findById(child.id) != null) return error.ChildAlreadyExists;
        const next = try alloc.alloc(Child, self.children.len + 1);
        @memcpy(next[0..self.children.len], self.children);
        next[self.children.len] = child;
        if (self.children.len > 0) alloc.free(self.children);
        self.children = next;
        self.generation +|= 1;
    }

    pub fn startPersistentWork(
        self: *Registry,
        alloc: Allocator,
        agent: []const u8,
        active: ActiveWork,
    ) !*Child {
        const child = self.findPersistent(agent) orelse return error.ChildNotFound;
        switch (child.phase) {
            .idle, .interrupted => {},
            .running, .awaiting_approval => return error.ChildBusy,
            .finished => return error.ChildNotFound,
        }
        if (child.active) |*old| old.deinit(alloc);
        child.active = try active.clone(alloc);
        child.phase = .running;
        child.work_generation +|= 1;
        self.generation +|= 1;
        return child;
    }

    pub fn finish(
        self: *Registry,
        alloc: Allocator,
        child_id: []const u8,
        work_id: []const u8,
        outcome: Outcome,
    ) !void {
        const child = self.findById(child_id) orelse return error.ChildNotFound;
        const active = child.active orelse return error.StaleWork;
        if (!std.mem.eql(u8, active.id, work_id)) return error.StaleWork;
        if (child.last_work_id) |old| alloc.free(old);
        child.last_work_id = try alloc.dupe(u8, work_id);
        child.last_request_fingerprint = active.request_fingerprint;
        child.last_outcome = outcome;
        child.active.?.deinit(alloc);
        child.active = null;
        child.phase = if (child.kind == .persistent) .idle else .finished;
        self.generation +|= 1;
    }

    pub fn interruptActive(self: *Registry, alloc: Allocator) void {
        var changed = false;
        for (self.children) |*child| {
            if (child.phase != .running and child.phase != .awaiting_approval) continue;
            if (child.active) |active| {
                if (child.last_work_id) |old| alloc.free(old);
                child.last_work_id = alloc.dupe(u8, active.id) catch null;
                child.last_outcome = .interrupted;
            }
            child.phase = .interrupted;
            changed = true;
        }
        if (changed) self.generation +|= 1;
    }
};

pub const Store = struct {
    sessions: *session_store.Store,
    parent_id: []const u8,
    options: session_child_store.Options = .{},

    pub fn acquireLock(self: Store, alloc: Allocator) !io_mod.TimedAdvisoryLock {
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.parent_id,
            self.options,
        );
        defer capability.deinit();
        return capability.acquireTimedAdvisoryLock(
            .subagent_control,
            lock_file,
            lock_deadline_ms,
        );
    }

    pub fn load(self: Store, alloc: Allocator) !Registry {
        var capability = try self.sessions.openSubagentControlCapabilityReadOnly(
            alloc,
            self.parent_id,
            self.options,
        );
        defer capability.deinit();
        var file = capability.openFileReadOnly(
            alloc,
            .subagent_control,
            state_file,
        ) catch |err| {
            if (err == error.FileNotFound) return Registry.init(alloc, self.parent_id);
            return err;
        };
        defer file.deinit();
        const bytes = try file.readToEnd(alloc, max_state_bytes);
        defer alloc.free(bytes);
        return parseRegistry(alloc, bytes, self.parent_id);
    }

    pub fn save(self: Store, alloc: Allocator, registry: Registry) !void {
        if (!std.mem.eql(u8, registry.parent_id, self.parent_id)) {
            return error.InvalidParentId;
        }
        const bytes = try renderRegistry(alloc, registry);
        defer alloc.free(bytes);
        if (bytes.len > max_state_bytes) return error.StateTooLarge;
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            self.parent_id,
            self.options,
        );
        defer capability.deinit();
        var entry = try capability.atomicReplace(
            alloc,
            .subagent_control,
            state_file,
            bytes,
        );
        entry.deinit(alloc);
    }

    pub fn markChildSession(
        self: Store,
        alloc: Allocator,
        child_id: []const u8,
    ) !void {
        var bytes: std.Io.Writer.Allocating = .init(alloc);
        defer bytes.deinit();
        try bytes.writer.writeAll("{\"schema_version\":1,\"parent_id\":");
        try std.json.Stringify.value(self.parent_id, .{}, &bytes.writer);
        try bytes.writer.writeAll("}");
        var capability = try self.sessions.openSubagentControlCapabilityWritable(
            alloc,
            child_id,
            self.options,
        );
        defer capability.deinit();
        var entry = try capability.atomicReplace(
            alloc,
            .subagent_control,
            owner_marker_file,
            bytes.written(),
        );
        entry.deinit(alloc);
    }
};

/// Returns true for both the current immutable owner marker and legacy child
/// control records. Any unreadable marker fails closed so a child cannot
/// become externally resumable because its private metadata is damaged.
pub fn isManagedChildSession(
    sessions: session_store.Store,
    alloc: Allocator,
    session_id: []const u8,
) !bool {
    var capability = sessions.openSubagentControlCapabilityReadOnly(
        alloc,
        session_id,
        .{},
    ) catch |err| return switch (err) {
        error.SessionNotFound => false,
        else => err,
    };
    defer capability.deinit();
    var owner = capability.openFileReadOnly(
        alloc,
        .subagent_control,
        owner_marker_file,
    ) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (owner) |*file| {
        file.deinit();
        return true;
    }

    var legacy = capability.openFileReadOnly(
        alloc,
        .subagent_control,
        legacy_control_file,
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer legacy.deinit();
    const bytes = try legacy.readToEnd(alloc, max_state_bytes);
    defer alloc.free(bytes);
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidState;
    const parent = parsed.value.object.get("parent_id") orelse return false;
    return parent == .string;
}

fn renderRegistry(alloc: Allocator, registry: Registry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.print("{{\"schema_version\":{d},\"parent_id\":", .{schema_version});
    try std.json.Stringify.value(registry.parent_id, .{}, writer);
    try writer.print(",\"generation\":{d},\"children\":[", .{registry.generation});
    for (registry.children, 0..) |child, index| {
        if (index != 0) try writer.writeByte(',');
        try renderChild(writer, child);
    }
    try writer.writeAll("]}");
    return out.toOwnedSlice();
}

fn renderChild(writer: *std.Io.Writer, child: Child) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(child.id, .{}, writer);
    try writer.writeAll(",\"kind\":");
    try std.json.Stringify.value(@tagName(child.kind), .{}, writer);
    try writer.writeAll(",\"definition\":");
    if (child.definition) |definition| {
        try writer.writeAll("{\"agent\":");
        try std.json.Stringify.value(definition.agent, .{}, writer);
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(definition.instructions, .{}, writer);
        try writer.writeAll(",\"model\":");
        try writeOptionalString(writer, definition.model);
        try writer.writeAll(",\"effort\":");
        try writeOptionalString(writer, if (definition.effort) |*effort| effort.label() else null);
        try writer.writeByte('}');
    } else try writer.writeAll("null");
    try writer.writeAll(",\"phase\":");
    try std.json.Stringify.value(@tagName(child.phase), .{}, writer);
    try writer.print(",\"work_generation\":{d},\"active\":", .{child.work_generation});
    if (child.active) |active| try renderActive(writer, active) else try writer.writeAll("null");
    try writer.writeAll(",\"last_work_id\":");
    try writeOptionalString(writer, child.last_work_id);
    try writer.writeAll(",\"last_request_fingerprint\":");
    if (child.last_request_fingerprint) |fingerprint| {
        const fingerprint_hex = std.fmt.bytesToHex(fingerprint, .lower);
        try std.json.Stringify.value(&fingerprint_hex, .{}, writer);
    } else try writer.writeAll("null");
    try writer.writeAll(",\"last_outcome\":");
    try writeOptionalString(writer, if (child.last_outcome) |outcome| @tagName(outcome) else null);
    try writer.writeByte('}');
}

fn renderActive(writer: *std.Io.Writer, active: ActiveWork) !void {
    try writer.writeAll("{\"id\":");
    try std.json.Stringify.value(active.id, .{}, writer);
    try writer.writeAll(",\"request_fingerprint\":\"");
    const fingerprint_hex = std.fmt.bytesToHex(active.request_fingerprint, .lower);
    try writer.writeAll(&fingerprint_hex);
    try writer.writeByte('"');
    try writer.writeAll(",\"message\":");
    try std.json.Stringify.value(active.message, .{}, writer);
    try writer.writeAll(",\"root_user_intent_context\":");
    try std.json.Stringify.value(active.root_user_intent_context, .{}, writer);
    try writer.writeAll(",\"root_user_messages\":[");
    for (active.root_user_messages, 0..) |message, index| {
        if (index != 0) try writer.writeByte(',');
        try std.json.Stringify.value(message, .{}, writer);
    }
    try writer.print(
        "],\"root_user_evidence_complete\":{},\"permission_mode\":\"{s}\",\"created_at_ms\":{d}}}",
        .{ active.root_user_evidence_complete, @tagName(active.permission_mode), active.created_at_ms },
    );
}

fn parseRegistry(alloc: Allocator, bytes: []const u8, parent_id: []const u8) !Registry {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    const root = try object(parsed.value);
    try exactFields(root, &.{ "schema_version", "parent_id", "generation", "children" });
    if (try unsigned(root, "schema_version") != schema_version) return error.UnsupportedSchema;
    const stored_parent = try string(root, "parent_id");
    if (!std.mem.eql(u8, stored_parent, parent_id)) return error.InvalidParentId;
    const values = root.get("children") orelse return error.InvalidState;
    if (values != .array or values.array.items.len > max_children) return error.InvalidState;
    var registry = try Registry.init(alloc, parent_id);
    errdefer registry.deinit(alloc);
    registry.generation = try unsigned(root, "generation");
    const children = try alloc.alloc(Child, values.array.items.len);
    var built: usize = 0;
    errdefer {
        for (children[0..built]) |*child| child.deinit(alloc);
        alloc.free(children);
    }
    for (values.array.items) |value| {
        children[built] = try parseChild(alloc, value);
        built += 1;
    }
    registry.children = children;
    try validateRegistry(registry);
    return registry;
}

fn parseChild(alloc: Allocator, value: std.json.Value) !Child {
    const source = try object(value);
    try exactFields(source, &.{ "id", "kind", "definition", "phase", "work_generation", "active", "last_work_id", "last_request_fingerprint", "last_outcome" });
    const id_value = try string(source, "id");
    domain.validateId(id_value) catch return error.InvalidState;
    const kind = std.meta.stringToEnum(Kind, try string(source, "kind")) orelse return error.InvalidState;
    const phase = std.meta.stringToEnum(Phase, try string(source, "phase")) orelse return error.InvalidState;
    var definition = if (source.get("definition")) |definition_value|
        if (definition_value == .null) null else try parseDefinition(alloc, definition_value)
    else
        return error.InvalidState;
    errdefer if (definition) |*item| item.deinit(alloc);
    var active = if (source.get("active")) |active_value|
        if (active_value == .null) null else try parseActive(alloc, active_value)
    else
        return error.InvalidState;
    errdefer if (active) |*item| item.deinit(alloc);
    return .{
        .id = try alloc.dupe(u8, id_value),
        .kind = kind,
        .definition = definition,
        .phase = phase,
        .work_generation = try unsigned(source, "work_generation"),
        .active = active,
        .last_work_id = try optionalStringAlloc(alloc, source, "last_work_id"),
        .last_request_fingerprint = if (try optionalString(source, "last_request_fingerprint")) |raw|
            try parseFingerprint(raw)
        else
            null,
        .last_outcome = if (try optionalString(source, "last_outcome")) |raw|
            std.meta.stringToEnum(Outcome, raw) orelse return error.InvalidState
        else
            null,
    };
}

fn parseDefinition(alloc: Allocator, value: std.json.Value) !DefinitionSnapshot {
    const source = try object(value);
    try exactFields(source, &.{ "agent", "instructions", "model", "effort" });
    const agent = try string(source, "agent");
    if (!agent_config.validName(agent)) return error.InvalidState;
    const instructions = try string(source, "instructions");
    if (instructions.len == 0 or instructions.len > agent_config.max_instructions_bytes) return error.InvalidState;
    return .{
        .agent = try alloc.dupe(u8, agent),
        .instructions = try alloc.dupe(u8, instructions),
        .model = try optionalStringAlloc(alloc, source, "model"),
        .effort = if (try optionalString(source, "effort")) |raw|
            types.ReasoningEffort.parse(raw) orelse return error.InvalidState
        else
            null,
    };
}

fn parseActive(alloc: Allocator, value: std.json.Value) !ActiveWork {
    const source = try object(value);
    try exactFields(source, &.{ "id", "request_fingerprint", "message", "root_user_intent_context", "root_user_messages", "root_user_evidence_complete", "permission_mode", "created_at_ms" });
    const messages_value = source.get("root_user_messages") orelse return error.InvalidState;
    if (messages_value != .array or messages_value.array.items.len > domain.max_admission_items) return error.InvalidState;
    const messages = try alloc.alloc([]u8, messages_value.array.items.len);
    var built: usize = 0;
    errdefer {
        for (messages[0..built]) |message| alloc.free(message);
        alloc.free(messages);
    }
    for (messages_value.array.items) |message| {
        if (message != .string) return error.InvalidState;
        messages[built] = try alloc.dupe(u8, message.string);
        built += 1;
    }
    const evidence = source.get("root_user_evidence_complete") orelse return error.InvalidState;
    if (evidence != .bool) return error.InvalidState;
    const created = source.get("created_at_ms") orelse return error.InvalidState;
    if (created != .integer) return error.InvalidState;
    return .{
        .id = try alloc.dupe(u8, try string(source, "id")),
        .request_fingerprint = try parseFingerprint(try string(source, "request_fingerprint")),
        .message = try alloc.dupe(u8, try string(source, "message")),
        .root_user_intent_context = try alloc.dupe(u8, try string(source, "root_user_intent_context")),
        .root_user_messages = messages,
        .root_user_evidence_complete = evidence.bool,
        .permission_mode = std.meta.stringToEnum(
            types.PermissionMode,
            try string(source, "permission_mode"),
        ) orelse return error.InvalidState,
        .created_at_ms = created.integer,
    };
}

fn validateRegistry(registry: Registry) !void {
    for (registry.children, 0..) |child, index| {
        if ((child.kind == .persistent) != (child.definition != null)) return error.InvalidState;
        if ((child.phase == .running or child.phase == .awaiting_approval) != (child.active != null)) return error.InvalidState;
        for (registry.children[0..index]) |prior| {
            if (std.mem.eql(u8, prior.id, child.id)) return error.InvalidState;
            if (child.agentName()) |agent| {
                if (prior.agentName()) |prior_agent| {
                    if (std.mem.eql(u8, prior_agent, agent)) return error.InvalidState;
                }
            }
        }
    }
}

fn object(value: std.json.Value) !std.json.ObjectMap {
    return if (value == .object) value.object else error.InvalidState;
}

fn exactFields(source: std.json.ObjectMap, allowed: []const []const u8) !void {
    var iterator = source.iterator();
    while (iterator.next()) |entry| {
        for (allowed) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) break;
        } else return error.InvalidState;
    }
    if (source.count() != allowed.len) return error.InvalidState;
}

fn string(source: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const value = source.get(name) orelse return error.InvalidState;
    return if (value == .string) value.string else error.InvalidState;
}

fn optionalString(source: std.json.ObjectMap, name: []const u8) !?[]const u8 {
    const value = source.get(name) orelse return error.InvalidState;
    return switch (value) {
        .null => null,
        .string => value.string,
        else => error.InvalidState,
    };
}

fn optionalStringAlloc(alloc: Allocator, source: std.json.ObjectMap, name: []const u8) !?[]u8 {
    return if (try optionalString(source, name)) |value| try alloc.dupe(u8, value) else null;
}

fn unsigned(source: std.json.ObjectMap, name: []const u8) !u64 {
    const value = source.get(name) orelse return error.InvalidState;
    if (value != .integer or value.integer < 0) return error.InvalidState;
    return @intCast(value.integer);
}

fn parseFingerprint(raw: []const u8) ![32]u8 {
    if (raw.len != 64) return error.InvalidState;
    var result: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&result, raw) catch return error.InvalidState;
    return result;
}

fn writeOptionalString(writer: *std.Io.Writer, value: ?[]const u8) !void {
    if (value) |text| try std.json.Stringify.value(text, .{}, writer) else try writer.writeAll("null");
}

fn cloneStrings(alloc: Allocator, source: []const []u8) ![][]u8 {
    const result = try alloc.alloc([]u8, source.len);
    var built: usize = 0;
    errdefer {
        for (result[0..built]) |value| alloc.free(value);
        alloc.free(result);
    }
    for (source) |value| {
        result[built] = try alloc.dupe(u8, value);
        built += 1;
    }
    return result;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    if (values.len > 0) alloc.free(values);
}

test "parent child state round trips only required delegation state" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "01J00000000000000000000000");
    defer registry.deinit(alloc);
    var active = ActiveWork{
        .id = try alloc.dupe(u8, "work-1"),
        .message = try alloc.dupe(u8, "review this"),
        .created_at_ms = 1,
    };
    defer active.deinit(alloc);
    var definition = try agent_config.parseDefinition(alloc, "reviewer",
        \\{"description":"Reviews.","instructions":"Review carefully."}
    );
    defer definition.deinit(alloc);
    try registry.appendPersistent(
        alloc,
        "01J00000000000000000000001",
        definition,
        active,
    );
    const encoded = try renderRegistry(alloc, registry);
    defer alloc.free(encoded);
    try std.testing.expect(std.mem.find(u8, encoded, "relationship") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "notification") == null);
    try std.testing.expect(std.mem.find(u8, encoded, "cursor") == null);
    var decoded = try parseRegistry(alloc, encoded, registry.parent_id);
    defer decoded.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 1), decoded.children.len);
    try std.testing.expectEqualStrings("reviewer", decoded.children[0].agentName().?);
    try std.testing.expectEqual(Phase.running, decoded.children[0].phase);
}

test "persistent state derives create continue busy and terminal transitions" {
    const alloc = std.testing.allocator;
    var registry = try Registry.init(alloc, "01J00000000000000000000000");
    defer registry.deinit(alloc);
    var first = ActiveWork{
        .id = try alloc.dupe(u8, "work-1"),
        .message = try alloc.dupe(u8, "first"),
        .created_at_ms = 1,
    };
    defer first.deinit(alloc);
    var definition = try agent_config.parseDefinition(alloc, "reviewer",
        \\{"description":"Reviews.","instructions":"Review carefully."}
    );
    defer definition.deinit(alloc);
    try registry.appendPersistent(alloc, "01J00000000000000000000001", definition, first);
    try std.testing.expectError(
        error.ChildBusy,
        registry.startPersistentWork(alloc, "reviewer", first),
    );
    try registry.finish(alloc, registry.children[0].id, "work-1", .completed);
    var second = ActiveWork{
        .id = try alloc.dupe(u8, "work-2"),
        .message = try alloc.dupe(u8, "second"),
        .created_at_ms = 2,
    };
    defer second.deinit(alloc);
    const child = try registry.startPersistentWork(alloc, "reviewer", second);
    try std.testing.expectEqual(Phase.running, child.phase);
    try std.testing.expectEqual(@as(u64, 2), child.work_generation);
}
