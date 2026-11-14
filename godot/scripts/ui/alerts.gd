class_name Alerts
extends Control
## Two notification channels:
##   * the caution & warning banner: the most important unacknowledged alert from CW, in its NASA class
##     colour (red warning, flashing red emergency, yellow caution), with ACK / SILENCE / LIST. It stays
##     until acknowledged; after 10 s it shrinks to one line (in the helmet the HUD's strip carries it
##     after 4 s). Advisories (blue) come as toasts and end by themselves.
##   * toast(): small cards that slide in at the right edge and leave by themselves.

signal glitch(amount: float)
signal list_requested

var helmet := false        # the helmet HUD shows the alert itself: the big banner steps aside sooner
var muted := false         # no toasts (trailer recordings: the captions tell the story)
var _banner: PanelContainer
var _banner_title: Label
var _banner_text: Label
var _banner_do: Label
var _banner_icon: Label
var _banner_more: Label
var _banner_btns: HBoxContainer
var _ack_btn: Button
var _sil_btn: Button
var _shown := {}           # the alert on the banner
var _shown_ms := 0
var _compact := false
var _toasts: VBoxContainer


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)


func _ready() -> void:
	_banner = PanelContainer.new()
	_banner.material = UiKit.glass_material(2.5)
	_banner.mouse_filter = Control.MOUSE_FILTER_STOP
	_banner.custom_minimum_size = Vector2(600, 0)
	_banner.visible = false
	_banner.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and _compact:
			_compact = false   # click the one-line banner to see it in full again
			_shown_ms = Time.get_ticks_msec()
			_fill())
	add_child(_banner)
	var h := UiKit.hbox(14)
	_banner.add_child(h)
	_banner_icon = UiKit.label("⚠", 30, UiKit.CAUTION)
	_banner_icon.add_theme_font_override("font", UiKit.symbols())
	h.add_child(_banner_icon)
	var v := UiKit.vbox(3)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(v)
	_banner_title = UiKit.label("", 17, UiKit.TEXT, 700)
	v.add_child(_banner_title)
	_banner_text = UiKit.wrap("", 13, UiKit.TEXT)
	_banner_text.custom_minimum_size = Vector2(500, 0)
	v.add_child(_banner_text)
	_banner_do = UiKit.wrap("", 12, Color(1, 1, 1, 0.8))
	_banner_do.custom_minimum_size = Vector2(500, 0)
	v.add_child(_banner_do)
	_banner_btns = UiKit.hbox(8)
	_ack_btn = UiKit.button("ACKNOWLEDGE  ↵", func(): CW.acknowledge(str(_shown.get("id", ""))), "Acknowledge this alert: its tone and banner stop  [Enter / d-pad up]")
	_sil_btn = UiKit.button("SILENCE  ⌫", func(): CW.silence(), "Stop the tone; the alert stays on screen until acknowledged  [Backspace / d-pad down]")
	var list := UiKit.button("ALL ALERTS  F3", func(): list_requested.emit(), "Every active alert, the log, and the alert catalogue  [F3]")
	for b in [_ack_btn, _sil_btn, list]:
		_banner_btns.add_child(b)
	_banner_more = UiKit.label("", 11, Color(1, 1, 1, 0.75), 600)
	_banner_more.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_banner_more.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_banner_more.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_banner_btns.add_child(_banner_more)
	v.add_child(_banner_btns)
	_toasts = UiKit.vbox(8)
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toasts.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_toasts.custom_minimum_size = Vector2(330, 0)
	_toasts.alignment = BoxContainer.ALIGNMENT_BEGIN
	add_child(_toasts)
	resized.connect(_layout)
	CW.annunciate.connect(_on_annunciate)
	CW.changed.connect(_refresh)
	CW.audit.connect(func(titles: Array):
		toast("Alert audit: %d alert%s out of service (inhibited): %s. Enable them in F3 → CATALOGUE." % [titles.size(), "" if titles.size() == 1 else "s", ", ".join(PackedStringArray(titles))], "advisory"))
	_layout()


func _layout() -> void:
	_banner.position = Vector2((size.x - _banner.size.x) * 0.5, 118)
	# in the helmet the top centre holds the compass and the alert strip: toasts go low on the right
	_toasts.position = Vector2(size.x - 330 - 34, size.y * 0.6) if helmet else Vector2(size.x - 330 - 380, 74)


func set_helmet(on: bool) -> void:
	if on != helmet:
		helmet = on
		_layout()
		_refresh()


func _on_annunciate(a: Dictionary) -> void:
	if str(a["level"]) == "advisory":
		toast("%s — %s" % [str(a["title"]), str(a["text"])], "advisory")
		return
	_shown_ms = Time.get_ticks_msec()
	_compact = false
	_refresh()
	if not UiKit.reduce_flashing:
		glitch.emit({"emergency": 1.0, "warning": 0.8, "caution": 0.45}.get(str(a["level"]), 0.3))


## Show the top unacknowledged alert, or fade out when there is none.
func _refresh() -> void:
	var a := CW.top()
	if a.is_empty() or str(a["level"]) == "advisory":
		if _banner.visible and _banner.modulate.a > 0.99:
			var tw := create_tween()
			tw.tween_property(_banner, "modulate:a", 0.0, 0.3)
			tw.tween_callback(func(): _banner.visible = CW.top().size() > 0 and str(CW.top().get("level", "")) != "advisory")
		_shown = {}
		return
	var fresh := str(a["id"]) != str(_shown.get("id", "")) or str(a["level"]) != str(_shown.get("level", ""))
	_shown = a
	if fresh:
		_shown_ms = Time.get_ticks_msec()
		_compact = false
	if helmet:
		_banner.visible = false   # in the helmet the HUD's alert strip is the annunciator
		return
	if not _banner.visible or _banner.modulate.a < 0.99:
		_banner.visible = true
		_banner.pivot_offset = _banner.size * 0.5
		_banner.scale = Vector2(1.1, 0.3)
		_banner.modulate.a = 0.0
		var tw := create_tween().set_parallel(true)
		tw.tween_property(_banner, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tw.tween_property(_banner, "modulate:a", 1.0, 0.15)
	_fill()


func _fill() -> void:
	var a := _shown
	if a.is_empty():
		return
	var lv := str(a["level"])
	var col := UiKit.level_col(lv)
	_banner_icon.text = "☢" if str(a["id"]) in ["sep", "dose_rate", "dose_eva", "swx"] else "⚠"
	var state := ""
	if bool(a.get("cleared", false)) and not bool(a.get("event", false)):
		state = "  ·  CLEARED"
	elif bool(a.get("silenced", false)):
		state = "  ·  SILENCED"
	_banner_title.text = "%s  ·  %s%s" % [lv.to_upper(), str(a["title"]), state]
	_banner_text.text = str(a["text"])
	_banner_do.text = ("▸ " + str(a["do"])) if str(a["do"]) != "" and str(a["do"]) != str(a["text"]) else ""
	var m := CW.master()
	var more := int(m["n"]) - 1
	_banner_more.text = ("+%d more" % more) if more > 0 else ""
	_banner_text.visible = not _compact
	_banner_do.visible = not _compact and _banner_do.text != ""
	_banner_btns.visible = not _compact
	_sil_btn.disabled = bool(a.get("silenced", false))
	_banner.custom_minimum_size = Vector2(380 if _compact else 600, 0)
	_banner.reset_size()
	_style(col, lv)
	_layout()


func _style(col: Color, lv: String) -> void:
	var t := Time.get_ticks_msec()
	var flash := lv == "emergency" and not UiKit.reduce_flashing and int(t / 250) % 2 == 0
	var bg := Color(col.darkened(0.78 if not flash else 0.5), 0.9)
	var p := 0.5 + 0.5 * sin(t / 1000.0 * 7.0)
	var border := Color(col, 1.0 if UiKit.reduce_flashing else 0.45 + 0.55 * p)
	_banner.add_theme_stylebox_override("panel", UiKit.box(bg, border, 8, 3 if lv == "emergency" else 2, 12 if _compact else 14))
	_banner_icon.add_theme_color_override("font_color", Color.WHITE if flash else col)
	_banner_title.add_theme_color_override("font_color", col.lightened(0.3))


func _process(_d: float) -> void:
	if not _banner.visible or _shown.is_empty():
		return
	var age := Time.get_ticks_msec() - _shown_ms
	if helmet:
		_banner.visible = false   # the HUD's alert strip carries it
		return
	if not _compact and age > 10000:
		_compact = true
		_fill()
	_style(UiKit.level_col(str(_shown["level"])), str(_shown["level"]))


func toast(text: String, kind := "info") -> void:
	if muted:
		return
	var col: Color = {"info": UiKit.ACCENT, "ok": UiKit.GOOD, "warn": UiKit.CAUTION, "bad": UiKit.BAD, "advisory": UiKit.ADVISORY}.get(kind, UiKit.ACCENT)
	var p := PanelContainer.new()
	p.material = UiKit.glass_material(2.5)
	p.add_theme_stylebox_override("panel", UiKit.box(Color(0.02, 0.03, 0.045, 0.78), Color(col, 0.6), 7, 1, 10))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := UiKit.hbox(10)
	p.add_child(h)
	var bar := ColorRect.new()
	bar.color = col
	bar.custom_minimum_size = Vector2(3, 0)
	h.add_child(bar)
	var l := UiKit.wrap(text, 13, UiKit.TEXT)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(l)
	_toasts.add_child(p)
	# Keep the newest 4. remove_child first: queue_free() only frees at the end of the frame, so a
	# `while get_child_count() > 4: queue_free()` loop never ends and queues deletions until memory runs out.
	while _toasts.get_child_count() > 4:
		var old := _toasts.get_child(0)
		_toasts.remove_child(old)
		old.queue_free()
	p.modulate.a = 0.0
	p.pivot_offset = Vector2(330, 0)
	p.scale = Vector2(0.9, 0.9)
	var tw := p.create_tween()
	tw.set_parallel(true)
	tw.tween_property(p, "modulate:a", 1.0, 0.25)
	tw.tween_property(p, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.chain().tween_interval(4.5)
	tw.chain().tween_property(p, "modulate:a", 0.0, 0.5)
	tw.chain().tween_callback(p.queue_free)
	if kind != "advisory":   # advisories have their own NASA tone (CW plays it)
		Sfx.play("toggle" if kind == "info" else ("confirm" if kind == "ok" else "warn"), -10.0)
