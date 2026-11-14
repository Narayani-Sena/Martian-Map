class_name StatTile
extends PanelContainer
## Caption + big number that counts up/down to its new value.

var _caption: Label
var _value: Label
var _unit: Label
var _sub: Label
var _shown := 0.0
var _fmt: Callable
var _tw: Tween


func _init(caption: String, unit := "", big := 22) -> void:
	add_theme_stylebox_override("panel", UiKit.box(Color(1, 1, 1, 0.035), Color(1, 1, 1, 0.07), 8, 1, 9))
	mouse_filter = Control.MOUSE_FILTER_PASS
	var v := UiKit.vbox(0)
	add_child(v)
	_caption = UiKit.caps(caption, UiKit.DIM, 10)
	v.add_child(_caption)
	var h := UiKit.hbox(4)
	v.add_child(h)
	_value = UiKit.label("—", big, UiKit.TEXT, 500, true)
	h.add_child(_value)
	_unit = UiKit.label(unit, 12, UiKit.DIM)
	_unit.size_flags_vertical = Control.SIZE_SHRINK_END
	h.add_child(_unit)
	_sub = UiKit.label("", 11, UiKit.FAINT)
	_sub.visible = false
	v.add_child(_sub)
	_fmt = func(x: float) -> String: return "%.0f" % x


func set_value(v: float, fmt: Callable = Callable(), sub := "", color := UiKit.TEXT, unit := "") -> void:
	if fmt.is_valid():
		_fmt = fmt
	if unit != "":
		_unit.text = unit
	_sub.text = sub
	_sub.visible = sub != ""
	_value.add_theme_color_override("font_color", color)
	if _tw and _tw.is_valid():
		_tw.kill()
	_tw = create_tween()
	_tw.tween_method(_show, _shown, v, 1.1).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)


func set_text(t: String, sub := "", color := UiKit.TEXT) -> void:
	_value.text = t
	_value.add_theme_color_override("font_color", color)
	_sub.text = sub
	_sub.visible = sub != ""


func _show(x: float) -> void:
	_shown = x
	_value.text = _fmt.call(x)
