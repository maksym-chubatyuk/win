#!/usr/bin/env bash
# Applies patches/*.patch to the Madeira submodule, and patches/submodules/<path>.patch to Madeira's
# own submodule at <path> (wine, FEX, dxmt). Safe to run again: a patch already applied is skipped.
# A patch that no longer fits (upstream changed those lines) stops with its name; fix that patch and
# run again.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MADEIRA="$ROOT/third_party/madeira"

apply() { # <git dir> <patch file>
  local dir="$1" patch="$2" name="${2#"$ROOT"/}"
  if git -C "$dir" apply --reverse --check --whitespace=nowarn "$patch" 2>/dev/null; then
    echo "  applied already: $name"
  elif git -C "$dir" apply --check --whitespace=nowarn "$patch" 2>/dev/null; then
    git -C "$dir" apply --whitespace=nowarn "$patch"
    echo "  applied:         $name"
  else
    echo "error: $name does not apply to $(git -C "$dir" rev-parse --short HEAD):" >&2
    git -C "$dir" apply --check --whitespace=nowarn "$patch" >&2 || true
    exit 1
  fi
}

echo "Applying patches to Madeira ($(git -C "$MADEIRA" rev-parse --short HEAD))"
for patch in "$ROOT"/patches/*.patch; do
  apply "$MADEIRA" "$patch"
done
while IFS= read -r patch; do
  sub="${patch#"$ROOT"/patches/submodules/}"
  apply "$MADEIRA/${sub%.patch}" "$patch"
done < <(find "$ROOT/patches/submodules" -name '*.patch' | sort)
