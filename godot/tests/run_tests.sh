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
	if [ "$status" -eq 0 ]; then
		echo "PASS $name | $summary"
	else
		echo "FAIL $name (exit $status) | $summary"
		failed=$((failed + 1))
	fi
done

if [ "$failed" -ne 0 ]; then
	echo "$failed test script(s) failed" >&2
	exit 1
fi
echo "All $# test script(s) passed"
