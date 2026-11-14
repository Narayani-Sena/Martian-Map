extends Node
## Mission state shared by the 3D world and every UI panel (autoload "Mission").
## Holds the site, the EVA plan from the API, live conditions and the timeline clock.

signal status(text: String)                  # boot / loading messages
signal site_loaded
signal terrain_loaded
signal plan_started
signal plan_changed
signal plan_failed(message: String)
signal grids_changed
signal conditions_changed
signal space_weather_changed
signal weather_live_changed
signal time_changed(t: float)
signal playing_changed(on: bool)
signal selection_changed(stop_id: String)
signal mission_edited
signal tasks_changed
signal notify(text: String, kind: String)    # kind: info | ok | warn | bad
signal history_changed                       # undo / redo availability changed
signal mission_restored                      # undo, redo or reset replaced the settings: controls must re-read them
signal suggestions_changed                   # SUGGEST STOPS results arrived, were used or were cleared

const SPEEDS := [1.0, 10.0, 30.0, 60.0, 120.0, 300.0]

var site_id := "gale_boxwork"
var sites: Array = []          # /api/sites: every configured site, with a "built" flag
const LAST_SITE_FILE := "user://last_site.txt"
var site: Dictionary = {}
var grid: Geo
var grid2: Geo
var grid4: Geo
var terrain := TerrainData.new()
var site_texture: Texture2D
var site_normal: Texture2D
var regional_texture: Texture2D

# editable mission
var habitat: Dictionary = {}
var stops: Array = []
var relays: Array = []
var walk: Dictionary = {}
var suit: Dictionary = {}
var algorithm := "astar"
var start_utc := ""
var sep_active := false
var suit_fault := ""          # drill running: "" | "leak" | "co2" (see SuitModel)
var suit_fault_ms := 0        # when it started (real time: a drill runs at the same pace at any playback speed)
var return_to_hab := true
var rover_enabled := false   # rover-assisted EVA: PR-2 drives the crew to a drop-off and back
var rover_dropoff := {}      # {} = the planner chooses; else {"lon", "lat"}

# results
var plan: Dictionary = {}
var planning := false
var _replan_queued := false   # settings changed while a plan was computing: plan again with them

# packed copies of the plan's series for state_at() (see _index_plan)
const SIM_FIELDS := ["o2_pct", "battery_pct", "co2_pct", "water_pct", "met_w", "air_c", "sun_elev", "ltst", "dose_usv", "margin_min", "need_min", "limit_min",
	"ppco2_mmhg", "ppo2_kpa"]
var _pt := PackedFloat64Array()
var _pd := PackedFloat64Array()
var _plon := PackedFloat64Array()
var _plat := PackedFloat64Array()
var _pslope := PackedFloat64Array()
var _phaz := PackedFloat64Array()
var _pcomms := PackedFloat64Array()
var _pwb := PackedFloat64Array()
var _pshield := PackedFloat64Array()
var _pleg := PackedFloat64Array()
var _st := PackedFloat64Array()
var _sim := {}
var _rt := PackedFloat64Array()
var _rlon := PackedFloat64Array()
var _rlat := PackedFloat64Array()
var _cabin := Vector2(0.0, INF)   # suitport egress .. ingress window on a rover-assisted EVA
var _memo_t := NAN
var _memo := {}
var plan_error := ""
var conditions: Dictionary = {}
var space_weather: Dictionary = {}
var weather_live: Dictionary = {}
var traverse: Dictionary = {}
var waypoints: Dictionary = {}
var ingenuity: Dictionary = {}      # Ingenuity's flights near the site (ingenuity.geojson; Jezero)
var suggestions: Array = []         # science stops the planner proposed (data-use item D3)
var suggesting := false
var cme_drill := ""                 # CME drill: ISO time of a pretend full-hit arrival (pinned, so a later start clears it)
var _fetched := {}            # feed -> msec of its last good download, for STALE marks

# timeline
var eva_t := 0.0
var playing := false
var hold_at_end := false   # an abort walk is still under way: at the plan's end the clock holds (no stop, no rewind)
var speed_index := 2
var selected_stop := ""
var task_done := {}   # stop id -> Array[bool], ticked on the cuff checklist
var start_unix := 0.0

# edit history (Ctrl+Z / Ctrl+Y): snapshots of the editable mission taken before each change
const UNDO_MAX := 40
var _undo: Array = []    # [{label, state}], newest last
var _redo: Array = []


func _process(delta: float) -> void:
	if playing and has_plan():
		var total := total_s()
		eva_t = minf(eva_t + delta * play_speed(), total)
		time_changed.emit(eva_t)
		if eva_t >= total and not hold_at_end:
			set_playing(false)


# ------------------------------------------------------------------ helpers
func has_plan() -> bool:
	return not plan.is_empty()


func play_speed() -> float:
	return float(SPEEDS[speed_index])


func total_s() -> float:
	return float(plan["totals"]["total_s"]) if has_plan() else 0.0


func set_time(t: float) -> void:
	eva_t = clampf(t, 0.0, maxf(total_s(), 0.0))
	time_changed.emit(eva_t)


func set_playing(on: bool) -> void:
	if on and has_plan() and eva_t >= total_s() - 1.0 and not hold_at_end:
		eva_t = 0.0
	playing = on and has_plan()
	playing_changed.emit(playing)


func cycle_speed(dir := 1) -> void:
	speed_index = clampi(speed_index + dir, 0, SPEEDS.size() - 1)
	playing_changed.emit(playing)


func select_stop(id: String) -> void:
	selected_stop = id
	selection_changed.emit(id)


func task_state(stop_id: String, n: int) -> Array:
	var a: Array = task_done.get(stop_id, [])
	while a.size() < n:
		a.append(false)
	task_done[stop_id] = a
	return a


func toggle_task(stop_id: String, i: int) -> void:
	var s := stop_by_id(stop_id)
	var tasks: Array = s.get("tasks", [])
	if s.is_empty() or i < 0 or i >= tasks.size():
		return
	var a := task_state(stop_id, tasks.size())
	a[i] = not bool(a[i])
	tasks_changed.emit()


## Station on the cuff: the stop being worked, else the next one. {} after the last stop.
func cuff_station(t: float) -> Dictionary:
	if not has_plan():
		return {}
	var n := 0
	for e in plan["events"]:
		if str(e["kind"]) != "stop":
			continue
		n += 1
		if t < float(e["t1"]):
			var s := stop_by_id(str(e.get("id", "")))
			return {"stop": s, "index": n, "working": t >= float(e["t0"]), "t0": float(e["t0"]), "t1": float(e["t1"])}
	return {}


func traverse_sheet() -> void:
	var r := await Api.request_raw("/api/sites/%s/traverse-sheet" % site_id, HTTPClient.METHOD_POST, JSON.stringify(plan_body()), 240.0)
	if not r["ok"]:
		notify.emit("Traverse sheet failed: %s" % str(r["error"]), "bad")
		return
	var path := "user://traverse_sheet.html"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(r["body"])
	f.close()
	OS.shell_open(ProjectSettings.globalize_path(path))
	notify.emit("Traverse sheet opened in your browser (print it A4 landscape).", "ok")


func stop_by_id(id: String) -> Dictionary:
	for s in stops:
		if str(s.get("id", "")) == id:
			return s
	return {}


func xy_of(lon: float, lat: float) -> Vector2:
	return grid.to_xy(lon, lat)


func hab_xy() -> Vector2:
	return grid.to_xy(float(habitat["lon"]), float(habitat["lat"]))


# ------------------------------------------------------------------ rover-assisted EVA (PR-2)
func set_rover(on: bool) -> void:
	push_undo("turn PR-2 %s" % ("on" if on else "off"))
	rover_enabled = on
	mission_edited.emit()


func set_dropoff(lon: float, lat: float) -> void:
	push_undo("place PR-2")
	rover_dropoff = {"lon": lon, "lat": lat}
	rover_enabled = true
	mission_edited.emit()


func auto_dropoff() -> void:
	push_undo("automatic PR-2 drop-off")
	rover_dropoff = {}
	mission_edited.emit()


func has_rover() -> bool:
	return has_plan() and bool((plan.get("rover", {}) as Dictionary).get("enabled", false))


func dropoff_lonlat() -> Vector2:
	var d: Dictionary = plan["rover"]["dropoff"]
	return Vector2(float(d["lon"]), float(d["lat"]))


## Where the walking loop starts and ends: the hab, or PR-2 parked at its drop-off.
func haven_lonlat() -> Vector2:
	return dropoff_lonlat() if has_rover() else Vector2(float(habitat["lon"]), float(habitat["lat"]))


func haven_xy() -> Vector2:
	var ll := haven_lonlat()
	return xy_of(ll.x, ll.y)


func haven_name() -> String:
	return str(plan["rover"].get("name", "PR-2")) if has_rover() else "HAB"


## Outside suitport egress .. ingress the crew rides in the rover's cabin (window found by _index_plan).
func in_cabin(t: float) -> bool:
	if not has_rover():
		return false
	return t < _cabin.x or t >= _cabin.y


## PR-2 along its drive track; between the two drives it stands at the drop-off.
func rover_state(t: float) -> Dictionary:
	var a := _locate(_rt, t)
	var b := _locate(_rt, t + 3.0)
	var xy := xy_of(_at(_rlon, int(a.x), a.y), _at(_rlat, int(a.x), a.y))
	var ahead := xy_of(_at(_rlon, int(b.x), b.y), _at(_rlat, int(b.x), b.y))
	return {"xy": xy, "xy_ahead": ahead, "moving": xy.distance_to(ahead) > 0.05}


func site_lat() -> float:
	return float(site["center"]["lat"])


func site_lon() -> float:
	return float(site["center"]["lon"])


func landing_msd() -> float:
	return float(site.get("rover", {}).get("landing_msd_local", 0))


## UTC (unix) of a point on the EVA timeline.
func unix_at(t: float) -> float:
	return start_unix + t


func walk_query() -> Dictionary:
	var q := {}
	for k in ["flat_speed", "max_slope", "caution_slope", "max_rough", "sand_penalty", "hazard_aversion", "load_kg"]:
		if walk.has(k):
			q[k] = walk[k]
	return q


## Every place the crew can walk home to, for the ways-home network (feature A1): the hab and PR-2 parked
## at its drop-off. "lon,lat,name;..."
func havens_param() -> String:
	var parts := PackedStringArray()
	parts.append("%.7f,%.7f,Hab" % [float(habitat["lon"]), float(habitat["lat"])])
	if has_rover():
		var dl := dropoff_lonlat()
		parts.append("%.7f,%.7f,PR-2" % [dl.x, dl.y])
	return ";".join(parts)


func observers() -> String:
	var parts := PackedStringArray()
	var mast := float(site.get("radio", {}).get("habitat_mast_m", 12.0))
	parts.append("%.7f,%.7f,%.2f" % [float(habitat["lon"]), float(habitat["lat"]), mast])
	for r in relays:
		parts.append("%.7f,%.7f,%.2f" % [float(r["lon"]), float(r["lat"]), float(r.get("height_m", 3.0))])
	if has_rover():  # the parked rover's mast relays for the walkers
		var dl := dropoff_lonlat()
		parts.append("%.7f,%.7f,%.2f" % [dl.x, dl.y, float(plan["rover"].get("antenna_m", 3.5))])
	return ";".join(parts)


# ------------------------------------------------------------------ sites
## The site used last time (or `--site=<id>` on the command line).
func pick_initial_site() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--site="):
			site_id = a.substr(7)
			return
	if FileAccess.file_exists(LAST_SITE_FILE):
		var s := FileAccess.get_file_as_string(LAST_SITE_FILE).strip_edges()
		if s != "":
			site_id = s


func load_sites() -> void:
	var r := await Api.get_json("/api/sites", 60.0)
	if r["ok"] and r["data"] is Array:
		sites = r["data"]
	var built := []
	for s in sites:
		if bool(s.get("built", false)):
			built.append(str(s["id"]))
	if not built.is_empty() and not built.has(site_id):
		site_id = str(built[0])


func site_entry(id: String) -> Dictionary:
	for s in sites:
		if str(s.get("id", "")) == id:
			return s
	return {}


## Forget everything about the current site; the caller reloads the scene to boot the new one.
func switch_site(id: String) -> void:
	site_id = id
	var f := FileAccess.open(LAST_SITE_FILE, FileAccess.WRITE)
	if f:
		f.store_string(id)
		f.close()
	site = {}
	plan = {}
	plan_error = ""
	planning = false
	terrain = TerrainData.new()
	conditions = {}
	weather_live = {}
	traverse = {}
	waypoints = {}
	ingenuity = {}
	suggestions = []
	cme_drill = ""
	eva_t = 0.0
	playing = false
	selected_stop = ""
	task_done = {}


func rover_label() -> String:
	return str(site.get("rover_name", "Rover"))


## The raw-image feed of this site's rover ("msl" Curiosity, "mars2020" Perseverance).
func raw_images_mission() -> String:
	var rv: Variant = site.get("rover", {})
	return str((rv as Dictionary).get("raw_images_mission", "msl")) if rv is Dictionary else "msl"


## A short stamp of the site build for cache names, so a rebuilt site (re-aligned texture, new layers) is fetched again.
func build_stamp() -> String:
	return str(site.get("built_utc", "")).md5_text().substr(0, 8)


## Drop this site's cached downloads from older builds (their names carry another build stamp, or none).
func _prune_cache() -> void:
	var d := DirAccess.open(Api.CACHE_DIR)
	if d == null:
		return
	var keep := "%s_%s_" % [site_id, build_stamp()]
	for f in d.get_files():
		if f.begins_with(site_id + "_") and not f.begins_with(keep):
			d.remove(f)


# ------------------------------------------------------------------ loading
func load_site() -> bool:
	status.emit("Requesting site manifest")
	var r := await Api.get_json("/api/sites/%s" % site_id, 120.0)
	if not r["ok"] or not (r["data"] is Dictionary):
		status.emit("Site manifest failed: %s" % r["error"])
		return false
	site = r["data"]
	grid = Geo.from_dict(site["grid"])
	grid2 = Geo.from_dict(site["grid2"])
	grid4 = Geo.from_dict(site["grid4"])
	terrain.grid = grid
	terrain.elev_ref = float(site["elev_min"])
	_reset_mission()
	_load_saved()
	clear_history()
	site_loaded.emit()
	return true


func _reset_mission() -> void:
	habitat = (site["habitat"] as Dictionary).duplicate(true)
	stops = (site["stops"] as Array).duplicate(true)
	relays = []
	var i := 1
	for r in site.get("radio", {}).get("relays", []):
		var rr: Dictionary = (r as Dictionary).duplicate()
		rr["id"] = "R%d" % i
		relays.append(rr)
		i += 1
	walk = (site["defaults"]["walk"] as Dictionary).duplicate()
	suit = (site["defaults"]["suit"] as Dictionary).duplicate()
	start_utc = str(site["defaults"]["start_utc"])
	start_unix = MarsTime.parse_iso(start_utc)
	rover_enabled = false
	rover_dropoff = {}


func reset_mission() -> void:
	push_undo("reset to the site's defaults")
	_reset_mission()
	save_mission()
	mission_edited.emit()
	mission_restored.emit()


func load_terrain(progress: Callable) -> bool:
	progress.call("HiRISE 1 m elevation model (42 MB, cached after first run)", 0.0)
	_prune_cache()
	var stamp := build_stamp()
	var r := await Api.get_cached("/api/sites/%s/dem.bin" % site_id, "%s_%s_dem_1m.f32" % [site_id, stamp])
	if not r["ok"]:
		status.emit("DEM download failed: %s" % r["error"])
		return false
	var dem_img := [null]
	var dem_bytes: PackedByteArray = r["body"]
	await Api.run_async(func(): dem_img[0] = terrain.prepare_dem(dem_bytes, grid))   # off the main thread
	terrain.finish_dem(dem_img[0])
	progress.call("Regional 200 m elevation model (the crater and its surroundings)", 0.4)
	var rg := await Api.get_cached("/api/sites/%s/regional.bin" % site_id, "%s_%s_regional.f32" % [site_id, stamp])
	if rg["ok"] and site.get("regional_grid") is Dictionary:
		var off := 0.0
		var hd: Dictionary = rg["headers"]
		if hd.has("x-offset"):
			off = str(hd["x-offset"]).to_float()
		var reg_img := [null]
		var reg_bytes: PackedByteArray = rg["body"]
		var reg_g := Geo.from_dict(site["regional_grid"])
		await Api.run_async(func(): reg_img[0] = terrain.prepare_regional(reg_bytes, reg_g, off))
		terrain.finish_regional(reg_img[0])
	var px := int(Quality.get_value("tex"))
	progress.call("HiRISE colour mosaic (25 cm source, %d px drape)" % px, 0.55)
	site_texture = await Api.get_texture("/api/sites/%s/files/texture_%d.jpg" % [site_id, px], "%s_%s_texture_%d.jpg" % [site_id, stamp, px])
	progress.call("Terrain normal map from the 1 m DTM", 0.72)
	site_normal = await Api.get_texture("/api/sites/%s/files/normal_%d.jpg" % [site_id, px], "%s_%s_normal_%d.jpg" % [site_id, stamp, px])
	progress.call("Regional context imagery", 0.85)
	regional_texture = await Api.get_texture("/api/sites/%s/files/regional_texture.jpg" % site_id, "%s_%s_regional_texture.jpg" % [site_id, stamp])
	progress.call("Boulders detected in HiRISE shadows", 0.9)
	var bl := await Api.get_cached("/api/sites/%s/boulders.bin" % site_id, "%s_%s_boulders.f32" % [site_id, stamp], 86400.0)
	if bl["ok"]:
		terrain.set_boulders(bl["body"])
	progress.call("%s traverse" % rover_label(), 0.95)
	var tr := await Api.get_json("/api/sites/%s/files/rover_traverse.geojson" % site_id)
	if tr["ok"] and tr["data"] is Dictionary:
		traverse = tr["data"]
	var wp := await Api.get_json("/api/sites/%s/files/rover_waypoints.geojson" % site_id)
	if wp["ok"] and wp["data"] is Dictionary:
		waypoints = wp["data"]
	if (site.get("files", []) as Array).has("ingenuity.geojson"):
		var ig := await Api.get_json("/api/sites/%s/files/ingenuity.geojson" % site_id)
		if ig["ok"] and ig["data"] is Dictionary:
			ingenuity = ig["data"]
	terrain_loaded.emit()
	return true


# ------------------------------------------------------------------ planning
func plan_body() -> Dictionary:
	var st := []
	for s in stops:
		st.append({"id": s.get("id"), "name": s.get("name", "Stop"), "lon": s["lon"], "lat": s["lat"],
			"dwell_min": s.get("dwell_min", 20), "kind": s.get("kind"), "tasks": s.get("tasks", [])})
	var rl := []
	for r in relays:
		rl.append({"lon": r["lon"], "lat": r["lat"], "height_m": r.get("height_m", 3.0), "name": r.get("id")})
	return {
		"habitat": {"lon": habitat["lon"], "lat": habitat["lat"]},
		"stops": st, "return_to_habitat": return_to_hab, "algorithm": algorithm, "astar_weight": 1.0,
		"walk": walk, "suit": suit, "start_utc": start_utc, "sep_active": sep_active,
		"radio": {"habitat_mast_m": float(site.get("radio", {}).get("habitat_mast_m", 12.0)),
			"suit_antenna_m": float(site.get("radio", {}).get("suit_antenna_m", 2.0)), "relays": rl},
		"rover": {"enabled": rover_enabled, "dropoff": rover_dropoff if (rover_enabled and not rover_dropoff.is_empty()) else null},
	}.merged({"cme_arrivals": [{"arrival": cme_drill, "glancing": false, "cme": "DRILL"}]} if cme_drill != "" else {})


## CME drill on or off: a full-hit CME forecast 90 min into the EVA (data-use item E1).
func toggle_cme_drill() -> void:
	if cme_drill == "":
		cme_drill = MarsTime.to_iso(start_unix + 5400.0)
		notify.emit("CME drill: DONKI 'forecasts' a full-hit CME 90 min into the EVA. Re-planning …", "warn")
	else:
		cme_drill = ""
		notify.emit("CME drill ended: back to NASA DONKI's real forecasts", "info")
	request_plan()


## Plan the EVA with the current settings. An edit made while a plan is computing is not dropped:
## it queues exactly one more request, and the stale answer is thrown away, so the plan on screen
## always matches the settings on screen. Callers that await this get the final plan.
func request_plan() -> void:
	if site.is_empty():
		return
	if planning:
		_replan_queued = true
		return
	planning = true
	plan_error = ""
	plan_started.emit()
	var r: Dictionary
	while true:
		_replan_queued = false
		status.emit("Routing EVA with A* over the 2 m cost grid")
		r = await Api.post_json("/api/sites/%s/plan" % site_id, plan_body(), 240.0)
		if not _replan_queued:
			break
	planning = false
	if not r["ok"] or not (r["data"] is Dictionary):
		plan_error = str(r["error"])
		plan_failed.emit(plan_error)
		notify.emit(plan_error, "bad")
		return
	plan = r["data"]
	_index_plan()
	start_unix = MarsTime.parse_iso(str(plan["totals"]["start_utc"]))
	eva_t = clampf(eva_t, 0.0, total_s())
	plan_changed.emit()
	time_changed.emit(eva_t)
	save_mission()
	_load_grids()


func _load_grids() -> void:
	var hv := haven_lonlat()   # walk-back to the hab, or to PR-2 parked at its drop-off
	var hab := {"hab_lon": hv.x, "hab_lat": hv.y}
	var wq := walk_query()
	var jobs := [
		["walkback", "/api/sites/%s/grid/walkback.bin" % site_id + Api.q(hab.merged(wq)), "f32"],
		["comms", "/api/sites/%s/grid/comms.bin" % site_id + Api.q({"obs": observers(), "tgt": site.get("radio", {}).get("suit_antenna_m", 2.0)}), "u8"],
		["hazard", "/api/sites/%s/grid/hazard.bin" % site_id + Api.q(wq), "u8"],
		["shield", "/api/sites/%s/grid/shield.bin" % site_id, "f32"],
		["science", "/api/sites/%s/grid/science.bin" % site_id, "u8"],
	]
	for j in jobs:
		var r := await Api.request_raw(str(j[1]), HTTPClient.METHOD_GET, "", 120.0, false)
		if not r["ok"]:
			continue
		var gname := str((r["headers"] as Dictionary).get("x-grid", "grid2"))
		var g: Geo = grid4 if gname == "grid4" else grid2
		terrain.set_layer(str(j[0]), r["body"], g, str(j[2]))
	grids_changed.emit()


func refresh_conditions() -> void:
	var r := await Api.get_json("/api/sites/%s/conditions" % site_id, 60.0)
	if r["ok"] and r["data"] is Dictionary:
		conditions = r["data"]
		_fetched["conditions"] = Time.get_ticks_msec()
		conditions_changed.emit()


## Seconds since a feed ("conditions", "space_weather", "weather_live") last downloaded (INF = never).
func age_s(feed: String) -> float:
	return (Time.get_ticks_msec() - int(_fetched[feed])) / 1000.0 if _fetched.has(feed) else INF


## Start ("leak", "co2") or end ("") a suit drill.
func set_drill(kind: String) -> void:
	suit_fault = kind
	suit_fault_ms = Time.get_ticks_msec()


## The site rover's weather station (Curiosity REMS; Perseverance MEDA when published).
func refresh_weather_live() -> void:
	var r := await Api.get_json("/api/sites/%s/weather/live" % site_id, 90.0)
	if r["ok"] and r["data"] is Dictionary:
		weather_live = r["data"]
		_fetched["weather_live"] = Time.get_ticks_msec()
		weather_live_changed.emit()


func refresh_space_weather() -> void:
	var r := await Api.get_json("/api/spaceweather", 90.0)
	if r["ok"] and r["data"] is Dictionary:
		space_weather = r["data"]
		_fetched["space_weather"] = Time.get_ticks_msec()
	else:
		space_weather = {"status": "UNKNOWN", "reasons": [str(r["error"])], "errors": [str(r["error"])]}
	space_weather_changed.emit()


# ------------------------------------------------------------------ edit history
## Everything an edit can change that the planner reads.
func _snapshot() -> Dictionary:
	return {"habitat": habitat.duplicate(true), "stops": stops.duplicate(true), "relays": relays.duplicate(true),
		"walk": walk.duplicate(true), "suit": suit.duplicate(true), "algorithm": algorithm, "return_to_hab": return_to_hab,
		"rover_enabled": rover_enabled, "rover_dropoff": rover_dropoff.duplicate(true), "start_utc": start_utc,
		"start_unix": start_unix, "sep_active": sep_active}


func _restore(s: Dictionary) -> void:
	habitat = s["habitat"]
	stops = s["stops"]
	relays = s["relays"]
	walk = s["walk"]
	suit = s["suit"]
	algorithm = str(s["algorithm"])
	return_to_hab = bool(s["return_to_hab"])
	rover_enabled = bool(s["rover_enabled"])
	rover_dropoff = s["rover_dropoff"]
	start_utc = str(s["start_utc"])
	start_unix = float(s["start_unix"])
	sep_active = bool(s["sep_active"])
	if stop_by_id(selected_stop).is_empty():
		selected_stop = ""


## Call just before changing the mission; Ctrl+Z goes back to the state at this point.
func push_undo(label: String) -> void:
	_undo.append({"label": label, "state": _snapshot()})
	if _undo.size() > UNDO_MAX:
		_undo.pop_front()
	_redo.clear()
	history_changed.emit()


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_label() -> String:
	return str(_undo[-1]["label"]) if not _undo.is_empty() else ""


## Step back one edit. Returns what was undone ("" = nothing); the caller re-plans.
func undo() -> String:
	if _undo.is_empty():
		return ""
	var e: Dictionary = _undo.pop_back()
	_redo.append({"label": e["label"], "state": _snapshot()})
	_restore(e["state"])
	_after_history()
	return str(e["label"])


func redo() -> String:
	if _redo.is_empty():
		return ""
	var e: Dictionary = _redo.pop_back()
	_undo.append({"label": e["label"], "state": _snapshot()})
	_restore(e["state"])
	_after_history()
	return str(e["label"])


func _after_history() -> void:
	save_mission()
	mission_edited.emit()
	mission_restored.emit()
	selection_changed.emit(selected_stop)
	history_changed.emit()


func clear_history() -> void:
	_undo.clear()
	_redo.clear()
	history_changed.emit()


# ------------------------------------------------------------------ editing
func add_stop(lon: float, lat: float) -> Dictionary:
	push_undo("add a stop")
	var n := stops.size() + 1
	var id := "S%d" % n
	while not stop_by_id(id).is_empty():
		n += 1
		id = "S%d" % n
	var s := {"id": id, "name": "Waypoint %d" % n, "kind": "custom", "lon": lon, "lat": lat, "dwell_min": 15,
		"tasks": ["Photograph the site", "Collect a grab sample"], "science": "A stop added from the EVA console."}
	stops.append(s)
	mission_edited.emit()
	select_stop(id)
	return s


func remove_stop(id: String) -> void:
	push_undo("remove %s" % str(stop_by_id(id).get("name", id)))
	for i in stops.size():
		if str(stops[i].get("id", "")) == id:
			stops.remove_at(i)
			break
	if selected_stop == id:
		selected_stop = ""
	mission_edited.emit()


func move_stop(id: String, lon: float, lat: float) -> void:
	var s := stop_by_id(id)
	if s.is_empty():
		return
	push_undo("move %s" % str(s.get("name", id)))
	s["lon"] = lon
	s["lat"] = lat
	mission_edited.emit()


func set_start_hour(ltst_h: float) -> void:
	push_undo("change the egress time")
	var base := MarsTime.utc_for_ltst(Time.get_unix_time_from_system(), site_lon(), ltst_h)
	if base < Time.get_unix_time_from_system():
		base = MarsTime.utc_for_ltst(base + MarsTime.SOL_SECONDS, site_lon(), ltst_h)
	start_utc = MarsTime.to_iso(base)
	start_unix = base
	mission_edited.emit()


## Ask the planner for science stops inside the safe walk-back range (data-use item D3).
func suggest_stops(n := 3, max_walkback_min := 35.0) -> void:
	if site.is_empty() or suggesting:
		return
	suggesting = true
	suggestions_changed.emit()
	var st := []
	for s in stops:
		st.append({"lon": s["lon"], "lat": s["lat"]})
	var body := {"habitat": {"lon": habitat["lon"], "lat": habitat["lat"]}, "stops": st, "walk": walk, "n": n,
		"max_walkback_min": max_walkback_min}
	var rv: Variant = plan.get("rover", {}) if has_plan() else {}
	if rover_enabled and rv is Dictionary and (rv as Dictionary).get("dropoff") is Dictionary:
		var d: Dictionary = (rv as Dictionary)["dropoff"]
		body["haven"] = {"lon": d["lon"], "lat": d["lat"]}
	var r := await Api.post_json("/api/sites/%s/suggest-stops" % site_id, body, 60.0)
	suggesting = false
	if not r["ok"] or not (r["data"] is Dictionary):
		notify.emit("Suggest stops failed: %s" % str(r["error"]), "bad")
		suggestions_changed.emit()
		return
	suggestions = (r["data"] as Dictionary).get("suggestions", [])
	suggestions_changed.emit()
	if suggestions.is_empty():
		notify.emit("No science stop inside that walk-back range", "info")
	else:
		notify.emit("%d science stops within %d min of the %s" % [suggestions.size(), int(max_walkback_min), "rover" if body.has("haven") else "hab"], "ok")


## Add a suggested stop to the route (undoable) and drop it from the suggestions.
func accept_suggestion(sg: Dictionary) -> void:
	push_undo("add %s" % str(sg.get("name", "a suggested stop")))
	var n := stops.size() + 1
	var id := "S%d" % n
	while not stop_by_id(id).is_empty():
		n += 1
		id = "S%d" % n
	var tasks: Array = sg.get("tasks", [])
	stops.append({"id": id, "name": str(sg.get("name", "Science stop")), "kind": str(sg.get("kind", "outcrop")),
		"lon": float(sg["lon"]), "lat": float(sg["lat"]), "dwell_min": int(sg.get("dwell_min", 25)),
		"tasks": tasks.duplicate(), "science": str(sg.get("science", ""))})
	var keep := []
	for x in suggestions:
		if str((x as Dictionary).get("id", "")) != str(sg.get("id", "")):
			keep.append(x)
	suggestions = keep
	mission_edited.emit()
	suggestions_changed.emit()
	select_stop(id)


## Move the EVA start to an exact UTC time (e.g. the planner's first start clear of a CME window).
func set_start_utc(iso: String) -> void:
	push_undo("move the EVA start")
	start_utc = iso
	start_unix = MarsTime.parse_iso(iso)
	mission_edited.emit()
	mission_restored.emit()   # controls re-read the start time


func save_mission() -> void:
	var f := FileAccess.open("user://mission_%s.json" % site_id, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"habitat": habitat, "stops": stops, "relays": relays, "walk": walk, "suit": suit,
			"algorithm": algorithm, "return_to_hab": return_to_hab, "rover_enabled": rover_enabled, "rover_dropoff": rover_dropoff}, "  "))
		f.close()


## The editable mission as a file another console (or a backup) can load: export_mission / import_mission.
func mission_file() -> Dictionary:
	return {"format": "martian-map-mission", "version": 1, "site_id": site_id, "site_name": str(site.get("name", "")),
		"exported_utc": Time.get_datetime_string_from_system(true) + "Z",
		"habitat": habitat, "stops": stops, "relays": relays, "walk": walk, "suit": suit, "algorithm": algorithm,
		"return_to_hab": return_to_hab, "rover_enabled": rover_enabled, "rover_dropoff": rover_dropoff, "start_utc": start_utc}


func export_mission(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(mission_file(), "  "))
	f.close()
	return true


## Load a mission file (undoable). Returns "" or what was wrong with it.
func import_mission(path: String) -> String:
	if not FileAccess.file_exists(path):
		return "File not found"
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (d is Dictionary) or str((d as Dictionary).get("format", "")) != "martian-map-mission":
		return "Not a Martian Map mission file"
	var dd: Dictionary = d
	if str(dd.get("site_id", "")) != site_id:
		return "This mission is for %s; switch to that site first (SITE ▾)" % str(dd.get("site_name", dd.get("site_id", "?")))
	if not (dd.get("habitat") is Dictionary) or not (dd.get("stops") is Array):
		return "The file has no habitat or stops"
	push_undo("import a mission file")
	for k in ["habitat", "stops", "relays", "walk", "suit"]:
		if dd.has(k):
			set(k, dd[k])
	algorithm = str(dd.get("algorithm", algorithm))
	return_to_hab = bool(dd.get("return_to_hab", true))
	rover_enabled = bool(dd.get("rover_enabled", false))
	var rd: Variant = dd.get("rover_dropoff", {})
	rover_dropoff = rd if rd is Dictionary else {}
	if str(dd.get("start_utc", "")) != "":
		start_utc = str(dd["start_utc"])
	mission_restored.emit()
	mission_edited.emit()
	return ""


func _load_saved() -> void:
	var p := "user://mission_%s.json" % site_id
	if not FileAccess.file_exists(p):
		return
	var d: Variant = JSON.parse_string(FileAccess.get_file_as_string(p))
	if not (d is Dictionary):
		return
	for k in ["habitat", "stops", "relays", "walk", "suit"]:
		if (d as Dictionary).has(k):
			set(k, d[k])
	algorithm = str(d.get("algorithm", algorithm))
	return_to_hab = bool(d.get("return_to_hab", true))
	rover_enabled = bool(d.get("rover_enabled", false))
	var rd: Variant = d.get("rover_dropoff", {})
	rover_dropoff = rd if rd is Dictionary else {}


# ------------------------------------------------------------------ timeline queries
## Everything the HUD and 3D crew need at EVA time t. Called several times a frame (world, crew, dock,
## HUD), so it reads packed copies of the plan's series (built once per plan by _index_plan) and the
## answer for the latest t is memoised. Treat the returned dictionary as read-only.
func state_at(t: float) -> Dictionary:
	if has_plan() and t == _memo_t:
		return _memo
	var out := {"t": t, "xy": hab_xy() if not habitat.is_empty() else Vector2.ZERO, "d": 0.0, "event": {}, "phase": "—"}
	if not has_plan():
		return out
	var a := _locate(_pt, t)
	var d := _at(_pd, int(a.x), a.y)
	var b := _locate(_pd, d)
	var lon := _at(_plon, int(b.x), b.y)
	var lat := _at(_plat, int(b.x), b.y)
	out["d"] = d
	out["xy"] = grid.to_xy(lon, lat)
	out["lonlat"] = Vector2(lon, lat)
	var c := _locate(_pd, d + 8.0)
	out["xy_ahead"] = grid.to_xy(_at(_plon, int(c.x), c.y), _at(_plat, int(c.x), c.y))
	var si := _locate(_st, t)   # one search for all twelve suit series
	for k in SIM_FIELDS:
		out[k] = _at(_sim[k], int(si.x), si.y)
	var i := clampi(_pd.bsearch(d, false) - 1, 0, maxi(_pd.size() - 1, 0))   # last profile point at or before d
	out["slope"] = _pslope[i]
	out["hazard"] = int(_phaz[i])
	out["comms"] = int(_pcomms[i])
	out["walkback_min"] = _pwb[i]
	out["shield"] = _pshield[i]
	out["leg"] = int(_pleg[i])
	for e in plan["events"]:
		if t >= float(e["t0"]) and t < float(e["t1"]):
			out["event"] = e
			break
	if (out["event"] as Dictionary).is_empty() and t >= total_s() - 1.0:
		out["event"] = plan["events"][plan["events"].size() - 1]
	var ev: Dictionary = out["event"]
	out["phase"] = str(ev.get("kind", "—"))
	if has_rover():
		var rs := rover_state(t)
		out["rover_xy"] = rs["xy"]
		out["rover_moving"] = rs["moving"]
		if in_cabin(t):  # riding: the crew is wherever PR-2 is
			out["in_cabin"] = true
			out["ride"] = true
			out["xy"] = rs["xy"]
			out["xy_ahead"] = rs["xy_ahead"]
	_memo_t = t
	_memo = out
	return out


## Site position of the point `d` metres along the planned route (crew and EV2 placement).
func route_xy(d: float) -> Vector2:
	var b := _locate(_pd, d)
	return grid.to_xy(_at(_plon, int(b.x), b.y), _at(_plat, int(b.x), b.y))


## Packed copies of the plan's time series: typed arrays search and read far faster than the
## Variant arrays straight from JSON. JSON nulls become NAN for interpolation (skipped like before).
func _index_plan() -> void:
	var p: Dictionary = plan["profile"]
	_pt = _f64(p["t"])
	_pd = _f64(p["d"])
	_plon = _f64(p["lon"])
	_plat = _f64(p["lat"])
	_pslope = _f64(p["slope"], 0.0)
	_phaz = _f64(p["hazard"], 0.0)
	_pcomms = _f64(p["comms"], 0.0)
	_pwb = _f64(p["walkback_min"], 0.0)
	_pshield = _f64(p["shield"], 0.0)
	_pleg = _f64(p["leg"], 0.0)
	var s: Dictionary = plan["sim"]
	_st = _f64(s["t"])
	_sim = {}
	for k in SIM_FIELDS:
		_sim[k] = _f64(s.get(k, []))
	_rt = PackedFloat64Array()
	_cabin = Vector2(0.0, INF)
	if has_rover():
		var tr: Dictionary = plan["rover"]["track"]
		_rt = _f64(tr["t"])
		_rlon = _f64(tr["lon"])
		_rlat = _f64(tr["lat"])
		var evs: Array = plan["events"]
		var eg := 0.0
		var ig := total_s()
		for e in evs:
			if str(e["kind"]) == "egress":
				eg = float(e["t0"])
				break
		for j in range(evs.size() - 1, -1, -1):
			if str(evs[j]["kind"]) == "ingress":
				ig = float(evs[j]["t1"])
				break
		_cabin = Vector2(eg, ig)
	_memo_t = NAN


static func _f64(a: Array, null_as := NAN) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	out.resize(a.size())
	for i in a.size():
		var v: Variant = a[i]
		out[i] = null_as if v == null else float(v)
	return out


## (index, fraction) of x in the sorted series xs, clamped to its ends: the value is between xs[i] and xs[i+1].
static func _locate(xs: PackedFloat64Array, x: float) -> Vector2:
	var n := xs.size()
	if n == 0 or x <= xs[0]:
		return Vector2(0, 0.0)
	if x >= xs[n - 1]:
		return Vector2(n - 1, 0.0)
	var hi := xs.bsearch(x, true)   # first index with xs[hi] >= x (binary search in C++)
	var lo := hi - 1
	var span := xs[hi] - xs[lo]
	return Vector2(lo, (x - xs[lo]) / span if span > 0.0 else 0.0)


## Value of series ys at (index, fraction); a NAN (null) end falls back to the other one, as Geo.interp did.
static func _at(ys: PackedFloat64Array, i: int, f: float) -> float:
	if ys.is_empty():
		return 0.0
	var a := ys[i]
	if f <= 0.0 or i + 1 >= ys.size():
		return 0.0 if is_nan(a) else a
	var b := ys[i + 1]
	if is_nan(a):
		return 0.0 if is_nan(b) else b
	if is_nan(b):
		return a
	return a + (b - a) * f


## Next stop (or the hab) ahead of distance d along the route: {name, xy, d_remaining}.
func next_target(t: float) -> Dictionary:
	if not has_plan():
		return {}
	var tt := t
	for e in plan["events"]:
		var k := str(e["kind"])
		if (k == "stop" or k == "ingress") and float(e["t0"]) >= tt - 1.0:
			if k == "stop":
				var st := stop_by_id(str(e.get("id", "")))
				if not st.is_empty():
					return {"name": str(st["name"]), "xy": xy_of(float(st["lon"]), float(st["lat"])), "t0": float(e["t0"]), "kind": str(st.get("kind", "stop"))}
			if has_rover():
				return {"name": "%s (parked)" % haven_name(), "xy": haven_xy(), "t0": float(e["t0"]), "kind": "rover"}
			return {"name": str(habitat.get("name", "Habitat")), "xy": hab_xy(), "t0": float(e["t0"]), "kind": "hab"}
	return {"name": str(habitat.get("name", "Habitat")), "xy": hab_xy(), "t0": total_s(), "kind": "hab"}


## Mars clock for "now" (no API needed).
func now_clock() -> Dictionary:
	var unix := Time.get_unix_time_from_system()
	var mt := MarsTime.at(unix)
	var lon := site_lon() if not site.is_empty() else 137.4
	return {"unix": unix, "mt": mt, "lmst": MarsTime.lmst(mt, lon), "ltst": MarsTime.ltst(mt, lon),
		"sol": MarsTime.mission_sol(mt, lon, landing_msd()) if not site.is_empty() else 0, "ls": float(mt["ls"])}
