extends SceneTree

## iOS Traditional Chinese font fix: every player-visible string must be drawn
## by the bundled Noto Sans TC font, which must contain every glyph used.
## The font's system fallback is disabled, so desktop runs cannot hide a
## missing glyph that would show as a square on iPhone.

const FONT_PATH := "res://fonts/NotoSansTC-Regular.otf"
## Project default UI font: the bundled font with 1px tighter line spacing so
## the taller CJK line height keeps the existing portrait layout.
const UI_FONT_PATH := "res://fonts/ui_font.tres"
const LICENSE_PATH := "res://fonts/OFL.txt"
const SCAN_DIRS := ["res://scripts", "res://scenes"]
## Words the physical iPhone check must show (brief acceptance list).
const ACCEPTANCE_WORDS := ["A 城", "B 城", "市場", "交通", "金錢", "攜帶容量", "貨物容量", "測試商品一", "測試商品二", "測試商品三", "測試商品四", "測試商品五", "測試商品六", "買入", "賣出", "車費", "預計時間", "乘搭", "離開城市", "旅途中", "前往", "預計抵達", "《萬行誌：白手》", "10000", "0 / 20", "E"]

var _checks := 0
var _failures := 0
var _font: FontFile


func _initialize() -> void:
	_verify_configuration()
	_verify_glyph_coverage()
	await _verify_runtime_controls()
	if _failures == 0:
		print("Traditional Chinese font verification passed (%d checks)" % _checks)
	quit(1 if _failures > 0 else 0)


func _verify_configuration() -> void:
	_check(ProjectSettings.get_setting("gui/theme/custom_font", "") == UI_FONT_PATH, "The project default UI font must be the bundled UI font")
	var ui_font := load(UI_FONT_PATH) as FontVariation
	_check(ui_font != null and ui_font.base_font != null and ui_font.base_font.resource_path == FONT_PATH, "The UI font must be a variation of the bundled Noto Sans TC")
	if ui_font != null:
		_check(ui_font.get_spacing(TextServer.SPACING_TOP) == -1 and ui_font.get_spacing(TextServer.SPACING_BOTTOM) == -1 and ui_font.get_spacing(TextServer.SPACING_GLYPH) == 0, "The UI font may only tighten line spacing by 1px")
	_check(FileAccess.file_exists(FONT_PATH) or ResourceLoader.exists(FONT_PATH), "The font must be bundled in the project")
	_check(FileAccess.file_exists(LICENSE_PATH) and FileAccess.get_file_as_string(LICENSE_PATH).contains("SIL Open Font License"), "The font licence (OFL) must be bundled next to it")
	_font = load(FONT_PATH) as FontFile
	_check(_font != null, "The bundled font must load as a FontFile")
	if _font != null:
		_check(not _font.allow_system_fallback, "System font fallback must be off so coverage is really bundled")
		_check(not _font.has_char(0xE000), "Sanity: the coverage check must be able to fail (private-use U+E000)")


## Every character inside string literals of scripts and scenes, plus the
## acceptance words, must exist in the bundled font.
func _verify_glyph_coverage() -> void:
	if _font == null:
		return
	var literal := RegEx.new()
	literal.compile("\"((?:[^\"\\\\\\n]|\\\\.)*)\"")
	var chars := {}
	var files := 0
	for dir in SCAN_DIRS:
		for file_name in DirAccess.get_files_at(dir):
			if not (file_name.ends_with(".gd") or file_name.ends_with(".tscn")):
				continue
			files += 1
			for line in FileAccess.get_file_as_string(dir + "/" + file_name).split("\n"):
				if line.strip_edges().begins_with("#"):
					continue
				for found in literal.search_all(line):
					for character in found.get_string(1):
						chars[character] = true
	for word in ACCEPTANCE_WORDS:
		for character in word:
			chars[character] = true
	for code in range(0x20, 0x7F):
		chars[char(code)] = true
	var cjk := 0
	var missing := []
	for character in chars:
		var code: int = character.unicode_at(0)
		if code >= 0x2E80:
			cjk += 1
		if not _font.has_char(code):
			missing.append("%s(U+%04X)" % [character, code])
	_check(files >= 10 and cjk >= 100, "The scan must cover the UI sources (%d files, %d CJK characters)" % [files, cjk])
	_check(missing.is_empty(), "Every player-visible character must be in the bundled font; missing: %s" % str(missing))


## Labels and buttons across world, hub, transport and journey must resolve
## to the bundled font through the project default, with no per-node fonts.
func _verify_runtime_controls() -> void:
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	main.save_path = ""
	main.time_source = TimeSource.fixed(1800000000000)
	root.add_child(main)
	for frame in range(4):
		await physics_frame
	await process_frame
	var player := main.get_node("Actors/Player") as Player
	player.global_position = WorldLayout.CITY_ANCHORS["A"]
	for frame in range(4):
		await physics_frame
	await process_frame
	var screens := {"world": _controls(main)}
	_check(main.try_enter_city(), "Must enter City A")
	var hub := main.get_node("CityHub") as CityHub
	screens["market"] = _controls(main)
	hub.show_facility("transport")
	screens["transport"] = _controls(main)
	hub.get_transport_button("B").pressed.emit()
	screens["journey"] = _controls(main)
	for screen in screens:
		var wrong := []
		for control in screens[screen]:
			var font := (control as Control).get_theme_font("font")
			if font == null or font.resource_path != UI_FONT_PATH:
				wrong.append(str(control.name))
			if (control as Control).has_theme_font_override("font"):
				wrong.append(str(control.name) + " (per-node override)")
		_check(screens[screen].size() >= 3 and wrong.is_empty(), "%s: every label/button must use the bundled font %s" % [screen, str(wrong)])
		var missing := []
		for control in screens[screen]:
			for character in str(control.get("text")):
				if not _font.has_char(character.unicode_at(0)):
					missing.append(character)
		_check(missing.is_empty(), "%s: all displayed text must be covered by the bundled font %s" % [screen, str(missing)])
	root.remove_child(main)
	main.free()
	await process_frame


func _controls(node: Node) -> Array:
	return node.find_children("*", "Label", true, false) + node.find_children("*", "Button", true, false)


func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("FAILED: " + message)
