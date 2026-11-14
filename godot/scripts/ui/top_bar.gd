class_name TopBar
extends PanelContainer
## Mission bar: logo, site, a live Mars clock (sol, LTST, LMST, Ls, UTC), the EVA clock,
## GO/NO-GO and space-weather badges, the master alarm, the server link light and the view-mode switch.
## The GO badge counts the seconds while a plan computes and the link light counts how long it has been
## down (NASA-STD-3001 Table 10.2-1: progress within 1 s; [V2 10020]: say when data goes stale).

signal mode_requested(mode: String)
signal help_requested
signal settings_requested
signal demo_requested
signal tower_requested
signal site_requested(id: String)
signal cw_requested

var gear_btn: Button
var help_btn: Button
var demo_btn: Button
var tower_btn: Button

var _sol: Label
var _ltst: Label
var _lmst: Label
var _ls: Label
var _utc: Label
var _eva: Label
var _eva_sub: Label
var _site_btn: MenuButton
var _site_ids: Array = []
var _go: PanelContainer
var _swx: PanelContainer
var _link: Control
var _cw_btn: Button
var _plan_t0 := -1
var _down_t0 := -1
var _btn_orbit: Button
var _btn_walk: Button
var _acc := 0.0
var _go_state := ""
var _row: HBoxContainer
var _fit_queued := false
var _fit_width := 0.0   # the row's width when it was last fitted


func _init() -> void:
	material = UiKit.glass_material(3.0)
	var sb := UiKit.box(Color(0.016, 0.024, 0.036, 0.66), Color(0, 0, 0, 0), 0, 0, 14)
	sb.border_width_bottom = 1
	sb.border_color = Color(UiKit.ACCENT, 0.25)
	sb.content_margin_top = 7
	sb.content_margin_bottom = 7
	add_theme_stylebox_override("panel", sb)
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	var h := UiKit.hbox(20)
	add_child(h)
	var logo := Control.new()
	logo.custom_minimum_size = Vector2(34, 34)
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	logo.draw.connect(func():
		var c := Vector2(17, 17)
		var t := Time.get_ticks_msec() / 1000.0
		logo.draw_circle(c, 10, UiKit.MARS.darkened(0.2))
		logo.draw_circle(c + Vector2(-2.5, -3), 6.5, UiKit.MARS)
		logo.draw_arc(c, 15, t, t + 4.4, 32, UiKit.ACCENT, 2.0, true)
		logo.draw_circle(c + Vector2(cos(t + 4.4), sin(t + 4.4)) * 15.0, 2.2, Color.WHITE))
	h.add_child(logo)
	var tv := UiKit.vbox(0)
	tv.add_child(UiKit.label("MARTIAN MAP", 17, UiKit.TEXT, 700))
	var site_l := UiKit.caps("EVA console", UiKit.ACCENT, 10)
	site_l.name = "Site"
	tv.add_child(site_l)
	h.add_child(tv)
	_site_btn = MenuButton.new()
	_site_btn.text = "SITE  ▾"
	_site_btn.flat = true
	_site_btn.focus_mode = Control.FOCUS_NONE
	_site_btn.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_site_btn.tooltip_text = "Switch landing site (the console reloads that site's terrain and plan)"
	_site_btn.add_theme_font_override("font", UiKit.caps_font())
	_site_btn.add_theme_font_size_override("font_size", 11)
	_site_btn.add_theme_color_override("font_color", UiKit.ACCENT)
	_site_btn.visible = false
	_site_btn.get_popup().id_pressed.connect(_on_site_menu)
	h.add_child(_site_btn)
	h.add_child(UiKit.spacer(0, true))
	_sol = _clock_block(h, "SOL", "—")
	_ltst = _clock_block(h, "LTST · local true solar", "—")
	_lmst = _clock_block(h, "LMST", "—")
	_ls = _clock_block(h, "SEASON", "—")
	_utc = _clock_block(h, "EARTH UTC", "—")
	h.add_child(UiKit.spacer(0, true))
	var ev := UiKit.vbox(0)
	ev.add_child(UiKit.caps("EVA CLOCK", UiKit.DIM, 10))
	_eva = UiKit.label("T+00:00:00", 18, UiKit.ACCENT, 600, true)
	ev.add_child(_eva)
	h.add_child(ev)
	_eva_sub = UiKit.label("", 11, UiKit.DIM)
	var badges := UiKit.vbox(4)
	badges.alignment = BoxContainer.ALIGNMENT_CENTER
	_go = UiKit.chip("PLANNING", UiKit.DIM)
	_swx = UiKit.chip("SPACE WX …", UiKit.DIM)
	badges.add_child(_go)
	badges.add_child(_swx)
	h.add_child(badges)
	_cw_btn = UiKit.button("C&W ✓", func(): cw_requested.emit(), "Master alarm: caution & warning. Click for the alert list, log and catalogue  [F3]")
	_cw_btn.add_theme_font_override("font", UiKit.symbols())
	_cw_btn.custom_minimum_size = Vector2(96, 0)
	h.add_child(_cw_btn)
	CW.changed.connect(_update_cw)
	CW.annunciate.connect(func(_a: Dictionary): _update_cw())
	_link = Control.new()
	_link.custom_minimum_size = Vector2(84, 34)
	_link.mouse_filter = Control.MOUSE_FILTER_STOP
	_link.tooltip_text = "Mission server link"
	_link.draw.connect(_draw_link)
	h.add_child(_link)
	var modes := UiKit.hbox(0)
	_btn_orbit = UiKit.button("ORBIT", func(): mode_requested.emit("orbit"), "3D map view  [V]", true)
	_btn_walk = UiKit.button("HELMET", func(): mode_requested.emit("walk"), "First-person walk with the helmet HUD  [V]", true)
	var g := ButtonGroup.new()
	_btn_orbit.button_group = g
	_btn_walk.button_group = g
	_btn_orbit.button_pressed = true
	_btn_orbit.add_theme_stylebox_override("normal", UiKit.box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.1), 7, 1, 12))
	modes.add_child(_btn_orbit)
	modes.add_child(_btn_walk)
	h.add_child(modes)
	tower_btn = UiKit.button("TOWER", func(): tower_requested.emit(), "The data layers lift off the terrain as a stack, each named with its mission and instrument")
	h.add_child(tower_btn)
	demo_btn = UiKit.button("▶ DEMO", func(): demo_requested.emit(), "A hands-free fly-through: orbit, chase and helmet along the EVA. Any key, click or stick takes over.")
	demo_btn.add_theme_font_override("font", UiKit.symbols())
	h.add_child(demo_btn)
	gear_btn = UiKit.button("⚙", func(): settings_requested.emit(), "Settings: quality, interface size, mouse, sound  [F2]")
	gear_btn.add_theme_font_override("font", UiKit.symbols())
	h.add_child(gear_btn)
	help_btn = UiKit.button("?", func(): help_requested.emit(), "Keys and controls  [F1]")
	h.add_child(help_btn)
	_row = h


func _ready() -> void:
	(get_parent() as Control).resized.connect(_queue_fit)
	_queue_fit()


func _queue_fit() -> void:
	if not _fit_queued:
		_fit_queued = true
		_fit.call_deferred()


## Narrow screens or a larger interface size: drop the least important details, one at a time, until
## the row fits (tighter gaps, LMST, the long LTST caption, Earth UTC, the DEMO label, the season).
## The Mars clocks also show in the CONDITIONS tab. Starts from the full bar each time.
func _fit() -> void:
	_fit_queued = false
	var avail := get_parent_area_size().x - 44.0   # the panel's side margins, and room for the badges to change
	var lmst := _lmst.get_parent() as Control
	var utc := _utc.get_parent() as Control
	var season := _ls.get_parent() as Control
	var ltst_cap := (_ltst.get_parent() as Control).get_child(0) as Label
	_row.add_theme_constant_override("separation", 20)
	for c in [lmst, utc, season]:
		(c as Control).visible = true
	ltst_cap.text = "LTST · LOCAL TRUE SOLAR"
	demo_btn.text = "▶ DEMO"
	var steps: Array[Callable] = [
		func(): _row.add_theme_constant_override("separation", 12),
		func(): lmst.visible = false,
		func(): ltst_cap.text = "LTST",
		func(): utc.visible = false,
		func(): demo_btn.text = "▶",
		func(): season.visible = false,
	]
	for s in steps:
		if _row_width() <= avail:
			break
		s.call()
	_fit_width = _row_width()


func _row_width() -> float:
	var n := 0
	var w := 0.0
	for c in _row.get_children():
		var cc := c as Control
		if cc and cc.visible:
			w += cc.get_combined_minimum_size().x
			n += 1
	return w + _row.get_theme_constant("separation") * maxi(n - 1, 0)


## The ORBIT / HELMET switch, for the guided tour to point at.
func mode_rect() -> Rect2:
	return _btn_orbit.get_global_rect().merge(_btn_walk.get_global_rect())


func _clock_block(parent: Control, cap: String, val: String) -> Label:
	var v := UiKit.vbox(0)
	v.add_child(UiKit.caps(cap, UiKit.FAINT, 9))
	var l := UiKit.label(val, 15, UiKit.TEXT, 500, true)
	v.add_child(l)
	parent.add_child(v)
	return l


func set_sites(list: Array, current: String) -> void:
	var pm := _site_btn.get_popup()
	pm.clear()
	_site_ids.clear()
	for s in list:
		var built := bool(s.get("built", false))
		var label := "%s%s" % [str(s.get("name", s.get("id", "?"))), "" if built else "   (not built)"]
		pm.add_radio_check_item(label, _site_ids.size())
		var idx := pm.get_item_count() - 1
		pm.set_item_checked(idx, str(s.get("id", "")) == current)
		pm.set_item_disabled(idx, not built)
		_site_ids.append(str(s.get("id", "")))
	_site_btn.visible = list.size() > 1
	_queue_fit()


func _on_site_menu(i: int) -> void:
	if i >= 0 and i < _site_ids.size():
		site_requested.emit(_site_ids[i])


func set_site(name: String) -> void:
	var l := find_child("Site", true, false) as Label
	if l:
		l.text = name.to_upper()
	_queue_fit()


func set_mode(mode: String) -> void:
	_btn_orbit.set_pressed_no_signal(mode != "walk")
	_btn_walk.set_pressed_no_signal(mode == "walk")


func set_go(go: Variant) -> void:
	var state := "PLANNING" if go == null else ("GO" if bool(go) else "NO-GO")
	var col := UiKit.DIM if go == null else (UiKit.GOOD if bool(go) else UiKit.BAD)
	_plan_t0 = Time.get_ticks_msec() if go == null else -1
	UiKit.set_chip(_go, ("EVA " + state + (" ✓" if bool(go) else " ✕")) if state != "PLANNING" else "PLANNING …", col, go != null)
	if state != _go_state:
		_go_state = state
		UiKit.flash(_go, Color(2, 2, 2))


func set_space_weather(sw: Dictionary) -> void:
	var st := str(sw.get("status", "UNKNOWN"))
	var col: Color = {"GREEN": UiKit.GOOD, "AMBER": UiKit.AMBER, "RED": UiKit.BAD}.get(st, UiKit.DIM)
	UiKit.set_chip(_swx, "SPACE WX " + st, col)
	_swx.tooltip_text = "\n".join(PackedStringArray(sw.get("reasons", [])))
	_swx.mouse_filter = Control.MOUSE_FILTER_PASS


## The master alarm: the highest unacknowledged class and how many; flashes for an emergency.
func _update_cw() -> void:
	var m := CW.master()
	var lv := str(m["level"])
	var n := int(m["n"])
	if lv == "" or lv == "advisory":
		var inh := CW.inhibited().size()
		_cw_btn.text = "C&W ✓" + (" · %d INH" % inh if inh > 0 else "")
		_cw_btn.add_theme_color_override("font_color", UiKit.GOOD)
		_cw_btn.remove_theme_stylebox_override("normal")
		return
	var col := UiKit.level_col(lv)
	_cw_btn.text = "⚠ %s %d" % [{"emergency": "EMERG", "warning": "WARN", "caution": "CAUT"}.get(lv, lv.to_upper()), n]
	var flash := lv == "emergency" and not UiKit.reduce_flashing and int(Time.get_ticks_msec() / 250) % 2 == 0
	_cw_btn.add_theme_color_override("font_color", Color(0.02, 0.03, 0.04) if not flash else Color.WHITE)
	_cw_btn.add_theme_stylebox_override("normal", UiKit.box(col if not flash else col.darkened(0.4), col, 7, 1, 10))


func _process(delta: float) -> void:
	_acc += delta
	_link.queue_redraw()
	if CW.master()["level"] == "emergency":
		_update_cw()
	if _plan_t0 >= 0:
		UiKit.set_chip(_go, "PLANNING %d s" % int((Time.get_ticks_msec() - _plan_t0) / 1000.0), UiKit.DIM)
	(get_child(0).get_child(0) as Control).queue_redraw()
	if _acc < 0.25:
		return
	_acc = 0.0
	if Mission.site.is_empty():
		return
	var c := Mission.now_clock()
	_sol.text = "%d" % int(c["sol"])
	_ltst.text = MarsTime.hms(float(c["ltst"]))
	_lmst.text = MarsTime.hms(float(c["lmst"]), false)
	_ls.text = "Ls %.1f° %s" % [float(c["ls"]), MarsTime.season(float(c["ls"]), Mission.site_lat())]
	_utc.text = Time.get_time_string_from_unix_time(int(float(c["unix"])))
	if Mission.has_plan():
		var unix := Mission.unix_at(Mission.eva_t)
		var lt := MarsTime.ltst(MarsTime.at(unix), Mission.site_lon())
		_eva.text = MarsTime.clock(Mission.eva_t)
		_eva.tooltip_text = "EVA time at %s LTST" % MarsTime.hms(lt, false)
		_eva.add_theme_color_override("font_color", UiKit.ACCENT if Mission.playing else UiKit.TEXT)
	if absf(_row_width() - _fit_width) > 1.0:   # the clocks and badges got wider or narrower: fit again
		_queue_fit()


func _draw_link() -> void:
	var on := Api.online
	if on:
		_down_t0 = -1
	elif _down_t0 < 0:
		_down_t0 = Time.get_ticks_msec()
	var t := Time.get_ticks_msec() / 1000.0
	var col := UiKit.GOOD if on else UiKit.BAD
	var c := Vector2(10, 17)
	var p := 0.5 + 0.5 * sin(t * (6.0 if Api.requests_in_flight > 0 else 2.0))
	_link.draw_circle(c, 9.0, Color(col, 0.15 + 0.2 * p))
	_link.draw_circle(c, 4.5, col)
	_link.draw_string(UiKit.caps_font(), Vector2(22, 14), "LINK", HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, UiKit.DIM)
	var txt := ("%d REQ" % Api.requests_in_flight) if Api.requests_in_flight > 0 else ("OK" if on else "DOWN " + UiKit.fmt_age((Time.get_ticks_msec() - _down_t0) / 1000.0))
	_link.draw_string(UiKit.mono(500), Vector2(22, 28), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, col)
