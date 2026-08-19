const std = @import("std");
const host = @import("../hosts/host.zig");
const io_mod = @import("../shared/io.zig");
const oauth = @import("oauth.zig");
const oauth_transport = @import("oauth_transport.zig");
const secret = @import("secret.zig");
const codex_session = @import("codex_session.zig");

const Allocator = std.mem.Allocator;

pub const authorize_url = "https://auth.openai.com/oauth/authorize";
pub const token_url = "https://auth.openai.com/oauth/token";
pub const device_code_url = "https://auth.openai.com/api/accounts/deviceauth/usercode";
pub const device_token_url = "https://auth.openai.com/api/accounts/deviceauth/token";
pub const device_redirect_uri = "https://auth.openai.com/deviceauth/callback";
pub const verification_url = "https://auth.openai.com/codex/device";
pub const pkce_redirect_port: u16 = 1455;
pub const pkce_redirect_uri = "http://localhost:1455/auth/callback";
pub const scopes = "openid profile email offline_access";
const account_claim = "https://api.openai.com/auth";

pub const LoginError = error{
    LoginTimedOut,
    NoRefreshToken,
    InvalidOAuthResponse,
    AccessDenied,
    CodexAuthUnavailable,
};

pub const DeviceAuthorization = struct {
    device_auth_id: []u8,
    user_code: []u8,
    expires_in: i64,
    interval: i64,

    pub fn deinit(self: *DeviceAuthorization, alloc: Allocator) void {
        alloc.free(self.device_auth_id);
        alloc.free(self.user_code);
        self.* = undefined;
    }
};

pub const TokenBundle = struct {
    access_token: []u8,
    refresh_token: []u8,
    expires_in: i64,
    id_token: ?[]u8 = null,

    pub fn deinit(self: *TokenBundle, alloc: Allocator) void {
        secret.zeroAndFree(alloc, self.access_token);
        secret.zeroAndFree(alloc, self.refresh_token);
        if (self.id_token) |value| secret.zeroAndFree(alloc, value);
        self.* = undefined;
    }
};

pub fn requestDeviceAuthorization(
    alloc: Allocator,
    transport: oauth_transport.Provider,
) !DeviceAuthorization {
    const payload = try jsonObject(alloc, &.{
        .{ .key = "client_id", .value = codex_session.client_id },
    });
    defer alloc.free(payload);
    const bytes = try postJson(alloc, transport, device_code_url, payload, .{});
    defer secret.zeroAndFree(alloc, bytes);
    return parseDeviceAuthorization(alloc, bytes);
}

pub fn pollDeviceAuthorization(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    device: DeviceAuthorization,
    cancel_flag: *std.atomic.Value(bool),
    deadline: std.Io.Clock.Timestamp,
) !oauth.PollResult {
    const payload = try jsonObject(alloc, &.{
        .{ .key = "device_auth_id", .value = device.device_auth_id },
        .{ .key = "user_code", .value = device.user_code },
    });
    defer secret.zeroAndFree(alloc, payload);

    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = device_token_url,
        .payload = payload,
        .cancel_flag = cancel_flag,
        .deadline = deadline,
    });
    defer response.deinit(alloc);

    if (response.disposition != .accepted) {
        if (response.http_status == .forbidden or
            response.http_status == .not_found or
            response.http_status == .precondition_required)
        {
            return .pending;
        }
        return error.OAuthRequestFailed;
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, response.body, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const object = parsed.value.object;
    const authorization_code = requiredString(object, "authorization_code") catch return .pending;
    const code_verifier = requiredString(object, "code_verifier") catch return .pending;
    var tokens = try exchangeAuthorizationCode(
        alloc,
        transport,
        authorization_code,
        code_verifier,
        device_redirect_uri,
    );
    defer if (tokens.id_token) |value| secret.zeroAndFree(alloc, value);
    const refresh = tokens.refresh_token;
    tokens.refresh_token = &.{};
    return .{ .success = .{
        .access_token = tokens.access_token,
        .refresh_token = refresh,
        .expires_in = tokens.expires_in,
        .scope = try alloc.dupe(u8, scopes),
        .token_type = try alloc.dupe(u8, "Bearer"),
    } };
}

pub fn exchangeAuthorizationCode(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    code: []const u8,
    code_verifier: []const u8,
    redirect_uri: []const u8,
) !TokenBundle {
    const payload = try jsonObject(alloc, &.{
        .{ .key = "grant_type", .value = "authorization_code" },
        .{ .key = "client_id", .value = codex_session.client_id },
        .{ .key = "code", .value = code },
        .{ .key = "redirect_uri", .value = redirect_uri },
        .{ .key = "code_verifier", .value = code_verifier },
    });
    defer secret.zeroAndFree(alloc, payload);
    const bytes = try postJson(alloc, transport, token_url, payload, .{});
    defer secret.zeroAndFree(alloc, bytes);
    return parseTokenBundle(alloc, bytes);
}

pub fn refreshTokens(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    refresh_token: []const u8,
) !TokenBundle {
    const payload = try jsonObject(alloc, &.{
        .{ .key = "grant_type", .value = "refresh_token" },
        .{ .key = "client_id", .value = codex_session.client_id },
        .{ .key = "refresh_token", .value = refresh_token },
    });
    defer secret.zeroAndFree(alloc, payload);
    const bytes = try postJson(alloc, transport, token_url, payload, .{});
    defer secret.zeroAndFree(alloc, bytes);
    return parseTokenBundle(alloc, bytes);
}

pub fn extractAccountId(alloc: Allocator, access_token: []const u8) !?[]u8 {
    const first_dot = std.mem.indexOfScalar(u8, access_token, '.') orelse return null;
    const second_dot = std.mem.indexOfScalarPos(u8, access_token, first_dot + 1, '.') orelse return null;
    const payload = access_token[first_dot + 1 .. second_dot];
    const decoded = decodeBase64Url(alloc, payload) catch return null;
    defer alloc.free(decoded);

    var parsed = std.json.parseFromSlice(std.json.Value, alloc, decoded, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const auth = parsed.value.object.get(account_claim) orelse return null;
    if (auth != .object) return null;
    const account = auth.object.get("chatgpt_account_id") orelse return null;
    if (account != .string or account.string.len == 0) return null;
    return try alloc.dupe(u8, account.string);
}

pub fn sessionFromTokens(
    alloc: Allocator,
    tokens: *TokenBundle,
    previous_device_id: ?[]const u8,
    now_ms: i64,
) !codex_session.Session {
    const expires_at_ms = try oauth.expiry_timestamp_ms(now_ms, tokens.expires_in);
    const account_id = try extractAccountId(alloc, tokens.access_token);
    errdefer if (account_id) |value| alloc.free(value);
    const device_id = if (previous_device_id) |value|
        try alloc.dupe(u8, value)
    else
        try randomHex(alloc, 16);
    errdefer alloc.free(device_id);

    const session = codex_session.Session{
        .issuer = try alloc.dupe(u8, codex_session.issuer),
        .client_id = try alloc.dupe(u8, codex_session.client_id),
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .expires_at_ms = expires_at_ms,
        .account_id = account_id,
        .device_id = device_id,
    };
    tokens.access_token = &.{};
    tokens.refresh_token = &.{};
    return session;
}

pub fn runDeviceLogin(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url_opener: host.UrlOpener,
) !void {
    var device = try requestDeviceAuthorization(alloc, transport);
    defer device.deinit(alloc);

    try writeStdout("Open ");
    try writeStdout(verification_url);
    try writeStdout("\nCode: ");
    try writeStdout(device.user_code);
    try writeStdout("\n\nWaiting for ChatGPT authorization...\n");
    _ = url_opener.open(alloc, verification_url) catch false;

    var cancel = std.atomic.Value(bool).init(false);
    const interval_ms: u64 = @intCast(@max(device.interval, 5) * 1000);
    const deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(device.expires_in * 1000)),
    });

    while (true) {
        const now = std.Io.Clock.Timestamp.now(io_mod.getIo(), .awake);
        if (now.raw.nanoseconds >= deadline.raw.nanoseconds) return LoginError.LoginTimedOut;
        io_mod.sleep(interval_ms * std.time.ns_per_ms);
        const poll_deadline = std.Io.Clock.Timestamp.fromNow(io_mod.getIo(), .{
            .clock = .awake,
            .raw = .fromMilliseconds(15_000),
        });
        const result = pollDeviceAuthorization(alloc, transport, device, &cancel, poll_deadline) catch |err| switch (err) {
            error.AuthorizationPending => continue,
            else => return err,
        };
        switch (result) {
            .pending, .slow_down => continue,
            .success => |token_set| {
                var tokens = TokenBundle{
                    .access_token = token_set.access_token,
                    .refresh_token = token_set.refresh_token orelse return LoginError.NoRefreshToken,
                    .expires_in = token_set.expires_in,
                };
                const owned_scope = token_set.scope;
                defer alloc.free(owned_scope);
                const owned_type = token_set.token_type;
                defer alloc.free(owned_type);
                defer tokens.deinit(alloc);
                var session = try sessionFromTokens(alloc, &tokens, null, io_mod.milliTimestamp());
                defer session.deinit(alloc);
                try codex_session.saveNewSession(alloc, session);
                try writeStdout("Signed in to ChatGPT Codex.\n");
                return;
            },
        }
    }
}

fn parseDeviceAuthorization(alloc: Allocator, bytes: []const u8) !DeviceAuthorization {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const object = parsed.value.object;
    const device_auth_id = try alloc.dupe(u8, try requiredString(object, "device_auth_id"));
    errdefer alloc.free(device_auth_id);
    const user_code = try alloc.dupe(u8, try requiredString(object, "user_code"));
    errdefer alloc.free(user_code);
    const expires_in = requiredInteger(object, "expires_in") catch 900;
    const interval = requiredInteger(object, "interval") catch 5;
    return .{
        .device_auth_id = device_auth_id,
        .user_code = user_code,
        .expires_in = expires_in,
        .interval = interval,
    };
}

fn parseTokenBundle(alloc: Allocator, bytes: []const u8) !TokenBundle {
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidOAuthResponse;
    const object = parsed.value.object;
    const access_token = try alloc.dupe(u8, try requiredString(object, "access_token"));
    errdefer secret.zeroAndFree(alloc, access_token);
    const refresh_token = try alloc.dupe(u8, try requiredString(object, "refresh_token"));
    errdefer secret.zeroAndFree(alloc, refresh_token);
    const expires_in = requiredInteger(object, "expires_in") catch 3600;
    const id_token = if (object.get("id_token")) |value|
        if (value == .string) try alloc.dupe(u8, value.string) else null
    else
        null;
    return .{
        .access_token = access_token,
        .refresh_token = refresh_token,
        .expires_in = expires_in,
        .id_token = id_token,
    };
}

fn jsonObject(alloc: Allocator, fields: []const struct { key: []const u8, value: []const u8 }) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(alloc);
    errdefer out.deinit();
    try out.writer.writeByte('{');
    for (fields, 0..) |field, i| {
        if (i > 0) try out.writer.writeByte(',');
        try std.json.Stringify.value(field.key, .{}, &out.writer);
        try out.writer.writeByte(':');
        try std.json.Stringify.value(field.value, .{}, &out.writer);
    }
    try out.writer.writeByte('}');
    return out.toOwnedSlice();
}

fn postJson(
    alloc: Allocator,
    transport: oauth_transport.Provider,
    url: []const u8,
    payload: []const u8,
    bounds: struct {
        cancel_flag: ?*std.atomic.Value(bool) = null,
        deadline: ?std.Io.Clock.Timestamp = null,
    },
) ![]u8 {
    var response = try transport.execute(alloc, .{
        .method = .post_json,
        .url = url,
        .payload = payload,
        .cancel_flag = bounds.cancel_flag,
        .deadline = bounds.deadline,
    });
    defer response.deinit(alloc);
    if (response.disposition != .accepted) return error.OAuthRequestFailed;
    return response.takeBody();
}

fn requiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const value = object.get(key) orelse return error.InvalidOAuthResponse;
    if (value != .string or value.string.len == 0) return error.InvalidOAuthResponse;
    return value.string;
}

fn requiredInteger(object: std.json.ObjectMap, key: []const u8) !i64 {
    const value = object.get(key) orelse return error.InvalidOAuthResponse;
    return switch (value) {
        .integer => value.integer,
        else => error.InvalidOAuthResponse,
    };
}

fn decodeBase64Url(alloc: Allocator, encoded: []const u8) ![]u8 {
    const decoder = std.base64.url_safe_no_pad.Decoder;
    const decoded_len = try decoder.calcSizeForSlice(encoded);
    const out = try alloc.alloc(u8, decoded_len);
    errdefer alloc.free(out);
    try decoder.decode(out, encoded);
    return out;
}

fn randomHex(alloc: Allocator, nbytes: usize) ![]u8 {
    const bytes = try alloc.alloc(u8, nbytes);
    defer alloc.free(bytes);
    io_mod.getIo().random(bytes);
    const hex = try alloc.alloc(u8, nbytes * 2);
    const charset = "0123456789abcdef";
    for (bytes, 0..) |byte, i| {
        hex[i * 2] = charset[byte >> 4];
        hex[i * 2 + 1] = charset[byte & 0x0f];
    }
    return hex;
}

fn writeStdout(text: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io_mod.getIo(), text);
}

test "jwt extractor reads chatgpt_account_id claim" {
    const payload_json = "{\"https://api.openai.com/auth\":{\"chatgpt_account_id\":\"acct_99\"}}";
    var encoded_buf: [256]u8 = undefined;
    const encoded_len = std.base64.url_safe_no_pad.Encoder.calcSize(payload_json.len);
    _ = std.base64.url_safe_no_pad.Encoder.encode(encoded_buf[0..encoded_len], payload_json);
    const token = try std.fmt.allocPrint(std.testing.allocator, "aaa.{s}.sig", .{encoded_buf[0..encoded_len]});
    defer std.testing.allocator.free(token);
    const account_id = (try extractAccountId(std.testing.allocator, token)).?;
    defer std.testing.allocator.free(account_id);
    try std.testing.expectEqualStrings("acct_99", account_id);
}

test "device authorization parser keeps poll interval" {
    const json = "{\"device_auth_id\":\"d1\",\"user_code\":\"ABCD\",\"expires_in\":600,\"interval\":7}";
    var device = try parseDeviceAuthorization(std.testing.allocator, json);
    defer device.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("d1", device.device_auth_id);
    try std.testing.expectEqual(@as(i64, 7), device.interval);
}
