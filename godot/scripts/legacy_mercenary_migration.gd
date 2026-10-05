class_name LegacyMercenaryMigration
extends RefCounted

## Stage 8 P05 (approved plan, Q1 / Q3 / Q4): converts the Stage 7 fixed Merc
## A / Merc B of a valid v1-v11 save into roster Mercenaries. Pure rules, no
## file access; SaveStore runs it while loading a v1-v11 save (in memory: the
## file becomes v12 at the next normal save, and a v12 save never runs it).
##   - always both, merc_a first, then merc_b, whatever their growth
##   - merc_a -> GUARDIAN, merc_b -> MAGE, keeping the legacy stable ids and
##     exactly their saved Level, EXP and allocation (v1-v8: Lv1, 0 EXP, no
##     points; v9: Level / EXP, no points; v10 / v11: all three)
##   - into a free owned place (MercenaryRoster.MAX_OWNED never passed), else
##     into the pending list; never deployed; next_serial untouched
##   - a v11 roster already owning merc_a / merc_b: identical data (type,
##     Level, EXP, allocation) counts as already converted; any difference
##     refuses the whole save (nothing is picked, merged or overwritten)

const ORDER := ["merc_a", "merc_b"]


## `levels`: {merc_a: [level, exp], merc_b: [level, exp]} (validated);
## `allocation`: {merc_a: {hp, str, agi, int}, merc_b: ...} (validated against
## those Levels); `roster`: the save's roster (changed in place).
## Returns {"owned": [ids added to owned], "pending": [ids put in pending]},
## or {} when the save must be refused (a conflict or an invalid entry; the
## roster may then be partly changed and must be discarded).
static func migrate(levels: Dictionary, allocation: Dictionary, roster: MercenaryRoster) -> Dictionary:
	var report := {"owned": [], "pending": []}
	if roster == null:
		return {}
	for id in ORDER:
		if not levels.has(id) or not allocation.has(id):
			return {}
		var converted := Mercenary.create(id, MercenaryRoster.LEGACY_TYPES[id], levels[id][0], levels[id][1], allocation[id])
		if converted == null:
			return {}
		var existing := roster.get_mercenary(id)
		if existing != null:
			if existing.to_dict() != converted.to_dict():
				return {}
			continue
		if not roster.is_full():
			if not roster.add(converted):
				return {}
			report["owned"].append(id)
		else:
			if not roster.pend_legacy(converted):
				return {}
			report["pending"].append(id)
	return report
