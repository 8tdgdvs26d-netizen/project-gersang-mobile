#!/bin/sh
# VS-01 WP01-C — opens the Online TEST mode window (existing city market UI,
# trades confirmed by the LOCAL Nakama server) for hands-on testing on a Mac.
#
# - Starts the local Docker stack (nakama/docker-compose.yml) if needed.
# - Runs Godot with HOME pointed at a fresh temporary folder, so user:// is
#   isolated and the Development Save cannot be read or written. The Online
#   TEST mode never uses the local save anyway.
# - Local disposable test accounts only (127.0.0.1); no cloud, no fees.
#
# Usage: GODOT=/Applications/Godot.app/Contents/MacOS/Godot nakama/scripts/run_online_trade_ui.sh
set -eu
NAKAMA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$NAKAMA_DIR/.." && pwd)"
GODOT="${GODOT:-godot}"
DOCKER="${DOCKER:-docker}"

cd "$NAKAMA_DIR"
[ -d node_modules ] || npm ci
npm run build
"$DOCKER" compose up -d
i=0
until curl -sf http://127.0.0.1:17350/healthcheck >/dev/null; do
	i=$((i + 1)); [ "$i" -lt 90 ] || { echo "Nakama did not become healthy" >&2; exit 2; }
	sleep 1
done

ISOLATED_HOME="$(mktemp -d)"
echo "Isolated HOME (user:// root): $ISOLATED_HOME"
HOME="$ISOLATED_HOME" "$GODOT" --path "$REPO_DIR/godot" --import >/dev/null 2>&1 || true
HOME="$ISOLATED_HOME" "$GODOT" --path "$REPO_DIR/godot" res://scenes/online_trade_test_mode.tscn
