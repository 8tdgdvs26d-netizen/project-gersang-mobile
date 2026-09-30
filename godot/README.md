# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Reproducible iOS development export

The repository contains the non-sensitive inputs required to recreate an iOS
development build from a clean clone:

- `export_presets.cfg`: the Godot iOS preset, Bundle ID
  `com.charlie.myrial.unwritten`, Development Team `26YN4G22B2`, deployment
  target and other non-secret export options
- `ios_assets/`: the iPhone/iPad/App Store icon source files referenced by the
  preset
- `project.godot`: Godot 4.7 project settings, portrait orientation,
  Compatibility renderer and ETC2/ASTC texture import support

Signing material remains machine-local. Never commit Apple ID credentials,
passwords, certificates/private keys, provisioning profiles or
`.godot/export_credentials.cfg`. On a new Mac:

1. Install Godot 4.7.2 and its matching export templates, plus Xcode.
2. Clone the repository and open `godot/project.godot` once so Godot imports
   resources.
3. Sign in to the Apple account in Xcode and ensure the local Keychain has a
   usable Apple Development certificate for team `26YN4G22B2`.
4. Connect, pair and unlock the development iPhone. Keep Xcode automatic
   signing enabled; it creates or downloads the matching development profile.
5. In Godot, export the `iOS` preset, or run:
   `/path/to/Godot --headless --path godot --export-debug iOS /tmp/Myrial-Unwritten.ipa`
6. Confirm Xcode reports `ARCHIVE SUCCEEDED` and `EXPORT SUCCEEDED` before
   installing the IPA/app on a device.

The exported Xcode project/archive/IPA and every signing credential are build
or machine artifacts, not source files.

## UI font (Traditional Chinese)

All UI text uses the bundled `fonts/NotoSansTC-Regular.otf` (Noto Sans TC, SIL Open
Font License 1.1, see `fonts/OFL.txt`) through the project default font
`gui/theme/custom_font = res://fonts/ui_font.tres`. That FontVariation only tightens line
spacing by 1px so the existing portrait layout is unchanged. System font fallback is off,
so iPhone never depends on device fonts, and desktop runs show the same glyphs. Keep the
export filter on all resources (or include `fonts/`) so the font is packaged.
`tests/verify_tc_font.gd` checks that every player-visible character is in the font.

## Current work package

Combat C03: Party & Mercenary Combat. The battle party is the Hero + two fixed Prototype
Mercenaries; runtime only, save version stays 8.

- `CombatBattle.create()` / `from_encounter()` always build Hero (1, 2) + Merc A (1, 1) + Merc B
  (1, 3) inside the preparation area (`CombatConfig.MERC_A` / `MERC_B`, `CombatUnit.role`).
  Prototype test data, not balance: Merc A HP 200, ATK 15, range 1, 1.0 s, 4 cells/s; Merc B
  HP 150, ATK 12, range 3, 1.2 s, 4 cells/s. Not recruitable, no roster, not saved.
  `PartyFixture.HERO_ONLY` is a test fixture only (the C01 single-friendly rule tests); the game
  never uses it and the player cannot choose it
- one friendly unit selected at a time (tap it; the Hero starts selected). Move / target commands
  go to the selected unit only; every other unit keeps its own order and target. A dead unit
  cannot be selected or commanded; if the selected unit dies nothing stays selected
- enemies attack the nearest alive friendly unit (ties: Hero, Merc A, Merc B) and retarget when
  it dies. DEFEAT only on a Full Party Wipe — the Hero's death alone does not end the battle;
  VICTORY is still every enemy dead, whoever survives. C02 `BattleResult` and lifecycle unchanged
- occupancy fix: when every cell near its target is taken, a unit searches the whole grid for a
  free cell instead of staying on a claimed one (seen with 3 friendly units vs 20 enemies)
- `CombatView`: names 主角 / 傭兵A / 傭兵B, one colour each, HP of every unit (「陣亡」 when dead),
  the camera follows the selected unit (else the first alive one)
- tests: `tests/verify_c03_party_combat.gd`

Previous: Combat C02: Combat ↔ World lifecycle (stacked on C01). A finished battle's result is consumed
once by the world; runtime only, save version stays 8.

- a battle that reaches VICTORY / DEFEAT produces one `BattleResult` (encounter id, outcome,
  participating group ids, single-commit claim). The result screen's 「返回世界」 only asks
  `main.commit_battle_result()` to consume it; the button never decides the outcome
- `commit_battle_result()` is the only way a Combat encounter ends. It refuses (and changes
  nothing) for a repeat, a result that is not the running battle's own, or an encounter that is
  no longer LOCKED / pending. Order: claim the commit → 5 s recovery protection on → groups
  (`EncounterHandoff.resolve_encounter`) → encounter ended, player unlocked where the encounter
  caught them (`EncounterSession.end_resolved_encounter`) → battle closed, world input back →
  one save. A failed save never undoes the committed result
- VICTORY: the participating World Enemy Groups leave the current world instance (never reset
  home); other groups are untouched; city visits and other world transitions never bring them
  back. **Approved Known Limitation:** removal is session only — a relaunch rebuilds the fixed
  Prototype groups from `main.tscn` (no group persistence, no respawn system, save v8)
- DEFEAT: the participating groups are released and reset home; the player stays at the
  encounter position (no city, hospital, revive or penalty)
- no reward, EXP, loot, penalty or retreat. The old bare-LOCKED 「返回世界（原型）」 /
  `prototype_end_encounter()` is off in the game (`prototype_end_enabled`); only the E01–E03
  tests (Combat off) still use it
- tests: `tests/verify_c02_world_lifecycle.gd`

Previous: Combat C01: minimum playable battle (Encounter LOCKED → battlefield → 3 s preparation →
real-time combat → Victory / Defeat). Runtime only; save version stays 8.

- a LOCKED encounter opens the battle at once (`main.gd`, `CombatView`); the world stays as
  LOCKED left it underneath (player locked, groups held, nothing new triggers). The battle keeps
  the encounter id and groups; 1 / 2 / 3 World Enemy Groups → 10 / 15 / 20 enemies of one
  Prototype archetype, placed from column 10 on
- `CombatBattle` (rules, no rendering / input / clock) + `CombatUnit` + `CombatConfig`
  (Prototype data): 5 rows × 60 columns (Prototype decision), discrete 8-direction cell steps;
  units may pass through each other but never stop on a cell another unit stands on or has
  claimed; no pathfinding. Time only moves through `advance(ms)` (physics delta in the game,
  exact ms in tests)
- PREPARATION 3000 ms (「備戰 3 / 2 / 1」): enemies do not move, target, attack or take / deal
  damage; the Hero may move only inside the first 3 columns (5 × 3 = 15 cells), no targeting.
  Exactly at 3000 ms FIGHTING starts (once); a step in progress simply continues
- FIGHTING: tap the Hero = select (starts selected), tap a cell = move, tap an enemy = target:
  the Hero approaches, stops in range and Basic Attacks every attack interval (100% hit); a dead
  target is dropped and the Hero waits (no automatic retarget). Enemies pursue the nearest alive
  friendly unit and Basic Attack in range. Every HP change goes through
  `CombatBattle.resolve_damage()`; HP 0 = dead (no movement, attack, AI or targeting)
- VICTORY when every enemy is dead; DEFEAT when every friendly unit is dead (C01: the Hero).
  Both are final (nothing moves, attacks or takes damage). C01's temporary result exit is
  replaced by the C02 lifecycle above
- Prototype stats (`CombatConfig`, not balance): Hero HP 300, ATK 20, range 1, interval
  1.0 s, 4 cells/s; enemy HP 40, ATK 4, range 1, interval 1.5 s, 2 cells/s
- portrait app kept: the grid scrolls horizontally with the Hero (final Combat orientation not
  decided here)
- `main.combat_enabled` is a test seam only (default true, never saved, no player setting): the
  E01–E03 tests switch it off to keep observing the bare LOCKED phase
- tests: `tests/verify_c01_combat.gd`

Previous: Encounter E03: Aggressive / Passive threat dispositions and manual challenge foundation.

- every World Enemy Group has a fixed disposition in `WorldLayout.PROTOTYPE_GROUPS`
  (`WorldLayout.Disposition`, config only, never saved): `prototype_monster_01` and
  `prototype_monster_02` are AGGRESSIVE, `prototype_monster_03` is PASSIVE
- AGGRESSIVE groups keep the E02 behaviour: aggro (240 px), chase, catch, start an encounter,
  auto-join during JOINING; safe buffers and recovery protection still stop them
- PASSIVE groups patrol and pause as before but never aggro or chase, touching them starts no
  encounter and they never auto-join (not even an AGGRESSIVE group's encounter)
- 「挑戰」 shows only in WORLD with no encounter (not JOINING / LOCKED), outside every city safe
  buffer, with an active PASSIVE group within 200 px (`EncounterHandoff.CHALLENGE_RANGE`).
  Recovery protection does not hide it. Pressing it starts the same encounter pipeline as a
  catch (`EncounterHandoff.challenge()` → one `encounter_id`, the PASSIVE group primary,
  `triggered_at_ms` = the press, JOINING 5.0 s, player locked); AGGRESSIVE groups in range may
  join (e.g. `[03, 01, 02]`, planned size 20) and never reset the window
- a challenge during recovery protection ends the protection at once (countdown hidden, no
  aggro suppression left)
- no Combat, retreat, reward, cooldown, confirmation, target selection or save change
  (save version stays 8)
- tests: `tests/verify_e03_disposition_challenge.gd`. `tests/verify_e02_multi_group.gd` makes
  group 3 AGGRESSIVE for its three-group join cases

Previous: Encounter E02: multi-group join foundation (with the E02 fix pass).

E02 fix pass (after Mac acceptance):

- 5 s recovery protection after the prototype end (`EncounterSession.PROTECTION_MS`,
  TimeSource, runtime only): the player moves freely, all groups keep patrolling but never
  aggro (a chasing one turns back) and no contact becomes an encounter
  (`EncounterHandoff.set_protected`, `WorldMonster.set_aggro_suppressed`). 「遭遇保護 X.X...」
  counts it down; it ends by itself and is never saved
- aggro radius 200 → 240 px
- new three-group geometry: homes (800, 700), (1100, 700), (950, 930) (group 1 moved from
  (760, 650) so its whole 240 px aggro circle stays inside the zone); the zone grew 30 px south
  (x 560–1240, y 450–1060). Each group roams four points ~100 px around its home; the three
  activity regions overlap near the middle without sharing a route. West of group 1 (e.g.
  (640, 700)) only group 1 can reach; north between groups 1 and 2 (e.g. (900, 600)) groups 1
  and 2 but never 3; the middle (e.g. (950, 780)) all three. Spawn and city exits stay out of
  every group's reach
- controlled irregular patrol: each group walks its own fixed itinerary that revisits its
  points in a varied order (not one rigid loop) and pauses 0.5–2.0 s at some stops
  (`patrol_pauses`, physics time, deterministic). Aggro works while paused; a chase ends the
  pause; a reset / return restarts the itinerary with no pause left

- three prototype World Enemy Groups (one monster each, same scene / AI / speeds / aggro):
  `prototype_monster_01` (the WT01–WT05 monster), `prototype_monster_02`,
  `prototype_monster_03`; homes and itineraries as in the fix pass above
  (`WorldLayout.PROTOTYPE_GROUPS`, `WorldMonster.group_index`). No fourth group
- low_threat_zone_01 grew east and south to hold them: x 560–1240, y 450–1060 (was x 560–1000,
  y 450–850; the corner nearest City A is unchanged). Every home and loop is outside all
  safe buffers, clear of the obstacles, and out of aggro range of the spawn and both city
  return points. Deliberate spots: west of group 1 → one group; north between groups 1 and 2
  → two; the middle of the three → three
- the first group to physically catch the player starts the encounter (WT04, unchanged) and
  is the context's `monster_id`. While JOINING, every other active group whose aggro radius
  holds the player (in WORLD, outside safety) joins once, in the order it qualifies, up to 3
  (`EncounterHandoff.join_groups_in_range()`, `MAX_GROUPS`); no contact needed. A join never
  creates a trigger or a new `encounter_id` and never resets `triggered_at_ms` or the 5 s
  window. No group joins after LOCKED. All groups are hostile for now (no Aggressive /
  Passive yet)
- `EncounterContext.group_monster_ids` lists every group in join order (catcher first);
  `get_group_count()` / `get_planned_combat_enemy_count()`: 1 → 10, 2 → 15, 3 → 20 (planning data
  only, no Combat enemies)
- joined groups are held like the catcher; groups not taking part keep their normal world
  behaviour. The overlay adds 「敵軍加入 ×2」 / 「敵軍加入 ×3」 under the unchanged countdown, and
  keeps it at 「遭遇鎖定」
- the prototype end, leaving WORLD and the WT04 cancel release and reset every participating
  group (home, IDLE, patrol from the start). Nothing is saved (save version 8)
- tests: `tests/verify_e02_multi_group.gd`. The WT01–WT05 and E01 tests remove groups 2 and 3
  before the scene starts: the one-group world they were written for

Previous: Encounter E01: join window & lock foundation.

- `EncounterSession` (new node in the main scene) follows the WT04 `EncounterHandoff`: it does
  no contact detection and keeps the handoff's pending `EncounterContext` as the one active
  encounter. Phases: NONE → JOINING → LOCKED
- JOINING starts once, at the first catch (`triggered_at_ms`), and lasts exactly 5000 ms on the
  TimeSource. The player cannot move (keyboard or joystick: `Player.movement_locked`) and
  cannot escape; the WT04 hold keeps the monster frozen. The overlay counts down
  「遭遇準備 5.0...」 … 「遭遇準備 0.1...」 (rounded up to tenths, never below 0); a second trigger
  never starts another encounter or resets the timer
- at 5000 ms: LOCKED, 「遭遇鎖定」. No combat, no rewards; `get_context()` still carries the full
  context for the future Combat System
- TEMPORARY, pre-Combat: while LOCKED a 「返回世界（原型）」 button (`prototype_end_encounter()`)
  ends the encounter through the WT04 recovery (monster home, IDLE, patrol restarted) and
  unlocks the player; refused during JOINING. No result of any kind
- leaving WORLD (city, travel) during JOINING or LOCKED cancels it the same way
  (`cancel_for_world_exit()`); nothing is saved (save version 8), a reload starts with no
  encounter and no lock
- only the one existing monster; no multi-group join, combat, retreat or aggression types
- tests: `tests/verify_e01_join_window.gd`. The WT01, WT02 and WT04 tests run with the join
  window off (`EncounterSession.enabled = false`): they were written for a caught player who
  keeps moving; E01 covers the lock

Previous: World Threat WT05: minimal patrol foundation.

- the one monster no longer stands still: while IDLE it walks a fixed loop (「巡邏」)
  home (760, 650) → (860, 610) → (860, 720) → (700, 720) → home, at 60 px/s (chase stays
  160 px/s, player 220 px/s). One loop is about 470 px, just under 8 s
- the loop is layout data (`WorldLayout.PROTOTYPE_MONSTER_PATROL`): every point and straight
  leg is 130+ px inside low_threat_zone_01, clear of both obstacles (no pathfinding), and
  far from every city safe buffer; the new-game spawn and City A's return point stay out of
  aggro range of the whole loop
- no new state: IDLE now means patrolling (smallest change). Aggro works from anywhere on
  the loop; CHASE / RETURNING / safe buffers / leash are unchanged. Reaching home after a
  chase, entering a city, travelling, the WT04 cancel and a reload all restart the loop from
  its first point at home, so the patrol is deterministic
- WT04: a pending encounter holds the monster, patrol included (frozen position and target)
- nothing about patrol is saved (save version 8 unchanged)
- tests: `tests/verify_wt05_patrol.gd`. The WT01–WT04 tests run with the patrol loop off
  (`patrol_points = []`), the stationary idle monster they were written for; WT05 checks
  the same rules with patrol on

Previous: World Threat WT04: encounter trigger + context foundation.

- `EncounterHandoff` (new node in the main scene) turns the monster's contact into exactly one
  Encounter Trigger: signal `encounter_triggered(context)`. Valid only when the monster
  reports contact with its own id, the threat is active, the player is in WORLD, outside
  every city safe buffer, and really overlaps the monster
- `EncounterContext` (new, never saved): `encounter_id` ("encounter_1", "encounter_2" … in
  trigger order, per session), `monster_id`, `trigger_world_position` (the monster),
  `player_world_position`, `threat_zone_id` (from `WorldThreatZones` at the player; "" outside
  every zone) and `triggered_at_ms` (TimeSource)
- pending latch: after a trigger the encounter stays pending and every further contact is
  ignored. Only `consume_pending_encounter()` (the future Encounter System's hand-back)
  clears it as a hand-back. After a consume, a new trigger needs a new contact (separate,
  then touch again)
- recovery (review fix): leaving WORLD (entering a city, or starting travel) calls
  `cancel_pending_encounter()`: the pending encounter is dropped (no signal), the monster is
  released and put back at home, IDLE. While the player stays in WORLD (safe buffers
  included) nothing clears it: no timeout, no auto-consume
- while pending the monster is held: its AI stands still in its current state and shows
  「遭遇觸發」. The monster only knows this neutral hold (`set_hold`); all encounter logic lives
  in the handoff. The consume releases it; it is never despawned, defeated or reset
- no encounter screen, combat, rewards or mode change: the player keeps moving in WORLD.
  Until an Encounter System exists nothing consumes the trigger in normal play: the monster
  stays held until the player enters a city (or reloads); back in WORLD it can catch the
  player again (a new `encounter_id`)
- save version 8 unchanged; a reload starts with nothing pending
- tests: `tests/verify_wt04_encounter_trigger.gd`. WT02's test hands each trigger straight
  back so its chase checks run with nothing pending

Previous: World Threat WT03: city safe buffer + low-level threat zone foundation.

- `WorldThreatZones` (new, layout data only, never saved): answers "is this position in a
  city safe buffer?" (`safe_buffer_city_at`) and "in which threat zone?" (`threat_zone_at`).
  Kept out of trading, warehouse, market, transport, save and City Hub code
- city safe buffer: a 420 px circle around every active city (A, B; prototype value). It
  covers the 240 px entry trigger and the return point (340 px out) with 80 px to spare, so
  leaving a city starts safe. The new-game spawn is inside City A's
- `low_threat_zone_01`: one fixed rectangle x 560–1000, y 450–850 south-east of City A (spatial
  intent for the future outer Level 1–4 areas; no enemy levels). It holds the monster's home
  (760, 650) and its whole 200 px aggro circle, and stays 18 px clear of City A's buffer
- the monster treats safe buffers as sanctuary: it never aggroes a player inside one,
  reports no contact there, and a chase turns to RETURNING as soon as the player (or the
  monster itself) is inside one, before the 450 px leash. It then returns home as in WT02
  and can aggro again once the player leaves safety. The home must lie outside every buffer
  (checked at start). The zone itself is not a wall
- prototype markings under the cities and actors: faint green circles 「安全區」 and a faint
  red rectangle 「低級威脅區」 (`ThreatZoneOverlay`), drawn straight from the layout data
- no combat, encounter, levels, patrol, extra monsters or cities; save version 8 unchanged
- tests: `tests/verify_wt03_safe_buffer_threat_zone.gd`. WT01 / WT02 tests: a detached test
  player now stands at the monster (not at (0, 0), which is inside City A's buffer), and the
  bounds test uses the far corner instead of City A's

Previous: World Threat WT02: aggro, chase & disengage foundation.

- the same single monster now runs IDLE → CHASE → RETURNING → IDLE, shown as
  「待機」／「追擊」／「返回」 under its name. `state_changed(monster_id, state)` fires once per change
- home (760, 650): a stand-in low-level threat spot south-east of City A, between the two
  obstacles and never straight behind one, 372 px from the new-game spawn. Moved from WT01's
  (720, 320) in the WT02 review so that leaving a city never starts a chase (no formal zones)
- aggro: the player comes within 200 px of the idle monster (prototype tuning; was 250).
  Leash: the chase ends once the player is more than 450 px from home; the gap between the
  two radii prevents flicker. RETURNING ignores the player until it is home, then IDLE may
  aggro again
- chase / return speed 160 px/s, slower than the player's 220 px/s, so walking away always
  escapes. Straight line toward the target; each step is shape-cast (24 px circle) against
  the static obstacles one axis at a time, so it stops at a wall and slides along it, never
  passes through, and stays inside the world. No pathfinding: it can be held against an
  obstacle while the player stands straight behind it. The last 4 px to home snap
- the monster stays the WT01 `Area2D` (no physics body, so it never pushes or blocks the
  player); WT01 contact keeps its once-per-overlap semantics, also while chasing
- WORLD only: entering a city or travelling resets it to home / IDLE; returning to the world
  starts from there. Safe city exit: every return point is far outside the aggro radius
  (City A's (540, 200) is 501 px from home, City B's much farther), so the player chooses
  when to walk into the threat
- no attack, damage, encounter or combat. Nothing about the monster is saved (save
  version 8 unchanged); a load always rebuilds it at home, IDLE
- tests: `tests/verify_wt02_aggro_chase.gd` (WT01's test keeps its static-contact checks
  with no chase target)

Previous: World Threat WT01: visible prototype monster foundation.

- one prototype monster: stable id `prototype_monster_01`, fixed position (720, 320) as layout
  data in `WorldLayout` (inside the playable rect, clear of both obstacles, City A's entry
  trigger and return point, reachable from the default spawn)
- `WorldMonster` (`scenes/world_monster.tscn`): a minimal drawn red shape labelled
  「怪物（原型）」 and a 48 px contact circle. `player_contacted(monster_id)` fires once when the
  player enters, never while the player stays inside, and again only after leaving and
  re-entering (a debug line is printed on contact)
- active only in WORLD mode: `main.gd` switches it off with the world in IN_CITY / TRAVELING
- contact changes no game state: no encounter, combat, patrol, aggro or chase, and nothing
  monster-related is saved (save version unchanged)
- tests: `tests/verify_wt01_visible_monster.gd`

Previous: T06 World Exploration v0.1: world position persistence & state integrity.

- `PlayerLocation` holds the exact world position (`world_position`), only in WORLD mode;
  IN_CITY and TRAVELING have none (null), so no fake coordinate is ever stored
- valid = finite and inside the playable rect, the same limits the player's movement is
  clamped to: x 16–39984, y 48–40000. Saved coordinates outside it, NaN / infinity or
  malformed values reject the whole save (never clamped)
- leaving city A / B places the player at its approved return point; after moving away and
  saving, a reload restores the moved position. City entry, passenger transport and
  arrival rules are unchanged
- when the world position is saved (approved): at most every 5 s while the player has moved
  (`WORLD_AUTOSAVE_INTERVAL_MS`), and at once when the app pauses, loses focus or is closed;
  standing still never rewrites the save. Entering / leaving a city and trades save as before
- save version 8: only `location` changes (adds `world_position`); saves are written with
  full float precision. `SaveStore.save()` refuses an invalid location before creating any
  file, so an existing valid save is never overwritten
- migration of v1–v7 (no exact position; nothing invented): WORLD with a last-city context →
  that city's return point; WORLD without one → the default world spawn (420, 500);
  IN_CITY / TRAVELING keep their meaning
- tests: `tests/verify_t06_world_position.gd`

Previous: T05 Profit / Loss + Trading Integration: purchase lot → FIFO cost → realized P/L per sale.

- `TradeCostLedger` (new) holds the acquisition-cost identity of trade goods, separate from the
  quantity containers: per container (backpack, each city warehouse) and good, lots
  `{seq, quantity, unit_cost}` or `{seq, quantity, unknown: true}` ordered by `seq`, a stable
  acquisition sequence number (1, 2, 3 … in purchase order; one global counter). No average
  cost: different purchases never merge. CharacterInventory stays a quantity / capacity
  container
- ACQUISITION-ORDER FIFO: a sale consumes the carried units with the lowest `seq` first. A
  lot keeps its `seq` wherever it goes, so goods just taken out of a warehouse are still as
  old as when they were bought
- buy (1 or 10, one locked price, T03 unchanged) appends one lot at that price; sell consumes
  the oldest lots FIFO. Sell results add revenue, cost_known, acquisition_cost and
  realized_profit; when any sold unit has an unknown cost, acquisition_cost and
  realized_profit are null (never 0) and the sale still pays in full
- `TradeService.preview_sell()` runs the same rules as `sell()` without changing anything;
  the market row shows 「預計：賣1 +4 / 賣10 +40」 for the sizes the player can sell
  (資料不足 when a size's cost is not fully known). The executed sale uses the quote at
  execution time (T04 recovery may move it)
- sale feedback: 「已賣出 10 件…，收入 1260，成本 840，盈利 +420」 (虧損 -N / 盈虧 0), or
  「…，成本：資料不足」. Merchandise P/L only: transport fares are separate, and there is no
  trading run, trip or cumulative profit
- warehouse deposit / withdraw move the source's lowest-`seq` units with their `seq`, quantity
  and cost; a partial transfer splits a lot across containers under the same `seq` and the
  parts rejoin when they meet again. No purchase, sale or profit happens there
- atomic: wallet, inventory, market and ledger change together; any failure inside a trade
  restores all four. A save write that fails AFTER a completed trade keeps the trade
  (M2-06 contract, unchanged); warehouse transfers keep their own save-failure rollback,
  now including the lots. Trades and transfers refuse a ledger that does not match the goods
- save version 7 adds `cost_ledger` ({next_seq, backpack, warehouses: {city: …}}), validated
  strictly (exact keys; positive integer seqs, quantities and costs; seqs strictly ascending
  per container x good; one seq always the same good and cost; next_seq above every seq;
  lot totals equal to every carried and stored quantity) or the whole save is rejected
- v1–v6 saves get one UNKNOWN lot per good and container: quantities kept, no price
  invented. Deterministic migration order: backpack, then each warehouse in active-city
  order; goods in catalog order within a container. P/L and previews are never saved
- prototype UI adjustment (approved): the market view hides the 「城市（原型）」 title and
  uses a 4px row gap to fit the 16px preview line; buttons stay 104 × 88
- tests: `tests/verify_t05_profit_loss.gd`

Previous: T04 Market Recovery / Restock: stock drifts back toward its target over time.

- PROTOTYPE rule: every 12 s of market time each city × good stock moves 1 unit toward its
  target stock (100) and stops exactly there (95 → … → 100, 105 → … → 100, never past).
  Cities and goods recover independently. Only stock changes; the price follows through the
  unchanged T03 formula, and baseline / target never change
- one implementation: `MarketRecovery` holds the market's own timeline anchor and applies
  whole steps by elapsed time (`MarketState.recover_toward_target()` moves the stock). The
  anchor advances by whole steps only, so a partial step's remainder is kept (29 s → 2 steps,
  5 s carried). Dropped or late frames lose nothing (36 s in one frame → 3 steps)
- `main.update_market_recovery()` runs every frame and before each trade, reads time only
  from TimeSource, saves when stock changed and refreshes an open market. Trades never
  touch the anchor, so they do not reset the recovery timer
- offline: the saved anchor + stock rebuild the recovery on load; at most 30 minutes
  (150 steps) count. Loading never rewrites the save, so repeated reloads never
  double-apply. A future, negative or malformed timestamp applies zero recovery and
  re-anchors at now
- save version 6 adds `market_recovery` ({anchor_ms}); v1–v5 saves load with their stock
  unchanged and the anchor starts at that first load (no invented history). A v6 save
  missing the key is rejected like any other missing section
- ORDER-LOCKED PRICING (1 or 10 units per order, one price per order) is unchanged
- no restock UI (no countdown, progress or history); the open market just shows the newest
  stock and prices
- tests: `tests/verify_t04_market_recovery.gd` with the independent test model
  `tests/market_recovery_model.gd`
- NOT INCLUDED: per-good / per-city speeds, NPC merchants, production, events, price
  history, profit / loss (T05 and later)

Previous: T03 Dynamic Market Pricing: trade → stock → price.

- the city × good baseline reference price (MarketPrices) never moves; the price players see
  is a dynamic reference derived from baseline + current stock + target stock by the single
  formula `MarketRules.dynamic_reference()`, then the existing 105% / 95% spread
- PROTOTYPE rule: every 10% stock deviation moves the price ~5% the other way
  (stock 80 → +10%, 50 → +25%, 120 → −10%, 150 → −25%), clamped to 50%..200% of the
  baseline. With stock ≥ 0 the highest reachable price is +50% (stock 0); the 200% ceiling
  is a safety bound. The floor is reached at stock 2 × target
- integer-only maths: stock / target ratio in basis points by long division, price change in
  parts per million, round half up, overflow-safe for every value MarketState accepts
- quotes now include baseline_reference_price, dynamic_reference_price, buy / buyback,
  stock and target_stock (reference_price stays the baseline)
- buying lowers stock so the next quote is dearer; selling raises stock so it is cheaper.
  Cities and goods are independent. The market UI shows the new prices after every trade
- no save schema change: only stock is saved, so a reload rebuilds identical prices
- ORDER-LOCKED PRICING: one order = one price. `TradeService` only accepts orders of exactly
  1 or 10 units (domain rule, `ALLOWED_ORDER_QUANTITIES`); every unit of an order uses the
  quote read before it (total = unit price × quantity), and only after the whole order does
  the stock — and so the next quote — change. Market rows offer 買入 1 / 買入 10 / 賣出 1 /
  賣出 10 (104 × 88 buttons so four fit the 720-wide portrait layout)
- NOT INCLUDED (T04 / T05): recovery or restock over time, price history, profit / loss
- older market tests now compute expected prices with `tests/dynamic_price_model.gd`, an
  independent test-side model of the approved rule

Previous: T02 Warehouse UX + Remote View:

- backpack wording: every player-facing capacity line says 背包容量 (market 背包容量：x / y,
  failures 背包容量不足); 貨物容量 is no longer used for the character's capacity
- backpack prototype baseline: CharacterStats keeps capacity = base + Strength × per-Strength;
  per-Strength changed 1 → 9, so default Strength 10 gives 10 + 90 = 100 and capacity still
  scales with Strength (5 → 55, 20 → 190). PROTOTYPE PARAMETERS, not the formal curve.
  Legacy v1/v2 save validation keeps the historical Cargo cap of 20 it was written with
- warehouse city selector (A 城倉庫 / B 城倉庫): any active city's warehouse can be viewed
  from any city hub. The character's city shows 「X 城倉庫・本地倉庫」 with 背包：N / 倉庫：N
  and 存入 1 / 取出 1; any other city shows 「X 城倉庫・遠端查看：只可在所在城市存取倉庫物品」,
  its stored counts and 倉庫容量, and no transfer controls
- locality stays in WarehouseService: transfer requests carry the viewed city and are
  rejected unless it is the character's current city; switching views changes nothing and
  saves nothing. main.get_warehouse_view(city) gives read-only copies
- warehouse capacity stays 200 per city; no save schema change (still version 5)
- older rule tests that need a small full backpack use `tests/fixed_capacity_stats.gd`
  (a fixed capacity-20 fixture); the real 100 baseline is verified in
  `tests/verify_t02_warehouse_ux.gd`

Previous: T01 City Warehouse Foundation adds one independent item warehouse per active city:

- flow: Market ↔ CharacterInventory ↔ Warehouse. The market never reads or writes a
  warehouse; purchases enter and sales leave the character's inventory only
- `CityWarehouse` stores item quantities only (no money). Capacity is quantity × the
  authoritative GoodsCatalog capacity cost; callers can never supply a cost
- `WarehouseState` holds A and B, gives read access by city (contents, used, max,
  remaining capacity) and owns the save shape. Capacity is 200 per city, a PROTOTYPE
  PARAMETER that is never saved, so it can be re-tuned without migrating saves
- `WarehouseService` (UI-independent) deposits/withdraws only while IN_CITY and only in the
  current city; remote cities, the world and journeys are rejected. Transfers are free,
  atomic (both sides or neither), keep the existing inventory capacity and over-capacity
  rules, apply a repeated request id once, and roll back if the save fails
  (無法儲存，操作已取消). It never touches the wallet, market or journey
- City Hub 倉庫 tab: 背包容量 / 倉庫容量, per good 背包：N / 倉庫：N, 存入 1 / 取出 1
- save version 5 adds `warehouses` (city → items); v1–v4 saves load with empty warehouses,
  and malformed warehouse data rejects the whole save
- NOT INCLUDED (T02 or later): remote warehouse viewing UX, sorting/filtering, upgrades,
  paid expansion, money storage, market ↔ warehouse shortcuts

Previous: M2-09 Intercity Paid Passenger Transport lets the main character ride between the
two active cities for a fare. Transport carries people, never goods:

- `TransportService` (UI-independent) validates the request, charges the fare through
  `Wallet`, starts a journey and settles the arrival exactly once. It never receives
  `CharacterInventory`, `CharacterStats`, `MarketState`, `Cargo` or any warehouse; goods
  stay in the character's personal inventory and the vehicle adds no capacity
- `TransportRoutes` is the single source of the A → B and B → A fare (300) and travel
  time (90 s). These are PROTOTYPE PARAMETERS, not formal balance, and not the old
  Phaser bus formula
- `PlayerLocation` records WORLD / IN_CITY / TRAVELING, the current city (or the last
  city left, whose return point is used after a reopen) and the journey (id, origin,
  destination, start, arrival time, fare, status). Exact world coordinates are not saved
- `TimeSource` is the only clock gameplay reads (local system time for now; tests use a
  fixed, manually advanced clock)
- City Hub facilities: 市場 / 交通 tabs. 交通 shows 目的地 / 車費 / 預計時間 and 乘搭.
  During a journey the hub shows 旅途中 / 前往 X 城 / 預計抵達：N 秒; movement, city
  entry/exit and trading are locked, and on arrival the destination hub opens directly
- duplicate protection: each shown offer carries a request id, and a request id can
  start at most one journey, so a double tap charges once and can never turn A → B
  into an immediate B → A
- rollback: if the journey cannot be created or saved after the charge, money and
  location are restored and the player sees 無法儲存，乘搭已取消. Arrival is saved
  atomically too: if the arrival cannot be saved, the journey stays unfinished in both
  the game and the save (無法儲存，正在重試抵達) and is retried, so it settles exactly once
- save version 4 adds `location`; v1/v2/v3 saves still load at the normal world spawn.
  Entering or leaving a city now also saves, so a reopen restores the city, the world
  return point, or the journey (arriving immediately, once, if the ETA has passed)
- PROTOTYPE LIMITATION: journeys have no encounters. Transport risk / encounter
  interaction must be revisited when the Stage 3 Encounter system is integrated
- NOT INCLUDED: freight, vehicle cargo/storage, warehouse, mercenary travel or roster,
  stations, timetable, vehicle sprites/animation, rerouting, cancellation, refunds,
  cities C/D, road network, formal fare/time balance

M2-08 Character Inventory / Carrying Foundation replaces the player-global
Cargo runtime model with a character-owned inventory foundation:

- `CharacterInventory` owns item stacks per character and exposes deterministic
  used/max capacity, add/remove checks and atomic model-level transfers
- capacity is `quantity × capacity_cost`; stacking is display-only and gives no
  capacity discount
- `CharacterStats` is the capacity source. The current base, default Strength and
  capacity-per-Strength values are explicitly marked prototype parameters, not
  formal balance
- every carried item shares the same capacity interface. The six test goods keep
  the M2-07 placeholder costs, while an explicit cost resolver/stack cost lets a
  future Equipment system count equipped items without splitting capacity pools
- an inventory may become over capacity after a stat change or reload; existing
  items remain, removal remains possible, and new additions are rejected
- Market buy/sell now use the player's `CharacterInventory` while preserving the
  existing spread, stock checks and defensive transaction rollback
- save version 3 stores character id, Strength and inventory stacks; valid v1/v2
  Cargo saves migrate in memory, while corrupt saves still reject as a whole
- `Cargo` remains only as a temporary compatibility wrapper for historical tests
  and callers; the runtime session uses `CharacterInventory`
- NOT INCLUDED: warehouse changes, mercenary roster/centre, recruitment/dismissal,
  transport, battle loot UI, full Equipment, formal Strength/goods balance,
  dynamic markets, partial fill, restock, market ticks or UI/art polish

M2-07 Basic Market Foundation turns the fixed price table into a stateful city market:

- per-city Market State (`scripts/market_state.gd`): each active city × good has its own
  reference price, current stock and target stock; the market belongs to the world, not
  the player (`main.gd` only holds it for the session)
- baseline values in `scripts/market_prices.gd`: the M2-04 A/B test prices become the
  prototype reference prices, with prototype initial stock 100 and target stock 100
- prototype 5% spread in `scripts/market_rules.gd`: players buy at ceil(reference × 1.05)
  and sell at floor(reference × 0.95), computed with integer maths (for example 80 → 84 / 76,
  1250 → 1313 / 1187); buy price is always above the buyback price
- buying lowers the city's stock and is rejected when the stock is too low (no partial
  fill); selling raises it and may go above the target stock
- a same-city buy-then-sell always loses money (for example A Good 1 × 10: −80)
- `TradeService` takes the market, uses its quote, and keeps every trade atomic across
  money, cargo and stock
- market persistence: the save (version 2) also stores every city × good reference price,
  stock and target stock; an M2-06 save without a market keeps its money and cargo and gets
  a fresh default market; a market that is present but invalid rejects the whole save
- player-facing rule: all text players see is Traditional Chinese; the City Hub market
  shows 買入價 / 賣出價 / 持有 / 庫存 with 買入 1 / 賣出 1, and goods show the placeholder
  names 測試商品一 … 六 (internal ids stay `test_good_01` … `06`)
- NOT YET implemented: dynamic pricing (reference prices never move with trades), supply and
  demand, restocking, market ticks, partial fills, formal balancing and formal goods names

M2-06 adds minimal local persistence (prototype persistence only):

- saves only the player's Money and Cargo to `user://myrial_save.json` as small JSON
  (`{"version": 1, "money": …, "cargo": {"test_good_01": …}}`) via `scripts/save_store.gd`
- does not save the world position, current city or City Hub state: after a restart the
  player uses the normal world spawn with the saved Money and Cargo
- autosaves after every successful Buy/Sell; failed trades never write the save
- on startup a valid save is fully validated, then restored into new Wallet/Cargo
  objects through their normal APIs; a missing, invalid or corrupt save is never
  partially restored and simply leaves the safe defaults (10000 money, empty cargo)
  until the next successful trade writes a fresh valid save
- a failed save write keeps the successful trade and only logs a warning
- tests use their own save path (or `save_path = ""` to turn persistence off), so they
  never read or overwrite the player's real save
- no save slots, manual save/load, cloud, backend, encryption or migration framework

M2-05A adds a minimal touch Enter City control to unblock mobile Market acceptance:

- an `Enter City` touch button (`EnterControls/EnterCityButton` in `scenes/main.tscn`)
  in the lower-right corner, outside the left-half joystick area and clear of every
  City Hub button underneath it
- the button only appears in the world while an active city can be entered from the
  player's position, and hides inside the City Hub and at the safe return points
- tapping it calls the same authoritative `try_enter_city()` path as the keyboard;
  the E key is preserved, and both use one shared `can_enter_city()` rule
- no auto-enter and no generic interaction framework

M2-05 adds a minimal player-operable Market UI, building on the accepted M2-04 trade core:

- the City Hub now shows a MARKET section directly (no extra navigation)
- six goods visible, one row each, built from `GoodsCatalog`
- city prices visible for the current city, read from `MarketPrices`
- Buy 1 and Sell 1 buttons per good; each press asks `scripts/main.gd` to run exactly
  one `buy_in_current_city` / `sell_in_current_city` trade through `TradeService`
- Money, Cargo used / capacity and each good's Held quantity refresh immediately
- one-line transaction feedback (for example `Bought 1 Test Good 1 for 80`,
  `Not enough money`, `Not enough cargo space`, `Not enough goods`)
- portrait prototype layout that fits the 720 × 1280 reference with 120 × 88 touch buttons
- the UI only displays and forwards presses; it never changes money or cargo itself

NOT INCLUDED in M2-05: formal UI or art, dynamic prices, market stock, quantity selection
(Buy 10 / Buy Max / Sell All), trade history, save/load, formal balancing, and a touch way
to enter a city from the world (added by M2-05A above).

M2-04 Money, A/B Price Table and Buy/Sell Transaction Core (accepted):

- `scripts/wallet.gd`: a prototype wallet with `STARTING_MONEY` 10000 (TEST VALUE);
  integer money that can never go negative, changed only through validated spend/add
- `scripts/market_prices.gd`: fixed A/B test prices for all six goods (one price per
  city used for both buying and selling); reserved cities C/D have no prices
- `scripts/trade_service.gd`: a UI-independent trade core with atomic buy and atomic
  sell; every check runs before any state changes, and cargo is only changed through
  the M2-03 Cargo API
- proven routes: A → B `test_good_01` (10 bought for 800, sold for 1200, +400),
  B → A `test_good_05` (+800 for 2) and a losing A → B `test_good_05` example (−800)
- the wallet and cargo are session state owned by `scripts/main.gd`, so World ↔ City
  transitions preserve both Money and Cargo
- the City Hub shows developer-only `Money` and `Cargo` lines; trading is exposed
  through `main.buy_in_current_city()` / `sell_in_current_city()` for tests and
  runtime checks, with no Market UI yet

M2-03 Six Test Goods and Cargo Data Foundation (accepted):

- six prototype goods (`test_good_01` … `test_good_06`) in one data source,
  `scripts/goods_catalog.gd`; unit sizes and base values are TEST VALUES only,
  not a formal economy balance or formal goods names
- `scripts/cargo.gd`: a UI-independent cargo model with a prototype
  `CARGO_CAPACITY` of 20 cargo units, where used capacity = Σ quantity × unit size
- validated add/remove (unknown goods, non-positive or non-integer quantities and
  overflow are rejected; removing to zero deletes the entry)
- six-goods inventory support: all six goods can be held together within capacity
- the cargo is session state owned by `scripts/main.gd`, so World ↔ City
  transitions preserve it (it resets only when the game restarts; no disk save yet)
- the City Hub shows a developer-only `Cargo: used / 20` line
- the goods catalog is global: both active cities carry all six goods and there
  are no per-city prices yet, so no per-city availability layer is needed

M2-02 City Hub Foundation (accepted):

- World → City A/B trigger → explicit Enter → shared Prototype City Hub → Leave →
  correct world return
- a new `interact` input action (E key); standing in a trigger never forces entry
- `scripts/main.gd` is a small world/city state controller holding `current_city_id`;
  entering pauses player physics and joystick input, leaving restores them
- one reusable `scenes/city_hub.tscn` overlay for every active city, showing
  `[ City A ]` or `[ City B ]`, "Prototype City Hub" and a Leave City button
- per-city return points in `WorldLayout.CITY_RETURN_POINTS`: A (540, 200) and
  B (39,460, 200), beside each city, outside its trigger and collision
- entry also checks the player's current collision box against the trigger circle,
  so a stale Area2D overlap right after a teleport cannot re-enter a city
- cities C and D stay reserved coordinates with no hub entry

M2-01 40K World and Two Corner Cities (accepted):

- a 40,000 × 40,000 square world (0 ≤ x, y ≤ 40,000) defined in `scripts/world_layout.gd`
- four approved city anchors: A (200, 200) and B (39,800, 200) are active prototype
  markers; C (200, 39,800) and D (39,800, 39,800) are reserved coordinates only
- `scenes/city_marker.tscn`: a placeholder city footprint, label and `Area2D` entry
  trigger that reports when the player is inside (no city content yet)
- player spawn at (420, 500), just outside City A and with City A on screen
- a lightweight line grid (`scripts/world_grid.gd`) as the only orientation aid
- A → B is 39,600 units, about 180 seconds at the unchanged 220 units/second

Earlier accepted foundations:


- `project.godot` with a 720 × 1280 portrait base viewport and Compatibility renderer
- handheld orientation locked to portrait for iPhone
- a 405 × 720 desktop window override for Mac testing only; the world still
  renders at the 720 × 1280 portrait viewport
- a `CharacterBody2D` player scene at `scenes/player.tscn`
- free, normalized eight-direction movement using W, A, S, and D
- an exported `move_speed` setting, defaulting to 220 pixels per second
- a `Camera2D` owned by the player so the viewport follows its movement
- one shared rectangular world boundary used by both movement and its visual guide
- player clamping that keeps the full placeholder body inside that boundary
- matching player and obstacle collision shapes using Godot's 2D physics
- two solid placeholder blocks for collision and wall-sliding verification
- one Y-sorted actor group containing the player and placeholder obstacles
- foot/base sorting origins so vertical position controls visual depth
- obstacle visuals taller than their base collision for occlusion verification
- a developer-prototype floating virtual joystick (`scenes/touch_joystick.tscn`)
  that starts wherever one finger presses on the left half of the screen
- touch and keyboard directions combined into the player's single movement path;
  the joystick only reports a direction and never moves the player itself
- Godot-generated and local export files excluded from version control

Open `project.godot` in Godot 4.x and run the project. A static bootstrap screen
should appear and the output should contain:

`Myrial: Unwritten M2-09 passenger transport ready`

Headless verification scripts live in `tests/`. Run them through the runner, which
first performs the headless import (`--import`) and then runs the scripts:

`GODOT=/Applications/Godot.app/Contents/MacOS/Godot godot/tests/run_tests.sh`
(all `tests/verify_*.gd`) or `GODOT=... godot/tests/run_tests.sh verify_t01_warehouse`.

The import step is required on a fresh clone: `godot/.godot/` is a generated cache
(git-ignored, never committed), and a direct `--script` run does not scan the project,
so without it `class_name` scripts cannot be resolved and the bundled font is not
imported. Running a single script directly
(`godot --headless --path godot --script res://tests/verify_t01_warehouse.gd`) works only
after the project has been imported at least once since the last new `class_name` script.

## Deliberately not included

M2-05 does not add a formal Market UI, quantity selection, dynamic prices, market stock,
supply/demand, tax, fees or spreads, trade history, formal balancing, cargo item-list UI, save/load, storage, city facilities,
NPCs, formal city content, a touch Enter button, gameplay for cities C and D, roads, minimap, fast travel, terrain features, battle mode, landscape battle orientation, runtime orientation switching,
tap-to-move, pathfinding, sprint, dodge, interaction or combat buttons,
multi-touch gestures, haptics, safe-area layout, final HUD art, camera smoothing, camera
limits or shake, complex obstacle shapes, transparency effects, cities, economy, combat, monsters, online systems,
saved-game migration, production UI, or final art. The boundary, guide lines and
origin marker, and solid blocks are temporary verification visuals, not world art.
Those excluded features require separate approved work packages and evidence.
