#!/bin/bash
# Usage: tools/blender-run.sh <script.py> [-- script args...]
# Runs headless Blender 5.2 with the standard flags. Machine-wide (16 GB Mac): the run holds one slot of the
# 2-slot heavy pool (tools/with-heavy.sh, FIFO queue, shared with Xcode and other heavy jobs) for its whole
# lifetime, and as a second guard waits until fewer than 2 Blender processes are running at all (catches
# Blenders started outside the pool). A short mkdir mutex keeps the count-and-start atomic. Exit code = Blender's.
# Test overrides: BLENDER_RUN_BIN (binary), BLENDER_RUN_PATTERN (pgrep -f regex), BLENDER_RUN_MUTEX, BLENDER_RUN_MAX.
set -uo pipefail
TOOLS="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="${1:?usage: blender-run.sh <script.py> [-- args]}"
if [ "${BLENDER_RUN_INNER:-}" != 1 ]; then
	# take the heavy slot first, then run this same script inside it
	BLENDER_RUN_INNER=1 exec "$TOOLS/with-heavy.sh" --owner "blender $(basename "$SCRIPT")" -- "$0" "$@"
fi
shift
BLENDER="${BLENDER_RUN_BIN:-/Applications/Blender.app/Contents/MacOS/Blender}"
PATTERN="${BLENDER_RUN_PATTERN:-^/Applications/Blender.app/Contents/MacOS/Blender( |\$)}"
MUTEX="${BLENDER_RUN_MUTEX:-/tmp/blender-run.mutex}"
MAX="${BLENDER_RUN_MAX:-2}"
pid=""
napper=""
have_mutex=0
on_signal() {
	# Blender already started: forward the signal and let the wait loop below collect its exit code.
	# Not started yet (queued behind the pgrep guard): the job is cancelled, so give up right here instead of
	# launching Blender later; release the mutex if we hold it.
	if [ -n "$pid" ]; then
		kill -TERM "$pid" 2>/dev/null
		return
	fi
	[ -n "$napper" ] && kill "$napper" 2>/dev/null
	[ "$have_mutex" = 1 ] && rmdir "$MUTEX" 2>/dev/null
	exit "$1"
}
trap 'on_signal 143' TERM
trap 'on_signal 130' INT
trap 'on_signal 129' HUP
while true; do
	if mkdir "$MUTEX" 2>/dev/null; then
		have_mutex=1
		running=$(pgrep -f "$PATTERN" | wc -l | tr -d ' ')
		if [ "$running" -lt "$MAX" ]; then
			"$BLENDER" --background --factory-startup -noaudio --python-exit-code 1 --python "$SCRIPT" "$@" &
			pid=$!
			sleep 1
			rmdir "$MUTEX"
			have_mutex=0
			# wait again if a trapped signal interrupted wait
			wait "$pid"; rc=$?
			while kill -0 "$pid" 2>/dev/null; do wait "$pid"; rc=$?; done
			exit $rc
		fi
		rmdir "$MUTEX"
		have_mutex=0
	fi
	# break a stale mutex (holder died) after 30 s
	if [ -d "$MUTEX" ] && [ $(($(date +%s) - $(stat -f %m "$MUTEX"))) -gt 30 ]; then rmdir "$MUTEX" 2>/dev/null; fi
	# interruptible nap: a foreground sleep would delay the trap until it ends
	sleep 2 &
	napper=$!
	wait "$napper" 2>/dev/null
	napper=""
done
