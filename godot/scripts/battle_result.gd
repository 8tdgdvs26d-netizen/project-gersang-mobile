class_name BattleResult
extends RefCounted

## Combat C02: the outcome of one finished battle, produced once by
## CombatBattle when it reaches VICTORY or DEFEAT and consumed once by the
## world lifecycle (main.commit_battle_result). Runtime only, never saved.
## It carries no reward, EXP or loot.

enum Outcome { VICTORY, DEFEAT }

## The locked encounter the battle came from.
var encounter_id := ""
var outcome: Outcome = Outcome.DEFEAT
## The World Enemy Groups that took part (primary group first).
var group_monster_ids: Array[String] = []
var _committed := false


static func create(from_encounter_id: String, result_outcome: Outcome, group_ids: Array[String]) -> BattleResult:
	var result := BattleResult.new()
	result.encounter_id = from_encounter_id
	result.outcome = result_outcome
	result.group_monster_ids = group_ids.duplicate()
	return result


func is_victory() -> bool:
	return outcome == Outcome.VICTORY


func is_committed() -> bool:
	return _committed


## Claims the single commit. Returns false when it was already claimed.
func claim_commit() -> bool:
	if _committed:
		return false
	_committed = true
	return true
