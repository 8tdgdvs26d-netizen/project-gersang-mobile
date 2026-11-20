#!/bin/sh
# VS-01 WP01-H E2 — process-kill recovery tests (offline, scripted server).
#
# For each pair, phase A runs tests/wp01h_process_kill.gd and kills ITSELF
# (OS.kill on its own pid) at a named point of a Pending Store write; phase B
# then runs in a FRESH process against the same user:// and must recover.
#
# Isolation: a new disposable root per pair; HOME / XDG_* / TMPDIR all point
# inside it, and the run stops unless Godot reports its user data directory
# inside that root and no gameplay save exists there. Nothing outside the root
# is read or written; the root is left in place for inspection.
#
# Pairs: see tests/wp01h_process_kill.gd (8 pairs: E2 Targeted Revision + quarantine mark journal / live mark
# write / ticket hold; Final Safety Fix + unmatched journal mark).
#
# Usage: GODOT=/path/to/Godot_v4.7.2 godot/tests/run_wp01h_kill_tests.sh
# Pass: phase A ends by signal (exit > 128) after printing KILL-POINT and
# without any RPC-SENT for the killed step; phase B exits 0 with its own
# "passed" line and no FAILED / SCRIPT ERROR / Parse Error.

GODOT="${GODOT:-godot}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="res://tests/wp01h_process_kill.gd"
# Each phase is bounded: a hang counts as a failure (exit 124), never a pass.
LIMIT="timeout 180"
command -v timeout >/dev/null 2>&1 || LIMIT=""

BASE_TMP="${TMPDIR:-/tmp}"
failed=0
PAIRS="trade_after_rename:trade_recover trade_second_tmp:trade_second_check trade_clear_tmp:trade_clear_check combat_after_rename:combat_recover trade_mark_journal:trade_mark_check trade_mark_live_tmp:trade_mark_check combat_hold_journal:combat_hold_check trade_mark_journal:trade_orphan_check"
total=0
for pair in $PAIRS; do
	total=$((total + 1))
	pair="$(printf '%s' "$pair" | tr ':' ' ')"
	set -- $pair
	a="$1"; b="$2"
	root="$(mktemp -d "$BASE_TMP/wp01h-kill-XXXXXXXX")"
	mkdir -p "$root/home" "$root/data" "$root/config" "$root/cache" "$root/tmp"
	export HOME="$root/home" XDG_DATA_HOME="$root/data" XDG_CONFIG_HOME="$root/config" XDG_CACHE_HOME="$root/cache" TMPDIR="$root/tmp"
	out_a="$($LIMIT "$GODOT" --headless --path "$PROJECT" --script "$SCRIPT" -- --phase "$a" 2>&1)"
	st_a=$?
	ud="$(printf '%s\n' "$out_a" | sed -n 's/^PHASE .* user_data=//p' | head -1)"
	case "$ud" in
		"$root"/*) ;;
		*) echo "ISOLATION STOP [$a]: user data dir '$ud' is not under $root"; exit 3 ;;
	esac
	reason=""
	if [ "$st_a" -le 128 ]; then reason="phase A exit $st_a (not killed)"; fi
	if ! printf '%s\n' "$out_a" | grep -q '^KILL-POINT'; then reason="$reason; no KILL-POINT"; fi
	if printf '%s\n' "$out_a" | grep -qE 'SCRIPT ERROR|Parse Error'; then reason="$reason; script error in A"; fi
	case "$a" in
		trade_after_rename|combat_after_rename)
			if printf '%s\n' "$out_a" | grep -q '^RPC-SENT'; then reason="$reason; an RPC was sent before the kill"; fi ;;
	esac
	out_b="$($LIMIT "$GODOT" --headless --path "$PROJECT" --script "$SCRIPT" -- --phase "$b" 2>&1)"
	st_b=$?
	if [ "$st_b" -ne 0 ]; then reason="$reason; phase B exit $st_b"; fi
	if ! printf '%s\n' "$out_b" | grep -q "phase $b passed"; then reason="$reason; phase B no pass line"; fi
	if printf '%s\n' "$out_b" | grep -qE 'SCRIPT ERROR|Parse Error|^(ERROR: )?FAILED:'; then reason="$reason; phase B failure"; fi
	if [ -n "$reason" ]; then
		failed=$((failed + 1))
		echo "FAIL $a -> $b [${reason#; }] root=$root"
		printf '%s\n' "$out_a" | grep -E 'KILL-POINT|RPC-SENT|FAILED|ERROR' | head -5
		printf '%s\n' "$out_b" | grep -E 'FAILED|ERROR|passed' | head -8
	else
		echo "PASS $a (killed, exit $st_a) -> $b | $(printf '%s\n' "$out_b" | grep 'passed') | root=$root"
	fi
done
if [ "$failed" -ne 0 ]; then
	echo "$failed process-kill pair(s) failed"
	exit 1
fi
echo "All $total process-kill pairs passed"
exit 0
