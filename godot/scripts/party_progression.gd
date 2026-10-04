class_name PartyProgression
extends RefCounted

## Stage 8 P04: the C05 battle settlement for the game's party — the Hero +
## the deployed roster Mercenaries (CombatBattle.create_party). The C05 rules
## are unchanged: the EXP pool is shared equally (integer division, remainder
## discarded) by EVERY friendly unit alive at settlement; DEFEAT awards
## nothing; a RETREAT keeps the EXP of its kills. Each survivor's share goes
## to exactly one place, so nothing is settled twice:
##   "hero"                 -> ProgressionState (its Hero slot)
##   a roster Mercenary id  -> that Mercenary's own Level / EXP (add_exp)
##   another ProgressionState slot (the C01-C08 fixture merc_a / merc_b)
##                          -> ProgressionState, as before
##   anything else          -> counted in the division, awarded nowhere
## The roster is checked before the fixture slots, so a roster instance whose
## id happens to be merc_a / merc_b never feeds the legacy slot.
## Shares: {id: {"exp", "from_level", "level", "leveled"}}.


## The shares `result` would award, without changing anything.
static func preview(result: BattleResult, progression: ProgressionState, roster: MercenaryRoster) -> Dictionary:
	var shares := {}
	if result == null or progression == null or result.outcome == BattleResult.Outcome.DEFEAT or result.exp_pool <= 0 or result.survivor_ids.is_empty():
		return shares
	var share := result.exp_pool / result.survivor_ids.size()
	if share <= 0:
		return shares
	for id in result.survivor_ids:
		var held := _held(id, progression, roster)
		if held.is_empty():
			continue
		var after := ProgressionState.advance(held[0], held[1], share)
		shares[id] = {"exp": share, "from_level": held[0], "level": after[0], "leveled": after[0] > held[0]}
	return shares


## Applies `result` (see preview()) and returns the same shares.
static func apply(result: BattleResult, progression: ProgressionState, roster: MercenaryRoster) -> Dictionary:
	var shares := preview(result, progression, roster)
	for id in shares:
		var mercenary := _mercenary(id, roster)
		if mercenary != null:
			mercenary.add_exp(int(shares[id]["exp"]))
		else:
			progression.award(id, int(shares[id]["exp"]))
	return shares


## [level, exp] currently held by `id`'s owner, or [] when nobody holds it.
static func _held(id: String, progression: ProgressionState, roster: MercenaryRoster) -> Array:
	var mercenary := _mercenary(id, roster)
	if mercenary != null:
		return [mercenary.get_level(), mercenary.get_exp()]
	if progression.get_level(id) > 0:
		return [progression.get_level(id), progression.get_exp(id)]
	return []


static func _mercenary(id: String, roster: MercenaryRoster) -> Mercenary:
	if roster == null or id == Mercenary.HERO_ID:
		return null
	return roster.get_mercenary(id)
