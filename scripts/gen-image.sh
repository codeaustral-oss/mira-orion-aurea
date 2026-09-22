#!/usr/bin/env bash
# Generate one image through the Codex built-in image_gen tool (imagegen skill).
#
# Usage:
#   ./scripts/gen-image.sh <out-absolute-path> "<image prompt>" [quality]
#
# quality: high (default) | medium | draft
#
# The prompt is handed to `codex exec` on stdin so shell quoting can never
# corrupt the art direction. Codex saves the bitmap under
# $CODEX_HOME/generated_images and then copies the selected output to <out>.

set -euo pipefail

OUT="$1"
PROMPT="$2"
QUALITY="${3:-high}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

if [[ -z "${OUT:-}" || -z "${PROMPT:-}" ]]; then
  echo "usage: gen-image.sh <out-absolute-path> \"<prompt>\" [quality]" >&2
  exit 2
fi

case "$QUALITY" in
  draft)  QUALITY_LINE="Use the fastest reasonable draft settings (low quality). This is a concept sketch." ;;
  medium) QUALITY_LINE="Use medium quality." ;;
  *)      QUALITY_LINE="Use high quality. This is a final, production-bound asset." ;;
esac

mkdir -p "$(dirname "$OUT")"

RUN_DIR="$(mktemp -d)"
trap 'rm -rf "$RUN_DIR"' EXIT

cat > "$RUN_DIR/instruction.md" <<EOF
Use your built-in image generation tool (the imagegen skill's image_gen tool) to generate exactly ONE image.

Image prompt:
---
$PROMPT
---

$QUALITY_LINE

Rules for this run:
- Generate exactly one image. Do not generate variants, do not generate a second image.
- Do not create, write, edit or delete any file other than the final copy described below.
- Do not read or explore the repository. Do not run any command other than the copy and verify steps.
- After generating, copy the resulting image file to this exact absolute path: $OUT
- Verify the file exists at that path.
- Your final message must be a single line: DONE <absolute path> <bytes>
EOF

touch "$RUN_DIR/start.marker"

codex exec \
  -C "$ROOT" \
  -s workspace-write \
  --skip-git-repo-check \
  --ephemeral \
  -o "$RUN_DIR/last.txt" \
  - < "$RUN_DIR/instruction.md" >"$RUN_DIR/run.log" 2>&1 || true

# Some CLI builds generate the bitmap but never hand the payload to the model,
# so the copy step inside the run cannot happen. The image is still on disk
# under the host's generated_images: take the newest one this run produced.
if [[ ! -s "$OUT" ]]; then
  candidates="$(find "${CODEX_HOME:-$HOME/.codex}/generated_images" -type f -name '*.png' -newer "$RUN_DIR/start.marker" 2>/dev/null || true)"
  if [[ -n "$candidates" ]]; then
    newest="$(printf '%s\n' "$candidates" | xargs ls -t 2>/dev/null | head -1 || true)"
    if [[ -n "${newest:-}" && -s "$newest" ]]; then
      mkdir -p "$(dirname "$OUT")"
      cp "$newest" "$OUT"
    fi
  fi
fi

if [[ ! -s "$OUT" ]]; then
  echo "FAIL $OUT (missing or empty)" >&2
  tail -30 "$RUN_DIR/run.log" >&2
  exit 1
fi

echo "OK $OUT $(stat -c%s "$OUT") bytes"
