const std = @import("std");
const types = @import("../shared/types.zig");

pub const ProviderId = enum {
    freeride,
    gateway,
    codex,
    grok,
};

/// ridex ships FreeRide-first: the local gateway is the default route
/// and needs no login. Vercel/Codex/Grok stay available via
/// `ridex provider <name>`.
pub const default_provider: ProviderId = .freeride;

/// FreeRide's smart-router preset tuned for agent tool-calling.
pub const freeride_default_model = "freeride/coding";

/// The provider whose transport endpoints (chat URL, model catalog
/// base) are currently active. Published from the provider runtime's
/// no-fail adoption boundary so URL resolution in the gateway builtin
/// can pick FreeRide's loopback endpoints without threading the
/// provider through every call site.
pub var active_transport_provider: ProviderId = default_provider;

pub const ProviderSelection = struct {
    provider: ProviderId,
    model: []const u8,
};

pub fn parse(value: []const u8) ?ProviderId {
    if (std.ascii.eqlIgnoreCase(value, "freeride")) return .freeride;
    if (std.ascii.eqlIgnoreCase(value, "gateway")) return .gateway;
    if (std.ascii.eqlIgnoreCase(value, "codex")) return .codex;
    if (std.ascii.eqlIgnoreCase(value, "grok")) return .grok;
    return null;
}

pub fn authorizesCredential(provider: ProviderId, source: ?types.CredentialSource) bool {
    const selected = source orelse return false;
    return switch (provider) {
        // FreeRide's credential is synthetic (the local gateway ignores
        // the bearer), so any non-subscription source authorizes it.
        .freeride => selected != .chatgpt_subscription and selected != .grok_subscription,
        .gateway => selected != .chatgpt_subscription and selected != .grok_subscription,
        .codex => selected == .chatgpt_subscription,
        .grok => selected == .grok_subscription,
    };
}

test "explicit providers authorize only their own credential origins" {
    try std.testing.expect(authorizesCredential(.gateway, .ai_gateway_api_key));
    try std.testing.expect(authorizesCredential(.gateway, .fx_login));
    try std.testing.expect(!authorizesCredential(.gateway, .chatgpt_subscription));
    try std.testing.expect(authorizesCredential(.codex, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.codex, .ai_gateway_api_key));
    try std.testing.expect(!authorizesCredential(.codex, null));
    try std.testing.expect(authorizesCredential(.grok, .grok_subscription));
    try std.testing.expect(!authorizesCredential(.grok, .chatgpt_subscription));
    try std.testing.expect(!authorizesCredential(.gateway, .grok_subscription));
}

test "provider parsing exposes gateway codex and grok" {
    try std.testing.expectEqual(ProviderId.gateway, parse("gateway").?);
    try std.testing.expectEqual(ProviderId.codex, parse("CODEX").?);
    try std.testing.expectEqual(ProviderId.grok, parse("GROK").?);
    try std.testing.expect(parse("openai-codex") == null);
    try std.testing.expect(parse("") == null);
}
