const std = @import("std");
const builtin = @import("builtin");
const agent_stream_provider = @import("../agent/stream_provider.zig");
const provider_runtime = @import("provider_runtime.zig");
const app_session_runtime = @import("app_session_runtime.zig");
const session_display_metadata = @import("../session/session_display_metadata.zig");
const session_title_generator = @import("../session/session_title_generator.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");

pub const GeneratedTitle = session_title_generator.GeneratedTitle;

pub const State = struct {
    mutex: std.Io.Mutex = .init,
    thread: ?std.Thread = null,
    result: ?GeneratedTitle = null,
    cancel: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn Runtime(comptime App: type) type {
    return struct {
        const SessionRuntime = app_session_runtime.Runtime(App);

        pub fn start(app: *App, prompt: []const u8) void {
            if (comptime builtin.single_threaded) return;
            if (app.session_title_generation.thread != null) return;
            if (SessionRuntime.cachedSessionTitle(app) != null) return;
            const session_id = SessionRuntime.activeSessionId(app) orelse return;
            const credential = app.auth.apiKey() orelse return;
            const expected_title = session_display_metadata.deriveTitleFromPrompt(app.alloc, prompt) catch return orelse return;
            defer app.alloc.free(expected_title);
            SessionRuntime.setCachedSessionTitle(app, expected_title) catch return;

            const task = Task.create(app, session_id, expected_title, prompt, credential) catch return;
            app.session_title_generation.cancel.store(false, .seq_cst);
            app.session_title_generation.thread = std.Thread.spawn(.{}, Task.run, .{task}) catch {
                task.deinit();
                return;
            };
        }

        pub fn poll(app: *App) !void {
            const state = &app.session_title_generation;
            state.mutex.lockUncancelable(io_mod.getIo());
            const result = state.result;
            state.result = null;
            state.mutex.unlock(io_mod.getIo());
            const generated = result orelse return;
            defer generated.deinit();
            if (state.thread) |thread| thread.join();
            state.thread = null;
            try SessionRuntime.applyGeneratedSessionTitle(app, generated);
        }

        pub fn stop(app: *App) void {
            const state = &app.session_title_generation;
            state.cancel.store(true, .seq_cst);
            if (state.thread) |thread| thread.join();
            state.thread = null;
            state.mutex.lockUncancelable(io_mod.getIo());
            const result = state.result;
            state.result = null;
            state.mutex.unlock(io_mod.getIo());
            if (result) |generated| generated.deinit();
        }

        const Task = struct {
            app: *App,
            stream_provider: agent_stream_provider.Provider,
            session_id: []u8,
            expected_title: []u8,
            prompt: []u8,
            credential: []u8,
            model: []u8,
            gateway_team: ?[]u8,
            account_id: ?[]u8,
            credential_source: ?types.CredentialSource,

            fn create(app: *App, session_id: []const u8, expected_title: []const u8, prompt: []const u8, credential: []const u8) !*Task {
                const alloc = std.heap.c_allocator;
                const task = try alloc.create(Task);
                errdefer alloc.destroy(task);
                task.* = .{
                    .app = app,
                    .stream_provider = app.agentStreamProvider(),
                    .session_id = try alloc.dupe(u8, session_id),
                    .expected_title = undefined,
                    .prompt = undefined,
                    .credential = undefined,
                    .model = undefined,
                    .gateway_team = null,
                    .account_id = null,
                    .credential_source = app.auth.credentialSource(),
                };
                errdefer alloc.free(task.session_id);
                task.expected_title = try alloc.dupe(u8, expected_title);
                errdefer alloc.free(task.expected_title);
                task.prompt = try alloc.dupe(u8, prompt);
                errdefer alloc.free(task.prompt);
                task.credential = try alloc.dupe(u8, credential);
                errdefer alloc.free(task.credential);
                task.model = try alloc.dupe(u8, provider_runtime.model(app));
                errdefer alloc.free(task.model);
                if (app.auth.gatewayTeam()) |team| task.gateway_team = try alloc.dupe(u8, team);
                errdefer if (task.gateway_team) |team| alloc.free(team);
                if (app.auth.accountId()) |account| task.account_id = try alloc.dupe(u8, account);
                return task;
            }

            fn deinit(self: *Task) void {
                const alloc = std.heap.c_allocator;
                if (self.session_id.len > 0) alloc.free(self.session_id);
                if (self.expected_title.len > 0) alloc.free(self.expected_title);
                alloc.free(self.prompt);
                alloc.free(self.credential);
                alloc.free(self.model);
                if (self.gateway_team) |team| alloc.free(team);
                if (self.account_id) |account| alloc.free(account);
                alloc.destroy(self);
            }

            fn run(self: *Task) void {
                defer self.deinit();
                const app = self.app;
                const title = session_title_generator.generate(std.heap.c_allocator, .{
                    .stream_provider = self.stream_provider,
                    .credential = .{ .secret = self.credential, .source = self.credential_source, .account_id = self.account_id, .tenant = self.gateway_team },
                    .session_id = self.session_id,
                    .model = self.model,
                    .retry_count = 1,
                    .user_prompt = self.prompt,
                    .cancel_flag = &app.session_title_generation.cancel,
                    .trace_ctx = .{},
                }) catch |err| {
                    debug_trace.logf("session", "event=title_generation_failed err={s}", .{@errorName(err)});
                    return;
                } orelse return;

                const state = &app.session_title_generation;
                state.mutex.lockUncancelable(io_mod.getIo());
                defer state.mutex.unlock(io_mod.getIo());
                if (state.cancel.load(.seq_cst)) {
                    std.heap.c_allocator.free(title);
                    return;
                }
                state.result = .{
                    .session_id = self.session_id,
                    .expected_title = self.expected_title,
                    .title = title,
                };
                self.session_id = &.{};
                self.expected_title = &.{};
            }
        };
    };
}
