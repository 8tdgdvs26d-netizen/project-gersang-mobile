class_name CityHub
extends CanvasLayer

## Shared prototype City Hub overlay used by every active city, including a
## minimal player market. The hub only displays state and forwards button
## presses as requests; every trade runs in main.gd.

signal leave_requested
signal buy_requested(good_id: String)
signal sell_requested(good_id: String)

const NAME_WIDTH := 170.0
const PRICE_WIDTH := 130.0
const HELD_WIDTH := 100.0
const TRADE_BUTTON_SIZE := Vector2(120, 88)
const ROW_FONT_SIZE := 22
const FAILURE_MESSAGES := {
	"insufficient_money": "Not enough money",
	"insufficient_cargo_space": "Not enough cargo space",
	"insufficient_cargo": "Not enough goods",
}

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
	_city_label.text = "[ City %s ]" % city_id
	_feedback_label.text = ""
	visible = true


## Developer-only debug line; the cargo model itself lives outside the hub.
func show_cargo_summary(used: int, capacity: int) -> void:
	_cargo_label.text = "Cargo: %d / %d" % [used, capacity]


## Developer-only debug line; the money model itself lives outside the hub.
func show_money(balance: int) -> void:
	_money_label.text = "Money: %d" % balance


## Refreshes every market row for the open city. Prices are read from
## MarketPrices; holdings come from a copy of the cargo contents.
func show_market(holdings: Dictionary) -> void:
	for good_id in _rows:
		var price := MarketPrices.get_price(city_id, good_id)
		_row_label(good_id, "PriceLabel").text = "Price %d" % price if price > 0 else "Price -"
		_row_label(good_id, "HeldLabel").text = "Held %d" % holdings.get(good_id, 0)


func show_trade_feedback(action: String, good_id: String, quantity: int, result: Dictionary) -> void:
	if result.get("success", false):
		var good_name: String = GoodsCatalog.get_good(good_id).get("display_name", good_id)
		var verb := "Bought" if action == "buy" else "Sold"
		_feedback_label.text = "%s %d %s for %d" % [verb, quantity, good_name, result["total_value"]]
	else:
		_feedback_label.text = FAILURE_MESSAGES.get(result.get("reason", ""), "Trade failed")


func close() -> void:
	city_id = ""
	_city_label.text = ""
	_cargo_label.text = ""
	_money_label.text = ""
	_feedback_label.text = ""
	for good_id in _rows:
		_row_label(good_id, "PriceLabel").text = ""
		_row_label(good_id, "HeldLabel").text = ""
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


## Returns the displayed name, price and held text of one market row.
func get_market_row_texts(good_id: String) -> Dictionary:
	if not _rows.has(good_id):
		return {}
	return {
		"name": _row_label(good_id, "NameLabel").text,
		"price": _row_label(good_id, "PriceLabel").text,
		"held": _row_label(good_id, "HeldLabel").text,
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
		row.add_child(_make_label("NameLabel", GoodsCatalog.get_good(good_id)["display_name"], NAME_WIDTH))
		row.add_child(_make_label("PriceLabel", "", PRICE_WIDTH))
		row.add_child(_make_label("HeldLabel", "", HELD_WIDTH))
		row.add_child(_make_button("BuyButton", "Buy 1", _on_buy_pressed.bind(good_id)))
		row.add_child(_make_button("SellButton", "Sell 1", _on_sell_pressed.bind(good_id)))
		_market_rows.add_child(row)
		_rows[good_id] = row


func _make_label(node_name: String, text: String, width: float) -> Label:
	var label := Label.new()
	label.name = node_name
	label.text = text
	label.custom_minimum_size = Vector2(width, 0)
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	return label


func _make_button(node_name: String, text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.name = node_name
	button.text = text
	button.custom_minimum_size = TRADE_BUTTON_SIZE
	button.add_theme_font_size_override("font_size", ROW_FONT_SIZE)
	button.pressed.connect(on_pressed)
	return button


func _row_label(good_id: String, node_name: String) -> Label:
	return _rows[good_id].get_node(node_name) as Label


func _on_leave_pressed() -> void:
	leave_requested.emit()


func _on_buy_pressed(good_id: String) -> void:
	buy_requested.emit(good_id)


func _on_sell_pressed(good_id: String) -> void:
	sell_requested.emit(good_id)
