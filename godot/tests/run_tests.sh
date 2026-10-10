#!/bin/sh
# Reproducible headless test run for the Godot project.
#
# A direct `godot --script` run does not scan the project, so on a fresh clone
# (no generated godot/.godot/ cache) class_name scripts cannot be resolved and
# the bundled font is not imported. This runner always performs the headless
# import first, which registers every class_name script and imports resources,
# then runs the verification scripts.
#
# Usage (from anywhere):
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot godot/tests/run_tests.sh
#   GODOT=/path/to/godot godot/tests/run_tests.sh verify_t01_warehouse
# Without arguments every tests/verify_*.gd runs. GODOT defaults to `godot`.
# On a completely fresh cache the import step may print font "Cannot open
# file ... .fontdata" errors before it imports the font; these are expected
# once and do not affect the run.
#
# Pass rule (WP01-B-T01): Godot 4.7.2 exits 0 when a --script fails to parse,
# and a script error inside an awaited coroutine does not stop the test, so
# the exit code alone is not proof. A script PASSES only if ALL hold:
#   1. it exits 0;
#   2. it prints its own success line: a line containing "verification passed"
#      that is not itself a failure line (every verify_*.gd prints exactly one);
#   3. no line contains "SCRIPT ERROR" or "Parse Error";
#   4. no line reports a test failure: a line starting with "FAILED:" or, from
#      push_error, "ERROR: FAILED:". Reason codes such as ERR_SAVE_FAILED
#      inside other lines are not failure reports.
# Anything else is FAIL, with the reason in brackets. Exit codes: 0 all pass,
# 1 any failure, 2 import problem (unchanged).
# Self-test of these rules: godot/tests/runner_selftest.sh.

GODOT="${GODOT:-godot}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"

if ! "$GODOT" --headless --path "$PROJECT" --import >/dev/null 2>&1; then
	echo "Godot import step failed (GODOT=$GODOT)" >&2
	exit 2
fi
if [ ! -f "$PROJECT/.godot/global_script_class_cache.cfg" ]; then
	echo "Godot import did not create the class cache (GODOT=$GODOT)" >&2
	exit 2
fi

if [ "$#" -eq 0 ]; then
	set -- $(cd "$PROJECT/tests" && ls verify_*.gd | sed 's/\.gd$//')
fi

failed=0
for name in "$@"; do
	name="${name%.gd}"
	output="$("$GODOT" --headless --path "$PROJECT" --script "res://tests/$name.gd" 2>&1)"
	status=$?
	summary="$(printf '%s\n' "$output" | grep -E 'passed|FAILED|SCRIPT ERROR|Parse Error' | head -3 | tr '\n' ' ')"
	reason=""
	if [ "$status" -ne 0 ]; then
		reason="exit $status"
	elif printf '%s\n' "$output" | grep -qE 'SCRIPT ERROR|Parse Error'; then
		reason="exit 0; script or parse error"
	elif printf '%s\n' "$output" | grep -qE '^(ERROR: )?FAILED:'; then
		reason="exit 0; test reported FAILED"
	elif ! printf '%s\n' "$output" | grep -vE '^(ERROR: )?FAILED:' | grep -q 'verification passed'; then
		reason="exit 0; no success line"
	fi
	if [ -z "$reason" ]; then
		echo "PASS $name | $summary"
	else
		echo "FAIL $name ($reason) | $summary"
		failed=$((failed + 1))
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "$failed test script(s) failed" >&2
	exit 1
fi
echo "All $# test script(s) passed"
