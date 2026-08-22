//! Native system URL opener behind the host.UrlOpener contract. Opens a URL
//! in the user's default browser via the platform launcher; shared by
//! authentication and user-consented URL flows.

const std = @import("std");
const builtin = @import("builtin");
const debug_trace = @import("../shared/debug_trace.zig");
const host = @import("host.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

pub const native_opener = host.UrlOpener{
    .open_fn = openUrlForHost,
};

fn openUrlForHost(_: ?*anyopaque, alloc: Allocator, url: []const u8) host.UrlOpenError!bool {
    return openUrl(alloc, url);
}

fn openUrl(alloc: Allocator, url: []const u8) Allocator.Error!bool {
    return launchUrl(alloc, url, builtin.os.tag, .{}) == .opened;
}

const LaunchResult = struct {
    term: std.process.Child.Term,
};

const LaunchFn = *const fn (*anyopaque, Allocator, []const []const u8) anyerror!LaunchResult;

const Launcher = struct {
    ctx: *anyopaque = undefined,
    launch: LaunchFn = launchActual,
};

const LaunchOutcome = enum {
    opened,
    failed,
    unsupported,
};

fn launchActual(_: *anyopaque, arena: Allocator, argv: []const []const u8) anyerror!LaunchResult {
    const result = try std.process.run(arena, io_mod.getIo(), .{ .argv = argv });
    defer arena.free(result.stdout);
    defer arena.free(result.stderr);
    return .{ .term = result.term };
}

fn launchUrl(
    alloc: Allocator,
    url: []const u8,
    os_tag: std.Target.Os.Tag,
    launcher: Launcher,
) LaunchOutcome {
    var macos_argv = [_][]const u8{ "open", url };
    var linux_argv = [_][]const u8{ "xdg-open", url };
    const argv: []const []const u8 = switch (os_tag) {
        .macos => &macos_argv,
        .linux => &linux_argv,
        else => return .unsupported,
    };

    const result = launcher.launch(launcher.ctx, alloc, argv) catch |err| {
        debug_trace.logf("core", "url opener launcher failed err={s}", .{@errorName(err)});
        return .failed;
    };
    switch (result.term) {
        .exited => |code| if (code == 0) return .opened,
        else => {},
    }

    logUnsuccessfulTerm(result.term);
    return .failed;
}

fn logUnsuccessfulTerm(term: std.process.Child.Term) void {
    switch (term) {
        .exited => |code| debug_trace.logf("core", "url opener unsuccessful term=exited exit_code={d}", .{code}),
        .signal => |sig| debug_trace.logf("core", "url opener unsuccessful term=signal signal={d}", .{@intFromEnum(sig)}),
        .stopped => |sig| debug_trace.logf("core", "url opener unsuccessful term=stopped signal={d}", .{@intFromEnum(sig)}),
        .unknown => |code| debug_trace.logf("core", "url opener unsuccessful term=unknown status={d}", .{code}),
    }
}

/// Set when a browser hand-off should not pull the terminal back to the front.
const no_focus_terminal_env = "FX_NO_FOCUS_TERMINAL";

const EnvLookupFn = *const fn ([]const u8) ?[]const u8;

/// Brings the terminal application fx is running under back to the front.
///
/// Best effort by design: a browser page cannot focus another application, so
/// the return trip after an OAuth redirect has to be initiated from this side.
/// Failing to focus is never worth failing a sign-in over, so the outcome is
/// traced and discarded.
pub fn focusOwningTerminal(alloc: Allocator) void {
    _ = focusTerminal(alloc, builtin.os.tag, .{}, lookupEnv);
}

/// Mirrors `io_mod.envFlagEnabled` against an injectable lookup so the focus
/// path stays testable without touching the real environment.
fn isEnabled(env: EnvLookupFn, key: []const u8) bool {
    const raw = env(key) orelse return false;
    const value = std.mem.trim(u8, raw, " \t\r\n");
    if (value.len == 0) return false;
    const affirmative = [_][]const u8{ "1", "true", "yes", "on" };
    for (affirmative) |word| {
        if (std.ascii.eqlIgnoreCase(value, word)) return true;
    }
    return false;
}

fn lookupEnv(name: []const u8) ?[]const u8 {
    return io_mod.getenv(name);
}

/// Bundle identifiers for terminals that do not export `__CFBundleIdentifier`,
/// which happens when the shell was reached over SSH or reattached under a
/// multiplexer.
fn bundleIdForTermProgram(term_program: []const u8) ?[]const u8 {
    const known = [_]struct { term: []const u8, bundle: []const u8 }{
        .{ .term = "Apple_Terminal", .bundle = "com.apple.Terminal" },
        .{ .term = "iTerm.app", .bundle = "com.googlecode.iterm2" },
        .{ .term = "WarpTerminal", .bundle = "dev.warp.Warp-Stable" },
        .{ .term = "ghostty", .bundle = "com.mitchellh.ghostty" },
        .{ .term = "vscode", .bundle = "com.microsoft.VSCode" },
        .{ .term = "Hyper", .bundle = "co.zeit.hyper" },
        .{ .term = "kitty", .bundle = "net.kovidgoyal.kitty" },
        .{ .term = "WezTerm", .bundle = "com.github.wez.wezterm" },
        .{ .term = "Tabby", .bundle = "org.tabby" },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, entry.term, term_program)) return entry.bundle;
    }
    return null;
}

/// launchd stamps `__CFBundleIdentifier` with the application that started the
/// process tree and children inherit it, so it names the real owning terminal
/// even when several are running.
fn resolveTerminalBundleId(env: EnvLookupFn) ?[]const u8 {
    if (env(__cf_bundle_identifier_env)) |bundle| {
        if (bundle.len > 0) return bundle;
    }
    if (env("TERM_PROGRAM")) |term_program| return bundleIdForTermProgram(term_program);
    return null;
}

const __cf_bundle_identifier_env = "__CFBundleIdentifier";

fn focusTerminal(
    alloc: Allocator,
    os_tag: std.Target.Os.Tag,
    launcher: Launcher,
    env: EnvLookupFn,
) LaunchOutcome {
    // Linux window managers offer no portable way to raise a specific app, and
    // Windows has no launcher here at all.
    if (os_tag != .macos) return .unsupported;
    if (isEnabled(env, no_focus_terminal_env)) return .unsupported;
    const bundle_id = resolveTerminalBundleId(env) orelse return .unsupported;

    var argv = [_][]const u8{ "open", "-b", bundle_id };
    const result = launcher.launch(launcher.ctx, alloc, &argv) catch |err| {
        debug_trace.logf("core", "terminal focus launcher failed err={s}", .{@errorName(err)});
        return .failed;
    };
    switch (result.term) {
        .exited => |code| if (code == 0) return .opened,
        else => {},
    }
    logUnsuccessfulTerm(result.term);
    return .failed;
}

const MockLauncher = struct {
    argv_joined: std.ArrayList(u8) = .empty,
    result: anyerror!LaunchResult = .{ .term = .{ .exited = 0 } },

    fn launch(raw: *anyopaque, alloc: Allocator, argv: []const []const u8) anyerror!LaunchResult {
        const self: *MockLauncher = @ptrCast(@alignCast(raw));
        for (argv, 0..) |arg, i| {
            if (i > 0) try self.argv_joined.append(alloc, ' ');
            try self.argv_joined.appendSlice(alloc, arg);
        }
        return self.result;
    }

    fn launcher(self: *MockLauncher) Launcher {
        return .{ .ctx = self, .launch = launch };
    }

    fn deinit(self: *MockLauncher, alloc: Allocator) void {
        self.argv_joined.deinit(alloc);
    }
};

test "url opener selects the platform launcher argv" {
    const alloc = std.testing.allocator;

    var macos = MockLauncher{};
    defer macos.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .macos, macos.launcher()));
    try std.testing.expectEqualStrings("open http://localhost:3000", macos.argv_joined.items);

    var linux = MockLauncher{};
    defer linux.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, launchUrl(alloc, "http://localhost:3000", .linux, linux.launcher()));
    try std.testing.expectEqualStrings("xdg-open http://localhost:3000", linux.argv_joined.items);
}

test "url opener reports unsupported platforms without launching" {
    const alloc = std.testing.allocator;
    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, launchUrl(alloc, "http://x", .windows, mock.launcher()));
    try std.testing.expectEqualStrings("", mock.argv_joined.items);
}

test "url opener treats nonzero exit, bad terms, and launch errors as failed" {
    const alloc = std.testing.allocator;

    var nonzero = MockLauncher{ .result = .{ .term = .{ .exited = 3 } } };
    defer nonzero.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .macos, nonzero.launcher()));

    var signaled = MockLauncher{ .result = .{ .term = .{ .signal = @enumFromInt(2) } } };
    defer signaled.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .macos, signaled.launcher()));

    var erroring = MockLauncher{ .result = error.SpawnFailed };
    defer erroring.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.failed, launchUrl(alloc, "http://x", .linux, erroring.launcher()));
}

const MockEnv = struct {
    var bundle: ?[]const u8 = null;
    var term_program: ?[]const u8 = null;
    var suppressed: bool = false;

    var suppress_value: []const u8 = "1";

    fn lookup(name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, no_focus_terminal_env)) return if (suppressed) suppress_value else null;
        if (std.mem.eql(u8, name, __cf_bundle_identifier_env)) return bundle;
        if (std.mem.eql(u8, name, "TERM_PROGRAM")) return term_program;
        return null;
    }

    fn reset() void {
        bundle = null;
        term_program = null;
        suppressed = false;
        suppress_value = "1";
    }
};

test "terminal focus prefers the inherited bundle identifier" {
    const alloc = std.testing.allocator;
    MockEnv.reset();
    MockEnv.bundle = "dev.warp.Warp-Stable";
    MockEnv.term_program = "Apple_Terminal";

    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, focusTerminal(alloc, .macos, mock.launcher(), MockEnv.lookup));
    try std.testing.expectEqualStrings("open -b dev.warp.Warp-Stable", mock.argv_joined.items);
}

test "terminal focus falls back to TERM_PROGRAM when the bundle id is absent" {
    const alloc = std.testing.allocator;
    MockEnv.reset();
    MockEnv.term_program = "iTerm.app";

    var mock = MockLauncher{};
    defer mock.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.opened, focusTerminal(alloc, .macos, mock.launcher(), MockEnv.lookup));
    try std.testing.expectEqualStrings("open -b com.googlecode.iterm2", mock.argv_joined.items);
}

test "terminal focus stays put when suppressed, unknown, or off macOS" {
    const alloc = std.testing.allocator;

    MockEnv.reset();
    MockEnv.bundle = "dev.warp.Warp-Stable";
    MockEnv.suppressed = true;
    var suppressed = MockLauncher{};
    defer suppressed.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, focusTerminal(alloc, .macos, suppressed.launcher(), MockEnv.lookup));
    try std.testing.expectEqualStrings("", suppressed.argv_joined.items);

    MockEnv.reset();
    MockEnv.term_program = "some-unknown-terminal";
    var unknown = MockLauncher{};
    defer unknown.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, focusTerminal(alloc, .macos, unknown.launcher(), MockEnv.lookup));
    try std.testing.expectEqualStrings("", unknown.argv_joined.items);

    MockEnv.reset();
    MockEnv.bundle = "dev.warp.Warp-Stable";
    var linux = MockLauncher{};
    defer linux.deinit(alloc);
    try std.testing.expectEqual(LaunchOutcome.unsupported, focusTerminal(alloc, .linux, linux.launcher(), MockEnv.lookup));
    try std.testing.expectEqualStrings("", linux.argv_joined.items);
}

test "terminal focus ignores an empty or negative suppression value" {
    const alloc = std.testing.allocator;
    for ([_][]const u8{ "", "0", "false", "off" }) |value| {
        MockEnv.reset();
        MockEnv.bundle = "dev.warp.Warp-Stable";
        MockEnv.suppressed = true;
        MockEnv.suppress_value = value;

        var mock = MockLauncher{};
        defer mock.deinit(alloc);
        try std.testing.expectEqual(
            LaunchOutcome.opened,
            focusTerminal(alloc, .macos, mock.launcher(), MockEnv.lookup),
        );
        try std.testing.expectEqualStrings("open -b dev.warp.Warp-Stable", mock.argv_joined.items);
    }
    MockEnv.reset();
}
