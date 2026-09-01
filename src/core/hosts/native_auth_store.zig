const std = @import("std");
const builtin = @import("builtin");
const auth_store = @import("../auth/auth_store.zig");
const debug_trace = @import("../shared/debug_trace.zig");
const io_mod = @import("../shared/io.zig");
const native_keychain = @import("native_keychain.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("../auth/secret.zig");

const Allocator = std.mem.Allocator;
const max_auth_document_bytes: usize = 256 * 1024;
const max_legacy_api_key_bytes: usize = 8 * 1024;
const max_legacy_session_bytes: usize = 64 * 1024;
const mutation_lock_file_name = "auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;
const e2e_lock_contention_file_name = "auth-lock-contention";

const MutationLockProbe = struct {
    fx_dir: std.Io.Dir,
    signaled: bool = false,

    fn try_lock(raw: ?*anyopaque, file: std.Io.File) anyerror!bool {
        const locked = try file.tryLock(io_mod.getIo(), .exclusive);
        const self: *MutationLockProbe = @ptrCast(@alignCast(raw.?));
        if (!locked and !self.signaled) {
            signal_e2e_lock_contention(self.fx_dir);
            self.signaled = true;
        }
        return locked;
    }
};

fn signal_e2e_lock_contention(fx_dir: std.Io.Dir) void {
    const enabled = io_mod.getenv("FX_E2E_AUTH_LOCK_CONTENTION") orelse return;
    if (!std.mem.eql(u8, enabled, "1")) return;
    var file = fx_dir.createFile(io_mod.getIo(), e2e_lock_contention_file_name, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    }) catch return;
    defer file.close(io_mod.getIo());
    file.writeStreamingAll(io_mod.getIo(), "contended\n") catch {};
}

const StorageBackend = enum {
    profile_file,
    macos_keychain,
};

const KeychainError = Allocator.Error || native_keychain.Error;

fn storage_backend() StorageBackend {
    if (comptime builtin.is_test) return .profile_file;
    if (comptime builtin.os.tag == .macos) {
        if (!native_keychain.isDisabled()) return .macos_keychain;
    }
    return .profile_file;
}

const KeychainBackend = struct {
    context: ?*anyopaque = null,
    load_document_fn: *const fn (?*anyopaque, Allocator) KeychainError!?[]u8,
    store_document_fn: *const fn (?*anyopaque, []const u8) KeychainError!void,
    load_api_key_fn: *const fn (?*anyopaque, Allocator) KeychainError!?[]u8,
    delete_api_key_fn: *const fn (?*anyopaque, Allocator) KeychainError!bool,

    fn load_document(self: KeychainBackend, alloc: Allocator) KeychainError!?[]u8 {
        return self.load_document_fn(self.context, alloc);
    }

    fn store_document(self: KeychainBackend, value: []const u8) KeychainError!void {
        return self.store_document_fn(self.context, value);
    }

    fn load_api_key(self: KeychainBackend, alloc: Allocator) KeychainError!?[]u8 {
        return self.load_api_key_fn(self.context, alloc);
    }

    fn delete_api_key(self: KeychainBackend, alloc: Allocator) KeychainError!bool {
        return self.delete_api_key_fn(self.context, alloc);
    }
};

const native_keychain_backend = KeychainBackend{
    .load_document_fn = native_load_document,
    .store_document_fn = native_store_document,
    .load_api_key_fn = native_load_api_key,
    .delete_api_key_fn = native_delete_api_key,
};

fn native_load_document(_: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
    return native_keychain.loadOAuthSession(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        else => return err,
    };
}

fn native_store_document(_: ?*anyopaque, value: []const u8) KeychainError!void {
    return native_keychain.storeOAuthSession(value);
}

fn native_load_api_key(_: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
    return native_keychain.load(alloc) catch |err| switch (err) {
        error.KeychainItemNotFound => null,
        else => return err,
    };
}

fn native_delete_api_key(_: ?*anyopaque, alloc: Allocator) KeychainError!bool {
    return native_keychain.delete(alloc);
}

const ProfileMutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    fn deinit(self: *ProfileMutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    fn load(self: *ProfileMutation, alloc: Allocator) !?auth_store.Document {
        var file = self.fx_dir.dir.openFile(io_mod.getIo(), profile_paths.auth_file_name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer file.close(io_mod.getIo());

        const stat = try file.stat(io_mod.getIo());
        if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
            return error.AuthDocumentInsecure;
        }
        const bytes = try io_mod.readFileToEnd(alloc, &file, max_auth_document_bytes);
        defer secret.zeroAndFree(alloc, bytes);
        return try auth_store.Document.parse(alloc, bytes);
    }

    fn commit(
        self: *ProfileMutation,
        alloc: Allocator,
        document: auth_store.Document,
    ) !void {
        const bytes = try document.stringify(alloc);
        defer secret.zeroAndFree(alloc, bytes);
        try io_mod.durableReplaceVerified(
            alloc,
            &self.fx_dir,
            profile_paths.auth_file_name,
            bytes,
        );
    }
};

fn begin_profile_mutation(home: []const u8) !ProfileMutation {
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();

    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    errdefer fx_dir.close();
    var probe = MutationLockProbe{ .fx_dir = fx_dir.dir };
    var lock = try io_mod.acquireTimedAdvisoryLockWithOps(
        &fx_dir,
        mutation_lock_file_name,
        mutation_lock_deadline_ms,
        .{ .ctx = &probe, .try_lock = MutationLockProbe.try_lock },
    );
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

const ProfileObservation = struct {
    state: auth_store.StoreState,
    document: ?auth_store.Document = null,

    fn deinit(self: *ProfileObservation, alloc: Allocator) void {
        if (self.document) |*document| document.deinit(alloc);
        self.* = .{ .state = .empty };
    }

    fn take_document(self: *ProfileObservation) ?auth_store.Document {
        const document = self.document;
        self.document = null;
        return document;
    }
};

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const EntryMutation = struct {
    profile: ProfileMutation,
    source: auth_store.StoredSource,
    backend: StorageBackend = .profile_file,
    keychain: KeychainBackend = native_keychain_backend,

    pub fn deinit(self: *EntryMutation) void {
        self.profile.deinit();
        self.* = undefined;
    }

    pub fn load(self: *EntryMutation, alloc: Allocator) !?[]u8 {
        var observation = switch (self.backend) {
            .profile_file => try observe_profile(alloc, &self.profile.fx_dir.dir),
            .macos_keychain => try observe_keychain_profile(alloc, &self.profile.fx_dir.dir, self.keychain),
        };
        defer observation.deinit(alloc);
        try self.migrate_observation(alloc, &observation);
        const document = observation.document orelse return null;
        const value = document.get(self.source) orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn migrate_observation(
        self: *EntryMutation,
        alloc: Allocator,
        observation: *ProfileObservation,
    ) !void {
        switch (auth_store.decide_load(observation.state, .active)) {
            .missing, .use_current => return,
            .migrate_legacy => {},
            .use_legacy, .reject_current => unreachable,
        }
        const document = observation.document orelse return error.InvalidAuthDocument;
        const migrated = switch (self.backend) {
            .profile_file => publish_profile_migration(&self.profile, alloc, document),
            .macos_keychain => publish_keychain_migration(
                alloc,
                &self.profile.fx_dir.dir,
                document,
                self.keychain,
            ),
        };
        if (migrated) {
            observation.state = .current;
        }
    }

    pub fn save(self: *EntryMutation, alloc: Allocator, value: []const u8) !void {
        var observation = switch (self.backend) {
            .profile_file => try observe_profile(alloc, &self.profile.fx_dir.dir),
            .macos_keychain => try observe_keychain_profile(alloc, &self.profile.fx_dir.dir, self.keychain),
        };
        defer observation.deinit(alloc);
        const empty: auth_store.Document = .{};
        const document = if (observation.document) |*current| current else &empty;
        var next = try document.replaced(alloc, self.source, value);
        defer next.deinit(alloc);
        switch (self.backend) {
            .profile_file => {
                try commit_and_verify(&self.profile, alloc, next);
                delete_legacy_profile_files(&self.profile.fx_dir.dir) catch |err| {
                    debug_trace.logf("auth", "common auth cleanup incomplete backend=profile err={s}", .{@errorName(err)});
                };
            },
            .macos_keychain => {
                try commit_and_verify_keychain(alloc, next, self.keychain);
                delete_keychain_legacy_profile_files(&self.profile.fx_dir.dir) catch |err| {
                    debug_trace.logf("auth", "common auth cleanup incomplete backend=keychain source=profile err={s}", .{@errorName(err)});
                };
                _ = self.keychain.delete_api_key(alloc) catch |err| failed: {
                    debug_trace.logf("auth", "common auth cleanup incomplete backend=keychain source=stored_key err={s}", .{@errorName(err)});
                    break :failed false;
                };
            },
        }
    }

    pub fn delete(self: *EntryMutation, alloc: Allocator) !DeleteOutcome {
        var observation = switch (self.backend) {
            .profile_file => try observe_profile(alloc, &self.profile.fx_dir.dir),
            .macos_keychain => try observe_keychain_profile(alloc, &self.profile.fx_dir.dir, self.keychain),
        };
        defer observation.deinit(alloc);
        const document = observation.document orelse return .missing;
        if (document.get(self.source) == null) return .missing;
        var next = try document.removed(alloc, self.source);
        defer next.deinit(alloc);
        var cleanup_failed = false;
        switch (self.backend) {
            .profile_file => {
                commit_and_verify(&self.profile, alloc, next) catch |err| switch (err) {
                    error.DurableReplacePostRenameFailed => return .deleted_not_durable,
                    else => return err,
                };
                delete_legacy_profile_files(&self.profile.fx_dir.dir) catch |err| {
                    debug_trace.logf("auth", "common auth cleanup incomplete backend=profile err={s}", .{@errorName(err)});
                    cleanup_failed = true;
                };
            },
            .macos_keychain => {
                try commit_and_verify_keychain(alloc, next, self.keychain);
                delete_keychain_legacy_profile_files(&self.profile.fx_dir.dir) catch |err| {
                    debug_trace.logf("auth", "common auth cleanup incomplete backend=keychain source=profile err={s}", .{@errorName(err)});
                    cleanup_failed = true;
                };
                _ = self.keychain.delete_api_key(alloc) catch |err| failed: {
                    debug_trace.logf("auth", "common auth cleanup incomplete backend=keychain source=stored_key err={s}", .{@errorName(err)});
                    cleanup_failed = true;
                    break :failed false;
                };
            },
        }
        return if (cleanup_failed) .deleted_not_durable else .deleted;
    }
};

pub fn load_entry(
    alloc: Allocator,
    source: auth_store.StoredSource,
    intent: auth_store.LoadIntent,
) !?[]u8 {
    const home = io_mod.getenv("HOME") orelse return null;
    return switch (storage_backend()) {
        .profile_file => load_profile_entry(alloc, home, source, intent),
        .macos_keychain => blk: {
            var document = (try load_keychain_document(
                alloc,
                home,
                intent,
                native_keychain_backend,
            )) orelse break :blk null;
            defer document.deinit(alloc);
            const value = document.get(source) orelse break :blk null;
            break :blk try alloc.dupe(u8, value);
        },
    };
}

pub fn begin_entry_mutation(source: auth_store.StoredSource) !EntryMutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var mutation = try begin_profile_entry_mutation(home, source);
    mutation.backend = storage_backend();
    return mutation;
}

fn begin_profile_entry_mutation(
    home: []const u8,
    source: auth_store.StoredSource,
) !EntryMutation {
    return .{
        .profile = try begin_profile_mutation(home),
        .source = source,
    };
}

fn load_profile_entry(
    alloc: Allocator,
    home: []const u8,
    source: auth_store.StoredSource,
    intent: auth_store.LoadIntent,
) !?[]u8 {
    var document = (try load_profile_document(alloc, home, intent)) orelse return null;
    defer document.deinit(alloc);
    const value = document.get(source) orelse return null;
    return try alloc.dupe(u8, value);
}

fn commit_and_verify(
    mutation: *ProfileMutation,
    alloc: Allocator,
    document: auth_store.Document,
) !void {
    try mutation.commit(alloc, document);
    var verified = (try mutation.load(alloc)) orelse return error.AuthDocumentWriteMismatch;
    defer verified.deinit(alloc);
    if (!document.eql(verified)) return error.AuthDocumentWriteMismatch;
}

fn publish_profile_migration(
    mutation: *ProfileMutation,
    alloc: Allocator,
    document: auth_store.Document,
) bool {
    commit_and_verify(mutation, alloc, document) catch |err| {
        debug_trace.logf("auth", "common auth migration deferred backend=profile step=publish err={s}", .{@errorName(err)});
        return false;
    };
    delete_legacy_profile_files(&mutation.fx_dir.dir) catch |err| {
        debug_trace.logf("auth", "common auth migration cleanup incomplete backend=profile err={s}", .{@errorName(err)});
    };
    return true;
}

fn load_profile_document(
    alloc: Allocator,
    home: []const u8,
    intent: auth_store.LoadIntent,
) !?auth_store.Document {
    var initial = try observe_profile_home(alloc, home);
    defer initial.deinit(alloc);
    switch (auth_store.decide_load(initial.state, intent)) {
        .missing => return null,
        .use_legacy, .use_current => return initial.take_document(),
        .reject_current => unreachable,
        .migrate_legacy => {},
    }

    var mutation = try begin_profile_mutation(home);
    defer mutation.deinit();
    var observation = try observe_profile(alloc, &mutation.fx_dir.dir);
    defer observation.deinit(alloc);
    return switch (auth_store.decide_load(observation.state, intent)) {
        .missing => null,
        .use_current => observation.take_document(),
        .migrate_legacy => migrated: {
            const document = observation.document orelse return error.InvalidAuthDocument;
            _ = publish_profile_migration(&mutation, alloc, document);
            break :migrated observation.take_document();
        },
        .use_legacy, .reject_current => unreachable,
    };
}

fn observe_profile_home(alloc: Allocator, home: []const u8) !ProfileObservation {
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{ .state = .empty },
        else => return err,
    };
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return .{ .state = .empty },
        else => return err,
    };
    defer fx_dir.close(io_mod.getIo());
    return observe_profile(alloc, &fx_dir);
}

fn load_keychain_document(
    alloc: Allocator,
    home: []const u8,
    intent: auth_store.LoadIntent,
    keychain: KeychainBackend,
) !?auth_store.Document {
    var initial = try observe_keychain_home(alloc, home, keychain);
    defer initial.deinit(alloc);
    switch (auth_store.decide_load(initial.state, intent)) {
        .missing => return null,
        .use_legacy, .use_current => return initial.take_document(),
        .reject_current => unreachable,
        .migrate_legacy => {},
    }

    var mutation = try begin_profile_mutation(home);
    defer mutation.deinit();
    var observation = try observe_keychain_profile(alloc, &mutation.fx_dir.dir, keychain);
    defer observation.deinit(alloc);
    return switch (auth_store.decide_load(observation.state, intent)) {
        .missing => null,
        .use_current => observation.take_document(),
        .migrate_legacy => migrated: {
            const document = observation.document orelse return error.InvalidAuthDocument;
            _ = publish_keychain_migration(alloc, &mutation.fx_dir.dir, document, keychain);
            break :migrated observation.take_document();
        },
        .use_legacy, .reject_current => unreachable,
    };
}

fn observe_keychain_home(
    alloc: Allocator,
    home: []const u8,
    keychain: KeychainBackend,
) !ProfileObservation {
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return observe_keychain_without_profile(alloc, keychain),
        else => return err,
    };
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return observe_keychain_without_profile(alloc, keychain),
        else => return err,
    };
    defer fx_dir.close(io_mod.getIo());
    return observe_keychain_profile(alloc, &fx_dir, keychain);
}

fn observe_keychain_without_profile(
    alloc: Allocator,
    keychain: KeychainBackend,
) !ProfileObservation {
    var document: auth_store.Document = .{};
    errdefer document.deinit(alloc);
    var found = false;
    const stored = try keychain.load_document(alloc);
    defer if (stored) |bytes| secret.zeroAndFree(alloc, bytes);
    if (stored) |bytes| {
        const version = (try declared_version(alloc, bytes)) orelse return error.InvalidAuthDocument;
        switch (version) {
            2 => return .{ .state = .current, .document = try auth_store.Document.parse(alloc, bytes) },
            1 => {
                const next = try document.replaced(alloc, .fx_login, bytes);
                document.deinit(alloc);
                document = next;
                found = true;
            },
            else => return error.InvalidAuthDocument,
        }
    }
    if (try keychain.load_api_key(alloc)) |key| {
        defer secret.zeroAndFree(alloc, key);
        const next = try document.replaced(alloc, .stored_key, key);
        document.deinit(alloc);
        document = next;
        found = true;
    }
    return if (found)
        .{ .state = .legacy, .document = document }
    else blk: {
        document.deinit(alloc);
        break :blk .{ .state = .empty };
    };
}

fn observe_keychain_profile(
    alloc: Allocator,
    fx_dir: *std.Io.Dir,
    keychain: KeychainBackend,
) !ProfileObservation {
    const stored = try keychain.load_document(alloc);
    defer if (stored) |bytes| secret.zeroAndFree(alloc, bytes);
    const stored_version = if (stored) |bytes| try declared_version(alloc, bytes) else null;
    var current = if (stored) |bytes|
        if (stored_version == 2)
            try auth_store.Document.parse(alloc, bytes)
        else
            null
    else
        null;
    defer if (current) |*document| document.deinit(alloc);
    if (stored_version != null and stored_version != 1 and stored_version != 2) {
        return error.InvalidAuthDocument;
    }

    var profile = try observe_profile(alloc, fx_dir);
    defer profile.deinit(alloc);
    if (profile.state == .malformed_current) return error.InvalidAuthDocument;
    var document = profile.take_document() orelse auth_store.Document{};
    errdefer document.deinit(alloc);
    var found = profile.state != .empty;
    var needs_migration = found;
    if (current) |*keychain_document| {
        const merged = try merge_auth_documents(
            alloc,
            keychain_document,
            &document,
        );
        document.deinit(alloc);
        document = merged;
        found = true;
    }
    if (stored) |bytes| {
        if (document.get(.fx_login) == null) {
            if (stored_version == 1) {
                const next = try document.replaced(alloc, .fx_login, bytes);
                document.deinit(alloc);
                document = next;
                found = true;
                needs_migration = true;
            }
        }
        if (stored_version == null and !found) return error.InvalidAuthDocument;
    }
    if (try keychain.load_api_key(alloc)) |key| {
        defer secret.zeroAndFree(alloc, key);
        if (document.get(.stored_key) == null) {
            const next = try document.replaced(alloc, .stored_key, key);
            document.deinit(alloc);
            document = next;
            found = true;
            needs_migration = true;
        }
    }
    return if (found)
        .{
            .state = if (current != null and !needs_migration) .current else .legacy,
            .document = document,
        }
    else blk: {
        document.deinit(alloc);
        break :blk .{ .state = .empty };
    };
}

fn merge_auth_documents(
    alloc: Allocator,
    primary: *const auth_store.Document,
    fallback: *const auth_store.Document,
) !auth_store.Document {
    var merged: auth_store.Document = .{};
    errdefer merged.deinit(alloc);
    for (std.meta.tags(auth_store.StoredSource)) |source| {
        const value = primary.get(source) orelse fallback.get(source) orelse continue;
        const next = try merged.replaced(alloc, source, value);
        merged.deinit(alloc);
        merged = next;
    }
    return merged;
}

fn commit_and_verify_keychain(
    alloc: Allocator,
    document: auth_store.Document,
    keychain: KeychainBackend,
) !void {
    const bytes = try document.stringify(alloc);
    defer secret.zeroAndFree(alloc, bytes);
    try keychain.store_document(bytes);
    const persisted = (try keychain.load_document(alloc)) orelse return error.AuthDocumentWriteMismatch;
    defer secret.zeroAndFree(alloc, persisted);
    var verified = try auth_store.Document.parse(alloc, persisted);
    defer verified.deinit(alloc);
    if (!document.eql(verified)) return error.AuthDocumentWriteMismatch;
}

fn publish_keychain_migration(
    alloc: Allocator,
    fx_dir: *std.Io.Dir,
    document: auth_store.Document,
    keychain: KeychainBackend,
) bool {
    commit_and_verify_keychain(alloc, document, keychain) catch |err| {
        debug_trace.logf("auth", "common auth migration deferred backend=keychain step=publish err={s}", .{@errorName(err)});
        return false;
    };
    delete_keychain_legacy_profile_files(fx_dir) catch |err| {
        debug_trace.logf("auth", "common auth migration cleanup incomplete backend=keychain source=profile err={s}", .{@errorName(err)});
    };
    _ = keychain.delete_api_key(alloc) catch |err| failed: {
        debug_trace.logf("auth", "common auth migration cleanup incomplete backend=keychain source=stored_key err={s}", .{@errorName(err)});
        break :failed false;
    };
    return true;
}

fn observe_profile(alloc: Allocator, fx_dir: *std.Io.Dir) !ProfileObservation {
    const auth_bytes = try read_optional_private_file(
        alloc,
        fx_dir,
        profile_paths.auth_file_name,
        max_auth_document_bytes,
    );
    defer if (auth_bytes) |bytes| secret.zeroAndFree(alloc, bytes);
    if (auth_bytes) |bytes| {
        const version = (try declared_version(alloc, bytes)) orelse return error.InvalidAuthDocument;
        if (version == 2) {
            return .{ .state = .current, .document = try auth_store.Document.parse(alloc, bytes) };
        }
        if (version != 1) return error.InvalidAuthDocument;
    }

    var document: auth_store.Document = .{};
    errdefer document.deinit(alloc);
    var found_legacy = false;
    if (auth_bytes) |bytes| {
        if ((try declared_version(alloc, bytes)) == 1) {
            const next = try document.replaced(alloc, .fx_login, bytes);
            document.deinit(alloc);
            document = next;
            found_legacy = true;
        }
    }
    if (try read_optional_private_file(
        alloc,
        fx_dir,
        profile_paths.api_key_file_name,
        max_legacy_api_key_bytes,
    )) |raw_key| {
        defer secret.zeroAndFree(alloc, raw_key);
        const key = std.mem.trim(u8, raw_key, "\r\n");
        if (key.len > 0) {
            const next = try document.replaced(alloc, .stored_key, key);
            document.deinit(alloc);
            document = next;
            found_legacy = true;
        }
    }
    if (try read_optional_private_file(
        alloc,
        fx_dir,
        profile_paths.chatgpt_auth_file_name,
        max_legacy_session_bytes,
    )) |bytes| {
        defer secret.zeroAndFree(alloc, bytes);
        if ((try declared_version(alloc, bytes)) == 1) {
            const next = try document.replaced(alloc, .chatgpt_subscription, bytes);
            document.deinit(alloc);
            document = next;
            found_legacy = true;
        }
    }
    if (try read_optional_private_file(
        alloc,
        fx_dir,
        profile_paths.grok_auth_file_name,
        max_legacy_session_bytes,
    )) |bytes| {
        defer secret.zeroAndFree(alloc, bytes);
        if ((try declared_version(alloc, bytes)) == 1) {
            const next = try document.replaced(alloc, .grok_subscription, bytes);
            document.deinit(alloc);
            document = next;
            found_legacy = true;
        }
    }

    return if (found_legacy)
        .{ .state = .legacy, .document = document }
    else blk: {
        document.deinit(alloc);
        break :blk .{ .state = .empty };
    };
}

fn declared_version(alloc: Allocator, bytes: []const u8) !?i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, alloc, bytes, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const version = parsed.value.object.get("version") orelse return null;
    return if (version == .integer) version.integer else null;
}

fn read_optional_private_file(
    alloc: Allocator,
    dir: *std.Io.Dir,
    name: []const u8,
    max_bytes: usize,
) !?[]u8 {
    var file = dir.openFile(io_mod.getIo(), name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (stat.kind != .file or stat.nlink != 1 or stat.permissions.toMode() & 0o077 != 0) {
        return error.AuthDocumentInsecure;
    }
    return try io_mod.readFileToEnd(alloc, &file, max_bytes);
}

fn read_profile_file(alloc: Allocator, home: []const u8, name: []const u8) ![]u8 {
    var home_dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true });
    defer home_dir.close(io_mod.getIo());
    var fx_dir = try home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    });
    defer fx_dir.close(io_mod.getIo());
    return (try read_optional_private_file(alloc, &fx_dir, name, max_auth_document_bytes)) orelse
        error.FileNotFound;
}

fn delete_legacy_profile_files(fx_dir: *std.Io.Dir) !void {
    var deleted = false;
    for ([_][]const u8{
        profile_paths.api_key_file_name,
        profile_paths.chatgpt_auth_file_name,
        profile_paths.grok_auth_file_name,
    }) |name| {
        fx_dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        deleted = true;
    }
    if (deleted) try io_mod.syncVerifiedDir(fx_dir.*);
}

fn delete_keychain_legacy_profile_files(fx_dir: *std.Io.Dir) !void {
    var deleted = false;
    for ([_][]const u8{
        profile_paths.auth_file_name,
        profile_paths.api_key_file_name,
        profile_paths.chatgpt_auth_file_name,
        profile_paths.grok_auth_file_name,
    }) |name| {
        fx_dir.deleteFile(io_mod.getIo(), name) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        deleted = true;
    }
    if (deleted) try io_mod.syncVerifiedDir(fx_dir.*);
}

test "profile auth store commits one private document and reloads every source" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var document: auth_store.Document = .{};
    defer document.deinit(alloc);
    const with_key = try document.replaced(alloc, .stored_key, "gateway-secret");
    document.deinit(alloc);
    document = with_key;
    const with_codex = try document.replaced(
        alloc,
        .chatgpt_subscription,
        "{\"version\":1,\"access_token\":\"codex\"}",
    );
    document.deinit(alloc);
    document = with_codex;

    var mutation = try begin_profile_mutation(home);
    try mutation.commit(alloc, document);
    mutation.deinit();

    var fx_dir = try tmp.dir.openDir(std.testing.io, ".fx", .{});
    defer fx_dir.close(std.testing.io);
    const stat = try fx_dir.statFile(std.testing.io, "auth.json", .{});
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);

    var reopened = try begin_profile_mutation(home);
    defer reopened.deinit();
    var loaded = (try reopened.load(alloc)) orelse return error.TestExpectedAuthDocument;
    defer loaded.deinit(alloc);
    try std.testing.expect(document.eql(loaded));
}

test "empty active load stays read only" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    try std.testing.expect((try load_profile_document(alloc, home, .active)) == null);
    try std.testing.expectError(
        error.FileNotFound,
        tmp.dir.statFile(std.testing.io, profile_paths.root_dir_name, .{}),
    );
}

test "malformed common document blocks legacy fallback and migration" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var verified_home = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer verified_home.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
    defer fx_dir.close();
    try io_mod.durableReplaceVerified(
        alloc,
        &fx_dir,
        profile_paths.auth_file_name,
        "{\"version\":2,\"credentials\":[]}",
    );
    try io_mod.durableReplaceVerified(
        alloc,
        &fx_dir,
        profile_paths.api_key_file_name,
        "gateway-secret",
    );

    try std.testing.expectError(
        error.InvalidAuthDocument,
        load_profile_document(alloc, home, .active),
    );
    _ = try fx_dir.dir.statFile(std.testing.io, profile_paths.api_key_file_name, .{});
}

test "legacy inspection is read only and active load publishes one common document" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var verified_home = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer verified_home.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
    defer fx_dir.close();

    const vercel =
        "{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\",\"access_token\":\"vercel-access\",\"refresh_token\":\"vercel-refresh\",\"expires_at_ms\":4102444800000,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\",\"team_slug\":\"team-slug\",\"team_id\":\"team-id\"}";
    const codex =
        "{\"version\":1,\"access_token\":\"codex-access\",\"refresh_token\":\"codex-refresh\",\"expires_at_ms\":4102444800000,\"account_id\":\"codex-account\"}";
    const grok =
        "{\"version\":1,\"access_token\":\"grok-access\",\"refresh_token\":\"grok-refresh\",\"expires_at_ms\":4102444800000,\"account_id\":\"grok-account\"}";
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.auth_file_name, vercel);
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.api_key_file_name, "gateway-secret");
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.chatgpt_auth_file_name, codex);
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.grok_auth_file_name, grok);

    var inspected = (try load_profile_document(alloc, home, .inspect)) orelse
        return error.TestExpectedLegacyDocument;
    defer inspected.deinit(alloc);
    try std.testing.expectEqualStrings("gateway-secret", inspected.get(.stored_key).?);
    try std.testing.expectEqualStrings(vercel, inspected.get(.fx_login).?);
    try std.testing.expectEqualStrings(codex, inspected.get(.chatgpt_subscription).?);
    try std.testing.expectEqualStrings(grok, inspected.get(.grok_subscription).?);
    _ = try fx_dir.dir.statFile(std.testing.io, profile_paths.api_key_file_name, .{});
    _ = try fx_dir.dir.statFile(std.testing.io, profile_paths.chatgpt_auth_file_name, .{});
    _ = try fx_dir.dir.statFile(std.testing.io, profile_paths.grok_auth_file_name, .{});

    const before = try read_profile_file(alloc, home, profile_paths.auth_file_name);
    defer secret.zeroAndFree(alloc, before);
    try std.testing.expect(std.mem.find(u8, before, "\"version\":1") != null);

    var migrated = (try load_profile_document(alloc, home, .active)) orelse
        return error.TestExpectedMigratedDocument;
    defer migrated.deinit(alloc);
    try std.testing.expect(inspected.eql(migrated));

    const after = try read_profile_file(alloc, home, profile_paths.auth_file_name);
    defer secret.zeroAndFree(alloc, after);
    var parsed_after = try auth_store.Document.parse(alloc, after);
    defer parsed_after.deinit(alloc);
    try std.testing.expect(migrated.eql(parsed_after));

    var migrated_fx_dir = try tmp.dir.openDir(std.testing.io, ".fx", .{});
    defer migrated_fx_dir.close(std.testing.io);
    for ([_][]const u8{
        profile_paths.api_key_file_name,
        profile_paths.chatgpt_auth_file_name,
        profile_paths.grok_auth_file_name,
    }) |name| {
        try std.testing.expectError(
            error.FileNotFound,
            migrated_fx_dir.statFile(std.testing.io, name, .{}),
        );
    }
}

test "source mutations share one document without losing unrelated credentials" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var key_mutation = try begin_profile_entry_mutation(home, .stored_key);
    try key_mutation.save(alloc, "gateway-secret");
    key_mutation.deinit();

    var codex_mutation = try begin_profile_entry_mutation(home, .chatgpt_subscription);
    try codex_mutation.save(alloc, "{\"version\":1,\"access_token\":\"codex\"}");
    codex_mutation.deinit();

    const key = (try load_profile_entry(alloc, home, .stored_key, .inspect)) orelse
        return error.TestExpectedStoredKey;
    defer secret.zeroAndFree(alloc, key);
    try std.testing.expectEqualStrings("gateway-secret", key);

    var delete_codex = try begin_profile_entry_mutation(home, .chatgpt_subscription);
    try std.testing.expectEqual(DeleteOutcome.deleted, try delete_codex.delete(alloc));
    delete_codex.deinit();

    const preserved_key = (try load_profile_entry(alloc, home, .stored_key, .inspect)) orelse
        return error.TestExpectedPreservedKey;
    defer secret.zeroAndFree(alloc, preserved_key);
    try std.testing.expectEqualStrings("gateway-secret", preserved_key);
    try std.testing.expect((try load_profile_entry(
        alloc,
        home,
        .chatgpt_subscription,
        .inspect,
    )) == null);
}

test "Keychain mutations merge current portable credentials before cleanup" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var verified_home = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer verified_home.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(
        &verified_home,
        profile_paths.root_dir_name,
    );
    defer fx_dir.close();
    try io_mod.durableReplaceVerified(
        alloc,
        &fx_dir,
        profile_paths.auth_file_name,
        "{\"version\":2,\"credentials\":{\"chatgpt_subscription\":{\"session\":{\"version\":1,\"access_token\":\"portable-codex\"}}}}\n",
    );

    var fake = FakeKeychain{
        .alloc = alloc,
        .document = try alloc.dupe(
            u8,
            "{\"version\":2,\"credentials\":{\"fx_login\":{\"session\":{\"version\":1,\"access_token\":\"keychain-vercel\"}}}}\n",
        ),
    };
    defer fake.deinit();
    {
        var mutation = try begin_profile_entry_mutation(home, .stored_key);
        defer mutation.deinit();
        mutation.backend = .macos_keychain;
        mutation.keychain = fake.backend();
        try mutation.save(alloc, "new-gateway-key");
    }

    var stored = try auth_store.Document.parse(alloc, fake.document.?);
    defer stored.deinit(alloc);
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"access_token\":\"keychain-vercel\"}",
        stored.get(.fx_login).?,
    );
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"access_token\":\"portable-codex\"}",
        stored.get(.chatgpt_subscription) orelse
            return error.TestExpectedPortableCredential,
    );
    try std.testing.expectEqualStrings(
        "new-gateway-key",
        stored.get(.stored_key).?,
    );
    try std.testing.expectError(
        error.FileNotFound,
        fx_dir.dir.statFile(std.testing.io, profile_paths.auth_file_name, .{}),
    );

    try io_mod.durableReplaceVerified(
        alloc,
        &fx_dir,
        profile_paths.auth_file_name,
        "{\"version\":2,\"credentials\":{\"grok_subscription\":{\"session\":{\"version\":1,\"access_token\":\"portable-grok\"}}}}\n",
    );
    var logout = try begin_profile_entry_mutation(home, .fx_login);
    defer logout.deinit();
    logout.backend = .macos_keychain;
    logout.keychain = fake.backend();
    try std.testing.expectEqual(DeleteOutcome.deleted, try logout.delete(alloc));

    var after_logout = try auth_store.Document.parse(alloc, fake.document.?);
    defer after_logout.deinit(alloc);
    try std.testing.expect(after_logout.get(.fx_login) == null);
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"access_token\":\"portable-codex\"}",
        after_logout.get(.chatgpt_subscription).?,
    );
    try std.testing.expectEqualStrings(
        "{\"version\":1,\"access_token\":\"portable-grok\"}",
        after_logout.get(.grok_subscription).?,
    );
    try std.testing.expectEqualStrings(
        "new-gateway-key",
        after_logout.get(.stored_key).?,
    );
    try std.testing.expectError(
        error.FileNotFound,
        fx_dir.dir.statFile(std.testing.io, profile_paths.auth_file_name, .{}),
    );
}

test "active entry mutation migrates an unexpired legacy subscription" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var verified_home = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer verified_home.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
    defer fx_dir.close();
    const codex =
        "{\"version\":1,\"access_token\":\"codex-access\",\"refresh_token\":\"codex-refresh\",\"expires_at_ms\":4102444800000,\"account_id\":\"codex-account\"}";
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.chatgpt_auth_file_name, codex);

    var mutation = try begin_profile_entry_mutation(home, .chatgpt_subscription);
    defer mutation.deinit();
    const loaded = (try mutation.load(alloc)) orelse return error.TestExpectedLegacyCredential;
    defer secret.zeroAndFree(alloc, loaded);

    try std.testing.expectEqualStrings(codex, loaded);
    const persisted = try read_profile_file(alloc, home, profile_paths.auth_file_name);
    defer secret.zeroAndFree(alloc, persisted);
    var document = try auth_store.Document.parse(alloc, persisted);
    defer document.deinit(alloc);
    try std.testing.expectEqualStrings(codex, document.get(.chatgpt_subscription).?);
    try std.testing.expectError(
        error.FileNotFound,
        fx_dir.dir.statFile(std.testing.io, profile_paths.chatgpt_auth_file_name, .{}),
    );
}

test "Keychain migration publishes every source before removing legacy credentials" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var verified_home = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer verified_home.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
    defer fx_dir.close();
    const codex =
        "{\"version\":1,\"access_token\":\"codex-access\",\"refresh_token\":\"codex-refresh\",\"expires_at_ms\":4102444800000,\"account_id\":\"codex-account\"}";
    const grok =
        "{\"version\":1,\"access_token\":\"grok-access\",\"refresh_token\":\"grok-refresh\",\"expires_at_ms\":4102444800000,\"account_id\":\"grok-account\"}";
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.chatgpt_auth_file_name, codex);
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.grok_auth_file_name, grok);

    var fake = FakeKeychain{
        .alloc = alloc,
        .document = try alloc.dupe(
            u8,
            "{\"version\":1,\"issuer\":\"https://vercel.com\",\"client_id\":\"client\",\"access_token\":\"vercel-access\",\"refresh_token\":\"vercel-refresh\",\"expires_at_ms\":4102444800000,\"scope\":\"openid offline_access\",\"token_type\":\"Bearer\",\"team_slug\":\"team-slug\",\"team_id\":\"team-id\"}",
        ),
        .api_key = try alloc.dupe(u8, "gateway-secret"),
    };
    defer fake.deinit();

    var loaded = (try load_keychain_document(alloc, home, .active, fake.backend())) orelse
        return error.TestExpectedKeychainDocument;
    defer loaded.deinit(alloc);
    try std.testing.expect(loaded.get(.stored_key) != null);
    try std.testing.expect(loaded.get(.fx_login) != null);
    try std.testing.expect(loaded.get(.chatgpt_subscription) != null);
    try std.testing.expect(loaded.get(.grok_subscription) != null);
    try std.testing.expect(fake.api_key == null);

    var stored = try auth_store.Document.parse(alloc, fake.document.?);
    defer stored.deinit(alloc);
    try std.testing.expect(loaded.eql(stored));
}

test "Keychain publication failure keeps legacy credentials authoritative" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try io_mod.dirRealpathAlloc(alloc, tmp.dir, ".");
    defer alloc.free(home);

    var verified_home = io_mod.VerifiedDir{
        .dir = try tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true }),
    };
    defer verified_home.close();
    var fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&verified_home, profile_paths.root_dir_name);
    defer fx_dir.close();
    const codex =
        "{\"version\":1,\"access_token\":\"codex-access\",\"refresh_token\":\"codex-refresh\",\"expires_at_ms\":4102444800000,\"account_id\":\"codex-account\"}";
    try io_mod.durableReplaceVerified(alloc, &fx_dir, profile_paths.chatgpt_auth_file_name, codex);

    var fake = FakeKeychain{ .alloc = alloc, .fail_store = true };
    defer fake.deinit();
    var mutation = try begin_profile_entry_mutation(home, .chatgpt_subscription);
    defer mutation.deinit();
    mutation.backend = .macos_keychain;
    mutation.keychain = fake.backend();
    const loaded = (try mutation.load(alloc)) orelse
        return error.TestExpectedLegacyDocument;
    defer secret.zeroAndFree(alloc, loaded);

    try std.testing.expectEqualStrings(codex, loaded);
    try std.testing.expect(fake.document == null);
    _ = try fx_dir.dir.statFile(std.testing.io, profile_paths.chatgpt_auth_file_name, .{});
}

const FakeKeychain = struct {
    alloc: Allocator,
    document: ?[]u8 = null,
    api_key: ?[]u8 = null,
    fail_store: bool = false,

    fn deinit(self: *FakeKeychain) void {
        if (self.document) |value| secret.zeroAndFree(self.alloc, value);
        if (self.api_key) |value| secret.zeroAndFree(self.alloc, value);
        self.* = undefined;
    }

    fn backend(self: *FakeKeychain) KeychainBackend {
        return .{
            .context = self,
            .load_document_fn = load_document,
            .store_document_fn = store_document,
            .load_api_key_fn = load_api_key,
            .delete_api_key_fn = delete_api_key,
        };
    }

    fn load_document(raw: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw.?));
        const value = self.document orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn store_document(raw: ?*anyopaque, value: []const u8) KeychainError!void {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw.?));
        if (self.fail_store) return error.KeychainWriteFailed;
        const replacement = try self.alloc.dupe(u8, value);
        if (self.document) |old| secret.zeroAndFree(self.alloc, old);
        self.document = replacement;
    }

    fn load_api_key(raw: ?*anyopaque, alloc: Allocator) KeychainError!?[]u8 {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw.?));
        const value = self.api_key orelse return null;
        return try alloc.dupe(u8, value);
    }

    fn delete_api_key(raw: ?*anyopaque, _: Allocator) KeychainError!bool {
        const self: *FakeKeychain = @ptrCast(@alignCast(raw.?));
        const value = self.api_key orelse return false;
        secret.zeroAndFree(self.alloc, value);
        self.api_key = null;
        return true;
    }
};
