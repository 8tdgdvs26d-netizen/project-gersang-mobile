extends SceneTree

const APPROVED_GOODS := [
	["test_good_01", "測試商品一", 1, 100],
	["test_good_02", "測試商品二", 1, 250],
	["test_good_03", "測試商品三", 2, 500],
	["test_good_04", "測試商品四", 2, 1000],
	["test_good_05", "測試商品五", 3, 2000],
	["test_good_06", "測試商品六", 4, 4000],
]
const INVALID_IDS := ["", "test_good_07", "TEST_GOOD_01", "unknown", null, 1, 3.5]
const INVALID_QUANTITIES := [0, -1, -20, 1.5, NAN, INF, "2", null]
const STRESS_STEPS := 600

var _checks := 0
var _failures := 0


func _initialize() -> void:
	_verify_catalog()
	_verify_cargo_basics()
	_verify_cargo_add_rules()
	_verify_cargo_remove_rules()
	_verify_multi_goods()
	_verify_stress()
	await _verify_transitions()

	if _failures == 0:
		print("M2-03 six goods and cargo verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Goods -----------------------------------------------------------------

func _verify_catalog() -> void:
	var ids := GoodsCatalog.get_ids()
	_check(GoodsCatalog.GOODS.size() == 6 and ids.size() == 6, "Catalog must hold exactly 6 goods")
	var unique := {}
	for good_id in ids:
		unique[good_id] = true
	_check(unique.size() == 6, "All 6 good ids must be unique")

	for index in range(APPROVED_GOODS.size()):
		var approved: Array = APPROVED_GOODS[index]
		var good := GoodsCatalog.get_good(approved[0])
		_check(ids[index] == approved[0], "Good %d must be %s" % [index + 1, approved[0]])
		_check(good.get("display_name") == approved[1], "%s display name must be %s" % [approved[0], approved[1]])
		_check(typeof(good.get("unit_size")) == TYPE_INT and good["unit_size"] > 0, "%s unit size must be a positive int" % approved[0])
		_check(typeof(good.get("base_value")) == TYPE_INT and good["base_value"] > 0, "%s base value must be a positive int" % approved[0])
		_check(good["unit_size"] == approved[2] and good["base_value"] == approved[3], "%s must match the approved test values" % approved[0])
		_check(GoodsCatalog.get_unit_size(approved[0]) == approved[2], "%s unit size lookup must match" % approved[0])

	for invalid_id in INVALID_IDS:
		_check(not GoodsCatalog.has_good(invalid_id), "Unknown good %s must be rejected" % str(invalid_id))
		_check(GoodsCatalog.get_good(invalid_id).is_empty(), "Unknown good %s lookup must be empty" % str(invalid_id))
		_check(GoodsCatalog.get_unit_size(invalid_id) == 0, "Unknown good %s unit size must be 0" % str(invalid_id))

	var copy := GoodsCatalog.get_good("test_good_06")
	copy["unit_size"] = 1
	_check(GoodsCatalog.get_unit_size("test_good_06") == 4, "Catalog lookups must return copies")

	var cargo_source := FileAccess.get_file_as_string("res://scripts/cargo.gd")
	_check(not cargo_source.contains("test_good_0"), "Cargo logic must not hardcode good ids")


# --- Cargo -----------------------------------------------------------------

func _verify_cargo_basics() -> void:
	var cargo := Cargo.new()
	_check(Cargo.CARGO_CAPACITY == 20, "Cargo capacity must be 20")
	_check(cargo.is_empty() and cargo.get_items().is_empty(), "New cargo must be empty")
	_check(cargo.get_used_capacity() == 0, "New cargo used capacity must be 0")
	_check(cargo.get_remaining_capacity() == 20, "New cargo remaining capacity must be 20")
	_check(cargo.get_quantity("test_good_01") == 0, "Missing good quantity must be 0")


func _verify_cargo_add_rules() -> void:
	var cargo := Cargo.new()
	_check(cargo.can_add("test_good_03", 5) and cargo.add("test_good_03", 5), "Adding 5 x good 3 must succeed")
	_check(cargo.get_quantity("test_good_03") == 5, "Good 3 quantity must be 5")
	_check(cargo.get_used_capacity() == 10, "5 x good 3 (size 2) must use 10 units")
	_check(cargo.get_remaining_capacity() == 10, "Remaining capacity must be 10")

	_check(cargo.add("test_good_03", 1) and cargo.get_quantity("test_good_03") == 6, "Adding the same good must stack")
	_check(cargo.get_used_capacity() == 12, "Stacked good 3 must use 12 units")
	_check(cargo.add("test_good_01", 2) and cargo.get_items().size() == 2, "Adding a second good must create a second entry")
	_check(cargo.get_used_capacity() == 14, "Mixed sizes must sum: 6x2 + 2x1 = 14")

	_check(cargo.add("test_good_05", 2), "Filling exactly to capacity must succeed")
	_check(cargo.get_used_capacity() == 20 and cargo.get_remaining_capacity() == 0, "Cargo must be exactly full")

	var full := cargo.get_items()
	_check(not cargo.can_add("test_good_01", 1) and not cargo.add("test_good_01", 1), "Exceeding capacity by 1 unit must fail")
	_check(cargo.get_items() == full and cargo.get_used_capacity() == 20, "Failed add must leave cargo unchanged")

	var partial := Cargo.new()
	partial.add("test_good_06", 4)
	var before := partial.get_items()
	_check(not partial.add("test_good_06", 2), "Adding 8 units into 4 remaining must fail")
	_check(partial.add("test_good_06", 1) and partial.get_used_capacity() == 20, "Adding exactly the remaining 4 units must succeed")
	_check(before == {"test_good_06": 4}, "Snapshot must not be affected by later adds")

	var guarded := Cargo.new()
	guarded.add("test_good_02", 3)
	var snapshot := guarded.get_items()
	for invalid_id in INVALID_IDS:
		_check(not guarded.can_add(invalid_id, 1) and not guarded.add(invalid_id, 1), "Adding invalid good %s must fail" % str(invalid_id))
	for invalid_quantity in INVALID_QUANTITIES:
		_check(not guarded.add("test_good_02", invalid_quantity), "Adding quantity %s must fail" % str(invalid_quantity))
	_check(not guarded.add("test_good_01", 1_000_000_000_000), "Huge quantity must fail without overflow")
	_check(guarded.get_items() == snapshot and guarded.get_used_capacity() == 3, "Rejected adds must leave cargo unchanged")

	var external := guarded.get_items()
	external["test_good_02"] = -5
	_check(guarded.get_quantity("test_good_02") == 3, "Returned items must be a copy")


func _verify_cargo_remove_rules() -> void:
	var cargo := Cargo.new()
	cargo.add("test_good_04", 5)
	cargo.add("test_good_02", 2)
	_check(cargo.can_remove("test_good_04", 2) and cargo.remove("test_good_04", 2), "Removing a valid quantity must succeed")
	_check(cargo.get_quantity("test_good_04") == 3, "Good 4 quantity must drop to 3")
	_check(cargo.get_used_capacity() == 8 and cargo.get_remaining_capacity() == 12, "Removing must release capacity")

	_check(cargo.remove("test_good_04", 3), "Removing the rest must succeed")
	_check(not cargo.get_items().has("test_good_04"), "Removing to 0 must delete the entry")
	_check(cargo.get_quantity("test_good_04") == 0, "Removed good quantity must be 0")

	var snapshot := cargo.get_items()
	_check(not cargo.can_remove("test_good_02", 3) and not cargo.remove("test_good_02", 3), "Removing more than held must fail")
	_check(not cargo.remove("test_good_04", 1), "Removing a good not held must fail")
	for invalid_id in INVALID_IDS:
		_check(not cargo.remove(invalid_id, 1), "Removing invalid good %s must fail" % str(invalid_id))
	for invalid_quantity in INVALID_QUANTITIES:
		_check(not cargo.remove("test_good_02", invalid_quantity), "Removing quantity %s must fail" % str(invalid_quantity))
	_check(cargo.get_items() == snapshot and cargo.get_used_capacity() == 2, "Rejected removes must leave cargo unchanged")

	cargo.clear()
	_check(cargo.is_empty() and cargo.get_used_capacity() == 0 and cargo.get_remaining_capacity() == 20, "Clear must reset cargo")
	_check(_invariants_hold(cargo), "Cargo must keep no zero or negative entries")


func _verify_multi_goods() -> void:
	var cargo := Cargo.new()
	for good_id in GoodsCatalog.get_ids():
		_check(cargo.add(good_id, 1), "Adding one %s must succeed" % good_id)
	_check(cargo.get_items().size() == 6, "Cargo must hold all 6 goods at once")
	_check(cargo.get_used_capacity() == 13, "One of each good must use 1+1+2+2+3+4 = 13 units")
	_check(cargo.add("test_good_01", 7) and cargo.get_used_capacity() == 20, "Topping up with 7 x good 1 must fill to 20")
	_check(not cargo.add("test_good_06", 1), "A size-4 good must not fit in a full cargo")

	var sizes := Cargo.new()
	_check(sizes.add("test_good_06", 3) and sizes.get_used_capacity() == 12, "3 x size 4 must use 12 units")
	_check(not sizes.add("test_good_05", 3), "3 x size 3 (9 units) must not fit into 8 remaining")
	_check(sizes.add("test_good_05", 2) and sizes.get_remaining_capacity() == 2, "2 x size 3 must leave 2 units")
	_check(sizes.add("test_good_03", 1) and sizes.get_used_capacity() == 20, "1 x size 2 must fill the last 2 units")
	_check(_invariants_hold(sizes) and _invariants_hold(cargo), "Mixed cargo must keep invariants")


## Deterministic property test against an independent reference model.
func _verify_stress() -> void:
	var cargo := Cargo.new()
	var model := {}
	var ids := GoodsCatalog.get_ids() + ["bad_good", ""]
	var quantities := [-2, -1, 0, 1, 1, 1, 2, 2, 3, 21]
	var seed := 20260925
	var mismatches := 0
	var invariant_breaks := 0
	var counts := {"add_ok": 0, "add_rejected": 0, "remove_ok": 0, "remove_rejected": 0, "full": 0}
	for step in range(STRESS_STEPS):
		# Fixed-seed LCG; the high bits drive each choice.
		seed = (seed * 1103515245 + 12345) % 2147483648
		var bits := seed >> 8
		var good_id: String = ids[bits % ids.size()]
		var quantity: int = quantities[(bits >> 4) % quantities.size()]
		var action := (bits >> 8) % 20
		var expected := false
		var actual := false
		if action == 19:
			cargo.clear()
			model.clear()
			expected = true
			actual = true
		elif action < 10:
			expected = _model_add(model, good_id, quantity)
			actual = cargo.add(good_id, quantity)
			counts["add_ok" if actual else "add_rejected"] += 1
		else:
			# Mostly remove goods actually held so removals often succeed.
			if not model.is_empty() and (bits >> 13) % 4 != 0:
				var held := model.keys()
				held.sort()
				good_id = held[(bits >> 15) % held.size()]
			expected = _model_remove(model, good_id, quantity)
			actual = cargo.remove(good_id, quantity)
			counts["remove_ok" if actual else "remove_rejected"] += 1
		if actual != expected or cargo.get_items() != model:
			mismatches += 1
		if not _invariants_hold(cargo) or cargo.get_used_capacity() != _model_used(model):
			invariant_breaks += 1
		if cargo.get_used_capacity() == Cargo.CARGO_CAPACITY:
			counts["full"] += 1
	_check(mismatches == 0, "Stress: cargo must match the reference model on all %d steps (%d mismatches)" % [STRESS_STEPS, mismatches])
	_check(invariant_breaks == 0, "Stress: invariants must hold on every step (%d breaks)" % invariant_breaks)
	_check(counts["add_ok"] >= 50 and counts["remove_ok"] >= 50, "Stress: sequence must exercise successful adds and removes %s" % str(counts))
	_check(counts["add_rejected"] >= 50 and counts["remove_rejected"] >= 50, "Stress: sequence must exercise rejected adds and removes %s" % str(counts))
	_check(counts["full"] >= 10, "Stress: sequence must reach full capacity %s" % str(counts))
	print("M2-03 stress counts: ", counts)


func _model_add(model: Dictionary, good_id: String, quantity: int) -> bool:
	var size: int = {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}.get(good_id, 0)
	if size == 0 or quantity <= 0 or _model_used(model) + quantity * size > 20:
		return false
	model[good_id] = model.get(good_id, 0) + quantity
	return true


func _model_remove(model: Dictionary, good_id: String, quantity: int) -> bool:
	if quantity <= 0 or model.get(good_id, 0) < quantity:
		return false
	model[good_id] -= quantity
	if model[good_id] == 0:
		model.erase(good_id)
	return true


func _model_used(model: Dictionary) -> int:
	var sizes := {"test_good_01": 1, "test_good_02": 1, "test_good_03": 2, "test_good_04": 2, "test_good_05": 3, "test_good_06": 4}
	var used := 0
	for good_id in model:
		used += model[good_id] * sizes[good_id]
	return used


func _invariants_hold(cargo: Cargo) -> bool:
	var recomputed := 0
	for good_id in cargo.get_items():
		var quantity = cargo.get_items()[good_id]
		if not GoodsCatalog.has_good(good_id) or typeof(quantity) != TYPE_INT or quantity <= 0:
			return false
		recomputed += quantity * GoodsCatalog.get_unit_size(good_id)
	var used := cargo.get_used_capacity()
	return used == recomputed and used >= 0 and used <= Cargo.CARGO_CAPACITY \
		and cargo.get_remaining_capacity() == Cargo.CARGO_CAPACITY - used


# --- Transitions -----------------------------------------------------------

func _verify_transitions() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = ""  # M2-06: keep this test away from the player's real save file
	root.add_child(main)
	await _settle()
	var player := main.get_node("Actors/Player") as Player
	var hub := main.get_node("CityHub") as CityHub

	_check(WorldLayout.WORLD_SIZE == Vector2(40000.0, 40000.0), "World size must be unchanged")
	_check(WorldLayout.CITY_A == Vector2(200.0, 200.0) and WorldLayout.CITY_B == Vector2(39800.0, 200.0), "City anchors must be unchanged")
	_check(player.move_speed == 220.0, "Movement speed must be unchanged")

	var cargo := main.cargo as Cargo
	_check(cargo != null and cargo.is_empty(), "Session cargo must exist and start empty")
	_check(cargo.add("test_good_03", 2) and cargo.add("test_good_06", 1), "Session cargo must accept goods")
	var expected := {"test_good_03": 2, "test_good_06": 1}

	player.global_position = WorldLayout.CITY_A
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == "A", "Must enter City A")
	_check(main.cargo == cargo and cargo.get_items() == expected, "Cargo must remain after entering City A")
	_check(hub.get_cargo_label_text() == "貨物容量：8 / 20", "City A hub must show the cargo debug summary")
	_check(main.leave_city(), "Must leave City A")
	_check(main.cargo == cargo and cargo.get_items() == expected, "Cargo must remain after leaving City A")
	await _settle()

	player.global_position = WorldLayout.CITY_B
	await _settle()
	_check(main.try_enter_city() and main.current_city_id == "B", "Must enter City B")
	_check(main.cargo == cargo and cargo.get_items() == expected, "Cargo must remain after entering City B")
	_check(hub.get_city_label_text() == "【B 城】" and hub.get_cargo_label_text() == "貨物容量：8 / 20", "City B hub must show B and the same cargo")
	_check(main.leave_city(), "Must leave City B")
	_check(main.cargo == cargo and cargo.get_items() == expected and cargo.get_used_capacity() == 8, "Cargo must remain after leaving City B")
	_check(player.global_position == WorldLayout.CITY_RETURN_POINTS["B"], "City Hub return point must be unchanged")
	await _settle()
	_check(not main.is_in_city() and player.is_physics_processing(), "World must be restored after the transitions")


func _settle() -> void:
	# Area2D overlaps update a few physics frames after a teleport.
	for frame in range(4):
		await physics_frame
	await process_frame


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
