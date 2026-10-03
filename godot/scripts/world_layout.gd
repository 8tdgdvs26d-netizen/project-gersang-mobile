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

## World Threat: the single prototype monster (group 1). Fixed identity and
## fixed home (layout data, never random): a stand-in low-level threat spot
## away from City A's exit, never straight behind an obstacle (returning home
## can always slide around them). E02 fix pass: moved from (760, 650) to
## (800, 700) so its whole 240 px aggro circle lies inside low_threat_zone_01
## (x 560–1040, y 460–940). Every city return point and the new-game spawn stay
## far outside every group's aggro range.
## Encounter E03: a World Enemy Group's fixed disposition (design data, never
## saved or changed at runtime). AGGRESSIVE groups aggro, chase, catch and
## auto-join encounters; PASSIVE groups only patrol and are challenged by the
## player (「挑戰」). Passive does not mean harmless in future Combat.
enum Disposition { AGGRESSIVE, PASSIVE }

const PROTOTYPE_MONSTER_ID := "prototype_monster_01"
const PROTOTYPE_MONSTER_POSITION := Vector2(800.0, 700.0)
## World Threat WT05 / E02 fix pass: group 1's patrol itinerary, walked in this
## order and ending back at home. Controlled irregular patrol: four fixed
## points around home visited in a varied, repeating order (not one rigid
## loop), with a deterministic pause (seconds, 0 = none) at some stops.
## Every point and straight leg lies well inside low_threat_zone_01, clear of
## both obstacles and far from every city safe buffer.
const PROTOTYPE_MONSTER_PATROL := [
	Vector2(900.0, 640.0),
	Vector2(900.0, 790.0),
	Vector2(800.0, 700.0),
	Vector2(740.0, 640.0),
	Vector2(760.0, 790.0),
	Vector2(900.0, 790.0),
	Vector2(900.0, 640.0),
	Vector2(800.0, 700.0),
]
const PROTOTYPE_MONSTER_PATROL_PAUSES := [0.0, 1.2, 0.0, 0.8, 0.0, 0.0, 1.5, 0.0]

## Encounter E02: the three prototype World Enemy Groups (one monster each),
## all in low_threat_zone_01. E02 fix pass (aggro 240 px): the homes form a
## triangle (~300 px sides) and each group roams four points ~100 px around
## its home in its own order with its own pauses, so the three activity
## regions overlap near the middle without sharing a route. Deliberate
## positions: west of group 1 → one group; north between groups 1 and 2 →
## two (out of group 3's reach); the middle → three. No group's aggro reaches
## the new-game spawn or a city return point.
## Stage 7 corrective — PROTOTYPE TUNABLE: a World Enemy Group defeated in a
## committed VICTORY comes back this long after the player returned to the
## world (GroupRespawn; runtime only, never saved).
const GROUP_RESPAWN_MS := 10000
const PROTOTYPE_GROUPS := [
	{
		"id": PROTOTYPE_MONSTER_ID,
		"home": PROTOTYPE_MONSTER_POSITION,
		"patrol": PROTOTYPE_MONSTER_PATROL,
		"pauses": PROTOTYPE_MONSTER_PATROL_PAUSES,
		"disposition": Disposition.AGGRESSIVE,
	},
	{
		"id": "prototype_monster_02",
		"home": Vector2(1100.0, 700.0),
		"patrol": [Vector2(1020.0, 790.0), Vector2(1180.0, 640.0), Vector2(1100.0, 700.0), Vector2(1020.0, 640.0), Vector2(1180.0, 790.0), Vector2(1100.0, 700.0)],
		"pauses": [1.0, 0.0, 0.6, 0.0, 1.8, 0.0],
		"disposition": Disposition.AGGRESSIVE,
	},
	{
		"id": "prototype_monster_03",
		"home": Vector2(950.0, 930.0),
		"patrol": [Vector2(870.0, 870.0), Vector2(1030.0, 1000.0), Vector2(950.0, 930.0), Vector2(1030.0, 870.0), Vector2(870.0, 1000.0), Vector2(950.0, 930.0)],
		"pauses": [0.0, 1.4, 0.0, 0.7, 0.0, 2.0],
		"disposition": Disposition.PASSIVE,
	},
]
