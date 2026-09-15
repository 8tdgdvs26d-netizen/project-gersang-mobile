# MYRIAL: UNWRITTEN Combat Prototype v0.31.0

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
{"ok":true,"version":"0.31.0","phase":"P2 Multi-city Warehouse Overview"}
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

## Current V30 capabilities (package.json version 0.30.0)

The package version advanced to `0.30.0` through further P1/P2 work beyond
`v0.5.2` above. Every item below is backed by an existing `/api` route in
`server.mjs` and/or a passing test in `test/battle.test.mjs` /
`test/hardening.test.mjs`:

- Server-authoritative 5-row by 60-column real-time battlefield: movement,
  formation deployment, target locking, and automatic basic attacks.
- Melee/ranged role pacing, agility-based movement and attack cadence, skill
  casting (heavy strike, thunder rune, ultimate rune, archer skill, iron
  wall, arrow rain), sigil-drawn special/ultimate skills, tactical pause,
  slow effects, and a timed ice wall obstacle (including out-of-range
  auto-approach casting).
- Elite encounters and elite boss telegraphed area attacks.
- Victory/defeat resolution, experience and level growth, and an idempotent
  post-battle loot settlement step.
- Per-character equipment backpacks separate from shared cargo, equipment
  transfer between a unit's backpack and the local city warehouse, and an
  idempotent equipment market (quote and sell).
- City market goods trading (`/api/commands/market/quote`, `buy`, `sell`).
- Cargo/storage transfer within a city, and a multi-city warehouse overview
  endpoint (remote city stock is read-only).
- Travel start, mid-journey reroute from the character's virtual position on
  the current road, and automatic resolution of an overdue journey.
- Idempotency safeguards: a lost response retry applies a purchase exactly
  once, a REJECTED command does not consume its idempotency key, and a
  RECONFIRM_REQUIRED command lets a corrected payload reuse the same key.

This summary only restates behavior already covered by existing code and
the current 43 (soon 44, see `CHANGELOG.md`) automated tests below — it does
not add, promise, or imply any new gameplay feature.

## v0.31.0 — Development Safety Foundation

This release adds development-process safety infrastructure only. It does
not change any gameplay logic, economy/market/city/travel/warehouse logic,
equipment/inventory/loot/progression logic, database schema, save format,
or Render configuration.

- Added `CLAUDE.md` with Git safety rules, a documentation reading order,
  and a two-step approval process (plan approval before coding, result
  approval before merge).
- Added `CHANGELOG.md` tracking the V30 baseline commit and this release.
- Added `.github/workflows/test.yml`: runs `npm test` on pull requests and
  pushes to `main` (Node.js 22, `permissions: contents: read`, no secrets,
  no deployment).
- Added `test/health.test.mjs`, an independent regression test asserting
  `/api/health` returns `ok:true`, `version:'0.31.0'`, and the unchanged
  `phase:'P2 Multi-city Warehouse Overview'`.
- Corrected this README's stale `v0.5.2` heading and health example to the
  current version, while keeping every historical section above unchanged.
- Bumped the visible version string to `0.31.0` in `package.json`,
  `public/index.html`, `public/app.js`, and the `server.mjs` health
  endpoint. The health endpoint's `phase` field is intentionally left
  unchanged.
