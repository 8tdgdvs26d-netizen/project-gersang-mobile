#!/bin/bash
# SAFE-F2 v0.1 cloud test harness (TEST-ONLY; execution branch only; never merged).
#
# Runs nakama/scripts/test_run_godot_regression_isolated.sh (the "target")
# under controlled faults and records evidence. It never edits the target.
#
# Safety rules of this file:
# - it removes NOTHING: no deleting command exists in it. Everything it
#   creates stays under the run root and is only LISTED (PRESERVED);
# - it refuses to do anything (exit 4, "HARNESS REFUSED") unless it is on a
#   GitHub-hosted Linux runner, not root, and --root is exactly
#   $RUNNER_TEMP/safe-f2-<run id>-<attempt>, an existing real folder owned by
#   this user. This check runs first in EVERY mode, including --audit and
#   --inventory, so an empty or wrong root is never scanned or written;
# - faults are injected only by small fake programs ("shims") placed first in
#   PATH for one case, or by file state inside that case's own folder;
# - every case runs with a clean environment (env -i), HOME and TMPDIR inside
#   the run root, and a time limit;
# - on the first mismatch in a group it stops that group (exit 1).
#
# Usage (from the workflow only):
#   bash safe_f2_cloud_harness.sh --root <root> --group N|M|F|L|N6|G|R1|R2|R3 [--godot <bin>]
#   bash safe_f2_cloud_harness.sh --root <root> --snapshot before|after
#   bash safe_f2_cloud_harness.sh --root <root> --inventory
#   bash safe_f2_cloud_harness.sh --root <root> --audit "<groups>"
#   bash safe_f2_cloud_harness.sh --root <root> --manifest
# Exit codes: 0 ok, 1 a case or audit rule did not match, 4 refused.

set -u

R4_SHA256="ab895451d5d17502b6c9b9ae5c4d636ec1172509ec847bf1e0f266ecf5c61a99"
TARGET_REL="nakama/scripts/test_run_godot_regression_isolated.sh"
WRAPPER_REL="nakama/scripts/run_godot_regression_isolated.sh"
VERIFY_COUNT=74
FULL_GROUPS="N M F L N6 G R1 R2 R3"
EXPECTED_ROWS=119
STUB_TIMEOUT=120
GODOT_CASE_TIMEOUT=900

die() {
	echo "HARNESS REFUSED: $*" >&2
	exit 4
}

# B-3: evidence or bookkeeping failure. Exit 1 makes the workflow step fail,
# and the final gate requires every step to succeed.
evidence_fail() {
	echo "HARNESS EVIDENCE FAILURE: $*" >&2
	exit 1
}

# B-3: every find pipeline goes through these two helpers. pipefail is set
# only inside their subshell, and any message from find counts as a failure,
# so an error can never be hidden by the following sort.
# list_tree <dir> <out>: sorted "%y %m %s %p" listing of <dir>.
list_tree() {
	(
		set -o pipefail
		/usr/bin/find "$1" -xdev -printf '%y %m %s %p\n' 2> "$2.errors" | LC_ALL=C sort > "$2"
	) || return 1
	[ ! -s "$2.errors" ] || return 1
}
# collect_case_dirs <tmp> <out>: sorted list of the target's case folders.
collect_case_dirs() {
	(
		set -o pipefail
		/usr/bin/find "$1" -mindepth 1 -maxdepth 1 -type d -name 'myrial-wrapper-test.*' -print 2> "$2.errors" | LC_ALL=C sort > "$2"
	) || return 1
	[ ! -s "$2.errors" ] || return 1
}

# ---------------------------------------------------------------- arguments
ROOT=""; MODE=""; GROUP=""; GODOT_BIN=""; SNAP=""; AUDIT_GROUPS=""
while [ "$#" -gt 0 ]; do
	case "$1" in
		--root) [ "$#" -ge 2 ] || die "--root needs a value"; ROOT="$2"; shift 2 ;;
		--group) [ "$#" -ge 2 ] || die "--group needs a value"; MODE="group"; GROUP="$2"; shift 2 ;;
		--godot) [ "$#" -ge 2 ] || die "--godot needs a value"; GODOT_BIN="$2"; shift 2 ;;
		--snapshot) [ "$#" -ge 2 ] || die "--snapshot needs a value"; MODE="snapshot"; SNAP="$2"; shift 2 ;;
		--inventory) MODE="inventory"; shift ;;
		--audit) [ "$#" -ge 2 ] || die "--audit needs a value"; MODE="audit"; AUDIT_GROUPS="$2"; shift 2 ;;
		--manifest) MODE="manifest"; shift ;;
		*) die "unknown argument: $1" ;;
	esac
done
[ -n "$MODE" ] || die "no mode given"

# ------------------------------------------------- runner and root guard
[ "${GITHUB_ACTIONS:-}" = "true" ] || die "not GitHub Actions"
[ "${RUNNER_ENVIRONMENT:-}" = "github-hosted" ] || die "runner is not github-hosted"
[ "${RUNNER_OS:-}" = "Linux" ] || die "runner OS is not Linux"
[ "$(uname -s)" = "Linux" ] || die "kernel is not Linux"
[ "$(id -u)" -ne 0 ] || die "running as root"
[ -n "${RUNNER_TEMP:-}" ] || die "RUNNER_TEMP is empty"
[ -n "${GITHUB_RUN_ID:-}" ] && [ -n "${GITHUB_RUN_ATTEMPT:-}" ] || die "run id or attempt is empty"
[ -n "${GITHUB_WORKSPACE:-}" ] && [ -d "$GITHUB_WORKSPACE" ] || die "GITHUB_WORKSPACE is missing"
case "$ROOT" in
	/?*) ;;
	*) die "--root is empty or not an absolute path" ;;
esac
case "$ROOT" in
	*/../*|*/..|*/./*|*/.) die "--root has a dot segment" ;;
esac
[ -d "$ROOT" ] || die "--root is not an existing folder"
[ ! -L "$ROOT" ] || die "--root is a symbolic link"
RUNNER_TEMP_REAL="$(realpath "$RUNNER_TEMP")" || die "cannot resolve RUNNER_TEMP"
ROOT_REAL="$(realpath "$ROOT")" || die "cannot resolve --root"
[ "$ROOT_REAL" = "$RUNNER_TEMP_REAL/safe-f2-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}" ] || die "--root is not the expected run root"
[ "$ROOT" = "$ROOT_REAL" ] || die "--root is not in canonical form"
[ "$(stat -c '%u' "$ROOT")" = "$(id -u)" ] || die "--root is not owned by this user"
for d in home tmp evidence; do
	[ -d "$ROOT/$d" ] && [ ! -L "$ROOT/$d" ] || die "run root lacks the '$d' folder"
done
for t in /usr/bin/mktemp /usr/bin/mkdir /usr/bin/cp /usr/bin/cat /usr/bin/chmod /usr/bin/ln \
	/usr/bin/env /usr/bin/timeout /usr/bin/find /usr/bin/sha256sum /usr/bin/dirname /bin/sh /bin/bash; do
	[ -x "$t" ] || die "required tool missing: $t"
done

WORKSPACE="$GITHUB_WORKSPACE"
TARGET="$WORKSPACE/$TARGET_REL"
REAL_WRAPPER="$WORKSPACE/$WRAPPER_REL"
EVID="$ROOT/evidence"
EVID_CASES="$EVID/cases"
WORK="$ROOT/work"
FAKES="$WORK/fakes"
S2DIR="$WORK/s2bin"
RESULTS="$EVID/results.tsv"
REAL_HOME="$(getent passwd "$(id -u)" | cut -d: -f6)"
[ -n "$REAL_HOME" ] || die "cannot determine the runner's real home"

mk() {
	/usr/bin/mkdir "$1" || die "cannot create folder (exists already?): $1"
}
ensure_dir() {
	if [ ! -d "$1" ]; then mk "$1"; fi
	[ ! -L "$1" ] || die "folder is a symbolic link: $1"
}

# ------------------------------------------------------------ planned ids
# One line per planned result: "<id>|<shell>". The audit requires a PASS (or
# CANARY_OK) result for every planned line of every group it is asked about.
planned_ids() {
	local g="$1" s i
	case "$g" in
		N)
			for s in S1 S2; do
				for i in N-1 N-3 N-4 N-5; do echo "$i|$s"; done
			done
			echo "CANARY|S1"
			;;
		M)
			for s in S1 S2; do
				for i in M-1 M-2 M-3 M-4 M-5 M-6 M-7 M-8 M-9 M-10a M-10b M-10c M-11 M-12 M-13 M-14 M-15 M-16 M-17; do
					echo "$i|$s"
				done
			done
			;;
		F)
			for s in S1 S2; do
				for i in F-1 F-2 F-3 F-4 F-5 F-6 F-7 F-8 F-9 F-10; do echo "$i|$s"; done
			done
			;;
		L)
			for s in S1 S2; do
				for i in L-1 L-2 L-3 L-4 L-5 L-6 L-7 L-8 L-9 L-10 L-11; do echo "$i|$s"; done
			done
			echo "L-10x|S2"
			;;
		N6)
			for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do echo "N-6.$i|S1"; done
			echo "N-6.total|S1"
			;;
		G)
			for s in S1 S2; do
				echo "G-1|$s"; echo "G-3|$s"
			done
			echo "G-4|-"
			;;
		R1) echo "R-1|-" ;;
		R2) echo "R-2|-" ;;
		R3) echo "R-3|-" ;;
		*) die "unknown group: $g" ;;
	esac
}

# ------------------------------------------------------------ result rows
# columns: id, shell, kind (script|check|canary), expected, actual, verdict, detail
row() {
	printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$RESULTS" \
		|| evidence_fail "cannot append to $RESULTS"
	printf '%-10s %-3s %-7s expected=%-4s actual=%-4s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}
stop_group() {
	echo "GROUP $GROUP STOPPED at $1: mismatch. Remaining cases of this group were NOT RUN."
	exit 1
}

# ------------------------------------------------------- shims and fakes
write_shim_mktemp() {
	/usr/bin/cat > "$1/mktemp" <<'SHIM'
#!/bin/bash
# SAFE-F2 test shim: only calls made with the target's own template are faulted.
last=""
for a in "$@"; do last="$a"; done
case "$last" in
	*/myrial-wrapper-test.XXXXXXXX) ;;
	*) exec /usr/bin/mktemp "$@" ;;
esac
base="${last%XXXXXXXX}"
f="$SAFE_F2_STATE/mktemp.count"
n=0
[ -f "$f" ] && read -r n < "$f"
n=$((n + 1))
printf '%s\n' "$n" > "$f"
case "${SAFE_F2_MKTEMP_MODE:-}" in
	fail) exit 1 ;;
	empty) exit 0 ;;
	root) printf '/\n'; exit 0 ;;
	relative) printf 'relative-dir\n'; exit 0 ;;
	outside) printf '%s\n' "$SAFE_F2_AUX/outside"; exit 0 ;;
	twolines)
		d="$(/usr/bin/mktemp "$@")" || exit 1
		printf '%s\n%s\n' "$d" "second-line"
		exit 0 ;;
	badsuffix) printf '%s\n' "${base}ab/.."; exit 0 ;;
	notcreated) printf '%s\n' "${base}NOTCREATED"; exit 0 ;;
	symlink)
		/usr/bin/ln -s "$SAFE_F2_AUX/linktarget" "${base}SYMLINK01" || exit 1
		printf '%s\n' "${base}SYMLINK01"
		exit 0 ;;
	nonempty_file)
		d="$(/usr/bin/mktemp "$@")" || exit 1
		printf 'pre-existing\n' > "$d/preexisting.txt" || exit 1
		printf '%s\n' "$d"
		exit 0 ;;
	nonempty_hidden)
		d="$(/usr/bin/mktemp "$@")" || exit 1
		printf 'pre-existing\n' > "$d/.hidden" || exit 1
		printf '%s\n' "$d"
		exit 0 ;;
	nonempty_dangling)
		d="$(/usr/bin/mktemp "$@")" || exit 1
		/usr/bin/ln -s "$d/does-not-exist" "$d/dangling" || exit 1
		printf '%s\n' "$d"
		exit 0 ;;
	fail_on_3)
		if [ "$n" -ge 3 ]; then exit 1; fi
		exec /usr/bin/mktemp "$@" ;;
	*) echo "mktemp shim: unknown mode" >&2; exit 99 ;;
esac
SHIM
	/usr/bin/chmod 755 "$1/mktemp"
}

write_shim_mkdir() {
	/usr/bin/cat > "$1/mkdir" <<'SHIM'
#!/bin/bash
# SAFE-F2 test shim: only folders inside a target case folder are faulted.
case "$*" in
	*/myrial-wrapper-test.*) ;;
	*) exec /usr/bin/mkdir "$@" ;;
esac
f="$SAFE_F2_STATE/mkdir.count"
n=0
[ -f "$f" ] && read -r n < "$f"
n=$((n + 1))
printf '%s\n' "$n" > "$f"
case "${SAFE_F2_MKDIR_MODE:-}" in
	fail_on)
		if [ "$n" -eq "${SAFE_F2_MKDIR_N:-0}" ]; then
			echo "mkdir shim: injected failure on call $n" >&2
			exit 1
		fi
		exec /usr/bin/mkdir "$@" ;;
	preexist_1)
		if [ "$n" -eq 1 ]; then
			/usr/bin/mkdir "$@" || exit 1
			/usr/bin/mkdir "$@"
			exit $?
		fi
		exec /usr/bin/mkdir "$@" ;;
	*) echo "mkdir shim: unknown mode" >&2; exit 99 ;;
esac
SHIM
	/usr/bin/chmod 755 "$1/mkdir"
}

write_shim_cp() {
	/usr/bin/cat > "$1/cp" <<'SHIM'
#!/bin/bash
# SAFE-F2 test shim: only the copy of the wrapper into a case folder is faulted.
dest=""
for a in "$@"; do dest="$a"; done
case "$dest" in
	*/myrial-wrapper-test.*/repo/nakama/scripts/run_godot_regression_isolated.sh) ;;
	*) exec /usr/bin/cp "$@" ;;
esac
repo="${dest%/nakama/scripts/run_godot_regression_isolated.sh}"
casedir="${repo%/repo}"
case "${SAFE_F2_CP_MODE:-}" in
	fail)
		echo "cp shim: injected failure" >&2
		exit 1 ;;
	then_ro_tests)
		/usr/bin/cp "$@" || exit 1
		/usr/bin/chmod 555 "$repo/godot/tests" || exit 98
		exit 0 ;;
	then_precreate_stub)
		/usr/bin/cp "$@" || exit 1
		printf 'pre-existing\n' > "$repo/godot/tests/run_tests.sh" || exit 98
		exit 0 ;;
	then_precreate_out)
		/usr/bin/cp "$@" || exit 1
		printf 'pre-existing\n' > "$casedir/wrapper_output.txt" || exit 98
		exit 0 ;;
	then_unreadable)
		/usr/bin/cp "$@" || exit 1
		/usr/bin/chmod 000 "$dest" || exit 98
		exit 0 ;;
	*) echo "cp shim: unknown mode" >&2; exit 99 ;;
esac
SHIM
	/usr/bin/chmod 755 "$1/cp"
}

write_shim_sh() {
	/usr/bin/cat > "$1/sh" <<'SHIM'
#!/bin/bash
# SAFE-F2 test shim: only the target's launcher call is faulted:
#   sh -c <launcher text> launcher <wrapper> <output> <status> <collector status>
# Every other call goes to the real shell under test unchanged.
if [ "${1:-}" = "-c" ] && [ "${3:-}" = "launcher" ] && [ "$#" -eq 7 ]; then
	case "${SAFE_F2_SH_MODE:-}" in
		exit97) exit 97 ;;
		out_unwritable)
			/usr/bin/chmod 000 "$5" || exit 96
			exec "$SAFE_F2_REAL_SH" "$@" ;;
		kill_self) kill -KILL $$ ;;
		precreate_status)
			printf 'garbage\n' > "$6" || exit 96
			exec "$SAFE_F2_REAL_SH" "$@" ;;
		precreate_collect)
			printf '0\n' > "$7" || exit 96
			exec "$SAFE_F2_REAL_SH" "$@" ;;
		*) echo "sh shim: unknown mode" >&2; exit 99 ;;
	esac
fi
exec "$SAFE_F2_REAL_SH" "$@"
SHIM
	/usr/bin/chmod 755 "$1/sh"
}

write_shim_cat() {
	/usr/bin/cat > "$1/cat" <<'SHIM'
#!/bin/bash
# SAFE-F2 test shim: only "cat" with no arguments (the target's output
# collector) is faulted. "cat <file>" goes to the real cat unchanged.
if [ "$#" -ne 0 ]; then exec /usr/bin/cat "$@"; fi
case "${SAFE_F2_CAT_MODE:-}" in
	fail_after_read) /usr/bin/cat > /dev/null; exit 1 ;;
	exit127) exit 127 ;;
	kill_self) kill -KILL $$ ;;
	discard_ok) /usr/bin/cat > /dev/null; exit 0 ;;
	*) echo "cat shim: unknown mode" >&2; exit 99 ;;
esac
SHIM
	/usr/bin/chmod 755 "$1/cat"
}

# Fake wrappers. The target starts its wrapper as "sh <file>", so each of
# these is interpreted by the shell under test.
write_fakes() {
	if [ -d "$FAKES" ]; then return 0; fi
	mk "$FAKES"
	/usr/bin/cat > "$FAKES/marker_wrapper.sh" <<'FAKE'
# prints nothing, always exits 0, leaves a marker each time it is started
printf 'started\n' >> "$SAFE_F2_MARKER"
exit 0
FAKE
	/usr/bin/cat > "$FAKES/passthrough_wrapper.sh" <<'FAKE'
# runs the runner and returns its exit code; NO strict PASS-line check
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
sh "$REPO_DIR/godot/tests/run_tests.sh" "$@"
FAKE
	/usr/bin/cat > "$FAKES/probe_wrapper.sh" <<'FAKE'
# records whether noclobber reached the wrapper
case "$-" in
	*C*) state=on ;;
	*) state=off ;;
esac
printf 'noclobber=%s shellopts=%s\n' "$state" "${SHELLOPTS:-}" >> "$SAFE_F2_MARKER"
exit 0
FAKE
	/usr/bin/cat > "$FAKES/code5_wrapper.sh" <<'FAKE'
# records whether stdout is a pipe, then exits 5
if [ -p /dev/stdout ]; then p=yes; else p=no; fi
printf 'stdout_pipe=%s\n' "$p" >> "$SAFE_F2_MARKER"
exit 5
FAKE
}

ensure_s2() {
	if [ -d "$S2DIR" ]; then return 0; fi
	mk "$S2DIR"
	/usr/bin/ln -s /bin/bash "$S2DIR/sh" || die "cannot create the bash-as-sh link"
}

# ------------------------------------------------------------- case runner
reset_case() {
	C_SHIMS=""            # space separated: mktemp mkdir cp sh cat
	C_ENV=()              # extra NAME=value for the case
	C_WRAPPER=""          # wrapper argument ("" = target's default)
	C_TMPDIR=""           # "" = <case>/tmp ; otherwise literal value
	C_PATH=""             # "" = default
	C_SCRIPT=""           # "" = the target in the workspace
	C_TIMEOUT="$STUB_TIMEOUT"
	X_ABORT=0             # 1: exit-3 rules (ABORTED, no verdict line)
	X_MARKER=""           # "" | absent | lines:<n>:<prefix>
	X_ERR_HAS=()          # fixed strings required in stderr
	X_OUT_HAS=()          # fixed strings required in stdout
	X_OK=""               # required number of "ok" lines
	X_PRESERVED_ERR=""    # required number of preserved folders listed in stderr
	X_DIRS=""             # required number of case folders in the case tmp
	X_COMPLETE=0          # 1: every case folder complete, collector 0
	X_STATUS_ALL=""       # every wrapper_status.txt must hold this
	X_FAILED_LINES=""     # required number of "FAILED:" lines in stdout
	CASE_WORK=""; CASE_EV=""; CASE_TMP=""; CASE_CODE=""
}

count_fixed() {  # count_fixed <fixed string> <file>
	local n
	n="$(grep -c -F -- "$1" "$2" 2>/dev/null)"
	printf '%s' "${n:-0}"
}
count_re() {  # count_re <regex> <file>
	local n
	n="$(grep -c -E -- "$1" "$2" 2>/dev/null)"
	printf '%s' "${n:-0}"
}

# prepare_case <id> <shell>: creates the case folders and shims.
prepare_case() {
	local id="$1" shell="$2" key
	key="${id}_${shell}"
	CASE_WORK="$GROUP_WORK/$key"
	CASE_EV="$EVID_CASES/$key"
	mk "$CASE_WORK"; mk "$CASE_WORK/tmp"; mk "$CASE_WORK/state"; mk "$CASE_WORK/bin"; mk "$CASE_WORK/aux"
	mk "$CASE_EV"
	CASE_TMP="$CASE_WORK/tmp"
	local s
	for s in $C_SHIMS; do
		case "$s" in
			mktemp) write_shim_mktemp "$CASE_WORK/bin" ;;
			mkdir) write_shim_mkdir "$CASE_WORK/bin" ;;
			cp) write_shim_cp "$CASE_WORK/bin" ;;
			sh) write_shim_sh "$CASE_WORK/bin" ;;
			cat) write_shim_cat "$CASE_WORK/bin" ;;
			*) die "unknown shim: $s" ;;
		esac
	done
}

# execute_case <id> <shell> <expected exit> <kind>
execute_case() {
	local id="$1" shell="$2" expect="$3" kind="$4"
	local shbin path tmpdir script fails="" v n d
	if [ "$shell" = "S2" ]; then
		shbin="$S2DIR/sh"; path="$CASE_WORK/bin:$S2DIR:/usr/bin:/bin"
	else
		shbin="/bin/sh"; path="$CASE_WORK/bin:/usr/bin:/bin"
	fi
	[ -z "$C_PATH" ] || path="$C_PATH"
	tmpdir="$CASE_TMP"
	[ -z "$C_TMPDIR" ] || tmpdir="$C_TMPDIR"
	script="$TARGET"
	[ -z "$C_SCRIPT" ] || script="$C_SCRIPT"
	local -a envv=(
		"PATH=$path" "HOME=$ROOT/home" "TMPDIR=$tmpdir"
		"SAFE_F2_STATE=$CASE_WORK/state" "SAFE_F2_AUX=$CASE_WORK/aux"
		"SAFE_F2_MARKER=$CASE_WORK/state/marker.txt" "SAFE_F2_REAL_SH=$shbin"
	)
	if [ "${#C_ENV[@]}" -gt 0 ]; then envv+=("${C_ENV[@]}"); fi
	local -a wargs=()
	[ -z "$C_WRAPPER" ] || wargs=("$C_WRAPPER")

	{
		printf 'id=%s\nshell=%s\nkind=%s\nexpected_exit=%s\nabort_rules=%s\nmarker_rule=%s\n' \
			"$id" "$shell" "$kind" "$expect" "$X_ABORT" "$X_MARKER"
		printf 'shell_binary=%s\nscript=%s\nwrapper_arg=%s\nshims=%s\ntimeout=%s\n' \
			"$shbin" "$script" "$C_WRAPPER" "$C_SHIMS" "$C_TIMEOUT"
		printf 'env:\n'; printf '  %s\n' "${envv[@]}"
	} > "$CASE_EV/expect.txt" || evidence_fail "cannot write $CASE_EV/expect.txt"

	(
		cd "$CASE_WORK" || exit 125
		exec /usr/bin/timeout --signal=TERM --kill-after=15 "$C_TIMEOUT" \
			/usr/bin/env -i "${envv[@]}" "$shbin" "$script" "${wargs[@]}"
	) > "$CASE_EV/stdout.log" 2> "$CASE_EV/stderr.log"
	CASE_CODE=$?
	printf '%s\n' "$CASE_CODE" > "$CASE_EV/exit_code.txt" || evidence_fail "cannot write $CASE_EV/exit_code.txt"

	# ---- evidence collection (B-3): any failure here is a mismatch
	if [ -f "$CASE_WORK/state/marker.txt" ]; then
		/usr/bin/cp "$CASE_WORK/state/marker.txt" "$CASE_EV/markers.txt" || fails="$fails evidence:markers-copy;"
	else
		printf 'ABSENT\n' > "$CASE_EV/markers.txt" || fails="$fails evidence:markers-write;"
	fi
	list_tree "$CASE_WORK" "$CASE_EV/tree_after.txt" || fails="$fails evidence:tree-listing;"
	collect_case_dirs "$CASE_TMP" "$CASE_EV/casedir_list.txt" || fails="$fails evidence:case-folder-listing;"
	{
		while IFS= read -r d; do
			printf '%s wrapper_status=%s collector_status=%s\n' "$d" \
				"$( [ -r "$d/wrapper_status.txt" ] && /usr/bin/cat "$d/wrapper_status.txt" || echo MISSING )" \
				"$( [ -r "$d/output_collector_status.txt" ] && /usr/bin/cat "$d/output_collector_status.txt" || echo MISSING )"
		done < "$CASE_EV/casedir_list.txt"
	} > "$CASE_EV/casedirs.txt" || fails="$fails evidence:casedirs;"
	for v in expect.txt exit_code.txt stdout.log stderr.log markers.txt tree_after.txt casedir_list.txt casedirs.txt; do
		[ -f "$CASE_EV/$v" ] || fails="$fails evidence:missing-$v;"
	done

	# ---- comparison with the expectation
	[ "$CASE_CODE" = "$expect" ] || fails="$fails exit=$CASE_CODE(want $expect);"
	if [ "$X_ABORT" = "1" ]; then
		[ "$(count_fixed "ABORTED" "$CASE_EV/stderr.log")" -ge 1 ] || fails="$fails no-ABORTED-in-stderr;"
		[ "$(count_fixed "Wrapper test passed" "$CASE_EV/stdout.log")" -eq 0 ] || fails="$fails verdict-passed-printed;"
		[ "$(count_fixed "Wrapper test FAILED" "$CASE_EV/stdout.log")" -eq 0 ] || fails="$fails verdict-failed-printed;"
	fi
	case "$X_MARKER" in
		"") ;;
		absent) [ ! -e "$CASE_WORK/state/marker.txt" ] || fails="$fails marker-present;" ;;
		lines:*)
			v="${X_MARKER#lines:}"; n="${v%%:*}"; v="${v#*:}"
			if [ -f "$CASE_WORK/state/marker.txt" ]; then
				[ "$(grep -c '' "$CASE_WORK/state/marker.txt")" -eq "$n" ] || fails="$fails marker-line-count;"
				[ "$(grep -c -v -F -- "$v" "$CASE_WORK/state/marker.txt")" -eq 0 ] || fails="$fails marker-content;"
			else
				fails="$fails marker-missing;"
			fi ;;
		*) die "unknown marker rule: $X_MARKER" ;;
	esac
	if [ "${#X_ERR_HAS[@]}" -gt 0 ]; then
		for v in "${X_ERR_HAS[@]}"; do
			[ "$(count_fixed "$v" "$CASE_EV/stderr.log")" -ge 1 ] || fails="$fails stderr-lacks[$v];"
		done
	fi
	if [ "${#X_OUT_HAS[@]}" -gt 0 ]; then
		for v in "${X_OUT_HAS[@]}"; do
			[ "$(count_fixed "$v" "$CASE_EV/stdout.log")" -ge 1 ] || fails="$fails stdout-lacks[$v];"
		done
	fi
	if [ -n "$X_OK" ]; then
		[ "$(count_re '^ok ' "$CASE_EV/stdout.log")" -eq "$X_OK" ] || fails="$fails ok-lines!=$X_OK;"
	fi
	if [ -n "$X_FAILED_LINES" ]; then
		[ "$(count_re '^FAILED:' "$CASE_EV/stdout.log")" -eq "$X_FAILED_LINES" ] || fails="$fails FAILED-lines!=$X_FAILED_LINES;"
	fi
	if [ -n "$X_PRESERVED_ERR" ]; then
		[ "$(count_re '^note       .*/myrial-wrapper-test\.' "$CASE_EV/stderr.log")" -eq "$X_PRESERVED_ERR" ] || fails="$fails preserved-in-stderr!=$X_PRESERVED_ERR;"
	fi
	if [ -n "$X_DIRS" ]; then
		[ "$(grep -c '' "$CASE_EV/casedir_list.txt")" -eq "$X_DIRS" ] || fails="$fails case-folders!=$X_DIRS;"
	fi
	if [ "$X_COMPLETE" = "1" ]; then
		while IFS= read -r d; do
			[ -d "$d/repo" ] || fails="$fails no-repo;"
			[ -f "$d/wrapper_output.txt" ] || fails="$fails no-output-file;"
			v="$( [ -f "$d/wrapper_status.txt" ] && /usr/bin/cat "$d/wrapper_status.txt" )"
			case "$v" in ''|*[!0-9]*) fails="$fails wrapper-status-not-numeric;" ;; esac
			v="$( [ -f "$d/output_collector_status.txt" ] && /usr/bin/cat "$d/output_collector_status.txt" )"
			[ "$v" = "0" ] || fails="$fails collector-status!=0;"
		done < "$CASE_EV/casedir_list.txt"
	fi
	if [ -n "$X_STATUS_ALL" ]; then
		while IFS= read -r d; do
			v="$( [ -f "$d/wrapper_status.txt" ] && /usr/bin/cat "$d/wrapper_status.txt" )"
			[ "$v" = "$X_STATUS_ALL" ] || fails="$fails wrapper-status!=$X_STATUS_ALL;"
		done < "$CASE_EV/casedir_list.txt"
	fi
	printf '%s\n' "${fails:-none}" > "$CASE_EV/check.txt" || evidence_fail "cannot write $CASE_EV/check.txt"

	if [ "$kind" = "canary" ]; then
		# The canary carries a deliberately wrong expectation. It is correct
		# only if the comparison above reported a mismatch.
		if [ -n "$fails" ]; then
			row "$id" "$shell" canary "$expect" "$CASE_CODE" CANARY_OK "mismatch detected as intended:$fails"
		else
			row "$id" "$shell" canary "$expect" "$CASE_CODE" CANARY_BROKEN "wrong expectation was not detected"
			stop_group "$id"
		fi
		return 0
	fi
	if [ -z "$fails" ]; then
		row "$id" "$shell" "$kind" "$expect" "$CASE_CODE" PASS "-"
	else
		row "$id" "$shell" "$kind" "$expect" "$CASE_CODE" MISMATCH "$fails"
		stop_group "$id"
	fi
}

run_case() {  # run_case <id> <shell> <expected exit>
	prepare_case "$1" "$2"
	execute_case "$1" "$2" "$3" script
}

# Expectation presets
abort_before_folder() {  # exit 3 before any case folder exists
	X_ABORT=1
}
abort_after_folder() {  # exit 3 with <n> preserved folders listed in stderr
	X_ABORT=1; X_PRESERVED_ERR="$1"
}
pass6() {
	X_OK=6; X_FAILED_LINES=0; X_DIRS=6; X_COMPLETE=1
	X_OUT_HAS=("Wrapper test passed (6 cases)")
}

# -------------------------------------------------- independent fixtures
# Expected fixture bytes, produced with the BASELINE's own echo / printf lines
# (not with the target's write_new_file), to prove the bytes did not change.
stub_sha() {  # stub_sha <exit code> <runner lines...>
	local code="$1" line
	shift
	{
		echo '#!/bin/sh'
		for line in "$@"; do printf "echo '%s'\n" "$line"; done
		echo "exit $code"
	} | /usr/bin/sha256sum | cut -d' ' -f1
}
expected_stub_shas() {
	stub_sha 0 "PASS a | A verification passed (1 checks)" "All 1 test script(s) passed"
	stub_sha 1 "PASS a | A verification passed (1 checks)" "FAIL b (exit 1) | FAILED: deliberate"
	stub_sha 1 "PASS a | A verification passed (1 checks)" "FAIL c (exit 1) | C verification passed (1 checks)"
	stub_sha 0 "PASS d | SCRIPT ERROR: Parse Error: x" "All 1 test script(s) passed"
	stub_sha 0 "PASS e | " "All 1 test script(s) passed"
	stub_sha 2 "Godot import step failed"
}
GD_SRC_1=$'extends SceneTree\nfunc _initialize() -> void:\n\tprint("FIXTURE verification passed (1 checks)")\n\tquit(0)'
GD_SRC_2=$'extends SceneTree\nfunc _initialize() -> void:\n\tpush_error("FAILED: deliberate")\n\tquit(1)'
GD_SRC_3=$'extends SceneTree\nfunc _initialize() -> void:\n\tpush_error("FAILED: deliberate")\n\tprint("FIXTURE verification passed (1 checks)")\n\tquit(1)'
GD_SRC_4=$'extends SceneTree\nfunc _initialize() -> void:\n\tvar x := undefined_call(\n\tquit(0)'
expected_gd_shas() {
	local s
	for s in "$GD_SRC_1" "$GD_SRC_2" "$GD_SRC_3" "$GD_SRC_4"; do
		printf '%s\n' "$s" | /usr/bin/sha256sum | cut -d' ' -f1
	done
}
expected_project_sha() {
	printf 'config_version=5\n\n[application]\n\nconfig/name="WrapperTest"\n' | /usr/bin/sha256sum | cut -d' ' -f1
}
expected_marker_sha() {
	printf 'class_name WrapperTestMarker\nextends RefCounted\n' | /usr/bin/sha256sum | cut -d' ' -f1
}

# fixture_check <id> <shell> <tmp of an exit-0 run> <stub|godot>
fixture_check() {
	local id="$1" shell="$2" tmp="$3" what="$4" ev d fails="" got want v
	ev="$EVID_CASES/${id}_${shell}"
	mk "$ev"
	collect_case_dirs "$tmp" "$ev/casedir_list.txt" || fails="$fails evidence:case-folder-listing;"
	if [ "$what" = "stub" ]; then
		want="$(expected_stub_shas | sort)"
		got="$(while IFS= read -r d; do
			if [ ! -e "$d/repo/godot/project.godot" ]; then /usr/bin/sha256sum < "$d/repo/godot/tests/run_tests.sh" | cut -d' ' -f1; fi
		done < "$ev/casedir_list.txt" | sort)"
		printf 'expected:\n%s\nfound:\n%s\n' "$want" "$got" > "$ev/fixture_hashes.txt" || fails="$fails evidence:fixture-hashes;"
		[ "$want" = "$got" ] || fails="$fails stub-runner-bytes-differ;"
		[ "$(printf '%s\n' "$got" | grep -c '')" -eq 6 ] || fails="$fails stub-runner-count!=6;"
	else
		want="$(expected_gd_shas | sort)"
		got="$(while IFS= read -r d; do
			if [ -e "$d/repo/godot/project.godot" ]; then /usr/bin/sha256sum < "$d/repo/godot/tests/verify_fixture.gd" | cut -d' ' -f1; fi
		done < "$ev/casedir_list.txt" | sort)"
		printf 'expected verify_fixture:\n%s\nfound:\n%s\n' "$want" "$got" > "$ev/fixture_hashes.txt" || fails="$fails evidence:fixture-hashes;"
		[ "$want" = "$got" ] || fails="$fails verify-fixture-bytes-differ;"
		[ "$(printf '%s\n' "$got" | grep -c '')" -eq 4 ] || fails="$fails verify-fixture-count!=4;"
		while IFS= read -r d; do
			if [ -e "$d/repo/godot/project.godot" ]; then
				v="$(/usr/bin/sha256sum < "$d/repo/godot/project.godot" | cut -d' ' -f1)"
				[ "$v" = "$(expected_project_sha)" ] || fails="$fails project.godot-bytes-differ;"
				v="$(/usr/bin/sha256sum < "$d/repo/godot/marker.gd" | cut -d' ' -f1)"
				[ "$v" = "$(expected_marker_sha)" ] || fails="$fails marker.gd-bytes-differ;"
			fi
		done < "$ev/casedir_list.txt"
	fi
	printf '%s\n' "${fails:-none}" > "$ev/check.txt" || evidence_fail "cannot write $ev/check.txt"
	if [ -z "$fails" ]; then
		row "$id" "$shell" check "-" "-" PASS "-"
	else
		row "$id" "$shell" check "-" "-" MISMATCH "$fails"
		stop_group "$id"
	fi
}

# --------------------------------------------------------------- groups
group_N() {
	local s
	for s in S1 S2; do
		reset_case; pass6
		run_case N-1 "$s" 0
		fixture_check N-3 "$s" "$CASE_TMP" stub

		reset_case; C_WRAPPER="$FAKES/marker_wrapper.sh"
		X_OK=0; X_FAILED_LINES=6; X_MARKER="lines:6:started"
		X_OUT_HAS=("Wrapper test FAILED: 6 of 6")
		run_case N-4 "$s" 1

		reset_case; C_WRAPPER="$FAKES/passthrough_wrapper.sh"
		X_OK=4; X_FAILED_LINES=2
		X_OUT_HAS=("Wrapper test FAILED: 2 of 6" "FAILED:  stub: PASS d | SCRIPT ERROR: Parse Error: x" "FAILED:  stub: PASS e | ")
		run_case N-5 "$s" 1
	done
	# Canary: a normal passing run judged against a deliberately wrong
	# expectation (exit 3). The harness must report the mismatch.
	reset_case; X_ABORT=1
	prepare_case CANARY S1
	execute_case CANARY S1 3 canary
}

group_M() {
	local s m
	for s in S1 S2; do
		for m in "M-1 fail" "M-2 empty" "M-3 root" "M-4 relative" "M-6 twolines" "M-7 badsuffix" "M-8 notcreated" \
			"M-10a nonempty_file" "M-10b nonempty_hidden" "M-10c nonempty_dangling"; do
			reset_case; abort_before_folder
			C_SHIMS="mktemp"; C_ENV=("SAFE_F2_MKTEMP_MODE=${m#* }")
			C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
			run_case "${m%% *}" "$s" 3
		done

		# M-5: an existing folder outside the temp base must stay unchanged.
		reset_case; abort_before_folder
		C_SHIMS="mktemp"; C_ENV=("SAFE_F2_MKTEMP_MODE=outside")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		prepare_case M-5 "$s"
		mk "$CASE_WORK/aux/outside"
		printf 'sentinel\n' > "$CASE_WORK/aux/outside/sentinel.txt" || die "cannot write the M-5 sentinel"
		list_tree "$CASE_WORK/aux" "$CASE_EV/aux_before.txt" || evidence_fail "M-5 aux listing (before) failed"
		execute_case M-5 "$s" 3 script
		list_tree "$CASE_WORK/aux" "$CASE_EV/aux_after.txt" || evidence_fail "M-5 aux listing (after) failed"
		cmp -s "$CASE_EV/aux_before.txt" "$CASE_EV/aux_after.txt" || { row M-5 "$s" check - - MISMATCH "outside-folder-changed"; stop_group M-5; }

		# M-9: a symbolic link of the right form; its target must stay unchanged.
		reset_case; abort_before_folder
		C_SHIMS="mktemp"; C_ENV=("SAFE_F2_MKTEMP_MODE=symlink")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		prepare_case M-9 "$s"
		mk "$CASE_WORK/aux/linktarget"
		list_tree "$CASE_WORK/aux" "$CASE_EV/aux_before.txt" || evidence_fail "M-9 aux listing (before) failed"
		execute_case M-9 "$s" 3 script
		list_tree "$CASE_WORK/aux" "$CASE_EV/aux_after.txt" || evidence_fail "M-9 aux listing (after) failed"
		cmp -s "$CASE_EV/aux_before.txt" "$CASE_EV/aux_after.txt" || { row M-9 "$s" check - - MISMATCH "link-target-changed"; stop_group M-9; }

		# M-11: two cases succeed, the third mktemp fails. Required: exactly two
		# "ok" lines, exactly two case folders (so no third wrapper could have
		# been started), both listed as preserved. Markers are not used here.
		reset_case; abort_after_folder 2
		C_SHIMS="mktemp"; C_ENV=("SAFE_F2_MKTEMP_MODE=fail_on_3")
		X_OK=2; X_DIRS=2; X_COMPLETE=1
		run_case M-11 "$s" 3

		# M-12: mktemp absent from PATH.
		reset_case; abort_before_folder
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("mktemp is not available")
		prepare_case M-12 "$s"
		mk "$CASE_WORK/nomk"
		/usr/bin/ln -s /usr/bin/dirname "$CASE_WORK/nomk/dirname" || die "cannot link dirname"
		C_PATH="$CASE_WORK/nomk"
		execute_case M-12 "$s" 3 script

		reset_case; abort_before_folder; C_TMPDIR="/"
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		run_case M-13 "$s" 3

		reset_case; abort_before_folder; C_TMPDIR="relative-tmp"
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		run_case M-14 "$s" 3

		reset_case; abort_before_folder
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		prepare_case M-15 "$s"
		C_TMPDIR="$CASE_WORK/missing-folder"
		execute_case M-15 "$s" 3 script

		# M-16: real mktemp fails because the temp base is read-only.
		reset_case; abort_before_folder
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("mktemp -d failed")
		prepare_case M-16 "$s"
		/usr/bin/chmod 555 "$CASE_WORK/tmp" || die "cannot make the case tmp read-only"
		execute_case M-16 "$s" 3 script

		# M-17 (positive): trailing slashes on TMPDIR, real mktemp.
		reset_case; pass6
		prepare_case M-17 "$s"
		C_TMPDIR="$CASE_WORK/tmp//"
		execute_case M-17 "$s" 0 script
	done
	# "/repo" must not exist after the mktemp group (M-3 returned "/").
	[ ! -e /repo ] || { row M-3 "-" check - - MISMATCH "/repo exists"; stop_group M-3; }
}

group_F() {
	local s
	for s in S1 S2; do
		reset_case; abort_after_folder 1; C_SHIMS="mkdir"
		C_ENV=("SAFE_F2_MKDIR_MODE=fail_on" "SAFE_F2_MKDIR_N=1")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		run_case F-1 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="mkdir"
		C_ENV=("SAFE_F2_MKDIR_MODE=fail_on" "SAFE_F2_MKDIR_N=4")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		run_case F-2 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="mkdir"
		C_ENV=("SAFE_F2_MKDIR_MODE=preexist_1")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		run_case F-3 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cp"
		C_ENV=("SAFE_F2_CP_MODE=fail")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		run_case F-4 "$s" 3

		# F-5: the wrapper argument does not exist. The target stops before any
		# case folder is created, so NO preserved-folder list is required.
		reset_case; abort_before_folder; X_DIRS=0
		X_ERR_HAS=("wrapper under test not found")
		prepare_case F-5 "$s"
		C_WRAPPER="$CASE_WORK/no-such-wrapper.sh"
		execute_case F-5 "$s" 3 script

		reset_case; abort_after_folder 1; C_SHIMS="cp"
		C_ENV=("SAFE_F2_CP_MODE=then_ro_tests")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("cannot create or write new file")
		run_case F-6 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cp"
		C_ENV=("SAFE_F2_CP_MODE=then_precreate_stub")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("file already exists")
		run_case F-7 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cp"
		C_ENV=("SAFE_F2_CP_MODE=then_precreate_out")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("wrapper output already exists")
		run_case F-8 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cp"
		C_ENV=("SAFE_F2_CP_MODE=then_unreadable")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("wrapper copy is missing or unreadable")
		run_case F-9 "$s" 3

		# F-10: Godot branch entered (GODOT set to a path that is never run),
		# but the script copy has no godot/tests/run_tests.sh beside it. The six
		# stub cases run first with the real wrapper, then the target aborts.
		reset_case; abort_after_folder 6; X_OK=6
		X_ERR_HAS=("real Godot test runner not found")
		C_ENV=("GODOT=/nonexistent/safe-f2-godot-is-never-run")
		C_WRAPPER="$REAL_WRAPPER"
		prepare_case F-10 "$s"
		mk "$CASE_WORK/alt"; mk "$CASE_WORK/alt/nakama"; mk "$CASE_WORK/alt/nakama/scripts"
		/usr/bin/cp "$TARGET" "$CASE_WORK/alt/nakama/scripts/test_run_godot_regression_isolated.sh" || die "cannot copy the target for F-10"
		C_SCRIPT="$CASE_WORK/alt/nakama/scripts/test_run_godot_regression_isolated.sh"
		execute_case F-10 "$s" 3 script
	done
}

group_L() {
	local s
	for s in S1 S2; do
		reset_case; abort_after_folder 1; C_SHIMS="sh"; C_ENV=("SAFE_F2_SH_MODE=exit97")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("launcher exited 97")
		run_case L-1 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="sh"; C_ENV=("SAFE_F2_SH_MODE=out_unwritable")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("launcher exited")
		run_case L-2 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="sh"; C_ENV=("SAFE_F2_SH_MODE=kill_self")
		C_WRAPPER="$FAKES/marker_wrapper.sh"; X_MARKER="absent"
		X_ERR_HAS=("launcher exited 137")
		run_case L-3 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="sh"; C_ENV=("SAFE_F2_SH_MODE=precreate_status")
		X_ERR_HAS=("does not hold a plain exit code")
		run_case L-4 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="sh"; C_ENV=("SAFE_F2_SH_MODE=precreate_collect")
		X_ERR_HAS=("launcher exited 98")
		run_case L-5 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cat"; C_ENV=("SAFE_F2_CAT_MODE=fail_after_read")
		X_ERR_HAS=("output collection failed (collector exit 1")
		run_case L-6 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cat"; C_ENV=("SAFE_F2_CAT_MODE=exit127")
		run_case L-7 "$s" 3

		reset_case; abort_after_folder 1; C_SHIMS="cat"; C_ENV=("SAFE_F2_CAT_MODE=kill_self")
		run_case L-8 "$s" 3

		# L-9 (documented boundary): the collector silently loses the output and
		# reports success. Result must be FAILED for all six, never "passed".
		reset_case; C_SHIMS="cat"; C_ENV=("SAFE_F2_CAT_MODE=discard_ok")
		X_OK=0; X_FAILED_LINES=6
		X_OUT_HAS=("Wrapper test FAILED: 6 of 6")
		run_case L-9 "$s" 1

		# L-10 (I-3 regression): noclobber must not reach the wrapper.
		reset_case; C_WRAPPER="$FAKES/probe_wrapper.sh"
		X_MARKER="lines:6:noclobber=off"
		run_case L-10 "$s" 1

		# L-11: the recorded wrapper code is the code the wrapper returned, and
		# the wrapper's stdout is a pipe (the collector).
		reset_case; C_WRAPPER="$FAKES/code5_wrapper.sh"
		X_MARKER="lines:6:stdout_pipe=yes"; X_STATUS_ALL=5; X_DIRS=6; X_FAILED_LINES=6
		run_case L-11 "$s" 1
	done
	# L-10x: same probe under bash-as-sh with SHELLOPTS exported (without
	# noclobber). bash passes exported SHELLOPTS to child shells.
	reset_case; C_WRAPPER="$FAKES/probe_wrapper.sh"
	C_ENV=("SHELLOPTS=hashall")
	X_MARKER="lines:6:noclobber=off"
	run_case L-10x S2 1
}

group_N6() {
	local i total=0 n
	for i in 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20; do
		reset_case; pass6
		run_case "N-6.$i" S1 0
		n="$(grep -c '' "$CASE_EV/casedir_list.txt")"
		total=$((total + n))
	done
	if [ "$total" -eq 120 ]; then
		row N-6.total S1 check 120 "$total" PASS "preserved case folders over 20 runs"
	else
		row N-6.total S1 check 120 "$total" MISMATCH "preserved-folder-total"
		stop_group N-6.total
	fi
}

snapshot_lines() {
	local p
	for p in "$REAL_HOME/.local/share/godot" "$REAL_HOME/.config/godot" "$REAL_HOME/.cache/godot" /repo; do
		if [ -e "$p" ] || [ -L "$p" ]; then printf 'PRESENT %s\n' "$p"; else printf 'ABSENT %s\n' "$p"; fi
	done
}

group_G() {
	local s ev fails=""
	[ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ] || die "--godot is missing or not executable"
	case "$GODOT_BIN" in
		"$ROOT"/*) ;;
		*) die "--godot is outside the run root" ;;
	esac
	for s in S1 S2; do
		reset_case
		C_TIMEOUT="$GODOT_CASE_TIMEOUT"; C_ENV=("GODOT=$GODOT_BIN")
		X_OK=10; X_FAILED_LINES=0; X_DIRS=10; X_COMPLETE=1
		X_OUT_HAS=("Wrapper test passed (10 cases)")
		run_case G-1 "$s" 0
		fixture_check G-3 "$s" "$CASE_TMP" godot
	done
	# G-4: where did Godot user data appear? Only inside the run root is allowed.
	ev="$EVID_CASES/G-4_-"
	mk "$ev"
	(
		set -o pipefail
		/usr/bin/find "$ROOT" -xdev -type d -name app_userdata -print 2> "$ev/find_errors.txt" | LC_ALL=C sort > "$ev/app_userdata_inside_root.txt"
	) || fails="evidence:app_userdata-listing;"
	[ ! -s "$ev/find_errors.txt" ] || fails="$fails evidence:app_userdata-listing-errors;"
	snapshot_lines > "$ev/outside_locations.txt" || fails="$fails evidence:outside-locations;"
	[ "$(grep -c '^PRESENT ' "$ev/outside_locations.txt")" -eq 0 ] || fails="godot-data-or-/repo-outside-run-root;"
	if [ -z "$fails" ]; then
		row G-4 "-" check "-" "-" PASS "-"
	else
		row G-4 "-" check "-" "-" MISMATCH "$fails"
		stop_group G-4
	fi
}

# Regression groups run the repository's own unmodified commands. They use
# the job's PATH (Node from setup-node) but HOME and TMPDIR inside the root.
regression_env() {
	/usr/bin/env -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u XDG_CACHE_HOME \
		HOME="$ROOT/home" TMPDIR="$1" "${@:2}"
}
group_R() {  # group_R <id> <timeout seconds> <subdir> <command...>
	local id="$1" limit="$2" sub="$3" ev tmp code
	shift 3
	ev="$EVID_CASES/${id}_-"; tmp="$GROUP_WORK/tmp"
	mk "$ev"; mk "$tmp"
	printf 'cwd=%s\ncommand=%s\ntimeout=%s\n' "$WORKSPACE/$sub" "$*" "$limit" > "$ev/expect.txt"
	(
		cd "$WORKSPACE/$sub" || exit 125
		regression_env "$tmp" /usr/bin/timeout --signal=TERM --kill-after=30 "$limit" "$@"
	) > "$ev/stdout.log" 2> "$ev/stderr.log"
	code=$?
	printf '%s\n' "$code" > "$ev/exit_code.txt"
	grep -E '^(# |ℹ )(tests|suites|pass|fail|cancelled|skipped|todo) ' "$ev/stdout.log" > "$ev/counts.txt" 2>/dev/null
	R_CODE="$code"; R_EV="$ev"
}
group_R1() {
	group_R R-1 900 "." npm test
	if [ "$R_CODE" -eq 0 ]; then row R-1 "-" check 0 "$R_CODE" PASS "node root tests; counts in counts.txt"
	else row R-1 "-" check 0 "$R_CODE" MISMATCH "npm test failed"; stop_group R-1; fi
}
group_R2() {
	group_R R-2 1200 "nakama" sh -c 'npm ci && npm test'
	if [ "$R_CODE" -eq 0 ]; then row R-2 "-" check 0 "$R_CODE" PASS "nakama unit tests; counts in counts.txt"
	else row R-2 "-" check 0 "$R_CODE" MISMATCH "npm ci or npm test failed"; stop_group R-2; fi
}
group_R3() {
	local files passes fails=""
	[ -n "$GODOT_BIN" ] && [ -x "$GODOT_BIN" ] || die "--godot is missing or not executable"
	files="$(
		set -o pipefail
		/usr/bin/find "$WORKSPACE/godot/tests" -maxdepth 1 -type f -name 'verify_*.gd' -print 2> "$GROUP_WORK/verify_count.errors" | grep -c ''
	)" || evidence_fail "cannot count verify_*.gd files"
	[ ! -s "$GROUP_WORK/verify_count.errors" ] || evidence_fail "find reported errors while counting verify_*.gd files"
	group_R R-3 1800 "." /usr/bin/env GODOT="$GODOT_BIN" sh "$REAL_WRAPPER"
	passes="$(count_re '^PASS ' "$R_EV/stdout.log")"
	printf 'verify_files=%s pass_lines=%s expected=%s\n' "$files" "$passes" "$VERIFY_COUNT" > "$R_EV/counts.txt"
	[ "$R_CODE" -eq 0 ] || fails="$fails exit=$R_CODE;"
	[ "$files" -eq "$VERIFY_COUNT" ] || fails="$fails verify-file-count=$files;"
	[ "$passes" -eq "$VERIFY_COUNT" ] || fails="$fails PASS-lines=$passes;"
	[ "$(count_re '^FAIL ' "$R_EV/stdout.log")" -eq 0 ] || fails="$fails FAIL-line-present;"
	[ "$(count_fixed "All $VERIFY_COUNT test script(s) passed" "$R_EV/stdout.log")" -ge 1 ] || fails="$fails no-all-passed-line;"
	[ "$(count_fixed "Strict check: every PASS line carries its passed message" "$R_EV/stdout.log")" -ge 1 ] || fails="$fails no-strict-check-line;"
	if [ -z "$fails" ]; then row R-3 "-" check 0 "$R_CODE" PASS "godot verify regression, linux"
	else row R-3 "-" check 0 "$R_CODE" MISMATCH "$fails"; stop_group R-3; fi
}

# ------------------------------------------------------------------ audit
# Re-reads the raw logs. It does not rely on the comparison made at run time.
audit() {
	local g line id shell key ev exp code out err verdict kind bad=0 n m
	local report="$EVID/audit_report.txt"
	printf '' > "$report" || die "cannot write the audit report"
	say() { printf '%s\n' "$*" | tee -a "$report"; }
	[ -f "$RESULTS" ] || { say "AUDIT FAIL: no results file"; return 1; }
	# The audit is only valid for the complete planned set, never a subset.
	[ "$AUDIT_GROUPS" = "$FULL_GROUPS" ] || { say "AUDIT FAIL: audit asked for '$AUDIT_GROUPS', must be '$FULL_GROUPS'"; return 1; }
	for g in $AUDIT_GROUPS; do
		# Checked here, in the main shell: an unknown group must stop the audit.
		planned_ids "$g" > /dev/null
		n="$(planned_ids "$g" | grep -c '')"
		[ "$n" -ge 1 ] || { say "AUDIT FAIL: group $g has no planned results"; return 1; }
	done
	# B-2: the result file must hold EXACTLY the planned set: 119 rows, each
	# id|shell once. Missing, duplicated or extra rows all fail the audit.
	local planned_file="$EVID/audit_planned_ids.txt" actual_file="$EVID/audit_actual_ids.txt"
	(
		set -o pipefail
		for g in $AUDIT_GROUPS; do planned_ids "$g"; done | LC_ALL=C sort > "$planned_file"
	) || { say "AUDIT FAIL: cannot build the planned id list"; return 1; }
	(
		set -o pipefail
		awk -F '\t' 'NF != 7 { bad = 1 } { print $1 "|" $2 } END { exit bad }' "$RESULTS" | LC_ALL=C sort > "$actual_file"
	) || { say "AUDIT FAIL: results file unreadable or a row does not have 7 columns"; bad=$((bad + 1)); }
	n="$(grep -c '' "$planned_file")"
	[ "$n" -eq "$EXPECTED_ROWS" ] || { say "AUDIT FAIL: planned rows = $n, must be $EXPECTED_ROWS"; bad=$((bad + 1)); }
	[ "$(LC_ALL=C sort -u "$planned_file" | grep -c '')" -eq "$n" ] || { say "AUDIT FAIL: the plan itself has duplicate ids"; bad=$((bad + 1)); }
	m="$(grep -c '' "$actual_file")"
	[ "$m" -eq "$EXPECTED_ROWS" ] || { say "AUDIT FAIL: result rows = $m, must be $EXPECTED_ROWS"; bad=$((bad + 1)); }
	while IFS= read -r line; do
		say "AUDIT FAIL: duplicated result row: $line"; bad=$((bad + 1))
	done < <(LC_ALL=C uniq -d "$actual_file")
	while IFS= read -r line; do
		say "AUDIT FAIL: missing result row: $line"; bad=$((bad + 1))
	done < <(LC_ALL=C comm -23 "$planned_file" <(LC_ALL=C sort -u "$actual_file"))
	while IFS= read -r line; do
		say "AUDIT FAIL: extra result row (not in the plan): $line"; bad=$((bad + 1))
	done < <(LC_ALL=C comm -13 "$planned_file" <(LC_ALL=C sort -u "$actual_file"))
	for g in $AUDIT_GROUPS; do
		while IFS= read -r line; do
			id="${line%%|*}"; shell="${line#*|}"; key="${id}_${shell}"
			n="$(awk -F '\t' -v i="$id" -v s="$shell" '$1==i && $2==s' "$RESULTS" | grep -c '')"
			if [ "$n" -ne 1 ]; then
				say "AUDIT FAIL: $id/$shell has $n result rows (want 1)"; bad=$((bad + 1)); continue
			fi
			verdict="$(awk -F '\t' -v i="$id" -v s="$shell" '$1==i && $2==s {print $6}' "$RESULTS")"
			kind="$(awk -F '\t' -v i="$id" -v s="$shell" '$1==i && $2==s {print $3}' "$RESULTS")"
			if [ "$kind" = "canary" ]; then
				[ "$verdict" = "CANARY_OK" ] || { say "AUDIT FAIL: canary verdict is $verdict"; bad=$((bad + 1)); }
				continue
			fi
			if [ "$verdict" != "PASS" ]; then
				say "AUDIT FAIL: $id/$shell verdict is $verdict"; bad=$((bad + 1)); continue
			fi
			[ "$kind" = "script" ] || continue
			ev="$EVID_CASES/$key"; out="$ev/stdout.log"; err="$ev/stderr.log"
			if [ ! -f "$out" ] || [ ! -f "$err" ] || [ ! -f "$ev/exit_code.txt" ] || [ ! -f "$ev/expect.txt" ]; then
				say "AUDIT FAIL: $id/$shell evidence files missing"; bad=$((bad + 1)); continue
			fi
			exp="$(sed -n 's/^expected_exit=//p' "$ev/expect.txt")"
			code="$(/usr/bin/cat "$ev/exit_code.txt")"
			[ "$code" = "$exp" ] || { say "AUDIT FAIL: $id/$shell exit $code, expected $exp"; bad=$((bad + 1)); }
			case "$exp" in
				3)
					[ "$(count_fixed "Wrapper test passed" "$out")" -eq 0 ] || { say "AUDIT FAIL: $id/$shell printed a PASS verdict on exit 3"; bad=$((bad + 1)); }
					[ "$(count_fixed "ABORTED" "$err")" -ge 1 ] || { say "AUDIT FAIL: $id/$shell no ABORTED on exit 3"; bad=$((bad + 1)); }
					if [ "$(sed -n 's/^marker_rule=//p' "$ev/expect.txt")" = "absent" ]; then
						[ "$(/usr/bin/cat "$ev/markers.txt")" = "ABSENT" ] || { say "AUDIT FAIL: $id/$shell wrapper marker present"; bad=$((bad + 1)); }
					fi ;;
				1)
					[ "$(count_fixed "Wrapper test passed" "$out")" -eq 0 ] || { say "AUDIT FAIL: $id/$shell printed a PASS verdict on exit 1"; bad=$((bad + 1)); }
					[ "$(count_fixed "Wrapper test FAILED" "$out")" -ge 1 ] || { say "AUDIT FAIL: $id/$shell no FAILED verdict on exit 1"; bad=$((bad + 1)); } ;;
				0)
					n="$(count_re '^ok ' "$out")"
					m="$(sed -n 's/^Wrapper test passed (\([0-9][0-9]*\) cases)$/\1/p' "$out")"
					[ -n "$m" ] && [ "$n" = "$m" ] || { say "AUDIT FAIL: $id/$shell ok lines ($n) do not match the verdict line ($m)"; bad=$((bad + 1)); }
					[ "$(count_re '^FAILED:' "$out")" -eq 0 ] || { say "AUDIT FAIL: $id/$shell FAILED line in an exit-0 run"; bad=$((bad + 1)); }
					[ "$(grep -c -v 'collector_status=0$' "$ev/casedirs.txt")" -eq 0 ] || { say "AUDIT FAIL: $id/$shell a collector status is not 0"; bad=$((bad + 1)); }
					[ "$(grep -c -E 'wrapper_status=[0-9]+ ' "$ev/casedirs.txt")" -eq "$(grep -c '' "$ev/casedirs.txt")" ] || { say "AUDIT FAIL: $id/$shell a wrapper status is not numeric"; bad=$((bad + 1)); }
					;;
				*) say "AUDIT FAIL: $id/$shell unexpected expected-exit '$exp'"; bad=$((bad + 1)) ;;
			esac
		done < <(planned_ids "$g")
	done
	n="$(awk -F '\t' '$6 != "PASS" && $6 != "CANARY_OK"' "$RESULTS" | grep -c '')"
	[ "$n" -eq 0 ] || { say "AUDIT FAIL: $n result row(s) have a verdict other than PASS / CANARY_OK"; bad=$((bad + 1)); }
	n="$(awk -F '\t' '$6 == "CANARY_OK"' "$RESULTS" | grep -c '')"
	[ "$n" -eq 1 ] || { say "AUDIT FAIL: $n CANARY_OK rows, must be exactly 1"; bad=$((bad + 1)); }
	# B-3: no repository change. Both git status records must exist, the
	# command must have succeeded, and the output must be empty.
	for g in before after; do
		if [ ! -f "$EVID/git_status_$g.txt" ] || [ ! -f "$EVID/git_status_$g.exit" ]; then
			say "AUDIT FAIL: git status record '$g' missing"; bad=$((bad + 1))
		elif [ "$(/usr/bin/cat "$EVID/git_status_$g.exit")" != "0" ]; then
			say "AUDIT FAIL: git status '$g' did not succeed"; bad=$((bad + 1))
		elif [ -s "$EVID/git_status_$g.txt" ]; then
			say "AUDIT FAIL: repository not clean at '$g' (see git_status_$g.txt)"; bad=$((bad + 1))
		fi
	done
	for g in before after; do
		if [ ! -f "$EVID/containment_$g.txt" ]; then
			say "AUDIT FAIL: containment snapshot '$g' missing"; bad=$((bad + 1))
		elif [ "$(grep -c '^PRESENT ' "$EVID/containment_$g.txt")" -ne 0 ]; then
			say "AUDIT FAIL: containment snapshot '$g' shows something outside the run root"; bad=$((bad + 1))
		fi
	done
	if [ "$bad" -eq 0 ]; then
		say "AUDIT PASS: exactly $EXPECTED_ROWS planned results, each once, all consistent with their raw logs; no false PASS found; repository clean before and after; groups: $AUDIT_GROUPS"
		return 0
	fi
	say "AUDIT FAIL: $bad problem(s)"
	return 1
}

# ------------------------------------------------------------------- main
ensure_dir "$EVID_CASES"
ensure_dir "$WORK"

case "$MODE" in
	snapshot)
		case "$SNAP" in before|after) ;; *) die "bad snapshot name" ;; esac
		[ ! -e "$EVID/containment_$SNAP.txt" ] || die "snapshot '$SNAP' exists already"
		[ ! -e "$EVID/git_status_$SNAP.txt" ] || die "git status record '$SNAP' exists already"
		snapshot_lines > "$EVID/containment_$SNAP.txt" || evidence_fail "cannot write containment_$SNAP.txt"
		# --no-optional-locks: git status must not write to the repository.
		(cd "$WORKSPACE" && git --no-optional-locks status --porcelain) > "$EVID/git_status_$SNAP.txt" 2> "$EVID/git_status_$SNAP.stderr"
		gs=$?
		printf '%s\n' "$gs" > "$EVID/git_status_$SNAP.exit" || evidence_fail "cannot write git_status_$SNAP.exit"
		/usr/bin/cat "$EVID/containment_$SNAP.txt"
		printf 'git status (%s): exit %s, %s line(s)\n' "$SNAP" "$gs" "$(grep -c '' "$EVID/git_status_$SNAP.txt")"
		/usr/bin/cat "$EVID/git_status_$SNAP.txt"
		[ "$gs" -eq 0 ] || evidence_fail "git status failed ($SNAP)"
		[ ! -s "$EVID/git_status_$SNAP.txt" ] || evidence_fail "repository is not clean ($SNAP)"
		[ "$(grep -c '^PRESENT ' "$EVID/containment_$SNAP.txt")" -eq 0 ] || evidence_fail "something exists outside the run root ($SNAP)"
		exit 0
		;;
	inventory)
		# Lists what the run left behind. Nothing is deleted or cleaned.
		[ ! -e "$EVID/leftover_inventory.txt" ] || die "inventory exists already"
		list_tree "$ROOT" "$EVID/leftover_inventory.txt" || evidence_fail "leftover inventory listing failed (see leftover_inventory.txt.errors)"
		{
			printf 'status=PRESERVED (listed only; nothing was deleted)\n'
			printf 'entries=%s\n' "$(grep -c '' "$EVID/leftover_inventory.txt")"
			printf 'target_case_folders=%s\n' "$(grep -c -E '^d .*/myrial-wrapper-test\.[A-Za-z0-9]+$' "$EVID/leftover_inventory.txt")"
		} > "$EVID/leftover_summary.txt" || evidence_fail "cannot write leftover_summary.txt"
		/usr/bin/cat "$EVID/leftover_summary.txt"
		[ "$(grep -c '' "$EVID/leftover_inventory.txt")" -ge 1 ] || evidence_fail "leftover inventory is empty"
		exit 0
		;;
	audit)
		[ -n "$AUDIT_GROUPS" ] || die "--audit needs the list of groups"
		audit
		exit $?
		;;
	manifest)
		[ ! -e "$EVID/manifest.sha256" ] || die "manifest exists already"
		(
			set -o pipefail
			cd "$EVID" || exit 1
			/usr/bin/find . -xdev -type f ! -name 'manifest.sha256' -print0 2> "$ROOT/manifest_find.errors" \
				| LC_ALL=C sort -z | xargs -0 -r /usr/bin/sha256sum
		) > "$EVID/manifest.sha256" || evidence_fail "manifest creation failed"
		[ ! -s "$ROOT/manifest_find.errors" ] || evidence_fail "find reported errors while building the manifest"
		files="$(
			set -o pipefail
			cd "$EVID" && /usr/bin/find . -xdev -type f ! -name 'manifest.sha256' -print | grep -c ''
		)" || evidence_fail "cannot count evidence files"
		entries="$(grep -c '' "$EVID/manifest.sha256")"
		[ "$entries" -ge 1 ] || evidence_fail "manifest is empty"
		[ "$entries" -eq "$files" ] || evidence_fail "manifest has $entries entries for $files files"
		(cd "$EVID" && /usr/bin/sha256sum --check --quiet manifest.sha256) || evidence_fail "manifest does not verify"
		printf 'manifest entries=%s (verified)\n' "$entries"
		exit 0
		;;
	group)
		[ -f "$TARGET" ] || die "target script not found"
		[ "$(/usr/bin/sha256sum < "$TARGET" | cut -d' ' -f1)" = "$R4_SHA256" ] || die "target script is not the accepted r4 file"
		[ -f "$REAL_WRAPPER" ] || die "real wrapper not found"
		[ "$(basename "$(readlink -f /bin/sh)")" = "dash" ] || die "/bin/sh is not dash (shell S1 would be mislabelled)"
		planned_ids "$GROUP" > /dev/null
		GROUP_WORK="$WORK/$GROUP"
		mk "$GROUP_WORK"
		planned_ids "$GROUP" > "$EVID/planned_$GROUP.txt" || evidence_fail "cannot write planned_$GROUP.txt"
		write_fakes
		ensure_s2
		echo "GROUP $GROUP START"
		case "$GROUP" in
			N) group_N ;;
			M) group_M ;;
			F) group_F ;;
			L) group_L ;;
			N6) group_N6 ;;
			G) group_G ;;
			R1) group_R1 ;;
			R2) group_R2 ;;
			R3) group_R3 ;;
		esac
		echo "GROUP $GROUP COMPLETE: every case matched its expectation"
		exit 0
		;;
esac
die "unhandled mode"
