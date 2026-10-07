#!/usr/bin/env bash
# Rebuilds every shop/reward icon (two Blender runs through the machine-wide heavy lock) and the sheets.
# Usage (from anywhere): art/blender/icons_shop/run_all.sh
set -euo pipefail
cd "$(dirname "$0")/../../.."
RUN=tools/blender-run.sh
S=art/blender/icons_shop/icons.py
"$RUN" "$S" -- CrateCommon CrateUncommon CrateRare CrateEpic CrateLegendary PassAutoCollect PassAutoCash PassAutoMerge \
	PassDoubleOrbs PassDoubleCash PassVipCracker PassCrateKey CashPack1 CashPack2 CashPack3 AuraPack1 AuraPack2 2>&1 | grep -E -i "error|traceback|^ICON" &
"$RUN" "$S" -- CashPack4 CashPack5 CashPack6 GemPack1 GemPack2 GemPack3 Heart Timer Crown Fire Gift2 Fans AuraPack3 AuraPack4 2>&1 |
	grep -E -i "error|traceback|^ICON" &
wait
python3 art/blender/icons_shop/make_sheet.py
