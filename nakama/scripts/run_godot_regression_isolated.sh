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
HOME="$ISOLATED_HOME" GODOT="${GODOT:-godot}" sh "$REPO_DIR/godot/tests/run_tests.sh" "$@"
