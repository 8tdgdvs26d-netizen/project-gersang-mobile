# MYRIAL: UNWRITTEN Combat Prototype v0.5.2

This repository now includes the deployable P0 First Playable.

## Runtime

- Node.js 22+
- Built-in `node:sqlite`
- Browser UI served from `/public`
- HTTP API and SQLite persistence in `server.mjs`

## Start

```bash
PORT=10000 DB_PATH=./first-playable.sqlite node server.mjs
```

Open:

```text
http://localhost:10000
```

## Health

```text
GET /api/health
```

Expected:

```json
{"ok":true,"version":"0.5.2","phase":"P1 Combat Navigation"}
```

## Render

Use this repository as a Docker Web Service. The root `Dockerfile` starts `server.mjs` and binds the server to `0.0.0.0:$PORT`.

For persistent game saves, mount a persistent disk at `/data` and set:

```text
DB_PATH=/data/first-playable.sqlite
```

Do not run multiple replicas against the same SQLite file. This is a single-process prototype build.

## P0 playable loop

Login / Session → City Market → Buy → Cargo / Storage → Travel → Arrival → Sell → Persistence / Reconnect.

## v0.4.1 hardening

- Gameplay mutation and successful idempotency record now commit atomically.
- Rejected and reconfirm-required commands no longer permanently consume a key.
- Travel rerouting starts from the character's virtual position on the current road.
- The deployed browser UI exposes rerouting while travelling.
- Regression tests cover duplicate delivery, reconfirm retry, rejected retry, and rerouting.

## v0.5.0 combat prototype

- Server-authoritative 5-row by 60-column battlefield.
- Three directly controllable player units and three autonomous enemies.
- Tap-to-select, tap-to-move, and tap-enemy-to-target controls.
- Melee range 2, ranged range 5, role-specific attack intervals, and automatic basic attacks.
- Units may pass through one another but cannot finish a movement command on an occupied cell.
- Server-owned HP, death removal, victory, defeat, and retreat states.
- Browser battle view polls the server while combat is active.
- Regression tests cover grid dimensions, authority, bounds, command idempotency, movement, targeting, and automatic damage.

## v0.5.1 combat UX fix

- Preserve the horizontal battlefield position across live server refreshes.
- Add jump controls for the player side, battlefield centre, and enemy side.
- Add visible hit flashes and a recent-damage combat log.
- Automatically acquire the next nearest enemy after a locked target dies.

## v0.5.2 combat navigation

- Replace quick-jump buttons with a large draggable battlefield scrollbar.
- Keep the range control and direct touch-scrolling synchronized in both directions.
