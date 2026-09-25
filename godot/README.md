# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

M2-02 City Hub Foundation builds on the accepted M2-01 40K world and two corner cities:

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

`Myrial: Unwritten M2-02 city hub foundation ready`

Headless verification scripts live in `tests/` and run with, for example:

`godot --headless --path godot --script res://tests/verify_m2_02.gd`

## Deliberately not included

M2-02 does not add markets, goods, buy/sell, cargo, money, storage, city facilities,
NPCs, formal city content, a touch Enter button, gameplay for cities C and D, roads, minimap, fast travel, terrain features, battle mode, landscape battle orientation, runtime orientation switching,
tap-to-move, pathfinding, sprint, dodge, interaction or combat buttons,
multi-touch gestures, haptics, safe-area layout, final HUD art, camera smoothing, camera
limits or shake, complex obstacle shapes, transparency effects, cities, economy, combat, monsters, online systems,
saved-game migration, production UI, or final art. The boundary, guide lines and
origin marker, and solid blocks are temporary verification visuals, not world art.
Those excluded features require separate approved work packages and evidence.
