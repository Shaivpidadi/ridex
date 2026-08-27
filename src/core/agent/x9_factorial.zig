const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const editor_environment_variable = "FX_EXPERIMENT_X9_EDITOR";
pub const provider_retry_environment_variable = "FX_EXPERIMENT_X9_PROVIDER_RETRY";

pub const EditorArm = enum { control, patch_v3 };
pub const ProviderRetryArm = enum { control, adaptive_v1 };

pub const ProviderRetryPolicy = struct {
    arm: ProviderRetryArm = .control,

    pub fn attemptLimit(self: ProviderRetryPolicy, configured_limit: usize) usize {
        const normalized = if (configured_limit == 0) 1 else configured_limit;
        return switch (self.arm) {
            .control => normalized,
            .adaptive_v1 => @min(normalized, adaptive_attempt_limit),
        };
    }

    pub fn responseHeadTimeoutMs(
        self: ProviderRetryPolicy,
        zero_based_attempt: usize,
    ) ?i64 {
        return switch (self.arm) {
            .control => null,
            .adaptive_v1 => adaptive_response_head_timeout_ms[
                @min(zero_based_attempt, adaptive_response_head_timeout_ms.len - 1)
            ],
        };
    }
};

pub const Arms = struct {
    editor: EditorArm = .control,
    provider_retry: ProviderRetryArm = .control,

    pub fn additionalVisibleToolNames(self: Arms) ?[]const []const u8 {
        return if (self.editor == .patch_v3) patch_tool_names[0..] else null;
    }

    pub fn blockedToolNames(self: Arms) ?[]const []const u8 {
        return if (self.editor == .patch_v3) exact_edit_tool_names[0..] else null;
    }

    pub fn providerRetryPolicy(self: Arms) ProviderRetryPolicy {
        return .{ .arm = self.provider_retry };
    }
};

pub const adaptive_attempt_limit: usize = 3;
pub const adaptive_response_head_timeout_ms = [_]i64{ 30_000, 60_000, 120_000 };

const patch_tool_names = [_][]const u8{"apply_patch"};
const exact_edit_tool_names = [_][]const u8{"edit_file"};

pub const ParseError = error{
    InvalidX9EditorArm,
    InvalidX9ProviderRetryArm,
};

pub fn parse(
    editor: ?[]const u8,
    provider_retry: ?[]const u8,
) ParseError!Arms {
    return .{
        .editor = if (editor) |value|
            std.meta.stringToEnum(EditorArm, value) orelse
                return error.InvalidX9EditorArm
        else
            .control,
        .provider_retry = if (provider_retry) |value|
            std.meta.stringToEnum(ProviderRetryArm, value) orelse
                return error.InvalidX9ProviderRetryArm
        else
            .control,
    };
}

pub fn currentArms() ParseError!Arms {
    return parse(
        io_mod.getenv(editor_environment_variable),
        io_mod.getenv(provider_retry_environment_variable),
    );
}

test "X9 factorial defaults to behavior-neutral control" {
    const arms = try parse(null, null);
    try std.testing.expectEqual(EditorArm.control, arms.editor);
    try std.testing.expectEqual(ProviderRetryArm.control, arms.provider_retry);
    try std.testing.expect(arms.additionalVisibleToolNames() == null);
    try std.testing.expect(arms.blockedToolNames() == null);
    try std.testing.expectEqual(@as(usize, 10), arms.providerRetryPolicy().attemptLimit(10));
    try std.testing.expect(arms.providerRetryPolicy().responseHeadTimeoutMs(0) == null);
}

test "X9 patch arm replaces exact edit without changing retry policy" {
    const arms = try parse("patch_v3", null);
    try std.testing.expectEqualStrings("apply_patch", arms.additionalVisibleToolNames().?[0]);
    try std.testing.expectEqualStrings("edit_file", arms.blockedToolNames().?[0]);
    try std.testing.expectEqual(@as(usize, 10), arms.providerRetryPolicy().attemptLimit(10));
}

test "X9 adaptive provider policy uses three escalating head deadlines" {
    const arms = try parse(null, "adaptive_v1");
    const policy = arms.providerRetryPolicy();
    try std.testing.expectEqual(@as(usize, 3), policy.attemptLimit(10));
    try std.testing.expectEqual(@as(usize, 2), policy.attemptLimit(2));
    try std.testing.expectEqual(@as(?i64, 30_000), policy.responseHeadTimeoutMs(0));
    try std.testing.expectEqual(@as(?i64, 60_000), policy.responseHeadTimeoutMs(1));
    try std.testing.expectEqual(@as(?i64, 120_000), policy.responseHeadTimeoutMs(2));
    try std.testing.expectEqual(@as(?i64, 120_000), policy.responseHeadTimeoutMs(9));
}

test "X9 factorial rejects unknown arms" {
    try std.testing.expectError(error.InvalidX9EditorArm, parse("patch", null));
    try std.testing.expectError(
        error.InvalidX9ProviderRetryArm,
        parse(null, "adaptive"),
    );
}
