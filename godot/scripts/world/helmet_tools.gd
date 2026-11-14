class_name HelmetTools
extends Node
## Helmet tools from the idea list, kept out of main.gd:
##   A6 ghost pacer (K)          a translucent EV walks the plan at the planned pace; the HUD says ahead or behind
##   A7 data flashlight (O)      the draped layer only inside a circle where you look, like a torch of data
##   B6 synthetic vision (N)     1 m contour lines and virtual 2 m snow poles every 50 m along the route
##   G6 white balance (B)        the ground and the sky in Earth-like light, so rock colours read as at home
##   C2 crew tags (T, Shift+T)   tag a hazard or a find where you look; a hazard re-plans the route
##   D3 co-driver                the next pace note on the HUD, read aloud once as you near it
##   E4 the sound of Jezero      at Jezero the ambience is the wind Perseverance recorded on sol 4
##   F1 hear the map             Geiger clicks from the dose rate, a detector chirp over high science ground

const WB_EARTH := Vector3(0.82, 1.05, 1.40)   # the same von Kries gains as the web planner
const FLASH_R := 9.0
const POLE_EVERY := 50.0
const FLASH_LAYER := "thermal"
const JEZERO_WIND := "res://audio/jezero_wind_sol004.mp3"

var world: MarsWorld
var toast: Callable = func(_t: String, _k: String) -> void: pass
var pick_layer: Callable = func(_id: String) -> void: pass
var ghost_on := false
var flashlight_on := false
var synthetic_on := false
var earth_light := false
var hear_on := true
var pace_s := NAN                # + ahead of the ghost, - behind (s)
var note := ""                   # the next pace note, for the HUD
var along := NAN                 # metres along the route where the walker is (the cuff strip map)
var look := Vector2.INF          # site xy where EV1 looks

var _ghost: Node3D
var _ghost_phase := 0.0
var _poles: MultiMeshInstance3D
var _route := PackedVector2Array()
var _route_d := PackedFloat64Array()
var _notes: Array = []           # [{d: absolute metres along the route, text}]
var _spoken := {}
var _speed := 1.0                # planned walking speed, m/s
var _jezero: AudioStreamPlayer
var _jezero_told := false
var _click_acc := 0.0
var _chirp_t := 0.0
var _acc := 0.0


func setup(w: MarsWorld, toast_cb: Callable, pick_layer_cb: Callable) -> void:
	world = w
	toast = toast_cb
	pick_layer = pick_layer_cb
	Mission.plan_changed.connect(_on_plan)
	Mission.site_loaded.connect(_on_site)
	world.mode_changed.connect(_on_mode)
	if Mission.has_plan():
		_on_plan()


# ------------------------------------------------------------------ switches
func set_ghost(on: bool) -> void:
	ghost_on = on and Mission.has_plan()
	world.keep_clock = ghost_on
	if ghost_on and _ghost == null:
		_ghost = Models.astronaut(Color("7fe8ff"))
		_ghost.name = "GhostPacer"
		var m := ShaderMaterial.new()
		m.shader = load("res://shaders/hologram.gdshader")
		m.set_shader_parameter("color", Color(0.55, 0.9, 1.0, 1.0))
		m.set_shader_parameter("intensity", 0.6)
		_material_all(_ghost, m)
		world.add_child(_ghost)
	if _ghost:
		_ghost.visible = ghost_on
	pace_s = NAN
	if ghost_on and world.mode == "walk":
		Mission.speed_index = 0          # real time: you race the plan at its own pace
		Mission.set_playing(true)
	if on and not Mission.has_plan():
		toast.call("Ghost pacer: plan an EVA first", "info")
	elif ghost_on:
		toast.call("Ghost pacer on: it walks the plan in real time. Ahead of it you are early; behind it, late.", "info")
	elif on == false:
		toast.call("Ghost pacer off", "info")


func set_flashlight(on: bool) -> void:
	var tm := world.terrain_mesh
	if on and world._param("overlay_opacity") < 0.05:
		pick_layer.call(FLASH_LAYER)   # no layer draped yet: light up the THEMIS night infrared
	flashlight_on = on
	if on:
		tm.set_param("overlay_edge", 2.5)
		toast.call("Data flashlight: the draped layer shows only where you look", "info")
	else:
		tm.set_param("overlay_edge", 35.0)
		tm.set_param("overlay_reveal", 1.0e9)


func set_synthetic(on: bool) -> void:
	synthetic_on = on
	world.set_contours(on)
	world.terrain_mesh.set_param("contour_interval", 1.0 if on else 5.0)
	world.terrain_mesh.set_param("contour_glow", 0.7 if on else 0.0)
	if on:
		_build_poles()
		toast.call("Synthetic vision: 1 m contours and a 2 m pole every 50 m along the route", "info")
	elif _poles:
		_poles.visible = false


func set_earth_light(on: bool) -> void:
	earth_light = on
	world.terrain_mesh.set_param("wb_gain", WB_EARTH if on else Vector3.ONE)
	if world.sky_mat:
		world.sky_mat.set_shader_parameter("wb_gain", WB_EARTH if on else Vector3.ONE)
	toast.call("Earth light: rock colours as they would look at home" if on else "Mars light", "info")


## Tag the ground where EV1 looks (feature C2). A hazard closes a small disc of ground and the route is planned again.
func tag(kind: String) -> void:
	var p := _look_point()
	if p == Vector2.INF:
		toast.call("Look at the ground to tag it", "info")
		return
	var ll := Mission.grid.to_lonlat(p.x, p.y)
	var dist := p.distance_to(world.walker.xy())
	var r := await Api.post_json("/api/sites/%s/tags" % Mission.site_id,
		{"kind": kind, "lon": ll.x, "lat": ll.y, "by": "EV1", "note": "Tagged from the helmet"}, 20.0)
	if not r["ok"]:
		toast.call("Tag not saved: %s" % str(r.get("error", "no answer")), "bad")
		return
	world.scan_pulse(p)
	Sfx.play("confirm", -8.0)
	if kind == "hazard":
		toast.call("Hazard tagged %d m away: re-planning around it" % int(dist), "warn")
		Mission.request_plan()
	else:
		toast.call("Find tagged %d m away: a candidate stop for the next EVA" % int(dist), "ok")


# ------------------------------------------------------------------ per frame
func _process(delta: float) -> void:
	if world == null or not world.ready_terrain:
		return
	var walk := world.mode == "walk"
	if flashlight_on:
		if walk:
			var p := _look_point()
			if p != Vector2.INF:
				world.terrain_mesh.set_param("overlay_origin", p)
				world.terrain_mesh.set_param("overlay_reveal", FLASH_R)
		else:
			set_flashlight(false)
	if ghost_on and _ghost and Mission.has_plan():
		_update_ghost(delta, walk)
	if walk and hear_on:
		_hear(delta)
	if drill_on:
		if walk:
			_update_drill()
		else:
			_end_drill(false)
	_acc += delta
	if _acc < 0.25:
		return
	_acc = 0.0
	if walk and Mission.has_plan():
		_update_note()
	else:
		note = ""
		along = NAN


func _update_ghost(delta: float, walk: bool) -> void:
	var st := Mission.state_at(Mission.eva_t)
	var ph := str(st.get("phase", ""))
	var show := walk and (ph == "walk" or ph == "stop") and not bool(st.get("in_cabin", false))
	_ghost.visible = show
	if not show:
		pace_s = NAN
		return
	var d := float(st["d"])
	var q := Mission.route_xy(d)
	var q2 := Mission.route_xy(d + 3.0)
	_ghost.position = world.td.world_at(q)
	if q2.distance_to(q) > 0.2:
		_ghost.rotation.y = -atan2(q2.x - q.x, q2.y - q.y)
	var moving := ph == "walk" and Mission.playing
	if moving:
		_ghost_phase += delta * 3.2 * clampf(Mission.play_speed(), 1.0, 3.0)
	Models.animate_astronaut(_ghost, _ghost_phase, 1.0 if moving else 0.0)
	var me := _route_distance(world.walker.xy(), d)
	pace_s = (me - d) / _speed if is_finite(me) else NAN


func _update_note() -> void:
	var st := Mission.state_at(Mission.eva_t)
	var me := _route_distance(world.walker.xy(), float(st["d"]))
	along = me
	if not is_finite(me) or _notes.is_empty():
		note = ""
		return
	var txt := ""
	for n in _notes:
		var ahead := float(n["d"]) - me
		if ahead < -6.0:
			continue
		if ahead > 120.0:
			break
		txt = ("NOW · %s" % str(n["text"])) if ahead < 8.0 else ("IN %d m · %s" % [int(round(ahead / 5.0) * 5.0), str(n["text"])])
		var key := str(n["d"])
		if ahead < 40.0 and not _spoken.has(key):
			_spoken[key] = true
			CW.say(str(n["text"]))   # the co-driver: each note read aloud once
		break
	note = txt


## The co-driver's notes on the whole route ({d, text}, sorted by d), for the cuff strip map.
func notes() -> Array:
	return _notes


## F1: Geiger clicks follow the dose rate; over high science ground a detector chirps, faster as it rises.
func _hear(delta: float) -> void:
	var tel_rate := 0.0
	var main_tel: Variant = get_parent().get("tel") if get_parent() else null
	if main_tel != null and main_tel.d is Dictionary and (main_tel.d as Dictionary).has("dose_rate"):
		tel_rate = float(main_tel.d["dose_rate"])
	var cps := clampf(tel_rate / 12.0, 0.15, 30.0)   # ~1-2 clicks a second in normal GCR, a rattle in a storm
	_click_acc += delta * cps
	while _click_acc >= 1.0:
		_click_acc -= randf_range(0.6, 1.4)
		Sfx.play("type", -30.0 + minf(cps, 10.0), randf_range(1.7, 2.6))
	var xy := world.walker.xy()
	var sci := world.td.layer_value("science", xy.x, xy.y, -1.0)
	if sci < 0.0:
		return
	var s := sci / 255.0
	if s < 0.35:
		_chirp_t = 0.0
		return
	_chirp_t -= delta
	if _chirp_t <= 0.0:
		_chirp_t = lerpf(1.3, 0.25, clampf((s - 0.35) / 0.5, 0.0, 1.0))
		Sfx.play("hover", -20.0, 0.8 + 1.4 * s)


# ------------------------------------------------------------------ plan, site, mode
func _on_plan() -> void:
	_route = PackedVector2Array()
	_route_d = PackedFloat64Array()
	_notes = []
	_spoken = {}
	if not Mission.has_plan():
		return
	var tt: Dictionary = Mission.plan.get("totals", {})
	var dist := float(tt.get("dist_m", 0.0))
	_speed = maxf(0.3, dist / maxf(float(tt.get("walk_s", 1.0)), 1.0))
	var d := 0.0
	while d <= dist:
		_route.append(Mission.route_xy(d))
		_route_d.append(d)
		d += 4.0
	# pace notes are per leg, in metres from the leg's start: put them on the whole route
	var prof: Dictionary = Mission.plan.get("profile", {})
	var legs: Array = prof.get("leg", [])
	var pd: Array = prof.get("d", [])
	var working: Array = prof.get("working", [])
	var start := {}
	for k in legs.size():
		var li := int(legs[k])
		if not start.has(li) and not (k < working.size() and bool(working[k])):
			start[li] = float(pd[k])
	for leg in Mission.plan.get("pace_notes", []):
		var d0 := float(start.get(int(leg["leg"]), NAN))
		if is_nan(d0):
			continue
		for n in leg["notes"]:
			var t := str(n["text"])
			var cut := t.find(": ")
			_notes.append({"d": d0 + float(n["d"]), "text": t.substr(cut + 2) if cut >= 0 else t})
	_notes.sort_custom(func(a, b): return float(a["d"]) < float(b["d"]))
	if synthetic_on:
		_build_poles()
	if not Mission.has_plan() and ghost_on:
		set_ghost(false)


func _on_site() -> void:
	_jezero_told = false
	_ambience(world.mode == "walk")


func _on_mode(mode: String) -> void:
	_ambience(mode == "walk")
	if mode != "walk" and _ghost:
		_ghost.visible = false


## E4: at Jezero the helmet ambience is real Martian wind, recorded by Perseverance's SuperCam microphone.
func _ambience(walk: bool) -> void:
	var jezero := Mission.site_id == "jezero_threeforks" and ResourceLoader.exists(JEZERO_WIND)
	if jezero and walk and Sfx.enabled and not Sfx.cli_mute:
		if _jezero == null:
			_jezero = AudioStreamPlayer.new()
			var st: AudioStream = load(JEZERO_WIND)
			if st is AudioStreamMP3:
				(st as AudioStreamMP3).loop = true
			_jezero.stream = st
			_jezero.bus = Sfx.BUS_AMB
			_jezero.volume_db = -6.0
			add_child(_jezero)
		if not _jezero.playing:
			_jezero.play()
		Sfx.loop("wind", false)   # the synthesised wind steps aside
		if not _jezero_told:
			_jezero_told = true
			toast.call("The wind you hear is real: Perseverance's SuperCam microphone, Jezero, sol 4 (NASA/JPL-Caltech/LANL/CNES)", "info")
	elif _jezero and _jezero.playing:
		_jezero.stop()
		if jezero == false or not walk:
			Sfx.loop("wind", true, -20.0)


# ------------------------------------------------------------------ helpers
func _look_point() -> Vector2:
	var cam := world.camera
	var hit := world.td.raycast(cam.global_position, -cam.global_transform.basis.z, 400.0)
	look = Vector2.INF if hit == Vector3.INF else Vector2(hit.x, -hit.z)
	return look


## Distance along the route of the route point nearest p, searched near `near_d` so a loop doubling back
## does not jump to the other leg. NAN if there is no route or you are more than 60 m from it.
func _route_distance(p: Vector2, near_d: float) -> float:
	if _route.is_empty():
		return NAN
	var lo := maxi(0, int((near_d - 250.0) / 4.0))
	var hi := mini(_route.size() - 1, int((near_d + 250.0) / 4.0))
	var best := INF
	var bi := -1
	for i in range(lo, hi + 1):
		var dd := _route[i].distance_squared_to(p)
		if dd < best:
			best = dd
			bi = i
	if bi < 0 or best > 60.0 * 60.0:
		return NAN
	return _route_d[bi]


func _build_poles() -> void:
	if _poles:
		_poles.queue_free()
		_poles = null
	if not Mission.has_plan():
		return
	var dist := float(Mission.plan.get("totals", {}).get("dist_m", 0.0))
	var n := int(dist / POLE_EVERY) + 1
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.035
	cyl.bottom_radius = 0.035
	cyl.height = 2.0
	cyl.radial_segments = 8
	cyl.rings = 1
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = cyl
	mm.instance_count = n
	for i in n:
		mm.set_instance_transform(i, Transform3D(Basis(), world.td.world_at(Mission.route_xy(i * POLE_EVERY), 1.0)))
	_poles = MultiMeshInstance3D.new()
	_poles.name = "SnowPoles"
	_poles.multimesh = mm
	var sm := ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = "shader_type spatial;\nrender_mode unshaded, cull_disabled, shadows_disabled;\nvarying float ly;\nvoid vertex() { ly = VERTEX.y; }\nvoid fragment() {\n\tfloat band = step(0.5, fract((ly + 1.0) * 2.0));\n\tALBEDO = mix(vec3(1.0, 0.28, 0.12), vec3(1.0), band) * 1.3;\n}\n"
	sm.shader = sh
	_poles.material_override = sm
	_poles.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	world.add_child(_poles)


func _material_all(n: Node, m: Material) -> void:
	if n is MeshInstance3D:
		(n as MeshInstance3D).material_override = m
		(n as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for c in n.get_children():
		_material_all(c, m)


# ------------------------------------------------------------------ B2 HUD-failure drill, B1 skyline fix
## B2: the HUD fails. The route, labels and map go dark and you walk home by the fallback card alone: the
## heading, where your shadow and the sun fall on the clock face, the paces, a landmark and the grid square.
## Back at the door (or U again) the console scores the walk. Y asks the skyline for a fix on the way.
var app                          # main.gd, for the HUD and the UI layer
var drill_on := false
var last_fix := {}               # the last skyline fix: {xy, r95, sq}
var last_score := -1             # the last drill's score (home by the card)
var _drill := {}
var _dark_nodes: Array = []      # what the drill switched off, to switch on again
var _dark_labels := true
var _card: PanelContainer
var _card_text: Label


func toggle_drill() -> void:
	if drill_on:
		_end_drill(false)
		return
	if world.mode != "walk" or not Mission.has_plan():
		toast.call("The HUD-failure drill runs in the helmet view (V) with a plan", "info")
		return
	var me := world.walker.xy()
	var door := world.haven_door()
	var dist := me.distance_to(door)
	if dist < 40.0:
		toast.call("Walk away from the %s first: the drill walks you home" % Mission.haven_name(), "info")
		return
	drill_on = true
	world.walker.autopilot = false
	if Mission.playing:
		Mission.set_playing(false)
	_drill = {"t0": Time.get_ticks_msec(), "start": me, "last": me, "walked": 0.0, "dist": dist, "fixes": 0}
	_set_dark(true)
	Sfx.play("warn", -6.0)
	toast.call("HUD FAILURE: displays dark. Walk home by the card. Y asks the skyline for a fix.", "warn")
	_show_card(_card_lines(me, door, []))
	# a landmark for the card (the named skyline features seen from here) and the grid square of the door
	var ll := Mission.grid.to_lonlat(me.x, me.y)
	var r := await Api.post_json("/api/sites/%s/skyline/fix" % Mission.site_id, {"lon": ll.x, "lat": ll.y, "seed": randi() % 1000}, 60.0)
	var dll := Mission.grid.to_lonlat(door.x, door.y)
	var gr := await Api.get_json("/api/sites/%s/grid-ref?lon=%f&lat=%f" % [Mission.site_id, dll.x, dll.y], 20.0)
	if gr["ok"] and gr["data"] is Dictionary:
		_drill["home_sq"] = "%s (%s)" % [str(gr["data"].get("ref_fine", "?")), str(gr["data"].get("say", ""))]
	if drill_on and r["ok"] and r["data"] is Dictionary:
		_drill["features"] = (r["data"] as Dictionary).get("features", [])
	if drill_on:
		_show_card(_card_lines(world.walker.xy(), door, _drill.get("features", [])))


func skyline_fix() -> void:
	if world.mode != "walk":
		toast.call("The skyline fix works in the helmet view (V)", "info")
		return
	var me := world.walker.xy()
	var ll := Mission.grid.to_lonlat(me.x, me.y)
	toast.call("Matching the horizon against the terrain model…", "info")
	var r := await Api.post_json("/api/sites/%s/skyline/fix" % Mission.site_id, {"lon": ll.x, "lat": ll.y, "seed": randi() % 1000}, 60.0)
	if not r["ok"] or not (r["data"] is Dictionary):
		toast.call("Skyline fix failed: %s" % str(r.get("error", "no answer")), "bad")
		return
	var fx: Dictionary = r["data"]["fix"]
	var fxy := Mission.grid.to_xy(float(fx["lon"]), float(fx["lat"]))
	var gr := await Api.get_json("/api/sites/%s/grid-ref?lon=%f&lat=%f" % [Mission.site_id, float(fx["lon"]), float(fx["lat"])], 20.0)
	var sq := str((gr["data"] as Dictionary).get("ref_fine", "?")) if gr["ok"] and gr["data"] is Dictionary else "?"
	var say := str((gr["data"] as Dictionary).get("say", "")) if gr["ok"] and gr["data"] is Dictionary else ""
	var door := world.haven_door()
	var hd := Geo.bearing_deg(fxy, door)
	if drill_on:
		_drill["fixes"] = int(_drill["fixes"]) + 1
	last_fix = {"xy": fxy, "r95": float(fx.get("r95_m", 0.0)), "sq": sq}
	world.scan_pulse(fxy)
	toast.call("Skyline fix: square %s (%s), ±%d m. %s: %03d°, %d m." % [sq, say, int(float(fx.get("r95_m", 0.0))),
		Mission.haven_name().capitalize(), int(round(hd)) % 360, int(fxy.distance_to(door))], "ok")


func _clock(rel_deg: float) -> int:
	var c := int(round(fposmod(rel_deg, 360.0) / 30.0)) % 12
	return 12 if c == 0 else c


func _card_lines(me: Vector2, door: Vector2, features: Array) -> String:
	var hd := Geo.bearing_deg(me, door)
	var dist := me.distance_to(door)
	var lines := ["FALLBACK CARD · WALK HOME", "Heading %03d° · %d m ≈ %d paces (1.5 m a pace)" % [int(round(hd)) % 360, int(dist), int(dist / 1.5)]]
	if world.sun_elev > 0.0:
		lines.append("Your shadow at %d o'clock · the sun at %d o'clock" % [_clock(world.sun_az + 180.0 - hd), _clock(world.sun_az - hd)])
	else:
		lines.append("The sun is down: walk by the landmark and the paces")
	for f in features:
		if f is Dictionary and f.has("az"):
			lines.append("%s at %d o'clock" % [str(f["name"]), _clock(float(f["az"]) - hd)])
			break
	if _drill.has("home_sq"):
		lines.append("The %s is in square %s" % [Mission.haven_name(), str(_drill["home_sq"])])
	lines.append("Count paces in hundreds · stop and ask the skyline (Y) if lost")
	return "\n".join(lines)


func _show_card(text: String) -> void:
	if _card == null:
		_card = PanelContainer.new()
		_card.name = "FallbackCard"
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.96, 0.93, 0.86, 0.94)
		sb.border_color = Color(0.35, 0.24, 0.15)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(14)
		_card.add_theme_stylebox_override("panel", sb)
		_card_text = Label.new()
		_card_text.add_theme_color_override("font_color", Color(0.13, 0.1, 0.07))
		_card_text.add_theme_font_size_override("font_size", 16)
		_card.add_child(_card_text)
		_card.anchor_left = 0.0
		_card.anchor_top = 1.0
		_card.anchor_bottom = 1.0
		_card.offset_left = 24
		_card.offset_top = -190
		_card.offset_bottom = -24
		_card.grow_vertical = Control.GROW_DIRECTION_BEGIN   # a longer card grows upward, never off the screen
		(app.ui as Control).add_child(_card)
	_card_text.text = text
	_card.visible = true


## Everything the visor draws goes dark (HUD, route, beacons, labels, the way home); what was showing comes back after.
func _set_dark(on: bool) -> void:
	app.hud.visible = not on and not app.ui_hidden
	if on:
		_dark_nodes.clear()
		var nodes: Array = [world.route_mi, world.crumbs, world.way_home_mi, world.rings_mi, world.sug_root, world.abort_mi]
		nodes.append_array(world.stop_nodes.values())
		for n in nodes:
			if n is Node3D and is_instance_valid(n) and (n as Node3D).visible:
				(n as Node3D).visible = false
				_dark_nodes.append(n)
		_dark_labels = world.show_labels
		world.set_layer_visible("labels", false)
	else:
		for n in _dark_nodes:
			if is_instance_valid(n):
				(n as Node3D).visible = true
		_dark_nodes.clear()
		world.set_layer_visible("labels", _dark_labels)
		if _card:
			_card.visible = false


func _update_drill() -> void:
	var me := world.walker.xy()
	var last: Vector2 = _drill["last"]
	var step := me.distance_to(last)
	if step < 30.0:   # not a teleport
		_drill["walked"] = float(_drill["walked"]) + step
	_drill["last"] = me
	if me.distance_to(world.haven_door()) < 15.0:
		_end_drill(true)


func _end_drill(home: bool) -> void:
	drill_on = false
	_set_dark(false)
	var secs := (Time.get_ticks_msec() - int(_drill.get("t0", Time.get_ticks_msec()))) / 1000.0
	var dist := float(_drill.get("dist", 0.0))
	var walked := maxf(float(_drill.get("walked", 0.0)), 1.0)
	var ideal := dist / maxf(_speed, 0.3)
	var eff := clampf(dist / walked, 0.0, 1.0)
	var pace := clampf(ideal / maxf(secs, 1.0), 0.0, 1.0)
	var score := int(round(100.0 * (0.65 * eff + 0.35 * pace))) - int(_drill.get("fixes", 0)) * 3
	if home:
		last_score = maxi(score, 0)
		Sfx.play("confirm", -4.0)
		toast.call("Home by the card: %d:%02d (ideal %d:%02d) · walked %d m for %d m (%d %% straight) · %d skyline fix%s · SCORE %d" % [
			int(secs) / 60, int(secs) % 60, int(ideal) / 60, int(ideal) % 60, int(walked), int(dist), int(eff * 100.0),
			int(_drill.get("fixes", 0)), "" if int(_drill.get("fixes", 0)) == 1 else "es", maxi(score, 0)], "ok")
	else:
		toast.call("Drill ended: displays back. %d m from the %s." % [int(world.walker.xy().distance_to(world.haven_door())), Mission.haven_name()], "info")
