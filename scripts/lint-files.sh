#!/usr/bin/env bash
# Formats, lints and type-checks only the given Luau files (for work in progress, when the
# whole tree may not pass scripts/check.sh yet).
# Usage: scripts/lint-files.sh src/server/World/Hub.luau [more files...]
set -uo pipefail
cd "$(dirname "$0")/.."
LSP_VERSION="$(luau-lsp --version | tr -d '[:space:]')"
DEFS="${LUAU_DEFS:-.cache/globalTypes-$LSP_VERSION.d.luau}"
MAP="sourcemap-$$.json"
trap 'rm -f "$MAP"' EXIT
status=0
echo "== stylua"
stylua "$@" || status=1
echo "== selene"
selene "$@" 2>&1 | tail -n 40 || status=1
echo "== luau-lsp"
rojo sourcemap chad.project.json -o "$MAP" >/dev/null
luau-lsp analyze --sourcemap="$MAP" --definitions="$DEFS" "$@" 2>&1 | grep -v '^\[INFO\]\|^\[WARN\]' | tail -n 60
[ "${PIPESTATUS[0]}" -eq 0 ] || status=1
[ $status -eq 0 ] && echo "OK" || echo "FAILED"
exit $status
