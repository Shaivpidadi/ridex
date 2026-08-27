const std = @import("std");
const change_tracker = @import("../../core/workspace/change_tracker.zig");
const io_mod = @import("../../core/shared/io.zig");
const pathing = @import("../../core/workspace/pathing.zig");
const permissions = @import("../../core/permissions/permissions.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");

const Allocator = std.mem.Allocator;
const max_patch_bytes: usize = 4 * 1024 * 1024;
const max_file_bytes: usize = 4 * 1024 * 1024;
const max_operations: usize = 64;
const max_hunks: usize = 256;

const Hunk = struct {
    old_text: []u8,
    new_text: []u8,

    fn deinit(self: *Hunk, alloc: Allocator) void {
        alloc.free(self.old_text);
        alloc.free(self.new_text);
        self.* = undefined;
    }
};

const Update = struct {
    path: []u8,
    move_to: ?[]u8 = null,
    hunks: []Hunk,
    anchor_eof: bool = false,

    fn deinit(self: *Update, alloc: Allocator) void {
        alloc.free(self.path);
        if (self.move_to) |move_to| alloc.free(move_to);
        for (self.hunks) |*hunk| hunk.deinit(alloc);
        alloc.free(self.hunks);
        self.* = undefined;
    }
};

const Add = struct {
    path: []u8,
    content: []u8,

    fn deinit(self: *Add, alloc: Allocator) void {
        alloc.free(self.path);
        alloc.free(self.content);
        self.* = undefined;
    }
};

const Delete = struct {
    path: []u8,

    fn deinit(self: *Delete, alloc: Allocator) void {
        alloc.free(self.path);
        self.* = undefined;
    }
};

const Operation = union(enum) {
    update: Update,
    add: Add,
    delete: Delete,

    fn deinit(self: *Operation, alloc: Allocator) void {
        switch (self.*) {
            .update => |*value| value.deinit(alloc),
            .add => |*value| value.deinit(alloc),
            .delete => |*value| value.deinit(alloc),
        }
        self.* = undefined;
    }
};

pub const Input = struct {
    operations: []Operation,

    pub fn deinit(self: *Input, alloc: Allocator) void {
        for (self.operations) |*operation| operation.deinit(alloc);
        alloc.free(self.operations);
        self.* = .{ .operations = &.{} };
    }
};

const Parser = struct {
    alloc: Allocator,
    lines: []const []const u8,
    index: usize = 0,
    reason: []const u8 = "invalid apply_patch input",
    hunk_count: usize = 0,

    const Error = Allocator.Error || std.Io.Writer.Error || error{InvalidPatch};

    fn invalid(self: *Parser, reason: []const u8) Error {
        self.reason = reason;
        return error.InvalidPatch;
    }

    fn current(self: *const Parser) ?[]const u8 {
        if (self.index >= self.lines.len) return null;
        return stripCarriageReturn(self.lines[self.index]);
    }

    fn parse(self: *Parser) Error![]Operation {
        if (!std.mem.eql(u8, self.current() orelse "", "*** Begin Patch")) {
            return self.invalid("apply_patch must start with *** Begin Patch");
        }
        self.index += 1;

        var operations: std.ArrayList(Operation) = .empty;
        var operations_transferred = false;
        defer if (!operations_transferred) {
            for (operations.items) |*operation| operation.deinit(self.alloc);
            operations.deinit(self.alloc);
        };

        while (self.current()) |line| {
            if (std.mem.eql(u8, line, "*** End Patch")) {
                self.index += 1;
                while (self.current()) |remaining| : (self.index += 1) {
                    if (std.mem.trim(u8, remaining, " \t").len != 0) {
                        return self.invalid("apply_patch has content after *** End Patch");
                    }
                }
                if (operations.items.len == 0) {
                    return self.invalid("apply_patch requires at least one file operation");
                }
                const owned = try operations.toOwnedSlice(self.alloc);
                operations_transferred = true;
                return owned;
            }
            if (std.mem.trim(u8, line, " \t").len == 0) {
                self.index += 1;
                continue;
            }
            if (operations.items.len == max_operations) {
                return self.invalid("apply_patch exceeds the 64 file-operation limit");
            }

            var operation = if (std.mem.startsWith(u8, line, "*** Update File: "))
                try self.parseUpdate()
            else if (std.mem.startsWith(u8, line, "*** Add File: "))
                try self.parseAdd()
            else if (std.mem.startsWith(u8, line, "*** Delete File: "))
                try self.parseDelete()
            else
                return self.invalid("apply_patch expected Update File, Add File, Delete File, or End Patch");
            errdefer operation.deinit(self.alloc);
            try operations.append(self.alloc, operation);
        }

        return self.invalid("apply_patch must end with *** End Patch");
    }

    fn parseUpdate(self: *Parser) Error!Operation {
        const path = try self.parseHeaderPath("*** Update File: ");
        errdefer self.alloc.free(path);
        self.index += 1;

        var move_to: ?[]u8 = null;
        errdefer if (move_to) |value| self.alloc.free(value);
        if (self.current()) |line| {
            if (std.mem.startsWith(u8, line, "*** Move to: ")) {
                move_to = try self.parseHeaderPath("*** Move to: ");
                self.index += 1;
            }
        }

        var hunks: std.ArrayList(Hunk) = .empty;
        var hunks_transferred = false;
        defer if (!hunks_transferred) {
            for (hunks.items) |*hunk| hunk.deinit(self.alloc);
            hunks.deinit(self.alloc);
        };
        while (self.current()) |line| {
            if (!std.mem.startsWith(u8, line, "@@")) break;
            if (self.hunk_count == max_hunks) {
                return self.invalid("apply_patch exceeds the 256 hunk limit");
            }
            self.hunk_count += 1;
            self.index += 1;
            var hunk = try self.parseHunk();
            errdefer hunk.deinit(self.alloc);
            try hunks.append(self.alloc, hunk);
        }
        if (hunks.items.len == 0) {
            return self.invalid("apply_patch Update File requires at least one @@ hunk");
        }
        const anchor_eof = if (self.current()) |line|
            std.mem.eql(u8, line, "*** End of File")
        else
            false;
        if (anchor_eof) self.index += 1;

        const owned_hunks = try hunks.toOwnedSlice(self.alloc);
        hunks_transferred = true;
        return .{ .update = .{
            .path = path,
            .move_to = move_to,
            .hunks = owned_hunks,
            .anchor_eof = anchor_eof,
        } };
    }

    fn parseAdd(self: *Parser) Error!Operation {
        const path = try self.parseHeaderPath("*** Add File: ");
        errdefer self.alloc.free(path);
        self.index += 1;

        var content: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer content.deinit();
        var previous_added = false;
        while (self.index < self.lines.len) {
            const raw = self.lines[self.index];
            const line = stripCarriageReturn(raw);
            if (std.mem.startsWith(u8, line, "*** ")) break;
            if (std.mem.eql(u8, line, "\\ No newline at end of file")) {
                if (!previous_added or !removeTrailingLineEnding(&content)) {
                    return self.invalid("apply_patch no-newline marker must follow an added line");
                }
                previous_added = false;
                self.index += 1;
                continue;
            }
            if (line.len == 0 or line[0] != '+') {
                return self.invalid("apply_patch Add File lines require a + prefix");
            }
            try content.writer.writeAll(raw[1..]);
            try content.writer.writeByte('\n');
            previous_added = true;
            self.index += 1;
        }

        return .{ .add = .{
            .path = path,
            .content = try content.toOwnedSlice(),
        } };
    }

    fn parseDelete(self: *Parser) Error!Operation {
        const path = try self.parseHeaderPath("*** Delete File: ");
        self.index += 1;
        return .{ .delete = .{ .path = path } };
    }

    fn parseHeaderPath(self: *Parser, prefix: []const u8) Error![]u8 {
        const line = self.current() orelse return self.invalid("apply_patch file header is missing");
        if (!std.mem.startsWith(u8, line, prefix)) {
            return self.invalid("apply_patch file header is malformed");
        }
        const path = std.mem.trim(u8, line[prefix.len..], " \t");
        if (path.len == 0) return self.invalid("apply_patch file path must not be empty");
        if (path.len > std.Io.Dir.max_path_bytes or
            std.mem.findScalar(u8, path, 0) != null)
        {
            return self.invalid("apply_patch file path is invalid");
        }
        return self.alloc.dupe(u8, path);
    }

    fn parseHunk(self: *Parser) Error!Hunk {
        var old_out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer old_out.deinit();
        var new_out: std.Io.Writer.Allocating = .init(self.alloc);
        errdefer new_out.deinit();
        var saw_change = false;
        var previous: ?HunkLineKind = null;

        while (self.index < self.lines.len) {
            const raw = self.lines[self.index];
            const line = stripCarriageReturn(raw);
            if (std.mem.startsWith(u8, line, "@@") or
                std.mem.startsWith(u8, line, "*** "))
            {
                break;
            }
            if (std.mem.eql(u8, line, "\\ No newline at end of file")) {
                const prior = previous orelse
                    return self.invalid("apply_patch no-newline marker must follow a hunk line");
                if ((prior == .context or prior == .removed) and
                    !removeTrailingLineEnding(&old_out))
                {
                    return self.invalid("apply_patch no-newline marker is misplaced");
                }
                if ((prior == .context or prior == .added) and
                    !removeTrailingLineEnding(&new_out))
                {
                    return self.invalid("apply_patch no-newline marker is misplaced");
                }
                previous = null;
                self.index += 1;
                continue;
            }
            if (line.len == 0) {
                return self.invalid("apply_patch hunk lines require a space, +, or - prefix");
            }

            const body = raw[1..];
            switch (line[0]) {
                ' ' => {
                    try appendPatchLine(&old_out, body);
                    try appendPatchLine(&new_out, body);
                    previous = .context;
                },
                '-' => {
                    try appendPatchLine(&old_out, body);
                    saw_change = true;
                    previous = .removed;
                },
                '+' => {
                    try appendPatchLine(&new_out, body);
                    saw_change = true;
                    previous = .added;
                },
                else => return self.invalid("apply_patch hunk lines require a space, +, or - prefix"),
            }
            self.index += 1;
        }

        if (!saw_change) return self.invalid("apply_patch hunk must add or remove text");
        const old_text = try old_out.toOwnedSlice();
        errdefer self.alloc.free(old_text);
        if (old_text.len == 0) {
            return self.invalid("apply_patch update insertion requires at least one context or removed line");
        }
        return .{
            .old_text = old_text,
            .new_text = try new_out.toOwnedSlice(),
        };
    }
};

const HunkLineKind = enum { context, removed, added };

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, args_json, .{}) catch {
        return failure(ctx.allocator, "apply_patch arguments must be valid JSON");
    };
    defer parsed.deinit();

    const patch = switch (parsed.value) {
        .string => |value| value,
        .object => |object| blk: {
            const value = object.get("patch") orelse object.get("input") orelse
                return failure(ctx.allocator, "apply_patch requires string field \"patch\"");
            if (value != .string) {
                return failure(ctx.allocator, "apply_patch field \"patch\" must be a string");
            }
            break :blk value.string;
        },
        else => return failure(ctx.allocator, "apply_patch arguments must be an object or patch string"),
    };
    if (patch.len > max_patch_bytes) {
        return failure(ctx.allocator, "apply_patch patch exceeds the 4 MiB limit");
    }

    const normalized = trimMarkdownFence(patch);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(ctx.allocator);
    var iterator = std.mem.splitScalar(u8, normalized, '\n');
    while (iterator.next()) |line| try lines.append(ctx.allocator, line);

    var parser = Parser{ .alloc = ctx.allocator, .lines = lines.items };
    const operations = parser.parse() catch |err| switch (err) {
        error.InvalidPatch => return failure(ctx.allocator, parser.reason),
        error.OutOfMemory => return error.OutOfMemory,
        error.WriteFailed => return failure(ctx.allocator, "apply_patch could not buffer the patch"),
    };
    errdefer {
        for (operations) |*operation| operation.deinit(ctx.allocator);
        ctx.allocator.free(operations);
    }
    const input = try ctx.allocator.create(Input);
    input.* = .{ .operations = operations };
    return .{ .input = .{ .ptr = input, .deinit_fn = inputDeinit } };
}

fn failure(alloc: Allocator, reason: []const u8) Allocator.Error!tool_dispatch.DecodeResult {
    return .{ .failure = try alloc.dupe(u8, reason) };
}

fn inputDeinit(ptr: *anyopaque, alloc: Allocator) void {
    const input: *Input = @ptrCast(@alignCast(ptr));
    input.deinit(alloc);
    alloc.destroy(input);
}

pub fn validate(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    const input = erased.as(Input);
    if (input.operations.len == 0) {
        return try ctx.allocator.dupe(u8, "apply_patch requires at least one file operation");
    }
    return null;
}

const Before = union(enum) {
    absent,
    content: []const u8,
};

const ChangeKind = enum { update, add, delete };

const PreparedChange = struct {
    kind: ChangeKind,
    path: []const u8,
    before: Before,
    after: ?[]const u8,
};

const ContentResult = union(enum) {
    content: []const u8,
    failure: []const u8,
};

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    var arena_state = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (ctx.workspace_root.len == 0) {
        return .{ .failure = try ctx.allocator.dupe(u8, "apply_patch requires a workspace") };
    }

    var prepared: std.ArrayList(PreparedChange) = .empty;
    defer prepared.deinit(arena);
    var updated: usize = 0;
    var added: usize = 0;
    var deleted: usize = 0;

    for (input.operations) |operation| {
        switch (operation) {
            .update => |update| {
                const source = resolvePatchPath(arena, ctx.workspace_root, update.path, .existing) catch |err| {
                    return pathFailure(ctx.allocator, update.path, err);
                };
                if (targetAlreadyPrepared(prepared.items, source)) {
                    return duplicateTarget(ctx.allocator, update.path);
                }
                const before = readPatchFile(arena, source) catch |err| {
                    return fileFailure(ctx.allocator, update.path, err);
                };
                const patched = switch (try applyHunks(
                    arena,
                    before,
                    update.hunks,
                    update.anchor_eof,
                )) {
                    .content => |content| content,
                    .failure => |reason| return .{ .failure = try ctx.allocator.dupe(u8, reason) },
                };
                if (std.mem.eql(u8, before, patched)) {
                    return .{ .failure = try std.fmt.allocPrint(
                        ctx.allocator,
                        "apply_patch failed: {s} would not change",
                        .{update.path},
                    ) };
                }

                if (update.move_to) |move_to| {
                    const destination = resolvePatchPath(arena, ctx.workspace_root, move_to, .create) catch |err| {
                        return pathFailure(ctx.allocator, move_to, err);
                    };
                    if (std.mem.eql(u8, source, destination) or
                        targetAlreadyPrepared(prepared.items, destination))
                    {
                        return duplicateTarget(ctx.allocator, move_to);
                    }
                    if (pathExists(destination) catch |err| {
                        return fileFailure(ctx.allocator, move_to, err);
                    }) {
                        return .{ .failure = try std.fmt.allocPrint(
                            ctx.allocator,
                            "apply_patch failed: move destination already exists: {s}",
                            .{move_to},
                        ) };
                    }
                    try prepared.append(arena, .{
                        .kind = .add,
                        .path = destination,
                        .before = .absent,
                        .after = patched,
                    });
                    try prepared.append(arena, .{
                        .kind = .delete,
                        .path = source,
                        .before = .{ .content = before },
                        .after = null,
                    });
                    added += 1;
                    deleted += 1;
                } else {
                    try prepared.append(arena, .{
                        .kind = .update,
                        .path = source,
                        .before = .{ .content = before },
                        .after = patched,
                    });
                    updated += 1;
                }
            },
            .add => |add| {
                const target = resolvePatchPath(arena, ctx.workspace_root, add.path, .create) catch |err| {
                    return pathFailure(ctx.allocator, add.path, err);
                };
                if (targetAlreadyPrepared(prepared.items, target)) {
                    return duplicateTarget(ctx.allocator, add.path);
                }
                if (pathExists(target) catch |err| {
                    return fileFailure(ctx.allocator, add.path, err);
                }) {
                    return .{ .failure = try std.fmt.allocPrint(
                        ctx.allocator,
                        "apply_patch failed: Add File target already exists: {s}",
                        .{add.path},
                    ) };
                }
                try prepared.append(arena, .{
                    .kind = .add,
                    .path = target,
                    .before = .absent,
                    .after = add.content,
                });
                added += 1;
            },
            .delete => |delete| {
                const target = resolvePatchPath(arena, ctx.workspace_root, delete.path, .existing) catch |err| {
                    return pathFailure(ctx.allocator, delete.path, err);
                };
                if (targetAlreadyPrepared(prepared.items, target)) {
                    return duplicateTarget(ctx.allocator, delete.path);
                }
                const before = readPatchFile(arena, target) catch |err| {
                    return fileFailure(ctx.allocator, delete.path, err);
                };
                try prepared.append(arena, .{
                    .kind = .delete,
                    .path = target,
                    .before = .{ .content = before },
                    .after = null,
                });
                deleted += 1;
            },
        }
    }

    verifyPreparedState(arena, prepared.items) catch |err| {
        return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "apply_patch aborted because workspace state changed before commit: {s}",
            .{@errorName(err)},
        ) };
    };

    var applied: usize = 0;
    while (applied < prepared.items.len) : (applied += 1) {
        if (ctx.cancel_flag) |cancel_flag| {
            if (cancel_flag.load(.seq_cst)) {
                const rollback_ok = rollbackChanges(arena, prepared.items[0..applied]);
                if (!rollback_ok) {
                    return .{ .failure = try ctx.allocator.dupe(
                        u8,
                        "apply_patch cancelled and rollback was incomplete",
                    ) };
                }
                return error.Cancelled;
            }
        }
        applyChange(arena, prepared.items[applied]) catch |err| {
            const rollback_ok = rollbackChanges(arena, prepared.items[0..applied]);
            return .{ .failure = try std.fmt.allocPrint(
                ctx.allocator,
                "apply_patch commit failed for {s}: {s}; rollback={s}",
                .{
                    displayPath(arena, ctx.workspace_root, prepared.items[applied].path),
                    @errorName(err),
                    if (rollback_ok) "complete" else "incomplete",
                },
            ) };
        };
    }

    publishUndoOperations(ctx.change_tracker, prepared.items);
    return .{ .success = try std.fmt.allocPrint(
        ctx.allocator,
        "Applied patch: {d} updated, {d} added, {d} deleted",
        .{ updated, added, deleted },
    ) };
}

fn resolvePatchPath(
    arena: Allocator,
    workspace_root: []const u8,
    input_path: []const u8,
    mode: @import("../../core/shared/types.zig").ResolveMode,
) ![]const u8 {
    return permissions.resolveFileToolPath(
        arena,
        workspace_root,
        "apply_patch",
        input_path,
        mode,
    );
}

fn readPatchFile(alloc: Allocator, absolute_path: []const u8) ![]u8 {
    const stat = try std.Io.Dir.cwd().statFile(io_mod.getIo(), absolute_path, .{});
    if (stat.kind != .file) return error.NotARegularFile;
    var file = try std.Io.Dir.openFileAbsolute(io_mod.getIo(), absolute_path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

fn applyHunks(
    alloc: Allocator,
    original: []const u8,
    hunks: []const Hunk,
    anchor_eof: bool,
) Allocator.Error!ContentResult {
    var current = try alloc.dupe(u8, original);
    var search_start: usize = 0;

    for (hunks, 0..) |hunk, hunk_index| {
        const relative = std.mem.find(u8, current[search_start..], hunk.old_text) orelse {
            return .{ .failure = try std.fmt.allocPrint(
                alloc,
                "apply_patch failed: hunk {d} context not found",
                .{hunk_index + 1},
            ) };
        };
        const match_start = search_start + relative;
        if (anchor_eof and hunk_index + 1 == hunks.len and
            match_start + hunk.old_text.len != current.len)
        {
            return .{ .failure = try std.fmt.allocPrint(
                alloc,
                "apply_patch failed: hunk {d} is not at end of file",
                .{hunk_index + 1},
            ) };
        }
        const second_search_start = match_start + 1;
        if (second_search_start <= current.len and
            std.mem.find(u8, current[second_search_start..], hunk.old_text) != null)
        {
            return .{ .failure = try std.fmt.allocPrint(
                alloc,
                "apply_patch failed: hunk {d} context is not unique; include more unchanged lines",
                .{hunk_index + 1},
            ) };
        }
        const new_len = std.math.add(
            usize,
            current.len - hunk.old_text.len,
            hunk.new_text.len,
        ) catch {
            return .{ .failure = try alloc.dupe(u8, "apply_patch result is too large") };
        };
        if (new_len > max_file_bytes) {
            return .{ .failure = try alloc.dupe(u8, "apply_patch result exceeds the 4 MiB file limit") };
        }
        const next = try alloc.alloc(u8, new_len);
        @memcpy(next[0..match_start], current[0..match_start]);
        @memcpy(
            next[match_start .. match_start + hunk.new_text.len],
            hunk.new_text,
        );
        const suffix_start = match_start + hunk.old_text.len;
        @memcpy(
            next[match_start + hunk.new_text.len ..],
            current[suffix_start..],
        );
        alloc.free(current);
        current = next;
        search_start = match_start + hunk.new_text.len;
    }
    return .{ .content = current };
}

fn applyChange(alloc: Allocator, change: PreparedChange) !void {
    if (change.after) |content| {
        try pathing.ensureParentDirectories(change.path);
        try io_mod.writeFileAtomic(alloc, change.path, content);
        return;
    }
    try std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), change.path);
}

fn verifyPreparedState(alloc: Allocator, changes: []const PreparedChange) !void {
    for (changes) |change| {
        switch (change.before) {
            .absent => if (try pathExists(change.path)) return error.PathAlreadyExists,
            .content => |expected| {
                const current = try readPatchFile(alloc, change.path);
                if (!std.mem.eql(u8, current, expected)) return error.FileChanged;
            },
        }
    }
}

fn rollbackChanges(alloc: Allocator, changes: []const PreparedChange) bool {
    var ok = true;
    var index = changes.len;
    while (index > 0) {
        index -= 1;
        const change = changes[index];
        switch (change.before) {
            .absent => std.Io.Dir.deleteFileAbsolute(io_mod.getIo(), change.path) catch |err| {
                if (err != error.FileNotFound) ok = false;
            },
            .content => |content| {
                pathing.ensureParentDirectories(change.path) catch {
                    ok = false;
                    continue;
                };
                io_mod.writeFileAtomic(alloc, change.path, content) catch {
                    ok = false;
                };
            },
        }
    }
    return ok;
}

fn publishUndoOperations(
    maybe_tracker: ?*change_tracker.ChangeTracker,
    changes: []const PreparedChange,
) void {
    const tracker = maybe_tracker orelse return;
    const alloc = std.heap.c_allocator;
    for (changes) |change| {
        const owned_path = alloc.dupe(u8, change.path) catch continue;
        const previous_content: ?[]u8 = switch (change.before) {
            .absent => null,
            .content => |content| alloc.dupe(u8, content) catch {
                alloc.free(owned_path);
                continue;
            },
        };
        const operation = change_tracker.FileOperation{
            .kind = switch (change.kind) {
                .update => .edit,
                .add => .write,
                .delete => .delete,
            },
            .path = owned_path,
            .previous_content = previous_content,
            .timestamp_ms = io_mod.milliTimestamp(),
        };
        tracker.pushOperation(alloc, operation) catch {
            alloc.free(owned_path);
            if (previous_content) |content| alloc.free(content);
        };
    }
}

fn targetAlreadyPrepared(changes: []const PreparedChange, path: []const u8) bool {
    for (changes) |change| {
        if (std.mem.eql(u8, change.path, path)) return true;
    }
    return false;
}

fn pathExists(path: []const u8) !bool {
    _ = std.Io.Dir.cwd().statFile(io_mod.getIo(), path, .{
        .follow_symlinks = false,
    }) catch |err| return switch (err) {
        error.FileNotFound, error.NotDir => false,
        else => err,
    };
    return true;
}

fn pathFailure(alloc: Allocator, path: []const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "apply_patch could not resolve {s}: {s}",
        .{ path, @errorName(err) },
    ) };
}

fn fileFailure(alloc: Allocator, path: []const u8, err: anyerror) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "apply_patch could not read {s}: {s}",
        .{ path, @errorName(err) },
    ) };
}

fn duplicateTarget(alloc: Allocator, path: []const u8) Allocator.Error!tool_dispatch.ToolResult {
    return .{ .failure = try std.fmt.allocPrint(
        alloc,
        "apply_patch targets {s} more than once; combine its hunks under one file header",
        .{path},
    ) };
}

fn displayPath(arena: Allocator, workspace_root: []const u8, absolute_path: []const u8) []const u8 {
    return pathing.workspaceRelativePath(arena, workspace_root, absolute_path) catch absolute_path;
}

fn appendPatchLine(out: *std.Io.Writer.Allocating, body: []const u8) !void {
    try out.writer.writeAll(body);
    try out.writer.writeByte('\n');
}

fn removeTrailingLineEnding(out: *std.Io.Writer.Allocating) bool {
    if (out.writer.end == 0 or out.writer.buffer[out.writer.end - 1] != '\n') return false;
    out.writer.end -= 1;
    if (out.writer.end > 0 and out.writer.buffer[out.writer.end - 1] == '\r') {
        out.writer.end -= 1;
    }
    return true;
}

fn trimMarkdownFence(patch: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, patch, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "```")) return trimmed;
    const first_line_end = std.mem.findScalar(u8, trimmed, '\n') orelse return trimmed;
    const after_open = trimmed[first_line_end + 1 ..];
    const closing = std.mem.lastIndexOf(u8, after_open, "```") orelse return trimmed;
    if (std.mem.trim(u8, after_open[closing + 3 ..], " \t\r\n").len != 0) return trimmed;
    return std.mem.trim(u8, after_open[0..closing], "\r\n");
}

fn stripCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return false;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return true;
}

fn decodeInput(args_json: []const u8) !tool_dispatch.ToolInput {
    return switch (try decode(.{ .allocator = std.testing.allocator }, args_json)) {
        .input => |input| input,
        .failure => |reason| {
            defer std.testing.allocator.free(reason);
            return error.TestExpectedDecodedInput;
        },
    };
}

fn workspaceRoot(alloc: Allocator, tmp: std.testing.TmpDir) ![]u8 {
    return io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
}

fn writeTestFile(dir: std.Io.Dir, path: []const u8, content: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| try dir.createDirPath(io_mod.getIo(), parent);
    var file = try dir.createFile(io_mod.getIo(), path, .{ .truncate = true });
    defer file.close(io_mod.getIo());
    try file.writeStreamingAll(io_mod.getIo(), content);
}

fn readTestFile(alloc: Allocator, dir: std.Io.Dir, path: []const u8) ![]u8 {
    var file = try dir.openFile(io_mod.getIo(), path, .{});
    defer file.close(io_mod.getIo());
    return io_mod.readFileToEnd(alloc, &file, max_file_bytes);
}

test "apply_patch v3 decodes multiple files and multiple hunks" {
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n@@\n-three\n+THREE\n*** Add File: b.txt\n+new\n*** Delete File: c.txt\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const patch_input = input.as(Input);
    try std.testing.expectEqual(@as(usize, 3), patch_input.operations.len);
    try std.testing.expectEqual(@as(usize, 2), patch_input.operations[0].update.hunks.len);
}

test "apply_patch v3 applies a transactional multi-file patch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo\nthree\n");
    try writeTestFile(tmp.dir, "c.txt", "remove\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n@@\n-three\n+THREE\n*** Add File: nested/b.txt\n+new\n*** Delete File: c.txt\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    var cancelled = std.atomic.Value(bool).init(false);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
        .cancel_flag = &cancelled,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);

    const a = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("ONE\ntwo\nTHREE\n", a);
    const b = try readTestFile(std.testing.allocator, tmp.dir, "nested/b.txt");
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualStrings("new\n", b);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io_mod.getIo(), "c.txt", .{}),
    );
}

test "apply_patch v3 validates every hunk before writing any file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\n");
    try writeTestFile(tmp.dir, "b.txt", "two\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-one\n+ONE\n*** Update File: b.txt\n@@\n-missing\n+TWO\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
    const a = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("one\n", a);
}

test "apply_patch v3 supports the standard end-of-file anchor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeTestFile(tmp.dir, "a.txt", "one\ntwo\n");
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Update File: a.txt\n@@\n-two\n+TWO\n*** End of File\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .success);
    const actual = try readTestFile(std.testing.allocator, tmp.dir, "a.txt");
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings("one\nTWO\n", actual);
}

test "apply_patch v3 refuses workspace escapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try workspaceRoot(std.testing.allocator, tmp);
    defer std.testing.allocator.free(root);
    const input = try decodeInput(
        \\{"patch":"*** Begin Patch\n*** Add File: ../outside.txt\n+nope\n*** End Patch"}
    );
    defer input.deinit(std.testing.allocator);
    const result = try call(.{
        .allocator = std.testing.allocator,
        .workspace_root = root,
    }, input);
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(result) == .failure);
}
