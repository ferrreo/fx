const std = @import("std");
const io_mod = @import("../shared/io.zig");
const types = @import("../shared/types.zig");
const codex_catalog = @import("codex_catalog");

pub const env_name = "FX_PROVIDER";

pub const Kind = enum {
    ai_gateway,
    openrouter,
    codex,

    pub fn label(self: Kind) []const u8 {
        return switch (self) {
            .ai_gateway => "AI Gateway",
            .openrouter => "OpenRouter",
            .codex => "ChatGPT Codex",
        };
    }

    pub fn streamProtocol(self: Kind) StreamProtocol {
        return switch (self) {
            .ai_gateway => .ai_sdk,
            .openrouter => .openai_chat,
            .codex => .openai_responses,
        };
    }

    pub fn fromCredentialSource(source: types.CredentialSource) Kind {
        return switch (source) {
            .openrouter_api_key => .openrouter,
            .codex_login => .codex,
            .vercel_oidc_token, .ai_gateway_api_key, .fx_login, .stored_key => .ai_gateway,
        };
    }
};

pub const StreamProtocol = enum {
    ai_sdk,
    openai_chat,
    openai_responses,
};

pub const openrouter_chat_url = "https://openrouter.ai/api/v1/chat/completions";
pub const openrouter_models_url = "https://openrouter.ai/api/v1/models";
pub const openrouter_credits_url = "https://openrouter.ai/api/v1/credits";
pub const codex_chat_url = "https://chatgpt.com/backend-api/codex/responses";

pub const default_openrouter_model = "openai/gpt-5.2";
pub const default_codex_model = codex_catalog.default_model;

const Configured = struct {
    mutex: std.Io.Mutex = .init,
    kind: Kind = .ai_gateway,
    set: bool = false,
};

var configured: Configured = .{};

pub fn parse(text: []const u8) ?Kind {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "ai-gateway") or
        std.ascii.eqlIgnoreCase(trimmed, "ai_gateway") or
        std.ascii.eqlIgnoreCase(trimmed, "vercel") or
        std.ascii.eqlIgnoreCase(trimmed, "gateway"))
        return .ai_gateway;
    if (std.ascii.eqlIgnoreCase(trimmed, "openrouter")) return .openrouter;
    if (std.ascii.eqlIgnoreCase(trimmed, "codex") or
        std.ascii.eqlIgnoreCase(trimmed, "chatgpt") or
        std.ascii.eqlIgnoreCase(trimmed, "openai-codex"))
        return .codex;
    return null;
}

pub fn persistName(kind: Kind) []const u8 {
    return switch (kind) {
        .ai_gateway => "ai-gateway",
        .openrouter => "openrouter",
        .codex => "codex",
    };
}

pub fn setConfigured(kind: Kind) void {
    configured.mutex.lockUncancelable(io_mod.getIo());
    defer configured.mutex.unlock(io_mod.getIo());
    configured.kind = kind;
    configured.set = true;
}

pub fn clearConfigured() void {
    configured.mutex.lockUncancelable(io_mod.getIo());
    defer configured.mutex.unlock(io_mod.getIo());
    configured.kind = .ai_gateway;
    configured.set = false;
}

pub fn resolve() Kind {
    if (io_mod.getenv(env_name)) |raw| {
        if (parse(raw)) |kind| return kind;
    }

    configured.mutex.lockUncancelable(io_mod.getIo());
    const remembered = if (configured.set) configured.kind else null;
    configured.mutex.unlock(io_mod.getIo());
    if (remembered) |kind| return kind;

    return resolveFromEnvAndSource(null);
}

/// Env override, then the active credential, then OpenRouter auto-detect.
/// Ignores in-process `setConfigured` so startup model choice follows the
/// credential that was just loaded rather than a previous request.
pub fn resolveFromEnvAndSource(source: ?types.CredentialSource) Kind {
    if (io_mod.getenv(env_name)) |raw| {
        if (parse(raw)) |kind| return kind;
    }
    if (source) |value| return Kind.fromCredentialSource(value);
    const openrouter_key = nonEmptyEnv("OPENROUTER_API_KEY");
    const gateway_key = nonEmptyEnv("AI_GATEWAY_API_KEY");
    const oidc = nonEmptyEnv("VERCEL_OIDC_TOKEN");
    if (openrouter_key and !gateway_key and !oidc) return .openrouter;
    return .ai_gateway;
}

pub fn chatUrl(kind: Kind, fallback: []const u8) []const u8 {
    return switch (kind) {
        .ai_gateway => fallback,
        .openrouter => openrouter_chat_url,
        .codex => codex_chat_url,
    };
}

pub fn defaultModel(kind: Kind, fallback: []const u8) []const u8 {
    return switch (kind) {
        .ai_gateway => fallback,
        .openrouter => default_openrouter_model,
        .codex => default_codex_model,
    };
}

/// OpenRouter ids are `provider/model`. Codex Responses ids are bare model names.
pub fn modelFits(kind: Kind, model: []const u8) bool {
    const has_provider_prefix = std.mem.findScalar(u8, model, '/') != null;
    return switch (kind) {
        .ai_gateway => true,
        .openrouter => has_provider_prefix,
        .codex => !has_provider_prefix,
    };
}

fn nonEmptyEnv(name: []const u8) bool {
    const value = io_mod.getenv(name) orelse return false;
    return std.mem.trim(u8, value, " \t\r\n").len > 0;
}

test "parse accepts stable provider names" {
    try std.testing.expectEqual(Kind.ai_gateway, parse("ai-gateway").?);
    try std.testing.expectEqual(Kind.ai_gateway, parse("vercel").?);
    try std.testing.expectEqual(Kind.openrouter, parse("OpenRouter").?);
    try std.testing.expectEqual(Kind.codex, parse("codex").?);
    try std.testing.expectEqual(Kind.codex, parse("chatgpt").?);
    try std.testing.expect(parse("unknown") == null);
}

test "credential source maps onto the matching inference provider" {
    try std.testing.expectEqual(Kind.openrouter, Kind.fromCredentialSource(.openrouter_api_key));
    try std.testing.expectEqual(Kind.codex, Kind.fromCredentialSource(.codex_login));
    try std.testing.expectEqual(Kind.ai_gateway, Kind.fromCredentialSource(.fx_login));
}

test "model ids match the provider catalog shape" {
    try std.testing.expect(modelFits(.openrouter, "openai/gpt-5.2"));
    try std.testing.expect(!modelFits(.openrouter, "gpt-5.3-codex"));
    try std.testing.expect(modelFits(.codex, "gpt-5.3-codex"));
    try std.testing.expect(!modelFits(.codex, "zai/glm-5.2"));
    try std.testing.expect(modelFits(.ai_gateway, "zai/glm-5.2"));
}
