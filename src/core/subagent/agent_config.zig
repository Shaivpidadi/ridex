const std = @import("std");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const sort_utils = @import("../shared/sort_utils.zig");
const types = @import("../shared/types.zig");

const Allocator = std.mem.Allocator;

pub const max_definitions: usize = 64;
pub const max_file_bytes: usize = 64 * 1024;
pub const max_name_bytes: usize = 64;
pub const max_description_bytes: usize = 512;
pub const max_instructions_bytes: usize = 64 * 1024;
pub const max_model_bytes: usize = 256;
pub const max_catalog_prompt_bytes: usize = 32 * 1024;

pub const Definition = struct {
    name: []u8,
    description: []u8,
    instructions: []u8,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,

    pub fn deinit(self: *Definition, alloc: Allocator) void {
        alloc.free(self.name);
        alloc.free(self.description);
        alloc.free(self.instructions);
        if (self.model) |model| alloc.free(model);
        self.* = undefined;
    }

    pub fn clone(self: Definition, alloc: Allocator) Allocator.Error!Definition {
        const name = try alloc.dupe(u8, self.name);
        errdefer alloc.free(name);
        const description = try alloc.dupe(u8, self.description);
        errdefer alloc.free(description);
        const instructions = try alloc.dupe(u8, self.instructions);
        errdefer alloc.free(instructions);
        const model = if (self.model) |value| try alloc.dupe(u8, value) else null;
        return .{
            .name = name,
            .description = description,
            .instructions = instructions,
            .model = model,
            .effort = self.effort,
        };
    }
};

pub const DiagnosticCause = enum {
    invalid_name,
    not_regular_file,
    unreadable,
    oversized,
    malformed_json,
    invalid_schema,
    capacity_exceeded,
};

pub const Diagnostic = struct {
    candidate: []u8,
    cause: DiagnosticCause,

    pub fn deinit(self: *Diagnostic, alloc: Allocator) void {
        alloc.free(self.candidate);
        self.* = undefined;
    }
};

pub const Catalog = struct {
    definitions: []Definition = &.{},
    diagnostics: []Diagnostic = &.{},

    pub fn deinit(self: *Catalog, alloc: Allocator) void {
        for (self.definitions) |*definition| definition.deinit(alloc);
        if (self.definitions.len > 0) alloc.free(self.definitions);
        for (self.diagnostics) |*diagnostic| diagnostic.deinit(alloc);
        if (self.diagnostics.len > 0) alloc.free(self.diagnostics);
        self.* = .{};
    }

    pub fn find(self: Catalog, name: []const u8) ?*const Definition {
        for (self.definitions) |*definition| {
            if (std.mem.eql(u8, definition.name, name)) return definition;
        }
        return null;
    }

    pub fn promptSectionAlloc(self: Catalog, alloc: Allocator) ![]u8 {
        if (self.definitions.len == 0) return alloc.dupe(u8, "");
        var out: std.Io.Writer.Allocating = .init(alloc);
        errdefer out.deinit();
        try out.writer.writeAll("<persistent_agents>\n");
        for (self.definitions) |definition| {
            const remaining = max_catalog_prompt_bytes -| out.writer.buffered().len;
            if (remaining <= 24) break;
            const description = definition.description[0..@min(
                definition.description.len,
                remaining - 24,
            )];
            try out.writer.print("{s}: {s}\n", .{ definition.name, description });
        }
        try out.writer.writeAll("Use subagent.message with one exact name above.\n</persistent_agents>");
        if (out.writer.buffered().len > max_catalog_prompt_bytes) {
            return error.WriteFailed;
        }
        return out.toOwnedSlice();
    }
};

pub const ParseError = error{
    OutOfMemory,
    InvalidName,
    MalformedJson,
    InvalidSchema,
};

pub fn parseDefinition(
    alloc: Allocator,
    name: []const u8,
    bytes: []const u8,
) ParseError!Definition {
    if (!validName(name)) return error.InvalidName;
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch
        return error.MalformedJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidSchema;
    const object = parsed.value.object;
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (!knownField(entry.key_ptr.*)) return error.InvalidSchema;
    }

    const description = try requiredText(
        object,
        "description",
        max_description_bytes,
    );
    const instructions = try requiredText(
        object,
        "instructions",
        max_instructions_bytes,
    );
    const model = try optionalText(object, "model", max_model_bytes);
    const effort = if (try optionalText(
        object,
        "effort",
        types.ReasoningEffort.max_name_bytes,
    )) |value|
        types.ReasoningEffort.parse(value) orelse return error.InvalidSchema
    else
        null;

    const owned_name = try alloc.dupe(u8, name);
    errdefer alloc.free(owned_name);
    const owned_description = try alloc.dupe(u8, description);
    errdefer alloc.free(owned_description);
    const owned_instructions = try alloc.dupe(u8, instructions);
    errdefer alloc.free(owned_instructions);
    const owned_model = if (model) |value| try alloc.dupe(u8, value) else null;
    return .{
        .name = owned_name,
        .description = owned_description,
        .instructions = owned_instructions,
        .model = owned_model,
        .effort = effort,
    };
}

pub fn loadFromHome(alloc: Allocator, home: []const u8) Allocator.Error!Catalog {
    const path = try profile_paths.agentsDir(alloc, home);
    defer alloc.free(path);
    return loadFromDirPath(alloc, path);
}

pub fn loadFromDirPath(alloc: Allocator, path: []const u8) Allocator.Error!Catalog {
    var dir = io_mod.openDirAbsoluteNoFollow(path, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) return .{};
        var diagnostics = try alloc.alloc(Diagnostic, 1);
        diagnostics[0] = .{
            .candidate = try alloc.dupe(u8, path),
            .cause = .unreadable,
        };
        return .{ .diagnostics = diagnostics };
    };
    defer dir.close(io_mod.getIo());

    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| alloc.free(name);
        names.deinit(alloc);
    }
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    errdefer freeDiagnostics(alloc, &diagnostics);

    var iterator = dir.iterate();
    while (true) {
        const entry = iterator.next(io_mod.getIo()) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendDiagnostic(alloc, &diagnostics, path, .unreadable);
            break;
        } orelse break;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        if (entry.kind != .file) {
            try appendDiagnostic(alloc, &diagnostics, entry.name, .not_regular_file);
            continue;
        }
        const name = try alloc.dupe(u8, entry.name);
        try names.append(alloc, name);
    }

    sort_utils.sort([]u8, names.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.lessThan);

    var definitions: std.ArrayList(Definition) = .empty;
    errdefer freeDefinitions(alloc, &definitions);
    for (names.items) |file_name| {
        if (definitions.items.len >= max_definitions) {
            try appendDiagnostic(alloc, &diagnostics, file_name, .capacity_exceeded);
            continue;
        }
        const stem = file_name[0 .. file_name.len - ".json".len];
        if (!validName(stem)) {
            try appendDiagnostic(alloc, &diagnostics, file_name, .invalid_name);
            continue;
        }
        var file = io_mod.openExistingReadOnlyRegularFile(
            dir,
            file_name,
            .no_follow,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendDiagnostic(alloc, &diagnostics, file_name, .unreadable);
            continue;
        };
        defer file.close(io_mod.getIo());
        const bytes = io_mod.readFileToEnd(alloc, &file, max_file_bytes) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendDiagnostic(
                alloc,
                &diagnostics,
                file_name,
                if (err == error.StreamTooLong) .oversized else .unreadable,
            );
            continue;
        };
        defer alloc.free(bytes);
        var definition = parseDefinition(alloc, stem, bytes) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            try appendDiagnostic(
                alloc,
                &diagnostics,
                file_name,
                switch (err) {
                    error.InvalidName => .invalid_name,
                    error.MalformedJson => .malformed_json,
                    error.InvalidSchema => .invalid_schema,
                    error.OutOfMemory => unreachable,
                },
            );
            continue;
        };
        errdefer definition.deinit(alloc);
        try definitions.append(alloc, definition);
    }

    return .{
        .definitions = try definitions.toOwnedSlice(alloc),
        .diagnostics = try diagnostics.toOwnedSlice(alloc),
    };
}

fn knownField(name: []const u8) bool {
    return std.mem.eql(u8, name, "description") or
        std.mem.eql(u8, name, "instructions") or
        std.mem.eql(u8, name, "model") or
        std.mem.eql(u8, name, "effort");
}

fn requiredText(
    object: std.json.ObjectMap,
    name: []const u8,
    max_bytes: usize,
) ParseError![]const u8 {
    return (try optionalText(object, name, max_bytes)) orelse error.InvalidSchema;
}

fn optionalText(
    object: std.json.ObjectMap,
    name: []const u8,
    max_bytes: usize,
) ParseError!?[]const u8 {
    const value = object.get(name) orelse return null;
    if (value != .string) return error.InvalidSchema;
    const text = value.string;
    if (text.len == 0 or text.len > max_bytes or
        !std.unicode.utf8ValidateSlice(text) or
        std.mem.findScalar(u8, text, 0) != null)
    {
        return error.InvalidSchema;
    }
    return text;
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name_bytes) return false;
    if (!std.ascii.isLower(name[0]) and !std.ascii.isDigit(name[0])) return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isLower(byte) and !std.ascii.isDigit(byte) and
            byte != '_' and byte != '-')
        {
            return false;
        }
    }
    return true;
}

fn appendDiagnostic(
    alloc: Allocator,
    diagnostics: *std.ArrayList(Diagnostic),
    candidate: []const u8,
    cause: DiagnosticCause,
) Allocator.Error!void {
    const owned = try alloc.dupe(u8, candidate);
    errdefer alloc.free(owned);
    try diagnostics.append(alloc, .{ .candidate = owned, .cause = cause });
}

fn freeDefinitions(alloc: Allocator, definitions: *std.ArrayList(Definition)) void {
    for (definitions.items) |*definition| definition.deinit(alloc);
    definitions.deinit(alloc);
}

fn freeDiagnostics(alloc: Allocator, diagnostics: *std.ArrayList(Diagnostic)) void {
    for (diagnostics.items) |*diagnostic| diagnostic.deinit(alloc);
    diagnostics.deinit(alloc);
}

test "agent definitions validate a strict minimal schema" {
    const alloc = std.testing.allocator;
    var definition = try parseDefinition(alloc, "reviewer",
        \\{"description":"Reviews changes.","instructions":"Review the requested change.","model":"openai/gpt-5.6-sol","effort":"high"}
    );
    defer definition.deinit(alloc);
    try std.testing.expectEqualStrings("reviewer", definition.name);
    try std.testing.expectEqualStrings("Reviews changes.", definition.description);
    try std.testing.expectEqualStrings("Review the requested change.", definition.instructions);
    try std.testing.expectEqualStrings("openai/gpt-5.6-sol", definition.model.?);
    try std.testing.expectEqualStrings("high", definition.effort.?.label());
}

test "agent definitions reject unsafe names and extra fields" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidName,
        parseDefinition(alloc, "../reviewer",
            \\{"description":"Reviews.","instructions":"Review."}
        ),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        parseDefinition(alloc, "reviewer",
            \\{"description":"Reviews.","instructions":"Review.","tools":["shell"]}
        ),
    );
}

test "agent definition discovery is deterministic and isolates invalid files" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "agents");
    var dir = try tmp.dir.openDir(std.testing.io, "agents", .{});
    defer dir.close(std.testing.io);
    try writeFixture(dir, "zeta.json", "{\"description\":\"Zeta.\",\"instructions\":\"Do zeta work.\"}");
    try writeFixture(dir, "alpha.json", "{\"description\":\"Alpha.\",\"instructions\":\"Do alpha work.\"}");
    try writeFixture(dir, "broken.json", "{");

    const path = try io_mod.dirRealpathAlloc(alloc, tmp.dir, "agents");
    defer alloc.free(path);
    var catalog = try loadFromDirPath(alloc, path);
    defer catalog.deinit(alloc);
    try std.testing.expectEqual(@as(usize, 2), catalog.definitions.len);
    try std.testing.expectEqualStrings("alpha", catalog.definitions[0].name);
    try std.testing.expectEqualStrings("zeta", catalog.definitions[1].name);
    try std.testing.expectEqual(@as(usize, 1), catalog.diagnostics.len);
    try std.testing.expectEqual(DiagnosticCause.malformed_json, catalog.diagnostics[0].cause);
}

fn writeFixture(dir: std.Io.Dir, name: []const u8, bytes: []const u8) !void {
    var file = try dir.createFile(std.testing.io, name, .{});
    defer file.close(std.testing.io);
    try file.writeStreamingAll(std.testing.io, bytes);
}
