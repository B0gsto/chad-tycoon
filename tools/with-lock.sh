#!/bin/bash
# Usage: tools/with-lock.sh <name> [options] -- <command...>
# Runs <command> while holding the machine-wide lock <name> (tools/locks.py): studio, heavy, assets.<game>,
# gen.<game>. Waits in a FIFO queue; the lock is released when the command ends or this process dies (kill -9
# included). Order when nesting: studio, heavy, assets, gen. Nested calls for a lock an ancestor holds are no-ops.
# Options: --owner TEXT --game NAME --priority 0-9 --slots N --timeout SEC --cap SEC --enforce-cap --quiet
# Exit: the command's status; 75 = timed out waiting for the lock; 127 = command not found.
# Examples:
#   tools/with-lock.sh studio -- python3 tools/studio-shot.py ...
#   tools/with-lock.sh assets.ChadTycoon --timeout 600 -- python3 tools/assets.py ...
TOOLS="$(cd "$(dirname "$0")" && pwd)"
[ $# -ge 1 ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
exec python3 "$TOOLS/locks.py" run "$@"
