#!/bin/bash
# Usage: tools/with-heavy.sh [options] -- <command...>
# Runs <command> in one slot of the machine-wide heavy-job pool (2 slots: Blender renders, Xcode builds, perf
# runs, anything that eats RAM on this 16 GB Mac). Waits FIFO; released when the command ends or this process
# dies. --slots 2 takes both slots (perf/gate runs; pair with --priority 1). Nested calls under a slot this
# process tree already holds are no-ops (so `with-heavy.sh tools/blender-run.sh ...` does not double-book).
# Options: --owner TEXT --game NAME --priority 0-9 --slots N --timeout SEC --cap SEC --enforce-cap --quiet
# Exit: the command's status; 75 = timed out waiting; 127 = command not found.
TOOLS="$(cd "$(dirname "$0")" && pwd)"
exec python3 "$TOOLS/locks.py" run heavy "$@"
