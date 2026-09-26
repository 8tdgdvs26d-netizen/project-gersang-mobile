extends SceneTree

## M2-07A: every player-visible label and button must be Traditional Chinese.
## Approved Latin in player text: the placeholder city codes A / B and the
## keyboard hint E. Brand metadata (project name), console logs, internal ids,
## comments and test names are developer-only and are not scanned.

const SCENES := [
	"res://scenes/main.tscn",
	"res://scenes/city_marker.tscn",
	"res://scenes/city_hub.tscn",
	"res://scenes/player.tscn",
	"res://scenes/obstacle.tscn",
	"res://scenes/touch_joystick.tscn",
]
const IDS := ["test_good_01", "test_good_02", "test_good_03", "test_good_04", "test_good_05", "test_good_06"]
const FAILURE_REASONS := ["insufficient_money", "insufficient_cargo_space", "insufficient_cargo", "insufficient_stock", "unknown_reason"]

var _checks := 0
var _failures := 0
var _latin := RegEx.new()
var _approved := RegEx.new()


func _initialize() -> void:
	_latin.compile("[A-Za-z]")
	# Standalone A / B (city codes) and E (key hint) are the only approved Latin.
	_approved.compile("(?<![A-Za-z])[ABE](?![A-Za-z])")
	_verify_scene_files()
	_verify_script_literals()
	await _verify_world_text()
	await _verify_city_text()

	if _failures == 0:
		print("M2-07A Traditional Chinese player text verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


# --- Static scans -------------------------------------------------------------------

func _verify_scene_files() -> void:
	var text_line := RegEx.new()
	text_line.compile("(?m)^text = \"(.*)\"$")
	var scanned := 0
	for path in SCENES:
		var source := FileAccess.get_file_as_string(path)
		_check(not source.is_empty(), "%s must be readable" % path)
		for found in text_line.search_all(source):
			scanned += 1
			var text := found.get_string(1)
			_check(_is_player_chinese(text), "%s text must be Traditional Chinese: \"%s\"" % [path, text])
	_check(scanned >= 10, "Scene scan must cover the world, marker and hub texts (%d found)" % scanned)


## Literal strings the scripts assign to player-visible text.
func _verify_script_literals() -> void:
	var assignment := RegEx.new()
	assignment.compile("\\.text = \"([^\"]*)\"")
	var scanned := 0
	for path in ["res://scripts/main.gd", "res://scripts/city_marker.gd", "res://scripts/city_hub.gd"]:
		var source := FileAccess.get_file_as_string(path)
		for found in assignment.search_all(source):
			scanned += 1
			var text := found.get_string(1).replace("%s", "").replace("%d", "")
			_check(_is_player_chinese(text), "%s must not assign English player text: \"%s\"" % [path, found.get_string(1)])
	_check(scanned >= 10, "Script scan must cover the marker and hub text assignments (%d found)" % scanned)
	for message in CityHub.FAILURE_MESSAGES.values() + [CityHub.GENERIC_FAILURE]:
		_check(_is_player_chinese(message), "Trade failure message must be Chinese: %s" % message)
	for good_id in IDS:
		var good_name: String = GoodsCatalog.get_good(good_id).get("display_name", "")
		_check(not good_name.is_empty() and _is_player_chinese(good_name), "%s display name must be Chinese" % good_id)


# --- Runtime scans --------------------------------------------------------------------

func _verify_world_text() -> void:
	var main := await _new_main()
	var title := main.get_node("Interface/Content/Status/Title") as Label
	var subtitle := main.get_node("Interface/Content/Status/Subtitle") as Label
	var scope := main.get_node("Interface/Content/Status/Scope") as Label
	var button := main.get_node("EnterControls/EnterCityButton") as Button
	_check(title.text == "《萬行誌：白手》", "World title must be the formal game name 《萬行誌：白手》 (%s)" % title.text)
	_check(subtitle.text == "開發原型：基本市場", "World subtitle must be Chinese (%s)" % subtitle.text)
	_check(scope.text == "走到 A 城或 B 城，按 E 或點「進入城市」", "World hint must be Chinese (%s)" % scope.text)
	_check(button.text == "進入城市", "Touch Enter City button must read 進入城市 (%s)" % button.text)
	for city in ["A", "B"]:
		var marker := _marker(main, city)
		_check(marker != null, "World must contain City %s" % city)
		if marker == null:
			continue
		var name_text: String = (marker.get_node("NameLabel") as Label).text
		var enter_text: String = (marker.get_node("EnterLabel") as Label).text
		_check(name_text == "%s 城（原型）" % city, "City %s marker name must read %s 城（原型） (%s)" % [city, city, name_text])
		_check(enter_text == "進入城市（E）", "City %s entry hint must read 進入城市（E） (%s)" % [city, enter_text])

	# Stand in City A so the entry hint and touch button are actually shown.
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS["A"]
	await _settle()
	await process_frame
	_check(button.visible and (_marker(main, "A").get_node("EnterLabel") as Label).visible, "Entry hint and button must be visible inside City A")
	var texts := _all_texts(main)
	_check(texts.size() >= 50, "World scan must include world, marker and hub nodes (%d texts)" % texts.size())
	_check(_all_chinese(texts, "world"), "All world labels and buttons must be Traditional Chinese")
	await _destroy(main)


func _verify_city_text() -> void:
	var main := await _new_main()
	var player := main.get_node("Actors/Player") as Player
	for city in ["A", "B"]:
		player.global_position = WorldLayout.CITY_ANCHORS[city]
		await _settle()
		_check(main.try_enter_city() and main.current_city_id == city, "Must enter City %s" % city)
		var hub := main.get_node("CityHub") as CityHub
		_check(hub.get_city_label_text() == "【%s 城】" % city, "Hub title must read 【%s 城】" % city)
		_check(_all_chinese(_all_texts(main), "City %s hub" % city), "City %s hub must be Traditional Chinese" % city)
		hub.get_market_button("test_good_01", "buy").pressed.emit()
		_check(_is_player_chinese(hub.get_feedback_text()) and not hub.get_feedback_text().is_empty(), "Buy feedback must be Chinese")
		hub.get_market_button("test_good_01", "sell").pressed.emit()
		_check(_is_player_chinese(hub.get_feedback_text()) and not hub.get_feedback_text().is_empty(), "Sell feedback must be Chinese")
		for reason in FAILURE_REASONS:
			hub.show_trade_feedback("buy", "test_good_01", 1, {"success": false, "reason": reason})
			_check(_is_player_chinese(hub.get_feedback_text()), "Failure feedback for %s must be Chinese (%s)" % [reason, hub.get_feedback_text()])
		_check(_all_chinese(_all_texts(main), "City %s hub after trades" % city), "City %s hub must stay Chinese after trades" % city)
		_check(main.leave_city(), "Must leave City %s" % city)
	await _destroy(main)


# --- Helpers ------------------------------------------------------------------------------

func _is_player_chinese(text: String) -> bool:
	return _latin.search(_approved.sub(text, "", true)) == null


func _all_texts(node: Node) -> Array:
	var texts := []
	for control in node.find_children("*", "Label", true, false) + node.find_children("*", "Button", true, false):
		texts.append(str((control as Control).get("text")))
	return texts


func _all_chinese(texts: Array, where: String) -> bool:
	var ok := true
	for text in texts:
		if not _is_player_chinese(text):
			push_error("English player text in %s: %s" % [where, text])
			ok = false
	return ok


func _marker(main: Node, city: String) -> CityMarker:
	for child in main.find_children("*", "CityMarker", true, false):
		if (child as CityMarker).city_id == city:
			return child
	return null


func _new_main() -> Node2D:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = ""
	root.add_child(main)
	await _settle()
	return main


func _destroy(main: Node) -> void:
	root.remove_child(main)
	main.free()
	await process_frame


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
