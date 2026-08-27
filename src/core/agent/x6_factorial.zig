const std = @import("std");
const io_mod = @import("../shared/io.zig");

pub const efficiency_environment_variable = "FX_EXPERIMENT_X6_EFFICIENCY";
pub const compaction_environment_variable = "FX_EXPERIMENT_X6_COMPACTION";

pub const efficiency_prompt =
    "Efficiency policy: use the latest tool result as evidence. Do not repeat an exact failed tool call without an intervening successful action; inspect the failure and change arguments, tool, or strategy. Stop searching when equivalent reads or searches stop producing new evidence, and summarize the best-supported result or blocker.";

pub const Arm = enum { control, active };

pub const Arms = struct {
    efficiency: Arm = .control,
    compaction: Arm = .control,

    pub fn prompt(self: Arms) []const u8 {
        return if (self.efficiency == .active) efficiency_prompt else "";
    }
};

pub const ParseError = error{
    InvalidX6EfficiencyArm,
    InvalidX6CompactionArm,
};

fn parseArm(raw: ?[]const u8, comptime parse_error: ParseError) ParseError!Arm {
    const value = raw orelse return .control;
    return std.meta.stringToEnum(Arm, value) orelse parse_error;
}

pub fn parse(efficiency: ?[]const u8, compaction: ?[]const u8) ParseError!Arms {
    return .{
        .efficiency = try parseArm(efficiency, error.InvalidX6EfficiencyArm),
        .compaction = try parseArm(compaction, error.InvalidX6CompactionArm),
    };
}

pub fn currentArms() ParseError!Arms {
    return parse(
        io_mod.getenv(efficiency_environment_variable),
        io_mod.getenv(compaction_environment_variable),
    );
}

test "X6 factorial defaults to behavior-neutral control" {
    const arms = try parse(null, null);
    try std.testing.expectEqual(Arm.control, arms.efficiency);
    try std.testing.expectEqual(Arm.control, arms.compaction);
    try std.testing.expectEqualStrings("", arms.prompt());
}

test "X6 factorial independently selects efficiency and compaction" {
    const efficiency = try parse("active", "control");
    try std.testing.expectEqual(Arm.active, efficiency.efficiency);
    try std.testing.expectEqual(Arm.control, efficiency.compaction);
    try std.testing.expectEqualStrings(efficiency_prompt, efficiency.prompt());

    const compaction = try parse("control", "active");
    try std.testing.expectEqual(Arm.control, compaction.efficiency);
    try std.testing.expectEqual(Arm.active, compaction.compaction);
    try std.testing.expectEqualStrings("", compaction.prompt());
}

test "X6 factorial rejects unknown arms" {
    try std.testing.expectError(error.InvalidX6EfficiencyArm, parse("on", "control"));
    try std.testing.expectError(error.InvalidX6CompactionArm, parse("control", "compact"));
}
