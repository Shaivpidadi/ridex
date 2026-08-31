const std = @import("std");
const builtin_skills = @import("../../builtins/skills.zig");
const context_limits = @import("../../core/config/context_limits.zig");
const lexical_relevance = @import("../../core/shared/lexical_relevance.zig");
const result_store = @import("../../core/session/result_store.zig");
const capability_retrieval = @import("../../core/tooling/capability_retrieval.zig");
const skill_runtime = @import("../../core/skills/skill_runtime.zig");
const tool_args = @import("../../core/tooling/tool_args.zig");
const tool_dispatch = @import("../../core/tooling/tool_dispatch.zig");
const tool_result_limits = @import("../../core/tooling/tool_result_limits.zig");

const Allocator = std.mem.Allocator;
const legacy_result_limit: usize = 8;

const Input = tool_args.OwnedSearchQueryInput;

const ProjectionCheck = union(enum) {
    valid,
    invalid,
    identity_changed: usize,
};

pub fn decode(
    ctx: tool_dispatch.DispatchContext,
    args_json: []const u8,
) tool_dispatch.DispatchError!tool_dispatch.DecodeResult {
    return switch (try tool_args.decodeOwnedSearchQuery(ctx.allocator, args_json, "skill_search")) {
        .failure => |body| .{ .failure = body },
        .input => |input| .{ .input = .{ .ptr = input, .deinit_fn = tool_args.destroyOwnedSearchQueryInput } },
    };
}

pub fn validate(
    _: tool_dispatch.DispatchContext,
    _: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!?[]u8 {
    return null;
}

pub fn call(
    ctx: tool_dispatch.DispatchContext,
    erased: tool_dispatch.ToolInput,
) tool_dispatch.DispatchError!tool_dispatch.ToolResult {
    const input = erased.as(Input);
    const model_output = searchRequest(
        ctx,
        .{
            .query = &input.prepared,
            .kind = .skill,
            .limit = legacy_result_limit,
        },
        @min(ctx.max_tool_result_bytes, result_store.large_result_threshold_bytes),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .failure = try std.fmt.allocPrint(
            ctx.allocator,
            "skill_search failed: {s}",
            .{@errorName(err)},
        ) },
    };
    return .{ .success = model_output };
}

pub fn searchRequest(
    ctx: tool_dispatch.DispatchContext,
    request: capability_retrieval.Request,
    max_bytes: usize,
) ![]u8 {
    var discovery = try builtin_skills.loadVisibleSkillsForTool(
        ctx.allocator,
        ctx.workspace_root,
        ctx.skills_dir,
    );
    defer discovery.deinit(ctx.allocator);
    skill_runtime.traceDiagnostics("skill_search", discovery.diagnostics);
    try reportDiagnostics(ctx, discovery.diagnostics);

    return renderProjectedSearch(
        ctx.allocator,
        request,
        discovery.skills,
        ctx.context_limits.skill_description_bytes,
        max_bytes,
    );
}

pub fn readsOnly(_: tool_dispatch.ToolInput) bool {
    return true;
}

pub fn isIrreversible(_: tool_dispatch.ToolInput) bool {
    return false;
}

fn reportDiagnostics(
    ctx: tool_dispatch.DispatchContext,
    diagnostics: []const skill_runtime.SkillDiagnostic,
) error{OutOfMemory}!void {
    if (diagnostics.len == 0) return;
    var notice: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer notice.deinit();
    skill_runtime.writeDiagnosticSummary(ctx.allocator, &notice.writer, diagnostics) catch
        return error.OutOfMemory;
    if (notice.written().len > 0) {
        try tool_dispatch.reportContextNotice(ctx, notice.written());
    }
}

fn renderProjectedSearch(
    alloc: Allocator,
    request: capability_retrieval.Request,
    skills: []const skill_runtime.Skill,
    description_limit: context_limits.Resolved,
    max_bytes: usize,
) ![]u8 {
    const documents = try alloc.alloc(capability_retrieval.Document, skills.len);
    defer alloc.free(documents);
    const document_skills = try alloc.alloc(*const skill_runtime.Skill, skills.len);
    defer alloc.free(document_skills);
    var identity_scratch_state = std.heap.ArenaAllocator.init(alloc);
    defer identity_scratch_state.deinit();
    const identity_scratch = identity_scratch_state.allocator();
    var document_count: usize = 0;
    for (skills) |*skill| {
        if (!try tool_result_limits.modelProjectionPreservesText(identity_scratch, skill.name) or
            !try tool_result_limits.modelProjectionPreservesText(identity_scratch, skill.path))
        {
            continue;
        }
        documents[document_count] = .{
            .identities = .{ skill.name, "" },
            .stable_key = skill.path,
            .primary = .{ skill.name, "", "", "" },
            .secondary = .{ skill.description, "", "" },
        };
        document_skills[document_count] = skill;
        document_count += 1;
    }
    var page = try capability_retrieval.retrieve(
        alloc,
        request,
        .skill,
        documents[0..document_count],
    );
    defer page.deinit(alloc);
    var retained_count = page.matches.len;

    while (true) {
        const next_cursor = try page.cursorAfter(alloc, retained_count);
        defer if (next_cursor) |cursor| alloc.free(cursor);
        const raw = renderRawSearch(
            alloc,
            page.matches[0..retained_count],
            document_skills[0..document_count],
            description_limit.effectiveBytes(),
            page.total_matches,
            next_cursor,
        ) catch |err| switch (err) {
            error.WriteFailed => return error.OutOfMemory,
            else => return err,
        };
        defer alloc.free(raw);

        const projected = @constCast(try tool_result_limits.prepareModelOutput(
            alloc,
            "skill_search",
            raw,
            max_bytes,
        ));
        errdefer alloc.free(projected);
        const check = try checkProjection(
            alloc,
            projected,
            page.matches[0..retained_count],
            document_skills[0..document_count],
            page.total_matches,
            next_cursor,
        );
        switch (check) {
            .valid => {
                const second = try tool_result_limits.prepareModelOutput(
                    alloc,
                    "skill_search",
                    projected,
                    max_bytes,
                );
                defer alloc.free(@constCast(second));
                if (std.mem.eql(u8, projected, second)) return projected;
            },
            .invalid, .identity_changed => {},
        }
        alloc.free(projected);
        retained_count = switch (check) {
            .identity_changed => |index| index,
            .valid, .invalid => if (retained_count > 0) retained_count - 1 else return error.SkillSearchResultLimitTooSmall,
        };
    }
}

fn renderRawSearch(
    alloc: Allocator,
    matches: []const capability_retrieval.Match,
    skills: []const *const skill_runtime.Skill,
    description_limit: usize,
    total_matches: usize,
    next_cursor: ?[]const u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll("{\"skills\":[");
    for (matches, 0..) |match, index| {
        if (index > 0) try out.writer.writeByte(',');
        const skill = skills[match.document_index];
        const description_end = context_limits.utf8PrefixLength(
            skill.description,
            description_limit,
        );
        try out.writer.writeAll("{\"name\":");
        try std.json.Stringify.value(skill.name, .{}, &out.writer);
        try out.writer.writeAll(",\"description\":");
        try std.json.Stringify.value(skill.description[0..description_end], .{}, &out.writer);
        try out.writer.writeAll(",\"location\":");
        try std.json.Stringify.value(skill.path, .{}, &out.writer);
        try out.writer.writeByte('}');
    }
    try out.writer.print("],\"count\":{d},\"total_matches\":{d},\"more_available\":{s},\"next_cursor\":", .{
        matches.len,
        total_matches,
        if (next_cursor != null) "true" else "false",
    });
    try std.json.Stringify.value(next_cursor, .{}, &out.writer);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

fn checkProjection(
    alloc: Allocator,
    projected: []const u8,
    matches: []const capability_retrieval.Match,
    skills: []const *const skill_runtime.Skill,
    total_matches: usize,
    next_cursor: ?[]const u8,
) !ProjectionCheck {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, projected, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .invalid,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .invalid;

    const skills_value = parsed.value.object.get("skills") orelse return .invalid;
    const count_value = parsed.value.object.get("count") orelse return .invalid;
    const total_value = parsed.value.object.get("total_matches") orelse return .invalid;
    const more_value = parsed.value.object.get("more_available") orelse return .invalid;
    const cursor_value = parsed.value.object.get("next_cursor") orelse return .invalid;
    if (skills_value != .array or
        count_value != .integer or
        count_value.integer < 0 or
        total_value != .integer or
        total_value.integer < 0 or
        more_value != .bool or
        more_value.bool != (next_cursor != null) or
        skills_value.array.items.len != matches.len)
    {
        return .invalid;
    }
    const count = std.math.cast(usize, count_value.integer) orelse return .invalid;
    const total = std.math.cast(usize, total_value.integer) orelse return .invalid;
    if (count != matches.len or total != total_matches) return .invalid;
    if (next_cursor) |expected| {
        if (cursor_value != .string or !std.mem.eql(u8, cursor_value.string, expected)) {
            return .invalid;
        }
    } else if (cursor_value != .null) return .invalid;

    for (skills_value.array.items, matches, 0..) |value, match, index| {
        if (value != .object) return .invalid;
        const name = value.object.get("name") orelse return .invalid;
        const description = value.object.get("description") orelse return .invalid;
        const location = value.object.get("location") orelse return .invalid;
        if (name != .string or description != .string or location != .string) return .invalid;
        const skill = skills[match.document_index];
        if (!std.mem.eql(u8, name.string, skill.name) or
            !std.mem.eql(u8, location.string, skill.path))
        {
            return .{ .identity_changed = index };
        }
    }
    return .valid;
}

test "skill search decoder enforces the shared query bounds" {
    const alloc = std.testing.allocator;
    const accepted_json = try std.fmt.allocPrint(alloc, "{{\"query\":\"{s}\"}}", .{"a" ** 4096});
    defer alloc.free(accepted_json);
    const accepted = try decode(.{ .allocator = alloc }, accepted_json);
    switch (accepted) {
        .input => |input| input.deinit(alloc),
        .failure => |message| {
            defer alloc.free(message);
            return error.TestUnexpectedResult;
        },
    }

    const too_long_json = try std.fmt.allocPrint(alloc, "{{\"query\":\"{s}\"}}", .{"a" ** 4097});
    defer alloc.free(too_long_json);
    const too_long = try decode(.{ .allocator = alloc }, too_long_json);
    switch (too_long) {
        .failure => |message| alloc.free(message),
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }

    var token_query: std.Io.Writer.Allocating = .init(alloc);
    defer token_query.deinit();
    for (0..65) |index| {
        if (index > 0) try token_query.writer.writeByte(' ');
        try token_query.writer.writeAll("token");
    }
    const too_many_tokens_json = try std.fmt.allocPrint(
        alloc,
        "{{\"query\":\"{s}\"}}",
        .{token_query.written()},
    );
    defer alloc.free(too_many_tokens_json);
    const too_many_tokens = try decode(.{ .allocator = alloc }, too_many_tokens_json);
    switch (too_many_tokens) {
        .failure => |message| alloc.free(message),
        .input => |input| {
            input.deinit(alloc);
            return error.TestUnexpectedResult;
        },
    }
}

test "skill search ranks metadata and returns final-projection-stable JSON" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "general", .description = "Review ordinary text", .path = "/skills/general/SKILL.md", .source = .workspace_fx },
        .{ .name = "fx-review", .description = "Review fx runtime changes", .path = "/skills/fx-review/SKILL.md", .source = .workspace_fx },
    };
    const query = try lexical_relevance.prepare("review fx runtime public");
    const output = try renderProjectedSearch(
        alloc,
        .{ .query = &query, .kind = .skill, .limit = legacy_result_limit },
        &skills,
        (context_limits.Values{}).skill_description_bytes,
        4096,
    );
    defer alloc.free(output);
    try std.testing.expect(std.mem.find(u8, output, "\"name\":\"fx-review\"") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"count\":1") != null);

    const projected_again = try tool_result_limits.prepareModelOutput(alloc, "skill_search", output, 4096);
    defer alloc.free(@constCast(projected_again));
    try std.testing.expectEqualStrings(output, projected_again);
}

test "skill search omits projected identities and permits redacted descriptions" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "unsafe-location", .description = "Review files", .path = "/skills/TOKEN=runtime-location-secret/SKILL.md", .source = .workspace_fx },
        .{ .name = "safe", .description = "API_KEY=runtime-description-secret", .path = "/skills/safe/SKILL.md", .source = .workspace_fx },
    };
    const query = try lexical_relevance.prepare("");
    const output = try renderProjectedSearch(
        alloc,
        .{ .query = &query, .kind = .skill, .limit = legacy_result_limit },
        &skills,
        (context_limits.Values{}).skill_description_bytes,
        4096,
    );
    defer alloc.free(output);
    try std.testing.expect(std.mem.find(u8, output, "unsafe-location") == null);
    try std.testing.expect(std.mem.find(u8, output, "\"name\":\"safe\"") != null);
    try std.testing.expect(std.mem.find(u8, output, "API_KEY=[redacted]") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"count\":1") != null);
    try std.testing.expect(std.mem.find(u8, output, "\"more_available\":false") != null);
}

test "skill search caps ranked entries and atomically omits byte overflow" {
    const alloc = std.testing.allocator;
    const skills = [_]skill_runtime.Skill{
        .{ .name = "one", .description = "x" ** 700, .path = "/skills/one/SKILL.md", .source = .workspace_fx },
        .{ .name = "two", .description = "two", .path = "/skills/two/SKILL.md", .source = .workspace_fx },
        .{ .name = "three", .description = "three", .path = "/skills/three/SKILL.md", .source = .workspace_fx },
        .{ .name = "four", .description = "four", .path = "/skills/four/SKILL.md", .source = .workspace_fx },
        .{ .name = "five", .description = "five", .path = "/skills/five/SKILL.md", .source = .workspace_fx },
        .{ .name = "six", .description = "six", .path = "/skills/six/SKILL.md", .source = .workspace_fx },
        .{ .name = "seven", .description = "seven", .path = "/skills/seven/SKILL.md", .source = .workspace_fx },
        .{ .name = "eight", .description = "eight", .path = "/skills/eight/SKILL.md", .source = .workspace_fx },
        .{ .name = "nine", .description = "nine", .path = "/skills/nine/SKILL.md", .source = .workspace_fx },
    };
    const query = try lexical_relevance.prepare("");
    const output = try renderProjectedSearch(
        alloc,
        .{ .query = &query, .kind = .skill, .limit = legacy_result_limit },
        &skills,
        (context_limits.Values{}).skill_description_bytes,
        1024,
    );
    defer alloc.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, output, .{});
    defer parsed.deinit();
    const entries = parsed.value.object.get("skills").?.array.items;
    try std.testing.expect(entries.len < legacy_result_limit);
    try std.testing.expect(entries.len > 0);
    try std.testing.expect(parsed.value.object.get("more_available").?.bool);
    try std.testing.expectEqual(@as(usize, @intCast(parsed.value.object.get("count").?.integer)), entries.len);
}

test "skill search decoder releases every accepted-input allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const decoded = try decode(.{ .allocator = alloc }, "{\"query\":\"review runtime\"}");
            switch (decoded) {
                .input => |input| input.deinit(alloc),
                .failure => |message| alloc.free(message),
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "skill search decoder releases every rejected-input allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const args_json = "{\"query\":\"" ++ ("token " ** 64) ++ "token\"}";
            const decoded = try decode(.{ .allocator = alloc }, args_json);
            switch (decoded) {
                .input => |input| input.deinit(alloc),
                .failure => |message| alloc.free(message),
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}

test "skill search projection releases every allocation failure" {
    const Case = struct {
        fn run(alloc: Allocator) !void {
            const skills = [_]skill_runtime.Skill{
                .{ .name = "unsafe", .description = "unsafe", .path = "/skills/TOKEN=runtime-location-secret/SKILL.md", .source = .workspace_fx },
                .{ .name = "oversized", .description = "x" ** 700, .path = "/skills/oversized/SKILL.md", .source = .workspace_fx },
                .{ .name = "three", .description = "three", .path = "/skills/three/SKILL.md", .source = .workspace_fx },
                .{ .name = "four", .description = "four", .path = "/skills/four/SKILL.md", .source = .workspace_fx },
                .{ .name = "five", .description = "five", .path = "/skills/five/SKILL.md", .source = .workspace_fx },
                .{ .name = "six", .description = "six", .path = "/skills/six/SKILL.md", .source = .workspace_fx },
                .{ .name = "seven", .description = "seven", .path = "/skills/seven/SKILL.md", .source = .workspace_fx },
                .{ .name = "eight", .description = "eight", .path = "/skills/eight/SKILL.md", .source = .workspace_fx },
                .{ .name = "nine", .description = "nine", .path = "/skills/nine/SKILL.md", .source = .workspace_fx },
            };
            const query = try lexical_relevance.prepare("");
            const output = try renderProjectedSearch(
                alloc,
                .{ .query = &query, .kind = .skill, .limit = legacy_result_limit },
                &skills,
                (context_limits.Values{}).skill_description_bytes,
                1024,
            );
            alloc.free(output);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Case.run, .{});
}
