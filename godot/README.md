# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

M1-07 Mobile Touch Movement builds on the accepted M1-06 y-sort and occlusion:

- `project.godot` with a 1280 × 720 base viewport and Compatibility renderer
- a `CharacterBody2D` player scene at `scenes/player.tscn`
- free, normalized eight-direction movement using W, A, S, and D
- an exported `move_speed` setting, defaulting to 220 pixels per second
- a `Camera2D` owned by the player so the viewport follows its movement
- minimal world reference guides used only to make camera movement observable
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

`Myrial: Unwritten M1-07 mobile touch movement ready`

Headless verification scripts live in `tests/` and run with, for example:

`godot --headless --path godot --script res://tests/verify_m1_07.gd`

## Deliberately not included

M1-07 does not add tap-to-move, pathfinding, sprint, dodge, interaction or combat buttons,
multi-touch gestures, haptics, safe-area layout, final HUD art, camera smoothing, camera
limits or shake, complex obstacle shapes, transparency effects, cities, economy, combat, monsters, online systems,
saved-game migration, production UI, or final art. The boundary, guide lines and
origin marker, and solid blocks are temporary verification visuals, not world art.
Those excluded features require separate approved work packages and evidence.
