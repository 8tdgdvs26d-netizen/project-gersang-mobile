class_name BattleResult
extends RefCounted

## Combat C02: the outcome of one finished battle, produced once by
## CombatBattle when it reaches VICTORY or DEFEAT and consumed once by the
## world lifecycle (main.commit_battle_result). Runtime only, never saved.
## C05: it carries the battle's EXP pool and the friendly units alive at
## settlement; ProgressionState turns them into EXP when the world commits it
## (DEFEAT awards none). No loot or money.

## C04: RETREAT — at least one friendly unit escaped through the Retreat Zone.
enum Outcome { VICTORY, DEFEAT, RETREAT }

## The locked encounter the battle came from.
var encounter_id := ""
var outcome: Outcome = Outcome.DEFEAT
## The World Enemy Groups that took part (primary group first).
var group_monster_ids: Array[String] = []
## C05: EXP earned by enemies actually killed in this battle.
var exp_pool := 0
## C05: ids of the friendly units alive at settlement ("hero", "merc_a",
## "merc_b"; Stage 8 P04: "hero" + the deployed roster Mercenaries' instance
## ids, settled by PartyProgression).
var survivor_ids: Array[String] = []
var _committed := false


static func create(from_encounter_id: String, result_outcome: Outcome, group_ids: Array[String]) -> BattleResult:
	var result := BattleResult.new()
	result.encounter_id = from_encounter_id
	result.outcome = result_outcome
	result.group_monster_ids = group_ids.duplicate()
	return result


func is_victory() -> bool:
	return outcome == Outcome.VICTORY


func is_retreat() -> bool:
	return outcome == Outcome.RETREAT


func is_committed() -> bool:
	return _committed


## Claims the single commit. Returns false when it was already claimed.
func claim_commit() -> bool:
	if _committed:
		return false
	_committed = true
	return true
