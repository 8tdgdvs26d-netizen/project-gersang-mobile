extends RefCounted

## VS-01 WP01-E — golden vectors from the EXISTING GDScript combat EXP / Level
## rules (CombatConfig, EncounterContext, WorldLayout, BattleResult,
## PartyProgression, ProgressionState). The Nakama TypeScript copy
## (nakama/src/wp01e_rules.ts) must reproduce every value
## (nakama/tests/unit/wp01e_parity.test.mjs); verify_vs01_wp01e_combat_vectors.gd
## re-checks that the GDScript rules still produce
## nakama/tests/fixtures/wp01e_vectors.json, so drift on either side fails a
## test. Regenerate with nakama/scripts/generate_wp01e_vectors.gd.


static func build_vectors() -> Dictionary:
	var required := []
	for level in range(0, ProgressionState.MAX_LEVEL + 2):
		required.append([level, ProgressionState.required_exp(level)])
	var gain := []
	for level in [1, 2, 3, 5, 10, 25, 50, 97, 98, 99, 100]:
		var need := ProgressionState.required_exp(level)
		for held in _held_samples(level, need):
			for amount in [0, 1, 9, 10, 50, 99, 100, 101, 149, 150, 151, 200, 250, 349, 350, 1000, 5000, 300000]:
				var after := ProgressionState.advance(level, held, amount)
				gain.append([level, held, amount, after[0], after[1]])
	return {
		"source": "godot/scripts combat_config.gd, encounter_context.gd, world_layout.gd, battle_result.gd, party_progression.gd, progression_state.gd",
		"exp_per_kill": CombatConfig.EXP_PER_KILL,
		"enemies_by_group_count": EncounterContext.PLANNED_COMBAT_ENEMIES,
		"group_ids": _group_ids(),
		"group_respawn_ms": WorldLayout.GROUP_RESPAWN_MS,
		"max_level": ProgressionState.MAX_LEVEL,
		"required_exp": required,
		"gain": gain,
		"settlement": _settlement(),
	}


static func _held_samples(level: int, need: int) -> Array:
	if level >= ProgressionState.MAX_LEVEL:
		return [0]
	return [0, 1, need / 2, need - 1]


static func _group_ids() -> Array:
	var ids := []
	for group in WorldLayout.PROTOTYPE_GROUPS:
		ids.append(String(group["id"]))
	return ids


## Hero-only battles settled by the real PartyProgression: every outcome,
## kill count and Hero state the battle rules can produce, from several
## starting Levels. Each row: [outcome, kills, hero_alive, enemy_count,
## level, exp, exp_awarded, level_after, exp_after].
static func _settlement() -> Array:
	var outcomes := {"victory": BattleResult.Outcome.VICTORY, "retreat": BattleResult.Outcome.RETREAT, "defeat": BattleResult.Outcome.DEFEAT}
	var rows := []
	for group_count in [1, 2, 3]:
		var enemy_count: int = EncounterContext.PLANNED_COMBAT_ENEMIES[group_count]
		for start in [[1, 0], [1, 99], [2, 140], [9, 0], [99, 0], [99, 5000], [100, 0]]:
			var level: int = start[0]
			var held: int = mini(start[1], maxi(ProgressionState.required_exp(level) - 1, 0))
			for outcome_name in outcomes:
				for kills in [0, 1, enemy_count - 1, enemy_count]:
					for hero_alive in [true, false]:
						if not _possible(outcome_name, kills, hero_alive, enemy_count):
							continue
						var result := BattleResult.create("vectors", outcomes[outcome_name], [])
						result.exp_pool = kills * CombatConfig.EXP_PER_KILL
						if hero_alive:
							result.survivor_ids.append("hero")
						var progression := ProgressionState.from_hero(level, held)
						var shares := PartyProgression.apply(result, progression, null)
						var awarded: int = int(shares["hero"]["exp"]) if shares.has("hero") else 0
						rows.append([outcome_name, kills, hero_alive, enemy_count, level, held, awarded,
							progression.get_level("hero"), progression.get_exp("hero")])
	return rows


## What CombatBattle can end with for a Hero-only party: VICTORY = every enemy
## dead (Hero alive); RETREAT = the alive Hero escaped (an enemy is left);
## DEFEAT = the Hero dead (an enemy is left).
static func _possible(outcome: String, kills: int, hero_alive: bool, enemy_count: int) -> bool:
	match outcome:
		"victory":
			return hero_alive and kills == enemy_count
		"retreat":
			return hero_alive and kills < enemy_count
		_:
			return not hero_alive and kills < enemy_count
