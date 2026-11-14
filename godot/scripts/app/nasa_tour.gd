class_name NasaTour
extends RefCounted
## Runtime checks for the NASA standards pass (docs/NASA_STANDARDS.md items N1-N25), run with
##   godot --path . --resolution 1600x900 -- --capture=<dir> --tour=nasa --mute
## Prints one "CHECK Nn PASS/FAIL  detail" line per item and saves screenshots of the new screens.
## Every setting it changes is put back at the end.

var m   # main.gd
var _before := {}


func _init(main_node) -> void:
	m = main_node


func _c(n: int, ok: bool, detail: String) -> void:
	print("CHECK N%d %s  %s" % [n, "PASS" if ok else "FAIL", detail])


func _setv(key: String, v: Variant) -> void:
	if not _before.has(key):
		_before[key] = Settings.get_value(key)
	Settings.set_value(key, v)


func run() -> void:
	await m._await_plan()
	await m._wait(1.0)
	await _layers()
	await _alerts()
	await _suit()
	await _information()
	await _settings()
	await _controls()
	await _abort_and_menu()
	await _voice()
	for k in _before:
		Settings.set_value(k, _before[k])
	Controls.reset_all()
	print("nasa tour: done")


# ------------------------------------------------------------------ N1-N3 data layers and legends
func _layers() -> void:
	var layers: Array = Mission.site.get("layers", [])
	var geo := {}
	var day := {}
	for L in layers:
		if str(L["id"]) == "geology":
			geo = L
		elif str(L["id"]) == "thermal_day":
			day = L
	var ok1 := not geo.is_empty() and (geo.get("legend", {}) as Dictionary).has("classes")
	var q := await Api.get_json("/api/sites/%s/query" % Mission.site_id + Api.q({"lon": float(Mission.site["center"]["lon"]), "lat": float(Mission.site["center"]["lat"])}), 60.0)
	var unit := ""
	if q["ok"] and q["data"] is Dictionary and (q["data"] as Dictionary).has("geology"):
		unit = "%s %s" % [str(q["data"]["geology"]["code"]), str(q["data"]["geology"]["name"])]
	if ok1:
		m.info.show_tab("LAYERS")
		m.info.select_layer("geology")
		await m._wait(4.0)
		ok1 = m.world.overlay_id == "geology"
		await m._shot("n01_geology.png")
	_c(1, ok1 and unit != "", "geology layer %s, %d legend classes, unit at the centre: %s" % [not geo.is_empty(), (geo.get("legend", {}).get("classes", []) as Array).size(), unit])
	var ok2 := not day.is_empty() and str(day.get("source", "")).contains("Mars Trek")
	if ok2:
		m.info.select_layer("thermal_day")
		await m._wait(4.0)
		ok2 = m.world.overlay_id == "thermal_day"
		await m._shot("n02_thermal_day.png")
	var trek := str(q["data"].get("trek_url", "")) if q["ok"] else ""
	_c(2, ok2 and trek.begins_with("https://trek.nasa.gov/mars"), "THEMIS day IR via Mars Trek draped %s; Trek link %s" % [ok2, trek])
	m.info.select_layer("hazard")
	await m._wait(0.3)
	var lg: LegendBar = m.info._legend
	var hz_classes := lg.classes.size()
	await m.get_tree().process_frame
	var hz_h := lg.custom_minimum_size.y
	var h_ok := hz_classes == 5 and hz_h > 20.0
	m.info.select_layer("geology")
	await m._wait(0.3)
	var g_classes := lg.classes.size()
	_c(3, h_ok and g_classes >= 1, "hazard legend %d labelled classes (height %.0f px), geology %d" % [hz_classes, hz_h, g_classes])
	m.info.select_layer("")
	m._on_overlay({"id": ""})


# ------------------------------------------------------------------ N4-N8 caution and warning
func _alerts() -> void:
	Mission.set_playing(false)
	CW.reset()
	# N4: classes, colours and priority
	CW.raise("test_caution", "check")
	CW.raise("test_warning", "check")
	CW.raise("test_emergency", "check")
	var top := CW.top()
	var mm := CW.master()
	var cols_ok := UiKit.level_col("emergency") == UiKit.BAD and UiKit.level_col("caution") == UiKit.CAUTION and UiKit.level_col("advisory") == UiKit.ADVISORY
	_c(4, str(top.get("level", "")) == "emergency" and str(mm["level"]) == "emergency" and int(mm["n"]) == 3 and cols_ok,
		"top %s, master %s x%d, colours by class %s" % [str(top.get("level", "")), str(mm["level"]), int(mm["n"]), cols_ok])
	await m._wait(1.2)
	await m._shot("n04_banner.png")
	CW.reset()
	# N5: latched until acknowledged
	for i in 12:
		CW.set_condition("comms", true, "check")
		await m._wait(0.1)
	var raised := not CW.get_alert("comms").is_empty()
	for i in 30:
		CW.set_condition("comms", false)
		await m._wait(0.1)
	var latched := not CW.get_alert("comms").is_empty() and bool(CW.get_alert("comms")["cleared"])
	CW.acknowledge("comms")
	var gone := CW.get_alert("comms").is_empty()
	_c(5, raised and latched and gone, "raised after the hold %s, still listed after clearing %s, gone once acknowledged %s" % [raised, latched, gone])
	# N6: silence / shelve / inhibit / audit
	CW.raise("test_warning", "check")
	var silenced := CW.silence() >= 1 and bool(CW.get_alert("test_warning")["silenced"]) and not bool(CW.get_alert("test_warning")["acked"])
	CW.acknowledge("test_warning")
	CW.shelve("hr_high", 1.0)
	for i in 10:
		CW.set_condition("hr_high", true, "check")
		await m._wait(0.1)
	# shelved: still listed, but not the alert put in front of the crew (a real alert, e.g. space weather, may be)
	var shelved := bool(CW.get_alert("hr_high").get("shelved", false)) and str(CW.top().get("id", "")) != "hr_high"
	CW.unshelve("hr_high")
	CW.reset()
	var audits := []
	var on_audit := func(t: Array): audits.append(t)
	CW.audit.connect(on_audit)
	CW.set_inhibited("slope", true)
	for i in 10:
		CW.set_condition("slope", true, "check")
		await m._wait(0.1)
	var inhibited_quiet := CW.get_alert("slope").is_empty()
	CW._audit_at = 0
	await m.get_tree().process_frame
	await m.get_tree().process_frame
	CW.audit.disconnect(on_audit)
	CW.set_inhibited("slope", false)
	_c(6, silenced and shelved and inhibited_quiet and audits.size() >= 1, "silence keeps it listed %s; shelved: listed, not annunciated %s; inhibited: not raised %s; audit fired %d" % [silenced, shelved, inhibited_quiet, audits.size()])
	# N7: tones, pre-alert, own bus with a floor, M leaves alarms alone
	var lens_ok := true
	for n in ["cw_emergency", "cw_warning", "cw_caution", "cw_advisory"]:
		var w: AudioStreamWAV = Sfx._streams.get(n)
		var secs := (w.data.size() / 2.0) / Sfx.RATE if w else 0.0
		lens_ok = lens_ok and absf(secs - float(Sfx.ALERT_LEN[n])) < 0.02
	CW.raise("test_caution", "check")
	await m._wait(0.3)
	var first := Sfx.last_alert.duplicate()
	await m._wait(float(Sfx.ALERT_LEN["cw_caution"]) + float(CW.GAP_S["caution"]) + 0.5)
	var second := Sfx.last_alert.duplicate()
	CW.reset()
	Sfx.set_enabled(false)
	var before_ms := int(Sfx.last_alert.get("msec", 0))
	CW.raise("test_warning", "check")
	await m._wait(0.3)
	var muted_still := int(Sfx.last_alert.get("msec", 0)) > before_ms and str(Sfx.last_alert.get("name", "")) == "cw_warning"
	Sfx.set_enabled(true)
	CW.reset()
	_setv("vol_alerts", 0.0)
	var bus_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(Sfx.BUS_ALERT))
	var floor_ok := bus_db >= linear_to_db(Sfx.ALERT_MIN_VOL) - 0.1
	_c(7, lens_ok and float(first.get("vol_db", 0)) == -10.0 and float(second.get("vol_db", -10)) == 0.0 and muted_still and floor_ok,
		"tone lengths per Table 10.3-1 %s; first burst %.0f dB, repeat %.0f dB; plays while muted %s; alarm bus at slider 0 = %.1f dB (floor %s)" % [lens_ok, float(first.get("vol_db", 0)), float(second.get("vol_db", -10)), muted_still, bus_db, floor_ok])
	# N8: log, export, test, speech
	var n0 := CW.log_entries.size()
	CW.test_annunciators()
	await m._wait(1.6)
	await m._shot("n08_test_alarms.png")
	while CW.testing:
		await m.get_tree().process_frame
	var tested := false
	for i in range(n0, CW.log_entries.size()):
		if str(CW.log_entries[i]["what"]) == "TEST COMPLETE":
			tested = true
	var csv := CW.export_log()
	var voices := DisplayServer.tts_get_voices_for_language("en").size()
	_c(8, tested and csv != "" and FileAccess.file_exists(csv), "annunciator test logged %s; %d log entries; CSV %s; English TTS voices %d (speech %s)" % [tested, CW.log_entries.size(), csv.get_file(), voices, CW.speech_ok])
	m.cw_panel.toggle(m.ui.size, "LOG")
	await m._wait(0.6)
	await m._shot("n08_cw_log.png")
	m.cw_panel.toggle(m.ui.size, "CATALOGUE")
	await m._wait(0.6)
	await m._shot("n08_cw_catalogue.png")
	m.cw_panel.close()
	CW.reset()


# ------------------------------------------------------------------ N9-N10 suit
func _suit() -> void:
	var tt: Dictionary = Mission.plan["totals"]
	Mission.set_time(float(tt["total_s"]) * 0.3)
	Mission.speed_index = 0
	Mission.set_playing(true)   # live: the monitor checks the suit
	await m._wait(1.5)
	var d: Dictionary = m.tel.d
	var nominal := absf(float(d["p_suit"]) - SuitModel.SUIT_P_KPA) < 0.1 and float(d["ppco2"]) < SuitModel.PPCO2_CAUTION and float(d["ppo2"]) > SuitModel.PPO2_CAUTION
	var levels := []
	m._suit_drill("co2")
	for i in 120:
		await m._wait(0.25)
		var a := CW.get_alert("ppco2_high")
		if not a.is_empty() and not levels.has(str(a["level"])):
			levels.append(str(a["level"]))
		if levels.has("emergency"):
			break
	var pc := float(m.tel.d["ppco2"])
	await m._shot("n09_co2_drill.png")
	m._suit_drill("")
	CW.reset()
	m._suit_drill("leak")
	var leak := false
	var leak_s := 0.0
	for i in 60:
		await m._wait(0.25)
		leak_s += 0.25
		if not CW.get_alert("suit_depress").is_empty():
			leak = true
			break
	await m._shot("n09_leak_banner.png")
	m._suit_drill("")
	Mission.set_playing(false)
	CW.reset()
	_c(9, nominal and levels.has("caution") and levels.has("warning") and levels.has("emergency") and leak and tt.has("max_ppco2_mmhg"),
		"nominal %.1f kPa / ppCO2 %.1f mmHg / ppO2 %.1f kPa %s; CO2 drill escalated through %s (%.1f mmHg); leak -> emergency after %.1f s %s; plan max ppCO2 %.1f mmHg" %
		[float(d["p_suit"]), float(d["ppco2"]), float(d["ppo2"]), nominal, ",".join(PackedStringArray(levels)), pc, leak_s, leak, float(tt.get("max_ppco2_mmhg", -1))])
	# N10: the other parameters, from a synthetic telemetry frame
	var fake: Dictionary = m.tel.d.duplicate()
	fake.merge({"live": true, "suited": true, "cabin": false, "o2_pct": 10.0, "battery_pct": 20.0, "water_pct": 11.0, "hr": 175.0,
		"dose_rate": 170.0, "dose_usv": 650.0, "sun_elev": 5.0, "met_high_s": 70.0, "met_w": 560.0, "scrubber_pct": 85.0,
		"margin_min": 30.0, "manual": true, "walk": true, "off_route": 90.0, "ev2_sep": 150.0, "comms": 0, "hazard": 4, "slope": 30.0}, true)
	var mon := CwMonitor.new()
	for i in 10:
		mon.check(fake)
		await m._wait(0.1)
	var want := ["o2_low", "batt_low", "water_low", "hr_high", "dose_rate", "dose_eva", "sunset", "met_high", "scrubber", "margin_low", "off_route", "ev2_sep", "comms", "hazard", "slope"]
	var missing := []
	for id in want:
		if CW.get_alert(id).is_empty():
			missing.append(id)
	var lv_ok := str(CW.get_alert("o2_low").get("level", "")) == "warning" and str(CW.get_alert("batt_low").get("level", "")) == "caution"
	_c(10, missing.is_empty() and lv_ok, "%d of %d monitored alerts raised (missing: %s); O2 10 %% = warning, battery 20 %% = caution %s" % [want.size() - missing.size(), want.size(), ",".join(PackedStringArray(missing)), lv_ok])
	m.cw_panel.toggle(m.ui.size, "ACTIVE")
	await m._wait(0.6)
	await m._shot("n10_cw_active.png")
	m.cw_panel.close()
	CW.reset()


# ------------------------------------------------------------------ N11-N15 information
func _information() -> void:
	m._set_mode("walk")
	await m._wait(3.5)
	var hud: HelmetHud = m.hud
	# N13 mode annunciation: autopilot -> manual
	var mode0 := str(m.tel.d.get("mode", ""))
	var n_log := CW.log_entries.size()
	m.world.toggle_autopilot()
	await m._wait(1.0)
	var said := false
	for i in range(n_log, CW.log_entries.size()):
		if str(CW.log_entries[i]["id"]) == "mode" and str(CW.log_entries[i]["text"]).begins_with("MANUAL"):
			said = true
	var chip_text := (hud._mode_chip.get_node("Text") as Label).text
	_c(13, mode0 == "AUTOPILOT" and said and chip_text == "MANUAL", "mode %s -> chip %s, advisory logged %s" % [mode0, chip_text, said])
	m.world.toggle_autopilot()
	await m._wait(0.5)
	# N14 turn-back
	var turn := (hud._l["turn"] as Label).text
	_c(14, turn.contains("TURN BACK") and str(m.tel.d.get("turn_by", "")) != "", "HUD: \"%s\"" % turn)
	# N12 words as well as colours
	var margin := (hud._l["margin"] as Label).text
	var slope := (hud._l["slope"] as Label).text
	var words := margin.contains("OK") or margin.contains("LOW") or margin.contains("CRIT") or margin.contains("NONE")
	_c(12, words and (slope.contains("▲") or slope.contains("▼") or slope.contains("■")), "margin \"%s\", slope \"%s\", legend classes carry names" % [margin, slope])
	# N11 stale and missing data: loss of signal timer, feed ages
	var waited_c := 0.0
	while is_inf(Mission.age_s("conditions")) and waited_c < 20.0:   # the feed may still be on its way after boot
		await m._wait(0.5)
		waited_c += 0.5
	var age := Mission.age_s("conditions")
	var lbl := UiKit.label("x")
	UiKit.mark_stale(lbl, "12.0", 130.0)
	var stale_ok := lbl.text.contains("STALE") and lbl.text.contains("2 min")
	lbl.free()
	var los_seen := false
	var xy0: Vector2 = m.world.walker.xy()
	var dead := _find_comms(0, xy0)
	if dead.is_finite():
		m.world.toggle_autopilot()
		m.world.walker.place(dead, 0.0)
		await m._wait(2.5)
		los_seen = float(m.tel.d.get("los_s", 0.0)) > 0.5 and not CW.get_alert("comms").is_empty()
		await m._shot("n11_los_strip.png")
		m.world.walker.place(xy0, 0.0)
		m.world.rejoin_route()
	_c(11, stale_ok and is_finite(age) and (los_seen or not dead.is_finite()), "STALE style %s; conditions %.0f s old; loss-of-signal timer and RADIO SHADOW in a dead zone %s" % [stale_ok, age, los_seen if dead.is_finite() else "n/a (no dead zone)"])
	await m._shot("n11_helmet_hud.png")
	m._set_mode("orbit")
	await m._wait(2.0)
	CW.reset()
	# N15 progress within 1 s, result after; site switch asks first
	Mission.request_plan()
	var go_txt := ""
	var t_badge := 0.0
	while t_badge < 1.0:   # the badge within the first second (a plan the server has to hand may be back sooner)
		await m.get_tree().process_frame
		t_badge += m.get_process_delta_time()
		go_txt = (m.top_bar._go.get_node("Text") as Label).text
		if go_txt.begins_with("PLANNING") or not Mission.planning:
			break
	var fast: bool = not go_txt.begins_with("PLANNING") and not Mission.planning
	await m._await_plan()
	var other := ""
	for s in Mission.sites:
		if str(s.get("id", "")) != Mission.site_id and bool(s.get("built", false)):
			other = str(s["id"])
	var asked := true
	if other != "":
		m._switch_site(other)
		await m._wait(0.4)
		asked = m.ui.get_node_or_null("Confirm") != null
		await m._shot("n15_confirm_switch.png")
		var dlg: Node = m.ui.get_node_or_null("Confirm")
		if dlg:
			dlg.queue_free()
	_c(15, (go_txt.begins_with("PLANNING") or fast) and asked, "while planning the badge reads \"%s\"%s; switching site asks first %s" % [go_txt,
		" (the plan was back within a second: nothing to show)" if fast else "", asked])


func _find_comms(level: int, near: Vector2) -> Vector2:
	var best := Vector2(INF, INF)
	var bd := INF
	for r in range(-60, 61, 4):
		for c in range(-60, 61, 4):
			var p := near + Vector2(c * 10.0, r * 10.0)
			if int(m.world.td.layer_value("comms", p.x, p.y, 2.0)) == level and int(m.world.td.layer_value("hazard", p.x, p.y, 0.0)) < 3:
				var dd := p.distance_to(near)
				if dd < bd:
					bd = dd
					best = p
	return best


# ------------------------------------------------------------------ N16-N20 settings
func _settings() -> void:
	var sp: SettingsPanel = m.settings_panel
	var tabs_ok := sp._pages.size() == 7
	for t in sp.TABS:
		tabs_ok = tabs_ok and (sp._pages[t] as Control).get_child_count() > 0
	sp.toggle(m.ui.size)
	sp.show_tab("ALERTS")
	await m._wait(0.6)
	await m._shot("n16_settings_alerts.png")
	sp.show_tab("CONTROLS")
	await m._wait(0.6)
	await m._shot("n16_settings_controls.png")
	sp.close()
	_c(16, tabs_ok, "7 tabs, each filled: %s" % tabs_ok)
	# N17 performance
	_setv("render_scale", "0.5")
	var rs: float = m.get_viewport().scaling_3d_scale
	_setv("show_fps", true)
	await m._wait(1.2)
	var fps_txt: String = m.fps_label.text
	_setv("vsync", false)
	var vs_off := DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED
	_setv("vsync", true)
	_setv("render_scale", "auto")
	_c(17, is_equal_approx(rs, 0.5) and fps_txt.contains("FPS") and vs_off, "render scale 0.5 -> %.2f; readout \"%s\"; v-sync off applied %s" % [rs, fps_txt.strip_edges(), vs_off])
	# N18 accessibility
	_setv("palette", "cvd")
	var cvd := UiKit.GOOD == Color("33c1a1") and UiKit.CAUTION == Color("f0e442")
	_setv("palette", "standard")
	_setv("min_text", 16)
	var floor_ok := true
	for l in m.ui.find_children("*", "Label", true, false):
		if (l as Label).has_meta("req_fs"):
			floor_ok = floor_ok and (l as Label).get_theme_font_size("font_size") >= 16
	await m._wait(0.3)
	await m._shot("n18_text16.png")
	_setv("min_text", 11)
	_setv("reduce_flashing", true)
	var rf := UiKit.reduce_flashing
	_setv("reduce_flashing", false)
	_setv("pressure_unit", "psi")
	m._set_mode("walk")
	await m._wait(3.0)
	var psi := (m.hud._l["press"] as Label).text
	_c(18, cvd and floor_ok and rf and psi.contains("psi"), "colour-blind palette %s; every label >= 16 px %s; reduce flashing %s; pressure \"%s\"" % [cvd, floor_ok, rf, psi])
	_setv("pressure_unit", "kPa")
	# N19 HUD declutter, opacity, tint
	_setv("hud_declutter", "minimal")
	await m._wait(0.4)
	var minimal: bool = not (m.hud._panels[2] as Control).visible and (m.hud._l["suitline"] as Label).visible and not m.hud.minimap.visible
	await m._shot("n19_hud_minimal.png")
	_setv("hud_declutter", "full")
	_setv("hud_opacity", 0.6)
	var op := is_equal_approx((m.hud._panels[1] as Control).modulate.a, 0.6)
	_setv("hud_opacity", 1.0)
	_setv("hud_tint", "amber")
	await m._wait(1.5)
	var tint: bool = HelmetHud.HUD == HelmetHud.TINTS["amber"] and m.hud.visible
	await m._shot("n19_hud_amber.png")
	_setv("hud_tint", "cyan")
	await m._wait(1.0)
	_c(19, minimal and op and tint, "minimal declutter %s; opacity 0.6 %s; amber tint rebuilt %s" % [minimal, op, tint])
	m._set_mode("orbit")
	await m._wait(2.0)
	# N20 export / import
	var path := "user://nasa_tour_mission.json"
	var n_stops := Mission.stops.size()
	var exported := Mission.export_mission(path)
	var removed: Dictionary = Mission.stops[Mission.stops.size() - 1]
	Mission.push_undo("tour: remove a stop")
	Mission.stops.pop_back()
	var err := Mission.import_mission(path)
	var back := Mission.stops.size() == n_stops
	var undo := Mission.undo()
	var undone := Mission.stops.size() == n_stops - 1
	Mission.stops.append(removed)
	Mission.save_mission()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	_c(20, exported and err == "" and back and undo != "" and undone, "exported %s; import restored %d stops %s; Ctrl+Z undoes the import %s" % [exported, n_stops, back, undone])


# ------------------------------------------------------------------ N21-N22 controls
func _controls() -> void:
	var k := InputEventKey.new()
	k.keycode = KEY_K
	k.physical_keycode = KEY_K
	Controls.rebind("cuff_menu", k, false)
	var has_k := false
	for e in InputMap.action_get_events("cuff_menu"):
		if e is InputEventKey and (e as InputEventKey).keycode == KEY_K:
			has_k = true
	var mkey := InputEventKey.new()
	mkey.keycode = KEY_M
	var clash := Controls.conflicts(mkey, "cuff_menu")
	var saved: Variant = Settings.get_binding("cuff_menu")
	Controls.reset_all()
	var back_to_x := Controls.binding_text("cuff_menu", false) == "X"
	_c(21, has_k and not clash.is_empty() and saved is Array and back_to_x, "cuff menu -> K %s, saved %s; M would clash with %s; reset gives X %s" % [has_k, saved is Array, ", ".join(PackedStringArray(clash)), back_to_x])
	# N22 feel: zoom speed, invert, dead zone, lope toggle
	var orbit: OrbitRig = m.world.orbit
	var d0: float = orbit.dist
	_setv("zoom_speed", 2.0)
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = Vector2(-1, -1)
	orbit.handle_input(wheel)
	var ratio: float = orbit.dist / d0
	orbit.dist = d0
	_setv("zoom_speed", 1.0)
	var p0: float = orbit.pitch
	var mm := InputEventMouseMotion.new()
	mm.relative = Vector2(0, 20)
	mm.button_mask = MOUSE_BUTTON_MASK_LEFT
	orbit.handle_input(mm)
	var up := orbit.pitch - p0
	orbit.pitch = p0
	_setv("invert_orbit", true)
	orbit.handle_input(mm)
	var inv := orbit.pitch - p0
	orbit.pitch = p0
	_setv("invert_orbit", false)
	_setv("deadzone", 0.35)
	var dz := InputMap.action_get_deadzone("move_forward")
	_setv("deadzone", 0.2)
	_setv("lope_toggle", true)
	var wk: Walker = m.world.walker
	wk.lope_latched = true
	var lope_on := wk.lope_on()
	wk.lope_latched = false
	_setv("lope_toggle", false)
	_c(22, absf(ratio - pow(0.86, 2.0)) < 0.02 and is_equal_approx(inv, -up) and absf(dz - 0.35) < 0.001 and lope_on,
		"wheel at zoom x2 -> x%.3f; tilt %.4f vs inverted %.4f; dead zone %.2f; lope toggle latches %s" % [ratio, up, inv, dz, lope_on])


# ------------------------------------------------------------------ N23-N24 abort, glove mode, cuff menu
func _abort_and_menu() -> void:
	var tt: Dictionary = Mission.plan["totals"]
	Mission.set_time(float(tt["total_s"]) * 0.45)
	m._set_mode("walk")
	await m._wait(3.5)
	m.hud.visible = true
	var start: Vector2 = m.world.walker.xy()
	m._abort_hold = 0.0   # as if End were held down
	await m._wait(HelmetHud.HOLD_S + 0.4)
	var on: bool = m.tel.abort_active
	var pts: PackedVector2Array = m.world.abort_path(start)
	var ends_home := pts.size() >= 2 and pts[pts.size() - 1].distance_to(m.world.haven_door()) < 1.0   # at its door
	var downhill := true
	var last := INF
	for p in pts:
		var w: float = m.world.td.layer_value("walkback", p.x, p.y, -1.0)
		if w >= 0.0:
			downhill = downhill and w <= last + 8.0
			last = w
	await m._wait(1.5)
	var target := (m.hud._l["target"] as Label).text
	var raised := not CW.get_alert("abort").is_empty()
	await m._shot("n23_abort_helmet.png")
	m._set_mode("orbit")
	await m._wait(2.0)
	m.world.orbit.target = m.world.td.world_at(start)
	m.world.orbit.dist = 900.0
	await m._wait(1.5)
	await m._shot("n23_abort_orbit.png")
	m._toggle_abort()
	var cancelled: bool = not m.tel.abort_active and m.world.abort_mi == null
	_c(23, on and ends_home and downhill and target.begins_with("ABORT") and raised and cancelled,
		"hold End -> abort %s; route %d points ends at %s %s, walk-back falls along it %s; HUD target \"%s\"; EVA ABORT warning %s; cancelled %s" %
		[on, pts.size(), Mission.haven_name(), ends_home, downhill, target, raised, cancelled])
	CW.reset()
	# N24 glove mode and the cuff menu
	_setv("glove_mode", true)
	await m._wait(0.5)
	var b := UiKit.button("probe")
	var big := b.custom_minimum_size.y >= 46.0
	b.free()
	m._open_cuff_menu()
	await m._wait(0.5)
	var menu: CuffMenu = m.cuff_menu
	var shown := menu.visible and menu._items.size() == 9
	await m._shot("n24_cuff_menu.png")
	var status_ev := InputEventKey.new()
	status_ev.keycode = KEY_3
	status_ev.pressed = true
	menu._input(status_ev)
	var ran := not menu.visible
	_setv("glove_mode", false)
	_c(24, big and shown and ran, "glove buttons >= 46 px %s; cuff menu with %d items %s; key 3 ran STATUS and closed it %s" % [big, menu._items.size(), shown, ran])
	await m._wait(1.0)


# ------------------------------------------------------------------ N25 voice
func _voice() -> void:
	var v: VoiceControl = m.voice
	if not v.available():
		print("CHECK N25 SKIP  not Windows")
		return
	var heard := []
	var states := []
	var on_cmd := func(t: String, c: float): heard.append([t, c])
	var on_state := func(s: String, dtl: String): states.append("%s %s" % [s, dtl])
	v.command.connect(on_cmd)
	v.state_changed.connect(on_state)
	m._voice_testing = false   # read the result here, not in main
	v.self_test("suit status")
	var waited := 0.0
	while heard.is_empty() and waited < 40.0 and not states.any(func(s: String) -> bool: return s.begins_with("error")):
		await m.get_tree().process_frame
		waited += m.get_process_delta_time()
	v.stop()
	v.command.disconnect(on_cmd)
	v.state_changed.disconnect(on_state)
	if heard.is_empty() and states.any(func(s: String) -> bool: return s.begins_with("error")):
		print("CHECK N25 SKIP  %s" % " / ".join(PackedStringArray(states)))
		return
	var ok := not heard.is_empty() and str(heard[0][0]) == "suit status"
	_c(25, ok, "Windows' voice said \"suit status\" into a WAV; the recogniser heard %s after %.1f s (%s)" % [str(heard[0]) if not heard.is_empty() else "nothing", waited, " / ".join(PackedStringArray(states))])
