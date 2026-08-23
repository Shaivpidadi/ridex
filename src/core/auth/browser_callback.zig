const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");

const Allocator = std.mem.Allocator;

const poll_ms: i32 = 100;
const socket_timeout_seconds: i64 = 30;
const silence_ms: i64 = 250;
const max_accepts_per_poll: usize = 16;

pub const Response = enum {
    ok,
    failed,
    unrelated,
};

pub fn ParseResult(comptime Callback: type) type {
    return union(enum) {
        accepted: Callback,
        unrelated,
        failed: anyerror,
    };
}

pub fn Accepted(comptime Callback: type) type {
    return struct {
        stream: std.Io.net.Stream,
        callback: Callback,

        pub fn deinit(self: *@This()) void {
            self.stream.close(io_mod.getIo());
            self.* = undefined;
        }

        pub fn respond(self: *@This(), outcome: Response) !void {
            try writeResponse(self.stream, outcome);
        }
    };
}

/// Drains the listener's queued connections and returns the first callback the
/// provider accepts, or null when no callback is ready during this poll.
///
/// Browsers may open an idle speculative connection or request unrelated paths
/// before sending the redirect. Those connections must not close the listener
/// or hold the real callback in the accept queue. Provider-specific parsing and
/// error classification stay in the adapter passed by the caller.
pub fn await(
    comptime Callback: type,
    comptime parse: fn (?*anyopaque, Allocator, []const u8) ParseResult(Callback),
    alloc: Allocator,
    listener: *std.Io.net.Server,
    parser_context: ?*anyopaque,
    cancel_flag: *std.atomic.Value(bool),
) !?Accepted(Callback) {
    var accepts: usize = 0;
    while (accepts < max_accepts_per_poll) : (accepts += 1) {
        if (!try listenerReady(listener, cancel_flag)) return null;
        var stream = listener.accept(io_mod.getIo()) catch |err| switch (err) {
            error.ConnectionAborted, error.WouldBlock => continue,
            else => return err,
        };
        var handed_off = false;
        defer if (!handed_off) stream.close(io_mod.getIo());
        setSocketTimeouts(stream.socket.handle);

        const maybe_target = readTarget(alloc, stream, cancel_flag) catch |err| switch (err) {
            error.Cancelled => return err,
            error.InvalidOAuthCallbackRequest, error.OAuthCallbackRequestTooLarge => {
                writeResponse(stream, .unrelated) catch {};
                continue;
            },
            else => return err,
        };
        const target = maybe_target orelse continue;
        defer alloc.free(target);

        const parsed = parse(parser_context, alloc, target);
        switch (parsed) {
            .accepted => |callback| {
                handed_off = true;
                return .{ .stream = stream, .callback = callback };
            },
            .unrelated => {
                writeResponse(stream, .unrelated) catch {};
                continue;
            },
            .failed => |err| {
                writeResponse(stream, .failed) catch {};
                return err;
            },
        }
    }
    return null;
}

fn listenerReady(
    listener: *std.Io.net.Server,
    cancel_flag: *std.atomic.Value(bool),
) !bool {
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    var fds = [_]std.posix.pollfd{.{
        .fd = listener.socket.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = try std.posix.poll(&fds, poll_ms);
    if (cancel_flag.load(.seq_cst)) return error.Cancelled;
    if (ready == 0) return false;
    if ((fds[0].revents & std.posix.POLL.IN) == 0) {
        return error.OAuthCallbackListenerFailed;
    }
    return true;
}

fn requestReadable(
    socket: std.posix.socket_t,
    cancel_flag: *std.atomic.Value(bool),
    deadline_ms: i64,
) !bool {
    while (true) {
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        const remaining_ms = deadline_ms - io_mod.milliTimestamp();
        const wait_ms: i32 = if (remaining_ms <= 0)
            0
        else
            @intCast(@min(remaining_ms, poll_ms));
        var fds = [_]std.posix.pollfd{.{
            .fd = socket,
            .events = std.posix.POLL.IN,
            .revents = 0,
        }};
        const ready = try std.posix.poll(&fds, wait_ms);
        if (cancel_flag.load(.seq_cst)) return error.Cancelled;
        if (ready != 0) return true;
        if (remaining_ms <= 0) return false;
    }
}

/// Reads the request target, or returns null when the connection remains
/// silent for the speculative-preconnect budget.
fn readTarget(
    alloc: Allocator,
    stream: std.Io.net.Stream,
    cancel_flag: *std.atomic.Value(bool),
) !?[]u8 {
    const deadline_ms = io_mod.milliTimestamp() + silence_ms;
    var socket_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io_mod.getIo(), &socket_buffer);
    var request_bytes: [16 * 1024]u8 = undefined;
    var request_len: usize = 0;
    var found_terminator = false;
    while (request_len < request_bytes.len) {
        if (reader.interface.bufferedLen() == 0 and
            !try requestReadable(stream.socket.handle, cancel_flag, deadline_ms))
        {
            return null;
        }
        request_bytes[request_len] = reader.interface.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (request_len == 0)
                null
            else
                error.InvalidOAuthCallbackRequest,
            error.ReadFailed => switch (reader.err orelse return error.ReadFailed) {
                error.ConnectionResetByPeer => return null,
                else => |read_err| return read_err,
            },
        };
        request_len += 1;
        if (std.mem.endsWith(u8, request_bytes[0..request_len], "\r\n\r\n")) {
            found_terminator = true;
            break;
        }
    }
    if (!found_terminator) return error.OAuthCallbackRequestTooLarge;
    const line_end = std.mem.find(u8, request_bytes[0..request_len], "\r\n") orelse
        return error.InvalidOAuthCallbackRequest;
    const request_line = request_bytes[0..line_end];
    if (!std.mem.startsWith(u8, request_line, "GET ")) {
        return error.InvalidOAuthCallbackRequest;
    }
    const target_end = std.mem.findScalarPos(u8, request_line, 4, ' ') orelse
        return error.InvalidOAuthCallbackRequest;
    return try alloc.dupe(u8, request_line[4..target_end]);
}

fn callbackPage(comptime title: []const u8, comptime detail: []const u8) []const u8 {
    return "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" ++
        "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
        "<title>fx</title><style>" ++
        ":root{color-scheme:light dark}" ++
        "body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;" ++
        "background:#fff;color:#111;" ++
        "font:15px/1.6 ui-sans-serif,-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}" ++
        "@media(prefers-color-scheme:dark){body{background:#0b0b0c;color:#f4f4f5}}" ++
        "main{text-align:center;padding:2rem;max-width:26rem}" ++
        "h1{margin:0 0 .5rem;font-size:1.125rem;font-weight:600;letter-spacing:-.01em}" ++
        "p{margin:0;font-size:.875rem;opacity:.62}" ++
        "</style></head><body><main><h1>" ++ title ++ "</h1><p>" ++ detail ++ "</p></main></body></html>";
}

fn writeResponse(stream: std.Io.net.Stream, outcome: Response) !void {
    const reply: struct { status: []const u8, body: []const u8 } = switch (outcome) {
        .ok => .{
            .status = "200 OK",
            .body = comptime callbackPage(
                "Authorization complete",
                "Returning you to fx. You can close this tab.",
            ),
        },
        .failed => .{
            .status = "400 Bad Request",
            .body = comptime callbackPage(
                "Authorization failed",
                "Return to fx for details.",
            ),
        },
        .unrelated => .{
            .status = "404 Not Found",
            .body = "<!doctype html><title>Not found</title>Not found.",
        },
    };
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io_mod.getIo(), &buffer);
    try writer.interface.print(
        "HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ reply.status, reply.body.len, reply.body },
    );
    try writer.interface.flush();
}

fn setSocketTimeouts(socket: std.posix.socket_t) void {
    const timeout = std.posix.timeval{ .sec = socket_timeout_seconds, .usec = 0 };
    const receive_rc = std.c.setsockopt(
        socket,
        std.c.SOL.SOCKET,
        std.c.SO.RCVTIMEO,
        &timeout,
        @sizeOf(std.posix.timeval),
    );
    if (receive_rc != 0) {
        const err = std.posix.errno(receive_rc);
        debug_trace.logf("auth", "OAuth callback receive timeout setup failed errno={s}", .{@tagName(err)});
    }
    const send_rc = std.c.setsockopt(
        socket,
        std.c.SOL.SOCKET,
        std.c.SO.SNDTIMEO,
        &timeout,
        @sizeOf(std.posix.timeval),
    );
    if (send_rc != 0) {
        const err = std.posix.errno(send_rc);
        debug_trace.logf("auth", "OAuth callback send timeout setup failed errno={s}", .{@tagName(err)});
    }
}

fn bindTestListener() !std.Io.net.Server {
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    return address.listen(io_mod.getIo(), .{ .reuse_address = true });
}

const TestCallback = struct {
    code: []const u8,
};

fn parseTestCallback(
    _: ?*anyopaque,
    _: Allocator,
    target: []const u8,
) ParseResult(TestCallback) {
    if (std.mem.eql(u8, target, "/callback?code=granted")) {
        return .{ .accepted = .{ .code = "granted" } };
    }
    return .unrelated;
}

const CallbackProbe = struct {
    port: u16,
    requests: []const []const u8,

    fn run(self: CallbackProbe) void {
        const io = io_mod.getIo();
        for (self.requests) |request| {
            var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
            var stream = address.connect(io, .{ .mode = .stream }) catch return;
            defer stream.close(io);
            if (request.len == 0) continue;
            var buffer: [512]u8 = undefined;
            var writer = stream.writer(io, &buffer);
            writer.interface.writeAll(request) catch return;
            writer.interface.flush() catch return;
            var read_buffer: [512]u8 = undefined;
            var reader = stream.reader(io, &read_buffer);
            _ = reader.interface.discardRemaining() catch {};
        }
    }
};

const ResetPreconnectProbe = struct {
    port: u16,
    request: []const u8,
    hold_ms: u64,
    connected: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *ResetPreconnectProbe) void {
        const io = io_mod.getIo();
        var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch
            return self.finish(true);
        {
            var reset_stream = address.connect(io, .{ .mode = .stream }) catch
                return self.finish(true);
            defer reset_stream.close(io);
            const reset_on_close: std.posix.linger = .{
                .onoff = 1,
                .linger = 0,
            };
            std.posix.setsockopt(
                reset_stream.socket.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.LINGER,
                std.mem.asBytes(&reset_on_close),
            ) catch return self.finish(true);
            self.finish(false);
            io_mod.sleep(self.hold_ms * std.time.ns_per_ms);
        }

        var stream = address.connect(io, .{ .mode = .stream }) catch return;
        defer stream.close(io);
        var buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(self.request) catch return;
        writer.interface.flush() catch return;
    }

    fn finish(self: *ResetPreconnectProbe, failed: bool) void {
        self.failed.store(failed, .release);
        self.connected.store(true, .release);
    }

    fn waitUntilConnected(self: *ResetPreconnectProbe) !void {
        while (!self.connected.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
        try std.testing.expect(!self.failed.load(.acquire));
    }
};

const HeldPreconnectProbe = struct {
    port: u16,
    request: []const u8 = "",
    delivered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *HeldPreconnectProbe) void {
        const io = io_mod.getIo();
        var address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch
            return self.finish(true);
        var idle = address.connect(io, .{ .mode = .stream }) catch
            return self.finish(true);
        defer idle.close(io);
        if (self.request.len == 0) {
            self.finish(false);
            return self.wait();
        }
        var stream = address.connect(io, .{ .mode = .stream }) catch
            return self.finish(true);
        defer stream.close(io);
        var buffer: [512]u8 = undefined;
        var writer = stream.writer(io, &buffer);
        writer.interface.writeAll(self.request) catch return self.finish(true);
        writer.interface.flush() catch return self.finish(true);
        self.finish(false);
        self.wait();
    }

    fn finish(self: *HeldPreconnectProbe, failed: bool) void {
        self.failed.store(failed, .release);
        self.delivered.store(true, .release);
    }

    fn wait(self: *HeldPreconnectProbe) void {
        while (!self.release.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
    }

    fn waitUntilDelivered(self: *HeldPreconnectProbe) !void {
        while (!self.delivered.load(.acquire)) io_mod.sleep(std.time.ns_per_ms);
        try std.testing.expect(!self.failed.load(.acquire));
    }
};

test "browser callback outruns an idle preconnect held open" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = HeldPreconnectProbe{
        .port = listener.socket.address.getPort(),
        .request = "GET /callback?code=granted HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    };
    const thread = try std.Thread.spawn(.{}, HeldPreconnectProbe.run, .{&probe});
    defer thread.join();
    defer probe.release.store(true, .release);
    try probe.waitUntilDelivered();

    var cancel_flag = std.atomic.Value(bool).init(false);
    const started_ms = io_mod.milliTimestamp();
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
    )) orelse return error.CallbackNeverArrived;
    defer accepted.deinit();
    try std.testing.expectEqualStrings("granted", accepted.callback.code);
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "browser callback cancels while an idle preconnect is open" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = HeldPreconnectProbe{ .port = listener.socket.address.getPort() };
    const thread = try std.Thread.spawn(.{}, HeldPreconnectProbe.run, .{&probe});
    defer thread.join();
    defer probe.release.store(true, .release);
    try probe.waitUntilDelivered();

    var cancel_flag = std.atomic.Value(bool).init(false);
    const Flip = struct {
        fn run(flag: *std.atomic.Value(bool)) void {
            io_mod.sleep(20 * std.time.ns_per_ms);
            flag.store(true, .seq_cst);
        }
    };
    const flip = try std.Thread.spawn(.{}, Flip.run, .{&cancel_flag});
    defer flip.join();

    const started_ms = io_mod.milliTimestamp();
    try std.testing.expectError(
        error.Cancelled,
        await(
            TestCallback,
            parseTestCallback,
            std.testing.allocator,
            &listener,
            null,
            &cancel_flag,
        ),
    );
    try std.testing.expect(io_mod.milliTimestamp() - started_ms < 1_000);
}

test "browser callback survives unrelated requests before the redirect" {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());
    const port = listener.socket.address.getPort();

    const requests = [_][]const u8{
        "",
        "GET /favicon.ico HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "GET /unrelated?code=nope HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        "GET /callback?code=granted HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
    };
    const probe = CallbackProbe{ .port = port, .requests = &requests };
    const thread = try std.Thread.spawn(.{}, CallbackProbe.run, .{probe});
    defer thread.join();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
    )) orelse return error.CallbackNeverArrived;
    defer accepted.deinit();
    try accepted.respond(.ok);
    try std.testing.expectEqualStrings("granted", accepted.callback.code);
}

fn expectResetPreconnectSurvives(hold_ms: u64) !void {
    var listener = try bindTestListener();
    defer listener.deinit(io_mod.getIo());

    var probe = ResetPreconnectProbe{
        .port = listener.socket.address.getPort(),
        .request = "GET /callback?code=granted HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n",
        .hold_ms = hold_ms,
    };
    const thread = try std.Thread.spawn(.{}, ResetPreconnectProbe.run, .{&probe});
    defer thread.join();
    try probe.waitUntilConnected();

    var cancel_flag = std.atomic.Value(bool).init(false);
    var accepted = (try await(
        TestCallback,
        parseTestCallback,
        std.testing.allocator,
        &listener,
        null,
        &cancel_flag,
    )) orelse return error.CallbackNeverArrived;
    defer accepted.deinit();
    try std.testing.expectEqualStrings("granted", accepted.callback.code);
}

test "browser callback survives a reset preconnect before the redirect" {
    try expectResetPreconnectSurvives(100);
}

test "browser callback survives a reset queued before accept" {
    try expectResetPreconnectSurvives(0);
}
