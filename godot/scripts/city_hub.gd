class_name CityHub
extends CanvasLayer

## Shared prototype City Hub overlay used by every active city, including a
## minimal player market. The hub only displays the quotes and state it is
## given and forwards button presses as requests; every trade runs in main.gd.
## All player-facing text here is Traditional Chinese.

signal leave_requested
signal buy_requested(good_id: String)
signal sell_requested(good_id: String)

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

@onready var _city_label := $Center/Content/CityLabel as Label
@onready var _leave_button := $Center/Content/LeaveButton as Button
@onready var _cargo_label := $Center/Content/CargoLabel as Label
@onready var _money_label := $Center/Content/MoneyLabel as Label
@onready var _feedback_label := $Center/Content/FeedbackLabel as Label
@onready var _market_rows := $Center/Content/MarketRows as VBoxContainer


func _ready() -> void:
	visible = false
	_leave_button.pressed.connect(_on_leave_pressed)
	_build_market_rows()


func open(opened_city_id: String) -> void:
	city_id = opened_city_id
	_city_label.text = "【%s 城】" % city_id
	_feedback_label.text = ""
	visible = true


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


func _on_buy_pressed(good_id: String) -> void:
	buy_requested.emit(good_id)


func _on_sell_pressed(good_id: String) -> void:
	sell_requested.emit(good_id)
