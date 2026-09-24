# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

M1-01 Project Bootstrap establishes only the minimum project skeleton:

- `project.godot` with a 1280 × 720 base viewport and Compatibility renderer
- one startup scene at `scenes/main.tscn`
- one GDScript startup script at `scripts/main.gd`
- Godot-generated and local export files excluded from version control

Open `project.godot` in Godot 4.x and run the project. A static bootstrap screen
should appear and the output should contain:

`Myrial: Unwritten M1-01 bootstrap ready`

## Deliberately not included

M1-01 does not add player movement, camera behaviour, world boundaries,
collision, Y-sorting, cities, economy, combat, monsters, online systems,
saved-game migration, production UI, or final art. Those require separate
approved work packages and evidence.
