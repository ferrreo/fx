const std = @import("std");
const debug_trace = @import("../shared/debug_trace.zig");
const host_target = @import("../hosts/target.zig");
const io_mod = @import("../shared/io.zig");
const profile_paths = @import("../shared/profile_paths.zig");
const secret = @import("secret.zig");

const Allocator = std.mem.Allocator;

pub const client_id = "app_EMoamEEZ73f0CkXaXp7hrann";
pub const issuer = "https://auth.openai.com";
const schema_version: i64 = 1;
const expiry_skew_ms: i64 = 60 * 1000;
const max_auth_file_bytes: usize = 64 * 1024;
const mutation_lock_file_name = "codex-auth.lock";
const mutation_lock_deadline_ms: u64 = 2000;

pub fn refresh_deadline_ms(expires_at_ms: i64) i64 {
    return expires_at_ms -| expiry_skew_ms;
}

pub const DeleteOutcome = enum {
    deleted,
    missing,
    deleted_not_durable,
};

pub const Session = struct {
    issuer: []u8,
    client_id: []u8,
    access_token: []u8,
    refresh_token: []u8,
    expires_at_ms: i64,
    account_id: ?[]u8 = null,
    device_id: ?[]u8 = null,

    pub fn deinit(self: *Session, alloc: Allocator) void {
        alloc.free(self.issuer);
        alloc.free(self.client_id);
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        if (self.account_id) |value| alloc.free(value);
        if (self.device_id) |value| alloc.free(value);
        self.* = undefined;
    }

    pub fn expired(self: Session, now_ms: i64) bool {
        return refresh_deadline_ms(self.expires_at_ms) <= now_ms;
    }
};

pub const Mutation = struct {
    fx_dir: io_mod.VerifiedDir,
    lock: io_mod.TimedAdvisoryLock,

    pub fn deinit(self: *Mutation) void {
        self.lock.release();
        self.fx_dir.close();
        self.* = undefined;
    }

    pub fn load(self: *Mutation, alloc: Allocator) !?Session {
        return loadFromDir(alloc, &self.fx_dir.dir);
    }

    pub fn save(self: *Mutation, alloc: Allocator, session: Session) !void {
        const text = try stringify(alloc, session);
        defer secret.zeroAndFree(alloc, text);
        try io_mod.durableReplaceVerified(alloc, &self.fx_dir, profile_paths.codex_auth_file_name, text);
    }

    pub fn delete(self: *Mutation) !DeleteOutcome {
        self.fx_dir.dir.deleteFile(io_mod.getIo(), profile_paths.codex_auth_file_name) catch |err| switch (err) {
            error.FileNotFound => return .missing,
            else => return err,
        };
        return .deleted;
    }
};

pub fn load(alloc: Allocator) !?Session {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return null;
    var home_dir = std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }) catch |err| {
        debug_trace.logf("auth", "codex session load skipped step=home err={s}", .{@errorName(err)});
        return null;
    };
    defer home_dir.close(io_mod.getIo());
    var fx_dir = home_dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => {
            debug_trace.logf("auth", "codex session load skipped step=fx_dir err={s}", .{@errorName(err)});
            return null;
        },
    };
    defer fx_dir.close(io_mod.getIo());
    return loadFromDir(alloc, &fx_dir);
}

fn loadFromDir(alloc: Allocator, fx_dir: *std.Io.Dir) !?Session {
    var file = fx_dir.openFile(io_mod.getIo(), profile_paths.codex_auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close(io_mod.getIo());
    const bytes = io_mod.readFileToEnd(alloc, &file, max_auth_file_bytes) catch |err| return err;
    defer secret.zeroAndFree(alloc, bytes);
    return try parse(alloc, bytes);
}

pub fn saveNewSession(alloc: Allocator, session: Session) !void {
    if (comptime host_target.is_wasm) return error.CodexAuthUnavailable;
    var mutation = try beginMutation();
    defer mutation.deinit();
    try mutation.save(alloc, session);
}

pub fn beginExistingMutation() !?Mutation {
    if (comptime host_target.is_wasm) return null;
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();
    const fx_dir = home_dir.dir.openDir(io_mod.getIo(), profile_paths.root_dir_name, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    return try lockMutation(.{ .dir = fx_dir });
}

fn beginMutation() !Mutation {
    const home = io_mod.getenv("HOME") orelse return error.HomeNotSet;
    var home_dir = io_mod.VerifiedDir{
        .dir = try std.Io.Dir.openDirAbsolute(io_mod.getIo(), home, .{ .iterate = true }),
    };
    defer home_dir.close();
    const fx_dir = try io_mod.openOrCreateVerifiedPrivateDir(&home_dir, profile_paths.root_dir_name);
    return lockMutation(fx_dir);
}

fn lockMutation(open_fx_dir: io_mod.VerifiedDir) !Mutation {
    var fx_dir = open_fx_dir;
    errdefer fx_dir.close();
    var lock = try io_mod.acquireTimedAdvisoryLock(&fx_dir, mutation_lock_file_name, mutation_lock_deadline_ms);
    errdefer lock.release();
    return .{ .fx_dir = fx_dir, .lock = lock };
}

pub fn parse(alloc: Allocator, bytes: []const u8) !Session {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidAuthSession;
    const object = parsed.value.object;
    const version = object.get("version") orelse return error.InvalidAuthSession;
    if (version != .integer or version.integer != schema_version) return error.InvalidAuthSession;

    const owned_issuer = try dupeRequired(alloc, object, "issuer");
    errdefer alloc.free(owned_issuer);
    const owned_client_id = try dupeRequired(alloc, object, "client_id");
    errdefer alloc.free(owned_client_id);
    const access_token = try dupeRequired(alloc, object, "access_token");
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try dupeRequired(alloc, object, "refresh_token");
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_at_ms = try requiredInteger(object, "expires_at_ms");
    const account_id = try dupeOptional(alloc, object, "account_id");
    errdefer if (account_id) |value| alloc.free(value);
    const device_id = try dupeOptional(alloc, object, "device_id");
    errdefer if (device_id) |value| alloc.free(value);

    return .{
        .issuer = owned_issuer,
        .client_id = owned_client_id,
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
        .device_id = device_id,
    };
}

pub fn stringify(alloc: Allocator, session: Session) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    const writer = &out.writer;
    try writer.writeAll("{\"version\":1");
    try writeField(writer, "issuer", session.issuer);
    try writeField(writer, "client_id", session.client_id);
    try writeField(writer, "access_token", session.access_token);
    try writeField(writer, "refresh_token", session.refresh_token);
    try writer.print(",\"expires_at_ms\":{d}", .{session.expires_at_ms});
    if (session.account_id) |value| try writeField(writer, "account_id", value);
    if (session.device_id) |value| try writeField(writer, "device_id", value);
    try writer.writeAll("}\n");
    return out.toOwnedSlice();
}

fn writeField(writer: *std.Io.Writer, name: []const u8, value: []const u8) !void {
    try writer.writeAll(",");
    try std.json.Stringify.value(name, .{}, writer);
    try writer.writeAll(":");
    try std.json.Stringify.value(value, .{}, writer);
}

fn dupeRequired(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) ![]u8 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return alloc.dupe(u8, value.string);
}

fn dupeOptional(alloc: Allocator, object: std.json.ObjectMap, key: []const u8) !?[]u8 {
    const value = object.get(key) orelse return null;
    if (value == .null) return null;
    if (value != .string or value.string.len == 0) return error.InvalidAuthSession;
    return try alloc.dupe(u8, value.string);
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidAuthSession;
    if (value != .integer) return error.InvalidAuthSession;
    return value.integer;
}

test "codex session round trips tokens and account identity" {
    const alloc = std.testing.allocator;
    var session = Session{
        .issuer = try alloc.dupe(u8, issuer),
        .client_id = try alloc.dupe(u8, client_id),
        .access_token = try alloc.dupe(u8, "access"),
        .refresh_token = try alloc.dupe(u8, "refresh"),
        .expires_at_ms = 42,
        .account_id = try alloc.dupe(u8, "acct_1"),
        .device_id = try alloc.dupe(u8, "dev_1"),
    };
    defer session.deinit(alloc);

    const text = try stringify(alloc, session);
    defer secret.zeroAndFree(alloc, text);
    var parsed = try parse(alloc, text);
    defer parsed.deinit(alloc);
    try std.testing.expectEqualStrings("access", parsed.access_token);
    try std.testing.expectEqualStrings("acct_1", parsed.account_id.?);
    try std.testing.expectEqual(@as(i64, 42), parsed.expires_at_ms);
}
