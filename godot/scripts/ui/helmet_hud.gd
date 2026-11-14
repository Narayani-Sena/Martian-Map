class_name HelmetHud
extends Control
## The helmet visor HUD for walk mode. Shows the Telemetry (suit, navigation, safety) that main.gd updates
## ~8 times a second, and the caution & warning system's top alert. Built to NASA-STD-3001 Vol 2:
## suit pressure, ppO2 and ppCO2 on display [V2 11035], metabolic rate [V2 11038], every value with its unit
## [V2 10046] and a word as well as a colour when it is out of limits [V2 10045], loss-of-signal and stale
## data marked [V2 10020], the mode always shown [V2 10162], the turn-back time worked out for you [V2 10113],
## and the centre of the view kept clear [V2 11022]. Declutter, opacity and tint are settings.

signal exit_requested
signal play_requested
signal autopilot_requested
signal abort_requested     # ABORT pressed and held (or CANCEL ABORT)
signal menu_requested      # the cuff menu button

const TINTS := {"cyan": Color(0.55, 0.95, 1.0), "green": Color(0.58, 1.0, 0.64), "amber": Color(1.0, 0.82, 0.46), "white": Color(0.93, 0.96, 1.0)}
static var HUD := Color(0.55, 0.95, 1.0)
static var HUD_DIM := Color(0.55, 0.95, 1.0, 0.55)
const HINT := "hold right button or F to look · WASD walk · SHIFT lope · SPACE jump (0.38 g) · TAB autopilot · X cuff menu · ENTER acknowledge · ⌫ silence · hold END abort · V map"
const HINT_LOCK := "MOUSE-LOOK LOCKED · move the mouse to look · F or ESC frees the cursor"
const EDGE := 34.0   # margin from the screen edge
const GAP := 12.0    # between stacked panels
const HOLD_S := 1.0  # ABORT is a guarded command: hold it this long [V2 10080]

var world: MarsWorld
var tel: Telemetry
var compass: CompassTape
var minimap: MiniMap
var ecg: EcgTrace
var _panels: Array[Control] = []
var _gauges := {}
var _l := {}
var _rows := {}     # name -> Control, for decluttering
var _hazard_chip: PanelContainer
var _mode_chip: PanelContainer
var _radio_bars: Control
var _radio_level := 2
var _acc := 0.0
var _power := 0.0
var info := {}      # last numbers shown (the visor's breath fog reads "met")
var _btn_play: Button
var _btn_auto: Button
var _btn_abort: Button
var _abort_hold := -1.0
var _controls: HFlowContainer   # wraps onto two rows when the room left of the minimap is short
var _cuff: PanelContainer
var _cuff_box: VBoxContainer
var _cuff_key := ""
var _look_locked := false
var _layout_queued := false
var _cw: PanelContainer
var tools: HelmetTools   # ghost pacer and co-driver notes
var _cw_icon: Label
var _cw_title: Label
var _cw_text: Label
var _cw_more: Label
var _cw_level := ""
var declutter := "full"
var opacity := 1.0


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	visible = false
	set_tint(str(Settings.get_value("hud_tint")))


static func set_tint(name: String) -> void:
	HUD = TINTS.get(name, TINTS["cyan"])
	HUD_DIM = Color(HUD, 0.55)


func _ready() -> void:
	compass = CompassTape.new()
	compass.size = Vector2(620, 60)
	add_child(compass)
	_panels.append(compass)
	# --- clock and mode (top left)
	var tl := _panel(Vector2(340, 0))
	var tv := UiKit.vbox(2)
	tl.add_child(tv)
	var r1 := UiKit.hbox(10)
	r1.add_child(_cap("EVA"))
	_l["clock"] = _num("T+00:00:00", 24)
	r1.add_child(_l["clock"])
	_mode_chip = UiKit.chip("—", HUD, true)
	_mode_chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r1.add_child(_mode_chip)
	tv.add_child(r1)
	_l["time"] = _txt("", 12)
	tv.add_child(_l["time"])
	_rows["time"] = _l["time"]
	_l["phase"] = _txt("", 13, HUD)
	tv.add_child(_l["phase"])
	_l["suitline"] = _txt("", 12, HUD)   # minimal declutter: the suit in one line
	tv.add_child(_l["suitline"])
	_rows["suitline"] = _l["suitline"]
	# --- suit (left)
	var lt := _panel(Vector2(300, 0))
	var lv := UiKit.vbox(5)
	lt.add_child(lv)
	lv.add_child(_cap("SUIT · EMU (simulated)"))
	for spec in [["o2", "O₂ PRIMARY", false], ["pwr", "BATTERY", false], ["co2", "CO₂ SCRUBBER", true], ["h2o", "FEEDWATER", false]]:
		var g := BarGauge.new(str(spec[1]), bool(spec[2]), 24.0)
		g.segments = 30
		lv.add_child(g)
		_gauges[spec[0]] = g
	var hr := UiKit.hbox(8)
	var hrv := UiKit.vbox(0)
	hrv.add_child(_cap("HEART"))
	_l["hr"] = _num("—", 20, UiKit.GOOD)
	hrv.add_child(_l["hr"])
	hr.add_child(hrv)
	ecg = EcgTrace.new()
	ecg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hr.add_child(ecg)
	lv.add_child(hr)
	_rows["ecg"] = ecg
	var sg := UiKit.grid(3, 10, 2)
	for k in [["press", "PRESSURE"], ["ppo2", "ppO₂"], ["ppco2", "ppCO₂"], ["temp", "SUIT TEMP"], ["met", "METABOLIC"], ["dose", "EVA DOSE"]]:
		var b := UiKit.vbox(0)
		b.add_child(_cap(str(k[1])))
		_l[k[0]] = _num("—", 15)
		b.add_child(_l[k[0]])
		sg.add_child(b)
	lv.add_child(sg)
	# --- navigation and safety (right)
	var rt := _panel(Vector2(310, 0))
	var rv := UiKit.vbox(5)
	rt.add_child(rv)
	_l["nav_cap"] = _cap("NAV · NEXT WAYPOINT")
	rv.add_child(_l["nav_cap"])
	_l["target"] = _txt("—", 17, Color.WHITE, 700)
	rv.add_child(_l["target"])
	var nr := UiKit.hbox(14)
	_l["dist"] = _num("—", 26, UiKit.AMBER)
	nr.add_child(_l["dist"])
	var nv := UiKit.vbox(0)
	_l["brg"] = _txt("", 12)
	_l["eta"] = _txt("", 12)
	nv.add_child(_l["brg"])
	nv.add_child(_l["eta"])
	nr.add_child(nv)
	rv.add_child(nr)
	rv.add_child(UiKit.hline(0.12))
	var ret := UiKit.hbox(8)
	var rv1 := UiKit.vbox(0)
	_l["ret_cap"] = _cap("WALK BACK TO HAB")
	rv1.add_child(_l["ret_cap"])
	_l["ret"] = _num("—", 18)
	rv1.add_child(_l["ret"])
	rv1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ret.add_child(rv1)
	var rv2 := UiKit.vbox(0)
	rv2.add_child(_cap("MARGIN"))
	_l["margin"] = _num("—", 18, UiKit.GOOD)
	rv2.add_child(_l["margin"])
	ret.add_child(rv2)
	rv.add_child(ret)
	_l["turn"] = _txt("", 13, HUD, 600)
	rv.add_child(_l["turn"])
	_l["pace"] = _txt("", 13, HUD, 700)   # ghost pacer (feature A6)
	rv.add_child(_l["pace"])
	_l["note"] = _txt("", 12, HUD, 600)   # co-driver pace note (feature D3)
	(_l["note"] as Label).autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	rv.add_child(_l["note"])
	var sep1 := UiKit.hline(0.12)
	rv.add_child(sep1)
	var tr := UiKit.hbox(8)
	var tv1 := UiKit.vbox(0)
	tv1.add_child(_cap("SLOPE AHEAD"))
	_l["slope"] = _num("—", 18)
	tv1.add_child(_l["slope"])
	tv1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tr.add_child(tv1)
	var tv2 := UiKit.vbox(2)
	tv2.add_child(_cap("GROUND"))
	_hazard_chip = UiKit.chip("—", UiKit.DIM, true)
	tv2.add_child(_hazard_chip)
	tr.add_child(tv2)
	rv.add_child(tr)
	var lr := UiKit.hbox(8)
	var lv1 := UiKit.vbox(0)
	lv1.add_child(_cap("HAB LINK"))
	_radio_bars = Control.new()
	_radio_bars.custom_minimum_size = Vector2(118, 22)
	_radio_bars.draw.connect(_draw_radio)
	lv1.add_child(_radio_bars)
	lv1.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lr.add_child(lv1)
	var lv2 := UiKit.vbox(0)
	lv2.add_child(_cap("DOSE RATE"))
	_l["rad"] = _num("—", 15, UiKit.AMBER)
	lv2.add_child(_l["rad"])
	lr.add_child(lv2)
	rv.add_child(lr)
	var sr := UiKit.hbox(8)
	var sv := UiKit.vbox(0)
	sv.add_child(_cap("SUN"))
	_l["sun"] = _num("—", 15, Color("ffd166"))
	sv.add_child(_l["sun"])
	sv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sr.add_child(sv)
	var sv2 := UiKit.vbox(0)
	sv2.add_child(_cap("SUNSET IN"))
	_l["sunset"] = _num("—", 15, Color("ffd166"))
	sv2.add_child(_l["sunset"])
	sr.add_child(sv2)
	rv.add_child(sr)
	_rows["nav_lower"] = [sep1, tr, lr, sr]
	_rows["sun"] = sr
	# --- cuff checklist, minimap, labels, buttons
	_cuff = _panel(Vector2(310, 0))
	_cuff_box = UiKit.vbox(3)
	_cuff.add_child(_cuff_box)
	Mission.tasks_changed.connect(func(): _cuff_key = "")
	minimap = MiniMap.new()
	minimap.size = Vector2(220, 220)
	add_child(minimap)
	_panels.append(minimap)
	_l["auto"] = _txt("", 13, HUD, 600)
	add_child(_l["auto"])
	_l["hint"] = _txt(HINT, 11, HUD_DIM)
	add_child(_l["hint"])
	world.look_lock_changed.connect(func(on: bool):
		_look_locked = on
		(_l["hint"] as Label).add_theme_color_override("font_color", HUD if on else HUD_DIM)
		_queue_layout())
	_controls = HFlowContainer.new()
	_controls.add_theme_constant_override("h_separation", 8)
	_controls.add_theme_constant_override("v_separation", 8)
	_controls.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_controls)
	var exit_btn := _hud_button("◀  MAP", "Back to the orbit map  [V / Esc]", func(): exit_requested.emit())
	exit_btn.custom_minimum_size = Vector2(104, 40)
	_controls.add_child(exit_btn)
	_btn_play = _hud_button("▶  PLAY ×1", "Walk the plan in real time  [P]", func(): play_requested.emit())
	_btn_play.custom_minimum_size = Vector2(124, 40)
	_controls.add_child(_btn_play)
	_btn_auto = _hud_button("AUTOPILOT", "Follow the planned route / walk by hand  [Tab]", func(): autopilot_requested.emit())
	_btn_auto.custom_minimum_size = Vector2(140, 40)
	_controls.add_child(_btn_auto)
	var menu := _hud_button("☰  CUFF", "The cuff menu: every crew action from the d-pad or number keys  [X / L3]", func(): menu_requested.emit())
	menu.custom_minimum_size = Vector2(96, 40)
	_controls.add_child(menu)
	_btn_abort = _hud_button("ABORT", "Hold to abort the EVA: red guidance straight back to the haven  [hold End / R3]", Callable())
	_btn_abort.custom_minimum_size = Vector2(96, 40)
	_btn_abort.button_down.connect(func(): _abort_hold = 0.0)
	_btn_abort.button_up.connect(func(): _abort_hold = -1.0)
	_btn_abort.add_theme_color_override("font_color", UiKit.BAD)
	_controls.add_child(_btn_abort)
	_panels.append(_controls)
	# --- caution & warning strip (top centre, under the compass; hidden when all is well)
	_cw = PanelContainer.new()
	_cw.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_cw.visible = false
	add_child(_cw)
	var ch := UiKit.hbox(10)
	_cw.add_child(ch)
	_cw_icon = UiKit.label("⚠", 22, UiKit.CAUTION)
	_cw_icon.add_theme_font_override("font", UiKit.symbols())
	ch.add_child(_cw_icon)
	var cv := UiKit.vbox(0)
	cv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ch.add_child(cv)
	_cw_title = UiKit.label("", 15, Color.WHITE, 700)
	cv.add_child(_cw_title)
	_cw_text = UiKit.wrap("", 12, Color.WHITE)
	_cw_text.custom_minimum_size.x = 380
	cv.add_child(_cw_text)
	_cw_more = UiKit.label("", 11, Color(1, 1, 1, 0.75), 600)
	cv.add_child(_cw_more)
	CW.changed.connect(_refresh_cw)
	CW.annunciate.connect(func(_a: Dictionary): _refresh_cw())
	resized.connect(_queue_layout)
	for p in [tl, rt, _cuff, lt]:   # panels that grow with bigger text or more checklist rows
		(p as Control).resized.connect(_queue_layout)
	_cw.resized.connect(_queue_layout)
	_controls.resized.connect(_queue_layout)
	apply_view_settings()
	_layout()


## Declutter level and opacity from the settings (tint needs a rebuild: main.gd does that).
func apply_view_settings() -> void:
	declutter = str(Settings.get_value("hud_declutter"))
	opacity = clampf(float(Settings.get_value("hud_opacity")), 0.4, 1.0)
	var full := declutter == "full"
	var minimal := declutter == "minimal"
	minimap.visible = full
	ecg.visible = full
	(_l["hint"] as Label).visible = full
	(_rows["time"] as Control).visible = not minimal
	(_rows["sun"] as Control).visible = full
	(_rows["suitline"] as Control).visible = minimal
	(_panels[2] as Control).visible = not minimal   # suit panel
	for c in _rows["nav_lower"]:
		(c as Control).visible = not minimal
	for p in _panels:
		p.modulate.a = opacity
	_cuff_key = ""
	_queue_layout()


func _hud_button(text: String, tip: String, cb: Callable) -> Button:
	var b := UiKit.button(text, cb, tip)
	b.add_theme_stylebox_override("normal", UiKit.box(Color(0.0, 0.06, 0.08, 0.55), Color(HUD, 0.55), 6, 1, 12))
	b.add_theme_stylebox_override("hover", UiKit.box(Color(HUD, 0.22), HUD, 6, 1, 12))
	b.add_theme_stylebox_override("pressed", UiKit.box(Color(HUD, 0.35), HUD, 6, 1, 12))
	b.add_theme_color_override("font_color", HUD)
	b.add_theme_font_override("font", UiKit.symbols())
	b.add_theme_font_size_override("font_size", 13)
	if UiKit.glove:
		b.custom_minimum_size.y = 52.0
	return b


func _cap(t: String) -> Label:
	return UiKit.caps(t, HUD_DIM, 9)


func _num(t: String, size := 18, col: Variant = null) -> Label:
	return UiKit.label(t, size, HUD if col == null else (col as Color), 500, true)


func _txt(t: String, size := 12, col: Variant = null, weight := 500) -> Label:
	return UiKit.label(t, size, HUD_DIM if col == null else (col as Color), weight)


func _panel(min_size: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := UiKit.box(Color(0.0, 0.06, 0.08, 0.32), Color(HUD, 0.25), 4, 1, 12)
	sb.border_width_left = 3
	sb.border_color = Color(HUD, 0.5)
	p.add_theme_stylebox_override("panel", sb)
	p.custom_minimum_size = min_size
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(p)
	_panels.append(p)
	return p


func _queue_layout() -> void:
	if not _layout_queued:
		_layout_queued = true
		_layout.call_deferred()


## Placed from the panels' real sizes (they grow with the text floor and the interface-size setting),
## so nothing overlaps on a 1366x768 laptop or with "Largest" text: the suit panel sits under the clock,
## the cuff under NAV, the compass narrows between the corner panels, the alert strip hangs under the
## compass, and the key hint wraps beside the minimap.
func _layout() -> void:
	_layout_queued = false
	if compass == null:
		return
	var w := size.x
	var h := size.y
	var tl := _panels[1] as Control
	var suit := _panels[2] as Control
	var nav := _panels[3] as Control
	tl.position = Vector2(EDGE, 24)
	suit.position = Vector2(EDGE, tl.position.y + tl.size.y + GAP)
	nav.position = Vector2(w - EDGE - nav.size.x, 24)
	var half := clampf(w * 0.5 - EDGE - maxf(tl.size.x, nav.size.x) - 16.0, 150.0, 310.0)
	compass.custom_minimum_size = Vector2(half * 2.0, 58)
	compass.size = Vector2(half * 2.0, 60)
	compass.position = Vector2((w - compass.size.x) * 0.5, 16)
	if _cw:
		_cw.custom_minimum_size.x = clampf(half * 2.0, 300.0, 560.0)
		_cw.reset_size()
		_cw.position = Vector2((w - _cw.size.x) * 0.5, compass.position.y + compass.size.y + 8.0)
	if _cuff:
		_cuff.position = Vector2(w - EDGE - _cuff.size.x, nav.position.y + nav.size.y + GAP)
	minimap.position = Vector2((w - minimap.size.x) * 0.5, h - minimap.size.y - 26)
	var right_room := w - (minimap.position.x + minimap.size.x) - EDGE - 16.0
	var auto := _l["auto"] as Label
	auto.size = Vector2(clampf(right_room, 120.0, 390.0), 20)
	auto.position = Vector2(w - EDGE + 4.0 - auto.size.x, h - 44)
	auto.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var hint := _l["hint"] as Label
	var room := minimap.position.x - EDGE - 16.0 if minimap.visible else w * 0.5 - EDGE
	hint.text = _fit_lines(hint, HINT_LOCK if _look_locked else HINT, room)
	hint.reset_size()
	hint.position = Vector2(EDGE, h - 24.0 - hint.size.y)
	if _controls:
		# the buttons get the room left of the minimap and wrap onto a second row when it is short
		var room_b := (minimap.position.x - EDGE - 16.0) if minimap.visible else (w - 2.0 * EDGE)
		if absf(_controls.size.x - room_b) > 0.5:
			_controls.size = Vector2(room_b, 0)
		var need := _controls.get_combined_minimum_size().y
		if absf(_controls.size.y - need) > 0.5:
			_controls.size.y = need
		var y0 := (hint.position.y if hint.visible else h - 12.0) - 12.0 - _controls.size.y
		_controls.position = Vector2(EDGE, y0)


## The text on one line if it fits in `room`, else broken in two (or three) at the " · " nearest the middle.
func _fit_lines(l: Label, text: String, room: float) -> String:
	var f := l.get_theme_font("font")
	var fs := l.get_theme_font_size("font_size")
	if f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= room:
		return text
	var parts := text.split(" · ")
	var best := text
	var best_w := INF
	for i in range(1, parts.size()):
		var a := " · ".join(parts.slice(0, i))
		var b := " · ".join(parts.slice(i))
		var mw := maxf(f.get_string_size(a, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x, f.get_string_size(b, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
		if mw < best_w:
			best_w = mw
			best = a + "\n" + b
	if best_w > room and parts.size() >= 3:   # still too wide: three lines
		var n := parts.size()
		var k := int(ceil(n / 3.0))
		best = " · ".join(parts.slice(0, k)) + "\n" + " · ".join(parts.slice(k, 2 * k)) + "\n" + " · ".join(parts.slice(2 * k))
	return best


## Visor power-on: panels flicker in one after another (a plain fade with reduced flashing).
func power_on() -> void:
	visible = true
	_power = 0.0
	_layout()
	Sfx.play("boot", -6.0)
	for i in _panels.size():
		var p := _panels[i]
		p.modulate.a = 0.0
		var tw := p.create_tween()
		tw.tween_interval(0.25 + i * 0.16)
		if not UiKit.reduce_flashing:
			for k in 3:
				tw.tween_property(p, "modulate:a", 0.9 * opacity, 0.04)
				tw.tween_property(p, "modulate:a", 0.15, 0.05)
		tw.tween_property(p, "modulate:a", opacity, 0.3)
	create_tween().tween_property(self, "_power", 1.0, 1.4)
	_refresh_cw()


func power_off() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.35)
	tw.tween_callback(func():
		visible = false
		modulate.a = 1.0)


func _process(delta: float) -> void:
	if _abort_hold >= 0.0:
		_abort_hold += delta
		_btn_abort.text = "HOLD… %.1f" % maxf(0.0, HOLD_S - _abort_hold)
		if _abort_hold >= HOLD_S:
			_abort_hold = -1.0
			abort_requested.emit()
	if not visible or world == null or not world.ready_terrain:
		return
	var wk := world.walker
	compass.heading = wk.heading_deg()
	minimap.heading = wk.heading_deg()
	minimap.center = wk.xy()
	queue_redraw()
	if _cw.visible and _cw_level == "emergency":
		_style_cw()   # the emergency strip flashes
	_acc += delta
	if _acc < 0.12:
		return
	_acc = 0.0
	_update_numbers()


func _update_tools() -> void:
	if tools == null:
		return
	var pace := ""
	var pcol := HUD
	if tools.ghost_on and is_finite(tools.pace_s):
		var s := absf(tools.pace_s)
		var ahead := tools.pace_s >= 0.0
		pace = "GHOST · %d:%02d %s" % [int(s) / 60, int(s) % 60, "AHEAD" if ahead else "BEHIND"]
		pcol = UiKit.GOOD if ahead else (UiKit.CAUTION if s < 120.0 else UiKit.BAD)
	_put(_l["pace"], pace, pcol)
	_put(_l["note"], ("▸ " + tools.note) if tools.note != "" else "", HUD)


## A value's text with a status word, so the meaning never rests on colour alone.
static func _tag(v: String, word: String) -> String:
	return v if word == "" else "%s %s" % [v, word]


func _update_numbers() -> void:
	if tel == null or tel.d.is_empty():
		return
	_update_tools()
	var d := tel.d
	var wk := world.walker
	var xy: Vector2 = d["xy"]
	var has := bool(d["has"])
	var unit := Settings.pressure_unit
	# --- mode
	var mode := str(d["mode"])
	var mcol: Color = {"AUTOPILOT": HUD, "ABORT": UiKit.BAD, "MANUAL": UiKit.CAUTION, "RIDING": UiKit.GOOD, "DEMO": UiKit.ADVISORY}.get(mode, HUD)
	UiKit.set_chip(_mode_chip, mode if mode != "" else "—", mcol, true)
	# --- suit
	var met := float(d["met_w"])
	ecg.bpm = float(d["hr"])
	var hrv := float(d["hr"])
	_put(_l["hr"], _tag("%d bpm" % int(hrv), "HIGH" if hrv > 160.0 else ""), UiKit.BAD if hrv > 180.0 else (UiKit.CAUTION if hrv > 160.0 else UiKit.GOOD))
	var p := float(d["p_suit"])
	var falling := float(d["p_drop_rate"]) > SuitModel.P_DROP_RATE
	_put(_l["press"], _tag(SuitModel.fmt_pressure(p, unit), "▼FALL" if falling else ("LOW" if p < SuitModel.P_CAUTION else "")),
		UiKit.BAD if (falling or p < SuitModel.P_WARNING) else (UiKit.CAUTION if p < SuitModel.P_CAUTION else HUD))
	var ppo2 := float(d["ppo2"])
	_put(_l["ppo2"], _tag(SuitModel.fmt_pressure(ppo2, unit), "LOW" if ppo2 < SuitModel.PPO2_CAUTION else ""),
		UiKit.BAD if ppo2 < SuitModel.PPO2_WARNING else (UiKit.CAUTION if ppo2 < SuitModel.PPO2_CAUTION else HUD))
	var pc := float(d["ppco2"])
	_put(_l["ppco2"], _tag("%.1f mmHg" % pc, "HIGH" if pc >= SuitModel.PPCO2_CAUTION else ""),
		UiKit.BAD if pc >= SuitModel.PPCO2_WARNING else (UiKit.CAUTION if pc >= SuitModel.PPCO2_CAUTION else HUD))
	_put(_l["temp"], "%.1f °C" % float(d["suit_c"]), HUD)
	_put(_l["met"], _tag("%d W" % int(met), "HIGH" if met > 520.0 else ""), UiKit.CAUTION if met > 520.0 else HUD)
	var dose := float(d["dose_usv"])
	_put(_l["dose"], "%.0f µSv" % dose if is_finite(dose) else "— NO DATA", HUD if is_finite(dose) else UiKit.FAINT)
	if has:
		_gauge("o2", float(d["o2_pct"]))
		_gauge("pwr", float(d["battery_pct"]))
		_gauge("co2", float(d["scrubber_pct"]), true)
		_gauge("h2o", float(d["water_pct"]))
	(_l["suitline"] as Label).text = "SUIT %s · ppCO₂ %.1f mmHg · O₂ %s" % [SuitModel.fmt_pressure(p, unit), pc,
		("%d%%" % int(float(d["o2_pct"]))) if has else "—"]
	# --- clock
	(_l["clock"] as Label).text = MarsTime.clock(Mission.eva_t)
	var unix := Mission.unix_at(Mission.eva_t)
	var mt := MarsTime.at(unix)
	(_l["time"] as Label).text = "%s LTST  ·  SOL %d  ·  %s" % [MarsTime.hms(MarsTime.ltst(mt, Mission.site_lon()), false),
		MarsTime.mission_sol(mt, Mission.site_lon(), Mission.landing_msd()), Geo.fmt_dist(wk.distance_walked) + " walked"]
	var ev: Dictionary = d["event"] if d["event"] is Dictionary else {}
	(_l["phase"] as Label).text = ("▸ " + str(ev.get("name", "")).to_upper()) if has else "▸ FREE WALK"
	# --- navigation (or the abort guidance)
	var tgt := Mission.next_target(Mission.eva_t)
	var tname := str(tgt.get("name", "—"))
	var txy: Vector2 = tgt.get("xy", Mission.hab_xy())
	var abort := bool(d["abort"])
	if abort:
		tname = "ABORT → %s" % Mission.haven_name()
		txy = Mission.haven_xy()
	var dist := xy.distance_to(txy)
	var brg := Geo.bearing_deg(xy, txy)
	(_l["nav_cap"] as Label).text = "NAV · ABORT: FOLLOW THE RED CHEVRONS" if abort else "NAV · NEXT WAYPOINT"
	_put(_l["target"], tname, UiKit.BAD if abort else Color.WHITE)
	(_l["dist"] as Label).text = Geo.fmt_dist(dist)
	(_l["brg"] as Label).text = "BRG %03d° %s" % [int(brg), Geo.compass(brg)]
	var eta_s := (float(tgt.get("t0", 0.0)) - Mission.eva_t) if (wk.autopilot and has and not abort) else dist / maxf(0.6, float(Mission.walk.get("flat_speed", 0.8)))
	if abort and wk.autopilot and world.abort_active():   # what is left of the red route at the walk-back pace
		eta_s = (world.abort_length() - world.abort_s) / maxf(0.1, world.abort_speed)
	(_l["eta"] as Label).text = "ETA %s" % MarsTime.dur(maxf(eta_s, 0.0))
	var wb := float(d["walkback_s"])
	(_l["ret"] as Label).text = "— NO DATA" if wb < -1.5 else ("NO PATH" if wb < 0.0 else MarsTime.dur(wb))
	(_l["ret_cap"] as Label).text = "WALK BACK TO %s" % Mission.haven_name()
	var margin := float(d["margin_min"])
	if has and is_finite(margin):
		var word := "OK" if margin >= 45.0 else ("LOW" if margin >= 25.0 else ("CRIT" if margin > 0.0 else "NONE"))
		_put(_l["margin"], "%d min %s" % [int(margin), word], UiKit.GOOD if margin >= 45.0 else (UiKit.CAUTION if margin >= 25.0 else UiKit.BAD))
		if margin <= 0.0:
			_put(_l["turn"], "⟲ TURN BACK NOW", UiKit.BAD)
		else:
			_put(_l["turn"], "⟲ TURN BACK IN %s · BY %s LTST" % [MarsTime.dur(margin * 60.0), str(d["turn_by"])], UiKit.CAUTION if margin < 45.0 else HUD)
	else:
		_put(_l["margin"], "— NO DATA", UiKit.FAINT)
		_put(_l["turn"], "", HUD)
	var slope := float(d["slope"])
	var arrow := "▲" if slope > 1.0 else ("▼" if slope < -1.0 else "■")
	_put(_l["slope"], _tag("%s %.0f°" % [arrow, absf(slope)], "STEEP" if absf(slope) > 25.0 else ""),
		UiKit.BAD if absf(slope) > 25.0 else (UiKit.CAUTION if absf(slope) > 15.0 else HUD))
	var hz := int(d["hazard"])
	UiKit.set_chip(_hazard_chip, UiKit.HAZARD_NAMES[clampi(hz, 0, 4)], UiKit.HAZARD[clampi(hz, 0, 4)], true)
	_radio_level = int(d["comms"])
	_radio_bars.queue_redraw()
	var rate := float(d["dose_rate"])
	_put(_l["rad"], _tag("%.1f µSv/h" % rate, "HIGH" if rate > 60.0 else ""), UiKit.BAD if rate > 150.0 else (UiKit.CAUTION if rate > 60.0 else HUD))
	_put(_l["sun"], "%.0f°" % world.sun_elev, Color("ffd166"))
	var ss := float(d["sunset_in_s"])
	_put(_l["sunset"], MarsTime.dur(ss) if is_finite(ss) and ss > 0.0 else ("AFTER SUNSET" if is_finite(ss) else "—"),
		UiKit.CAUTION if is_finite(ss) and ss < 3600.0 else Color("ffd166"))
	# --- mode line and buttons
	var auto_text := ("AUTOPILOT · following the plan ×%d" % int(Mission.play_speed()) if Mission.playing else "AUTOPILOT · paused (P to play)") if wk.autopilot else ("WALKING BY HAND · racing the ghost, EVA clock running · TAB rejoins the route" if world.keep_clock else "WALKING BY HAND · EVA clock paused · TAB rejoins the route")
	if abort and world.abort_active():
		if world.abort_done:
			auto_text = "ABORT COMPLETE · at %s · CANCEL ABORT returns to the plan" % Mission.haven_name()
		elif wk.autopilot:
			auto_text = ("AUTOPILOT · ABORT: walking home to %s ×%d" % [Mission.haven_name(), int(Mission.play_speed())]) if Mission.playing else ("AUTOPILOT · ABORT: paused (P walks home to %s)" % Mission.haven_name())
		else:
			auto_text = "WALKING BY HAND · follow the red chevrons · TAB: the autopilot walks you home"
	if wk.riding:
		auto_text = "RIDING IN %s · suits on the suitports%s" % [Mission.haven_name(), (" · ×%d" % int(Mission.play_speed())) if Mission.playing else " · paused (P to play)"]
	(_l["auto"] as Label).text = auto_text
	_btn_play.text = ("⏸  PAUSE" if Mission.playing else "▶  PLAY") + " ×%d" % int(Mission.play_speed())
	_btn_auto.text = "AUTOPILOT ON" if wk.autopilot else "AUTOPILOT OFF"
	if _abort_hold < 0.0:
		_btn_abort.text = "CANCEL ABORT" if abort else "ABORT"
	# --- compass and minimap
	compass.markers = [
		{"bearing": brg, "label": "%s %s" % [tname.to_upper(), Geo.fmt_dist(dist)], "color": UiKit.BAD if abort else UiKit.AMBER},
		{"bearing": world.sun_az, "label": "SUN", "color": Color("ffd166")},
	]
	# the HAB and the shelters, unless the target already is one (heading home, an abort): one marker, not two on top
	if txy.distance_to(Mission.hab_xy()) > 3.0:
		compass.markers.append({"bearing": Geo.bearing_deg(xy, Mission.hab_xy()), "label": "HAB %s" % Geo.fmt_dist(xy.distance_to(Mission.hab_xy())), "color": UiKit.ACCENT})
	for sh in Mission.site.get("shelters", []):
		var sxy := Mission.xy_of(float(sh["lon"]), float(sh["lat"]))
		if Mission.has_rover() and str(sh.get("kind", "")) == "rover":
			sxy = Mission.rover_state(Mission.eva_t)["xy"]
		if txy.distance_to(sxy) > 3.0:
			compass.markers.append({"bearing": Geo.bearing_deg(xy, sxy), "label": "%s %s" % [str(sh.get("id", "PR")), Geo.fmt_dist(xy.distance_to(sxy))], "color": UiKit.GOOD})
	var mk := [{"xy": Mission.hab_xy(), "color": UiKit.ACCENT}]
	if Mission.has_rover():
		mk.append({"xy": Mission.rover_state(Mission.eva_t)["xy"], "color": UiKit.GOOD})
	for s in Mission.stops:
		var kind := str(s.get("kind", "custom"))
		mk.append({"xy": Mission.xy_of(float(s["lon"]), float(s["lat"])), "color": MarsWorld.STOP_COLORS.get(kind, MarsWorld.STOP_COLORS["custom"])})
	minimap.markers = mk
	minimap.alt_route = world.abort_route if abort else PackedVector2Array()
	_update_cuff()
	info = {"met": met, "rate": rate, "margin": margin, "comms": _radio_level, "slope": slope, "walkback_min": wb / 60.0,
		"hazard": hz, "target": tname, "dist": dist, "txy": txy, "abort": abort}


func _put(l: Variant, text: String, col: Color) -> void:
	var lab := l as Label
	lab.text = text
	lab.add_theme_color_override("font_color", col)


func _gauge(key: String, pct: float, high_is_bad := false) -> void:
	var g := _gauges[key] as BarGauge
	var word := ""
	if high_is_bad:
		word = " FULL" if pct > 92.0 else (" HIGH" if pct > 80.0 else "")
	else:
		word = " CRIT" if pct < 12.0 else (" LOW" if pct < 25.0 else "")
	g.set_level(pct / 100.0, "%.0f%%%s" % [pct, word])


## The C&W strip shows the most important unacknowledged alert (it is gone when all is well).
func _refresh_cw() -> void:
	if _cw == null:
		return
	var a := CW.top()   # advisories show here too, for the few seconds they last
	if a.is_empty():
		_cw.visible = false
		_cw_level = ""
		return
	_cw.visible = true
	_cw_level = str(a["level"])
	var lv := _cw_level
	_cw_icon.text = "◆" if lv == "advisory" else ("☢" if str(a["id"]) in ["sep", "dose_rate", "dose_eva", "swx"] else "⚠")
	_cw_title.text = "%s · %s" % [lv.to_upper(), str(a["title"])]
	_cw_text.text = str(a["text"])
	var m := CW.master()
	var more := int(m["n"]) - 1
	_cw_more.text = ("+%d more  ·  " % more if more > 0 else "") + ("" if lv == "advisory" else "ENTER acknowledge · ⌫ silence · F3 list")
	_style_cw()
	_queue_layout()


func _style_cw() -> void:
	var col := UiKit.level_col(_cw_level)
	var flash := _cw_level == "emergency" and not UiKit.reduce_flashing and int(Time.get_ticks_msec() / 250) % 2 == 0
	var bg := Color(col.darkened(0.55), 0.92 if flash else 0.82)
	var sb := UiKit.box(bg, col, 6, 3 if _cw_level == "emergency" else 2, 10)
	_cw.add_theme_stylebox_override("panel", sb)
	_cw_icon.add_theme_color_override("font_color", Color.WHITE if flash else col.lightened(0.3))


## Apollo crews wore their checklist on the wrist; this is the station page of ours.
func _update_cuff() -> void:
	if world.abort_active():   # an abort: the station work stops, the checklist says what to do instead
		var akey := "abort|%s|%s" % [world.abort_done, declutter]
		if akey == _cuff_key:
			return
		_cuff_key = akey
		for c in _cuff_box.get_children():
			_cuff_box.remove_child(c)
			c.queue_free()
		_cuff.visible = true
		_cuff_box.add_child(_cap("CUFF CHECKLIST · ABORT"))
		if world.abort_done:
			_cuff_box.add_child(_txt("BACK AT %s" % Mission.haven_name(), 14, Color.WHITE, 700))
			_cuff_box.add_child(_txt("Ingress, check EV2 in, then report to the hab.", 12, HUD))
		else:
			_cuff_box.add_child(_txt("WALK HOME TO %s" % Mission.haven_name(), 14, UiKit.BAD, 700))
			_cuff_box.add_child(_txt("Stop station work, stow tools and samples, stay with EV2 and follow the red chevrons.", 12, HUD))
		_cuff.reset_size()
		_queue_layout()
		return
	var cs := Mission.cuff_station(Mission.eva_t)
	var working := bool(cs.get("working", false))
	var left := float(cs.get("t1", 0.0)) - Mission.eva_t
	var key := "%s|%s|%d|%s" % [str((cs.get("stop", {}) as Dictionary).get("id", "")), working, int(left / 60.0) if working else -1, declutter]
	if key == _cuff_key:
		return
	_cuff_key = key
	for c in _cuff_box.get_children():
		_cuff_box.remove_child(c)   # now, so the panel can shrink to the new rows straight away
		c.queue_free()
	_cuff.visible = declutter == "full" or working
	_fill_cuff(cs, working, left)
	_cuff.reset_size()
	_queue_layout()


func _fill_cuff(cs: Dictionary, working: bool, left: float) -> void:
	if cs.is_empty():
		_cuff_box.add_child(_cap("CUFF CHECKLIST · RETURN"))
		_cuff_box.add_child(_txt("All stations done: walk back, dust off, stow samples.", 12, HUD))
		return
	var s: Dictionary = cs["stop"]
	var sid := str(s.get("id", ""))
	_cuff_box.add_child(_cap("CUFF CHECKLIST · STA %d" % int(cs["index"])))
	_cuff_box.add_child(_txt(str(s.get("name", "")).to_upper(), 14, Color.WHITE, 700))
	if working:
		_cuff_box.add_child(_txt("ON STATION · %d min left" % int(ceil(left / 60.0)), 12, UiKit.CAUTION if left < 300.0 else HUD))
	else:
		_cuff_box.add_child(_txt("NEXT · arrive %s · %d min work" % [MarsTime.clock(float(cs["t0"])), int(s.get("dwell_min", 20))], 12, HUD_DIM))
	var tasks: Array = s.get("tasks", [])
	var state := Mission.task_state(sid, tasks.size())
	for i in mini(tasks.size(), 5):
		var row := Button.new()
		row.flat = true
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		row.text = "%s  %d  %s" % ["☑" if bool(state[i]) else "☐", i + 1, str(tasks[i])]
		row.add_theme_font_override("font", UiKit.symbols())
		row.add_theme_font_size_override("font_size", maxi(12, UiKit.MIN_FONT))
		row.add_theme_color_override("font_color", UiKit.GOOD if bool(state[i]) else HUD)
		row.add_theme_color_override("font_hover_color", Color.WHITE)
		row.clip_text = true
		row.custom_minimum_size = Vector2(286, 40 if UiKit.glove else 0)
		var idx := i
		row.pressed.connect(func():
			Mission.toggle_task(sid, idx)
			Sfx.play("toggle", -6.0))
		_cuff_box.add_child(row)
	_cuff_box.add_child(_txt("click or press 1–%d to tick" % mini(tasks.size(), 5), 10, HUD_DIM))
	if not working and tools != null:   # walking to the station: the route ahead, unrolled (D3)
		var strip := CuffStrip.new()
		strip.tools = tools
		_cuff_box.add_child(strip)


func toggle_cuff_task(i: int) -> void:
	var cs := Mission.cuff_station(Mission.eva_t)
	if cs.is_empty():
		return
	Mission.toggle_task(str((cs["stop"] as Dictionary).get("id", "")), i)
	Sfx.play("toggle", -6.0)


## Tick the first unticked task of the current station (voice "check" and the cuff menu). Returns its name.
func tick_next_task() -> String:
	var cs := Mission.cuff_station(Mission.eva_t)
	if cs.is_empty():
		return ""
	var s: Dictionary = cs["stop"]
	var tasks: Array = s.get("tasks", [])
	var state := Mission.task_state(str(s.get("id", "")), tasks.size())
	for i in tasks.size():
		if not bool(state[i]):
			toggle_cuff_task(i)
			return str(tasks[i])
	return ""


func _draw_radio() -> void:
	var cols := [UiKit.BAD, UiKit.CAUTION, UiKit.GOOD]
	var c: Color = cols[clampi(_radio_level, 0, 2)]
	for i in 4:
		var on := (_radio_level == 2) or (_radio_level == 1 and i < 2)
		var hh := 6.0 + i * 4.0
		_radio_bars.draw_rect(Rect2(i * 9.0, 20.0 - hh, 6.0, hh), c if on else Color(1, 1, 1, 0.12))
	var txt: String = UiKit.COMMS_NAMES[clampi(_radio_level, 0, 2)]
	if _radio_level == 0 and tel != null and not tel.d.is_empty():
		txt = "LOS %s" % MarsTime.dur(float(tel.d["los_s"]))   # loss of signal: how long the link has been gone
	_radio_bars.draw_string(UiKit.mono(600), Vector2(40, 18), txt, HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, c)


func _draw() -> void:
	if world == null or not world.ready_terrain:
		return
	var w := size.x
	var h := size.y
	var c := Vector2(w * 0.5, h * 0.5)
	var a := _power * opacity
	var col := Color(HUD, 0.5 * a)
	draw_arc(c, 16.0, 0, TAU, 40, Color(HUD, 0.35 * a), 1.2, true)
	for dv in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1)]:
		draw_line(c + dv * 22.0, c + dv * 34.0, col, 1.5)
	draw_circle(c, 1.6, Color(HUD, 0.8 * a))
	if declutter == "full":
		var pitch := rad_to_deg(world.walker.pitch)
		var ppd := h / world.camera.fov
		for deg in [-20, -10, 10, 20]:
			var y: float = c.y + (pitch - deg) * ppd
			if y < 120 or y > h - 260:
				continue
			var half: float = 70.0 if absi(deg) == 10 else 46.0
			draw_line(Vector2(c.x - half - 30, y), Vector2(c.x - 30, y), Color(HUD, 0.25 * a), 1.0)
			draw_line(Vector2(c.x + 30, y), Vector2(c.x + half + 30, y), Color(HUD, 0.25 * a), 1.0)
			draw_string(UiKit.mono(400), Vector2(c.x + half + 36, y + 4), "%+d" % deg, HORIZONTAL_ALIGNMENT_LEFT, -1, UiKit.MIN_FONT, Color(HUD, 0.35 * a))
	var m := 26.0
	var L := 46.0
	for corner in [Vector2(m, m), Vector2(w - m, m), Vector2(m, h - m), Vector2(w - m, h - m)]:
		var sx := 1.0 if corner.x < w * 0.5 else -1.0
		var sy := 1.0 if corner.y < h * 0.5 else -1.0
		draw_line(corner, corner + Vector2(L * sx, 0), Color(HUD, 0.35 * a), 2.0)
		draw_line(corner, corner + Vector2(0, L * sy), Color(HUD, 0.35 * a), 2.0)
	if info.has("target"):
		var txy: Vector2 = info["txy"]
		var abort := bool(info.get("abort", false))
		_draw_waypoint(world.td.world_at(txy, 2.2), str(info["target"]), float(info["dist"]), UiKit.BAD if abort else UiKit.AMBER, _power)
		var hab := Mission.hab_xy()
		if txy.distance_to(hab) > 5.0 and not abort:
			_draw_waypoint(world.td.world_at(hab, 6.0), "HAB", world.walker.xy().distance_to(hab), UiKit.ACCENT, _power * 0.7)


func _draw_waypoint(p: Vector3, name: String, dist: float, col: Color, a: float) -> void:
	var cam := world.camera
	var w := size.x
	var h := size.y
	var behind := cam.is_position_behind(p)
	var sp := cam.unproject_position(p)
	var margin := 70.0
	var inside := not behind and sp.x > margin and sp.x < w - margin and sp.y > 90 and sp.y < h - 90
	if inside:
		var s := 9.0 + (0.0 if UiKit.reduce_flashing else 3.0 * sin(Time.get_ticks_msec() / 220.0))
		draw_colored_polygon(PackedVector2Array([sp + Vector2(0, -s), sp + Vector2(s, 0), sp + Vector2(0, s), sp + Vector2(-s, 0)]), Color(col, 0.25 * a))
		draw_polyline(PackedVector2Array([sp + Vector2(0, -s), sp + Vector2(s, 0), sp + Vector2(0, s), sp + Vector2(-s, 0), sp + Vector2(0, -s)]), Color(col, a), 2.0, true)
		draw_string(UiKit.font(600), sp + Vector2(-90, -s - 8), name.to_upper(), HORIZONTAL_ALIGNMENT_CENTER, 180, maxi(12, UiKit.MIN_FONT), Color(col, a))
		draw_string(UiKit.mono(500), sp + Vector2(-80, s + 18), Geo.fmt_dist(dist), HORIZONTAL_ALIGNMENT_CENTER, 160, maxi(12, UiKit.MIN_FONT), Color(Color.WHITE, a))
	else:
		var c := Vector2(w * 0.5, h * 0.5)
		var dir := (sp - c)
		if behind:
			dir = -dir
		if dir.length() < 1.0:
			dir = Vector2(0, 1)
		dir = dir.normalized()
		var edge := c + dir * minf(w * 0.5 - margin, h * 0.5 - 100.0) / maxf(absf(dir.x), absf(dir.y)) * maxf(absf(dir.x), absf(dir.y))
		edge = Vector2(clampf(edge.x, margin, w - margin), clampf(edge.y, 100, h - 100))
		var perp := Vector2(-dir.y, dir.x)
		draw_colored_polygon(PackedVector2Array([edge + dir * 16.0, edge - dir * 6.0 + perp * 11.0, edge - dir * 6.0 - perp * 11.0]), Color(col, 0.85 * a))
		draw_string(UiKit.font(600), edge - dir * 30.0 + Vector2(-70, 4), "%s %s" % [name.to_upper(), Geo.fmt_dist(dist)], HORIZONTAL_ALIGNMENT_CENTER, 140, UiKit.MIN_FONT, Color(col, a))
