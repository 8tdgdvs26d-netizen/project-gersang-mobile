#!/bin/sh
# Self-test for godot/tests/run_tests.sh (WP01-B-T01).
#
# Builds a throw-away Godot project in a temporary folder, writes small
# fixture tests into ITS tests/ folder (never into this project), runs the
# given runner against it with an isolated HOME (isolated user://) and checks
# every verdict. Deliberately broken fixtures never enter the real project,
# so they cannot affect the normal regression or an export.
#
# Usage:
#   GODOT=/Applications/Godot.app/Contents/MacOS/Godot godot/tests/runner_selftest.sh [runner]
# [runner] defaults to the run_tests.sh next to this file. Exit 0 only if
# every fixture got the expected verdict and the runner's exit codes match.

GODOT="${GODOT:-godot}"
HERE="$(cd "$(dirname "$0")" && pwd)"
RUNNER="${1:-$HERE/run_tests.sh}"
WORK="$(mktemp -d)"
PROJ="$WORK/project"
mkdir -p "$PROJ/tests" "$WORK/home"
cp "$RUNNER" "$PROJ/tests/run_tests.sh"
printf 'config_version=5\n\n[application]\n\nconfig/name="RunnerSelfTest"\n' > "$PROJ/project.godot"
# One class_name script so the import writes the class cache the runner checks.
printf 'class_name RunnerSelfTestMarker\nextends RefCounted\n' > "$PROJ/marker.gd"

fixture() { printf '%s\n' "$2" > "$PROJ/tests/$1.gd"; }

# A. normal passing test: success line, exit 0
fixture verify_a_normal_pass 'extends SceneTree
var _failures := 0
func _initialize() -> void:
	if _failures == 0:
		print("FIXTURE A normal verification passed (1 checks)")
	quit(1 if _failures > 0 else 0)'

# B. parse error: Godot 4.7.2 exits 0 without running the test
fixture verify_b_parse_error 'extends SceneTree
func _initialize() -> void:
	var x := undefined_call(
	quit(0)'

# C. SCRIPT ERROR inside an awaited coroutine: the coroutine stops, the
#    caller continues, prints its success line and exits 0
fixture verify_c_script_error 'extends SceneTree
var _failures := 0
func _initialize() -> void:
	await _broken()
	if _failures == 0:
		print("FIXTURE C script error verification passed (1 checks)")
	quit(1 if _failures > 0 else 0)
func _broken() -> void:
	await process_frame
	var empty: Array = []
	var value = empty[3]'

# D. exit 0 but no success line at all
fixture verify_d_no_success_line 'extends SceneTree
func _initialize() -> void:
	print("FIXTURE D did some work")
	quit(0)'

# E1. reports FAILED and exits 1 (the normal failing convention)
fixture verify_e1_failed_exit1 'extends SceneTree
func _initialize() -> void:
	print("FAILED: FIXTURE E1 deliberate failure")
	quit(1)'

# E2. reports FAILED but exits 0 (a buggy test)
fixture verify_e2_failed_exit0 'extends SceneTree
func _initialize() -> void:
	print("FAILED: FIXTURE E2 deliberate failure")
	quit(0)'

# E3. reports FAILED, still prints its success line, exits 0
fixture verify_e3_failed_with_success_line 'extends SceneTree
func _initialize() -> void:
	print("FAILED: FIXTURE E3 deliberate failure")
	print("FIXTURE E3 verification passed (1 checks)")
	quit(0)'

# E4. the success words appear only inside a FAILED line
fixture verify_e4_marker_only_in_failed_line 'extends SceneTree
func _initialize() -> void:
	print("FAILED: FIXTURE E4 verification passed (1 checks)")
	quit(0)'

# Expected verdict per fixture.
expected() {
	case "$1" in
		verify_a_normal_pass) echo PASS ;;
		*) echo FAIL ;;
	esac
}

mismatch=0
echo "Runner under test: $RUNNER"
echo "Isolated HOME (user:// root): $WORK/home"
for f in $(cd "$PROJ/tests" && ls verify_*.gd | sed 's/\.gd$//'); do
	line="$(HOME="$WORK/home" GODOT="$GODOT" sh "$PROJ/tests/run_tests.sh" "$f" 2>/dev/null | grep -E "^(PASS|FAIL) $f( |$)")"
	got="${line%% *}"
	want="$(expected "$f")"
	if [ "$got" = "$want" ]; then
		echo "ok       $f: expected $want, got $got"
	else
		echo "MISMATCH $f: expected $want, got ${got:-nothing} | $line"
		mismatch=$((mismatch + 1))
	fi
done

# Runner exit codes: all-pass run -> 0, any failure -> 1.
HOME="$WORK/home" GODOT="$GODOT" sh "$PROJ/tests/run_tests.sh" verify_a_normal_pass >/dev/null 2>&1
all_pass_exit=$?
HOME="$WORK/home" GODOT="$GODOT" sh "$PROJ/tests/run_tests.sh" verify_a_normal_pass verify_b_parse_error >/dev/null 2>&1
mixed_exit=$?
if [ "$all_pass_exit" -eq 0 ]; then echo "ok       runner exit 0 when every test passes"; else echo "MISMATCH runner exit $all_pass_exit when every test passes (want 0)"; mismatch=$((mismatch + 1)); fi
if [ "$mixed_exit" -eq 1 ]; then echo "ok       runner exit 1 when a test fails"; else echo "MISMATCH runner exit $mixed_exit when a test fails (want 1)"; mismatch=$((mismatch + 1)); fi

rm -rf "$WORK"
if [ "$mismatch" -ne 0 ]; then
	echo "Runner self-test FAILED: $mismatch mismatch(es)"
	exit 1
fi
echo "Runner self-test passed (all fixtures and exit codes as expected)"
