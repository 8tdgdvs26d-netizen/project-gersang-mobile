#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SOURCE_CHECKOUT=$(git -C "$SCRIPT_DIR/../.." rev-parse --show-toplevel)
RUNTIME_ROOT=${ACCEPTANCE_RUNTIME_ROOT:-"${SOURCE_CHECKOUT}-runtime"}
GENERATED_ROOT="$RUNTIME_ROOT/generated"
CURRENT_FILE="$RUNTIME_ROOT/CURRENT_RUNTIME"
GODOT_BIN=${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}
ACCEPTANCE_DIR_NAME=${ACCEPTANCE_USER_DIR_NAME:-MYRIAL Unwritten Acceptance}

fail() {
	printf 'ERROR: %s\n' "$1" >&2
	exit 1
}

source_sha() {
	git -C "$SOURCE_CHECKOUT" rev-parse HEAD
}

require_clean_source() {
	[ -z "$(git -C "$SOURCE_CHECKOUT" status --short)" ] || fail "source checkout is not clean"
}

prepare_runtime() {
	require_clean_source
	[ -x "$GODOT_BIN" ] || fail "Godot executable not found: $GODOT_BIN"
	sha=$(source_sha)
	timestamp=$(date '+%Y%m%d-%H%M%S')
	runtime="$GENERATED_ROOT/${sha}-${timestamp}"
	mkdir -p "$runtime"
	rsync -a --exclude '.git/' --exclude '.godot/' "$SOURCE_CHECKOUT/" "$runtime/"
	project="$runtime/godot/project.godot"
	[ -f "$project" ] || fail "generated project.godot is missing"
	if grep -q '^config/use_custom_user_dir=' "$project" || grep -q '^config/custom_user_dir_name=' "$project"; then
		fail "source project already defines custom user data settings"
	fi
	awk -v custom_name="$ACCEPTANCE_DIR_NAME" '
		{ print }
		$0 == "config/name=\"Myrial: Unwritten\"" {
			print "config/use_custom_user_dir=true"
			print "config/custom_user_dir_name=\"" custom_name "\""
		}
	' "$project" > "$project.tmp"
	mv "$project.tmp" "$project"
	printf '%s\n' "$sha" > "$runtime/SOURCE_SHA"
	printf '%s\n' "$SOURCE_CHECKOUT" > "$runtime/SOURCE_CHECKOUT"
	printf '%s\n' "$runtime" > "$CURRENT_FILE"
	printf 'Prepared Acceptance runtime\nSource SHA: %s\nRuntime: %s\n' "$sha" "$runtime"
}

current_runtime() {
	[ -f "$CURRENT_FILE" ] || fail "no generated runtime; run: $0 prepare"
	runtime=$(sed -n '1p' "$CURRENT_FILE")
	case "$runtime" in
		"$GENERATED_ROOT"/*) ;;
		*) fail "CURRENT_RUNTIME points outside the generated runtime root" ;;
	esac
	[ -f "$runtime/SOURCE_SHA" ] || fail "runtime SOURCE_SHA is missing"
	[ -f "$runtime/godot/project.godot" ] || fail "runtime project.godot is missing"
	printf '%s\n' "$runtime"
}

acceptance_user_data() {
	printf '%s/Library/Application Support/Godot/app_userdata/%s\n' "$HOME" "$ACCEPTANCE_DIR_NAME"
}

show_runtime() {
	runtime=$(current_runtime)
	printf 'Source checkout: %s\n' "$SOURCE_CHECKOUT"
	printf 'Source SHA: %s\n' "$(sed -n '1p' "$runtime/SOURCE_SHA")"
	printf 'Runtime: %s\n' "$runtime"
	printf 'Acceptance user data: %s\n' "$(acceptance_user_data)"
	grep -F 'config/use_custom_user_dir=true' "$runtime/godot/project.godot"
	grep -F "config/custom_user_dir_name=\"$ACCEPTANCE_DIR_NAME\"" "$runtime/godot/project.godot"
}

run_game() {
	require_clean_source
	runtime=$(current_runtime)
	sha=$(sed -n '1p' "$runtime/SOURCE_SHA")
	[ "$sha" = "$(source_sha)" ] || fail "runtime SHA does not match source checkout; prepare a new runtime"
	show_runtime
	if [ ! -f "$runtime/godot/.godot/global_script_class_cache.cfg" ]; then
		printf 'Building fresh Godot import cache for Acceptance runtime...\n'
		"$GODOT_BIN" --editor --headless --import --path "$runtime/godot" --log-file "$RUNTIME_ROOT/acceptance-import.log"
	fi
	exec "$GODOT_BIN" --path "$runtime/godot" --windowed --log-file "$RUNTIME_ROOT/acceptance-game.log"
}

case "${1:-}" in
	prepare) prepare_runtime ;;
	show) show_runtime ;;
	run) run_game ;;
	*) printf 'Usage: %s {prepare|show|run}\n' "$0" >&2; exit 2 ;;
esac
