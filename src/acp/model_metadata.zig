const std = @import("std");
const gateway = @import("../builtins/gateway.zig");
const catalog = @import("../core/gateway/model_catalog.zig");
const metadata = @import("../core/gateway/model_catalog_metadata.zig");
const capabilities = @import("../core/config/model_capabilities.zig");
const jsonrpc = @import("jsonrpc.zig");

const Allocator = std.mem.Allocator;
const max_bytes = 64 * 1024;
const max_entries = 64;
const max_lease_ms = 3_600_000;
pub const ValidationError = error{ InvalidModelMetadata, ModelMetadataExpired };
const ParseError = Allocator.Error || error{InvalidModelMetadata};

/// Connection-owned capability description, never credential or persistence authority.
pub const Snapshot = struct {
    model: []u8 = &.{},
    revision: []u8 = &.{},
    entries: std.ArrayList(catalog.ModelCatalogEntry) = .empty,
    received_at_ms: i64 = 0,
    expires_at_ms: i64 = 0,

    pub fn deinit(self: *Snapshot, alloc: Allocator) void {
        if (self.model.len > 0) alloc.free(self.model);
        if (self.revision.len > 0) alloc.free(self.revision);
        catalog.freeModelCatalog(alloc, &self.entries);
        self.* = .{};
    }

    pub fn resolve(self: *const Snapshot, model: []const u8, fallback: capabilities.Capabilities, now_ms: i64) ValidationError!capabilities.Capabilities {
        if (self.entries.items.len == 0 or !std.mem.eql(u8, self.model, model) or now_ms < self.received_at_ms) {
            return error.InvalidModelMetadata;
        }
        if (now_ms >= self.expires_at_ms) return error.ModelMetadataExpired;
        return capabilities.mergeCapabilities(fallback, metadata.fromCatalogEntry(self.entries.items[0]));
    }

    /// Returns an owned snapshot. Time is supplied by the connection boundary.
    pub fn parse(alloc: Allocator, value: std.json.Value, now_ms: i64) ParseError!Snapshot {
        if (value != .object) return error.InvalidModelMetadata;
        const model = value.object.get("model") orelse return error.InvalidModelMetadata;
        const revision = value.object.get("revision") orelse return error.InvalidModelMetadata;
        const lease = value.object.get("validForMs") orelse return error.InvalidModelMetadata;
        const data = value.object.get("data") orelse return error.InvalidModelMetadata;
        if (model != .string or model.string.len == 0 or model.string.len > 1024 or
            revision != .string or revision.string.len == 0 or revision.string.len > 128 or
            lease != .integer or lease.integer < 0 or lease.integer > max_lease_ms or
            data != .array or data.array.items.len == 0 or data.array.items.len > max_entries) return error.InvalidModelMetadata;
        for (data.array.items) |row| {
            if (row != .object) return error.InvalidModelMetadata;
            const id = row.object.get("id") orelse return error.InvalidModelMetadata;
            if (id != .string or !std.mem.eql(u8, id.string, model.string)) return error.InvalidModelMetadata;
        }
        // Bound serialization before the canonical parser allocates catalog rows.
        var buffer: [max_bytes]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buffer);
        std.json.Stringify.value(value, .{}, &writer) catch return error.InvalidModelMetadata;

        var result = Snapshot{};
        errdefer result.deinit(alloc);
        result.model = try alloc.dupe(u8, model.string);
        result.revision = try alloc.dupe(u8, revision.string);
        result.entries = gateway.parseModelCatalogForView(alloc, writer.buffered(), .full) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidModelMetadata,
        };
        // The catalog parser skips non-language or malformed rows. They cannot
        // establish a usable host description for this strict selected-model path.
        if (result.entries.items.len != data.array.items.len) return error.InvalidModelMetadata;
        result.received_at_ms = now_ms;
        result.expires_at_ms = std.math.add(i64, now_ms, lease.integer) catch return error.InvalidModelMetadata;
        return result;
    }
};

/// Omission retains the lease; an explicit value must be a valid envelope.
/// A non-null result is owned by the caller.
pub fn parseUpdate(alloc: Allocator, params: ?[]const u8, now_ms: i64) ParseError!?Snapshot {
    const raw = params orelse return null;
    const parsed = std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidModelMetadata,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidModelMetadata;
    const value = parsed.value.object.get("modelMetadata") orelse return null;
    return try Snapshot.parse(alloc, value, now_ms);
}

pub fn rpcError(err: ValidationError, model: []const u8) jsonrpc.RpcError {
    return .{
        .code = jsonrpc.ErrorCode.invalid_params,
        .message = switch (err) {
            error.InvalidModelMetadata => "Selected model metadata is missing, invalid, or does not match the active model",
            error.ModelMetadataExpired => "Selected model metadata lease has expired",
        },
        .data = .{
            .code = switch (err) {
                error.InvalidModelMetadata => "LIBFX_MODEL_METADATA_INVALID",
                error.ModelMetadataExpired => "LIBFX_MODEL_METADATA_EXPIRED",
            },
            .model = model,
            .capability = "modelMetadata",
        },
    };
}

test "selected metadata resolves token image effort and fast capabilities with a bounded lease" {
    const alloc = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc,
        \\{"model":"catalog/model","revision":"7","validForMs":1000,"data":[{"id":"catalog/model","type":"language","tags":["vision","file-input","tool-use"],"reasoning_options":[{"type":"effort","values":["high"]}],"fast_options":[{"type":"toggle"}],"context_window":128000,"max_tokens":4096}]}
    , .{});
    defer parsed.deinit();
    var snapshot = try Snapshot.parse(alloc, parsed.value, 100);
    defer snapshot.deinit(alloc);
    const actual = try snapshot.resolve("catalog/model", .{}, 101);
    try std.testing.expectEqual(@as(?u32, 128000), actual.context_window);
    try std.testing.expectEqual(@as(?u32, 4096), actual.max_output_tokens);
    try std.testing.expectEqual(capabilities.ImageInputSupport.native, actual.image_input_support);
    try std.testing.expect(actual.supports_fast_mode);
    try std.testing.expect(capabilities.reasoningEffortSupported(actual, .literal("high")));
    try std.testing.expectError(error.InvalidModelMetadata, snapshot.resolve("other", .{}, 101));
    try std.testing.expectError(error.InvalidModelMetadata, snapshot.resolve("catalog/model", .{}, 99));
    try std.testing.expectError(error.ModelMetadataExpired, snapshot.resolve("catalog/model", .{}, 1100));
    try std.testing.expectError(error.InvalidModelMetadata, (Snapshot{}).resolve("catalog/model", .{}, 0));
}

test "selected metadata rejects invalid envelopes empty skipped and wrong-model rows" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{
        "null", "{}",
        \\{"model":"one","revision":"1","validForMs":1000,"data":[]}
        ,
        \\{"model":"one","revision":"1","validForMs":1000,"data":[{"id":"other","type":"language"}]}
        ,
        \\{"model":"one","revision":"1","validForMs":1000,"data":[{"id":"one","type":"embedding"}]}
        ,
        \\{"model":"one","revision":"1","validForMs":1000,"data":[null]}
        ,
        \\{"model":"one","revision":"","validForMs":1000,"data":[{"id":"one"}]}
        ,
        \\{"model":"one","revision":"1","validForMs":3600001,"data":[{"id":"one"}]}
        ,
        \\{"model":"one","revision":"1","validForMs":-1,"data":[{"id":"one"}]}
        ,
        \\{"model":"one","revision":"1","validForMs":1.5,"data":[{"id":"one"}]}
        ,
    }) |raw| {
        const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{});
        defer parsed.deinit();
        try std.testing.expectError(error.InvalidModelMetadata, Snapshot.parse(alloc, parsed.value, 0));
    }
}

test "selected metadata enforces row and serialized byte limits" {
    const alloc = std.testing.allocator;
    var raw: std.Io.Writer.Allocating = .init(alloc);
    defer raw.deinit();
    try raw.writer.writeAll("{\"model\":\"one\",\"revision\":\"1\",\"validForMs\":3600000,\"data\":[");
    for (0..65) |index| {
        if (index > 0) try raw.writer.writeByte(',');
        try raw.writer.writeAll("{\"id\":\"one\"}");
    }
    try raw.writer.writeAll("]}");
    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw.written(), .{});
    defer parsed.deinit();
    try std.testing.expectError(error.InvalidModelMetadata, Snapshot.parse(alloc, parsed.value, 0));

    const padding = try alloc.alloc(u8, max_bytes);
    defer alloc.free(padding);
    @memset(padding, 'x');
    const oversized = try std.fmt.allocPrint(alloc, "{{\"model\":\"one\",\"revision\":\"1\",\"validForMs\":1,\"data\":[{{\"id\":\"one\",\"description\":\"{s}\"}}]}}", .{padding});
    defer alloc.free(oversized);
    const too_large = try std.json.parseFromSlice(std.json.Value, alloc, oversized, .{});
    defer too_large.deinit();
    try std.testing.expectError(error.InvalidModelMetadata, Snapshot.parse(alloc, too_large.value, 0));
}

test "selected metadata request updates distinguish omission from invalid null and expire zero leases" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try parseUpdate(alloc, null, 0) == null);
    try std.testing.expect(try parseUpdate(alloc, "{}", 0) == null);
    try std.testing.expectError(error.InvalidModelMetadata, parseUpdate(alloc, "{\"modelMetadata\":null}", 0));
    var snapshot = (try parseUpdate(alloc,
        \\{"modelMetadata":{"model":"one","revision":"1","validForMs":0,"data":[{"id":"one"}]}}
    , 0)).?;
    defer snapshot.deinit(alloc);
    try std.testing.expectError(error.ModelMetadataExpired, snapshot.resolve("one", .{}, 0));
    try std.testing.expectEqualStrings("LIBFX_MODEL_METADATA_EXPIRED", rpcError(error.ModelMetadataExpired, "one").data.?.code);
}

fn allocationFailureCase(alloc: Allocator) !void {
    var snapshot = (try parseUpdate(alloc,
        \\{"modelMetadata":{"model":"one","revision":"1","validForMs":1000,"data":[{"id":"one","type":"language","reasoning_options":[{"type":"effort","values":["high"]}],"pricing":{"web_search":"0.01"}}]}}
    , 0)).?;
    defer snapshot.deinit(alloc);
    _ = try snapshot.resolve("one", .{}, 1);
}

test "selected metadata releases owned storage across allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}
