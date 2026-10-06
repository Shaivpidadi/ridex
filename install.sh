#!/usr/bin/env sh
# ridex installer. Run with:
#
#   curl -sSL https://api.free-ride.xyz/ridex.sh | sh
#
# What this does:
#   1. Downloads the latest ridex release tarball for this OS/arch from
#      github.com/Shaivpidadi/ridex/releases (checksum-verified) and
#      installs `ridex` (launcher) + `ridex-agent` (binary) into
#      ~/.local/bin, plus the freeride operations skill into
#      ~/.local/share/ridex/skills/.
#   2. Installs the FreeRide gateway via the existing FreeRide
#      installer (uv tool install freeride-gateway) — ridex's models
#      all come from the local FreeRide daemon on 127.0.0.1:11343.
#   3. Runs `ridex doctor`.
#
# Env knobs:
#   RIDEX_REF=ridex-v0.1.0   install a specific release tag
#   RIDEX_SKIP_GATEWAY=1     skip the FreeRide gateway install
#   FREERIDE_REF / FREERIDE_TELEMETRY pass through to the gateway installer

set -e

REPO="Shaivpidadi/ridex"
BIN_DIR="$HOME/.local/bin"
SHARE_DIR="$HOME/.local/share/ridex"

print() { printf '%s\n' "$*"; }
err() { printf 'error: %s\n' "$*" >&2; exit 1; }

print "ridex installer"
print ""

# ── OS / arch → release asset name ─────────────────────────────────
os="$(uname -s)"
arch="$(uname -m)"
case "$os" in
    Darwin) os_tag="macos" ;;
    Linux)  os_tag="linux" ;;
    *) err "ridex is not yet supported on $os (macOS and Linux only for now)." ;;
esac
case "$arch" in
    arm64|aarch64) arch_tag="aarch64" ;;
    x86_64|amd64)  arch_tag="x86_64" ;;
    *) err "unsupported architecture: $arch" ;;
esac
asset="ridex-${os_tag}-${arch_tag}.tar.gz"

# ── resolve the release tag ────────────────────────────────────────
if [ -n "${RIDEX_REF:-}" ]; then
    tag="$RIDEX_REF"
else
    # Latest release whose tag starts with ridex-v (the repo is a fork
    # of vercel-labs/fx; upstream-style tags are ignored).
    tag="$(curl -fsSL "https://api.github.com/repos/$REPO/releases?per_page=30" \
        | grep -o '"tag_name": *"ridex-v[^"]*"' | head -1 | cut -d'"' -f4)"
    [ -n "$tag" ] || err "could not find a ridex-v* release on github.com/$REPO"
fi
print "Installing $tag ($asset)..."

# ── download + verify ──────────────────────────────────────────────
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
base="https://github.com/$REPO/releases/download/$tag"
curl -fsSL -o "$tmp/$asset" "$base/$asset" || err "download failed: $base/$asset"
if curl -fsSL -o "$tmp/$asset.sha256" "$base/$asset.sha256" 2>/dev/null; then
    (
        cd "$tmp"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum -c "$asset.sha256" >/dev/null
        else
            expected="$(cut -d' ' -f1 "$asset.sha256")"
            actual="$(shasum -a 256 "$asset" | cut -d' ' -f1)"
            [ "$expected" = "$actual" ]
        fi
    ) || err "checksum verification failed for $asset"
else
    print "warning: no checksum published for $asset; skipping verification"
fi

# ── install ────────────────────────────────────────────────────────
mkdir -p "$BIN_DIR" "$SHARE_DIR"
tar -xzf "$tmp/$asset" -C "$tmp"
install -m 755 "$tmp/ridex-agent" "$BIN_DIR/ridex-agent"
install -m 755 "$tmp/ridex" "$BIN_DIR/ridex"
rm -rf "$SHARE_DIR/skills"
cp -R "$tmp/skills" "$SHARE_DIR/skills"
print "Installed ridex + ridex-agent to $BIN_DIR"

# ── FreeRide gateway ───────────────────────────────────────────────
if [ "${RIDEX_SKIP_GATEWAY:-0}" = "1" ]; then
    print "Skipping FreeRide gateway install (RIDEX_SKIP_GATEWAY=1)."
else
    print ""
    print "Installing the FreeRide gateway (ridex's model backend)..."
    curl -sSL https://api.free-ride.xyz/install.sh | sh
fi

# ── PATH + verify ──────────────────────────────────────────────────
print ""
case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
        print "Note: $BIN_DIR is not on your PATH yet. Run:"
        print "  export PATH=\"\$HOME/.local/bin:\$PATH\""
        print "Or add that line to your ~/.zshrc / ~/.bashrc."
        ;;
esac

print "Checking the install..."
"$BIN_DIR/ridex" doctor || true

print ""
print "Done. Try:  ridex ask \"reply with the single word pong\""
