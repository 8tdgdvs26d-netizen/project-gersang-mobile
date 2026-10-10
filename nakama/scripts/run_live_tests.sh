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

# Godot exits 0 even when a --script fails to parse, so each Godot run must
# also print its own "passed" line (WP01-B finding).
run_godot_strict() {
	marker="$1"; shift
	out="$(mktemp)"
	HOME="$ISOLATED_HOME" "$GODOT" --headless --path "$REPO_DIR/godot" "$@" 2>&1 | tee "$out"
	if ! grep -q "$marker" "$out" || grep -qE 'Parse Error|SCRIPT ERROR' "$out"; then
		echo "STRICT CHECK FAILED: no \"$marker\" line, or a parse / script error" >&2
		exit 1
	fi
}

ISOLATED_HOME="$(mktemp -d)"
echo "Isolated HOME (user:// root) for Godot: $ISOLATED_HOME"
HOME="$ISOLATED_HOME" "$GODOT" --headless --path "$REPO_DIR/godot" --import >/dev/null 2>&1 || true

echo "== Godot live probe, WP01 (Nakama Godot SDK v3.4.0, isolated user://)"
run_godot_strict "VS-01 WP01 live Nakama probe passed" --script res://tests/live_vs01_wp01_nakama.gd -- 127.0.0.1 17350

echo "== Godot live harness, WP01-B online trade (lossy proxy + restart, isolated user://)"
PROXY_PORT=17370
node tests/live/tools/lossy_proxy.mjs "$PROXY_PORT" 17350 > "$(mktemp)" 2>&1 &
PROXY_PID=$!
trap 'kill "$PROXY_PID" 2>/dev/null || true' EXIT
i=0
until curl -sf "http://127.0.0.1:$PROXY_PORT/__lossy_proxy/stats" >/dev/null; do
	i=$((i + 1)); [ "$i" -lt 30 ] || { echo "lossy proxy did not start" >&2; exit 2; }
	sleep 1
done
DOCKER_BIN="$(command -v "$DOCKER")"
run_godot_strict "VS-01 WP01-B live online trade harness passed" --script res://tests/live_vs01_wp01b_online_trade.gd -- \
	127.0.0.1 17350 "$PROXY_PORT" "$NAKAMA_DIR" "$DOCKER_BIN" "$HOME"
echo "Lossy proxy counters: $(curl -sf "http://127.0.0.1:$PROXY_PORT/__lossy_proxy/stats")"
