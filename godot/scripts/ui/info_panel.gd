class_name InfoPanel
extends PanelContainer
## Right panel with tabs: CONDITIONS (sun, weather, radiation), SPACE WX (NASA DONKI),
## ROVER CAM (Curiosity raw images near a stop), LAYERS (draped analysis layers) and INSPECT.

signal overlay_requested(layer: Dictionary)
signal layer_toggled(what: String, on: bool)
signal opacity_changed(v: float)
signal add_stop_here(lonlat: Vector2)
signal photo_requested(item: Dictionary, tex: Texture2D)
signal ping_requested
signal drill_requested
signal suit_drill_requested(kind: String)   # "leak" | "co2" | "" (end)

const TABS := ["CONDITIONS", "SPACE WX", "ROVER CAM", "LAYERS", "INSPECT"]

var _cap_now: Label
var _cap_meas: Label
var _cap_cam: Label
var _tab_btns := {}
var _pages := {}
var current := ""

var _c_ltst: Label
var _c_sub: Label
var _c_sun: Label
var _c_sun_chart: LineChart
var _c_temp_chart: LineChart
var _c_tiles := {}
var _c_rad: VBoxContainer
var _c_note: Label
var _c_meas: VBoxContainer

var _sw_box: PanelContainer
var _sw_status: Label
var _sw_reasons: VBoxContainer
var _sw_lists: VBoxContainer
var _sw_src: Label

var _cam_title: Label
var _cam_info: Label
var _cam_grid: GridContainer
var _cam_key := ""

var _layer_btns := {}
var _legend: LegendBar
var _legend_unit: Label
var _layer_about: Label
var _opacity: HSlider
var _active_layer := ""
var _layer_opacity := {}   # layer id -> opacity the user picked for it

var _insp_box: VBoxContainer
var _insp_point := Vector2(NAN, NAN)


func _init() -> void:
	material = UiKit.glass_material(3.2)
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 12, 1, 0))
	custom_minimum_size = Vector2(352, 0)
	var outer := UiKit.vbox(0)
	add_child(outer)
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 0)
	outer.add_child(tabs)
	var group := ButtonGroup.new()
	for name in TABS:
		var b := UiKit.button(name, func(): show_tab(name), "", true)
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.add_theme_font_size_override("font_size", UiKit.MIN_FONT)
		b.add_theme_font_override("font", UiKit.caps_font())
		var flat := UiKit.box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 0, 4)
		flat.content_margin_top = 10
		flat.content_margin_bottom = 9
		var on := UiKit.box(Color(UiKit.ACCENT, 0.1), Color(0, 0, 0, 0), 0, 0, 4)
		on.border_width_bottom = 2
		on.border_color = UiKit.ACCENT
		on.content_margin_top = 10
		on.content_margin_bottom = 9
		b.add_theme_stylebox_override("normal", flat)
		b.add_theme_stylebox_override("hover", UiKit.box(Color(1, 1, 1, 0.05), Color(0, 0, 0, 0), 0, 0, 4))
		b.add_theme_stylebox_override("pressed", on)
		b.add_theme_stylebox_override("hover_pressed", on)
		b.add_theme_color_override("font_color", UiKit.DIM)
		b.add_theme_color_override("font_pressed_color", UiKit.ACCENT)
		b.add_theme_color_override("font_hover_pressed_color", UiKit.ACCENT)
		tabs.add_child(b)
		_tab_btns[name] = b
	outer.add_child(UiKit.hline(0.08))
	var holder := Control.new()
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.clip_contents = true
	outer.add_child(holder)
	for name in TABS:
		var sc := ScrollContainer.new()
		sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		sc.set_anchors_preset(Control.PRESET_FULL_RECT)
		sc.visible = false
		holder.add_child(sc)
		var m := MarginContainer.new()
		for side in ["left", "right", "top", "bottom"]:
			m.add_theme_constant_override("margin_" + side, 14)
		m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sc.add_child(m)
		var v := UiKit.vbox(10)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		m.add_child(v)
		_pages[name] = {"scroll": sc, "box": v}
	_build_conditions(_pages["CONDITIONS"]["box"])
	_build_space_weather(_pages["SPACE WX"]["box"])
	_build_camera(_pages["ROVER CAM"]["box"])
	_build_inspect(_pages["INSPECT"]["box"])


func _ready() -> void:
	Mission.conditions_changed.connect(update_conditions)
	Mission.plan_changed.connect(update_conditions)
	Mission.space_weather_changed.connect(update_space_weather)
	Mission.weather_live_changed.connect(update_measured)
	Mission.site_loaded.connect(func(): _build_layers(_pages["LAYERS"]["box"]))
	Mission.site_loaded.connect(_on_site_captions)
	show_tab("CONDITIONS")


func scroll_to_end(name: String) -> void:
	var sc: ScrollContainer = _pages[name]["scroll"]
	sc.scroll_vertical = 100000


func show_tab(name: String) -> void:
	if name == current:
		return
	current = name
	for k in _tab_btns:
		(_tab_btns[k] as Button).set_pressed_no_signal(k == name)
	for k in _pages:
		var sc: ScrollContainer = _pages[k]["scroll"]
		sc.visible = k == name
	var page: ScrollContainer = _pages[name]["scroll"]
	# slide by moving both offsets together: the page keeps the holder's width
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.modulate.a = 0.0
	page.offset_left = 18.0
	page.offset_right = 18.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(page, "modulate:a", 1.0, 0.3)
	tw.tween_property(page, "offset_left", 0.0, 0.35).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(page, "offset_right", 0.0, 0.35).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	if name == "ROVER CAM" and _cam_key == "":
		refresh_camera()


# ------------------------------------------------------------------ CONDITIONS
func _build_conditions(v: VBoxContainer) -> void:
	_cap_now = UiKit.caps("At the site · right now", UiKit.ACCENT, 11)
	v.add_child(_cap_now)
	_c_ltst = UiKit.label("--:--:--", 34, UiKit.TEXT, 500, true)
	v.add_child(_c_ltst)
	_c_sub = UiKit.wrap("", 12, UiKit.DIM)
	v.add_child(_c_sub)
	_c_sun = UiKit.wrap("", 12, UiKit.TEXT)
	v.add_child(_c_sun)
	_c_sun_chart = LineChart.new()
	_c_sun_chart.custom_minimum_size = Vector2(0, 118)
	_c_sun_chart.title = "SUN ELEVATION · LOCAL SOLAR TIME"
	_c_sun_chart.x_fmt = func(x: float) -> String: return MarsTime.hms(x, false)
	_c_sun_chart.y_fmt = func(y: float) -> String: return "%d°" % int(round(y))
	_c_sun_chart.interactive = true
	v.add_child(_c_sun_chart)
	var g := UiKit.grid(2, 6, 6)
	v.add_child(g)
	for spec in [["air", "Air", "°C"], ["ground", "Ground", "°C"], ["pressure", "Pressure", "Pa"], ["wind", "Wind", "m/s"], ["tau", "Dust τ", ""], ["uv", "UV index", ""]]:
		var t := StatTile.new(str(spec[1]), str(spec[2]), 18)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(t)
		_c_tiles[spec[0]] = t
	_c_temp_chart = LineChart.new()
	_c_temp_chart.custom_minimum_size = Vector2(0, 118)
	_c_temp_chart.title = "TEMPERATURE · TODAY"
	_c_temp_chart.x_fmt = func(x: float) -> String: return MarsTime.hms(x, false)
	_c_temp_chart.y_fmt = func(y: float) -> String: return "%d°" % int(round(y))
	v.add_child(_c_temp_chart)
	v.add_child(UiKit.caps("Radiation", UiKit.DIM, 11))
	_c_rad = UiKit.vbox(4)
	v.add_child(_c_rad)
	_c_note = UiKit.wrap("", 10, UiKit.FAINT)
	v.add_child(_c_note)
	v.add_child(UiKit.hline())
	_cap_meas = UiKit.caps("Measured by the rover", UiKit.ACCENT, 11)
	v.add_child(_cap_meas)
	_c_meas = UiKit.vbox(6)
	_c_meas.add_child(UiKit.label("Loading the rover's weather station feed …", 12, UiKit.DIM))
	v.add_child(_c_meas)


func update_conditions() -> void:
	var c: Dictionary = Mission.conditions
	if c.is_empty():
		return
	_c_ltst.text = str(c.get("ltst", "--"))
	_c_sub.text = "Sol %d  ·  LMST %s  ·  Ls %.1f° %s  ·  MY %d" % [int(c.get("sol", 0)), str(c.get("lmst", "")).substr(0, 5), float(c.get("ls", 0)), str(c.get("season", "")), int(c.get("mars_year", 0))]
	var sun: Dictionary = c.get("sun", {})
	_c_sun.text = "☀ %.1f° up · azimuth %.0f° · %.1f h of daylight left · sunrise %s · sunset %s · %d W/m² at the surface" % [
		float(sun.get("elevation", 0)), float(sun.get("azimuth", 0)), float(sun.get("daylight_left_h", 0)),
		MarsTime.hms(float(sun.get("sunrise_ltst", 6.0)), false), MarsTime.hms(float(sun.get("sunset_ltst", 18.0)), false),
		int(float(sun.get("surface_wm2", {}).get("total", 0)))]
	var curve: Dictionary = c.get("sol_curve", {})
	var xs := PackedFloat32Array(curve.get("ltst", []))
	_c_sun_chart.x_min = 0.0
	_c_sun_chart.x_max = 24.0
	_c_sun_chart.y_min = -90.0
	_c_sun_chart.y_max = 90.0
	_c_sun_chart.hlines = [{"y": 0.0, "color": Color(1, 1, 1, 0.35), "text": "HORIZON"}]
	_c_sun_chart.set_series([{"xs": xs, "ys": PackedFloat32Array(curve.get("sun_elev", [])), "color": Color("ffd166"), "fill": true, "name": "sun", "width": 2.0}])
	_c_sun_chart.playhead = float(c.get("ltst_h", NAN))
	if Mission.has_plan():
		var tt: Dictionary = Mission.plan["totals"]
		var t0 := float(tt["start_ltst"])
		var t1 := t0 + float(tt["total_s"]) / 3600.0 / MarsTime.SOL_DAYS
		_c_sun_chart.bands = [{"x0": t0, "x1": t1, "color": Color(UiKit.ACCENT, 0.16)}]
		_c_sun_chart.tip_fmt = func(x: float) -> String:
			var inside := x >= t0 and x <= t1
			return "%s LTST\nsun %.1f°%s" % [MarsTime.hms(x, false), _c_sun_chart._sample(_c_sun_chart.series[0], x), "\nEVA window" if inside else ""]
	_c_temp_chart.x_min = 0.0
	_c_temp_chart.x_max = 24.0
	_c_temp_chart.set_series([
		{"xs": xs, "ys": PackedFloat32Array(curve.get("ground_c", [])), "color": UiKit.MARS, "name": "ground", "width": 1.6},
		{"xs": xs, "ys": PackedFloat32Array(curve.get("air_c", [])), "color": UiKit.ACCENT, "name": "air", "width": 2.0, "fill": true}])
	_c_temp_chart.auto_y(0.1)
	_c_temp_chart.playhead = float(c.get("ltst_h", NAN))
	_c_temp_chart.hlines = [{"y": 0.0, "color": Color(1, 1, 1, 0.25), "text": "0 °C"}]
	var w: Dictionary = c.get("weather", {})
	var deg := func(x: float) -> String: return "%d" % int(round(x))
	(_c_tiles["air"] as StatTile).set_value(float(w.get("air_c", 0)), deg, "%d … %d" % [int(float(w.get("air_min_c", 0))), int(float(w.get("air_max_c", 0)))])
	(_c_tiles["ground"] as StatTile).set_value(float(w.get("ground_c", 0)), deg)
	(_c_tiles["pressure"] as StatTile).set_value(float(w.get("pressure_pa", 0)), deg, "0.8 % of Earth")
	(_c_tiles["wind"] as StatTile).set_value(float(w.get("wind_ms", 0)), func(x: float) -> String: return "%.1f" % x)
	(_c_tiles["tau"] as StatTile).set_value(float(w.get("tau", 0)), func(x: float) -> String: return "%.2f" % x, "optical depth")
	var uv := float(w.get("uv_index", 0))
	(_c_tiles["uv"] as StatTile).set_value(uv, func(x: float) -> String: return "%.0f" % x, "", UiKit.BAD if uv > 11 else UiKit.AMBER)
	for ch in _c_rad.get_children():
		ch.queue_free()
	var r: Dictionary = c.get("radiation", {})
	var gcr := float(r.get("gcr_usv_h", 0))
	_rad_row("Galactic cosmic rays, open sky", "%.1f µSv/h" % gcr, UiKit.AMBER)
	_rad_row("Per sol outdoors", "%.2f mSv" % float(r.get("gcr_msv_day", 0)), UiKit.TEXT)
	_rad_row("Sky blocked by terrain at the hab", "%.1f %%" % (float(r.get("hab_site_shield", 0)) * 100.0), UiKit.TEXT)
	if Mission.has_plan():
		_rad_row("This EVA", "%.1f µSv" % float(Mission.plan["totals"]["dose_usv"]), UiKit.ACCENT)
		_rad_row("Share of a 600 mSv career limit", "%.3f %%" % (float(Mission.plan["totals"]["dose_usv"]) / 6000.0), UiKit.DIM)
	_c_note.text = str(w.get("model", ""))



func _on_site_captions() -> void:
	var rover := Mission.rover_label()
	var station := "REMS" if str(Mission.site.get("mission", "")) == "MSL" else "MEDA"
	if _cap_now:
		_cap_now.text = ("%s · right now" % str(Mission.site.get("short_name", "Site"))).to_upper()
	if _cap_meas:
		_cap_meas.text = ("Measured by %s · %s" % [rover, station]).to_upper()
	if _cap_cam:
		_cap_cam.text = ("%s raw images · ground truth" % rover).to_upper()


func update_measured() -> void:
	for ch in _c_meas.get_children():
		ch.queue_free()
	var w: Dictionary = Mission.weather_live
	if not bool(w.get("available", false)):
		_c_meas.add_child(UiKit.wrap(str(w.get("reason", "No measured weather for this site.")), 12, UiKit.DIM))
		return
	var L: Dictionary = w["latest"]
	_c_meas.add_child(UiKit.label("Sol %d · %s · Ls %d°" % [int(L["sol"]), str(L.get("date", "")), int(float(L.get("ls", 0.0)))], 13, UiKit.TEXT, 600))
	if bool(w.get("stale", false)):
		_c_meas.add_child(UiKit.wrap("The public feed has had no new sols since %s (%d sols ago): shown for reference only." % [str(L.get("date", "?")), int(w.get("lag_sols", 0))], 11, UiKit.AMBER))
	else:
		_c_meas.add_child(UiKit.wrap("%d sols old: the station's data reach the public feed with a delay." % int(w.get("lag_sols", 0)), 11, UiKit.FAINT))
	var g := UiKit.grid(2, 6, 6)
	_c_meas.add_child(g)
	var tiles := [["Air min / max", "%s / %s" % [_n(L.get("min_c")), _n(L.get("max_c"))], "°C"],
		["Ground min / max", "%s / %s" % [_n(L.get("ground_min_c")), _n(L.get("ground_max_c"))], "°C"],
		["Pressure", _n(L.get("pressure_pa")), "Pa"],
		["Sky", "—" if L.get("opacity") == null else str(L["opacity"]), "" if L.get("uv") == null else str(L["uv"])]]
	for t in tiles:
		var st := StatTile.new(str(t[0]), str(t[2]), 16)
		st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		st.set_text(str(t[1]))
		g.add_child(st)
	var ly: Variant = w.get("same_season_last_year")
	if ly is Dictionary:
		var d: Dictionary = ly
		_c_meas.add_child(UiKit.caps("Forecast: same season one Mars year ago", UiKit.DIM, 10))
		_c_meas.add_child(UiKit.wrap("Sols %d–%d (%s, Ls %d°): air %s … %s °C, ground %s … %s °C, %s Pa, %s." % [int(d["sol_from"]), int(d["sol_to"]),
			str(d.get("date", "")), int(float(d.get("ls", 0.0))), _n(d.get("min_c")), _n(d.get("max_c")), _n(d.get("ground_min_c")), _n(d.get("ground_max_c")),
			_n(d.get("pressure_pa")), str(d.get("opacity", "")).to_lower()], 12, UiKit.TEXT))
	var mv: Variant = w.get("model_vs_measured")
	if mv is Dictionary:
		var m: Dictionary = mv
		_c_meas.add_child(UiKit.wrap("Model check: our plain climatology said %s … %s °C for that sol (off by %+.1f / %+.1f °C), so the numbers above are calibrated with REMS season means." % [
			_n(m.get("min_c")), _n(m.get("max_c")), float(m.get("error_min_c", 0.0)), float(m.get("error_max_c", 0.0))], 11, UiKit.DIM))
	var rec: Dictionary = w.get("recent", {})
	if rec.has("sol"):
		var ch := LineChart.new()
		ch.custom_minimum_size = Vector2(0, 110)
		ch.title = "AIR MIN / MAX · LAST %d MEASURED SOLS" % (rec["sol"] as Array).size()
		ch.x_fmt = func(x: float) -> String: return "sol %d" % int(x)
		ch.y_fmt = func(y: float) -> String: return "%d°" % int(round(y))
		var xs := PackedFloat32Array(rec["sol"])
		ch.x_min = xs[0]
		ch.x_max = xs[xs.size() - 1]
		ch.set_series([{"xs": xs, "ys": PackedFloat32Array(rec["max_c"]), "color": UiKit.MARS, "name": "max", "width": 1.6},
			{"xs": xs, "ys": PackedFloat32Array(rec["min_c"]), "color": UiKit.ACCENT, "name": "min", "width": 1.6}])
		ch.auto_y(0.1)
		_c_meas.add_child(ch)
	_c_meas.add_child(UiKit.wrap(str(w.get("source", "")), 10, UiKit.FAINT))


static func _n(v: Variant) -> String:
	return "—" if v == null else "%d" % int(round(float(v)))


func _rad_row(k: String, val: String, col: Color) -> void:
	var h := UiKit.hbox(8)
	var kl := UiKit.label(k, 12, UiKit.DIM)
	kl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	kl.clip_text = true
	kl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(kl)
	h.add_child(UiKit.label(val, 12, col, 600, true))
	_c_rad.add_child(h)


# ------------------------------------------------------------------ SPACE WEATHER
func _build_space_weather(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Space weather for EVA · NASA DONKI", UiKit.ACCENT, 11))
	_sw_box = PanelContainer.new()
	_sw_box.add_theme_stylebox_override("panel", UiKit.box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.1), 10, 1, 14))
	v.add_child(_sw_box)
	var b := UiKit.vbox(6)
	_sw_box.add_child(b)
	_sw_status = UiKit.label("CHECKING …", 30, UiKit.DIM, 700)
	b.add_child(_sw_status)
	_sw_reasons = UiKit.vbox(3)
	b.add_child(_sw_reasons)
	_sw_lists = UiKit.vbox(8)
	v.add_child(_sw_lists)
	var drill := UiKit.button("☢  RUN SOLAR STORM DRILL", func(): drill_requested.emit(), "Simulate a solar particle event during the EVA")
	drill.add_theme_stylebox_override("normal", UiKit.box(Color(UiKit.BAD, 0.12), Color(UiKit.BAD, 0.6), 7, 1, 10))
	drill.add_theme_font_override("font", UiKit.symbols())
	v.add_child(drill)
	var cme := UiKit.button("☀  CME DRILL  (A FULL HIT 90 MIN INTO THE EVA)", func(): Mission.toggle_cme_drill(),
		"Pretend NASA DONKI forecasts a CME reaching Mars mid-EVA: the plan turns NO-GO, the timeline shows the arrival window, and USE SOL moves the start clear of it. Click again to end the drill.")
	cme.add_theme_font_override("font", UiKit.symbols())
	v.add_child(cme)
	v.add_child(UiKit.caps("Suit emergency drills", UiKit.DIM, 10))
	var dh := UiKit.hbox(6)
	for spec in [["leak", "SUIT LEAK", "Suit pressure starts falling: EMERGENCY alarm, purge and return"], ["co2", "CO₂ BREAKTHROUGH", "The scrubber cartridge breaks through: ppCO2 climbs through caution, warning and emergency"], ["", "END DRILL", "Back to a healthy suit"]]:
		var kind: String = spec[0]
		var dbtn := UiKit.button(str(spec[1]), func(): suit_drill_requested.emit(kind), str(spec[2]))
		dbtn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dh.add_child(dbtn)
	v.add_child(dh)
	_sw_src = UiKit.wrap("", 10, UiKit.FAINT)
	v.add_child(_sw_src)


func update_space_weather() -> void:
	var sw: Dictionary = Mission.space_weather
	var st := str(sw.get("status", "UNKNOWN"))
	var col: Color = {"GREEN": UiKit.GOOD, "AMBER": UiKit.AMBER, "RED": UiKit.BAD}.get(st, UiKit.DIM)
	_sw_status.text = st
	_sw_status.add_theme_color_override("font_color", col)
	_sw_box.add_theme_stylebox_override("panel", UiKit.box(Color(col, 0.1), Color(col, 0.55), 10, 1, 14))
	UiKit.flash(_sw_box, Color(1.6, 1.6, 1.6))
	for ch in _sw_reasons.get_children():
		ch.queue_free()
	for r in sw.get("reasons", []):
		_sw_reasons.add_child(UiKit.wrap("• " + str(r), 12, UiKit.TEXT))
	for ch in _sw_lists.get_children():
		ch.queue_free()
	var arr: Array = sw.get("mars_arrivals", [])
	_sw_lists.add_child(UiKit.caps("CME arrivals predicted at Mars (WSA-ENLIL)", UiKit.DIM, 10))
	if arr.is_empty():
		_sw_lists.add_child(UiKit.label("None in the last 30 days", 12, UiKit.FAINT))
	var shown := 0
	for i in range(arr.size() - 1, -1, -1):
		var a: Dictionary = arr[i]
		var hrs := float(a.get("hours_from_now", 0))
		var row := UiKit.hbox(8)
		var when := "in %d h" % int(hrs) if hrs >= 0 else "%d h ago" % int(-hrs)
		var c := UiKit.AMBER if hrs >= 0 and hrs <= 72 else (UiKit.BAD if hrs > -24 and hrs < 0 else UiKit.DIM)
		row.add_child(UiKit.label(str(a.get("arrival", "")).substr(0, 16).replace("T", " "), 12, UiKit.TEXT, 500, true))
		var wl := UiKit.label(when, 12, c, 600)
		wl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(wl)
		if a.get("speed_kms") != null:
			row.add_child(UiKit.label("%d km/s" % int(float(a["speed_kms"])), 11, UiKit.DIM))
		if bool(a.get("glancing", false)):
			row.add_child(UiKit.chip("glancing", UiKit.DIM))
		_sw_lists.add_child(row)
		shown += 1
		if shown >= 6:
			break
	var fl: Array = sw.get("flares", [])
	_sw_lists.add_child(UiKit.caps("Solar flares ≥ M class (30 days)", UiKit.DIM, 10))
	if fl.is_empty():
		_sw_lists.add_child(UiKit.label("None reported", 12, UiKit.FAINT))
	for f in fl.slice(0, 5):
		var row2 := UiKit.hbox(8)
		var cls := str(f.get("class", "?"))
		row2.add_child(UiKit.chip(cls, UiKit.BAD if cls.begins_with("X") else UiKit.AMBER, cls.begins_with("X")))
		var pk := UiKit.label(str(f.get("peak", "")).substr(0, 16).replace("T", " "), 12, UiKit.TEXT, 500, true)
		pk.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row2.add_child(pk)
		row2.add_child(UiKit.label("%d h ago" % int(float(f.get("hours_ago", 0))), 11, UiKit.DIM))
		_sw_lists.add_child(row2)
	var se: Array = sw.get("seps", [])
	_sw_lists.add_child(UiKit.caps("Solar energetic particle events", UiKit.DIM, 10))
	if se.is_empty():
		_sw_lists.add_child(UiKit.label("None reported", 12, UiKit.FAINT))
	for s in se.slice(0, 4):
		_sw_lists.add_child(UiKit.label("%s · %d h ago" % [str(s.get("time", "")).substr(0, 16).replace("T", " "), int(float(s.get("hours_ago", 0)))], 12, UiKit.TEXT))
	var errs: Array = sw.get("errors", [])
	_sw_src.text = "%s · key %s · cache %s min%s" % [str(sw.get("source", "NASA DONKI")), str(sw.get("key", "?")),
		str(sw.get("cache_age_min", "—")), ("\nUnavailable now: " + ", ".join(PackedStringArray(errs))) if not errs.is_empty() else ""]


# ------------------------------------------------------------------ ROVER CAM
func _build_camera(v: VBoxContainer) -> void:
	_cap_cam = UiKit.caps("Rover raw images · ground truth", UiKit.ACCENT, 11)
	v.add_child(_cap_cam)
	_cam_title = UiKit.label("Select a stop", 16, UiKit.TEXT, 600)
	v.add_child(_cam_title)
	_cam_info = UiKit.wrap("Pictures the rover took where it parked closest to the selected stop.", 12, UiKit.DIM)
	v.add_child(_cam_info)
	_cam_grid = UiKit.grid(3, 6, 6)
	v.add_child(_cam_grid)


func refresh_camera() -> void:
	var target := Mission.stop_by_id(Mission.selected_stop)
	var name := ""
	var lon := 0.0
	var lat := 0.0
	if not target.is_empty():
		name = str(target["name"])
		lon = float(target["lon"])
		lat = float(target["lat"])
	elif Mission.has_plan():
		var st := Mission.state_at(Mission.eva_t)
		var ll: Vector2 = st.get("lonlat", Vector2(Mission.site_lon(), Mission.site_lat()))
		lon = ll.x
		lat = ll.y
		name = "the crew's position"
	else:
		return
	var key := "%.6f,%.6f" % [lon, lat]
	if key == _cam_key:
		return
	_cam_key = key
	_on_site_captions()   # back from Ingenuity's photos to the rover's
	_cam_title.text = "Near " + name
	_cam_info.text = "Finding %s's nearest drive stop …" % Mission.rover_label()
	for ch in _cam_grid.get_children():
		ch.queue_free()
	var nr := await Api.get_json("/api/sites/%s/rover/nearest" % Mission.site_id + Api.q({"lon": lon, "lat": lat, "n": 1}))
	if not nr["ok"] or (nr["data"]["items"] as Array).is_empty():
		_cam_info.text = "No rover stops in this site."
		return
	var it: Dictionary = nr["data"]["items"][0]
	_cam_info.text = "Sol %d–%d · drive stop %s from %s · loading raw images from mars.nasa.gov …" % [int(it["sol"]), int(it["sol_end"]), Geo.fmt_dist(float(it["distance_m"])), name]
	var im := await Api.get_json("/api/rover/%s/images" % Mission.raw_images_mission() + Api.q({"sol": int(it["sol"]), "sol_end": int(it["sol_end"]), "per_page": 90}), 90.0)
	if key != _cam_key:
		return
	if not im["ok"]:
		_cam_info.text = "Raw image feed unavailable (%s)." % str(im["error"])
		return
	var items: Array = im["data"].get("items", [])
	var seen := {}
	var picked := []
	for x in items:
		var cam := str(x.get("camera", ""))
		if seen.get(cam, 0) >= 3:
			continue
		seen[cam] = int(seen.get(cam, 0)) + 1
		picked.append(x)
		if picked.size() >= 12:
			break
	_cam_info.text = "Sol %d–%d · %d images · drive stop %s from %s. Click a picture to enlarge." % [int(it["sol"]), int(it["sol_end"]), int(im["data"].get("total", items.size())), Geo.fmt_dist(float(it["distance_m"])), name]
	var i := 0
	for x in picked:
		_add_thumb(x, i)
		i += 1


func _add_thumb(item: Dictionary, i: int) -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.4), Color(1, 1, 1, 0.12), 6, 1, 2))
	p.custom_minimum_size = Vector2(100, 100)
	p.mouse_filter = Control.MOUSE_FILTER_STOP
	p.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	p.tooltip_text = "%s · sol %d\n%s" % [str(item.get("camera", "")), int(item.get("sol", 0)), str(item.get("title", ""))]
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tr.custom_minimum_size = Vector2(96, 96)
	p.add_child(tr)
	var cap := UiKit.caps(str(item.get("camera", "")), UiKit.TEXT, 8)
	cap.size_flags_vertical = Control.SIZE_SHRINK_END
	p.add_child(cap)
	_cam_grid.add_child(p)
	p.modulate.a = 0.0
	p.mouse_entered.connect(func():
		p.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.4), UiKit.ACCENT, 6, 2, 2))
		Sfx.play("hover", -14.0))
	p.mouse_exited.connect(func(): p.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0.4), Color(1, 1, 1, 0.12), 6, 1, 2)))
	p.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			photo_requested.emit(item, tr.texture))
	var url := "/api/image-proxy" + Api.q({"url": item.get("thumb", item.get("url", "")), "max_px": 256})
	var tex := await Api.get_texture(url, "", true)
	if not is_instance_valid(p):
		return
	if tex:
		tr.texture = tex
	var tw := p.create_tween()
	tw.tween_interval(0.05 * i)
	tw.tween_property(p, "modulate:a", 1.0, 0.35)


## Inspect: how sure the data is here, what makes the spot interesting, the light, and Ingenuity's view (data-use item D2-D7).
func _inspect_extras(d: Dictionary) -> void:
	var conf_rows := []
	if d.get("sand_conf") != null:
		conf_rows.append(["Sand estimate", float(d["sand_conf"]), ""])
	if d.get("terrain_conf") != null:
		conf_rows.append(["Terrain data", float(d["terrain_conf"]), "slope ±%d°" % int(round(float(d.get("slope_unc", 0.0))))])
	if not conf_rows.is_empty():
		_insp_box.add_child(UiKit.caps("How sure the data is here", UiKit.DIM, 10))
		for cr in conf_rows:
			var v := float(cr[1])
			var row := UiKit.hbox(8)
			var nm := UiKit.label(str(cr[0]), 12, UiKit.TEXT)
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(nm)
			var word := "HIGH" if v >= 0.6 else ("MEDIUM" if v >= 0.3 else "LOW")
			row.add_child(UiKit.chip("%s %d%%%s" % [word, int(v * 100.0), ("  " + str(cr[2])) if str(cr[2]) != "" else ""],
				UiKit.GOOD if v >= 0.6 else (UiKit.AMBER if v >= 0.3 else UiKit.BAD), true))
			_insp_box.add_child(row)
	var why: Variant = d.get("sand_why")
	if why is Dictionary and (not ((why as Dictionary).get("for", []) as Array).is_empty() or not ((why as Dictionary).get("against", []) as Array).is_empty()):
		var parts := []
		if not ((why as Dictionary)["for"] as Array).is_empty():
			parts.append("for sand: " + ", ".join(PackedStringArray((why as Dictionary)["for"])))
		if not ((why as Dictionary)["against"] as Array).is_empty():
			parts.append("against: " + ", ".join(PackedStringArray((why as Dictionary)["against"])))
		_insp_box.add_child(UiKit.wrap("Sand clues " + "; ".join(PackedStringArray(parts)) + ".", 11, UiKit.DIM))
	var sci: Variant = d.get("science_info")
	if sci is Dictionary and not ((sci as Dictionary).get("reasons", []) as Array).is_empty():
		_insp_box.add_child(UiKit.caps("Science opportunity %.2f" % float((sci as Dictionary).get("score", 0.0)), UiKit.DIM, 10))
		for r in (sci as Dictionary)["reasons"]:
			_insp_box.add_child(UiKit.wrap("▸ " + str((r as Dictionary).get("text", "")), 11, UiKit.TEXT))
	var sun: Variant = d.get("sun")
	if sun is Dictionary and (sun as Dictionary).get("sunrise_ltst") != null:
		var sd: Dictionary = sun
		_insp_box.add_child(UiKit.wrap("Sun over the terrain here: %s → %s LTST (flat horizon %s–%s)." % [
			MarsTime.hms(float(sd["sunrise_ltst"]), false), MarsTime.hms(float(sd["sunset_ltst"]), false),
			MarsTime.hms(float(sd.get("flat_sunrise_ltst", 6.0)), false), MarsTime.hms(float(sd.get("flat_sunset_ltst", 18.0)), false)], 11, UiKit.DIM))
	var sc: Variant = d.get("scouted")
	if sc is Dictionary:
		var f: Dictionary = sc
		var heli := UiKit.button("INGENUITY FLIGHT %d · SOL %d PHOTOS" % [int(f["flight"]), int(f["sol"])], func(): show_ingenuity(f),
			"This spot is under Ingenuity's flight %d (%s): its downward camera saw it. Show the helicopter's photos." % [int(f["flight"]), str(f.get("earth_date", ""))])
		_insp_box.add_child(heli)


## ROVER CAM tab, Ingenuity's own photos from one flight (colour camera first, then the down-looking navigation camera).
func show_ingenuity(f: Dictionary) -> void:
	show_tab("ROVER CAM")
	_cam_key = "heli:%d" % int(f.get("flight", 0))
	_cap_cam.text = "INGENUITY RAW IMAGES · SEEN FROM THE AIR"
	_cam_title.text = "Ingenuity flight %d" % int(f.get("flight", 0))
	_cam_info.text = "Sol %d (%s) · up to %.0f m · %s · loading the helicopter's photos …" % [int(f.get("sol", 0)), str(f.get("earth_date", "")),
		float(f.get("max_alt_m", 0.0)), Geo.fmt_dist(float(f.get("length_m", 0.0)))]
	for ch in _cam_grid.get_children():
		ch.queue_free()
	var key := _cam_key
	var im := await Api.get_json("/api/ingenuity/images" + Api.q({"sol": int(f.get("sol", 0)), "per_page": 12}), 90.0)
	if key != _cam_key:
		return
	if not im["ok"]:
		_cam_info.text = "Raw image feed unavailable (%s)." % str(im["error"])
		return
	var items: Array = (im["data"] as Dictionary).get("items", [])
	_cam_info.text = "Sol %d · %d photos from Ingenuity (colour camera looks ahead, navigation camera straight down). Click to enlarge." % [int(f.get("sol", 0)), items.size()]
	var i := 0
	for x in items:
		_add_thumb(x, i)
		i += 1


# ------------------------------------------------------------------ LAYERS
func _build_layers(v: VBoxContainer) -> void:
	for ch in v.get_children():
		ch.queue_free()
	v.add_child(UiKit.caps("Draped analysis layers", UiKit.ACCENT, 11))
	var group := ButtonGroup.new()
	var none := _layer_button({"id": "", "name": "HiRISE imagery only", "group": "Base"}, group)
	none.button_pressed = true
	v.add_child(none)
	for L in Mission.site.get("layers", []):
		if str(L["id"]) == "hillshade":
			continue
		v.add_child(_layer_button(L, group))
	_legend = LegendBar.new()
	v.add_child(_legend)
	_legend_unit = UiKit.wrap("", 11, UiKit.DIM)
	v.add_child(_legend_unit)
	_layer_about = UiKit.wrap("", 11, UiKit.TEXT)
	v.add_child(_layer_about)
	var oh := UiKit.hbox(8)
	oh.add_child(UiKit.label("Opacity", 12, UiKit.DIM))
	_opacity = HSlider.new()
	_opacity.min_value = 0.1
	_opacity.max_value = 1.0
	_opacity.step = 0.01
	_opacity.value = 0.85
	_opacity.focus_mode = Control.FOCUS_NONE
	_opacity.scrollable = false   # let the wheel scroll the LAYERS page
	_opacity.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_opacity.value_changed.connect(func(x: float):
		_layer_opacity[_active_layer] = x   # remembered per layer
		opacity_changed.emit(x))
	oh.add_child(_opacity)
	v.add_child(oh)
	v.add_child(UiKit.hline())
	v.add_child(UiKit.caps("Show", UiKit.DIM, 11))
	for spec in [["route", "Planned route", true], ["traverse", "%s's traverse" % Mission.rover_label(), true], ["ingenuity", "Ingenuity flights (Jezero)", true], ["rings", "Walk-back time rings", false],
			["labels", "Labels", true], ["contours", "Contours (5 m)", false], ["grid", "100 m survey grid", false], ["dust", "Dust devils", true]]:
		var what := str(spec[0])
		v.add_child(UiKit.check(str(spec[1]), bool(spec[2]), func(on: bool): layer_toggled.emit(what, on)))
	var ping := UiKit.button("◎  PING TERRAIN SCAN", func(): ping_requested.emit(), "Sweep a scan pulse out from the habitat  [J]")
	ping.add_theme_font_override("font", UiKit.symbols())
	v.add_child(ping)


func _layer_button(L: Dictionary, group: ButtonGroup) -> Button:
	var b := UiKit.button("", func(): _choose_layer(L), str(L.get("group", "")), true)
	b.button_group = group
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text = "  %s" % str(L["name"])
	b.add_theme_font_override("font", UiKit.font(500))
	b.add_theme_font_size_override("font_size", 13)
	_layer_btns[str(L["id"])] = b
	return b


## Opacity to drape the current layer at: what you last set for it, else the API's default for that layer.
func opacity() -> float:
	return _opacity.value if _opacity else 0.85


func _choose_layer(L: Dictionary) -> void:
	_active_layer = str(L["id"])
	if _opacity:
		_opacity.set_value_no_signal(float(_layer_opacity.get(_active_layer, L.get("default_opacity", 0.85))))
	_legend.set_legend(L.get("legend"))
	var lg: Variant = L.get("legend")
	_legend_unit.text = ("Unit: " + str((lg as Dictionary).get("unit", ""))) if lg is Dictionary else ""
	var about := str(L.get("about", ""))
	if str(L.get("source", "")) != "":
		about += ("  " if about != "" else "") + "Source: " + str(L["source"]) + "."
	_layer_about.text = about
	_layer_about.visible = about != ""
	overlay_requested.emit(L)


func select_layer(id: String) -> void:
	for L in Mission.site.get("layers", []):
		if str(L["id"]) == id:
			(_layer_btns[id] as Button).button_pressed = true
			_choose_layer(L)


# ------------------------------------------------------------------ INSPECT
func _build_inspect(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Point inspector", UiKit.ACCENT, 11))
	_insp_box = UiKit.vbox(8)
	v.add_child(_insp_box)
	_insp_box.add_child(UiKit.wrap("Click anywhere on the terrain to read elevation, slope, roughness, loose-sand risk, radiation shielding, radio coverage and the walk back to the hab at that spot.", 12, UiKit.DIM))


func inspect(lonlat: Vector2) -> void:
	_insp_point = lonlat
	show_tab("INSPECT")
	for ch in _insp_box.get_children():
		ch.queue_free()
	_insp_box.add_child(UiKit.label("%.5f° E  %.5f° N" % [lonlat.x, lonlat.y], 14, UiKit.TEXT, 500, true))
	var wait := UiKit.label("Sampling 7 layers …", 12, UiKit.DIM)
	_insp_box.add_child(wait)
	var q := {"lon": lonlat.x, "lat": lonlat.y, "hab_lon": Mission.habitat["lon"], "hab_lat": Mission.habitat["lat"],
		"obs": Mission.observers(), "tgt": 2.0, "utc": MarsTime.to_iso(Mission.start_unix)}
	q.merge(Mission.walk_query())
	var r := await Api.get_json("/api/sites/%s/query" % Mission.site_id + Api.q(q), 60.0)
	if lonlat != _insp_point:
		return
	wait.queue_free()
	if not r["ok"] or not bool(r["data"].get("inside", false)):
		_insp_box.add_child(UiKit.label("Outside the mapped site.", 12, UiKit.AMBER))
		return
	var d: Dictionary = r["data"]
	var g := UiKit.grid(2, 6, 6)
	_insp_box.add_child(g)
	var hz := int(d.get("hazard", 0))
	var tiles := [
		["Elevation", "%.1f" % float(d.get("elev", 0)), "m (MOLA datum)", UiKit.TEXT],
		["Slope", "%.1f" % float(d.get("slope", 0)), "°", UiKit.AMBER if float(d.get("slope", 0)) > 15 else UiKit.TEXT],
		["Roughness", "%.2f" % float(d.get("rough", 0)), "m", UiKit.AMBER if float(d.get("rough", 0)) > 0.3 else UiKit.TEXT],
		["Loose sand", "%d" % int(float(d.get("sand", 0)) * 100.0), "%", UiKit.TEXT],
		["Sky blocked", "%.1f" % (float(d.get("shield", 0)) * 100.0), "%", UiKit.TEXT],
		["Dose rate", "%.1f" % float(d.get("gcr_usv_h", 0)), "µSv/h", UiKit.AMBER],
		["Walk back", "—" if d.get("walkback_min") == null else "%.0f" % float(d["walkback_min"]), "min", UiKit.ACCENT],
		["Radio", UiKit.COMMS_NAMES[clampi(int(d.get("comms", 0)), 0, 2)], "to hab", UiKit.GOOD if int(d.get("comms", 0)) == 2 else UiKit.AMBER],
	]
	for t in tiles:
		var st := StatTile.new(str(t[0]), str(t[2]), 18)
		st.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		st.set_text(str(t[1]), "", t[3])
		g.add_child(st)
		UiKit.appear(st, 0.04 * g.get_child_count())
	var hrow := UiKit.hbox(8)
	hrow.add_child(UiKit.label("Terrain class", 12, UiKit.DIM))
	hrow.add_child(UiKit.chip(UiKit.HAZARD_NAMES[clampi(hz, 0, 4)], UiKit.HAZARD[clampi(hz, 0, 4)], true))
	_insp_box.add_child(hrow)
	_inspect_extras(d)
	var cr: Variant = d.get("crism")
	if cr is Dictionary and not (cr as Dictionary).is_empty():
		_insp_box.add_child(UiKit.caps("Orbital spectroscopy here (CRISM)", UiKit.DIM, 10))
		for kind in cr:
			var c: Dictionary = cr[kind]
			var row := UiKit.hbox(8)
			var sw := ColorRect.new()
			var rgb: Array = c.get("rgb", [0, 0, 0])
			sw.color = Color8(int(rgb[0]), int(rgb[1]), int(rgb[2]))
			sw.custom_minimum_size = Vector2(14, 14)
			sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			row.add_child(sw)
			var nm := UiKit.label(str(c.get("name", kind)).replace("CRISM ", ""), 12, UiKit.TEXT)
			nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			nm.clip_text = true
			row.add_child(nm)
			var dom: Variant = c.get("dominant")
			var strength := float(c.get("strength", 0.0))
			row.add_child(UiKit.label(("%s · %d%%" % [str(dom), int(strength * 100.0)]) if dom != null else "weak", 11,
				UiKit.ACCENT if strength > 0.5 else UiKit.DIM, 600, true))
			_insp_box.add_child(row)
	var geo: Variant = d.get("geology")
	if geo is Dictionary:
		var gd: Dictionary = geo
		_insp_box.add_child(UiKit.caps("Geologic unit (USGS map)", UiKit.DIM, 10))
		var grow := UiKit.hbox(8)
		var gsw := ColorRect.new()
		gsw.color = Color(str(gd.get("color", "#888888")))
		gsw.custom_minimum_size = Vector2(14, 14)
		gsw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grow.add_child(gsw)
		var gn := UiKit.wrap("%s · %s" % [str(gd.get("code", "")), str(gd.get("name", ""))], 12, UiKit.TEXT)
		gn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grow.add_child(gn)
		_insp_box.add_child(grow)
		if str(gd.get("interpretation", "")) != "":
			_insp_box.add_child(UiKit.wrap(str(gd["interpretation"]), 11, UiKit.TEXT))
		_insp_box.add_child(UiKit.wrap("%s, %s" % [str(gd.get("map", "")), str(gd.get("scale", ""))], 10, UiKit.FAINT))
	var coords := "%.5f, %.5f" % [lonlat.y, lonlat.x]
	var trek := UiKit.button("OPEN NASA MARS TREK", func():
		DisplayServer.clipboard_set(coords)
		OS.shell_open(str(d.get("trek_url", "https://trek.nasa.gov/mars/"))),
		"Opens NASA Mars Trek in your browser and copies this point (lat, lon: %s) for Trek's search box" % coords)
	_insp_box.add_child(trek)
	var add := UiKit.button("+  ADD AS EVA STOP", func(): add_stop_here.emit(lonlat), "Insert a stop here and re-plan")
	add.add_theme_stylebox_override("normal", UiKit.box(Color(UiKit.ACCENT, 0.14), Color(UiKit.ACCENT, 0.6), 7, 1, 10))
	_insp_box.add_child(add)

