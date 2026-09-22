#!/usr/bin/env bash
# Start the local decision proxy with the key loaded from .env.
#
# The key is read from .env (gitignored) and exported into the process
# environment. It is never printed, never logged, and never sent to the app.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "No .env found. Copy .env.example to .env and set TYPESAFE_API_KEY." >&2
  exit 1
fi

# shellcheck disable=SC1091
set -a
source .env
set +a

if [[ -z "${TYPESAFE_API_KEY:-}" ]]; then
  echo "TYPESAFE_API_KEY is empty in .env — the proxy will answer from deterministic rules." >&2
fi

exec node server/server.mjs
