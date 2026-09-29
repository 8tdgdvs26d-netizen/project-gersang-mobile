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
## World Threat WT05: the prototype monster's fixed patrol loop, visited in
## this order and ending back at home. Every point and straight leg lies well
## inside low_threat_zone_01 (130+ px from its edges), clear of both obstacles
## and far from every city safe buffer.
const PROTOTYPE_MONSTER_PATROL := [
	Vector2(860.0, 610.0),
	Vector2(860.0, 720.0),
	Vector2(700.0, 720.0),
	Vector2(760.0, 650.0),
]

## Encounter E02: the three prototype World Enemy Groups (one monster each),
## all in low_threat_zone_01. Group 1 is the WT01–WT05 monster; groups 2 and 3
## use the same loop shape, shifted. The homes form a ~260 px triangle so the
## player can deliberately meet one group (west of group 1), two (north,
## between groups 1 and 2, out of group 3's reach) or all three (the middle).
## No group's aggro reaches the new-game spawn or a city return point.
const PROTOTYPE_GROUPS := [
	{"id": PROTOTYPE_MONSTER_ID, "home": PROTOTYPE_MONSTER_POSITION, "patrol": PROTOTYPE_MONSTER_PATROL},
	{
		"id": "prototype_monster_02",
		"home": Vector2(1020.0, 650.0),
		"patrol": [Vector2(1120.0, 610.0), Vector2(1120.0, 720.0), Vector2(960.0, 720.0), Vector2(1020.0, 650.0)],
	},
	{
		"id": "prototype_monster_03",
		"home": Vector2(890.0, 860.0),
		"patrol": [Vector2(990.0, 820.0), Vector2(990.0, 930.0), Vector2(830.0, 930.0), Vector2(890.0, 860.0)],
	},
]
