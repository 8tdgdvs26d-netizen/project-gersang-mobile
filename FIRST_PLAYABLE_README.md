# MYRIAL: UNWRITTEN Combat Prototype v0.32.0

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
{"ok":true,"version":"0.32.0","phase":"P3 World Map & City Hub Vertical Slice"}
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
the current 44 automated tests below — it does not add, promise, or imply
any new gameplay feature.

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

## v0.32.0 — World Map & City Hub Vertical Slice

This release adds a Hong Kong four-region World Map and a City Hub screen.
It reuses the existing `travel`/`reroute`/`resolve-arrival` backend and
client functions unchanged, and reuses the existing market/storage render
logic unchanged — only their navigation entry point moved. No database
schema or save-format change, and only two additive read-only pieces of
server surface: a new `GET /api/roads` endpoint and a `segments` field
added to `GET /api/character/char-demo/snapshot`'s `activeTravel`.

- World Map (`public/worldmap.js`) replaces the previous "旅行" tab. It
  shows the four Hong Kong-inspired regions (港島 / 九龍 / 新界西 / 新界東)
  as an SVG, with the existing 3 demo cities placed as temporary metadata:
  `harbour-city` → 港島, `hill-market` → 新界東, `starter-village` → 新界西.
  九龍 (Kowloon) currently has no city and is shown as not yet open. The
  map supports touch drag/pan (native scroll, no zoom in this slice).
- Tapping a city on the map calls the existing `travel()` function when
  the character is `IN_CITY`, or the existing `reroute()` function when
  already `TRAVELING` — no second travel implementation was written.
- The hero marker's position while `TRAVELING` is computed by a pure,
  independently-tested function (`computeTravelPosition`) from the
  segment breakdown, `startedAt`/`estimatedArrivalAt`, `GET /api/roads`,
  and city coordinates — fully reconstructable after a reload with no
  client-held state, including the reroute "virtual position" segment.
- City Hub (new screen, entered only once `state==='IN_CITY'` and the
  hub's city id matches the character's current city) replaces the old
  top-level 市場/倉庫 tabs with 7 entries: 市場 and 貨倉 (reused, unchanged
  business logic) are open; 銀行, 傭兵店, 裝備店, 工廠 show "尚未開放"
  (not yet implemented — not claimed as done); 離開城市 returns to the
  World Map without any server call.
- 貨艙 (personal cargo), 戰鬥, and 紀錄 remain top-level tabs, unchanged.
- Bumped the visible version string to `0.32.0` and the health endpoint's
  `phase` to `P3 World Map & City Hub Vertical Slice`.

Known limitation: only 3 demo cities exist; the World Map, City Hub, and
city metadata are designed to be data-driven so more cities (up to the
long-term ~100-city goal) can be added later without rewriting rendering
logic — this slice does not add any new city.
