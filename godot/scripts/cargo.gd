class_name Cargo
extends CharacterInventory

## Deprecated compatibility name for the pre-M2-08 player-global Cargo model.
## New runtime code owns one CharacterInventory per character.

## Deprecated M2-03 compatibility wrapper. Runtime code uses
## CharacterInventory; old verification scripts may still construct Cargo.
const CARGO_CAPACITY := CharacterStats.PROTOTYPE_BASE_CAPACITY \
	+ CharacterStats.PROTOTYPE_DEFAULT_STRENGTH * CharacterStats.PROTOTYPE_CAPACITY_PER_STRENGTH
