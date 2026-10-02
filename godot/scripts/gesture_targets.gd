class_name GestureTargets
extends RefCounted

## Combat C07: which enemies a Gesture hits — up to `count` different alive
## enemies picked at random (all of them when there are no more than
## `count`). The random source is passed in, so a seeded generator replays
## the same pick (tests); the battle keeps its randomness here, outside its
## deterministic rules.


static func pick(enemies: Array[CombatUnit], count: int, rng: RandomNumberGenerator) -> Array[CombatUnit]:
	var alive: Array[CombatUnit] = []
	for enemy in enemies:
		if enemy.alive:
			alive.append(enemy)
	if alive.size() <= count:
		return alive
	# Partial Fisher-Yates: the first `count` entries become a uniform pick.
	for index in range(count):
		var other := rng.randi_range(index, alive.size() - 1)
		var held := alive[index]
		alive[index] = alive[other]
		alive[other] = held
	return alive.slice(0, count)
