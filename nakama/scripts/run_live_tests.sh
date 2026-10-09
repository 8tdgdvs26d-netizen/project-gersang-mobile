#!/bin/sh
# VS-01 WP01 — build the server module, start the LOCAL Nakama + PostgreSQL
# stack, then run the live Node stress tests and the live Godot SDK probe.
# Local Docker only; no cloud resources. Data lives in this compose project's
# own volume (myrial-vs01-wp01_pgdata); nothing else is touched.
#
# Usage: GODOT=/Applications/Godot.app/Contents/MacOS/Godot nakama/scripts/run_live_tests.sh
set -eu
NAKAMA_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$NAKAMA_DIR/.." && pwd)"
GODOT="${GODOT:-godot}"
DOCKER="${DOCKER:-docker}"
export DOCKER

cd "$NAKAMA_DIR"
[ -d node_modules ] || npm ci
npm run build
wait_healthy() {
	i=0
	until curl -sf "$1/healthcheck" >/dev/null; do
		i=$((i + 1)); [ "$i" -lt 90 ] || { echo "Nakama at $1 did not become healthy" >&2; exit 2; }
		sleep 1
	done
}
# Two nodes on one database: the second exists only for the multi-node test.
"$DOCKER" compose --profile multinode up -d
wait_healthy http://127.0.0.1:17350
wait_healthy http://127.0.0.1:17360
# Restart so the freshly built module is loaded on both nodes.
"$DOCKER" compose --profile multinode restart nakama nakama2 >/dev/null
wait_healthy http://127.0.0.1:17350
wait_healthy http://127.0.0.1:17360
export MYRIAL_NAKAMA_URL_2=http://127.0.0.1:17360

echo "== Nakama live stress (Node, local server)"
node --test --test-concurrency=1 tests/live/*.test.mjs

echo "== Godot live probe (Nakama Godot SDK v3.4.0, isolated user://)"
ISOLATED_HOME="$(mktemp -d)"
HOME="$ISOLATED_HOME" "$GODOT" --headless --path "$REPO_DIR/godot" --import >/dev/null 2>&1 || true
HOME="$ISOLATED_HOME" "$GODOT" --headless --path "$REPO_DIR/godot" --script res://tests/live_vs01_wp01_nakama.gd -- 127.0.0.1 17350
