const std = @import("std");
const context_limits = @import("context_limits.zig");
const io_mod = @import("../shared/io.zig");
const model_provider = @import("model_provider.zig");
const settings_store = @import("settings_store.zig");
const types = @import("../shared/types.zig");
const tool_result_limits = @import("../tooling/tool_result_limits.zig");
const workspace_access = @import("../workspace/workspace_access.zig");

const Allocator = std.mem.Allocator;

pub const schema_version: u32 = 1;
pub const max_config_file_bytes: usize = 64 * 1024;
pub const max_system_prompt_parts: usize = 16;
pub const max_system_prompt_part_bytes: usize = 64 * 1024;
pub const max_system_prompt_total_bytes: usize = 128 * 1024;

pub const json_schema =
    "{\"$schema\":\"https://json-schema.org/draft/2020-12/schema\",\"$id\":\"https://fx.sh/schema/launch-config-v1.json\",\"title\":\"fx launch configuration\",\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"schema_version\"],\"$defs\":{\"contextLimit\":{\"oneOf\":[{\"type\":\"integer\",\"minimum\":0},{\"const\":\"off\"}]}},\"properties\":{" ++
    "\"schema_version\":{\"const\":1}," ++
    "\"agent\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++
    "\"provider\":{\"enum\":[\"gateway\",\"codex\",\"grok\"]},\"model\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":1024},\"effort\":{\"type\":\"string\"},\"fast_mode\":{\"type\":\"boolean\"},\"max_steps\":{\"type\":\"integer\",\"minimum\":0},\"first_call_tool_choice\":{\"enum\":[\"auto\",\"none\",\"required\"]},\"enabled_tools\":{\"type\":\"array\",\"uniqueItems\":true,\"items\":{\"type\":\"string\"}}}}," ++
    "\"prompt\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"system_parts\":{\"type\":\"array\",\"maxItems\":16,\"items\":{\"oneOf\":[" ++
    "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"type\",\"id\"],\"properties\":{\"type\":{\"const\":\"builtin\"},\"id\":{\"const\":\"default\"}}}," ++
    "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"type\",\"text\"],\"properties\":{\"type\":{\"const\":\"inline\"},\"text\":{\"type\":\"string\",\"maxLength\":65536}}}," ++
    "{\"type\":\"object\",\"additionalProperties\":false,\"required\":[\"type\",\"path\"],\"properties\":{\"type\":{\"const\":\"file\"},\"path\":{\"type\":\"string\",\"minLength\":1}}}]}}}}," ++
    "\"runtime\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{\"permission_mode\":{\"enum\":[\"ask\",\"auto\",\"yolo\"]},\"max_tool_result_bytes\":{\"type\":\"integer\",\"minimum\":1024},\"context_enabled\":{\"type\":\"boolean\"},\"context_limits\":{\"type\":\"object\",\"additionalProperties\":false,\"properties\":{" ++
    "\"skill_description_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"skill_catalog_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"skill_chunk_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"skill_file_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_description_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_search_result_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_server_instructions_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"mcp_selected_schema_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"project_instruction_file_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"project_instructions_total_bytes\":{\"$ref\":\"#/$defs/contextLimit\"},\"image_adapter_output_bytes\":{\"$ref\":\"#/$defs/contextLimit\"}}},\"additional_directories\":{\"type\":\"array\",\"maxItems\":16,\"uniqueItems\":true,\"items\":{\"type\":\"string\"}}}}}}\n";

pub const InputSource = union(enum) {
    regular_file: []const u8,
    non_file,
};

pub const FilePart = struct {
    path: []u8,
    content: []u8,
};

pub const SystemPart = union(enum) {
    builtin,
    @"inline": []u8,
    file: FilePart,

    pub fn deinit(self: *SystemPart, alloc: Allocator) void {
        switch (self.*) {
            .builtin => {},
            .@"inline" => |text| alloc.free(text),
            .file => |part| {
                alloc.free(part.path);
                alloc.free(part.content);
            },
        }
        self.* = undefined;
    }
};

pub const ParsedDocument = struct {
    provider: ?model_provider.ProviderId = null,
    model: ?[]u8 = null,
    effort: ?types.ReasoningEffort = null,
    fast_mode: ?bool = null,
    max_steps: ?usize = null,
    first_call_tool_choice: ?types.ToolChoice = null,
    enabled_tools: ?[][]u8 = null,
    system_parts: ?[]SystemPart = null,
    permission_mode: ?types.PermissionMode = null,
    max_tool_result_bytes: ?usize = null,
    context_enabled: ?bool = null,
    context_limit_overrides: ?context_limits.Overrides = null,
    additional_directories: ?[][]u8 = null,

    pub fn deinit(self: *ParsedDocument, alloc: Allocator) void {
        if (self.model) |model| alloc.free(model);
        if (self.enabled_tools) |names| freeStrings(alloc, names);
        if (self.system_parts) |parts| {
            for (parts) |*part| part.deinit(alloc);
            alloc.free(parts);
        }
        if (self.additional_directories) |paths| freeStrings(alloc, paths);
        self.* = undefined;
    }

    pub fn validateEnabledTools(
        self: *const ParsedDocument,
        available_tool_names: []const []const u8,
    ) !void {
        const selected = self.enabled_tools orelse return;
        for (selected) |name| {
            if (!containsName(available_tool_names, name)) {
                return error.ToolCapabilityUnavailable;
            }
        }
    }

    pub fn validateSystemPromptTotal(
        self: *const ParsedDocument,
        builtin_prompt: []const u8,
    ) !void {
        const parts = self.system_parts orelse return;
        var total: usize = 0;
        for (parts) |part| {
            const part_len = switch (part) {
                .builtin => builtin_prompt.len,
                .@"inline" => |text| text.len,
                .file => |file| file.content.len,
            };
            total = std.math.add(usize, total, part_len) catch
                return error.SystemPromptTooLarge;
            if (total > max_system_prompt_total_bytes) return error.SystemPromptTooLarge;
        }
    }
};

pub const Field = enum(u8) {
    provider,
    model,
    effort,
    fast_mode,
    max_steps,
    first_call_tool_choice,
    enabled_tools,
    system_parts,
    permission_mode,
    max_tool_result_bytes,
    context_enabled,
    context_limits,
    additional_directories,

    pub fn jsonPointer(self: Field) []const u8 {
        return switch (self) {
            .provider => "/agent/provider",
            .model => "/agent/model",
            .effort => "/agent/effort",
            .fast_mode => "/agent/fast_mode",
            .max_steps => "/agent/max_steps",
            .first_call_tool_choice => "/agent/first_call_tool_choice",
            .enabled_tools => "/agent/enabled_tools",
            .system_parts => "/prompt/system_parts",
            .permission_mode => "/runtime/permission_mode",
            .max_tool_result_bytes => "/runtime/max_tool_result_bytes",
            .context_enabled => "/runtime/context_enabled",
            .context_limits => "/runtime/context_limits",
            .additional_directories => "/runtime/additional_directories",
        };
    }

    pub fn dottedName(self: Field) []const u8 {
        return switch (self) {
            .provider => "agent.provider",
            .model => "agent.model",
            .effort => "agent.effort",
            .fast_mode => "agent.fast_mode",
            .max_steps => "agent.max_steps",
            .first_call_tool_choice => "agent.first_call_tool_choice",
            .enabled_tools => "agent.enabled_tools",
            .system_parts => "prompt.system_parts",
            .permission_mode => "runtime.permission_mode",
            .max_tool_result_bytes => "runtime.max_tool_result_bytes",
            .context_enabled => "runtime.context_enabled",
            .context_limits => "runtime.context_limits",
            .additional_directories => "runtime.additional_directories",
        };
    }
};

pub const field_count = std.meta.fields(Field).len;

pub const FieldMask = struct {
    bits: u16 = 0,

    pub fn set(self: *FieldMask, field: Field) void {
        self.bits |= @as(u16, 1) << @as(u4, @intCast(@intFromEnum(field)));
    }

    pub fn contains(self: FieldMask, field: Field) bool {
        return self.bits & (@as(u16, 1) << @as(u4, @intCast(@intFromEnum(field)))) != 0;
    }
};

pub const Source = union(enum) {
    compiled_default,
    project_file,
    profile_global,
    profile_workspace,
    explicit_file: struct {
        path: []const u8,
        layer: usize,
    },
    stdin,
    environment: struct {
        name: []const u8,
    },
    command: struct {
        argument_index: usize,
    },

    pub fn clone(self: Source, alloc: Allocator) !Source {
        return switch (self) {
            .compiled_default => .compiled_default,
            .project_file => .project_file,
            .profile_global => .profile_global,
            .profile_workspace => .profile_workspace,
            .explicit_file => |value| .{ .explicit_file = .{
                .path = try alloc.dupe(u8, value.path),
                .layer = value.layer,
            } },
            .stdin => .stdin,
            .environment => |value| .{ .environment = .{
                .name = try alloc.dupe(u8, value.name),
            } },
            .command => |value| .{ .command = value },
        };
    }

    pub fn deinit(self: *Source, alloc: Allocator) void {
        switch (self.*) {
            .explicit_file => |value| alloc.free(value.path),
            .environment => |value| alloc.free(value.name),
            else => {},
        }
        self.* = .compiled_default;
    }
};

pub const OwnedLaunchPolicy = struct {
    explicit_fields: FieldMask = .{},
    sources: [field_count]Source = [_]Source{.compiled_default} ** field_count,
    system_parts: ?[]SystemPart = null,
    system_prompt: ?[]u8 = null,
    enabled_tools: ?[][]u8 = null,

    pub fn deinit(self: *OwnedLaunchPolicy, alloc: Allocator) void {
        for (&self.sources) |*item| item.deinit(alloc);
        if (self.system_parts) |parts| {
            for (parts) |*part| part.deinit(alloc);
            alloc.free(parts);
        }
        if (self.system_prompt) |text| alloc.free(text);
        if (self.enabled_tools) |names| freeStrings(alloc, names);
        self.* = .{};
    }

    pub fn take(self: *OwnedLaunchPolicy) OwnedLaunchPolicy {
        const value = self.*;
        self.* = .{};
        return value;
    }

    pub fn source(self: *const OwnedLaunchPolicy, field: Field) Source {
        return self.sources[@intFromEnum(field)];
    }

    pub fn setSource(
        self: *OwnedLaunchPolicy,
        alloc: Allocator,
        field: Field,
        source_value: Source,
        explicit: bool,
    ) !void {
        const index = @intFromEnum(field);
        var replacement = try source_value.clone(alloc);
        errdefer replacement.deinit(alloc);
        self.sources[index].deinit(alloc);
        self.sources[index] = replacement;
        if (explicit) self.explicit_fields.set(field);
    }

    pub fn composeSystemPrompt(
        self: *OwnedLaunchPolicy,
        alloc: Allocator,
        builtin_prompt: []const u8,
    ) !void {
        const parts = self.system_parts orelse return;
        if (self.system_prompt != null) return;
        var output: std.Io.Writer.Allocating = .init(alloc);
        defer output.deinit();
        for (parts) |part| {
            const text = switch (part) {
                .builtin => builtin_prompt,
                .@"inline" => |value| value,
                .file => |value| value.content,
            };
            const next_len = std.math.add(usize, output.written().len, text.len) catch
                return error.SystemPromptTooLarge;
            if (next_len > max_system_prompt_total_bytes) return error.SystemPromptTooLarge;
            output.writer.writeAll(text) catch return error.OutOfMemory;
        }
        const composed = try output.toOwnedSlice();
        if (self.system_prompt) |old| alloc.free(old);
        self.system_prompt = composed;
    }
};

fn containsName(names: []const []const u8, target: []const u8) bool {
    for (names) |name| {
        if (std.mem.eql(u8, name, target)) return true;
    }
    return false;
}

const RawDocument = struct {
    schema_version: u32,
    agent: ?RawAgent = null,
    prompt: ?RawPrompt = null,
    runtime: ?RawRuntime = null,
};

const RawAgent = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    fast_mode: ?bool = null,
    max_steps: ?usize = null,
    first_call_tool_choice: ?[]const u8 = null,
    enabled_tools: ?[]const []const u8 = null,
};

const RawPrompt = struct {
    system_parts: ?[]const RawSystemPart = null,
};

const RawSystemPart = struct {
    type: []const u8,
    id: ?[]const u8 = null,
    path: ?[]const u8 = null,
    text: ?[]const u8 = null,
};

const RawRuntime = struct {
    permission_mode: ?[]const u8 = null,
    max_tool_result_bytes: ?usize = null,
    context_enabled: ?bool = null,
    context_limits: ?RawContextLimits = null,
    additional_directories: ?[]const []const u8 = null,
};

const RawContextLimits = struct {
    skill_description_bytes: ?std.json.Value = null,
    skill_catalog_bytes: ?std.json.Value = null,
    skill_chunk_bytes: ?std.json.Value = null,
    skill_file_bytes: ?std.json.Value = null,
    mcp_description_bytes: ?std.json.Value = null,
    mcp_search_result_bytes: ?std.json.Value = null,
    mcp_server_instructions_bytes: ?std.json.Value = null,
    mcp_selected_schema_bytes: ?std.json.Value = null,
    project_instruction_file_bytes: ?std.json.Value = null,
    project_instructions_total_bytes: ?std.json.Value = null,
    image_adapter_output_bytes: ?std.json.Value = null,
};

pub fn parseDocument(
    alloc: Allocator,
    bytes: []const u8,
    source: InputSource,
) !ParsedDocument {
    if (bytes.len > max_config_file_bytes) return error.ConfigFileTooLarge;
    try rejectNullValues(alloc, bytes);

    var raw = try std.json.parseFromSlice(RawDocument, alloc, bytes, .{
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
    });
    defer raw.deinit();
    if (raw.value.schema_version != schema_version) return error.UnsupportedSchemaVersion;

    var result = ParsedDocument{};
    errdefer result.deinit(alloc);

    if (raw.value.agent) |agent| try parseAgent(alloc, &result, agent);
    if (raw.value.prompt) |prompt| try parsePrompt(alloc, &result, prompt, source);
    if (raw.value.runtime) |runtime| try parseRuntime(alloc, &result, runtime);
    return result;
}

pub fn parseOverride(alloc: Allocator, name: []const u8, value: []const u8) !ParsedDocument {
    const placement = overridePlacement(name) orelse return error.UnknownConfigField;
    var encoded: std.Io.Writer.Allocating = .init(alloc);
    defer encoded.deinit();

    try encoded.writer.print("{{\"schema_version\":1,\"{s}\":{{\"{s}\":", .{
        placement.namespace,
        placement.field,
    });
    if (placement.structured) {
        try encoded.writer.writeAll(value);
    } else {
        try std.json.Stringify.value(value, .{}, &encoded.writer);
    }
    try encoded.writer.writeAll("}}");
    return parseDocument(alloc, encoded.written(), .non_file);
}

const OverridePlacement = struct {
    namespace: []const u8,
    field: []const u8,
    structured: bool,
};

fn overridePlacement(name: []const u8) ?OverridePlacement {
    inline for (&.{
        .{ "agent.provider", "agent", "provider", false },
        .{ "agent.model", "agent", "model", false },
        .{ "agent.effort", "agent", "effort", false },
        .{ "agent.fast_mode", "agent", "fast_mode", true },
        .{ "agent.max_steps", "agent", "max_steps", true },
        .{ "agent.first_call_tool_choice", "agent", "first_call_tool_choice", false },
        .{ "agent.enabled_tools", "agent", "enabled_tools", true },
        .{ "prompt.system_parts", "prompt", "system_parts", true },
        .{ "runtime.permission_mode", "runtime", "permission_mode", false },
        .{ "runtime.max_tool_result_bytes", "runtime", "max_tool_result_bytes", true },
        .{ "runtime.context_enabled", "runtime", "context_enabled", true },
        .{ "runtime.context_limits", "runtime", "context_limits", true },
        .{ "runtime.additional_directories", "runtime", "additional_directories", true },
    }) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return .{
            .namespace = entry[1],
            .field = entry[2],
            .structured = entry[3],
        };
    }
    return null;
}

fn rejectNullValues(alloc: Allocator, bytes: []const u8) !void {
    var scanner = std.json.Scanner.initCompleteInput(alloc, bytes);
    defer scanner.deinit();
    while (true) {
        switch (try scanner.next()) {
            .null => return error.NullUnsupported,
            .end_of_document => return,
            else => {},
        }
    }
}

fn parseAgent(alloc: Allocator, result: *ParsedDocument, raw: RawAgent) !void {
    if (raw.provider) |provider| {
        result.provider = std.meta.stringToEnum(model_provider.ProviderId, provider) orelse
            return error.InvalidProvider;
    }
    if (raw.model) |model| {
        settings_store.validateModel(model) catch return error.InvalidModel;
        result.model = try alloc.dupe(u8, model);
    }
    if (raw.effort) |effort| {
        result.effort = types.ReasoningEffort.parse(effort) orelse return error.InvalidEffort;
    }
    result.fast_mode = raw.fast_mode;
    result.max_steps = raw.max_steps;
    if (raw.first_call_tool_choice) |choice| {
        result.first_call_tool_choice = std.meta.stringToEnum(types.ToolChoice, choice) orelse
            return error.InvalidToolChoice;
    }
    if (raw.enabled_tools) |names| {
        result.enabled_tools = try dupeUniqueNames(alloc, names);
    }
}

fn parsePrompt(
    alloc: Allocator,
    result: *ParsedDocument,
    raw: RawPrompt,
    source: InputSource,
) !void {
    const raw_parts = raw.system_parts orelse return;
    if (raw_parts.len > max_system_prompt_parts) return error.TooManySystemPromptParts;

    const parts = try alloc.alloc(SystemPart, raw_parts.len);
    var initialized: usize = 0;
    errdefer {
        for (parts[0..initialized]) |*part| part.deinit(alloc);
        alloc.free(parts);
    }

    var static_bytes: usize = 0;
    for (raw_parts, 0..) |part, index| {
        parts[index] = try parseSystemPart(alloc, part, source);
        initialized += 1;
        static_bytes = std.math.add(usize, static_bytes, switch (parts[index]) {
            .builtin => 0,
            .@"inline" => |text| text.len,
            .file => |file| file.content.len,
        }) catch return error.SystemPromptTooLarge;
        if (static_bytes > max_system_prompt_total_bytes) return error.SystemPromptTooLarge;
    }
    result.system_parts = parts;
}

fn parseSystemPart(alloc: Allocator, raw: RawSystemPart, source: InputSource) !SystemPart {
    if (std.mem.eql(u8, raw.type, "builtin")) {
        if (raw.id == null or !std.mem.eql(u8, raw.id.?, "default") or
            raw.path != null or raw.text != null)
        {
            return error.InvalidSystemPromptPart;
        }
        return .builtin;
    }
    if (std.mem.eql(u8, raw.type, "inline")) {
        if (raw.text == null or raw.id != null or raw.path != null) {
            return error.InvalidSystemPromptPart;
        }
        try validatePromptText(raw.text.?);
        return .{ .@"inline" = try alloc.dupe(u8, raw.text.?) };
    }
    if (std.mem.eql(u8, raw.type, "file")) {
        if (raw.path == null or raw.id != null or raw.text != null) {
            return error.InvalidSystemPromptPart;
        }
        const declaring_file = switch (source) {
            .regular_file => |path| path,
            .non_file => return error.FilePartRequiresRegularConfigSource,
        };
        const content = try readPromptFile(alloc, declaring_file, raw.path.?);
        errdefer alloc.free(content);
        return .{ .file = .{
            .path = try alloc.dupe(u8, raw.path.?),
            .content = content,
        } };
    }
    return error.InvalidSystemPromptPart;
}

fn readPromptFile(alloc: Allocator, declaring_file: []const u8, raw_path: []const u8) ![]u8 {
    if (!validPathText(raw_path)) return error.UnsafePromptFile;
    const base = std.fs.path.dirname(declaring_file) orelse ".";
    const resolved = try std.fs.path.resolve(alloc, &.{ base, raw_path });
    defer alloc.free(resolved);

    var file = io_mod.openExistingRegularFile(std.Io.Dir.cwd(), resolved, .read_only) catch |err| switch (err) {
        error.FileNotFound => return error.PromptFileMissing,
        else => return error.UnsafePromptFile,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file) return error.UnsafePromptFile;
    if (stat.size > max_system_prompt_part_bytes) return error.SystemPromptPartTooLarge;
    const content = io_mod.readFileToEnd(alloc, &file, max_system_prompt_part_bytes + 1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SystemPromptPartTooLarge,
    };
    errdefer alloc.free(content);
    if (content.len > max_system_prompt_part_bytes) return error.SystemPromptPartTooLarge;
    try validatePromptText(content);
    return content;
}

fn validatePromptText(text: []const u8) !void {
    if (text.len > max_system_prompt_part_bytes) return error.SystemPromptPartTooLarge;
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.findScalar(u8, text, 0) != null) {
        return error.InvalidSystemPromptText;
    }
}

fn parseRuntime(alloc: Allocator, result: *ParsedDocument, raw: RawRuntime) !void {
    if (raw.permission_mode) |mode| {
        result.permission_mode = std.meta.stringToEnum(types.PermissionMode, mode) orelse
            return error.InvalidPermissionMode;
    }
    if (raw.max_tool_result_bytes) |value| {
        if (value < tool_result_limits.min_configured_tool_result_bytes) {
            return error.InvalidMaxToolResultBytes;
        }
        result.max_tool_result_bytes = value;
    }
    result.context_enabled = raw.context_enabled;
    if (raw.context_limits) |limits| result.context_limit_overrides = try parseContextLimits(limits);
    if (raw.additional_directories) |paths| {
        if (paths.len > workspace_access.max_additional_directories) return error.TooManyAdditionalDirectories;
        for (paths, 0..) |path, index| {
            if (!validPathText(path)) return error.InvalidAdditionalDirectory;
            for (paths[0..index]) |prior| {
                if (std.mem.eql(u8, path, prior)) return error.DuplicateAdditionalDirectory;
            }
        }
        result.additional_directories = try dupeStrings(alloc, paths);
    }
}

fn parseContextLimits(raw: RawContextLimits) !context_limits.Overrides {
    var result = context_limits.Overrides{};
    inline for (std.meta.fields(RawContextLimits)) |field| {
        if (@field(raw, field.name)) |value| {
            const name = context_limits.Name.parse(field.name) orelse unreachable;
            result.set(name, .{
                .value = try parseContextLimitValue(value),
                .source = .compiled_default,
            });
        }
    }
    return result;
}

fn parseContextLimitValue(value: std.json.Value) !context_limits.Value {
    return switch (value) {
        .integer => |integer| .{
            .bytes = std.math.cast(usize, integer) orelse return error.InvalidContextLimit,
        },
        .string => |string| if (std.mem.eql(u8, string, "off"))
            .off
        else
            error.InvalidContextLimit,
        else => error.InvalidContextLimit,
    };
}

fn dupeUniqueNames(alloc: Allocator, names: []const []const u8) ![][]u8 {
    for (names, 0..) |name, index| {
        if (name.len == 0 or !std.unicode.utf8ValidateSlice(name) or
            std.mem.findScalar(u8, name, 0) != null)
        {
            return error.InvalidToolName;
        }
        for (names[0..index]) |prior| {
            if (std.mem.eql(u8, name, prior)) return error.DuplicateToolName;
        }
    }
    return dupeStrings(alloc, names);
}

fn validPathText(path: []const u8) bool {
    return path.len > 0 and path.len <= std.fs.max_path_bytes and
        std.unicode.utf8ValidateSlice(path) and std.mem.findScalar(u8, path, 0) == null;
}

fn dupeStrings(alloc: Allocator, values: []const []const u8) ![][]u8 {
    const owned = try alloc.alloc([]u8, values.len);
    var initialized: usize = 0;
    errdefer {
        for (owned[0..initialized]) |value| alloc.free(value);
        alloc.free(owned);
    }
    for (values, 0..) |value, index| {
        owned[index] = try alloc.dupe(u8, value);
        initialized += 1;
    }
    return owned;
}

fn freeStrings(alloc: Allocator, values: [][]u8) void {
    for (values) |value| alloc.free(value);
    alloc.free(values);
}

test "strict explicit document accepts versioned retained fields" {
    var parsed = try parseDocument(
        std.testing.allocator,
        "{\"schema_version\":1,\"agent\":{\"provider\":\"gateway\",\"model\":\"openai/gpt-5.4\",\"fast_mode\":true,\"enabled_tools\":[\"read_file\"]},\"runtime\":{\"permission_mode\":\"auto\",\"context_limits\":{\"skill_chunk_bytes\":4096}}}",
        .non_file,
    );
    defer parsed.deinit(std.testing.allocator);

    try std.testing.expectEqual(model_provider.ProviderId.gateway, parsed.provider.?);
    try std.testing.expectEqualStrings("openai/gpt-5.4", parsed.model.?);
    try std.testing.expectEqual(true, parsed.fast_mode.?);
    try std.testing.expectEqualStrings("read_file", parsed.enabled_tools.?[0]);
    try std.testing.expectEqual(types.PermissionMode.auto, parsed.permission_mode.?);
    try std.testing.expectEqual(
        @as(usize, 4096),
        parsed.context_limit_overrides.?.get(.skill_chunk_bytes).?.effectiveBytes(),
    );
}

test "published schema is valid JSON and describes the strict root" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json_schema, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(false, parsed.value.object.get("additionalProperties").?.bool);
    try std.testing.expect(parsed.value.object.get("$defs") != null);
}

test "strict explicit document rejects unknown duplicate null and unsupported version" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.UnknownField,
        parseDocument(alloc, "{\"schema_version\":1,\"unknown\":true}", .non_file),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseDocument(alloc, "{\"schema_version\":1,\"schema_version\":1}", .non_file),
    );
    try std.testing.expectError(
        error.NullUnsupported,
        parseDocument(alloc, "{\"schema_version\":1,\"agent\":{\"model\":null}}", .non_file),
    );
    try std.testing.expectError(
        error.UnsupportedSchemaVersion,
        parseDocument(alloc, "{\"schema_version\":2}", .non_file),
    );
}

test "non-file explicit sources reject prompt file parts" {
    try std.testing.expectError(
        error.FilePartRequiresRegularConfigSource,
        parseDocument(
            std.testing.allocator,
            "{\"schema_version\":1,\"prompt\":{\"system_parts\":[{\"type\":\"file\",\"path\":\"prompt.md\"}]}}",
            .non_file,
        ),
    );
}

test "system prompt part shapes and unique arrays are strict" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidSystemPromptPart,
        parseDocument(
            alloc,
            "{\"schema_version\":1,\"prompt\":{\"system_parts\":[{\"type\":\"builtin\",\"id\":\"default\",\"text\":\"extra\"}]}}",
            .non_file,
        ),
    );
    try std.testing.expectError(
        error.DuplicateToolName,
        parseDocument(
            alloc,
            "{\"schema_version\":1,\"agent\":{\"enabled_tools\":[\"read_file\",\"read_file\"]}}",
            .non_file,
        ),
    );
}

test "typed overrides share strict document parsing" {
    var scalar = try parseOverride(std.testing.allocator, "agent.fast_mode", "true");
    defer scalar.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, scalar.fast_mode.?);

    var structured = try parseOverride(
        std.testing.allocator,
        "agent.enabled_tools",
        "[\"read_file\",\"grep_files\"]",
    );
    defer structured.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("grep_files", structured.enabled_tools.?[1]);

    try std.testing.expectError(
        error.FilePartRequiresRegularConfigSource,
        parseOverride(
            std.testing.allocator,
            "prompt.system_parts",
            "[{\"type\":\"file\",\"path\":\"prompt.md\"}]",
        ),
    );
    try std.testing.expectError(
        error.UnknownConfigField,
        parseOverride(std.testing.allocator, "agent.unknown", "true"),
    );
}

test "strict document ownership cleans every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var parsed = try parseDocument(
                alloc,
                "{\"schema_version\":1,\"agent\":{\"model\":\"openai/gpt-5.4\",\"enabled_tools\":[\"read_file\",\"grep_files\"]},\"prompt\":{\"system_parts\":[{\"type\":\"inline\",\"text\":\"policy\"}]},\"runtime\":{\"additional_directories\":[\"/tmp/one\",\"/tmp/two\"]}}",
                .non_file,
            );
            defer parsed.deinit(alloc);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "owned launch policy projections clean every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            var policy = OwnedLaunchPolicy{};
            defer policy.deinit(alloc);
            policy.enabled_tools = try dupeStrings(alloc, &.{"read_file"});
            const text = try alloc.dupe(u8, "policy");
            var text_owned = true;
            errdefer if (text_owned) alloc.free(text);
            const parts = try alloc.alloc(SystemPart, 1);
            var parts_owned = true;
            errdefer if (parts_owned) alloc.free(parts);
            parts[0] = .{ .@"inline" = text };
            policy.system_parts = parts;
            text_owned = false;
            parts_owned = false;
            try policy.composeSystemPrompt(alloc, "builtin");
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
