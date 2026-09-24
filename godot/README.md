# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

M1-04 World Boundary builds on the accepted M1-03 camera follow:

- `project.godot` with a 1280 × 720 base viewport and Compatibility renderer
- a `CharacterBody2D` player scene at `scenes/player.tscn`
- free, normalized eight-direction movement using W, A, S, and D
- an exported `move_speed` setting, defaulting to 220 pixels per second
- a `Camera2D` owned by the player so the viewport follows its movement
- minimal world reference guides used only to make camera movement observable
- one shared rectangular world boundary used by both movement and its visual guide
- player clamping that keeps the full placeholder body inside that boundary
- Godot-generated and local export files excluded from version control

Open `project.godot` in Godot 4.x and run the project. A static bootstrap screen
should appear and the output should contain:

`Myrial: Unwritten M1-04 world boundary ready`

## Deliberately not included

M1-04 does not add camera smoothing, camera limits or shake, obstacle collision,
Y-sorting, mobile touch controls, cities, economy, combat, monsters, online systems,
saved-game migration, production UI, or final art. The boundary, guide lines and
origin marker are temporary verification visuals, not world art. Those excluded
features require separate approved work packages and evidence.
