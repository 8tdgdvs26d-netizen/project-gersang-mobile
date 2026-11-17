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

# Safety (SAFE-F2 v0.1):
# - this script deletes NOTHING: there is no rm / rmdir / find -delete in it.
#   Every case folder is left in place and listed at the end (PRESERVED);
# - every case works only inside one fresh folder that mktemp created and that
#   was verified to be <temp base>/myrial-wrapper-test.<letters and digits>;
# - each mktemp case directory must be empty, and all case artifacts are
#   created exclusively (existing files/directories are never reused);
# - every file this script creates is opened by a plain "printf ... > file"
#   inside a short-lived subshell (write_new_file). No redirection to a file
#   is attached to a { ...; } group, a function call or a special built-in,
#   because shells differ on whether such a redirection error ends the shell;
# - noclobber (set -C) is never on in the main shell, and never on before or
#   while the wrapper under test runs: it exists only inside those subshells
#   and, in the launcher, only after the wrapper has finished;
# - the wrapper's exit code and the result of collecting its output are
#   recorded separately (run_wrapper). A verdict is given only if both
#   records exist and the output collector ended with 0; anything else is
#   ABORTED (exit 3). The records show which steps were reached and what
#   they returned. They do not prove that the wrapper started correctly,
#   and they say nothing about the wrapper's own internal tee / temp files;
# - any set-up failure (mktemp, mkdir, cp, writing a fixture) stops the whole
#   script at once with exit 3 ("ABORTED"), which is neither a wrapper PASS
#   (exit 0) nor a wrapper FAIL (exit 1).

# abort <reason>: fail closed. Must only be called in the main shell, never
# inside $(...), so that the exit really ends the whole script.
abort() {
	echo "ABORTED: $1" >&2
	echo "Wrapper test ABORTED (set-up failure, no verdict on the wrapper; nothing was deleted)" >&2
	if [ -n "${kept_dirs:-}" ]; then
		echo "note     known case folder(s) PRESERVED, not cleaned:" >&2
		printf '%s' "$kept_dirs" >&2
	fi
	exit 3
}

HERE="$(cd "$(dirname "$0")" && pwd)" || abort "cannot resolve this script's own folder"
case "$HERE" in
	/?*) ;;
	*) abort "this script's own folder is not a usable absolute path: '$HERE'" ;;
esac
WRAPPER="${1:-$HERE/run_godot_regression_isolated.sh}"
REAL_RUNNER="$HERE/../../godot/tests/run_tests.sh"
failures=0
checks=0
kept_dirs=""

[ -f "$WRAPPER" ] || abort "wrapper under test not found: '$WRAPPER'"
command -v mktemp > /dev/null 2>&1 || abort "mktemp is not available"

# Temporary base folder: TMPDIR (or /tmp) without trailing slashes. It must be
# an existing absolute folder and can never be "/" itself.
TMP_PREFIX="myrial-wrapper-test"
TMP_BASE="${TMPDIR:-/tmp}"
while [ "${TMP_BASE%/}" != "$TMP_BASE" ]; do TMP_BASE="${TMP_BASE%/}"; done
case "$TMP_BASE" in
	/?*) ;;
	*) abort "temporary base folder must be an absolute path other than /: '${TMPDIR:-/tmp}'" ;;
esac
[ -d "$TMP_BASE" ] || abort "temporary base folder does not exist: '$TMP_BASE'"

# new_case_dir: sets $case_dir to a fresh folder created by mktemp, or aborts.
# The path is accepted only if mktemp succeeded AND it is exactly
# "$TMP_BASE/$TMP_PREFIX.<letters and digits>" AND it is a real folder (not a
# symbolic link). An empty, relative, multi-line or otherwise odd answer aborts.
new_case_dir() {
	case_dir=""
	created="$(mktemp -d "$TMP_BASE/$TMP_PREFIX.XXXXXXXX")" || abort "mktemp -d failed"
	[ -n "$created" ] || abort "mktemp -d returned an empty path"
	expected_start="$TMP_BASE/$TMP_PREFIX."
	suffix=${created#"$expected_start"}
	[ "$suffix" != "$created" ] || abort "mktemp -d returned a path outside the expected location: '$created'"
	case "$suffix" in
		''|*[!A-Za-z0-9]*) abort "mktemp -d returned a path of an unexpected form: '$created'" ;;
	esac
	[ -d "$created" ] || abort "mktemp -d path is not a folder: '$created'"
	[ ! -L "$created" ] || abort "mktemp -d path is a symbolic link: '$created'"
	# A well-behaved mktemp -d creates an empty private directory. Reject a
	# substituted/reused non-empty directory, including hidden files or symlinks.
	for entry in "$created"/* "$created"/.[!.]* "$created"/..?*; do
		if [ -e "$entry" ] || [ -L "$entry" ]; then
			abort "mktemp -d returned a non-empty directory: '$created'"
		fi
	done
	case_dir="$created"
	# Record immediately; a later setup ABORT must disclose the remaining path.
	kept_dirs="${kept_dirs}note       $case_dir
"
}

# new_repo: sets $repo (throw-away repository layout) and $out (file for the
# wrapper's output), both inside a fresh verified $case_dir, or aborts.
# Call it directly, never as $(new_repo): a failure must stop the script.
new_repo() {
	repo=""; out=""
	new_case_dir
	repo="$case_dir/repo"
	out="$case_dir/wrapper_output.txt"
	# No mkdir -p: any pre-existing repo/subdirectory is a setup failure.
	mkdir "$repo" || abort "throw-away repo already exists or cannot be created: '$repo'"
	mkdir "$repo/godot" || abort "cannot create fresh godot folder in '$repo'"
	mkdir "$repo/nakama" || abort "cannot create fresh nakama folder in '$repo'"
	mkdir "$repo/godot/tests" || abort "cannot create fresh tests folder in '$repo'"
	mkdir "$repo/nakama/scripts" || abort "cannot create fresh scripts folder in '$repo'"
	[ ! -e "$repo/nakama/scripts/run_godot_regression_isolated.sh" ] &&
		[ ! -L "$repo/nakama/scripts/run_godot_regression_isolated.sh" ] || abort "wrapper destination already exists"
	cp "$WRAPPER" "$repo/nakama/scripts/run_godot_regression_isolated.sh" || abort "cannot copy the wrapper into '$repo'"
	# The output file is created later, exclusively, by run_wrapper.
	[ ! -e "$out" ] && [ ! -L "$out" ] || abort "wrapper output already exists: '$out'"
}

# write_new_file <path> <printf format> [printf arguments...]
# Creates <path> as a NEW file with that content, or aborts.
# - The subshell keeps noclobber (set -C) away from the main shell, so it can
#   never reach the wrapper under test (through SHELLOPTS or otherwise).
# - Inside it, the only redirection is on one plain printf (a regular
#   utility): if the file exists already or cannot be opened, printf does not
#   run and the subshell ends non-zero; if the write fails, printf itself is
#   non-zero. Should a shell end the subshell early on that error, the result
#   is still non-zero. Every path therefore reaches the abort below, which
#   runs in the main shell.
write_new_file() {
	wn_path="$1"; shift
	[ ! -e "$wn_path" ] && [ ! -L "$wn_path" ] || abort "file already exists, refusing to reuse it: '$wn_path'"
	( set -C; printf "$@" > "$wn_path" ) || abort "cannot create or write new file: '$wn_path'"
	[ -f "$wn_path" ] || abort "new file is missing after writing: '$wn_path'"
	[ ! -L "$wn_path" ] || abort "new file is a symbolic link: '$wn_path'"
}

# Launcher: runs in its own "sh -c" process. $1 = wrapper, $2 = output file,
# $3 = wrapper status file, $4 = collector status file.
# - "exec >> $2" opens the output file once, before the wrapper exists. If it
#   cannot be opened, the launcher ends here (a shell that does not end by
#   itself takes "|| exit 97"), so the wrapper is never started and neither
#   status file is written.
# - The wrapper is started as before ("sh <wrapper>"), with noclobber off.
#   Its stdout and stderr go through a pipe to "cat", the output collector,
#   which is the only process that writes them into the output file. cat
#   ends non-zero if one of its writes fails. A pipeline's status is that of
#   its last command, so $? after the pipeline is the collector's result.
# - The wrapper's own exit code is written to $3 from inside the pipeline,
#   and the collector's to $4 after it; set -C is turned on only AFTER the
#   wrapper has finished, to create each status file exclusively.
# - What $3 means: the "sh <wrapper>" step was reached with the output
#   attached, and that command returned this number. It is NOT separate proof
#   that the wrapper started correctly (for example 126 / 127 would be
#   recorded the same way).
LAUNCHER='exec >> "$2" 2>&1 || exit 97
{
	sh "$1" 2>&1
	code=$?
	set -C
	printf "%s\n" "$code" > "$3"
} | cat
collect=$?
set -C
printf "%s\n" "$collect" > "$4" || exit 98
exit 0'

# read_code_file <path> <what>: sets $code_value to the plain number stored
# in <path>, or aborts (missing file, symbolic link, unreadable, not a number).
read_code_file() {
	code_value=""
	[ -f "$1" ] || abort "$2 was not recorded (launcher exit $launcher_code): '$1'"
	[ ! -L "$1" ] || abort "$2 file is a symbolic link: '$1'"
	code_value="$(cat "$1")" || abort "cannot read the $2 file '$1'"
	case "$code_value" in
		''|*[!0-9]*) abort "$2 file does not hold a plain exit code: '$1'" ;;
	esac
}

# run_wrapper <stub|godot>: runs the wrapper copy in $repo, collects its
# output in $out and sets $got to the wrapper's own exit code, or aborts.
# Two separate results are required before any verdict:
# - the wrapper's exit code ($got), read ONLY from its status file;
# - the output collector's exit code, read ONLY from its own status file.
# A missing or non-numeric record, or a collector result other than 0, is an
# output-collection / set-up failure: ABORT (exit 3), never a wrapper
# verdict. So a wrapper result is never judged against output that the
# collector reported it could not write.
# Limits (not claimed): this covers the outer collection only. Failures
# inside the wrapper (its own tee and temp files) and write errors that the
# system reports to nobody are outside what this script can detect.
run_wrapper() {
	got=""
	wrapper_copy="$repo/nakama/scripts/run_godot_regression_isolated.sh"
	status_file="$case_dir/wrapper_status.txt"
	collect_file="$case_dir/output_collector_status.txt"
	[ -f "$wrapper_copy" ] && [ -r "$wrapper_copy" ] || abort "wrapper copy is missing or unreadable: '$wrapper_copy'"
	[ ! -e "$status_file" ] && [ ! -L "$status_file" ] || abort "wrapper status file already exists: '$status_file'"
	[ ! -e "$collect_file" ] && [ ! -L "$collect_file" ] || abort "collector status file already exists: '$collect_file'"
	write_new_file "$out" ''
	case "$1" in
		stub) GODOT=unused sh -c "$LAUNCHER" launcher "$wrapper_copy" "$out" "$status_file" "$collect_file" ;;
		godot) sh -c "$LAUNCHER" launcher "$wrapper_copy" "$out" "$status_file" "$collect_file" ;;
		*) abort "run_wrapper: unknown mode '$1'" ;;
	esac
	launcher_code=$?
	[ "$launcher_code" -eq 0 ] ||
		abort "launcher exited $launcher_code: no verdict"
	read_code_file "$collect_file" "output collector result"
	collect_code="$code_value"
	read_code_file "$status_file" "wrapper exit code"
	got="$code_value"
	[ "$collect_code" -eq 0 ] || abort "output collection failed (collector exit $collect_code, wrapper exit $got): no verdict; output file '$out'"
	[ -f "$out" ] || abort "wrapper output file is missing after the run: '$out'"
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
	new_repo
	# Build the stub runner text first (no file involved), then write it in
	# one step. Same bytes as before: "#!/bin/sh", one echo '<line>' per
	# runner line, then "exit <code>".
	stub_text='#!/bin/sh'
	for line in "$@"; do
		stub_text="$stub_text
echo '$line'"
	done
	stub_text="$stub_text
exit $code"
	write_new_file "$repo/godot/tests/run_tests.sh" '%s\n' "$stub_text"
	run_wrapper stub
	# The runner's own lines must still be shown (tee output preserved).
	expect "stub: $label" "$want" "$got" "$out" "$1"
	# No clean-up here on purpose (SAFE-F2): $case_dir is preserved.
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
	[ -f "$REAL_RUNNER" ] || abort "real Godot test runner not found: '$REAL_RUNNER'"
	godot_case() {
		label="$1"; want="$2"; source="$3"
		new_repo
		cp "$REAL_RUNNER" "$repo/godot/tests/run_tests.sh" || abort "cannot copy the real runner into '$repo'"
		write_new_file "$repo/godot/project.godot" 'config_version=5\n\n[application]\n\nconfig/name="WrapperTest"\n'
		write_new_file "$repo/godot/marker.gd" 'class_name WrapperTestMarker\nextends RefCounted\n'
		write_new_file "$repo/godot/tests/verify_fixture.gd" '%s\n' "$source"
		run_wrapper godot
		expect "godot: $label" "$want" "$got" "$out" "verify_fixture"
		# No clean-up here on purpose (SAFE-F2): $case_dir is preserved.
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

echo "note     nothing was deleted; case folder(s) PRESERVED (not cleaned):"
printf '%s' "$kept_dirs"

if [ "$failures" -ne 0 ]; then
	echo "Wrapper test FAILED: $failures of $checks case(s)"
	exit 1
fi
echo "Wrapper test passed ($checks cases)"
