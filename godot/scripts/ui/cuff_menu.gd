class_name CuffMenu
extends PanelContainer
## The cuff menu (X, or L3 on a gamepad): every crew action as one big button, so a gloved hand, the
## d-pad or the number keys can run the EVA without fine mouse work (NASA-STD-3001 [V2 11024]: suited crew
## must be able to work the interfaces they need). Up/down or the d-pad move, Enter or A runs, 1-9 run
## directly, Esc or B closes. ABORT asks twice (press again within 4 s) [V2 10080].

signal action(id: String)

var _items: Array = []      # [{id, text, enabled}]
var _sel := 0
var _box: VBoxContainer
var _armed := -1            # msec when ABORT was armed (needs a second press)
var provider: Callable      # -> Array of {id, text, enabled}: main.gd builds the items for the moment


func _init() -> void:
	add_theme_stylebox_override("panel", UiKit.box(Color(0.0, 0.05, 0.07, 0.94), Color(HelmetHud.HUD, 0.7), 10, 2, 16))
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UiKit.vbox(8)
	add_child(v)
	v.add_child(UiKit.caps("Cuff menu", HelmetHud.HUD, 12))
	_box = UiKit.vbox(6)
	v.add_child(_box)
	v.add_child(UiKit.label("▲▼ or d-pad · ENTER / A runs · 1–9 · ESC / B closes", 11, UiKit.DIM))


func open(host_size: Vector2) -> void:
	_armed = -1
	_sel = 0
	_refresh()
	visible = true
	reset_size()
	position = Vector2(host_size.x - size.x - 40.0, (host_size.y - size.y) * 0.5)
	UiKit.appear(self, 0.0, 0.18)
	Sfx.play("toggle", -6.0)


func close() -> void:
	if visible:
		visible = false
		Sfx.play("toggle", -8.0)


func _refresh() -> void:
	_items = provider.call() if provider.is_valid() else []
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	for i in _items.size():
		var it: Dictionary = _items[i]
		var idx := i
		var text := "%d   %s" % [(i + 1) % 10, str(it["text"])]
		if str(it["id"]) == "abort" and _armed >= 0:
			text = "%d   PRESS AGAIN TO CONFIRM ABORT" % ((i + 1) % 10)
		var b := UiKit.button(text, func(): _run(idx), "")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(360, 56 if UiKit.glove else 44)
		b.disabled = not bool(it.get("enabled", true))
		b.add_theme_font_size_override("font_size", 15)
		var col := UiKit.BAD if str(it["id"]) in ["abort", "cancel_abort"] else HelmetHud.HUD
		var on := i == _sel
		b.add_theme_stylebox_override("normal", UiKit.box(Color(col, 0.28 if on else 0.08), Color(col, 0.95 if on else 0.35), 7, 2 if on else 1, 12))
		b.add_theme_color_override("font_color", Color.WHITE if on else col)
		_box.add_child(b)


func _run(i: int) -> void:
	if i < 0 or i >= _items.size() or not bool((_items[i] as Dictionary).get("enabled", true)):
		return
	var id := str(_items[i]["id"])
	if id == "abort":
		var now := Time.get_ticks_msec()
		if _armed < 0 or now - _armed > 4000:
			_armed = now
			_sel = i
			_refresh()
			Sfx.play("warn", -6.0)
			return
	close()
	action.emit(id)


func _input(event: InputEvent) -> void:
	if not visible or not event.is_pressed() or event.is_echo():
		return
	var handled := true
	var key := event is InputEventKey
	if event.is_action_pressed("ui_accept") or (event is InputEventJoypadButton and event.is_action_pressed("jump")):
		_run(_sel)
	elif event.is_action_pressed("ui_down") or (key and event.is_action_pressed("move_back")):
		_sel = (_sel + 1) % maxi(1, _items.size())
		_refresh()
		Sfx.play("hover", -8.0)
	elif event.is_action_pressed("ui_up") or (key and event.is_action_pressed("move_forward")):
		_sel = (_sel - 1 + _items.size()) % maxi(1, _items.size())
		_refresh()
		Sfx.play("hover", -8.0)
	elif event.is_action_pressed("ui_cancel") or event.is_action_pressed("back") or event.is_action_pressed("cuff_menu"):
		close()
	elif event is InputEventKey and (event as InputEventKey).keycode >= KEY_0 and (event as InputEventKey).keycode <= KEY_9:
		var n := int((event as InputEventKey).keycode - KEY_0)
		_run((n + 9) % 10)
	else:
		handled = false
	if handled:
		get_viewport().set_input_as_handled()
