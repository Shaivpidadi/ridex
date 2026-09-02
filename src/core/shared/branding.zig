//! ridex branding. The fork ships as `ridex`; FreeRide is the gateway
//! and model brand. Internal identifiers (FX_* env vars, config keys,
//! module names) deliberately keep the upstream names so rebases stay
//! cheap — only user-visible surfaces read from here.

/// The command users type. Used in help/usage text and handoff hints
/// ("Continue session with: ridex --resume ...").
pub const cli_name = "ridex";

/// Display name for banners and headers.
pub const display_name = "ridex";
