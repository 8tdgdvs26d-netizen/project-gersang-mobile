class_name GoodsCatalog
extends RefCounted

## Single data source for the six Stage 2 prototype goods.
## All values are TEST VALUES for automated verification, not a formal
## economy balance. Display names are player-facing Traditional Chinese
## placeholders (測試商品一 … 六); formal names and prices are decided later.

const GOODS := [
	{"id": "test_good_01", "display_name": "測試商品一", "unit_size": 1, "base_value": 100},
	{"id": "test_good_02", "display_name": "測試商品二", "unit_size": 1, "base_value": 250},
	{"id": "test_good_03", "display_name": "測試商品三", "unit_size": 2, "base_value": 500},
	{"id": "test_good_04", "display_name": "測試商品四", "unit_size": 2, "base_value": 1000},
	{"id": "test_good_05", "display_name": "測試商品五", "unit_size": 3, "base_value": 2000},
	{"id": "test_good_06", "display_name": "測試商品六", "unit_size": 4, "base_value": 4000},
]


static func get_ids() -> Array:
	var ids := []
	for good in GOODS:
		ids.append(good["id"])
	return ids


static func has_good(good_id: Variant) -> bool:
	return not get_good(good_id).is_empty()


## Returns a copy of the good's data, or an empty Dictionary for unknown ids.
static func get_good(good_id: Variant) -> Dictionary:
	if typeof(good_id) != TYPE_STRING:
		return {}
	for good in GOODS:
		if good["id"] == good_id:
			return good.duplicate()
	return {}


## Returns the good's unit size, or 0 for unknown ids.
static func get_unit_size(good_id: Variant) -> int:
	return get_good(good_id).get("unit_size", 0)
