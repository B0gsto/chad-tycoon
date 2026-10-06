#!/usr/bin/env bash
# Usage: tools/ci-install-tools.sh
# Installs the pinned toolchain on a Linux x86_64 CI runner into ~/.local/bin (on the PATH of GitHub's ubuntu runners;
# also appended to $GITHUB_PATH when run inside Actions) and pre-fetches the Roblox type definitions that
# scripts/check.sh reads, into .cache/globalTypes-<luau-lsp version>.d.luau.
# Versions match rokit.toml (what local development uses); bump both together, and the sha256 sums below
# (shasum -a 256 <zip> of each release asset).
set -euo pipefail
cd "$(dirname "$0")/.."

ROJO=7.7.0 LUNE=0.10.5 SELENE=0.31.0 STYLUA=2.5.2 LUAU_LSP=1.70.0
BIN="$HOME/.local/bin"
mkdir -p "$BIN" .cache
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fetch() { # repo tag asset binary sha256
	curl -fsSL --retry 3 -o "$TMP/$4.zip" "https://github.com/$1/releases/download/$2/$3"
	echo "$5  $TMP/$4.zip" | sha256sum -c --quiet -
	unzip -oq "$TMP/$4.zip" "$4" -d "$BIN"
	chmod +x "$BIN/$4"
}
fetch rojo-rbx/rojo "v$ROJO" "rojo-$ROJO-linux-x86_64.zip" rojo \
	22503e5839864f9d7c2171c48b536fc229f2cc4d8774c9cc149f60941d864073
fetch lune-org/lune "v$LUNE" "lune-$LUNE-linux-x86_64.zip" lune \
	1fb5dee6a1afa1d300092805c6e660fe06144d29dd68c45cf6956f040667f791
fetch Kampfkarren/selene "$SELENE" "selene-$SELENE-linux.zip" selene \
	dac452422747999ec4919bbb8bb52992b66aae533b60022bf005669de8616671
fetch JohnnyMorganz/StyLua "v$STYLUA" "stylua-linux-x86_64.zip" stylua \
	bcb0d855e91f102f28a370e850f8566b3b44b79e6274d806ea5246837c0fd5ab
fetch JohnnyMorganz/luau-lsp "$LUAU_LSP" "luau-lsp-linux-x86_64.zip" luau-lsp \
	4ff08890ea0d4b6d9de25fdff1a4c87e0dc9f2e45d782c894e83475e51d55813

# Same file name scripts/check.sh computes from `luau-lsp --version`, so it finds it and skips its own download.
curl -fsSL --retry 3 -o ".cache/globalTypes-$LUAU_LSP.d.luau" \
	"https://raw.githubusercontent.com/JohnnyMorganz/luau-lsp/$LUAU_LSP/scripts/globalTypes.d.luau"

if [ -n "${GITHUB_PATH:-}" ]; then
	echo "$BIN" >>"$GITHUB_PATH"
fi
for t in rojo lune selene stylua luau-lsp; do
	echo "$t: $("$BIN/$t" --version 2>&1 | head -1)"
done
