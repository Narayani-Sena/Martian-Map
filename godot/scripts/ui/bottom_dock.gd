class_name BottomDock
extends PanelContainer
## Timeline dock: transport controls and the EVA clock, the event timeline, an elevation
## profile with hazard and radio-shadow bands, and the suit consumables at the playhead.

signal follow_toggled(on: bool)

var _clock: Label
var _ltst: Label
var _phase: PanelContainer
var _phase_name: Label
var _play: Button
var _speed: Button
var _timeline: TimelineBar
var _slow_ms := 0   # last time the slow readouts (chip, gauges, margin) were refreshed during playback
var world: MarsWorld   # set by main: during an abort the phase chip reads the walk home, not the plan
var _profile: LineChart
var _gauges := {}
var _margin: Label
var _dose: Label
var _met: Label
var _follow: Button


func _init() -> void:
	material = UiKit.glass_material(3.2)
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 12, 1, 12))
	var h := UiKit.hbox(16)
	add_child(h)
	var tv := UiKit.vbox(4)
	tv.custom_minimum_size = Vector2(196, 0)
	h.add_child(tv)
	tv.add_child(UiKit.caps("EVA timeline", UiKit.ACCENT, 10))
	_clock = UiKit.label("T+00:00:00", 28, UiKit.TEXT, 600, true)
	tv.add_child(_clock)
	_ltst = UiKit.label("—", 12, UiKit.DIM)
	tv.add_child(_ltst)
	var ph := UiKit.hbox(6)
	_phase = UiKit.chip("—", UiKit.DIM)
	ph.add_child(_phase)
	_phase_name = UiKit.label("", 11, UiKit.TEXT)
	_phase_name.clip_text = true
	_phase_name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ph.add_child(_phase_name)
	tv.add_child(ph)
	var tr := UiKit.hbox(4)
	tr.add_child(UiKit.button("⏮", func(): Mission.set_time(0.0), "Back to egress  [Home]"))
	_play = UiKit.button("▶  PLAY", func(): Mission.set_playing(not Mission.playing), "Play / pause the EVA  [Space]")
	_play.custom_minimum_size = Vector2(84, 0)
	tr.add_child(_play)
	tr.add_child(UiKit.button("⏭", _next_event, "Jump to the next event"))
	_speed = UiKit.button("×30", func(): Mission.cycle_speed(1 if not Input.is_key_pressed(KEY_SHIFT) else -1), "Playback speed (shift-click: slower)  [ ] ]")
	tr.add_child(_speed)
	for b in tr.get_children():
		(b as Button).add_theme_font_override("font", UiKit.symbols())
	tv.add_child(tr)
	_follow = UiKit.button("FOLLOW CREW", func(): follow_toggled.emit(_follow.button_pressed), "Camera follows EV1 during playback", true)
	tv.add_child(_follow)
	var mid := UiKit.vbox(2)
	mid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(mid)
	_timeline = TimelineBar.new()
	_timeline.scrubbed.connect(func(t: float): Mission.set_time(t))
	mid.add_child(_timeline)
	_profile = LineChart.new()
	_profile.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_profile.custom_minimum_size = Vector2(200, 92)
	_profile.pad = Vector4(44, 6, 4, 4)
	_profile.title = "ELEVATION ALONG THE ROUTE   ▨ HAZARDOUS GROUND   ⁘ RADIO SHADOW"
	_profile.y_ticks = 3
	_profile.y_fmt = func(y: float) -> String: return "%d m" % int(round(y))
	_profile.x_fmt = func(_x: float) -> String: return ""
	_profile.scrubbed.connect(func(t: float): Mission.set_time(t))
	mid.add_child(_profile)
	var right := UiKit.vbox(5)
	right.custom_minimum_size = Vector2(250, 0)
	h.add_child(right)
	right.add_child(UiKit.caps("Suit consumables at playhead", UiKit.ACCENT, 10))
	for spec in [["o2", "OXYGEN", false], ["pwr", "BATTERY", false], ["co2", "CO₂ SCRUBBER LOAD", true], ["h2o", "COOLING WATER", false]]:
		var g := BarGauge.new(str(spec[1]), bool(spec[2]), 26.0)
		right.add_child(g)
		_gauges[spec[0]] = g
	var row := UiKit.hbox(12)
	_margin = UiKit.label("", 12, UiKit.GOOD, 600, true)
	_dose = UiKit.label("", 12, UiKit.TEXT, 500, true)
	_met = UiKit.label("", 12, UiKit.DIM, 500, true)
	row.add_child(_margin)
	row.add_child(_dose)
	row.add_child(_met)
	right.add_child(row)


func _ready() -> void:
	Mission.plan_changed.connect(_on_plan)
	Mission.time_changed.connect(_on_time)
	Mission.playing_changed.connect(_on_playing)
	visibility_changed.connect(func():   # hidden in the helmet view: catch up when it shows again
		if is_visible_in_tree():
			_on_time(Mission.eva_t))


func set_follow(on: bool) -> void:
	_follow.set_pressed_no_signal(on)


func _next_event() -> void:
	if not Mission.has_plan():
		return
	for e in Mission.plan["events"]:
		if float(e["t0"]) > Mission.eva_t + 1.0:
			Mission.set_time(float(e["t0"]))
			return


func _on_playing(on: bool) -> void:
	_play.text = "⏸  PAUSE" if on else "▶  PLAY"
	_speed.text = "×%d" % int(Mission.play_speed())
	if not on:
		_slow_ms = 0
		_on_time(Mission.eva_t)   # the readouts at the moment playback stopped


func _on_plan() -> void:
	var p: Dictionary = Mission.plan["profile"]
	var tt: Dictionary = Mission.plan["totals"]
	var sunset: Variant = tt.get("sunset_t")
	var sw: Dictionary = Mission.plan.get("space_weather", {}) if Mission.plan.get("space_weather") is Dictionary else {}
	var sun: Dictionary = Mission.plan.get("sun", {}) if Mission.plan.get("sun") is Dictionary else {}
	_timeline.set_plan(Mission.plan["events"], float(tt["total_s"]), float(sunset) if sunset != null else NAN, sw.get("arrivals", []), sun.get("shade", []))
	var ts := PackedFloat32Array(p["t"])
	var zs := PackedFloat32Array(p["z"])
	_profile.x_min = 0.0
	_profile.x_max = float(tt["total_s"])
	var bands := []
	var hz: Array = p["hazard"]
	var cm: Array = p["comms"]
	for i in range(1, ts.size()):   # one band per run of hazardous or radio-shadow route (hatched / dotted)
		var kind := "hatch" if int(hz[i]) >= 3 else ("dots" if int(cm[i]) == 0 else "")
		if kind == "":
			continue
		if not bands.is_empty() and str(bands[-1]["pattern"]) == kind and float(bands[-1]["x1"]) >= ts[i - 1] - 0.5:
			bands[-1]["x1"] = ts[i]
		else:
			bands.append({"x0": ts[i - 1], "x1": ts[i], "pattern": kind,
				"color": Color(UiKit.BAD, 0.35) if kind == "hatch" else Color(UiKit.VIOLET, 0.2)})
	_profile.bands = bands
	_profile.set_series([{"xs": ts, "ys": zs, "color": UiKit.ACCENT, "fill": true, "name": "elev", "width": 2.0}])
	_profile.auto_y(0.15)
	_profile.tip_fmt = func(t: float) -> String:
		var st := Mission.state_at(t)
		var ev: Dictionary = st.get("event", {})
		return "%s · %s\n%.0f m · slope %.0f° · %s\n%s · walk-back %.0f min" % [MarsTime.clock(t), str(ev.get("name", "")),
			_profile._sample(_profile.series[0], t), float(st.get("slope", 0)), UiKit.HAZARD_NAMES[clampi(int(st.get("hazard", 0)), 0, 4)],
			UiKit.COMMS_NAMES[clampi(int(st.get("comms", 0)), 0, 2)], float(st.get("walkback_min", 0))]
	_on_time(Mission.eva_t)
	_on_playing(Mission.playing)


func _on_time(t: float) -> void:
	if not is_visible_in_tree():
		return   # the helmet view hides the dock: no labels, gauges or charts to update
	_clock.text = MarsTime.clock(t)
	_timeline.set_time(t)
	_profile.set_playhead(t)
	if not Mission.has_plan():
		return
	# chips, gauges and colours change slowly: while the EVA plays, about 10 times a second is plenty
	var now := Time.get_ticks_msec()
	if Mission.playing and now - _slow_ms < 100:
		return
	_slow_ms = now
	var st := Mission.state_at(t)
	_ltst.text = "%s LTST  ·  sun %.0f°  ·  air %.0f °C" % [MarsTime.hms(float(st.get("ltst", 0)), false), float(st.get("sun_elev", 0)), float(st.get("air_c", 0))]
	var ev: Dictionary = st.get("event", {})
	var kind := str(ev.get("kind", "—"))
	var col: Color = TimelineBar.KIND_COLORS.get(kind, UiKit.DIM)
	var chip: String = {"egress": "AIRLOCK", "ingress": "AIRLOCK", "walk": "WALKING", "stop": "WORKING", "drive": "DRIVING"}.get(kind, "—")
	if str(ev.get("name", "")).begins_with("Suitport"):
		chip = "SUITPORT"
	var name := str(ev.get("name", ""))
	if world and world.abort_active():
		chip = "ABORT"
		col = UiKit.BAD
		name = ("Back at %s" % Mission.haven_name()) if world.abort_done else ("Walking home to %s · %s to go" % [Mission.haven_name(), Geo.fmt_dist(world.abort_length() - world.abort_s)])
	UiKit.set_chip(_phase, chip, col, true)
	_phase_name.text = name
	(_gauges["o2"] as BarGauge).set_level(float(st["o2_pct"]) / 100.0, "%.0f %%" % float(st["o2_pct"]))
	(_gauges["pwr"] as BarGauge).set_level(float(st["battery_pct"]) / 100.0, "%.0f %%" % float(st["battery_pct"]))
	(_gauges["co2"] as BarGauge).set_level(float(st["co2_pct"]) / 100.0, "%.0f %%" % float(st["co2_pct"]))
	(_gauges["h2o"] as BarGauge).set_level(float(st["water_pct"]) / 100.0, "%.0f %%" % float(st["water_pct"]))
	var mg := float(st["margin_min"])
	_margin.text = "MARGIN %d min" % int(mg)
	_margin.add_theme_color_override("font_color", UiKit.GOOD if mg > 60 else (UiKit.AMBER if mg > 20 else UiKit.BAD))
	_dose.text = "%.1f µSv" % float(st["dose_usv"])
	_met.text = "%d W" % int(float(st["met_w"]))
