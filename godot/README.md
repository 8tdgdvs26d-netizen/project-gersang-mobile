# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

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
to enter a city from the world (entering still needs the E key).

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

`Myrial: Unwritten M2-05 minimal player market ready`

Headless verification scripts live in `tests/` and run with, for example:

`godot --headless --path godot --script res://tests/verify_m2_05.gd`

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
