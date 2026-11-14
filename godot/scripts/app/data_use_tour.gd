class_name DataUseTour
extends RefCounted
## Runtime checks for the data-use pass (items D1-D7), run with
##   godot --path . --resolution 1600x900 -- --capture=<dir> --tour=datause --mute [--site=jezero_threeforks]
## Prints one "CHECK Dn PASS/FAIL  detail" line per item and saves screenshots of the new screens.
## The route, start time and suggestions are put back at the end.

var m   # main.gd


func _init(main_node) -> void:
	m = main_node


func _c(n: int, ok: bool, detail: String) -> void:
	print("CHECK D%d %s  %s" % [n, "PASS" if ok else "FAIL", detail])


func run() -> void:
	await m._await_plan()
	await m._wait(1.0)
	var stops0: Array = Mission.stops.duplicate(true)
	var start0 := Mission.start_utc
	await _space_weather()
	await _cme_drill()
	await _sand_confidence()
	await _suggest()
	await _sun()
	await _ingenuity()
	_team_frame()
	_uncertainty()
	Mission.stops = stops0
	Mission.start_utc = start0
	Mission.start_unix = MarsTime.parse_iso(start0)
	Mission.suggestions = []
	Mission.suggestions_changed.emit()
	Mission.mission_edited.emit()
	Mission.mission_restored.emit()
	Mission.save_mission()   # first: the saved mission must not keep the tour's edits, even if the re-plan below is slow
	Mission.request_plan()
	await m._await_plan(90.0)
	print("datause tour: done")


## Text of every Label under a node (to find what a panel shows).
func _texts(n: Node) -> String:
	var out := PackedStringArray()
	for ch in n.find_children("*", "Label", true, false):
		out.append((ch as Label).text)
	for ch in n.find_children("*", "Button", true, false):
		out.append((ch as Button).text)
	return " | ".join(out)


# ------------------------------------------------------------------ D1 CME arrivals against the suited window
func _space_weather() -> void:
	var body := Mission.plan_body()
	var hit := MarsTime.to_iso(Mission.start_unix + 5400.0)
	body["cme_arrivals"] = [{"arrival": hit, "glancing": false, "cme": "DRILL"}]
	var r := await Api.post_json("/api/sites/%s/plan" % Mission.site_id, body, 240.0)
	var ok: bool = bool(r["ok"]) and r["data"] is Dictionary
	var sw: Dictionary = (r["data"] as Dictionary).get("space_weather", {}) if ok else {}
	var level := str(sw.get("level", ""))
	var sug: Variant = sw.get("suggested")
	if ok:   # show the what-if plan as if the planner had made it
		Mission.plan = r["data"]
		Mission._index_plan()
		Mission.plan_changed.emit()
		await m._wait(1.5)
	var tl: TimelineBar = m.dock._timeline
	var bands := tl.cme.size()   # count now: USE SOL below re-plans onto a clear day
	var panel_txt := _texts(m.plan_panel._checks_box)
	var has_btn := panel_txt.contains("USE SOL")
	await m._shot("d01_cme_window.png")
	var moved := false
	if has_btn:
		for b in m.plan_panel._checks_box.find_children("*", "Button", true, false):
			if (b as Button).text.begins_with("USE SOL"):
				(b as Button).pressed.emit()
				break
		await m._await_plan()
		await m._wait(1.0)
		moved = Mission.start_utc != "" and sug is Dictionary and abs(Mission.start_unix - MarsTime.parse_iso(str((sug as Dictionary)["start_utc"]))) < 2.0
	_c(1, level == "nogo" and sug is Dictionary and bands > 0 and has_btn and moved,
		"what-if CME at T+1.5 h: level %s, suggested %s, timeline bands %d, USE SOL button %s, start moved %s" % [level,
		str((sug as Dictionary).get("start_ltst", "-")) if sug is Dictionary else "none", bands, has_btn, moved])


# ------------------------------------------------------------------ E1 the CME drill (SPACE WX tab)
func _cme_drill() -> void:
	Mission.toggle_cme_drill()
	await m._wait(0.3)
	await m._await_plan()
	await m._wait(1.0)
	var sw: Dictionary = Mission.plan.get("space_weather", {}) if Mission.plan.get("space_weather") is Dictionary else {}
	var lvl := str(sw.get("level", ""))
	var src := str(sw.get("source", ""))
	var go_on := bool(Mission.plan.get("totals", {}).get("go", true))
	m.info.show_tab("SPACE WX")
	await m._wait(0.6)
	await m._shot("e01_cme_drill.png")
	Mission.toggle_cme_drill()
	await m._wait(0.3)
	await m._await_plan()
	var sw2: Dictionary = Mission.plan.get("space_weather", {}) if Mission.plan.get("space_weather") is Dictionary else {}
	var ok := lvl == "nogo" and src == "request" and not go_on and Mission.cme_drill == "" and str(sw2.get("source", "")) != "request"
	print("CHECK E1 %s  CME drill: level %s from %s, plan GO %s; after ending it the forecasts come from %s" % ["PASS" if ok else "FAIL", lvl, src, go_on, str(sw2.get("source", "?"))])


# ------------------------------------------------------------------ D2 / D7 the sand estimate and its confidence in Inspect
func _sand_confidence() -> void:
	var hab := Vector2(float(Mission.habitat["lon"]), float(Mission.habitat["lat"]))
	m.info.inspect(hab)
	var waited := 0.0
	while waited < 20.0 and not _texts(m.info._insp_box).to_lower().contains("how sure"):
		await m._wait(0.5)
		waited += 0.5
	var txt := _texts(m.info._insp_box).to_lower()
	await m._shot("d02_inspect_confidence.png")
	var sand: Dictionary = Mission.site.get("sand", {}) if Mission.site.get("sand") is Dictionary else {}
	_c(2, txt.contains("how sure") and txt.contains("sand estimate") and txt.contains("terrain data") and not sand.is_empty(),
		"Inspect shows sand and terrain confidence; site sand model flags %.1f %% (>= 0.58)" % (float(sand.get("share_ge_058", 0.0)) * 100.0))


# ------------------------------------------------------------------ D3 SUGGEST STOPS
func _suggest() -> void:
	var n0 := Mission.stops.size()
	Mission.suggest_stops(3, 35.0)
	await m._wait(0.2)
	var waited := 0.0
	while Mission.suggesting and waited < 60.0:
		await m._wait(0.25)
		waited += 0.25
	await m._wait(0.8)
	var ns := Mission.suggestions.size()
	var beacons: int = m.world.sug_root.get_child_count() if m.world.sug_root else 0
	var cards := 0
	for ch in m.plan_panel._sug_box.get_children():
		if ch is PanelContainer:
			cards += 1
	var labels := 0
	for c in m.world.callouts():
		if str(c.get("kind", "")) == "suggest":
			labels += 1
	if ns > 0:
		m.world.focus_xy(Mission.xy_of(float(Mission.suggestions[0]["lon"]), float(Mission.suggestions[0]["lat"])), 900.0)
	await m._wait(2.5)
	await m._shot("d03_suggestions.png")
	var name := ""
	if ns > 0:
		name = str(Mission.suggestions[0]["name"])
		Mission.accept_suggestion(Mission.suggestions[0])
		Mission.request_plan()
		await m._await_plan()
	var in_plan := false
	for e in Mission.plan.get("events", []):
		if str(e["kind"]) == "stop" and str(e.get("name", "")) == name:
			in_plan = true
	_c(3, ns >= 1 and beacons == ns and cards == ns and labels == ns and Mission.stops.size() == n0 + 1 and in_plan,
		"%d suggestions (%d beacons, %d cards, %d callouts); added '%s' and re-planned: %s" % [ns, beacons, cards, labels, name, in_plan])


# ------------------------------------------------------------------ D4 sunlight over the real terrain
func _sun() -> void:
	var tt: Dictionary = Mission.plan.get("totals", {})
	var line := _texts(m.plan_panel._checks_box)
	m.info.show_tab("LAYERS")
	m.info.select_layer("shadow")
	var waited := 0.0
	while m.world.overlay_id != "shadow" and waited < 20.0:
		await m._wait(0.5)
		waited += 0.5
	await m._wait(1.5)
	await m._shot("d04_terrain_shadow.png")
	var drape_ok: bool = m.world.overlay_id == "shadow"
	m.info.select_layer("science")
	await m._wait(4.0)
	await m._shot("d04b_science_layer.png")
	_c(4, tt.get("terrain_sunset_ltst") != null and float(tt["terrain_sunset_ltst"]) < float(tt.get("sunset_ltst", 99.0)) and line.contains("Sun over the terrain") and drape_ok,
		"terrain sunset %s LTST (flat %s), panel line %s, shadow drape %s" % [MarsTime.hms(float(tt.get("terrain_sunset_ltst", 0.0)), false),
		MarsTime.hms(float(tt.get("sunset_ltst", 0.0)), false), line.contains("Sun over the terrain"), drape_ok])


# ------------------------------------------------------------------ D5 Ingenuity (Jezero)
func _ingenuity() -> void:
	var feats: Array = Mission.ingenuity.get("features", [])
	if feats.is_empty():
		_c(5, Mission.site_id != "jezero_threeforks" and m.world.heli_mi == null, "no Ingenuity flights at %s (expected outside Jezero)" % Mission.site_id)
		return
	var f28 := {}
	for f in feats:
		var p: Dictionary = (f as Dictionary).get("properties", {})
		if str(p.get("kind", "")) == "flight" and bool(p.get("in_site", false)) and int(p.get("flight", 0)) == 28:
			f28 = p
	var mesh_ok: bool = m.world.heli_mi != null and m.world.heli_mi.visible
	m.world.focus_xy(Mission.xy_of(77.417, 18.456), 1400.0)
	await m._wait(3.0)
	await m._shot("d05_ingenuity_flights.png")
	var thumbs := 0
	if not f28.is_empty():
		m.info.show_ingenuity(f28)
		var waited := 0.0
		while waited < 45.0 and m.info._cam_grid.get_child_count() == 0:
			await m._wait(0.5)
			waited += 0.5
		await m._wait(3.0)
		thumbs = m.info._cam_grid.get_child_count()
		await m._shot("d05b_ingenuity_photos.png")
	_c(5, mesh_ok and not f28.is_empty() and thumbs > 0, "%d flight features, 3D paths %s, flight 28 photos %d" % [feats.size(), mesh_ok, thumbs])


# ------------------------------------------------------------------ D6 the rover team's frame
func _team_frame() -> void:
	var td: Variant = Mission.site.get("team_dem")
	var off: Variant = Mission.site.get("texture_offset_m")
	var px := int(Quality.get_value("tex"))
	var cached := FileAccess.file_exists(Api.CACHE_DIR.path_join("%s_%s_texture_%d.jpg" % [Mission.site_id, Mission.build_stamp(), px]))
	var rv: Dictionary = Mission.site.get("rover", {})
	_c(6, td is Dictionary and float((td as Dictionary).get("shift_m", 0.0)) > 10.0 and off is Array and cached and bool(rv.get("aligned_with_team_dem", false)),
		"team DTM %s shifted %.0f m; texture offset %s; texture cached under this build's stamp %s; rover heights %.2f m from our DTM" % [
		str((td as Dictionary).get("name", "?")) if td is Dictionary else "none", float((td as Dictionary).get("shift_m", 0.0)) if td is Dictionary else 0.0,
		str(off), cached, float(rv.get("datum_offset_m", 99.0))])


# ------------------------------------------------------------------ D7 uncertainty in the plan
func _uncertainty() -> void:
	var tt: Dictionary = Mission.plan.get("totals", {})
	var mr: Variant = tt.get("margin_range_min")
	var sub := (m.plan_panel._tiles["margin"] as StatTile)._sub.text
	var ok: bool = mr is Array and float(mr[0]) <= float(tt["min_margin_min"]) and float(tt["min_margin_min"]) <= float(mr[1]) and sub.contains("–")
	_c(7, ok and (tt.get("route_confidence", {}) as Dictionary).has("terrain_low_m"),
		"margin %d min, range %s, tile '%s', route confidence %s" % [int(float(tt.get("min_margin_min", 0.0))), str(mr), sub, str(tt.get("route_confidence", {}))])
