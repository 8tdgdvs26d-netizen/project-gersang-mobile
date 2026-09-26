# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

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

`Myrial: Unwritten M2-08 character inventory foundation ready`

Headless verification scripts live in `tests/` and run with, for example:

`godot --headless --path godot --script res://tests/verify_m2_08.gd`

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
