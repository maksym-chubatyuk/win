#!/usr/bin/env bash
# Writes the changes made in third_party/madeira and its wine, FEX and dxmt submodules back into
# patches/, keeping each patch's note (the text before its first diff). Prebuilt binaries
# (app/Madeira/*.dll, *.a) are build outputs and stay out.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MADEIRA="$ROOT/third_party/madeira"

save() { # <patch file> <git dir> [pathspec...]
  local patch="$1" dir="$2"; shift 2
  local note=""
  [[ -f "$patch" ]] && note="$(sed '/^diff --git /,$d' "$patch")"
  { [[ -n "$note" ]] && printf '%s\n\n' "$note"; git -C "$dir" diff --ignore-submodules=all -- "$@"; } > "$patch.new"
  mv "$patch.new" "$patch"
  echo "  ${patch#"$ROOT"/}: $(grep -c '^diff --git ' "$patch" || true) files"
}

mkdir -p "$ROOT/patches/submodules"
save "$ROOT/patches/madeira.patch" "$MADEIRA" . ':!*.dll' ':!*.a'
for sub in wine FEX dxmt; do
  save "$ROOT/patches/submodules/$sub.patch" "$MADEIRA/$sub" .
done
