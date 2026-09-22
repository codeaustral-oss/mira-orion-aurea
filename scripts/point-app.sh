#!/usr/bin/env bash
# Point a built Mira bundle at the decision proxy.
#
#   ./scripts/point-app.sh <path-to-app-bundle>
#
# Why this is its own script: the installer and a manual run need the same two
# facts written into a bundle — where the proxy is, and the key that proves the
# app may call it. Neither belongs in the repository or in the signed binary, so
# the app resolves them from its Info.plist at launch, and this script is the
# only thing that puts them there. Given a device bundle it also works for a
# simulator product if a build should talk to a gated proxy.
#
# The address defaults to the hosted proxy. For local work against a proxy on
# this Mac, set MIRA_PROXY_LEGACY_HOST to the Mac's LAN address and the bundle
# gets the legacy `MIRAProxyHost` key instead (the app reads that as
# http://<host>:8791). MIRA_PROXY_URL overrides the hosted address.
#
# The key comes from the repo's .env, is never printed, and is never logged.
# Without one, every proxy key is removed from the bundle: a build that cannot
# authenticate must reach nothing but its own loopback, not a remote server.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="${1:-}"
if [[ -z "$APP" ]]; then
  echo "usage: $0 <path-to-app-bundle>" >&2
  exit 2
fi
if [[ ! -d "$APP" ]]; then
  echo "no app bundle at $APP" >&2
  exit 1
fi
PLIST="$APP/Info.plist"
if [[ ! -f "$PLIST" ]]; then
  echo "no Info.plist inside $APP" >&2
  exit 1
fi

# The hosted proxy answers on both names; mira-api is the one every resolver
# already knows (the pretty mira.codeaustral.com was created later and some
# caches still hold its old NXDOMAIN).
HOSTED_URL="${MIRA_PROXY_URL:-https://mira-api.codeaustral.com}"
LEGACY_HOST="${MIRA_PROXY_LEGACY_HOST:-}"
read -r HOSTED_URL <<<"$HOSTED_URL" || true
read -r LEGACY_HOST <<<"$LEGACY_HOST" || true

remove_key() {
  /usr/libexec/PlistBuddy -c "Delete :$1" "$PLIST" >/dev/null 2>&1 || true
}

write_key() {
  remove_key "$1"
  /usr/libexec/PlistBuddy -c "Add :$1 string $2" "$PLIST" >/dev/null
}

# One value out of the repo .env. It is read, never sourced: a stray line in a
# developer's .env must not run as shell, and the value must not reach the
# terminal. Quotes are stripped; whitespace around the value is not part of it.
env_value() {
  local name="$1" line value
  [[ -f "$ROOT/.env" ]] || return 1
  line="$(grep -E "^${name}=" "$ROOT/.env" | tail -n 1 || true)"
  [[ -n "$line" ]] || return 1
  value="${line#*=}"
  value="${value%$'\r'}"
  value="${value#\"}"
  value="${value%\"}"
  value="${value#\'}"
  value="${value%\'}"
  read -r value <<<"$value" || true
  [[ -n "$value" ]] || return 1
  printf '%s' "$value"
}

KEY="$(env_value MIRA_PROXY_KEY || true)"

if [[ -z "$KEY" ]]; then
  remove_key MIRAProxyURL
  remove_key MIRAProxyHost
  remove_key MIRAProxyKey
  echo "  proxy: none (no MIRA_PROXY_KEY in .env) — this build stays on loopback"
  exit 0
fi

if [[ -n "$LEGACY_HOST" ]]; then
  remove_key MIRAProxyURL
  write_key MIRAProxyHost "$LEGACY_HOST"
  echo "  proxy: http://$LEGACY_HOST:8791 (local network override)"
else
  if [[ ! "$HOSTED_URL" =~ ^https?://[^/]+ ]]; then
    echo "MIRA_PROXY_URL must be a full http(s) URL; got: $HOSTED_URL" >&2
    exit 2
  fi
  remove_key MIRAProxyHost
  write_key MIRAProxyURL "$HOSTED_URL"
  echo "  proxy: $HOSTED_URL"
fi

write_key MIRAProxyKey "$KEY"
echo "  proxy key: attached (read from .env, value not printed)"
