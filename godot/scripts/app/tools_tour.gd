class_name ToolsTour
extends RefCounted
## Checks for the helmet tools (HelmetTools), run with
##   godot --path . --resolution 1600x900 -- --capture=<dir> --tour=tools --mute [--site=jezero_threeforks]
## Prints CHECK Tn PASS/FAIL lines and saves t01-t07 screenshots; the view, time and tools are put back.

var m   # main.gd
var _pass := 0
var _fail := 0


func _init(main_node) -> void:
	m = main_node


func _check(id: String, ok: bool, what: String) -> void:
	print("CHECK %s %s  %s" % [id, "PASS" if ok else "FAIL", what])
	if ok:
		_pass += 1
	else:
		_fail += 1


## A time a quarter of the way into the first walking leg.
func _walk_time() -> float:
	for e in Mission.plan["events"]:
		if str(e["kind"]) == "walk":
			return float(e["t0"]) + (float(e["t1"]) - float(e["t0"])) * 0.3
	return 0.0


func _place_on_route(d: float, look_ahead := 12.0) -> void:
	var w: MarsWorld = m.world
	var p: Vector2 = Mission.route_xy(d)
	var q: Vector2 = Mission.route_xy(d + look_ahead)
	w.walker.place(p, rad_to_deg(atan2(q.x - p.x, q.y - p.y)))


func run() -> void:
	var boot := 0.0
	while not Mission.has_plan() and boot < 240.0:
		await m._wait(0.5)
		boot += 0.5
	await m._await_plan()
	await m._wait(1.0)
	var w: MarsWorld = m.world
	var tools: HelmetTools = m.tools
	var t0 := Mission.eva_t
	Mission.set_playing(false)
	var tw := _walk_time()
	Mission.set_time(tw)
	m._set_mode("walk")
	await m._wait(2.5)
	w.walker.autopilot = false
	var d0 := float(Mission.state_at(tw)["d"])
	_place_on_route(d0)
	w.walker.pitch = -0.12
	await m._wait(1.5)
	await m._shot("t01_helmet.png")

	# G6 white balance
	tools.set_earth_light(true)
	await m._wait(0.6)
	await m._shot("t02_earth_light.png")
	var wb: Variant = w.terrain_mesh.material.get_shader_parameter("wb_gain")
	_check("T1", wb is Vector3 and (wb as Vector3).is_equal_approx(HelmetTools.WB_EARTH), "white balance gains on the terrain (%s)" % str(wb))
	tools.set_earth_light(false)

	# B6 synthetic vision and snow poles
	tools.set_synthetic(true)
	await m._wait(1.2)
	await m._shot("t03_synthetic_vision.png")
	var poles: MultiMeshInstance3D = w.get_node_or_null("SnowPoles")
	var n_poles := poles.multimesh.instance_count if poles else 0
	var want := int(float(Mission.plan["totals"]["dist_m"]) / HelmetTools.POLE_EVERY) + 1
	_check("T2", n_poles == want and w._param("contour_strength") > 0.9 and w._param("contour_interval") < 1.5,
		"%d snow poles (want %d), contours %.2f at %.1f m" % [n_poles, want, w._param("contour_strength"), w._param("contour_interval")])
	tools.set_synthetic(false)
	await m._wait(0.8)

	# A7 data flashlight (picks the THEMIS night IR layer when none is draped)
	tools.set_flashlight(true)
	var waited := 0.0
	while w._param("overlay_opacity") < 0.05 and waited < 30.0:
		await m._wait(0.5)
		waited += 0.5
	await m._wait(1.5)
	await m._shot("t04_data_flashlight.png")
	_check("T3", tools.flashlight_on and absf(w._param("overlay_reveal") - HelmetTools.FLASH_R) < 0.01 and w._param("overlay_edge") < 3.0
		and tools.look != Vector2.INF, "flashlight: reveal %.1f m around the look point %s" % [w._param("overlay_reveal"), str(tools.look)])
	tools.set_flashlight(false)
	m._flashlight_layer("")   # nothing draped again (an unknown id is ignored)
	m._on_overlay({"id": ""})

	# A6 ghost pacer: the clock runs in real time, the ghost walks the plan, the HUD says ahead or behind
	Mission.set_time(tw)
	_place_on_route(d0)
	tools.set_ghost(true)
	await m._wait(4.0)
	await m._shot("t05_ghost_pacer.png")
	var ghost: Node3D = w.get_node_or_null("GhostPacer")
	_check("T4", ghost != null and ghost.visible and Mission.playing and Mission.play_speed() == 1.0 and is_finite(tools.pace_s),
		"ghost visible, clock at x%.0f, pace %.1f s" % [Mission.play_speed(), tools.pace_s])
	var gd := float(Mission.state_at(Mission.eva_t)["d"])
	_place_on_route(gd + 30.0)
	await m._wait(0.6)
	var ahead := tools.pace_s
	_place_on_route(maxf(gd - 30.0, 0.0))
	await m._wait(0.6)
	var behind := tools.pace_s
	_check("T5", ahead > 10.0 and behind < -10.0, "30 m ahead reads %+.0f s, 30 m behind reads %+.0f s" % [ahead, behind])
	tools.set_ghost(false)
	Mission.set_playing(false)

	# D3 co-driver: 50 m before a note the HUD says what comes
	var target := {}
	for n in tools._notes:
		if float(n["d"]) > 80.0:
			target = n
			break
	if not target.is_empty():
		var want_d := float(target["d"]) - 50.0
		var pt: Array = Mission.plan["profile"]["t"]
		var pdd: Array = Mission.plan["profile"]["d"]
		var t_at := tw
		for k in pdd.size():   # the clock where the plan stands at that point, so the walker is "on time" there
			if float(pdd[k]) >= want_d:
				t_at = float(pt[k])
				break
		Mission.set_time(t_at)
		_place_on_route(want_d)
		await m._wait(0.8)
		var hud_note := str((m.hud._l["note"] as Label).text)
		await m._shot("t06_codriver_note.png")
		_check("T6", tools.note.begins_with("IN ") and hud_note.begins_with("▸ "), "note: %s" % tools.note)
	else:
		_check("T6", false, "no pace note beyond 80 m on this plan")

	# F1 hear the map: the science grid is loaded for the detector chirp
	_check("T7", w.td.has_layer("science"), "science grid for the detector chirp")
	# E4 the sound of Jezero: the recording is in the project and plays at Jezero (silent under --mute)
	_check("T8", ResourceLoader.exists(HelmetTools.JEZERO_WIND), "Perseverance's wind recording is imported")

	# B2 HUD-failure drill: the displays go dark and the card says how to walk home
	Mission.set_time(tw)
	_place_on_route(float(Mission.plan["totals"]["dist_m"]) * 0.3)
	await m._wait(0.8)
	var lit_before := 0
	for b in w.stop_nodes.values():
		lit_before += 1 if (b as Node3D).visible else 0
	tools.toggle_drill()
	var waited_card := 0.0
	while tools.drill_on and tools._card_text != null and not tools._card_text.text.contains("square") and waited_card < 30.0:
		await m._wait(0.5)
		waited_card += 0.5
	await m._wait(0.8)
	var card_txt: String = tools._card_text.text if tools._card_text != null else ""
	await m._shot("t07_hud_failure_card.png")
	var beacons_dark := true
	for b in w.stop_nodes.values():
		beacons_dark = beacons_dark and not (b as Node3D).visible
	_check("T9", tools.drill_on and not m.hud.visible and (w.route_mi == null or not w.route_mi.visible) and beacons_dark
		and card_txt.contains("Heading") and card_txt.contains("paces") and card_txt.contains("square"),
		"drill: HUD and beacons dark, card: %s" % card_txt.replace("\n", " | "))

	# B1 skyline fix on the way (counts against the drill score)
	tools.last_fix = {}
	tools.skyline_fix()
	var waited_fix := 0.0
	while tools.last_fix.is_empty() and waited_fix < 60.0:
		await m._wait(0.5)
		waited_fix += 0.5
	await m._wait(0.8)
	await m._shot("t08_skyline_fix.png")
	var fix_err := INF
	if not tools.last_fix.is_empty():
		fix_err = (tools.last_fix["xy"] as Vector2).distance_to(w.walker.xy())
	var r95 := float(tools.last_fix.get("r95", 0.0))
	_check("T10", fix_err < maxf(2.0 * r95, 80.0) and int(tools._drill.get("fixes", 0)) == 1,
		"skyline fix %.0f m from the walker (95 %% circle %.0f m), square %s" % [fix_err, r95, str(tools.last_fix.get("sq", "?"))])

	# walk home to the door in 20 m steps: the drill ends there and scores the walk
	var door: Vector2 = w.haven_door()
	var start: Vector2 = w.walker.xy()
	var steps := maxi(1, int(ceil(start.distance_to(door) / 20.0)))
	for k in range(1, steps + 1):
		var p := start.lerp(door, float(k) / float(steps))
		w.walker.place(p, rad_to_deg(atan2(door.x - p.x, door.y - p.y)))
		await m._wait(0.06)
	await m._wait(0.8)
	await m._shot("t09_drill_scored.png")
	var lit_after := 0
	for b in w.stop_nodes.values():
		lit_after += 1 if (b as Node3D).visible else 0
	_check("T11", not tools.drill_on and tools.last_score > 0 and m.hud.visible and lit_after == lit_before,
		"home by the card: score %d, %d of %d beacons back" % [tools.last_score, lit_after, lit_before])

	await _lake_checks()

	# put things back
	m._set_mode("orbit")
	Mission.set_time(t0)
	await m._wait(1.5)
	print("tools tour: %d passed, %d failed" % [_pass, _fail])


## Only the lake checks (--tour=lake).
func run_lake() -> void:
	var boot := 0.0
	while not Mission.has_plan() and boot < 240.0:
		await m._wait(0.5)
		boot += 0.5
	await m._await_plan()
	await m._wait(1.0)
	Mission.set_playing(false)
	await _lake_checks()
	m._set_mode("orbit")
	await m._wait(1.0)
	print("lake tour: %d passed, %d failed" % [_pass, _fail])


## D1 (--tour=live): the helmet streams its state to the habitat console's relay, and a waypoint and a message
## pushed from the habitat reach the visor.
func run_live() -> void:
	var boot := 0.0
	while not Mission.has_plan() and boot < 240.0:
		await m._wait(0.5)
		boot += 0.5
	await m._await_plan()
	var w: MarsWorld = m.world
	var lv: LiveLink = m.live
	m._set_mode("walk")
	await m._wait(1.5)
	w.walker.autopilot = false
	_place_on_route(220.0)   # out of the airlock, where a beacon 170 m off can be seen
	await m._wait(1.0)
	var waited := 0.0
	while not lv.connected and waited < 30.0:
		await m._wait(0.5)
		waited += 0.5
	await m._wait(1.5)
	var st: Dictionary = await Api.get_json("/api/live/%s" % Mission.site_id, 10.0)
	var data: Dictionary = st["data"] if st["ok"] and st["data"] is Dictionary else {}
	var last: Dictionary = data.get("last", {}) if data.get("last") is Dictionary else {}
	var clients: Dictionary = data.get("clients", {}) if data.get("clients") is Dictionary else {}
	var ll_me := Mission.grid.to_lonlat(w.walker.xy().x, w.walker.xy().y)
	var off_m := Mission.xy_of(float(last.get("lon", 0.0)), float(last.get("lat", 0.0))).distance_to(w.walker.xy())
	_check("T18", lv.connected and lv.sent > 0 and str(last.get("source", "")) == "helmet" and int(clients.get("helmet", 0)) >= 1 and off_m < 25.0
		and last.has("o2_pct") and last.has("heading"), "relay has the helmet: %d sent, last fix %.1f m from EV1 (%.5f, %.5f), O2 %s %%, mode %s" % [
		lv.sent, off_m, ll_me.y, ll_me.x, str(last.get("o2_pct", "?")), str(last.get("mode", "?"))])
	var p := w.walker.xy() + Vector2(140.0, 90.0)
	var ll := Mission.grid.to_lonlat(p.x, p.y)
	var r0 := lv.received
	await Api.post_json("/api/live/%s/command" % Mission.site_id, {"type": "waypoint", "lon": ll.x, "lat": ll.y, "name": "Sample cache"}, 10.0)
	await Api.post_json("/api/live/%s/command" % Mission.site_id, {"type": "message", "text": "Dust rising to the west, head for the cache"}, 10.0)
	waited = 0.0
	while lv.received < r0 + 2 and waited < 10.0:
		await m._wait(0.25)
		waited += 0.25
	w.walker.pitch = -0.02
	w.walker.place(w.walker.xy(), rad_to_deg(atan2(p.x - w.walker.xy().x, p.y - w.walker.xy().y)))
	await m._wait(1.2)
	await m._shot("t15_habitat_waypoint.png")
	_check("T19", lv.received >= r0 + 2 and str(lv.waypoint.get("name", "")) == "Sample cache" and lv._beacon != null and lv._beacon.visible
		and lv.last_message.begins_with("Dust"), "from the habitat: waypoint %s at %.0f m, message \"%s\"" % [
		str(lv.waypoint.get("name", "")), (lv.waypoint.get("xy", p) as Vector2).distance_to(w.walker.xy()), lv.last_message])
	await Api.post_json("/api/live/%s/command" % Mission.site_id, {"type": "clear_waypoint"}, 10.0)
	waited = 0.0
	while lv.waypoint.size() > 0 and waited < 10.0:
		await m._wait(0.25)
		waited += 0.25
	_check("T20", lv.waypoint.is_empty() and not lv._beacon.visible, "the habitat cleared it")
	m._set_mode("orbit")
	await m._wait(1.0)
	print("live tour: %d passed, %d failed" % [_pass, _fail])


## Only the layer tower (--tour=tower): the sheets lift into a stack, hold, and settle back.
func run_tower() -> void:
	var boot := 0.0
	while not Mission.has_plan() and boot < 240.0:
		await m._wait(0.5)
		boot += 0.5
	await m._await_plan()
	await m._wait(1.0)
	Mission.set_playing(false)
	var tw: LayerTower = m.tower
	var t_pre := Time.get_ticks_msec()
	var waited := 0.0
	while not tw.load_sheets_ready() and waited < 400.0:   # the console composes them in the background
		await m._wait(0.5)
		waited += 0.5
	var pre_s := (Time.get_ticks_msec() - t_pre) / 1000.0
	var t0 := Time.get_ticks_msec()
	m.play_tower(4.0)
	waited = 0.0
	while not (tw.running and tw.visible) and waited < 60.0:
		await m._wait(0.25)
		waited += 0.25
	var load_s := (Time.get_ticks_msec() - t0) / 1000.0
	await m._wait(tw.sheets.size() * LayerTower.STAGGER_S + LayerTower.RISE_S + 1.0)
	await m._shot("t13_tower.png")
	var n := tw.sheets.size()
	var ids := PackedStringArray()
	for s in tw.sheets:
		ids.append(str(s["id"]))
	var top_y := float((tw.sheets[n - 1]["node"] as Node3D).position.y) if n > 0 else NAN
	_check("T16", tw.running and n >= 6 and absf(top_y - (tw._base_y + (n - 1) * tw._gap)) < 1.0 and load_s < 5.0,
		"%d sheets up (%s), %.0f m apart; preloaded %.0f s after the plan, shown %.1f s after TOWER" % [n, ", ".join(ids), tw._gap, pre_s, load_s])
	await m._wait(2.5)
	await m._shot("t14_tower_turned.png")
	waited = 0.0
	while tw.running and waited < 30.0:
		await m._wait(0.25)
		waited += 0.25
	_check("T17", not tw.running and not tw.visible, "the sheets settled back into the terrain")
	print("tower tour: %d passed, %d failed" % [_pass, _fail])


## A4 flood the crater: the water rises to the first level; the lake bed and the helmet readout follow it.
func _lake_checks() -> void:
	var w: MarsWorld = m.world
	var lk: LakeWater = m.lake
	m._set_mode("orbit")
	await m._wait(1.0)
	lk.cycle()
	var waited_lake := 0.0
	while not lk.on and waited_lake < 30.0:
		await m._wait(0.5)
		waited_lake += 0.5
	w.orbit.fly_to(w.td.world_at(Mission.hab_xy()), 7000.0, w.orbit.yaw, deg_to_rad(30.0), 0.05)
	await m._wait(LakeWater.RISE_S + 1.0)
	var lake_y := w._param("lake_y")
	var want_y := lk.level - w.td.elev_ref
	await m._shot("t10_lake_orbit.png")
	w.orbit.fly_to(w.td.world_at(Mission.hab_xy()), 4200.0, w.orbit.yaw, deg_to_rad(88.0), 0.05)
	await m._wait(2.0)
	await m._shot("t10b_lake_top.png")
	_check("T12", lk.on and absf(lake_y - want_y) < 0.05 and lk._plane != null and lk._plane.visible,
		"lake at %s m (%s): surface y %.1f (want %.1f), %d %% of the site under water" % [LakeWater.fmt_elev(lk.level), lk.level_name,
		lake_y, want_y, int(round(100.0 * float(lk.stats.get("share_under", 0.0))))])
	m._set_mode("walk")
	await m._wait(1.5)
	w.walker.autopilot = false
	w.walker.place(w.haven_door(), 200.0)
	await m._wait(2.5)
	await m._shot("t11_lake_helmet.png")
	_check("T13", is_finite(lk.depth_here) and lk.depth_here > 0.0 and lk.under > 0.5 and lk._banner.visible
		and lk._b_text.text.contains("over you"), "helmet at the door: %.1f m of water over the walker, tint %.2f, banner: %s" % [
		lk.depth_here, lk.under, lk._b_text.text])
	# on the shore: a point a few metres above the water, looking downhill over the lake
	var shore := Vector2.INF
	var hab0 := Mission.hab_xy()
	for ring in range(1, 40):
		for k in 24:
			var p := hab0 + Vector2.from_angle(TAU * k / 24.0) * ring * 30.0
			var above := w.td.height_abs(p.x, p.y) - lk.level
			if above > 1.5 and above < 5.0:
				shore = p
				break
		if shore != Vector2.INF:
			break
	if shore != Vector2.INF:
		var e := 6.0
		var grad := Vector2(w.td.height_abs(shore.x + e, shore.y) - w.td.height_abs(shore.x - e, shore.y),
			w.td.height_abs(shore.x, shore.y + e) - w.td.height_abs(shore.x, shore.y - e))
		var down := -grad.normalized() if grad.length() > 0.01 else Vector2(0, 1)
		w.walker.place(shore - down * 6.0, rad_to_deg(atan2(down.x, down.y)))
		w.walker.pitch = -0.04
		await m._wait(2.5)
		await m._shot("t12_lake_shore.png")
		_check("T15", is_finite(lk.depth_here) and lk.depth_here < 0.0 and lk.under < 0.5 and lk._b_text.text.contains("above the shore"),
			"on the shore %.1f m above the water: %s" % [-lk.depth_here, lk._b_text.text])
	else:
		_check("T15", false, "no shore point within 1.2 km of the habitat")
	lk.set_off(true)
	await m._wait(0.5)
	_check("T14", not lk.on and w._param("lake_y") < -1.0e8 and not lk._plane.visible and not lk._banner.visible, "the lake is gone again")
