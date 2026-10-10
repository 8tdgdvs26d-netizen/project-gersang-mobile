#!/bin/sh
# Runs the full Godot regression (godot/tests/run_tests.sh) with HOME pointed
# at a fresh temporary directory, so user:// is a separate, disposable folder
# and the Development Save (user://myrial_save.json in the normal user data
# folder) cannot be read or written (approved D6).
#
# Usage: GODOT=/Applications/Godot.app/Contents/MacOS/Godot nakama/scripts/run_godot_regression_isolated.sh [verify_name ...]
set -eu
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ISOLATED_HOME="$(mktemp -d)"
echo "Isolated HOME (user:// root): $ISOLATED_HOME"
OUT="$(mktemp)"
set +e
HOME="$ISOLATED_HOME" GODOT="${GODOT:-godot}" sh "$REPO_DIR/godot/tests/run_tests.sh" "$@" | tee "$OUT"
STATUS=$?
set -e
# Strict re-check (WP01-B finding): Godot 4.7.2 exits 0 when a --script fails
# to PARSE, so godot/tests/run_tests.sh alone would report such a script as
# PASS. Every PASS line must carry its script's own "passed" message and no
# parse / script error.
FALSE_PASS="$( { grep '^PASS ' "$OUT" | grep -v 'passed' ; grep '^PASS ' "$OUT" | grep -E 'Parse Error|SCRIPT ERROR' ; } || true )"
if [ -n "$FALSE_PASS" ]; then
	echo "STRICT CHECK FAILED: PASS line(s) without a passed message or with errors:" >&2
	printf '%s\n' "$FALSE_PASS" >&2
	exit 1
fi
echo "Strict check: every PASS line carries its passed message and no parse / script error ($(grep -c '^PASS ' "$OUT") scripts)"
exit "$STATUS"
