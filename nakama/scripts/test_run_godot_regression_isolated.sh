#!/bin/sh
# Automated test for nakama/scripts/run_godot_regression_isolated.sh (PR #133):
# the wrapper's exit code must follow the Godot test runner it wraps, and its
# strict PASS-line check must still catch false PASS lines.
#
# Each case builds a throw-away copy of the repository layout
# (<repo>/godot/tests/run_tests.sh + <repo>/nakama/scripts/<wrapper>) in a
# temporary folder:
# - STUB cases: run_tests.sh is a stub that prints chosen lines and exits with
#   a chosen code (fast, deterministic, no Godot needed);
# - GODOT cases (when GODOT is set): the repository's real run_tests.sh runs
#   small fixture tests in a throw-away Godot project with an isolated HOME.
#
# Usage: [GODOT=/Applications/Godot.app/Contents/MacOS/Godot] sh nakama/scripts/test_run_godot_regression_isolated.sh [wrapper]
# [wrapper] defaults to the run_godot_regression_isolated.sh next to this file.

HERE="$(cd "$(dirname "$0")" && pwd)"
WRAPPER="${1:-$HERE/run_godot_regression_isolated.sh}"
REAL_RUNNER="$HERE/../../godot/tests/run_tests.sh"
failures=0
checks=0

new_repo() {
	repo="$(mktemp -d)/repo"
	mkdir -p "$repo/godot/tests" "$repo/nakama/scripts"
	cp "$WRAPPER" "$repo/nakama/scripts/run_godot_regression_isolated.sh"
	echo "$repo"
}

# expect <label> <want: zero|nonzero|N> <got> <output-file> [must-contain]
expect() {
	checks=$((checks + 1))
	ok=1
	case "$2" in
		zero) [ "$3" -eq 0 ] || ok=0 ;;
		nonzero) [ "$3" -ne 0 ] || ok=0 ;;
		*) [ "$3" -eq "$2" ] || ok=0 ;;
	esac
	if [ -n "$5" ] && ! grep -q "$5" "$4"; then ok=0; fi
	if [ "$ok" -eq 1 ]; then
		echo "ok       $1 (wrapper exit $3)"
	else
		echo "FAILED:  $1 (wrapper exit $3, want $2${5:+, output containing \"$5\"})"
		failures=$((failures + 1))
	fi
}

# stub_case <label> <want> <runner exit> <runner stdout lines...>
stub_case() {
	label="$1"; want="$2"; code="$3"; shift 3
	repo="$(new_repo)"
	{
		echo '#!/bin/sh'
		for line in "$@"; do printf "echo '%s'\n" "$line"; done
		echo "exit $code"
	} > "$repo/godot/tests/run_tests.sh"
	out="$(mktemp)"
	GODOT=unused sh "$repo/nakama/scripts/run_godot_regression_isolated.sh" > "$out" 2>&1
	got=$?
	# The runner's own lines must still be shown (tee output preserved).
	expect "stub: $label" "$want" "$got" "$out" "$1"
	rm -rf "$(dirname "$repo")" "$out"
}

echo "Wrapper under test: $WRAPPER"

# 1. runner PASS -> wrapper 0
stub_case "PASS a | A verification passed (1 checks)" zero 0 \
	"PASS a | A verification passed (1 checks)" "All 1 test script(s) passed"
# 2. runner FAIL -> wrapper non-zero
stub_case "FAIL b (exit 1) | FAILED: deliberate" nonzero 1 \
	"PASS a | A verification passed (1 checks)" "FAIL b (exit 1) | FAILED: deliberate"
# 3. runner FAIL although its output carries success words -> non-zero
stub_case "FAIL c (exit 1) | C verification passed (1 checks)" nonzero 1 \
	"PASS a | A verification passed (1 checks)" "FAIL c (exit 1) | C verification passed (1 checks)"
# 4. parse error reported as PASS by an exit-code-only runner -> non-zero (strict check)
stub_case "PASS d | SCRIPT ERROR: Parse Error: x" nonzero 0 \
	"PASS d | SCRIPT ERROR: Parse Error: x" "All 1 test script(s) passed"
# 5. PASS line without its passed message -> non-zero (strict check)
stub_case "PASS e | " nonzero 0 "PASS e | " "All 1 test script(s) passed"
# 6. runner import failure (exit 2) -> wrapper keeps exit 2
stub_case "Godot import step failed" 2 2 "Godot import step failed"

if [ -n "${GODOT:-}" ] && [ "$GODOT" != "unused" ]; then
	# Real runner + real Godot fixture tests, isolated HOME via the wrapper.
	godot_case() {
		label="$1"; want="$2"; source="$3"
		repo="$(new_repo)"
		cp "$REAL_RUNNER" "$repo/godot/tests/run_tests.sh"
		printf 'config_version=5\n\n[application]\n\nconfig/name="WrapperTest"\n' > "$repo/godot/project.godot"
		printf 'class_name WrapperTestMarker\nextends RefCounted\n' > "$repo/godot/marker.gd"
		printf '%s\n' "$source" > "$repo/godot/tests/verify_fixture.gd"
		out="$(mktemp)"
		sh "$repo/nakama/scripts/run_godot_regression_isolated.sh" > "$out" 2>&1
		got=$?
		expect "godot: $label" "$want" "$got" "$out" "verify_fixture"
		rm -rf "$(dirname "$repo")" "$out"
	}
	godot_case "normal passing test" zero 'extends SceneTree
func _initialize() -> void:
	print("FIXTURE verification passed (1 checks)")
	quit(0)'
	godot_case "ordinary failing test (FAILED + exit 1)" nonzero 'extends SceneTree
func _initialize() -> void:
	push_error("FAILED: deliberate")
	quit(1)'
	godot_case "failing test that still prints its success line (exit 1)" nonzero 'extends SceneTree
func _initialize() -> void:
	push_error("FAILED: deliberate")
	print("FIXTURE verification passed (1 checks)")
	quit(1)'
	godot_case "parse error" nonzero 'extends SceneTree
func _initialize() -> void:
	var x := undefined_call(
	quit(0)'
else
	echo "note     GODOT not set: real-Godot cases skipped"
fi

if [ "$failures" -ne 0 ]; then
	echo "Wrapper test FAILED: $failures of $checks case(s)"
	exit 1
fi
echo "Wrapper test passed ($checks cases)"
