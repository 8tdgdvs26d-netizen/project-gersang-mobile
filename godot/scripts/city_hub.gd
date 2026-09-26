class_name CityHub
extends CanvasLayer

## Shared prototype City Hub overlay used by every active city, with two
## minimal facilities (market and passenger transport) and a traveling view
## shown during a journey. The hub only displays the quotes and state it is
## given and forwards button presses as requests; every trade and journey runs
## in main.gd. All player-facing text here is Traditional Chinese.

signal leave_requested
signal buy_requested(good_id: String)
signal sell_requested(good_id: String)
signal transport_requested(destination_city_id: String, request_id: String)
signal facility_changed(facility: String)

const FACILITY_MARKET := "market"
const FACILITY_TRANSPORT := "transport"
const MARKET_NOTE := "開發原型：每次買入或賣出 1 件"
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
const FAILURE_MESSAGES := {
	"insufficient_money": "金錢不足",
	"insufficient_cargo_space": "貨物容量不足",
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
var _facility := FACILITY_MARKET
var _traveling := false

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
	_build_market_rows()


## Opens the hub of a city on its market facility.
func open(opened_city_id: String) -> void:
	city_id = opened_city_id
	_traveling = false
	_city_label.text = "【%s 城】" % city_id
	_feedback_label.text = ""
	_travel_destination_label.text = ""
	_travel_remaining_label.text = ""
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
	if _traveling or not facility in [FACILITY_MARKET, FACILITY_TRANSPORT]:
		return
	_feedback_label.text = ""
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


func show_cargo_summary(used: int, capacity: int) -> void:
	_cargo_label.text = "貨物容量：%d / %d" % [used, capacity]


func show_money(balance: int) -> void:
	_money_label.text = "金錢：%d" % balance


## Refreshes every market row from the quotes computed by the market; the hub
## never calculates prices or stock itself. Holdings are a copy of the cargo.
func show_market(quotes: Dictionary, holdings: Dictionary) -> void:
	for good_id in _rows:
		var quote: Dictionary = quotes.get(good_id, {})
		_row_label(good_id, "BuyPriceLabel").text = "買入價 %s" % _number(quote, "buy_price")
		_row_label(good_id, "BuybackPriceLabel").text = "賣出價 %s" % _number(quote, "buyback_price")
		_row_label(good_id, "HeldLabel").text = "持有 %d" % holdings.get(good_id, 0)
		_row_label(good_id, "StockLabel").text = "庫存 %s" % _number(quote, "stock")


func show_trade_feedback(action: String, good_id: String, quantity: int, result: Dictionary) -> void:
	if result.get("success", false):
		var good_name: String = GoodsCatalog.get_good(good_id).get("display_name", good_id)
		if action == "buy":
			_feedback_label.text = "已買入 %d 件%s，支付 %d" % [quantity, good_name, result["total_value"]]
		else:
			_feedback_label.text = "已賣出 %d 件%s，收入 %d" % [quantity, good_name, result["total_value"]]
	else:
		_feedback_label.text = FAILURE_MESSAGES.get(result.get("reason", ""), GENERIC_FAILURE)


func close() -> void:
	city_id = ""
	_traveling = false
	_travel_destination_label.text = ""
	_travel_remaining_label.text = ""
	_city_label.text = ""
	_cargo_label.text = ""
	_money_label.text = ""
	_feedback_label.text = ""
	for good_id in _rows:
		for node_name in ["BuyPriceLabel", "BuybackPriceLabel", "HeldLabel", "StockLabel"]:
			_row_label(good_id, node_name).text = ""
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
	return _rows[good_id].get_node("BuyButton" if action == "buy" else "SellButton") as Button


func _build_market_rows() -> void:
	for good_id in GoodsCatalog.get_ids():
		var row := HBoxContainer.new()
		row.name = good_id
		row.add_theme_constant_override("separation", 10)
		var info := VBoxContainer.new()
		info.name = "Info"
		info.custom_minimum_size = Vector2(INFO_WIDTH, 0)
		info.add_theme_constant_override("separation", 0)
		info.add_child(_make_label("NameLabel", GoodsCatalog.get_good(good_id)["display_name"], NAME_FONT_SIZE))
		info.add_child(_make_line("PriceLine", ["BuyPriceLabel", "BuybackPriceLabel"]))
		info.add_child(_make_line("StockLine", ["HeldLabel", "StockLabel"]))
		row.add_child(info)
		row.add_child(_make_button("BuyButton", "買入 1", _on_buy_pressed.bind(good_id)))
		row.add_child(_make_button("SellButton", "賣出 1", _on_sell_pressed.bind(good_id)))
		_market_rows.add_child(row)
		_rows[good_id] = row


func _make_line(node_name: String, label_names: Array) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.name = node_name
	for label_name in label_names:
		var label := _make_label(label_name, "", DETAIL_FONT_SIZE)
		label.custom_minimum_size = Vector2(INFO_WIDTH / 2.0, 0)
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


## One view at a time: market rows, transport offers, or the journey panel.
## The facility tabs double as the facility title (the active tab is disabled).
func _apply_view(facility: String) -> void:
	_facility = facility
	var in_city := not _traveling
	var transport := in_city and facility == FACILITY_TRANSPORT
	_title_label.visible = in_city
	_facility_tabs.visible = in_city
	_note_label.visible = in_city
	_leave_button.visible = in_city
	_market_rows.visible = in_city and not transport
	_transport_rows_box.visible = transport
	_travel_panel.visible = _traveling
	_note_label.text = TRANSPORT_NOTE if transport else MARKET_NOTE
	_market_tab.disabled = in_city and not transport
	_transport_tab.disabled = transport


static func _seconds(ms: int) -> int:
	return (maxi(ms, 0) + 999) / 1000


func _on_buy_pressed(good_id: String) -> void:
	buy_requested.emit(good_id)


func _on_sell_pressed(good_id: String) -> void:
	sell_requested.emit(good_id)
