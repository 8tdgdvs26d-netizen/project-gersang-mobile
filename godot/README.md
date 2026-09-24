# Myrial: Unwritten — Godot project

This directory contains the Godot 4.x + GDScript migration project for
《萬行誌：白手》.

## Current work package

M1-02 Player Movement builds on the M1-01 project skeleton:

- `project.godot` with a 1280 × 720 base viewport and Compatibility renderer
- a `CharacterBody2D` player scene at `scenes/player.tscn`
- free, normalized eight-direction movement using W, A, S, and D
- an exported `move_speed` setting, defaulting to 220 pixels per second
- Godot-generated and local export files excluded from version control

Open `project.godot` in Godot 4.x and run the project. A static bootstrap screen
should appear and the output should contain:

`Myrial: Unwritten M1-02 player movement ready`

## Deliberately not included

M1-02 does not add camera behaviour, world boundaries, obstacle collision,
Y-sorting, mobile touch controls, cities, economy, combat, monsters, online systems,
saved-game migration, production UI, or final art. Those require separate
approved work packages and evidence.
