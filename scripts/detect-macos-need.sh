#!/usr/bin/env bash
# Decide whether a change needs the macOS arm64 checks.
#
# Usage: detect-macos-need.sh <base-revision> <head-revision>
#
# macOS runs only when a change touches behavior that can differ on macOS: a
# Zig file with macOS-specific code before or after the change, build.zig, the
# macOS signing script, the native SDK addon, an E2E file listed in
# tests/e2e/macos-platform-tests.json, or the macOS checks themselves. Set
# MACOS_REQUESTED to a reason to force the checks, and SDK_NATIVE_REQUESTED=true
# to force the native SDK addon check.
#
# Writes needed=true|false and sdk_native=true|false to $GITHUB_OUTPUT and the
# reasons to $GITHUB_STEP_SUMMARY when those files are set.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  printf 'usage: %s <base-revision> <head-revision>\n' "$0" >&2
  exit 2
fi

base="$1"
head="$2"
platform_list=tests/e2e/macos-platform-tests.json

needed=false
sdk_native=false
reasons=()

require() {
  needed=true
  reasons+=("$1")
}

require_sdk_native() {
  sdk_native=true
  require "$1"
}

has_macos_code() {
  local content
  content="$({ git show "$head:$1" 2>/dev/null; git show "$base:$1" 2>/dev/null; } || true)"
  grep -Eq '\.macos|isDarwin|[Dd]arwin' <<<"$content"
}

is_platform_test() {
  jq -e --arg file "$1" 'index($file) != null' "$platform_list" >/dev/null
}

if [ -n "${MACOS_REQUESTED:-}" ]; then
  require "$MACOS_REQUESTED"
fi
if [ "${SDK_NATIVE_REQUESTED:-false}" = true ]; then
  require_sdk_native "native SDK addon check requested"
fi

while IFS= read -r path; do
  case "$path" in
    .github/workflows/macos.yml)
      require_sdk_native "$path: the macOS checks changed" ;;
    scripts/detect-macos-need.sh | scripts/smoke-binary.sh | tests/e2e/ci-run-files.sh | "$platform_list")
      require "$path: the macOS checks changed" ;;
    build.zig | build.zig.zon)
      require "$path: build configuration changed" ;;
    scripts/sign-and-notarize-macos.sh)
      require "$path: macOS signing changed" ;;
    src/napi_*.zig | sdk/node.js | sdk/tests/test-node-napi.mjs)
      require_sdk_native "$path: native SDK addon changed" ;;
    *.zig)
      if has_macos_code "$path"; then
        require "$path: contains macOS-specific code"
      fi ;;
    tests/e2e/*.test.ts)
      name="${path#tests/e2e/}"
      if [[ "$name" != */* ]] && is_platform_test "$name"; then
        require "$path: macOS platform E2E file changed"
      fi ;;
  esac
done < <(git diff --name-only --no-renames "$base" "$head")

if [ "$needed" = true ]; then
  printf 'macOS arm64 checks needed:\n'
  printf '  %s\n' "${reasons[@]}"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    {
      printf '### macOS arm64 checks run\n\n'
      printf -- '- %s\n' "${reasons[@]}"
    } >>"$GITHUB_STEP_SUMMARY"
  fi
else
  printf 'No macOS-specific change; macOS arm64 checks skipped.\n'
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf 'No macOS-specific change; macOS arm64 checks skipped.\n' >>"$GITHUB_STEP_SUMMARY"
  fi
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'needed=%s\n' "$needed"
    printf 'sdk_native=%s\n' "$sdk_native"
  } >>"$GITHUB_OUTPUT"
fi
