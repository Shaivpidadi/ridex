const std = @import("std");
const io_mod = @import("../shared/io.zig");
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

/// Runtime default: `FX_DEFAULT_PROVIDER` overrides the compiled
/// default. The upstream e2e/SDK suites model gateway-first flows
/// (Vercel login, team selection, gateway model auto-pick); CI pins
/// them to `gateway` through this instead of rewriting hundreds of
/// fixtures — and users get an escape hatch for free.
pub fn defaultProvider() ProviderId {
    const fallback = surface_default orelse default_provider;
    const raw = io_mod.getenv("FX_DEFAULT_PROVIDER") orelse return fallback;
    return parse(raw) orelse fallback;
}

/// Per-surface compiled default, set by host mains before any session
/// starts. The CLI/TUI ships freeride-first; the embeddable SDK
/// surfaces (napi/wasm) declare `.gateway` because their public
/// contract is gateway-shaped — `apiKey` is required and maps to
/// AI_GATEWAY_API_KEY. `FX_DEFAULT_PROVIDER` still overrides.
pub var surface_default: ?ProviderId = null;

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
    if (selected == .host_managed) return true;
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

test "compiled default is freeride and the env override parses provider names" {
    // The zig suites run without FX_DEFAULT_PROVIDER (only the TS
    // e2e/SDK CI jobs pin it to gateway), so the compiled default
    // must hold here.
    try std.testing.expectEqual(ProviderId.freeride, defaultProvider());
    try std.testing.expectEqual(ProviderId.freeride, default_provider);
}
