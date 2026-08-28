const std = @import("std");
const io_mod = @import("../shared/io.zig");
const session_layout = @import("session_layout.zig");
const session_replay = @import("session_replay.zig");

const magic = "FXTR";
const schema_version: u8 = 1;
const fixed_metadata_bytes = magic.len + 1 + 2 + 8 + 16 + 8 + 16 + 8;
const max_metadata_bytes = fixed_metadata_bytes + 255;
const data_file = "transcript.ansi";
const metadata_file = "transcript.meta";

const Metadata = struct {
    session_id: []u8,
    committed_len: u64,
    position: session_replay.CommitPosition,

    pub fn deinit(self: *Metadata, alloc: std.mem.Allocator) void {
        alloc.free(self.session_id);
        self.* = undefined;
    }
};

pub const ExactReader = struct {
    file: std.Io.File,
    committed_len: u64,

    pub fn readAt(self: *const ExactReader, buffer: []u8, offset: u64) !usize {
        if (offset >= self.committed_len or buffer.len == 0) return 0;
        const remaining = self.committed_len - offset;
        const limit: usize = @intCast(@min(remaining, buffer.len));
        return self.file.readPositionalAll(
            io_mod.getIo(),
            buffer[0..limit],
            offset,
        );
    }
};

pub const Admission = union(enum) {
    missing,
    incomplete,
    corrupt,
    exact: ExactReader,

    pub fn deinit(self: *Admission) void {
        switch (self.*) {
            .exact => |reader| reader.file.close(io_mod.getIo()),
            .missing, .incomplete, .corrupt => {},
        }
        self.* = undefined;
    }
};

const MetadataInput = struct {
    session_id: []const u8,
    committed_len: u64,
    position: session_replay.CommitPosition,
};

fn encodeMetadata(alloc: std.mem.Allocator, input: MetadataInput) ![]u8 {
    session_layout.validateSessionId(input.session_id) catch
        return error.InvalidTranscriptMetadata;
    if (input.committed_len == 0 or input.session_id.len > 255) {
        return error.InvalidTranscriptMetadata;
    }
    var out: std.Io.Writer.Allocating = .init(alloc);
    defer out.deinit();
    try out.writer.writeAll(magic);
    try out.writer.writeByte(schema_version);
    try writeInt(&out.writer, u16, @intCast(input.session_id.len));
    try writeInt(&out.writer, u64, input.committed_len);
    try out.writer.writeAll(&input.position.log_generation);
    try writeInt(&out.writer, u64, input.position.through_seq);
    try out.writer.writeAll(&input.position.through_event_id);
    try writeInt(&out.writer, u64, input.position.through_event_log_bytes);
    try out.writer.writeAll(input.session_id);
    return out.toOwnedSlice();
}

fn decodeMetadata(alloc: std.mem.Allocator, bytes: []const u8) !Metadata {
    if (bytes.len < fixed_metadata_bytes or bytes.len > max_metadata_bytes) {
        return error.InvalidTranscriptMetadata;
    }
    var cursor = Cursor{ .bytes = bytes };
    if (!std.mem.eql(u8, try cursor.take(magic.len), magic) or
        (try cursor.take(1))[0] != schema_version)
    {
        return error.InvalidTranscriptMetadata;
    }
    const session_id_len = try cursor.readInt(u16);
    const committed_len = try cursor.readInt(u64);
    const log_generation = try cursor.take(16);
    const through_seq = try cursor.readInt(u64);
    const through_event_id = try cursor.take(16);
    const through_event_log_bytes = try cursor.readInt(u64);
    if (session_id_len == 0 or session_id_len > 255 or committed_len == 0) {
        return error.InvalidTranscriptMetadata;
    }
    const session_id = try cursor.take(session_id_len);
    if (cursor.remaining() != 0) return error.InvalidTranscriptMetadata;
    session_layout.validateSessionId(session_id) catch
        return error.InvalidTranscriptMetadata;
    return .{
        .session_id = try alloc.dupe(u8, session_id),
        .committed_len = committed_len,
        .position = .{
            .log_generation = log_generation[0..16].*,
            .through_seq = through_seq,
            .through_event_id = through_event_id[0..16].*,
            .through_event_log_bytes = through_event_log_bytes,
        },
    };
}

pub fn publishComplete(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    position: session_replay.CommitPosition,
    bytes: []const u8,
) !void {
    if (bytes.len == 0 or try validatedPrefix(bytes, true) != bytes.len) {
        return error.InvalidTranscriptGrammar;
    }
    try io_mod.durableReplaceVerified(alloc, session_dir, data_file, bytes);
    const encoded = try encodeMetadata(alloc, .{
        .session_id = session_id,
        .committed_len = @intCast(bytes.len),
        .position = position,
    });
    defer alloc.free(encoded);
    try io_mod.durableReplaceVerified(alloc, session_dir, metadata_file, encoded);
}

pub fn appendAndCommit(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    prior_committed_len: u64,
    position: session_replay.CommitPosition,
    bytes: []const u8,
) !u64 {
    return appendAndCommitWithOps(
        alloc,
        session_dir,
        session_id,
        prior_committed_len,
        position,
        bytes,
        .{},
    );
}

fn appendAndCommitWithOps(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    prior_committed_len: u64,
    position: session_replay.CommitPosition,
    bytes: []const u8,
    metadata_ops: io_mod.DurableOps,
) !u64 {
    if (prior_committed_len == 0 or bytes.len == 0 or
        try validatedPrefix(bytes, true) != bytes.len)
    {
        return error.InvalidTranscriptAppend;
    }
    const next_committed_len = std.math.add(
        u64,
        prior_committed_len,
        std.math.cast(u64, bytes.len) orelse return error.TranscriptTooLarge,
    ) catch return error.TranscriptTooLarge;

    var file = try io_mod.openExistingRegularFile(
        session_dir.dir,
        data_file,
        .read_write,
    );
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (!safeFile(stat)) return error.UnsafeTranscriptFile;
    if (stat.size != prior_committed_len) return error.IncompleteTranscript;
    try file.writePositionalAll(io_mod.getIo(), bytes, prior_committed_len);
    try file.sync(io_mod.getIo());

    const encoded = try encodeMetadata(alloc, .{
        .session_id = session_id,
        .committed_len = next_committed_len,
        .position = position,
    });
    defer alloc.free(encoded);
    try io_mod.durableReplaceVerifiedWithOps(
        alloc,
        session_dir,
        metadata_file,
        encoded,
        metadata_ops,
    );
    return next_committed_len;
}

pub fn restampComplete(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    committed_len: u64,
    position: session_replay.CommitPosition,
) !void {
    if (committed_len == 0) return error.IncompleteTranscript;
    var file = try io_mod.openExistingRegularFile(
        session_dir.dir,
        data_file,
        .read_only,
    );
    defer file.close(io_mod.getIo());
    const stat = try file.stat(io_mod.getIo());
    if (!safeFile(stat)) return error.UnsafeTranscriptFile;
    if (stat.size != committed_len) return error.IncompleteTranscript;

    const encoded = try encodeMetadata(alloc, .{
        .session_id = session_id,
        .committed_len = committed_len,
        .position = position,
    });
    defer alloc.free(encoded);
    try io_mod.durableReplaceVerified(alloc, session_dir, metadata_file, encoded);
}

pub fn admit(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    current_position: session_replay.CommitPosition,
) !Admission {
    return admitWithCurrentPosition(
        alloc,
        session_dir,
        session_id,
        current_position,
    );
}

pub fn admitActive(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
) !Admission {
    return admitWithCurrentPosition(alloc, session_dir, session_id, null);
}

fn admitWithCurrentPosition(
    alloc: std.mem.Allocator,
    session_dir: *io_mod.VerifiedDir,
    session_id: []const u8,
    current_position: ?session_replay.CommitPosition,
) !Admission {
    var metadata_handle = io_mod.openExistingRegularFile(
        session_dir.dir,
        metadata_file,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return classifyMissingData(session_dir),
        else => return .corrupt,
    };
    defer metadata_handle.close(io_mod.getIo());
    const metadata_stat = metadata_handle.stat(io_mod.getIo()) catch return .corrupt;
    if (!safeFile(metadata_stat) or
        metadata_stat.size == 0 or
        metadata_stat.size > max_metadata_bytes)
    {
        return .corrupt;
    }
    const metadata_bytes = io_mod.readFileToEnd(
        alloc,
        &metadata_handle,
        max_metadata_bytes,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .corrupt,
    };
    defer alloc.free(metadata_bytes);
    var metadata = decodeMetadata(alloc, metadata_bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .corrupt,
    };
    defer metadata.deinit(alloc);

    var data = io_mod.openExistingRegularFile(
        session_dir.dir,
        data_file,
        .read_only,
    ) catch |err| switch (err) {
        error.FileNotFound => return .incomplete,
        else => return .corrupt,
    };
    errdefer data.close(io_mod.getIo());
    const data_stat = data.stat(io_mod.getIo()) catch return .corrupt;
    const admission_class = classify(.{
        .session_identity = if (std.mem.eql(u8, metadata.session_id, session_id))
            .matching
        else
            .mismatched,
        .data_safety = if (safeFile(data_stat)) .safe else .unsafe,
        .metadata = .valid,
        .committed_len = metadata.committed_len,
        .data_len = data_stat.size,
        .stored_position = metadata.position,
        .current_position = current_position,
    });
    return switch (admission_class) {
        .exact => .{ .exact = .{
            .file = data,
            .committed_len = metadata.committed_len,
        } },
        .incomplete => blk: {
            data.close(io_mod.getIo());
            break :blk .incomplete;
        },
        .corrupt => blk: {
            data.close(io_mod.getIo());
            break :blk .corrupt;
        },
    };
}

fn classifyMissingData(session_dir: *io_mod.VerifiedDir) Admission {
    var data = io_mod.openExistingRegularFile(
        session_dir.dir,
        data_file,
        .read_only,
    ) catch |err| return switch (err) {
        error.FileNotFound => .missing,
        else => .corrupt,
    };
    defer data.close(io_mod.getIo());
    const stat = data.stat(io_mod.getIo()) catch return .corrupt;
    return if (safeFile(stat) and stat.size > 0) .incomplete else .corrupt;
}

fn safeFile(stat: std.Io.File.Stat) bool {
    return stat.kind == .file and stat.nlink == 1 and
        stat.permissions.toMode() & 0o777 == 0o600;
}

fn appendDataForTest(session_dir: *io_mod.VerifiedDir, bytes: []const u8) !void {
    var file = try io_mod.openExistingRegularFile(
        session_dir.dir,
        data_file,
        .read_write,
    );
    defer file.close(io_mod.getIo());
    const offset = try file.length(io_mod.getIo());
    try file.writePositionalAll(io_mod.getIo(), bytes, offset);
    try file.sync(io_mod.getIo());
}

fn writeInt(writer: *std.Io.Writer, comptime T: type, value: T) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    try writer.writeAll(&bytes);
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Cursor, len: usize) ![]const u8 {
        if (len > self.remaining()) return error.InvalidTranscriptMetadata;
        defer self.pos += len;
        return self.bytes[self.pos..][0..len];
    }

    fn readInt(self: *Cursor, comptime T: type) !T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn remaining(self: Cursor) usize {
        return self.bytes.len - self.pos;
    }
};

const AdmissionClass = enum {
    exact,
    incomplete,
    corrupt,
};

const IdentityState = enum {
    matching,
    mismatched,
};

const DataSafety = enum {
    safe,
    unsafe,
};

const MetadataState = enum {
    valid,
    missing,
    invalid,
};

const AdmissionFacts = struct {
    session_identity: IdentityState,
    data_safety: DataSafety,
    metadata: MetadataState,
    committed_len: u64,
    data_len: u64,
    stored_position: session_replay.CommitPosition,
    current_position: ?session_replay.CommitPosition,
};

fn classify(facts: AdmissionFacts) AdmissionClass {
    if (facts.session_identity == .mismatched or
        facts.data_safety == .unsafe or
        facts.metadata == .invalid or
        facts.committed_len > facts.data_len)
    {
        return .corrupt;
    }
    if (facts.metadata == .missing or
        facts.committed_len == 0 or
        facts.committed_len != facts.data_len or
        (if (facts.current_position) |current_position|
            !positionsEqual(facts.stored_position, current_position)
        else
            false))
    {
        return .incomplete;
    }
    return .exact;
}

fn positionsEqual(
    lhs: session_replay.CommitPosition,
    rhs: session_replay.CommitPosition,
) bool {
    return std.meta.eql(lhs, rhs);
}

pub const max_control_sequence_bytes: usize = 4096;

pub const GrammarError = error{
    InvalidTranscriptGrammar,
    TruncatedTranscriptSequence,
};

/// Returns the largest prefix ending on a complete terminal-grammar token.
/// The caller retains the suffix and prepends it to the next fixed-size read.
pub fn validatedPrefix(bytes: []const u8, eof: bool) GrammarError!usize {
    var index: usize = 0;
    var safe_end: usize = 0;
    while (index < bytes.len) {
        const byte = bytes[index];
        if (byte == 0x1b) {
            const sequence_len = try controlSequenceLen(bytes[index..], eof);
            if (sequence_len == null) return safe_end;
            index += sequence_len.?;
            safe_end = index;
            continue;
        }
        if (byte == '\n' or byte == '\r' or byte == '\t') {
            index += 1;
            safe_end = index;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) return error.InvalidTranscriptGrammar;
        if (byte < 0x80) {
            index += 1;
            safe_end = index;
            continue;
        }

        const sequence_len = utf8SequenceLen(byte) orelse
            return error.InvalidTranscriptGrammar;
        if (sequence_len > bytes.len - index) {
            if (eof) return error.TruncatedTranscriptSequence;
            return safe_end;
        }
        const sequence = bytes[index..][0..sequence_len];
        if (!std.unicode.utf8ValidateSlice(sequence)) {
            return error.InvalidTranscriptGrammar;
        }
        index += sequence_len;
        safe_end = index;
    }
    return safe_end;
}

fn utf8SequenceLen(first: u8) ?usize {
    if (first >= 0xc2 and first <= 0xdf) return 2;
    if (first >= 0xe0 and first <= 0xef) return 3;
    if (first >= 0xf0 and first <= 0xf4) return 4;
    return null;
}

fn controlSequenceLen(bytes: []const u8, eof: bool) GrammarError!?usize {
    if (bytes.len < 2) return incompleteSequence(eof);
    return switch (bytes[1]) {
        '[' => sgrSequenceLen(bytes, eof),
        ']' => osc8SequenceLen(bytes, eof),
        else => error.InvalidTranscriptGrammar,
    };
}

fn sgrSequenceLen(bytes: []const u8, eof: bool) GrammarError!?usize {
    var index: usize = 2;
    while (index < bytes.len and index < max_control_sequence_bytes) : (index += 1) {
        const byte = bytes[index];
        if (byte == 'm') return index + 1;
        if (!std.ascii.isDigit(byte) and byte != ';' and byte != ':') {
            return error.InvalidTranscriptGrammar;
        }
    }
    if (index >= max_control_sequence_bytes) return error.InvalidTranscriptGrammar;
    return incompleteSequence(eof);
}

fn osc8SequenceLen(bytes: []const u8, eof: bool) GrammarError!?usize {
    if (bytes.len < 4) return incompleteSequence(eof);
    if (bytes[2] != '8' or bytes[3] != ';') return error.InvalidTranscriptGrammar;

    var index: usize = 4;
    var saw_uri_separator = false;
    while (index < bytes.len and index < max_control_sequence_bytes) : (index += 1) {
        const byte = bytes[index];
        if (byte >= 0x80) {
            const sequence_len = utf8SequenceLen(byte) orelse
                return error.InvalidTranscriptGrammar;
            if (sequence_len > bytes.len - index) return incompleteSequence(eof);
            if (!std.unicode.utf8ValidateSlice(bytes[index..][0..sequence_len])) {
                return error.InvalidTranscriptGrammar;
            }
            index += sequence_len - 1;
            continue;
        }
        if (!saw_uri_separator) {
            if (byte == ';') {
                saw_uri_separator = true;
                continue;
            }
            if (byte < 0x20 or byte == 0x7f or byte == 0x1b) {
                return error.InvalidTranscriptGrammar;
            }
            continue;
        }
        if (byte == 0x1b) {
            if (index + 1 >= bytes.len) return incompleteSequence(eof);
            if (bytes[index + 1] != '\\') return error.InvalidTranscriptGrammar;
            return index + 2;
        }
        if ((byte < 0x20 and byte != '\t') or byte == 0x7f) {
            return error.InvalidTranscriptGrammar;
        }
    }
    if (index >= max_control_sequence_bytes) return error.InvalidTranscriptGrammar;
    return incompleteSequence(eof);
}

fn incompleteSequence(eof: bool) GrammarError!?usize {
    if (eof) return error.TruncatedTranscriptSequence;
    return null;
}

const test_position = session_replay.CommitPosition{
    .log_generation = [_]u8{0x11} ** 16,
    .through_seq = 7,
    .through_event_id = [_]u8{0x22} ** 16,
    .through_event_log_bytes = 4096,
};

test "transcript admission is exact only for a complete matching record" {
    const exact = classify(.{
        .session_identity = .matching,
        .data_safety = .safe,
        .metadata = .valid,
        .committed_len = 128,
        .data_len = 128,
        .stored_position = test_position,
        .current_position = test_position,
    });
    try std.testing.expectEqual(AdmissionClass.exact, exact);

    var advanced = test_position;
    advanced.through_seq += 1;
    try std.testing.expectEqual(AdmissionClass.incomplete, classify(.{
        .session_identity = .matching,
        .data_safety = .safe,
        .metadata = .valid,
        .committed_len = 128,
        .data_len = 128,
        .stored_position = test_position,
        .current_position = advanced,
    }));
    try std.testing.expectEqual(AdmissionClass.incomplete, classify(.{
        .session_identity = .matching,
        .data_safety = .safe,
        .metadata = .valid,
        .committed_len = 128,
        .data_len = 129,
        .stored_position = test_position,
        .current_position = test_position,
    }));
    try std.testing.expectEqual(AdmissionClass.corrupt, classify(.{
        .session_identity = .matching,
        .data_safety = .safe,
        .metadata = .valid,
        .committed_len = 129,
        .data_len = 128,
        .stored_position = test_position,
        .current_position = test_position,
    }));
    try std.testing.expectEqual(AdmissionClass.corrupt, classify(.{
        .session_identity = .mismatched,
        .data_safety = .safe,
        .metadata = .valid,
        .committed_len = 128,
        .data_len = 128,
        .stored_position = test_position,
        .current_position = test_position,
    }));
}

test "transcript metadata round trips complete session identity and position" {
    const alloc = std.testing.allocator;
    const encoded = try encodeMetadata(alloc, .{
        .session_id = "session-1",
        .committed_len = 8192,
        .position = test_position,
    });
    defer alloc.free(encoded);

    var decoded = try decodeMetadata(alloc, encoded);
    defer decoded.deinit(alloc);
    try std.testing.expectEqualStrings("session-1", decoded.session_id);
    try std.testing.expectEqual(@as(u64, 8192), decoded.committed_len);
    try std.testing.expectEqual(test_position, decoded.position);

    try std.testing.expectError(
        error.InvalidTranscriptMetadata,
        decodeMetadata(alloc, encoded[0 .. encoded.len - 1]),
    );
}

test "transcript grammar releases only complete UTF-8 SGR and OSC 8 sequences" {
    const styled_link = "ok \x1b[38;2;1;2;3m\x1b]8;id=fx;https://example.com\x1b\\é\x1b]8;;\x1b\\\r\n";
    try std.testing.expectEqual(
        styled_link.len,
        try validatedPrefix(styled_link, true),
    );

    try std.testing.expectEqual(
        @as(usize, 3),
        try validatedPrefix("ok \xe2", false),
    );
    try std.testing.expectError(
        error.TruncatedTranscriptSequence,
        validatedPrefix("ok \xe2", true),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        try validatedPrefix("ok \x1b]8;;https://example.com", false),
    );
    try std.testing.expectError(
        error.InvalidTranscriptGrammar,
        validatedPrefix("unsafe\x1b[2J", true),
    );
    try std.testing.expectError(
        error.InvalidTranscriptGrammar,
        validatedPrefix("unsafe\x07", true),
    );
    try std.testing.expectError(
        error.InvalidTranscriptGrammar,
        validatedPrefix("\x1b]8;;https://example.com/\xff\x1b\\", true),
    );
}

test "transcript record admits exact committed bytes and treats a staged tail as incomplete" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = io_mod.VerifiedDir{ .dir = try temp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer verified.close();

    try publishComplete(
        alloc,
        &verified,
        "session-1",
        test_position,
        "one\r\ntwo\r\n",
    );
    var exact = try admit(
        alloc,
        &verified,
        "session-1",
        test_position,
    );
    defer exact.deinit();
    try std.testing.expect(exact == .exact);
    var buffer: [32]u8 = undefined;
    const read = try exact.exact.readAt(&buffer, 0);
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", buffer[0..read]);

    try appendDataForTest(&verified, "staged");
    var incomplete = try admit(
        alloc,
        &verified,
        "session-1",
        test_position,
    );
    defer incomplete.deinit();
    try std.testing.expect(incomplete == .incomplete);
}

test "active transcript admits a complete older display prefix but rejects a staged tail" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = io_mod.VerifiedDir{ .dir = try temp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer verified.close();

    try publishComplete(
        alloc,
        &verified,
        "session-1",
        test_position,
        "one\r\ntwo\r\n",
    );
    var advanced = test_position;
    advanced.through_seq += 1;
    advanced.through_event_log_bytes += 64;

    var cold = try admit(alloc, &verified, "session-1", advanced);
    defer cold.deinit();
    try std.testing.expect(cold == .incomplete);

    var active = try admitActive(alloc, &verified, "session-1");
    defer active.deinit();
    try std.testing.expect(active == .exact);

    try appendDataForTest(&verified, "staged");
    var staged = try admitActive(alloc, &verified, "session-1");
    defer staged.deinit();
    try std.testing.expect(staged == .incomplete);
}

test "transcript append advances committed bytes only after durable data" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = io_mod.VerifiedDir{ .dir = try temp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer verified.close();

    try publishComplete(alloc, &verified, "session-1", test_position, "one\r\n");
    var advanced = test_position;
    advanced.through_seq += 1;
    advanced.through_event_log_bytes += 64;
    advanced.through_event_id = [_]u8{0x33} ** 16;
    const committed = try appendAndCommit(
        alloc,
        &verified,
        "session-1",
        "one\r\n".len,
        advanced,
        "two\r\n",
    );
    try std.testing.expectEqual(@as(u64, 10), committed);

    var exact = try admit(alloc, &verified, "session-1", advanced);
    defer exact.deinit();
    try std.testing.expect(exact == .exact);
    var buffer: [16]u8 = undefined;
    const read = try exact.exact.readAt(&buffer, 0);
    try std.testing.expectEqualStrings("one\r\ntwo\r\n", buffer[0..read]);
}

test "transcript metadata can restamp unchanged complete bytes" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = io_mod.VerifiedDir{ .dir = try temp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer verified.close();
    try publishComplete(alloc, &verified, "session-1", test_position, "stable");
    var advanced = test_position;
    advanced.through_seq += 1;
    advanced.through_event_id = [_]u8{0x55} ** 16;
    advanced.through_event_log_bytes += 32;
    try restampComplete(alloc, &verified, "session-1", 6, advanced);

    var exact = try admit(alloc, &verified, "session-1", advanced);
    defer exact.deinit();
    try std.testing.expect(exact == .exact);
}

test "transcript metadata failure leaves a recoverable staged tail" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = io_mod.VerifiedDir{ .dir = try temp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer verified.close();
    try publishComplete(alloc, &verified, "session-1", test_position, "first");

    const Failure = struct {
        fn syncFile(_: ?*anyopaque, _: std.Io.File) anyerror!void {
            return error.NoSpaceLeft;
        }
    };
    var advanced = test_position;
    advanced.through_seq += 1;
    advanced.through_event_id = [_]u8{0x66} ** 16;
    advanced.through_event_log_bytes += 32;
    try std.testing.expectError(
        error.DurableReplacePreRenameFailed,
        appendAndCommitWithOps(
            alloc,
            &verified,
            "session-1",
            5,
            advanced,
            " second",
            .{ .sync_file = Failure.syncFile },
        ),
    );

    var admission = try admit(alloc, &verified, "session-1", advanced);
    defer admission.deinit();
    try std.testing.expect(admission == .incomplete);
}

test "transcript admission fails closed for unsafe or malformed committed files" {
    const alloc = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var verified = io_mod.VerifiedDir{ .dir = try temp.dir.openDir(
        std.testing.io,
        ".",
        .{ .iterate = true, .follow_symlinks = false },
    ) };
    defer verified.close();
    try publishComplete(alloc, &verified, "session-1", test_position, "safe");

    var data = try io_mod.openExistingRegularFile(
        verified.dir,
        data_file,
        .read_write,
    );
    try data.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o644),
    );
    data.close(std.testing.io);
    var unsafe = try admit(alloc, &verified, "session-1", test_position);
    defer unsafe.deinit();
    try std.testing.expect(unsafe == .corrupt);

    var writable = try verified.dir.openFile(std.testing.io, data_file, .{ .mode = .read_write });
    try writable.setPermissions(
        std.testing.io,
        std.Io.File.Permissions.fromMode(0o600),
    );
    writable.close(std.testing.io);
    try io_mod.durableReplaceVerified(alloc, &verified, metadata_file, "malformed");
    var malformed = try admit(alloc, &verified, "session-1", test_position);
    defer malformed.deinit();
    try std.testing.expect(malformed == .corrupt);
}
