class_name PlanPanel
extends PanelContainer
## Left panel: EVA summary tiles, the stops (click to fly there), GO/NO-GO checks and planner
## settings (start time, algorithm, storm drill). Everything re-animates when a new plan lands.

signal stop_activated(id: String)
signal tool_changed(tool: String)
signal undo_requested

var _status: PanelContainer
var _title: Label
var _story: Label
var _tiles := {}
var _stops_box: VBoxContainer
var _checks_box: VBoxContainer
var _add_btn: Button
var _start_lbl: Label
var _start_slider: HSlider
var _algo_a: Button
var _algo_d: Button
var _drill: CheckButton
var _ret: CheckButton
var _rover: CheckButton
var _pr_btn: Button
var _rover_lbl: Label
var _load_lbl: Label
var _load_slider: HSlider
var _compute_lbl: Label
var _busy_t := 0.0
var _undo_btn: Button
var _sug_btn: Button
var _sug_box: VBoxContainer
var _sug_limit := 35.0


func _init() -> void:
	material = UiKit.glass_material(3.2)
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL, UiKit.LINE, 12, 1, 0))
	custom_minimum_size = Vector2(350, 0)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)
	var m := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + side, 14)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(m)
	var v := UiKit.vbox(10)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	m.add_child(v)
	var head := UiKit.hbox(8)
	var ht := UiKit.vbox(0)
	ht.add_child(UiKit.caps("EVA plan", UiKit.ACCENT, 11))
	_title = UiKit.label("EVA traverse", 17, UiKit.TEXT, 600)
	ht.add_child(_title)
	ht.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(ht)
	_status = UiKit.chip("PLANNING", UiKit.DIM)
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_status)
	v.add_child(head)
	_story = UiKit.wrap("", 12, UiKit.DIM)
	v.add_child(_story)
	var g := UiKit.grid(2, 6, 6)
	v.add_child(g)
	for spec in [["dist", "Distance", "km"], ["dur", "Duration", ""], ["margin", "Min. margin", "min"], ["dose", "Radiation dose", "µSv"],
			["climb", "Climb / descent", "m"], ["slope", "Steepest", "°"], ["walkback", "Farthest walk-back", "min"], ["radio", "Radio shadow", "%"]]:
		var t := StatTile.new(str(spec[1]), str(spec[2]), 20)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		g.add_child(t)
		_tiles[spec[0]] = t
	_compute_lbl = UiKit.label("", 11, UiKit.FAINT)
	v.add_child(_compute_lbl)
	v.add_child(UiKit.hline())
	var sh := UiKit.hbox(8)
	var stl := UiKit.caps("Traverse stops", UiKit.DIM, 11)
	stl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sh.add_child(stl)
	_add_btn = UiKit.button("+ ADD STOP", func(): tool_changed.emit("add-stop" if _add_btn.button_pressed else ""), "Then click the terrain to drop a new stop", true)
	sh.add_child(_add_btn)
	v.add_child(sh)
	_stops_box = UiKit.vbox(6)
	v.add_child(_stops_box)
	var sg_row := UiKit.hbox(6)
	_sug_btn = UiKit.button("✦  SUGGEST STOPS", func(): Mission.suggest_stops(3, _sug_limit),
		"Find science stops (CRISM minerals, map-unit contacts, ridges and hollows, rover sample sites) inside the safe walk-back range")
	_sug_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sg_row.add_child(_sug_btn)
	var lim := UiKit.button("≤ 35 MIN", func(): pass, "Longest walk back to the hab (or the parked rover) a suggested stop may have. Click to change.")
	lim.pressed.connect(func():
		_sug_limit = 20.0 if _sug_limit >= 50.0 else _sug_limit + 15.0
		lim.text = "≤ %d MIN" % int(_sug_limit))
	sg_row.add_child(lim)
	v.add_child(sg_row)
	_sug_box = UiKit.vbox(5)
	v.add_child(_sug_box)
	v.add_child(UiKit.hline())
	v.add_child(UiKit.caps("Go / no-go checks", UiKit.DIM, 11))
	_checks_box = UiKit.vbox(5)
	v.add_child(_checks_box)
	v.add_child(UiKit.hline())
	v.add_child(UiKit.caps("Planner", UiKit.DIM, 11))
	_start_lbl = UiKit.label("Egress at —", 12, UiKit.TEXT)
	v.add_child(_start_lbl)
	_start_slider = HSlider.new()
	_start_slider.min_value = 6.5
	_start_slider.max_value = 15.5
	_start_slider.step = 0.25
	_start_slider.value = 9.0
	_start_slider.focus_mode = Control.FOCUS_NONE
	_start_slider.scrollable = false   # the wheel scrolls the panel; it must not move the slider behind the planner's back
	_start_slider.value_changed.connect(func(x: float): _start_lbl.text = "Egress at %s LTST (next sol)" % MarsTime.hms(x, false))
	_start_slider.drag_ended.connect(func(changed: bool):
		if changed:
			Mission.set_start_hour(_start_slider.value)
			Mission.request_plan())
	v.add_child(_start_slider)
	_load_lbl = UiKit.label("Carried equipment: 8 kg", 12, UiKit.TEXT)
	v.add_child(_load_lbl)
	_load_slider = HSlider.new()
	_load_slider.min_value = 0
	_load_slider.max_value = 40
	_load_slider.step = 1
	_load_slider.value = 8
	_load_slider.focus_mode = Control.FOCUS_NONE
	_load_slider.scrollable = false
	_load_slider.tooltip_text = "Tools, sample bags and instruments. Each kg slows walking by 0.4 % and raises the metabolic cost."
	_load_slider.value_changed.connect(func(x: float): _load_lbl.text = "Carried equipment: %d kg  ·  %.2f m/s on the flat" % [int(x), float(Mission.walk.get("flat_speed", 0.8)) / (1.0 + 0.004 * x)])
	_load_slider.drag_ended.connect(func(changed: bool):
		if changed:
			Mission.push_undo("change the carried load")
			Mission.walk["load_kg"] = _load_slider.value
			Mission.request_plan())
	v.add_child(_load_slider)
	var algo := UiKit.hbox(0)
	_algo_a = UiKit.button("A*  (own)", func(): _set_algo("astar"), "Directional A* written for this project", true)
	_algo_d = UiKit.button("DIJKSTRA", func(): _set_algo("dijkstra"), "scikit-image minimum-cost path (C)", true)
	var bg := ButtonGroup.new()
	_algo_a.button_group = bg
	_algo_d.button_group = bg
	_algo_a.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_algo_d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	algo.add_child(_algo_a)
	algo.add_child(_algo_d)
	v.add_child(algo)
	_drill = UiKit.check("Solar storm drill (SEP)", false, func(on: bool):
		Mission.push_undo("storm drill %s" % ("on" if on else "off"))
		Mission.sep_active = on
		Mission.request_plan())
	v.add_child(_drill)
	_ret = UiKit.check("Return to the habitat", true, func(on: bool):
		Mission.push_undo("return to the habitat %s" % ("on" if on else "off"))
		Mission.return_to_hab = on
		Mission.request_plan())
	v.add_child(_ret)
	var rv_row := UiKit.hbox(6)
	_rover = UiKit.check("Drive out in PR-2", false, func(on: bool):
		Mission.set_rover(on)
		Mission.request_plan())
	_rover.tooltip_text = "Rover-assisted EVA: PR-2 drives the crew to a drop-off near the stops (slopes under 20°, around boulders of 1 m and more). Suit consumables are only used outside; the parked rover is the safe haven and a radio relay."
	_rover.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rv_row.add_child(_rover)
	_pr_btn = UiKit.button("PLACE", func(): tool_changed.emit("place-pr" if _pr_btn.button_pressed else ""), "Click the terrain to park PR-2 there", true)
	rv_row.add_child(_pr_btn)
	var auto_fn := func():
		Mission.auto_dropoff()
		if Mission.rover_enabled:
			Mission.request_plan()
	rv_row.add_child(UiKit.button("AUTO", auto_fn, "Let the planner choose a level, drivable drop-off that keeps the walking short"))
	v.add_child(rv_row)
	_rover_lbl = UiKit.wrap("", 11, UiKit.DIM)
	v.add_child(_rover_lbl)
	var acts := UiKit.hbox(6)
	var rp := UiKit.button("⟳  RE-PLAN", func(): Mission.request_plan(), "Recompute the route and timeline")
	rp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rp.add_theme_stylebox_override("normal", UiKit.box(Color(UiKit.ACCENT, 0.16), Color(UiKit.ACCENT, 0.6), 7, 1, 10))
	acts.add_child(rp)
	_undo_btn = UiKit.button("↶", func(): undo_requested.emit(), "Undo the last change  [Ctrl+Z]")
	_undo_btn.add_theme_font_override("font", UiKit.symbols())
	_undo_btn.disabled = true
	acts.add_child(_undo_btn)
	var reset_fn := func():
		Mission.reset_mission()
		Mission.notify.emit("Stops and settings reset to the site's defaults. Ctrl+Z brings yours back.", "info")
		Mission.request_plan()
	acts.add_child(UiKit.button("RESET", reset_fn, "Restore the site's default stops (Ctrl+Z undoes it)"))
	acts.add_child(UiKit.button("SHEET", func(): Mission.traverse_sheet(), "Apollo-style traverse sheet: photomap, stations, times and tasks (opens in your browser)"))
	v.add_child(acts)
	v.add_child(UiKit.spacer(4))


func _ready() -> void:
	Mission.plan_started.connect(_on_plan_started)
	Mission.plan_changed.connect(_on_plan)
	Mission.plan_failed.connect(func(msg: String):
		UiKit.set_chip(_status, "ROUTE FAILED", UiKit.BAD, true)
		_compute_lbl.text = msg)
	Mission.mission_edited.connect(_rebuild_stops)
	Mission.tasks_changed.connect(_rebuild_stops)
	Mission.selection_changed.connect(func(_id: String): _rebuild_stops())
	Mission.site_loaded.connect(_on_site)
	Mission.suggestions_changed.connect(_rebuild_suggestions)
	Mission.mission_restored.connect(_sync_controls)
	Mission.history_changed.connect(func():
		_undo_btn.disabled = not Mission.can_undo()
		_undo_btn.tooltip_text = ("Undo: %s  [Ctrl+Z]" % Mission.undo_label()) if Mission.can_undo() else "Nothing to undo")


func _on_site() -> void:
	_story.text = str(Mission.site.get("story", ""))
	_title.text = "%s traverse" % str(Mission.site.get("short_name", "EVA"))
	_sync_controls()


## Put every planner control back in line with Mission (site load, undo, redo, reset).
func _sync_controls() -> void:
	_drill.set_pressed_no_signal(Mission.sep_active)
	_ret.set_pressed_no_signal(Mission.return_to_hab)
	_rover.set_pressed_no_signal(Mission.rover_enabled)
	_algo_a.set_pressed_no_signal(Mission.algorithm == "astar")   # both: no_signal does not update the group
	_algo_d.set_pressed_no_signal(Mission.algorithm != "astar")
	var lt := MarsTime.ltst(MarsTime.at(Mission.start_unix), Mission.site_lon())
	_start_slider.set_value_no_signal(snappedf(lt, 0.25))
	_start_lbl.text = "Egress at %s LTST (next sol)" % MarsTime.hms(lt, false)
	var ld := float(Mission.walk.get("load_kg", 8.0))
	_load_slider.set_value_no_signal(ld)
	_load_lbl.text = "Carried equipment: %d kg  ·  %.2f m/s on the flat" % [int(ld), float(Mission.walk.get("flat_speed", 0.8)) / (1.0 + 0.004 * ld)]
	_rebuild_stops()


func set_tool(tool: String) -> void:
	_add_btn.set_pressed_no_signal(tool == "add-stop")
	_pr_btn.set_pressed_no_signal(tool == "place-pr")


func _set_algo(a: String) -> void:
	if Mission.algorithm != a:
		Mission.push_undo("switch to %s" % ("A*" if a == "astar" else "Dijkstra"))
		Mission.algorithm = a
		Mission.request_plan()


func _on_plan_started() -> void:
	UiKit.set_chip(_status, "PLANNING …", UiKit.ACCENT)
	_busy_t = 0.0


func _process(delta: float) -> void:
	if Mission.planning:
		_busy_t += delta
		_compute_lbl.text = "Routing over 2.6 M cells" + ".".repeat(int(_busy_t * 3.0) % 4)


func _on_plan() -> void:
	var tt: Dictionary = Mission.plan["totals"]
	var go := bool(tt["go"])
	UiKit.set_chip(_status, "GO" if go else "NO-GO", UiKit.GOOD if go else UiKit.BAD, true)
	UiKit.flash(_status, Color(2, 2, 2))
	var riding := bool(tt.get("rover", false))
	(_tiles["dist"] as StatTile).set_value(float(tt["dist_m"]) / 1000.0, func(x: float) -> String: return "%.2f" % x,
		("walked · +%.2f km by PR-2" % (float(tt.get("drive_m", 0.0)) / 1000.0)) if riding else "walked")
	(_tiles["dur"] as StatTile).set_value(float(tt["total_s"]), func(x: float) -> String: return MarsTime.dur(x),
		("walk %s · work %s · drive %s" % [MarsTime.dur(float(tt["walk_s"])), MarsTime.dur(float(tt["stop_s"])), MarsTime.dur(float(tt.get("drive_s", 0.0)))]) if riding
		else ("walk %s · work %s" % [MarsTime.dur(float(tt["walk_s"])), MarsTime.dur(float(tt["stop_s"]))]))
	_rover_lbl.text = ("Drop-off %s · %s in the cab · %s in suits · the parked rover is the safe haven and a radio relay"
		% ["placed by hand" if not Mission.rover_dropoff.is_empty() else "chosen automatically", MarsTime.dur(float(tt.get("drive_s", 0.0))), MarsTime.dur(float(tt.get("suit_s", 0.0)))]) if riding else ""
	_rover_lbl.visible = riding
	var mg := float(tt["min_margin_min"])
	var mr: Variant = tt.get("margin_range_min")
	var mr_txt := (" · %d–%d" % [int(round(float(mr[0]))), int(round(float(mr[1])))]) if mr is Array and (mr as Array).size() == 2 else ""
	(_tiles["margin"] as StatTile).set_value(mg, func(x: float) -> String: return "%d" % int(round(x)),
		"limited by %s%s" % [str(tt.get("limiting", "—")), mr_txt], UiKit.GOOD if mg >= 60 else (UiKit.AMBER if mg >= 20 else UiKit.BAD))
	(_tiles["dose"] as StatTile).set_value(float(tt["dose_usv"]), func(x: float) -> String: return "%.1f" % x,
		"≈ %.1f%% of a 600 mSv career" % (float(tt["dose_usv"]) / 6000.0), UiKit.AMBER if Mission.sep_active else UiKit.TEXT)
	(_tiles["climb"] as StatTile).set_value(float(tt["ascent_m"]), func(x: float) -> String: return "%d" % int(round(x)), "descent %d m" % int(round(float(tt["descent_m"]))))
	var ms := float(tt["max_slope"])
	(_tiles["slope"] as StatTile).set_value(ms, func(x: float) -> String: return "%.1f" % x, "limit %d°" % int(float(Mission.walk.get("max_slope", 25))),
		UiKit.AMBER if ms > float(Mission.walk.get("caution_slope", 15)) else UiKit.TEXT)
	(_tiles["walkback"] as StatTile).set_value(float(tt["max_walkback_min"]), func(x: float) -> String: return "%.0f" % x, "to PR-2 (parked)" if riding else "to the hab")
	var dead := float(tt["comms_dead_fraction"]) * 100.0
	(_tiles["radio"] as StatTile).set_value(dead, func(x: float) -> String: return "%.0f" % x, "no line of sight", UiKit.AMBER if dead > 5.0 else UiKit.TEXT)
	_compute_lbl.text = "%s · %d legs · computed in %.1f s" % ["A* (own)" if str(tt["algorithm"]) == "astar" else "Dijkstra (scikit-image)",
		(Mission.plan["legs"] as Array).size(), float(tt["compute_ms"]) / 1000.0]
	for c in _checks_box.get_children():
		c.queue_free()
	var i := 0
	for iss in Mission.plan.get("issues", []):
		var lvl := str(iss["level"])
		var col := UiKit.GOOD if lvl == "ok" else (UiKit.BAD if lvl.begins_with("nogo") else UiKit.AMBER)
		var row := UiKit.hbox(8)
		var icon := UiKit.label("✓" if lvl == "ok" else ("✕" if lvl.begins_with("nogo") else "!"), 14, col, 700)
		icon.custom_minimum_size = Vector2(16, 0)
		icon.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		row.add_child(icon)
		var t := UiKit.wrap(str(iss["text"]), 12, UiKit.TEXT)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(t)
		_checks_box.add_child(row)
		UiKit.appear(row, 0.08 * i)
		i += 1
	_add_space_weather()
	_add_sun_line(tt)
	_rebuild_stops()


## The sun over the real terrain where the EVA ends, next to the flat-horizon times (data-use item D4).
func _add_sun_line(tt: Dictionary) -> void:
	if tt.get("terrain_sunset_ltst") == null:
		return
	var txt := "Sun over the terrain at the %s: %s → %s LTST (flat %s–%s)." % ["rover" if bool(tt.get("rover", false)) else "hab",
		MarsTime.hms(float(tt["terrain_sunrise_ltst"]), false), MarsTime.hms(float(tt["terrain_sunset_ltst"]), false),
		MarsTime.hms(float(tt.get("sunrise_ltst", 6.0)), false), MarsTime.hms(float(tt.get("sunset_ltst", 18.0)), false)]
	if float(tt.get("shade_min", 0.0)) > 0.0:
		txt += " %d min of the walk in terrain shadow." % int(round(float(tt["shade_min"])))
	_checks_box.add_child(UiKit.wrap(txt, 11, UiKit.DIM))


func _rebuild_suggestions() -> void:
	_sug_btn.disabled = Mission.suggesting
	_sug_btn.text = "SEARCHING …" if Mission.suggesting else "✦  SUGGEST STOPS"
	for c in _sug_box.get_children():
		c.queue_free()
	var i := 0
	for sg in Mission.suggestions:
		var s: Dictionary = sg
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UiKit.box(Color(MarsWorld.C_SUGGEST, 0.08), Color(MarsWorld.C_SUGGEST, 0.5), 8, 1, 8))
		var col := UiKit.vbox(2)
		card.add_child(col)
		var head := UiKit.hbox(6)
		var nm := UiKit.label("◆ " + str(s.get("name", "Science stop")), 13, UiKit.TEXT, 600)
		nm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		head.add_child(nm)
		var add_fn := func():
			Mission.accept_suggestion(s)
			Mission.request_plan()
		head.add_child(UiKit.button("+ ADD", add_fn, "Add this stop to the route and re-plan"))
		col.add_child(head)
		var unit: Variant = s.get("unit")
		col.add_child(UiKit.label("SCIENCE %.2f · %.0f MIN BACK · SLOPE %.0f°%s" % [float(s.get("score", 0.0)), float(s.get("walkback_min", 0.0)), float(s.get("slope", 0.0)),
			(" · " + str((unit as Dictionary).get("code", ""))) if unit is Dictionary else ""], 10, MarsWorld.C_SUGGEST))
		var k := 0
		for r in s.get("reasons", []):
			if k >= 2:
				break
			col.add_child(UiKit.wrap("▸ " + str((r as Dictionary).get("text", "")), 11, UiKit.DIM))
			k += 1
		_sug_box.add_child(card)
		UiKit.appear(card, 0.06 * i)
		i += 1
	if not Mission.suggestions.is_empty():
		var clear := UiKit.button("CLEAR SUGGESTIONS", func():
			Mission.suggestions = []
			Mission.suggestions_changed.emit())
		_sug_box.add_child(clear)


## DONKI CME forecasts against the suited window: where the data came from, and the first clear start.
func _add_space_weather() -> void:
	var sw: Dictionary = Mission.plan.get("space_weather", {}) if Mission.plan.get("space_weather") is Dictionary else {}
	if sw.is_empty():
		return
	var src := str(sw.get("source", ""))
	var txt := ""
	if not bool(sw.get("checked", false)):
		txt = "Space weather not checked (%s)." % ("turned off" if src == "off" else "NASA DONKI unreachable, nothing cached")
	else:
		var near := 0
		for a in sw.get("arrivals", []):
			if a.get("overlap") != null:
				near += 1
		txt = "CME forecasts at Mars (DONKI %s): %s. Each forecast counts as a ±%d h window." % [
			"live" if src == "live" else ("cache" if src == "cache" else "what-if"),
			("%d overlap the time in suits" % near) if near > 0 else "none near the time in suits", int(float(sw.get("uncertainty_h", 12.0)))]
	_checks_box.add_child(UiKit.wrap(txt, 11, UiKit.DIM))
	var sug: Variant = sw.get("suggested")
	if sug is Dictionary:
		var sd: Dictionary = sug
		var d := float(sd.get("delay_h", 0.0))
		var use_fn := func():
			Mission.set_start_utc(str(sd["start_utc"]))
			Mission.notify.emit("EVA start moved clear of the CME arrival window. Ctrl+Z undoes it.", "ok")
			Mission.request_plan()
		var b := UiKit.button("USE SOL %d %s LTST  (%s%d h)" % [int(sd.get("mission_sol", 0)), MarsTime.hms(float(sd.get("start_ltst", 9.0)), false),
				"+" if d >= 0 else "", int(round(d))], use_fn,
			"First start whose time in suits clears every predicted arrival window and still ends 30 min before sunset")
		_checks_box.add_child(b)


func _rebuild_stops() -> void:
	for c in _stops_box.get_children():
		c.queue_free()
	var events: Array = Mission.plan.get("events", []) if Mission.has_plan() else []
	var idx := 1
	for s in Mission.stops:
		var id := str(s["id"])
		var kind := str(s.get("kind", "custom"))
		var col: Color = MarsWorld.STOP_COLORS.get(kind, MarsWorld.STOP_COLORS["custom"])
		var sel := id == Mission.selected_stop
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", UiKit.box(Color(col, 0.16 if sel else 0.05), Color(col, 0.8 if sel else 0.22), 8, 1, 8))
		card.mouse_filter = Control.MOUSE_FILTER_STOP
		card.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var row := UiKit.hbox(10)
		card.add_child(row)
		var badge := Control.new()
		badge.custom_minimum_size = Vector2(28, 28)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var n := idx
		badge.draw.connect(func():
			badge.draw_circle(Vector2(14, 14), 13, Color(col, 0.25))
			badge.draw_arc(Vector2(14, 14), 13, 0, TAU, 32, col, 1.5, true)
			badge.draw_string(UiKit.font(700), Vector2(0, 19), str(n), HORIZONTAL_ALIGNMENT_CENTER, 28, 13, Color.WHITE))
		row.add_child(badge)
		var col_v := UiKit.vbox(1)
		col_v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col_v.add_child(UiKit.label(str(s.get("name", id)), 14, UiKit.TEXT, 600))
		var eta := ""
		for e in events:
			if str(e["kind"]) == "stop" and str(e.get("id", "")) == id:
				eta = " · arrive %s · %s LTST" % [MarsTime.clock(float(e["t0"])), MarsTime.hms(float(e.get("t0_ltst", 0.0)), false)]
		var tasks_all: Array = s.get("tasks", [])
		var done := 0
		for v in Mission.task_state(id, tasks_all.size()):
			if bool(v):
				done += 1
		var tick := ("  ·  ✓ %d/%d" % [done, tasks_all.size()]) if done > 0 else ""
		col_v.add_child(UiKit.label("%s · %d min%s%s" % [kind.to_upper(), int(s.get("dwell_min", 20)), eta, tick], 11, col))
		if sel and str(s.get("science", "")) != "":
			col_v.add_child(UiKit.wrap(str(s["science"]), 11, UiKit.DIM))
			for task in s.get("tasks", []):
				col_v.add_child(UiKit.label("▸ " + str(task), 11, UiKit.TEXT))
		if sel:
			for e in events:
				if str(e["kind"]) == "stop" and str(e.get("id", "")) == id:
					var lt: Variant = (e as Dictionary).get("light")
					if lt is Dictionary:
						col_v.add_child(UiKit.wrap("☀ " + str((lt as Dictionary).get("note", "")), 11, UiKit.DIM))
					var sci: Variant = (e as Dictionary).get("science")
					if sci is Dictionary:
						for r in (sci as Dictionary).get("reasons", []):
							col_v.add_child(UiKit.wrap("◆ " + str((r as Dictionary).get("text", "")), 11, MarsWorld.C_SUGGEST))
					var sc: Variant = (e as Dictionary).get("scouted")
					if sc is Dictionary:
						col_v.add_child(UiKit.wrap("Seen from the air by Ingenuity: flight %d, sol %d" % [int((sc as Dictionary)["flight"]), int((sc as Dictionary)["sol"])], 11, MarsWorld.C_HELI))
		row.add_child(col_v)
		if Mission.stops.size() > 1:
			var remove_fn := func():
				var nm := str(Mission.stop_by_id(id).get("name", id))
				Mission.remove_stop(id)
				Mission.notify.emit("Removed %s. Ctrl+Z puts it back." % nm, "info")
				Mission.request_plan()
			var del := UiKit.button("✕", remove_fn, "Remove this stop")
			del.flat = true
			del.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			row.add_child(del)
		card.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
				Sfx.play("click", -6.0)
				stop_activated.emit(id))
		card.mouse_entered.connect(func(): Sfx.play("hover", -14.0))
		_stops_box.add_child(card)
		idx += 1
