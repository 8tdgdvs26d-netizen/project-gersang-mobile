class_name WorldLayout
extends RefCounted

## Approved Stage 2 world scale and four-city spatial anchors.
## Only cities A and B are active; C and D are spatial reservations only.

const WORLD_SIZE := Vector2(40000.0, 40000.0)

const CITY_A := Vector2(200.0, 200.0)
const CITY_B := Vector2(39800.0, 200.0)
const CITY_C := Vector2(200.0, 39800.0)
const CITY_D := Vector2(39800.0, 39800.0)

const CITY_ANCHORS := {
	"A": CITY_A,
	"B": CITY_B,
	"C": CITY_C,
	"D": CITY_D,
}
const ACTIVE_CITY_IDS := ["A", "B"]
const RESERVED_CITY_IDS := ["C", "D"]

## Where the player reappears in the world after leaving each active city:
## beside the city on the A-B route, outside its entry trigger and collision.
const CITY_RETURN_POINTS := {
	"A": Vector2(540.0, 200.0),
	"B": Vector2(39460.0, 200.0),
}

## World Threat: the single prototype monster. Fixed identity and fixed home
## (layout data, never random). WT02 review: a stand-in low-level threat spot
## away from City A's exit, a short walk from the default spawn (372 px),
## between the two obstacles and never straight behind one (so returning home
## can always slide around them). Every city return point stays far outside
## its aggro radius (City A's: 501 px), so leaving a city never starts a chase.
const PROTOTYPE_MONSTER_ID := "prototype_monster_01"
const PROTOTYPE_MONSTER_POSITION := Vector2(760.0, 650.0)
