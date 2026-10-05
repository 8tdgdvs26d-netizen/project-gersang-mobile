class_name CityHub
extends CanvasLayer

## Shared prototype City Hub overlay used by every active city, with four
## minimal facilities (market, passenger transport, the city's own item
## warehouse and, Stage 8 P02, the Mercenary Center) and a traveling view
## shown during a journey. The hub only displays the quotes and state it is
## given and forwards button presses as requests; every trade and journey runs
## in main.gd. All player-facing text here is Traditional Chinese.

signal leave_requested
## Market orders carry their size: 1 or 10 (the trade domain enforces the rule).
signal buy_requested(good_id: String, quantity: int)
signal sell_requested(good_id: String, quantity: int)
signal transport_requested(destination_city_id: String, request_id: String)
signal facility_changed(facility: String)
## Transfer requests carry the city whose warehouse is shown, so the domain
## (WarehouseService) rejects anything that is not the character's city.
signal deposit_requested(city_id: String, item_id: String, request_id: String)
signal withdraw_requested(city_id: String, item_id: String, request_id: String)
signal warehouse_city_selected(city_id: String)
## Stage 8 P02: a 招聘 press (the recruitment itself runs in main.gd).
signal recruit_requested(type: String)
## Stage 8 P03: 設為出戰 / 取消出戰 and a confirmed 解僱 (run in main.gd).
signal deployment_requested(mercenary_id: String, deployed: bool)
signal dismiss_requested(mercenary_id: String)
## Stage 8 P05: 領取 pressed on a pending legacy Mercenary.
signal claim_requested(mercenary_id: String)
## Stage 9 P02: buy one `item_id` for the character `character_id` (stable id).
signal equipment_buy_requested(character_id: String, item_id: String)
## Stage 10 P02: 醫院 — the Hero's free recovery, and the chosen Mercenaries'
## paid recovery (stable ids).
signal hospital_hero_requested
signal hospital_recover_requested(mercenary_ids: Array)

const FACILITY_MARKET := "market"
const FACILITY_TRANSPORT := "transport"
const FACILITY_WAREHOUSE := "warehouse"
const FACILITY_MERCENARY := "mercenary"
## Stage 9 P02: 裝備商店. Stage 10 P02 (approved option A): the six facility
## tabs share one row: 112 x 64 each, 8 px apart, font 24, labels never cut
## (six 128 px tabs cannot fit in 720).
const FACILITY_EQUIPMENT := "equipment"
## Stage 10 P02: 醫院, only in a city with a Hospital
## (WorldLayout.city_has_hospital).
const FACILITY_HOSPITAL := "hospital"
const FACILITIES := [FACILITY_MARKET, FACILITY_TRANSPORT, FACILITY_WAREHOUSE, FACILITY_MERCENARY, FACILITY_EQUIPMENT, FACILITY_HOSPITAL]
## Stage 10 P02: 醫院 texts (RecoveryService decides who needs recovery and
## the prices; the hub only shows them and passes stable ids back).
const HOSPITAL_NOTE := "開發原型：主角治療免費；每名傭兵治療 $%s（不論傷勢）"
const HOSPITAL_HERO_BUTTON_TEXT := "免費恢復"
const HOSPITAL_SELECT_TEXT := "選擇"
const HOSPITAL_SELECTED_TEXT := "已選擇"
const HOSPITAL_CONFIRM_TEXT := "確認治療"
const HOSPITAL_HP_MP_TEXT := "血量 %d / %d　魔力 %d / %d"
const HOSPITAL_DEAD_TEXT := "【陣亡】需要復活"
const HOSPITAL_HURT_TEXT := "【受傷】需要治療"
const HOSPITAL_HEALTHY_TEXT := "【狀態良好】無需治療"
const HOSPITAL_FREE_TEXT := "治療費用：免費"
const HOSPITAL_PRICE_TEXT := "治療費用：$%s"
const HOSPITAL_NO_PRICE_TEXT := "治療費用：不需要"
const HOSPITAL_NO_MERCENARY_TEXT := "尚未持有傭兵"
const HOSPITAL_SUMMARY_TEXT := "已選傭兵 %d 名　合計 $%s　持有金錢 $%s"
const HOSPITAL_SHORT_TEXT := "持有金錢不足，請減少選擇的傭兵"
const HOSPITAL_HERO_SUCCESS_TEXT := "主角已完全恢復"
const HOSPITAL_SUCCESS_TEXT := "已恢復 %d 名傭兵，費用 $%s"
const HOSPITAL_FAILURE_MESSAGES := {
	"ERR_INSUFFICIENT_FUNDS": HOSPITAL_SHORT_TEXT,
	"ERR_NOTHING_TO_RECOVER": "沒有需要治療的角色",
	"ERR_NOT_NEEDED": "選擇已更新，請重新選擇",
	"ERR_UNKNOWN_MERCENARY": "選擇已更新，請重新選擇",
	"ERR_DUPLICATE": "選擇已更新，請重新選擇",
	"ERR_HERO_SELECTED": "選擇已更新，請重新選擇",
	"ERR_INVALID_REQUEST": "選擇已更新，請重新選擇",
	"ERR_SAVE_FAILED": "無法儲存，治療已取消",
	"ERR_IN_COMBAT": "戰鬥中無法治療",
	"ERR_NO_HOSPITAL": "此城市沒有醫院",
}
const HOSPITAL_GENERIC_FAILURE := "治療失敗"
const HOSPITAL_ROW_BUTTON_SIZE := Vector2(160, 88)
const HOSPITAL_INFO_WIDTH := 440.0
## The Mercenary list scrolls past this height (five rows fit on 720 x 1280).
const HOSPITAL_SCROLL_MAX_HEIGHT := 560.0
## Stage 8 P02: Mercenary Center (傭兵中心) texts. Types, names, role lines
## and the price come from RecruitmentService.
const MERCENARY_NOTE := "開發原型：每名傭兵 $1,000；同一類型可重複招聘"
## Stage 9 P02: 裝備商店 texts (EquipmentCatalog gives names, slots, weights
## and bonuses; EquipmentShopService the prices).
const EQUIPMENT_NOTE := "開發原型：每次購買 1 件，放入所選角色的背包（不會自動裝備）"
const EQUIPMENT_DETAIL_TEXT := "重量 %d　價格 $%s"
const EQUIPMENT_BUY_TEXT := "購買"
const EQUIPMENT_RECIPIENT_TEXT := "收件角色：%s"
const EQUIPMENT_RECIPIENT_LOAD_TEXT := "背包容量：%d / %d"
const EQUIPMENT_PREVIOUS_TEXT := "上一位"
const EQUIPMENT_NEXT_TEXT := "下一位"
const EQUIPMENT_SUCCESS_TEXT := "已購買%s，放入%s的背包"
const EQUIPMENT_FAILURE_MESSAGES := {
	"ERR_INSUFFICIENT_FUNDS": "金錢不足",
	"ERR_INSUFFICIENT_CAPACITY": "%s的背包容量不足",
	"ERR_UNKNOWN_CHARACTER": "找不到此角色",
	"ERR_UNKNOWN_EQUIPMENT": "裝備無效",
	"ERR_SAVE_FAILED": "無法儲存，購買已取消",
	"ERR_NOT_IN_CITY": "需要在城市內購買",
}
const EQUIPMENT_GENERIC_FAILURE := "購買失敗"
## The recipient chosen first: the Hero's stable id (display data only; the
## hub never holds the roster model).
const EQUIPMENT_DEFAULT_RECIPIENT := "hero"
const MERCENARY_COUNT_TEXT := "持有傭兵：%d / %d"
const MERCENARY_NONE_TEXT := "尚未持有傭兵"
const MERCENARY_PRICE_TEXT := "招聘費用：$%s"
const RECRUIT_BUTTON_TEXT := "招聘"
const RECRUIT_BUTTON_SIZE := Vector2(140, 96)
const RECRUIT_INFO_WIDTH := 480.0
const RECRUIT_SUCCESS_TEXT := "成功招聘%s"
const RECRUIT_FAILURE_MESSAGES := {
	"ERR_INSUFFICIENT_FUNDS": "金錢不足",
	"ERR_ROSTER_FULL": "傭兵人數已達上限",
	"ERR_INVALID_TYPE": "傭兵類型無效",
	"ERR_RECRUIT_FAILED": "招聘失敗",
	"ERR_SAVE_FAILED": "無法儲存，招聘已取消",
	"ERR_NOT_IN_CITY": "需要在城市內招聘",
}
const RECRUIT_GENERIC_FAILURE := "招聘失敗"
## Stage 8 P03: the owned roster, deployment and dismissal (texts only; the
## rules live in PartyService).
const MERCENARY_VIEW_RECRUIT := "recruit"
const MERCENARY_VIEW_ROSTER := "roster"
const RECRUIT_VIEW_TEXT := "招聘"
const ROSTER_VIEW_TEXT := "我的傭兵"
const DEPLOYED_COUNT_TEXT := "出戰傭兵：%d / %d"
const DEPLOY_TEXT := "設為出戰"
const UNDEPLOY_TEXT := "取消出戰"
const DISMISS_TEXT := "解僱"
const ROSTER_ROW_INFO_WIDTH := 420.0
const ROSTER_BUTTON_SIZE := Vector2(124, 88)
const DISMISS_BUTTON_SIZE := Vector2(100, 88)
const DISMISS_CONFIRM_TITLE := "確定解僱%s？"
const DISMISS_CONFIRM_NOTE := "解僱後無法復原，亦不會退還招聘費用。"
const DISMISS_CANCEL_TEXT := "取消"
const DISMISS_CONFIRM_TEXT := "確定解僱"
## Stage 8 iPhone L3 corrective (Charlie-approved): 確定解僱 waits a 5 s
## safety countdown each time the confirmation opens (確定解僱（5）…（1）,
## disabled); 取消 is always available.
const DISMISS_COUNTDOWN_SECONDS := 5.0
const DISMISS_COUNTDOWN_TEXT := "確定解僱（%d）"
const DEPLOY_SUCCESS_TEXT := "%s已設為出戰"
const UNDEPLOY_SUCCESS_TEXT := "%s已取消出戰"
const DISMISS_SUCCESS_TEXT := "已解僱%s"
const DEPLOYED_DISMISS_TEXT := "請先取消出戰，再解僱傭兵"
const PARTY_FAILURE_MESSAGES := {
	"ERR_DEPLOY_FULL": "出戰傭兵已達上限",
	"ERR_DEPLOYED": DEPLOYED_DISMISS_TEXT,
	# Stage 9 P01: a Mercenary holding goods or equipment cannot be dismissed.
	"ERR_HAS_ITEMS": "請先清空此傭兵攜帶的物品及裝備，再解僱",
	# Stage 10 P00: a dead Mercenary cannot be deployed.
	"ERR_DEAD": "此傭兵已陣亡，無法出戰",
	"ERR_UNKNOWN_MERCENARY": "找不到此傭兵",
	"ERR_ALREADY_DEPLOYED": "此傭兵已在出戰名單",
	"ERR_NOT_DEPLOYED": "此傭兵未在出戰名單",
	"ERR_NOT_IN_CITY": "需要在城市內操作",
	"ERR_ROSTER_FULL": ROSTER_FULL_CLAIM_TEXT,
}
const DEPLOY_SAVE_FAILED_TEXT := "無法儲存，隊伍變更已取消"
const DISMISS_SAVE_FAILED_TEXT := "無法儲存，解僱已取消"
## Stage 9 P05 (iPhone acceptance): a dismissal refused because the
## Mercenary still holds goods or equipment (ERR_HAS_ITEMS, the unchanged
## P01 rule) opens this modal notice instead of a line in the page.
const DISMISS_BLOCKED_TITLE := "無法解僱"
const DISMISS_BLOCKED_LINES := ["此傭兵仍攜帶物品或裝備。", "請先清空後再解僱。"]
const DISMISS_BLOCKED_OK_TEXT := "確定"
## Stage 8 P05: the pending legacy Mercenaries (我的傭兵, above the roster).
const PENDING_TITLE_TEXT := "暫存傳承傭兵"
const PENDING_ROW_TEXT := "%s　Lv.%d"
const CLAIM_TEXT := "領取"
const ROSTER_FULL_CLAIM_TEXT := "傭兵人數已達上限，請先解僱一名傭兵"
const CLAIM_SUCCESS_TEXT := "已領取%s"
const CLAIM_SAVE_FAILED_TEXT := "無法儲存，領取已取消"
## Stage 8 P05: the roster list scrolls past this height (five rows fit
## without scrolling; the pending rows may push it past).
const ROSTER_SCROLL_MAX_HEIGHT := 748.0
const PARTY_GENERIC_FAILURE := "操作失敗"
const WAREHOUSE_NOTE := "開發原型：每次存入或取出 1 件；倉庫只存物品"
const WAREHOUSE_LOCAL_STATUS := "%s 城倉庫・本地倉庫（每次存入或取出 1 件）"
const WAREHOUSE_REMOTE_STATUS := "%s 城倉庫・遠端查看：只可在所在城市存取倉庫物品"
const CITY_TAB_SIZE := Vector2(200, 64)
const WAREHOUSE_FAILURE_MESSAGES := {
	"ERR_INSUFFICIENT_CARRIED": "數量不足",
	"ERR_INSUFFICIENT_STORED": "數量不足",
	"ERR_WAREHOUSE_CAPACITY": "倉庫容量不足",
	"ERR_CARRY_CAPACITY": "背包容量不足",
	"ERR_NOT_IN_CITY": "只可使用所在城市的倉庫",
	"ERR_WRONG_CITY": "只可使用所在城市的倉庫",
	"ERR_DUPLICATE_REQUEST": "已處理此要求",
	"ERR_INVALID_QUANTITY": "數量無效",
	"ERR_UNKNOWN_ITEM": "物品無效",
	"ERR_SAVE_FAILED": "無法儲存，操作已取消",
}
const WAREHOUSE_GENERIC_FAILURE := "操作失敗"
const MARKET_NOTE := "開發原型：每單買賣 1 件或 10 件，同一單使用同一價格"
const TRANSPORT_NOTE := "只載乘客，貨物由角色自行攜帶（車費及時間為測試數值）"
const TRANSPORT_FAILURE_MESSAGES := {
	"ERR_INSUFFICIENT_FUNDS": "金錢不足",
	"ERR_ALREADY_THERE": "已在此城市",
	"ERR_ALREADY_TRAVELING": "旅途中，無法乘搭",
	"ERR_DUPLICATE_REQUEST": "已處理此乘搭要求",
	"ERR_NOT_IN_CITY": "需要在城市內乘搭",
	"ERR_INVALID_DESTINATION": "目的地無效",
	"ERR_TRANSPORT_UNAVAILABLE": "此路線暫未開放",
	"ERR_SAVE_FAILED": "無法儲存，乘搭已取消",
}
const TRANSPORT_GENERIC_FAILURE := "無法乘搭"
const ARRIVAL_RETRY_MESSAGE := "無法儲存，正在重試抵達"

const INFO_WIDTH := 400.0
const TRADE_BUTTON_SIZE := Vector2(120, 88)
const NAME_FONT_SIZE := 22
const DETAIL_FONT_SIZE := 20
## Market rows fit four order buttons (買入 1 / 買入 10 / 賣出 1 / 賣出 10) in
## the 720-wide portrait layout, so they use narrower buttons and details.
const MARKET_BUTTON_SIZE := Vector2(104, 88)
const MARKET_INFO_WIDTH := 260.0
const MARKET_DETAIL_FONT_SIZE := 18
const MARKET_ROW_SEPARATION := 6
## Small fourth line of a market row: expected sale result (T05).
const MARKET_PREVIEW_FONT_SIZE := 16
const COST_UNKNOWN_TEXT := "資料不足"
## Button node name -> [label, is_buy, order quantity].
const MARKET_ORDER_BUTTONS := {
	"BuyButton": ["買入 1", true, 1],
	"Buy10Button": ["買入 10", true, 10],
	"SellButton": ["賣出 1", false, 1],
	"Sell10Button": ["賣出 10", false, 10],
}
const MARKET_BUTTON_ACTIONS := {"buy": "BuyButton", "buy10": "Buy10Button", "sell": "SellButton", "sell10": "Sell10Button"}
const FAILURE_MESSAGES := {
	"insufficient_money": "金錢不足",
	"insufficient_cargo_space": "背包容量不足",
	"insufficient_cargo": "持有貨物不足",
	"insufficient_market_stock": "市場庫存不足",
}
const GENERIC_FAILURE := "交易失敗"

var city_id := ""
## good_id -> market row, built once from GoodsCatalog.
var _rows := {}
## destination city id -> transport row, rebuilt for each city.
var _transport_rows := {}
var _transport_request_id := ""
## good_id -> warehouse row, built once from GoodsCatalog.
var _warehouse_rows := {}
var _warehouse_request_id := ""
## City whose warehouse is shown, and whether it is the character's city.
var _warehouse_view_city := ""
var _warehouse_local := false
## city id -> selector button
var _warehouse_city_buttons := {}
var _facility := FACILITY_MARKET
var _traveling := false
## Stage 8 P02: type -> Mercenary Center row.
var _recruit_rows := {}
var _mercenary_count_label: Label
var _mercenary_owned_label: Label
## Stage 8 P03: sub-views, the deployed count, the roster rows (id -> row,
## rebuilt from show_mercenaries) and the dismissal confirmation.
var _mercenary_view := MERCENARY_VIEW_RECRUIT
var _deployed_count_label: Label
var _recruit_view_button: Button
var _roster_view_button: Button
var _recruit_box: VBoxContainer
var _roster_box: VBoxContainer
## Stage 8 P05: scrolls the pending section + roster rows.
var _roster_scroll: ScrollContainer
var _pending_box: VBoxContainer
var _pending_rows := {}
var _roster_rows := {}
var _roster_entries := {}
var _roster_empty_label: Label
var _dismiss_modal: Control
var _dismiss_title: Label
var _dismiss_id := ""
## Stage 9 P05: the one 無法解僱 notice (reused, never stacked).
var _blocked_modal: Control
var _blocked_lines: Array[Label] = []
## Stage 9 P02: item id -> 裝備商店 row; the recipients ({id, name, load,
## capacity}, Hero first, then owned Mercenaries) and the chosen one's
## stable id.
var _equipment_rows := {}
var _equipment_recipients: Array = []
var _equipment_recipient_id := EQUIPMENT_DEFAULT_RECIPIENT
var _equipment_recipient_label: Label
var _equipment_load_label: Label
## Stage 10 P02: 醫院 — the last status (RecoveryService.get_status), the
## Mercenary rows by stable id and the chosen stable ids (only ids that need
## recovery; rebuilt from every status, never guessed).
var _hospital_status := {}
var _hospital_rows := {}
var _hospital_selected: Array = []
var _hospital_hero_row: Control
var _hospital_scroll: ScrollContainer
var _hospital_box: VBoxContainer
var _hospital_empty_label: Label
var _hospital_summary_label: Label
var _hospital_short_label: Label
var _hospital_confirm_button: Button
## Seconds the open confirmation has waited (UI time, restarts on every
## open); 確定解僱 is enabled once it reaches DISMISS_COUNTDOWN_SECONDS.
var _dismiss_waited := 0.0

@onready var _city_label := $Center/Content/CityLabel as Label
@onready var _leave_button := $Center/Content/LeaveButton as Button
@onready var _cargo_label := $Center/Content/CargoLabel as Label
@onready var _money_label := $Center/Content/MoneyLabel as Label
@onready var _feedback_label := $Center/Content/FeedbackLabel as Label
@onready var _market_rows := $Center/Content/MarketRows as VBoxContainer
@onready var _title_label := $Center/Content/TitleLabel as Label
@onready var _facility_tabs := $Center/Content/FacilityTabs as HBoxContainer
@onready var _market_tab := $Center/Content/FacilityTabs/MarketTabButton as Button
@onready var _transport_tab := $Center/Content/FacilityTabs/TransportTabButton as Button
@onready var _warehouse_tab := $Center/Content/FacilityTabs/WarehouseTabButton as Button
@onready var _mercenary_tab := $Center/Content/FacilityTabs/MercenaryTabButton as Button
@onready var _mercenary_panel := $Center/Content/MercenaryPanel as VBoxContainer
@onready var _equipment_tab := $Center/Content/FacilityTabs/EquipmentTabButton as Button
@onready var _equipment_panel := $Center/Content/EquipmentPanel as VBoxContainer
@onready var _hospital_tab := $Center/Content/FacilityTabs/HospitalTabButton as Button
@onready var _hospital_panel := $Center/Content/HospitalPanel as VBoxContainer
@onready var _warehouse_summary_label := $Center/Content/WarehouseSummaryLabel as Label
@onready var _warehouse_status_label := $Center/Content/WarehouseStatusLabel as Label
@onready var _warehouse_city_tabs := $Center/Content/WarehouseCityTabs as HBoxContainer
@onready var _warehouse_rows_box := $Center/Content/WarehouseRows as VBoxContainer
@onready var _note_label := $Center/Content/NoteLabel as Label
@onready var _transport_rows_box := $Center/Content/TransportRows as VBoxContainer
@onready var _travel_panel := $Center/Content/TravelPanel as VBoxContainer
@onready var _travel_destination_label := $Center/Content/TravelPanel/DestinationLabel as Label
@onready var _travel_remaining_label := $Center/Content/TravelPanel/RemainingLabel as Label


func _ready() -> void:
	visible = false
	_leave_button.pressed.connect(_on_leave_pressed)
	_market_tab.pressed.connect(show_facility.bind(FACILITY_MARKET))
	_transport_tab.pressed.connect(show_facility.bind(FACILITY_TRANSPORT))
	_warehouse_tab.pressed.connect(show_facility.bind(FACILITY_WAREHOUSE))
	_mercenary_tab.pressed.connect(show_facility.bind(FACILITY_MERCENARY))
	_equipment_tab.pressed.connect(show_facility.bind(FACILITY_EQUIPMENT))
	_hospital_tab.pressed.connect(show_facility.bind(FACILITY_HOSPITAL))
	_build_market_rows()
	_build_mercenary_panel()
	_build_equipment_panel()
	_build_hospital_panel()
	_build_warehouse_rows()
	_build_warehouse_city_tabs()


## Opens the hub of a city on its market facility.
func open(opened_city_id: String) -> void:
	city_id = opened_city_id
	_warehouse_view_city = opened_city_id
	_traveling = false
	_city_label.text = "【%s 城】" % city_id
	_feedback_label.text = ""
	_travel_destination_label.text = ""
	_travel_remaining_label.text = ""
	_hospital_selected.clear()
	_apply_view(FACILITY_MARKET)
	visible = true


## Shows the journey view: no facilities and no way to leave until arrival.
func open_traveling(destination_city_id: String, remaining_ms: int) -> void:
	city_id = ""
	_traveling = true
	_city_label.text = "旅途中"
	_feedback_label.text = ""
	_travel_destination_label.text = "前往 %s 城" % destination_city_id
	show_travel_remaining(remaining_ms)
	_apply_view(FACILITY_MARKET)
	visible = true


## Arrival could not be saved yet; the journey is still in progress.
func show_arrival_retry() -> void:
	if _traveling:
		_feedback_label.text = ARRIVAL_RETRY_MESSAGE


func show_travel_remaining(remaining_ms: int) -> void:
	_travel_remaining_label.text = "預計抵達：%d 秒" % _seconds(remaining_ms)


func show_facility(facility: String) -> void:
	if _traveling or not facility in FACILITIES:
		return
	# Stage 10 P02: 醫院 only where the city has one.
	if facility == FACILITY_HOSPITAL and not has_hospital():
		return
	_feedback_label.text = ""
	close_dismiss_confirm()
	close_dismiss_blocked()
	if facility == FACILITY_MERCENARY and _facility != FACILITY_MERCENARY:
		show_mercenary_view(MERCENARY_VIEW_RECRUIT)
	if facility == FACILITY_HOSPITAL and _facility != FACILITY_HOSPITAL:
		_hospital_selected.clear()
		_refresh_hospital()
	_apply_view(facility)
	facility_changed.emit(facility)


func get_facility() -> String:
	return "traveling" if _traveling else _facility


## Rebuilds the transport offers from `quotes` ({destination, fare,
## duration_ms}); every press of these offers carries `request_id`.
func show_transport_routes(quotes: Array, request_id: String) -> void:
	_transport_request_id = request_id
	for row in _transport_rows.values():
		_transport_rows_box.remove_child(row)
		row.queue_free()
	_transport_rows.clear()
	for quote in quotes:
		var destination: String = quote["destination"]
		var row := HBoxContainer.new()
		row.name = "Route" + destination
		row.add_theme_constant_override("separation", 10)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(INFO_WIDTH + 130.0, 0)
		info.add_theme_constant_override("separation", 0)
		info.add_child(_make_label("DestinationLabel", "目的地：%s 城" % destination, NAME_FONT_SIZE))
		info.add_child(_make_label("FareLabel", "車費：%d" % quote["fare"], DETAIL_FONT_SIZE))
		info.add_child(_make_label("DurationLabel", "預計時間：%d 秒" % _seconds(quote["duration_ms"]), DETAIL_FONT_SIZE))
		row.add_child(info)
		row.add_child(_make_button("RideButton", "乘搭", _on_ride_pressed.bind(destination)))
		_transport_rows_box.add_child(row)
		_transport_rows[destination] = row


func show_transport_feedback(result: Dictionary) -> void:
	if not result.get("success", false):
		_feedback_label.text = TRANSPORT_FAILURE_MESSAGES.get(result.get("reason", ""), TRANSPORT_GENERIC_FAILURE)


func get_transport_destinations() -> Array:
	return _transport_rows.keys()


func get_transport_row_texts(destination_city_id: String) -> Dictionary:
	if not _transport_rows.has(destination_city_id):
		return {}
	var row: Node = _transport_rows[destination_city_id]
	return {
		"destination": (row.find_child("DestinationLabel", true, false) as Label).text,
		"fare": (row.find_child("FareLabel", true, false) as Label).text,
		"duration": (row.find_child("DurationLabel", true, false) as Label).text,
	}


func get_transport_button(destination_city_id: String) -> Button:
	if not _transport_rows.has(destination_city_id):
		return null
	return _transport_rows[destination_city_id].get_node("RideButton") as Button


func get_transport_request_id() -> String:
	return _transport_request_id


func get_travel_texts() -> Dictionary:
	return {"title": _city_label.text, "destination": _travel_destination_label.text, "remaining": _travel_remaining_label.text}


func is_leave_available() -> bool:
	return visible and _leave_button.visible


## Shows one city's warehouse (`view` from main: city_id, local, contents,
## used, max) next to the backpack. A remote warehouse is read-only: its
## transfer buttons are hidden and the status explains why. Display only:
## every transfer runs in main.gd through WarehouseService.
func show_warehouse(view: Dictionary, carried: Dictionary, carry_used: int, carry_max: int, request_id: String) -> void:
	_warehouse_request_id = request_id
	_warehouse_view_city = view.get("city_id", "")
	_warehouse_local = view.get("local", false)
	var stored: Dictionary = view.get("contents", {})
	_warehouse_status_label.text = (WAREHOUSE_LOCAL_STATUS if _warehouse_local else WAREHOUSE_REMOTE_STATUS) % _warehouse_view_city
	_warehouse_summary_label.text = "背包容量：%d / %d　倉庫容量：%d / %d" % [carry_used, carry_max, view.get("used", 0), view.get("max", 0)]
	for good_id in _warehouse_rows:
		var carried_label := _warehouse_label(good_id, "CarriedLabel")
		carried_label.text = "背包：%d" % carried.get(good_id, 0)
		carried_label.visible = _warehouse_local
		_warehouse_label(good_id, "StoredLabel").text = "倉庫：%d" % stored.get(good_id, 0)
		for button_name in ["DepositButton", "WithdrawButton"]:
			(_warehouse_rows[good_id].get_node(button_name) as Button).visible = _warehouse_local
	for city in _warehouse_city_buttons:
		(_warehouse_city_buttons[city] as Button).disabled = city == _warehouse_view_city


## Selects which city's warehouse to show; main refreshes the view.
func show_warehouse_city(selected_city_id: String) -> void:
	if _traveling or not _warehouse_city_buttons.has(selected_city_id):
		return
	_warehouse_view_city = selected_city_id
	_feedback_label.text = ""
	warehouse_city_selected.emit(selected_city_id)


func get_warehouse_view_city() -> String:
	return _warehouse_view_city


func is_warehouse_view_local() -> bool:
	return _warehouse_local


func get_warehouse_status_text() -> String:
	return _warehouse_status_label.text


func get_warehouse_city_button(selected_city_id: String) -> Button:
	return _warehouse_city_buttons.get(selected_city_id)


func show_warehouse_feedback(action: String, good_id: String, result: Dictionary) -> void:
	if result.get("success", false):
		var good_name: String = GoodsCatalog.get_good(good_id).get("display_name", good_id)
		_feedback_label.text = ("已存入 %d 件%s" if action == "deposit" else "已取出 %d 件%s") % [result.get("quantity", 0), good_name]
	else:
		_feedback_label.text = WAREHOUSE_FAILURE_MESSAGES.get(result.get("reason", ""), WAREHOUSE_GENERIC_FAILURE)


func get_warehouse_summary_text() -> String:
	return _warehouse_summary_label.text


func get_warehouse_row_texts(good_id: String) -> Dictionary:
	if not _warehouse_rows.has(good_id):
		return {}
	return {
		"name": _warehouse_label(good_id, "NameLabel").text,
		"carried": _warehouse_label(good_id, "CarriedLabel").text,
		"stored": _warehouse_label(good_id, "StoredLabel").text,
	}


func get_warehouse_button(good_id: String, action: String) -> Button:
	if not _warehouse_rows.has(good_id):
		return null
	return _warehouse_rows[good_id].get_node("DepositButton" if action == "deposit" else "WithdrawButton") as Button


func get_warehouse_request_id() -> String:
	return _warehouse_request_id


func show_cargo_summary(used: int, capacity: int) -> void:
	_cargo_label.text = "背包容量：%d / %d" % [used, capacity]


func show_money(balance: int) -> void:
	_money_label.text = "金錢：%d" % balance


## Stage 8 P02: the owned Mercenaries (display labels, e.g. "法師 #2") and
## how many of the maximum are held. The hub only shows what it is given.
## Stage 8 P03: `entries` are the roster rows ({id, label, title, hint,
## progress, allocation, deployed}) and the deployed count of the maximum.
## P05: `pending` [{id, label, level}] are the pending legacy Mercenaries
## (領取 only while count < max_count).
func show_mercenaries(labels: Array, count: int, max_count: int, entries: Array = [], deployed_count: int = 0, max_deployed: int = 3, pending: Array = []) -> void:
	_mercenary_count_label.text = MERCENARY_COUNT_TEXT % [count, max_count]
	_mercenary_owned_label.text = "　".join(labels) if not labels.is_empty() else MERCENARY_NONE_TEXT
	_deployed_count_label.text = DEPLOYED_COUNT_TEXT % [deployed_count, max_deployed]
	_rebuild_pending_rows(pending, count >= max_count)
	_rebuild_roster_rows(entries)
	_fit_roster_scroll()
	if _dismiss_id != "" and not _roster_entries.has(_dismiss_id):
		close_dismiss_confirm()


## Stage 8 P03: 招聘 or 我的傭兵 inside the Mercenary Center.
func show_mercenary_view(view: String) -> void:
	if view != MERCENARY_VIEW_RECRUIT and view != MERCENARY_VIEW_ROSTER:
		return
	_mercenary_view = view
	_recruit_box.visible = view == MERCENARY_VIEW_RECRUIT
	_mercenary_owned_label.visible = view == MERCENARY_VIEW_RECRUIT
	_roster_box.visible = view == MERCENARY_VIEW_ROSTER
	_roster_scroll.visible = view == MERCENARY_VIEW_ROSTER
	_recruit_view_button.disabled = view == MERCENARY_VIEW_RECRUIT
	_roster_view_button.disabled = view == MERCENARY_VIEW_ROSTER


func get_mercenary_view() -> String:
	return _mercenary_view


func get_deployed_count_text() -> String:
	return _deployed_count_label.text


func get_roster_ids() -> Array:
	return _roster_rows.keys()


## A roster row's lines and button texts ({} for an unknown id).
func get_roster_row_texts(mercenary_id: String) -> Dictionary:
	if not _roster_rows.has(mercenary_id):
		return {}
	var row: Node = _roster_rows[mercenary_id]
	var texts := {}
	for name in ["TitleLabel", "HintLabel", "ProgressLabel", "AllocationLabel", "StatsLabel", "DerivedLabel", "PendingLabel"]:
		texts[name] = (row.find_child(name, true, false) as Label).text
	texts["deploy_button"] = get_deploy_button(mercenary_id).text
	return texts


func get_deploy_button(mercenary_id: String) -> Button:
	return _roster_rows[mercenary_id].find_child("DeployButton", true, false) as Button if _roster_rows.has(mercenary_id) else null


func get_dismiss_button(mercenary_id: String) -> Button:
	return _roster_rows[mercenary_id].find_child("DismissButton", true, false) as Button if _roster_rows.has(mercenary_id) else null


func is_dismiss_confirm_open() -> bool:
	return _dismiss_modal != null and _dismiss_modal.visible


## The id the confirmation is for ("" when closed) and its title.
func get_dismiss_confirm() -> Dictionary:
	return {"id": _dismiss_id, "title": _dismiss_title.text if is_dismiss_confirm_open() else ""}


func get_dismiss_confirm_button() -> Button:
	return _dismiss_modal.find_child("ConfirmButton", true, false) as Button


func get_dismiss_cancel_button() -> Button:
	return _dismiss_modal.find_child("CancelButton", true, false) as Button


func close_dismiss_confirm() -> void:
	_dismiss_id = ""
	if _dismiss_modal != null:
		_dismiss_modal.visible = false


## Stage 9 P05: the 無法解僱 notice (one node, shown again — never a second
## window). It changes nothing; 確定 closes it.
func show_dismiss_blocked() -> void:
	close_dismiss_confirm()
	_blocked_modal.visible = true


func close_dismiss_blocked() -> void:
	if _blocked_modal != null:
		_blocked_modal.visible = false


func is_dismiss_blocked_open() -> bool:
	return _blocked_modal != null and _blocked_modal.visible


func get_dismiss_blocked_ok_button() -> Button:
	return _blocked_modal.find_child("OkButton", true, false) as Button


## {"title", "lines"} of the notice.
func get_dismiss_blocked_text() -> Dictionary:
	return {"title": (_blocked_modal.find_child("TitleLabel", true, false) as Label).text, "lines": _blocked_lines.map(func(label: Label) -> String: return label.text)}


## Stage 8 P03: the result of 設為出戰 / 取消出戰 ("deploy" / "undeploy") or
## 解僱 ("dismiss") for the Mercenary shown as `label`.
func show_party_feedback(action: String, result: Dictionary, label: String) -> void:
	if result.get("success", false):
		var success := {"deploy": DEPLOY_SUCCESS_TEXT, "undeploy": UNDEPLOY_SUCCESS_TEXT, "dismiss": DISMISS_SUCCESS_TEXT, "claim": CLAIM_SUCCESS_TEXT}
		_feedback_label.text = success.get(action, "%s") % label
	elif action == "dismiss" and result.get("reason", "") == "ERR_HAS_ITEMS":
		# Stage 9 P05: a modal notice, not a line in the page.
		show_dismiss_blocked()
	elif result.get("reason", "") == "ERR_SAVE_FAILED":
		_feedback_label.text = {"dismiss": DISMISS_SAVE_FAILED_TEXT, "claim": CLAIM_SAVE_FAILED_TEXT}.get(action, DEPLOY_SAVE_FAILED_TEXT)
	else:
		_feedback_label.text = PARTY_FAILURE_MESSAGES.get(result.get("reason", ""), PARTY_GENERIC_FAILURE)


## Stage 8 P02: the result of a 招聘 press.
func show_recruit_feedback(result: Dictionary) -> void:
	if result.get("success", false):
		_feedback_label.text = RECRUIT_SUCCESS_TEXT % RecruitmentService.TYPE_NAMES.get(result.get("type", ""), "")
	else:
		_feedback_label.text = RECRUIT_FAILURE_MESSAGES.get(result.get("reason", ""), RECRUIT_GENERIC_FAILURE)


func get_mercenary_count_text() -> String:
	return _mercenary_count_label.text


func get_mercenary_owned_text() -> String:
	return _mercenary_owned_label.text


func get_recruit_button(type: String) -> Button:
	return _recruit_rows[type].find_child("RecruitButton", true, false) as Button if _recruit_rows.has(type) else null


## A recruit row's name / role, hint and price lines.
func get_recruit_row_texts(type: String) -> Dictionary:
	if not _recruit_rows.has(type):
		return {}
	var row: Node = _recruit_rows[type]
	return {
		"name": (row.find_child("NameLabel", true, false) as Label).text,
		"hint": (row.find_child("HintLabel", true, false) as Label).text,
		"price": (row.find_child("PriceLabel", true, false) as Label).text,
	}


## Refreshes every market row from the quotes computed by the market; the hub
## never calculates prices or stock itself. Holdings are a copy of the cargo.
## `previews` (good_id -> order size -> sale terms) comes from the trade
## domain's own sale preview; the hub only formats it.
func show_market(quotes: Dictionary, holdings: Dictionary, previews: Dictionary = {}) -> void:
	for good_id in _rows:
		var quote: Dictionary = quotes.get(good_id, {})
		_row_label(good_id, "BuyPriceLabel").text = "買入價 %s" % _number(quote, "buy_price")
		_row_label(good_id, "BuybackPriceLabel").text = "賣出價 %s" % _number(quote, "buyback_price")
		_row_label(good_id, "HeldLabel").text = "持有 %d" % holdings.get(good_id, 0)
		_row_label(good_id, "StockLabel").text = "庫存 %s" % _number(quote, "stock")
		_row_label(good_id, "PreviewLabel").text = _preview_text(previews.get(good_id, {}))


## 「預計：賣1 +4 / 賣10 +40」 for the order sizes that can be sold now. A size
## whose FIFO cost is not fully known shows 資料不足, never a number; when no
## size has a known cost the line is just 「預計：資料不足」.
func _preview_text(by_size: Dictionary) -> String:
	var parts := []
	var any_known := false
	for size in [1, 10]:
		if by_size.has(size):
			var terms: Dictionary = by_size[size]
			var known: bool = terms.get("cost_known", false)
			any_known = any_known or known
			parts.append("賣%d %s" % [size, _signed(terms["realized_profit"]) if known else COST_UNKNOWN_TEXT])
	if parts.is_empty():
		return ""
	return "預計：" + (" / ".join(parts) if any_known else COST_UNKNOWN_TEXT)


## Merchandise result appended to the sale feedback line (T05): cost and
## realized profit / loss, or 成本：資料不足. "" for a result without cost data.
func _profit_text(result: Dictionary) -> String:
	if not result.has("cost_known"):
		return ""
	if not result["cost_known"]:
		return "，成本：" + COST_UNKNOWN_TEXT
	var profit: int = result["realized_profit"]
	var word := "盈利" if profit > 0 else ("虧損" if profit < 0 else "盈虧")
	return "，成本 %d，%s %s" % [result["acquisition_cost"], word, _signed(profit)]


static func _signed(value: int) -> String:
	return "+%d" % value if value > 0 else "%d" % value


func show_trade_feedback(action: String, good_id: String, quantity: int, result: Dictionary) -> void:
	if result.get("success", false):
		var good_name: String = GoodsCatalog.get_good(good_id).get("display_name", good_id)
		if action == "buy":
			_feedback_label.text = "已買入 %d 件%s，支付 %d" % [quantity, good_name, result["total_value"]]
		else:
			_feedback_label.text = "已賣出 %d 件%s，收入 %d" % [quantity, good_name, result["total_value"]] + _profit_text(result)
	else:
		_feedback_label.text = FAILURE_MESSAGES.get(result.get("reason", ""), GENERIC_FAILURE)


func close() -> void:
	close_dismiss_confirm()
	close_dismiss_blocked()
	_hospital_selected.clear()
	city_id = ""
	_traveling = false
	_travel_destination_label.text = ""
	_travel_remaining_label.text = ""
	_city_label.text = ""
	_cargo_label.text = ""
	_money_label.text = ""
	_feedback_label.text = ""
	for good_id in _rows:
		for node_name in ["BuyPriceLabel", "BuybackPriceLabel", "HeldLabel", "StockLabel", "PreviewLabel"]:
			_row_label(good_id, node_name).text = ""
	_warehouse_summary_label.text = ""
	_warehouse_status_label.text = ""
	_warehouse_view_city = ""
	_warehouse_local = false
	for good_id in _warehouse_rows:
		_warehouse_label(good_id, "CarriedLabel").text = ""
		_warehouse_label(good_id, "StoredLabel").text = ""
	visible = false


func is_open() -> bool:
	return visible


func get_city_label_text() -> String:
	return _city_label.text


func get_cargo_label_text() -> String:
	return _cargo_label.text


func get_money_label_text() -> String:
	return _money_label.text


func get_feedback_text() -> String:
	return _feedback_label.text


func get_market_good_ids() -> Array:
	return _rows.keys()


## A market row's expected sale result line ("" when nothing can be sold).
func get_market_preview_text(good_id: String) -> String:
	return _row_label(good_id, "PreviewLabel").text if _rows.has(good_id) else ""


## Returns the displayed name, buy price, sell price, held and stock text of
## one market row.
func get_market_row_texts(good_id: String) -> Dictionary:
	if not _rows.has(good_id):
		return {}
	return {
		"name": _row_label(good_id, "NameLabel").text,
		"buy_price": _row_label(good_id, "BuyPriceLabel").text,
		"buyback_price": _row_label(good_id, "BuybackPriceLabel").text,
		"held": _row_label(good_id, "HeldLabel").text,
		"stock": _row_label(good_id, "StockLabel").text,
	}


func get_market_button(good_id: String, action: String) -> Button:
	if not _rows.has(good_id):
		return null
	## action: "buy" / "sell" (1 unit) or "buy10" / "sell10" (10 units).
	if not MARKET_BUTTON_ACTIONS.has(action):
		return null
	return _rows[good_id].get_node(MARKET_BUTTON_ACTIONS[action]) as Button


func _build_market_rows() -> void:
	for good_id in GoodsCatalog.get_ids():
		var row := HBoxContainer.new()
		row.name = good_id
		row.add_theme_constant_override("separation", MARKET_ROW_SEPARATION)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(MARKET_INFO_WIDTH, 0)
		info.add_theme_constant_override("separation", 0)
		info.add_child(_make_label("NameLabel", GoodsCatalog.get_good(good_id)["display_name"], NAME_FONT_SIZE))
		info.add_child(_make_line("PriceLine", ["BuyPriceLabel", "BuybackPriceLabel"], MARKET_INFO_WIDTH, MARKET_DETAIL_FONT_SIZE))
		info.add_child(_make_line("StockLine", ["HeldLabel", "StockLabel"], MARKET_INFO_WIDTH, MARKET_DETAIL_FONT_SIZE))
		var preview := _make_label("PreviewLabel", "", MARKET_PREVIEW_FONT_SIZE)
		# Never widens the row: an extreme value is trimmed, the buttons stay put.
		preview.custom_minimum_size = Vector2(MARKET_INFO_WIDTH, 0)
		preview.clip_text = true
		preview.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		info.add_child(preview)
		row.add_child(info)
		for button_name in MARKET_ORDER_BUTTONS:
			var order: Array = MARKET_ORDER_BUTTONS[button_name]
			var handler := _on_buy_pressed if order[1] else _on_sell_pressed
			var button := _make_button(button_name, order[0], handler.bind(good_id, order[2]))
			button.custom_minimum_size = MARKET_BUTTON_SIZE
			row.add_child(button)
		_market_rows.add_child(row)
		_rows[good_id] = row


## Stage 8 P02: the Mercenary Center: held count, owned list, one row per
## recruitable type (name and role, a short hint, the price, 招聘).
# --- Stage 9 P02: 裝備商店 -----------------------------------------------------

func _build_equipment_panel() -> void:
	var picker := HBoxContainer.new()
	picker.name = "RecipientPicker"
	picker.alignment = BoxContainer.ALIGNMENT_CENTER
	picker.add_theme_constant_override("separation", 12)
	var previous := _make_button("PreviousRecipientButton", EQUIPMENT_PREVIOUS_TEXT, select_equipment_recipient_step.bind(-1))
	var next := _make_button("NextRecipientButton", EQUIPMENT_NEXT_TEXT, select_equipment_recipient_step.bind(1))
	var names := VBoxContainer.new()
	names.name = "Recipient"
	names.custom_minimum_size = Vector2(360, 0)
	names.add_theme_constant_override("separation", 0)
	_equipment_recipient_label = _make_label("RecipientLabel", "", NAME_FONT_SIZE + 2)
	_equipment_recipient_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_equipment_load_label = _make_label("RecipientLoadLabel", "", DETAIL_FONT_SIZE)
	_equipment_load_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	names.add_child(_equipment_recipient_label)
	names.add_child(_equipment_load_label)
	for button in [previous, next]:
		(button as Button).custom_minimum_size = Vector2(130, 88)
	picker.add_child(previous)
	picker.add_child(names)
	picker.add_child(next)
	_equipment_panel.add_child(picker)
	for item_id in EquipmentShopService.get_item_ids():
		var item := EquipmentCatalog.get_item(item_id)
		var row := HBoxContainer.new()
		row.name = "Equipment_" + item_id
		row.add_theme_constant_override("separation", 16)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(RECRUIT_INFO_WIDTH, 0)
		info.add_theme_constant_override("separation", 0)
		info.add_child(_make_label("NameLabel", "%s　%s" % [item["display_name"], EquipmentCatalog.slot_name(item["slot"])], NAME_FONT_SIZE + 2))
		info.add_child(_make_label("BonusLabel", equipment_bonus_text(item_id), DETAIL_FONT_SIZE))
		info.add_child(_make_label("DetailLabel", EQUIPMENT_DETAIL_TEXT % [int(item["capacity_cost"]), _thousands(EquipmentShopService.get_price(item_id))], DETAIL_FONT_SIZE))
		row.add_child(info)
		var button := _make_button("BuyEquipmentButton", EQUIPMENT_BUY_TEXT, _on_equipment_buy_pressed.bind(item_id))
		button.custom_minimum_size = RECRUIT_BUTTON_SIZE
		row.add_child(button)
		_equipment_panel.add_child(row)
		_equipment_rows[item_id] = row
	_update_equipment_recipient()


## "力量 +2" style text of an item's fixed bonuses (EquipmentCatalog).
static func equipment_bonus_text(item_id: String) -> String:
	return EquipmentCatalog.describe_bonuses(item_id)


## The receiving characters ({id, name, load, capacity}: the Hero, then the
## owned Mercenaries). The chosen one stays chosen by its stable id; when it
## is gone the Hero is chosen.
func show_equipment_shop(recipients: Array) -> void:
	_equipment_recipients = recipients.duplicate(true)
	if _recipient_index(_equipment_recipient_id) < 0:
		_equipment_recipient_id = _equipment_recipients[0]["id"] if not _equipment_recipients.is_empty() else ""
	_update_equipment_recipient()


## Chooses the recipient by stable id (false when it is not offered).
func select_equipment_recipient(character_id: String) -> bool:
	if _recipient_index(character_id) < 0:
		return false
	_equipment_recipient_id = character_id
	_update_equipment_recipient()
	return true


## 上一位 / 下一位: the previous / next recipient (wrapping).
func select_equipment_recipient_step(step: int) -> void:
	if _equipment_recipients.is_empty():
		return
	var index := maxi(_recipient_index(_equipment_recipient_id), 0)
	index = posmod(index + step, _equipment_recipients.size())
	_equipment_recipient_id = _equipment_recipients[index]["id"]
	_feedback_label.text = ""
	_update_equipment_recipient()


func get_equipment_recipient_id() -> String:
	return _equipment_recipient_id


func get_equipment_recipient_texts() -> Dictionary:
	return {"name": _equipment_recipient_label.text, "load": _equipment_load_label.text}


func get_equipment_buy_button(item_id: String) -> Button:
	return _equipment_rows[item_id].find_child("BuyEquipmentButton", true, false) as Button if _equipment_rows.has(item_id) else null


## A shop row's name / bonus / detail texts ({} for an item not on sale).
func get_equipment_row_texts(item_id: String) -> Dictionary:
	if not _equipment_rows.has(item_id):
		return {}
	var row: Node = _equipment_rows[item_id]
	return {
		"name": (row.find_child("NameLabel", true, false) as Label).text,
		"bonus": (row.find_child("BonusLabel", true, false) as Label).text,
		"detail": (row.find_child("DetailLabel", true, false) as Label).text,
	}


## The purchase result (EquipmentShopService.buy or main's refusal).
func show_equipment_feedback(result: Dictionary, item_name: String, recipient_name: String) -> void:
	if result.get("success", false):
		_feedback_label.text = EQUIPMENT_SUCCESS_TEXT % [item_name, recipient_name]
		return
	var message: String = EQUIPMENT_FAILURE_MESSAGES.get(result.get("reason", ""), EQUIPMENT_GENERIC_FAILURE)
	_feedback_label.text = message % recipient_name if message.contains("%s") else message


func _recipient_index(character_id: String) -> int:
	for index in range(_equipment_recipients.size()):
		if _equipment_recipients[index]["id"] == character_id:
			return index
	return -1


func _update_equipment_recipient() -> void:
	var index := _recipient_index(_equipment_recipient_id)
	if index < 0:
		_equipment_recipient_label.text = EQUIPMENT_RECIPIENT_TEXT % ""
		_equipment_load_label.text = ""
		return
	var recipient: Dictionary = _equipment_recipients[index]
	_equipment_recipient_label.text = EQUIPMENT_RECIPIENT_TEXT % recipient["name"]
	_equipment_load_label.text = EQUIPMENT_RECIPIENT_LOAD_TEXT % [int(recipient["load"]), int(recipient["capacity"])]


func _on_equipment_buy_pressed(item_id: String) -> void:
	if _equipment_recipient_id == "":
		return
	equipment_buy_requested.emit(_equipment_recipient_id, item_id)


# --- Stage 10 P02: 醫院 ----------------------------------------------------------

## Whether the open city has a Hospital (WorldLayout.HOSPITAL_CITY_IDS).
func has_hospital() -> bool:
	return not _traveling and WorldLayout.city_has_hospital(city_id)


func _build_hospital_panel() -> void:
	_hospital_hero_row = _make_hospital_row("HeroRow", HOSPITAL_HERO_BUTTON_TEXT, _on_hospital_hero_pressed)
	_hospital_panel.add_child(_hospital_hero_row)
	_hospital_scroll = ScrollContainer.new()
	_hospital_scroll.name = "HospitalScroll"
	_hospital_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_hospital_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_hospital_panel.add_child(_hospital_scroll)
	_hospital_box = VBoxContainer.new()
	_hospital_box.name = "MercenaryRows"
	_hospital_box.add_theme_constant_override("separation", 10)
	_hospital_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_hospital_scroll.add_child(_hospital_box)
	_hospital_empty_label = _make_label("NoMercenaryLabel", HOSPITAL_NO_MERCENARY_TEXT, DETAIL_FONT_SIZE)
	_hospital_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hospital_box.add_child(_hospital_empty_label)
	_hospital_summary_label = _make_label("SummaryLabel", "", NAME_FONT_SIZE)
	_hospital_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hospital_panel.add_child(_hospital_summary_label)
	_hospital_short_label = _make_label("ShortLabel", "", DETAIL_FONT_SIZE)
	_hospital_short_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hospital_short_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45))
	_hospital_panel.add_child(_hospital_short_label)
	_hospital_confirm_button = _make_button("ConfirmRecoveryButton", HOSPITAL_CONFIRM_TEXT, _on_hospital_confirm_pressed)
	_hospital_confirm_button.custom_minimum_size = Vector2(360, 88)
	_hospital_confirm_button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_hospital_panel.add_child(_hospital_confirm_button)
	_refresh_hospital()


## One character row: name / HP + MP / state / price on the left, its
## button on the right.
func _make_hospital_row(node_name: String, button_text: String, on_pressed: Callable) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = node_name
	row.add_theme_constant_override("separation", 16)
	var info := VBoxContainer.new()
	info.name = "Info"
	info.custom_minimum_size = Vector2(HOSPITAL_INFO_WIDTH, 0)
	info.add_theme_constant_override("separation", 0)
	info.add_child(_make_label("NameLabel", "", NAME_FONT_SIZE + 2))
	for line in ["HpMpLabel", "StateLabel", "PriceLabel"]:
		var label := _make_label(line, "", DETAIL_FONT_SIZE)
		label.clip_text = true
		label.custom_minimum_size = Vector2(HOSPITAL_INFO_WIDTH, 0)
		info.add_child(label)
	row.add_child(info)
	var button := _make_button("RowButton", button_text, on_pressed)
	button.custom_minimum_size = HOSPITAL_ROW_BUTTON_SIZE
	button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(button)
	return row


## The Hospital's state from main.gd (RecoveryService.get_status: {hero,
## mercenaries, balance, mercenary_price}). Rows follow the stable ids; the
## selection keeps only ids that are still offered and still need recovery.
func show_hospital(status: Dictionary) -> void:
	_hospital_status = status.duplicate(true)
	_refresh_hospital()
	if _facility == FACILITY_HOSPITAL and not _traveling:
		_note_label.text = HOSPITAL_NOTE % _thousands(int(_hospital_status.get("mercenary_price", 0)))


func _refresh_hospital() -> void:
	if _hospital_panel == null:
		return
	var hero: Dictionary = _hospital_status.get("hero", {})
	_fill_hospital_row(_hospital_hero_row, hero, CharacterConfig.DISPLAY_NAMES["hero"])
	var hero_button := _hospital_hero_row.find_child("RowButton", true, false) as Button
	hero_button.disabled = not bool(hero.get("needs_recovery", false))
	var entries: Array = _hospital_status.get("mercenaries", [])
	var ids := entries.map(func(entry: Dictionary) -> String: return entry["id"])
	if ids != _hospital_rows.keys():
		for row in _hospital_rows.values():
			_hospital_box.remove_child(row)
			row.queue_free()
		_hospital_rows.clear()
		for id in ids:
			var row := _make_hospital_row("Merc_" + id, HOSPITAL_SELECT_TEXT, _on_hospital_toggle.bind(id))
			(row.find_child("RowButton", true, false) as Button).toggle_mode = true
			_hospital_box.add_child(row)
			_hospital_rows[id] = row
	_hospital_empty_label.visible = ids.is_empty()
	var offered := {}
	for entry in entries:
		offered[entry["id"]] = bool(entry["needs_recovery"])
	_hospital_selected = _hospital_selected.filter(func(id: String) -> bool: return offered.get(id, false))
	for entry in entries:
		var row: Control = _hospital_rows[entry["id"]]
		_fill_hospital_row(row, entry, str(entry.get("label", entry["id"])))
		var button := row.find_child("RowButton", true, false) as Button
		var chosen := _hospital_selected.has(entry["id"])
		button.disabled = not bool(entry["needs_recovery"])
		button.set_pressed_no_signal(chosen)
		button.text = HOSPITAL_SELECTED_TEXT if chosen else HOSPITAL_SELECT_TEXT
	var needed := _hospital_box.get_combined_minimum_size()
	_hospital_scroll.custom_minimum_size = Vector2(needed.x, minf(needed.y, HOSPITAL_SCROLL_MAX_HEIGHT))
	var total := get_hospital_total()
	var balance := int(_hospital_status.get("balance", 0))
	_hospital_summary_label.text = HOSPITAL_SUMMARY_TEXT % [_hospital_selected.size(), _thousands(total), _thousands(balance)]
	var affordable := total <= balance
	_hospital_short_label.text = "" if affordable else HOSPITAL_SHORT_TEXT
	_hospital_confirm_button.text = HOSPITAL_CONFIRM_TEXT + ("（$%s）" % _thousands(total) if total > 0 else "")
	_hospital_confirm_button.disabled = _hospital_selected.is_empty() or not affordable


func _fill_hospital_row(row: Control, entry: Dictionary, name: String) -> void:
	(row.find_child("NameLabel", true, false) as Label).text = name
	if entry.is_empty():
		for line in ["HpMpLabel", "StateLabel", "PriceLabel"]:
			(row.find_child(line, true, false) as Label).text = ""
		return
	(row.find_child("HpMpLabel", true, false) as Label).text = HOSPITAL_HP_MP_TEXT % [int(entry["hp"]), int(entry["max_hp"]), int(entry["mp"]), int(entry["max_mp"])]
	var state := HOSPITAL_HEALTHY_TEXT
	if bool(entry["dead"]):
		state = HOSPITAL_DEAD_TEXT
	elif bool(entry["needs_recovery"]):
		state = HOSPITAL_HURT_TEXT
	var state_label := row.find_child("StateLabel", true, false) as Label
	state_label.text = state
	state_label.add_theme_color_override("font_color", Color(1.0, 0.5, 0.45) if bool(entry["dead"]) else (Color(0.94, 0.8, 0.4) if bool(entry["needs_recovery"]) else Color(0.6, 0.85, 0.6)))
	var price := HOSPITAL_NO_PRICE_TEXT
	if bool(entry["needs_recovery"]):
		price = HOSPITAL_FREE_TEXT if bool(entry.get("hero", false)) else HOSPITAL_PRICE_TEXT % _thousands(int(entry["price"]))
	(row.find_child("PriceLabel", true, false) as Label).text = price


## The chosen Mercenaries' total: each one's price (RecoveryService, from
## the status); the Hero never counts.
func get_hospital_total() -> int:
	var total := 0
	for entry in _hospital_status.get("mercenaries", []):
		if _hospital_selected.has(entry["id"]):
			total += int(entry["price"])
	return total


## Chooses / drops a Mercenary by stable id (only one that needs recovery).
func toggle_hospital_selection(mercenary_id: String) -> bool:
	var entry := _hospital_entry(mercenary_id)
	if entry.is_empty() or not bool(entry["needs_recovery"]):
		_refresh_hospital()
		return false
	if _hospital_selected.has(mercenary_id):
		_hospital_selected.erase(mercenary_id)
	else:
		_hospital_selected.append(mercenary_id)
	_feedback_label.text = ""
	_refresh_hospital()
	return true


func get_hospital_selection() -> Array:
	return _hospital_selected.duplicate()


func clear_hospital_selection() -> void:
	_hospital_selected.clear()
	_refresh_hospital()


func get_hospital_ids() -> Array:
	return _hospital_rows.keys()


func get_hospital_hero_button() -> Button:
	return _hospital_hero_row.find_child("RowButton", true, false) as Button


func get_hospital_select_button(mercenary_id: String) -> Button:
	return _hospital_rows[mercenary_id].find_child("RowButton", true, false) as Button if _hospital_rows.has(mercenary_id) else null


func get_hospital_confirm_button() -> Button:
	return _hospital_confirm_button


## The texts of the Hero row ("hero") or a Mercenary row (stable id).
func get_hospital_row_texts(id: String) -> Dictionary:
	var row: Node = _hospital_hero_row if id == Mercenary.HERO_ID else _hospital_rows.get(id)
	if row == null:
		return {}
	var texts := {}
	for line in ["NameLabel", "HpMpLabel", "StateLabel", "PriceLabel"]:
		texts[line] = (row.find_child(line, true, false) as Label).text
	texts["button"] = (row.find_child("RowButton", true, false) as Button).text
	return texts


func get_hospital_summary_texts() -> Dictionary:
	return {"summary": _hospital_summary_label.text, "short": _hospital_short_label.text, "confirm": _hospital_confirm_button.text}


## The result of 免費恢復 / 確認治療 (RecoveryService via main.gd). On success
## the selection is cleared; on a stale choice it is dropped. main.gd then
## shows the fresh status (refused / failed: the restored state).
func show_hospital_feedback(result: Dictionary, hero_only: bool) -> void:
	if result.get("success", false):
		var parts := []
		if result.get("hero_recovered", false):
			parts.append(HOSPITAL_HERO_SUCCESS_TEXT)
		var count: int = (result.get("mercenary_ids", []) as Array).size()
		if count > 0 and not hero_only:
			parts.append(HOSPITAL_SUCCESS_TEXT % [count, _thousands(int(result.get("total", 0)))])
		_feedback_label.text = "；".join(parts)
		# The free Hero recovery leaves the Mercenary choice as it is.
		if not hero_only:
			_hospital_selected.clear()
	else:
		var reason: String = result.get("reason", "")
		_feedback_label.text = HOSPITAL_FAILURE_MESSAGES.get(reason, HOSPITAL_GENERIC_FAILURE)
		if reason in ["ERR_NOT_NEEDED", "ERR_UNKNOWN_MERCENARY", "ERR_DUPLICATE", "ERR_HERO_SELECTED", "ERR_INVALID_REQUEST"]:
			_hospital_selected.clear()
	_refresh_hospital()


func _hospital_entry(mercenary_id: String) -> Dictionary:
	for entry in _hospital_status.get("mercenaries", []):
		if entry["id"] == mercenary_id:
			return entry
	return {}


func _on_hospital_toggle(mercenary_id: String) -> void:
	toggle_hospital_selection(mercenary_id)


func _on_hospital_hero_pressed() -> void:
	hospital_hero_requested.emit()


func _on_hospital_confirm_pressed() -> void:
	if _hospital_selected.is_empty():
		return
	hospital_recover_requested.emit(_hospital_selected.duplicate())


func _build_mercenary_panel() -> void:
	_mercenary_count_label = _make_label("MercenaryCountLabel", "", NAME_FONT_SIZE + 2)
	_mercenary_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mercenary_panel.add_child(_mercenary_count_label)
	_mercenary_owned_label = _make_label("MercenaryOwnedLabel", MERCENARY_NONE_TEXT, DETAIL_FONT_SIZE)
	_mercenary_owned_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mercenary_owned_label.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_mercenary_owned_label.custom_minimum_size = Vector2(RECRUIT_INFO_WIDTH + RECRUIT_BUTTON_SIZE.x, 0)
	_deployed_count_label = _make_label("DeployedCountLabel", DEPLOYED_COUNT_TEXT % [0, 3], NAME_FONT_SIZE)
	_deployed_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_mercenary_panel.add_child(_deployed_count_label)
	var views := HBoxContainer.new()
	views.name = "MercenaryViews"
	views.alignment = BoxContainer.ALIGNMENT_CENTER
	views.add_theme_constant_override("separation", 16)
	_recruit_view_button = _make_button("RecruitViewButton", RECRUIT_VIEW_TEXT, show_mercenary_view.bind(MERCENARY_VIEW_RECRUIT))
	_roster_view_button = _make_button("RosterViewButton", ROSTER_VIEW_TEXT, show_mercenary_view.bind(MERCENARY_VIEW_ROSTER))
	for button in [_recruit_view_button, _roster_view_button]:
		(button as Button).custom_minimum_size = Vector2(220, 64)
		views.add_child(button)
	_mercenary_panel.add_child(views)
	_mercenary_panel.add_child(_mercenary_owned_label)
	_recruit_box = VBoxContainer.new()
	_recruit_box.name = "RecruitBox"
	_recruit_box.add_theme_constant_override("separation", 12)
	_mercenary_panel.add_child(_recruit_box)
	_roster_scroll = ScrollContainer.new()
	_roster_scroll.name = "RosterScroll"
	_roster_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_roster_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_mercenary_panel.add_child(_roster_scroll)
	_roster_box = VBoxContainer.new()
	_roster_box.name = "RosterBox"
	_roster_box.add_theme_constant_override("separation", 10)
	_roster_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_roster_scroll.add_child(_roster_box)
	_pending_box = VBoxContainer.new()
	_pending_box.name = "PendingBox"
	_pending_box.add_theme_constant_override("separation", 6)
	_roster_box.add_child(_pending_box)
	_roster_empty_label = _make_label("RosterEmptyLabel", MERCENARY_NONE_TEXT, DETAIL_FONT_SIZE)
	_roster_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_roster_box.add_child(_roster_empty_label)
	_build_dismiss_modal()
	_build_dismiss_blocked_modal()
	show_mercenary_view(MERCENARY_VIEW_RECRUIT)
	for type in RecruitmentService.TYPES:
		var row := HBoxContainer.new()
		row.name = "Recruit" + type
		row.add_theme_constant_override("separation", 16)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(RECRUIT_INFO_WIDTH, 0)
		info.add_theme_constant_override("separation", 0)
		info.add_child(_make_label("NameLabel", "%s　%s" % [RecruitmentService.TYPE_NAMES[type], RecruitmentService.ROLE_TEXT[type]], NAME_FONT_SIZE + 2))
		info.add_child(_make_label("HintLabel", RecruitmentService.HINT_TEXT[type], DETAIL_FONT_SIZE - 2))
		info.add_child(_make_label("PriceLabel", MERCENARY_PRICE_TEXT % _thousands(RecruitmentService.PRICE), DETAIL_FONT_SIZE))
		row.add_child(info)
		var button := _make_button("RecruitButton", RECRUIT_BUTTON_TEXT, _on_recruit_pressed.bind(type))
		button.custom_minimum_size = RECRUIT_BUTTON_SIZE
		row.add_child(button)
		_recruit_box.add_child(row)
		_recruit_rows[type] = row


## Stage 8 P03: one row per owned Mercenary: its lines, 設為出戰 / 取消出戰 and
## 解僱 (a deployed one says so instead of opening the confirmation).
## Stage 8 P05: the pending legacy section: its title, one row per pending
## Mercenary (name, Level, 領取) and, while the roster is full, the hint.
func _rebuild_pending_rows(pending: Array, full: bool) -> void:
	for child in _pending_box.get_children():
		_pending_box.remove_child(child)
		child.queue_free()
	_pending_rows.clear()
	_pending_box.visible = not pending.is_empty()
	if pending.is_empty():
		return
	var title := _make_label("PendingTitle", PENDING_TITLE_TEXT, NAME_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.88, 0.75, 0.36))
	_pending_box.add_child(title)
	for entry in pending:
		var id: String = entry["id"]
		var row := HBoxContainer.new()
		row.name = "Pending_" + id
		row.add_theme_constant_override("separation", 12)
		var info := _make_label("PendingInfo", PENDING_ROW_TEXT % [entry["label"], entry["level"]], NAME_FONT_SIZE)
		info.custom_minimum_size = Vector2(ROSTER_ROW_INFO_WIDTH + DISMISS_BUTTON_SIZE.x + 12, 0)
		row.add_child(info)
		var claim := _make_button("ClaimButton", CLAIM_TEXT, _on_claim_pressed.bind(id))
		claim.custom_minimum_size = ROSTER_BUTTON_SIZE
		claim.disabled = full
		row.add_child(claim)
		_pending_box.add_child(row)
		_pending_rows[id] = row
	if full:
		var hint := _make_label("PendingFullHint", ROSTER_FULL_CLAIM_TEXT, DETAIL_FONT_SIZE - 2)
		hint.add_theme_color_override("font_color", Color(1.0, 0.6, 0.5))
		_pending_box.add_child(hint)


## Stage 8 P05: one claim per press; the button waits for the next rebuild.
func _on_claim_pressed(mercenary_id: String) -> void:
	if not _pending_rows.has(mercenary_id):
		return
	var button := get_claim_button(mercenary_id)
	if button == null or button.disabled:
		return
	button.disabled = true
	claim_requested.emit(mercenary_id)


func get_pending_ids() -> Array:
	return _pending_rows.keys()


func get_claim_button(mercenary_id: String) -> Button:
	return _pending_rows[mercenary_id].find_child("ClaimButton", true, false) as Button if _pending_rows.has(mercenary_id) else null


## The pending section's texts: {"title", "rows": {id: text}, "hint"}.
func get_pending_texts() -> Dictionary:
	var rows := {}
	for id in _pending_rows:
		rows[id] = (_pending_rows[id].find_child("PendingInfo", true, false) as Label).text
	var hint := _pending_box.find_child("PendingFullHint", true, false) as Label
	var title := _pending_box.find_child("PendingTitle", true, false) as Label
	return {"title": title.text if title != null else "", "rows": rows, "hint": hint.text if hint != null else ""}


## Stage 8 P05: the list keeps its natural height up to
## ROSTER_SCROLL_MAX_HEIGHT, then scrolls.
func _fit_roster_scroll() -> void:
	var needed := _roster_box.get_combined_minimum_size()
	_roster_scroll.custom_minimum_size = Vector2(needed.x, minf(needed.y, ROSTER_SCROLL_MAX_HEIGHT))


func _rebuild_roster_rows(entries: Array) -> void:
	for row in _roster_rows.values():
		_roster_box.remove_child(row)
		row.queue_free()
	_roster_rows.clear()
	_roster_entries.clear()
	_roster_empty_label.visible = entries.is_empty()
	for entry in entries:
		var id: String = entry["id"]
		var row := HBoxContainer.new()
		row.name = "Merc_" + id
		row.add_theme_constant_override("separation", 12)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(ROSTER_ROW_INFO_WIDTH, 0)
		info.add_theme_constant_override("separation", 0)
		var title := _make_label("TitleLabel", entry["title"], NAME_FONT_SIZE)
		if entry["deployed"]:
			title.add_theme_color_override("font_color", Color(0.88, 0.75, 0.36))
		info.add_child(title)
		# P04 (P03 AC03): the instance's stats and derived values follow its
		# points.
		for line in [["HintLabel", "hint"], ["ProgressLabel", "progress"], ["AllocationLabel", "allocation"], ["StatsLabel", "stats"], ["DerivedLabel", "derived"]]:
			var label := _make_label(line[0], entry.get(line[1], ""), DETAIL_FONT_SIZE - 4)
			label.clip_text = true
			label.custom_minimum_size = Vector2(ROSTER_ROW_INFO_WIDTH, 0)
			info.add_child(label)
		row.add_child(info)
		# The buttons, with the not-open-yet equipment note under them (keeps
		# five rows inside the 720 x 1280 canvas).
		var side := VBoxContainer.new()
		side.name = "Side"
		side.add_theme_constant_override("separation", 0)
		var buttons := HBoxContainer.new()
		buttons.name = "Buttons"
		buttons.add_theme_constant_override("separation", 12)
		var deploy := _make_button("DeployButton", UNDEPLOY_TEXT if entry["deployed"] else DEPLOY_TEXT, _on_deploy_pressed.bind(id, not entry["deployed"]))
		deploy.custom_minimum_size = ROSTER_BUTTON_SIZE
		buttons.add_child(deploy)
		var dismiss := _make_button("DismissButton", DISMISS_TEXT, _on_dismiss_pressed.bind(id))
		dismiss.custom_minimum_size = DISMISS_BUTTON_SIZE
		buttons.add_child(dismiss)
		side.add_child(buttons)
		var pending := _make_label("PendingLabel", entry.get("pending", ""), DETAIL_FONT_SIZE - 4)
		pending.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		side.add_child(pending)
		row.add_child(side)
		_roster_box.add_child(row)
		_roster_rows[id] = row
		_roster_entries[id] = entry


## A full-screen confirmation in front of the hub (it takes every touch).
func _build_dismiss_modal() -> void:
	_dismiss_modal = ColorRect.new()
	_dismiss_modal.name = "DismissModal"
	(_dismiss_modal as ColorRect).color = Color(0.0, 0.0, 0.0, 0.7)
	_dismiss_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_dismiss_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	_dismiss_modal.visible = false
	add_child(_dismiss_modal)
	var panel := Panel.new()
	panel.name = "DismissPanel"
	panel.position = Vector2(60.0, 460.0)
	panel.size = Vector2(600.0, 340.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.13)
	style.border_color = Color(0.88, 0.75, 0.36)
	style.set_border_width_all(3)
	panel.add_theme_stylebox_override("panel", style)
	_dismiss_modal.add_child(panel)
	_dismiss_title = _make_label("TitleLabel", "", NAME_FONT_SIZE + 6)
	_dismiss_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_dismiss_title.position = Vector2(20.0, 40.0)
	_dismiss_title.size = Vector2(560.0, 60.0)
	panel.add_child(_dismiss_title)
	var note := _make_label("NoteLabel", DISMISS_CONFIRM_NOTE, DETAIL_FONT_SIZE)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	note.position = Vector2(30.0, 110.0)
	note.size = Vector2(540.0, 80.0)
	panel.add_child(note)
	var cancel := _make_button("CancelButton", DISMISS_CANCEL_TEXT, close_dismiss_confirm)
	cancel.position = Vector2(40.0, 220.0)
	cancel.size = Vector2(240.0, 88.0)
	panel.add_child(cancel)
	var confirm := _make_button("ConfirmButton", DISMISS_CONFIRM_TEXT, _on_dismiss_confirmed)
	confirm.position = Vector2(320.0, 220.0)
	confirm.size = Vector2(240.0, 88.0)
	panel.add_child(confirm)


## Stage 9 P05: the 無法解僱 notice, built like the confirmation (a
## full-screen dim in front of the hub that takes every touch).
func _build_dismiss_blocked_modal() -> void:
	_blocked_modal = ColorRect.new()
	_blocked_modal.name = "DismissBlockedModal"
	(_blocked_modal as ColorRect).color = Color(0.0, 0.0, 0.0, 0.7)
	_blocked_modal.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_blocked_modal.mouse_filter = Control.MOUSE_FILTER_STOP
	_blocked_modal.visible = false
	add_child(_blocked_modal)
	var panel := Panel.new()
	panel.name = "DismissBlockedPanel"
	panel.position = Vector2(60.0, 460.0)
	panel.size = Vector2(600.0, 360.0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.12, 0.13)
	style.border_color = Color(0.88, 0.75, 0.36)
	style.set_border_width_all(3)
	panel.add_theme_stylebox_override("panel", style)
	_blocked_modal.add_child(panel)
	var title := _make_label("TitleLabel", DISMISS_BLOCKED_TITLE, NAME_FONT_SIZE + 6)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.position = Vector2(20.0, 32.0)
	title.size = Vector2(560.0, 60.0)
	panel.add_child(title)
	for index in range(DISMISS_BLOCKED_LINES.size()):
		var line := _make_label("BodyLine%d" % index, DISMISS_BLOCKED_LINES[index], DETAIL_FONT_SIZE)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		line.position = Vector2(30.0, 108.0 + index * 52.0)
		line.size = Vector2(540.0, 52.0)
		panel.add_child(line)
		_blocked_lines.append(line)
	var ok := _make_button("OkButton", DISMISS_BLOCKED_OK_TEXT, close_dismiss_blocked)
	ok.position = Vector2(180.0, 240.0)
	ok.size = Vector2(240.0, 88.0)
	panel.add_child(ok)


func _on_deploy_pressed(mercenary_id: String, deployed: bool) -> void:
	deployment_requested.emit(mercenary_id, deployed)


## 解僱: a deployed Mercenary must be undeployed first (no confirmation);
## otherwise the confirmation opens. Nothing changes until it is confirmed.
func _on_dismiss_pressed(mercenary_id: String) -> void:
	if not _roster_entries.has(mercenary_id):
		return
	if _roster_entries[mercenary_id]["deployed"]:
		_feedback_label.text = DEPLOYED_DISMISS_TEXT
		return
	# Stage 9 P05: holding goods or equipment -> the 無法解僱 notice at once
	# (PartyService.dismiss would refuse it: ERR_HAS_ITEMS).
	if _roster_entries[mercenary_id].get("holds_anything", false):
		show_dismiss_blocked()
		return
	_dismiss_id = mercenary_id
	_dismiss_title.text = DISMISS_CONFIRM_TITLE % _roster_entries[mercenary_id]["label"]
	_dismiss_waited = 0.0
	_update_dismiss_countdown()
	_dismiss_modal.visible = true


## Stage 8 iPhone L3 corrective: the open confirmation's safety countdown.
func _process(delta: float) -> void:
	if is_dismiss_confirm_open() and get_dismiss_countdown() > 0.0:
		advance_dismiss_countdown(delta)


## Runs the countdown for `seconds` (UI time; tests feed it directly).
func advance_dismiss_countdown(seconds: float) -> void:
	if not is_dismiss_confirm_open() or seconds <= 0.0:
		return
	_dismiss_waited = minf(_dismiss_waited + seconds, DISMISS_COUNTDOWN_SECONDS)
	_update_dismiss_countdown()


## Seconds left before 確定解僱 is enabled (0 once it is).
func get_dismiss_countdown() -> float:
	return DISMISS_COUNTDOWN_SECONDS - _dismiss_waited


## 確定解僱（n） disabled while counting down (n = 5 for the first whole
## second waited, then 4 … 1), then 確定解僱 enabled.
func _update_dismiss_countdown() -> void:
	var confirm := get_dismiss_confirm_button()
	if get_dismiss_countdown() > 0.0:
		confirm.text = DISMISS_COUNTDOWN_TEXT % (int(DISMISS_COUNTDOWN_SECONDS) - int(_dismiss_waited))
		confirm.disabled = true
	else:
		confirm.text = DISMISS_CONFIRM_TEXT
		confirm.disabled = false


## 確定解僱: sends the one pending dismissal and closes (a second tap finds
## nothing pending).
func _on_dismiss_confirmed() -> void:
	# The countdown must have run out (a press while disabled does nothing).
	if get_dismiss_countdown() > 0.0:
		return
	var mercenary_id := _dismiss_id
	close_dismiss_confirm()
	if mercenary_id != "":
		dismiss_requested.emit(mercenary_id)


static func _thousands(value: int) -> String:
	var digits := str(value)
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.substr(digits.length() - 3) + grouped
		digits = digits.substr(0, digits.length() - 3)
	return digits + grouped


func _on_recruit_pressed(type: String) -> void:
	recruit_requested.emit(type)


func _make_line(node_name: String, label_names: Array, width: float = INFO_WIDTH, font_size: int = DETAIL_FONT_SIZE) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.name = node_name
	for label_name in label_names:
		var label := _make_label(label_name, "", font_size)
		label.custom_minimum_size = Vector2(width / 2.0, 0)
		line.add_child(label)
	return line


func _make_label(node_name: String, text: String, font_size: int) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", font_size)
	return label


func _make_button(node_name: String, text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = TRADE_BUTTON_SIZE
	button.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
	button.pressed.connect(on_pressed)
	return button


func _row_label(good_id: String, node_name: String) -> Label:
	return _rows[good_id].find_child(node_name, true, false) as Label


func _number(quote: Dictionary, key: String) -> String:
	return str(quote[key]) if quote.has(key) else "-"


func _on_leave_pressed() -> void:
	leave_requested.emit()


func _on_ride_pressed(destination_city_id: String) -> void:
	transport_requested.emit(destination_city_id, _transport_request_id)


func _on_deposit_pressed(good_id: String) -> void:
	if _warehouse_local:
		deposit_requested.emit(_warehouse_view_city, good_id, _warehouse_request_id)


func _on_withdraw_pressed(good_id: String) -> void:
	if _warehouse_local:
		withdraw_requested.emit(_warehouse_view_city, good_id, _warehouse_request_id)


func _build_warehouse_rows() -> void:
	for good_id in GoodsCatalog.get_ids():
		var row := HBoxContainer.new()
		row.name = good_id
		row.add_theme_constant_override("separation", 10)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(INFO_WIDTH, 0)
		info.add_theme_constant_override("separation", 0)
		info.add_child(_make_label("NameLabel", GoodsCatalog.get_good(good_id)["display_name"], NAME_FONT_SIZE))
		info.add_child(_make_line("CountLine", ["CarriedLabel", "StoredLabel"]))
		row.add_child(info)
		row.add_child(_make_button("DepositButton", "存入 1", _on_deposit_pressed.bind(good_id)))
		row.add_child(_make_button("WithdrawButton", "取出 1", _on_withdraw_pressed.bind(good_id)))
		_warehouse_rows_box.add_child(row)
		_warehouse_rows[good_id] = row


func _build_warehouse_city_tabs() -> void:
	for city in WorldLayout.ACTIVE_CITY_IDS:
		var button := Button.new()
		button.name = "City" + city
		button.text = "%s 城倉庫" % city
		button.focus_mode = Control.FOCUS_NONE
		button.custom_minimum_size = CITY_TAB_SIZE
		button.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
		button.pressed.connect(show_warehouse_city.bind(city))
		_warehouse_city_tabs.add_child(button)
		_warehouse_city_buttons[city] = button


func _warehouse_label(good_id: String, node_name: String) -> Label:
	return _warehouse_rows[good_id].find_child(node_name, true, false) as Label


## One view at a time: market rows, transport offers, warehouse rows, or the
## journey panel. The facility tabs double as the facility title (the active
## tab is disabled).
func _apply_view(facility: String) -> void:
	_facility = facility
	var in_city := not _traveling
	var transport := in_city and facility == FACILITY_TRANSPORT
	var warehouse := in_city and facility == FACILITY_WAREHOUSE
	var mercenary := in_city and facility == FACILITY_MERCENARY
	var equipment := in_city and facility == FACILITY_EQUIPMENT
	var hospital := in_city and facility == FACILITY_HOSPITAL
	var market := in_city and not transport and not warehouse and not mercenary and not equipment and not hospital
	# The warehouse view trades the title, money and note lines for its own
	# status line and city selector so the portrait layout keeps its height.
	# The market view drops the prototype title for its T05 expected-result
	# lines (prototype UI adjustment).
	_title_label.visible = in_city and not warehouse and not market and not mercenary and not equipment and not hospital
	_money_label.visible = not warehouse
	_facility_tabs.visible = in_city
	_note_label.visible = in_city and not warehouse
	_warehouse_status_label.visible = warehouse
	_warehouse_city_tabs.visible = warehouse
	_leave_button.visible = in_city
	_market_rows.visible = market
	_transport_rows_box.visible = transport
	_warehouse_rows_box.visible = warehouse
	_warehouse_summary_label.visible = warehouse
	# The warehouse view shows carrying capacity in its own summary line.
	_cargo_label.visible = not warehouse and not mercenary and not equipment and not hospital
	_mercenary_panel.visible = mercenary
	_hospital_panel.visible = hospital
	_hospital_tab.visible = in_city and has_hospital()
	# Stage 9 P02: the shop shows the chosen character's own capacity.
	_equipment_panel.visible = equipment
	_travel_panel.visible = _traveling
	_note_label.text = TRANSPORT_NOTE if transport else (WAREHOUSE_NOTE if warehouse else (MERCENARY_NOTE if mercenary else (EQUIPMENT_NOTE if equipment else (HOSPITAL_NOTE % _thousands(int(_hospital_status.get("mercenary_price", 0))) if hospital else MARKET_NOTE))))
	_market_tab.disabled = market
	_transport_tab.disabled = transport
	_warehouse_tab.disabled = warehouse
	_mercenary_tab.disabled = mercenary
	_equipment_tab.disabled = equipment
	_hospital_tab.disabled = hospital


static func _seconds(ms: int) -> int:
	return (maxi(ms, 0) + 999) / 1000


func _on_buy_pressed(good_id: String, quantity: int) -> void:
	buy_requested.emit(good_id, quantity)


func _on_sell_pressed(good_id: String, quantity: int) -> void:
	sell_requested.emit(good_id, quantity)
