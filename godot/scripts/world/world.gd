class_name MarsWorld
extends Node3D
## The 3D scene: Mars sky and sun from Mars24, the HiRISE terrain, the habitat and vehicles,
## the planned route with flowing chevrons, two astronauts on the timeline, dust and dust devils.
## Two camera rigs (orbit + first-person walker) with smooth transitions between them.

signal ground_clicked(xy: Vector2)
signal ground_double_clicked(xy: Vector2)
signal stop_clicked(id: String)
signal mode_changed(mode: String)
signal manual_taken   # walker left the autopilot (WASD) — the EVA clock was paused
signal object_clicked(item: Dictionary)   # a non-stop label (habitat, PR-2, rover): {id, kind, title, sub, pos}
signal stop_moved(id: String, xy: Vector2)   # a stop's beacon (or label) was dragged to a new spot
signal look_lock_changed(on: bool)

const ORBIT_FOV := 50.0
const WALK_FOV := 72.0
const STOP_COLORS := {"hollow": Color("ffb03b"), "ridge": Color("ff7a3d"), "depot": Color("ffd166"), "outcrop": Color("e76f51"), "contact": Color("ffd92f"), "custom": Color("d27bff")}
const C_SUGGEST := Color("e7298a")
const C_HELI := Color(0.23, 0.84, 0.78, 0.95)
const C_HAB := Color("4fd1ff")
const C_SHELTER := Color("3ddc84")
const C_ROUTE := Color(0.31, 0.82, 1.0, 0.95)
const C_TRAVERSE := Color(1.0, 0.62, 0.26, 0.9)
const C_DRIVE := Color(0.29, 0.87, 0.5, 0.95)

var camera: Camera3D
var env: Environment
var sky_mat: ShaderMaterial
var sun: DirectionalLight3D
var moonlight: DirectionalLight3D
var terrain_mesh: TerrainClipmap
var orbit := OrbitRig.new()
var walker := Walker.new()
var keep_clock := false   # ghost pacer (feature A6): walking by hand does not pause the EVA clock
var mode := "orbit"
var ready_terrain := false
var td: TerrainData

var markers_root: Node3D
var stop_nodes := {}
var hab_node: Node3D
var shelter_nodes: Array = []
var rover_node: Node3D
var relay_nodes: Array = []
var light_nodes: Array = []
var route_mi: MeshInstance3D
var route_mat: ShaderMaterial
var drive_mi: MeshInstance3D
var abort_mi: MeshInstance3D       # the red abort route back to the haven (EVA ABORT)
var way_home_mi: MeshInstance3D    # helmet: the trunk of the ways-home network from where you stand (feature A1)
var way_home_pts := PackedVector2Array()
var abort_route := PackedVector2Array()   # its points (site metres), for the HUD minimap
var abort_s := 0.0                        # metres of it the crew has walked (the autopilot walks it on the EVA clock)
var abort_speed := 0.75                   # m/s: its length over the planner's walk-back time from where it starts
var abort_done := false                   # the crew reached the haven
const AROUND_STEP := 0.15    # m round the wall the next step aims for when walking round a structure (~1.4 m/s)
const HAB_YAW_DEG := -15.0   # the habitat model's turn (rebuild_markers)
## Solid things the crew walks round, not through: {"name", "a", "b" (a core segment in site metres; a == b for a
## circle), "r" (keep-out for a crew member's centre: the model's half-width plus a suit), "side" (the way out
## for someone standing on the core), and for the habitat and PR-2 "door" (where the crew stands to go in or
## come out: the airlock door, the suitports)}. Built with the markers from the models' sizes (models.gd); PR-2's entry
## follows the rover. The walker collides with them by hand too.
var obstacles: Array = []
var _pr_obstacle := -1
var _abort_cum := PackedFloat32Array()    # cumulative length at each of its points
signal abort_arrived                      # the abort walk reached the haven
var pr_node: Node3D                # pressurized rover PR-2 (moves on a rover-assisted EVA)
var pr_home := Vector2.ZERO
var pr_home_yaw := 0.0
var pr_yaw := 0.0
var traverse_mi: MeshInstance3D
var heli_mi: MeshInstance3D          # Ingenuity's flights at their altitude (Jezero)
var heli_ground_mi: MeshInstance3D   # ... and their ground tracks
var sug_root: Node3D                 # SUGGEST STOPS beacons
var rings_mi: MeshInstance3D
var crumbs: MultiMeshInstance3D
var crumb_mat: ShaderMaterial
var crew: Array = []
var dust: GPUParticles3D
var devils: Array = []
var rocks: RockField

var sun_elev := 45.0
var sun_az := 120.0
var daylight := 1.0
var tau := 0.45
var overlay_id := ""
var show_route := true
var show_traverse := true
var show_heli := true
var show_rings := false
var show_labels := true

var _blend := 1.0
var _blend_from := Transform3D()
var _blend_fov := ORBIT_FOV
var _press_pos := Vector2.ZERO
var _press := false
var _dragged := false
var _crew_phase := 0.0
var _buddy := Vector2(INF, INF)   # EV2's position in the helmet view
var _buddy_phase := 0.0
var _buddy_d := -1.0              # EV2's distance along the planned route (autopilot)
var _buddy_vel := Vector2.ZERO    # smoothed velocity (m/s): EV2 faces the way it walks
var _buddy_still := 0.0           # seconds EV2 has stood still (then it turns to look at you)
var _buddy_side := 0.0            # 0..1: stepping aside from the route while working at a stop
var _last_shadow_mode := ""
var _tweens := {}
var label_hit: Callable           # screen point -> label dict ({} = none); set by the UI (Callouts.hit)
var hover_id := ""                # stop / object under the mouse in orbit view ("" = none)
var dragging_stop := ""           # stop being dragged to a new spot (left button held on it)
var _grab_stop := ""              # stop under the left press; becomes dragging_stop once the mouse moves
var _drag_xy := Vector2(INF, INF) # where the dragged stop is now
var _drag_offset := Vector2.ZERO  # beacon foot minus press point, on screen
var _hover_pos := Vector2(-1, -1)  # last mouse position that reached the 3D view
var _motion_pos := Vector2(-2, -2) # last mouse position seen at all (panels included)
var _hover_t := 0.0
var _hover_drawn := ""            # beacon currently drawn highlighted
var _sun_unix := -INF             # Mars clock (unix) the sun was last aimed for
var look_locked := false          # helmet mouse-look lock (F): the cursor is hidden and captured
var _look_hold := false           # right button held in the helmet: captured until it is let go


func _exit_tree() -> void:
	Mission.hold_at_end = false   # a site switch during an abort must not leave the clock holding


func _ready() -> void:
	_make_environment()
	camera = Camera3D.new()
	camera.fov = ORBIT_FOV
	camera.near = 0.5
	camera.far = 260000.0
	add_child(camera)
	camera.current = true
	orbit.picker = _pick
	orbit.ray_fn = func(p: Vector2) -> Array: return [camera.project_ray_origin(p), camera.project_ray_normal(p)]
	markers_root = Node3D.new()
	markers_root.name = "Markers"
	add_child(markers_root)
	_make_dust()
	Quality.apply(get_viewport(), env, sun)
	sun.directional_shadow_max_distance = float(Quality.get_value("shadow_dist_orbit"))
	_shadow_bias(false)
	dust.amount = int(Quality.get_value("dust"))
	Mission.plan_changed.connect(_on_plan_changed)
	Mission.plan_started.connect(func(): _set_route_stale(true))
	Mission.plan_failed.connect(func(_msg: String): _set_route_stale(false))
	Mission.mission_edited.connect(rebuild_markers)
	Mission.selection_changed.connect(_on_selection)
	Mission.time_changed.connect(_on_time)
	Mission.conditions_changed.connect(_on_conditions)


# ------------------------------------------------------------------ environment
func _make_environment() -> void:
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	sky_mat = ShaderMaterial.new()
	sky_mat.shader = load("res://shaders/mars_sky.gdshader")
	sky.sky_material = sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_sky_contribution = 1.0
	env.ambient_light_energy = 0.75
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 1.05
	env.tonemap_white = 6.0
	env.glow_enabled = true
	env.glow_intensity = 0.65
	env.glow_strength = 1.0
	env.glow_bloom = 0.03
	env.glow_hdr_threshold = 1.15
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	env.ssao_enabled = true
	env.ssao_radius = 1.6
	env.ssao_intensity = 1.4
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_EXPONENTIAL
	env.fog_density = 0.000032
	env.fog_light_color = Color(0.78, 0.6, 0.45)
	env.fog_light_energy = 1.0
	env.fog_sun_scatter = 0.25
	env.fog_aerial_perspective = 0.35
	env.fog_sky_affect = 0.0
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.14
	env.adjustment_contrast = 1.14
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 3000.0
	sun.directional_shadow_blend_splits = true
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.6
	sun.light_energy = 2.4
	add_child(sun)
	moonlight = DirectionalLight3D.new()
	moonlight.name = "NightFill"
	moonlight.light_color = Color(0.55, 0.62, 0.85)
	moonlight.light_energy = 0.0
	moonlight.rotation_degrees = Vector3(-50, 30, 0)
	add_child(moonlight)


func _make_dust() -> void:
	dust = GPUParticles3D.new()
	dust.name = "Dust"
	dust.amount = 1400
	dust.lifetime = 9.0
	dust.preprocess = 9.0
	dust.local_coords = false
	dust.visibility_aabb = AABB(Vector3(-80, -30, -80), Vector3(160, 70, 160))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(45, 10, 45)
	pm.direction = Vector3(1.0, 0.05, 0.35)
	pm.spread = 22.0
	pm.initial_velocity_min = 1.5
	pm.initial_velocity_max = 4.5
	pm.gravity = Vector3(0, -0.12, 0)
	pm.scale_min = 0.012
	pm.scale_max = 0.045
	pm.color = Color(0.86, 0.7, 0.54, 0.32)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 1.2
	pm.turbulence_noise_scale = 5.0
	dust.process_material = pm
	var quad := QuadMesh.new()
	var qm := StandardMaterial3D.new()
	qm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	qm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	qm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	qm.vertex_color_use_as_albedo = true
	qm.albedo_texture = Models.soft_dot()
	qm.distance_fade_mode = BaseMaterial3D.DISTANCE_FADE_PIXEL_ALPHA
	qm.distance_fade_min_distance = 1.2
	qm.distance_fade_max_distance = 6.0
	quad.material = qm
	dust.draw_pass_1 = quad
	dust.emitting = false
	add_child(dust)


func _make_devils() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 3:
		var h := rng.randf_range(260.0, 520.0)
		var mi := MeshInstance3D.new()
		var cm := Models.cyl(h * 0.09, h * 0.018, h, 28)
		cm.cap_top = false
		cm.cap_bottom = false
		cm.rings = 12
		mi.mesh = cm
		var sm := ShaderMaterial.new()
		sm.shader = load("res://shaders/dust_devil.gdshader")
		sm.set_shader_parameter("column_height", h)
		sm.set_shader_parameter("speed", rng.randf_range(0.7, 1.3))
		mi.material_override = sm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(mi)
		var ang := rng.randf() * TAU
		var r := rng.randf_range(2200.0, 6500.0)
		devils.append({"node": mi, "mat": sm, "h": h, "xy": Vector2(cos(ang), sin(ang)) * r,
			"vel": Vector2(rng.randf_range(2.0, 5.0), rng.randf_range(-1.5, 1.5))})


# ------------------------------------------------------------------ terrain + content
func setup_terrain() -> void:
	td = Mission.terrain
	terrain_mesh = TerrainClipmap.new()
	terrain_mesh.name = "Terrain"
	terrain_mesh.build(td, Mission.site_texture, Mission.regional_texture, Mission.site_normal)
	add_child(terrain_mesh)
	orbit.td = td
	walker.td = td
	rocks = RockField.new()
	rocks.name = "Rocks"
	rocks.td = td
	rocks.visible = false
	add_child(rocks)
	ready_terrain = true
	_make_devils()
	rebuild_markers()
	rebuild_traverse()
	rebuild_ingenuity()
	rebuild_suggestions()
	var hab := Mission.hab_xy()
	walker.place(hab + Vector2(14, -6), 200.0)
	set_time_unix(Mission.start_unix)


## Opening shot: high above the crater, then a long descent onto the site.
## From orbit down to the EVA: the home view, or `dest` (a camera_state() saved last time).
func cinematic_intro(duration := 7.5, dest := {}) -> void:
	var hab := Mission.hab_xy()
	orbit.target = td.world_at(Vector2(hab.x * 0.3, hab.y * 0.3 - 600.0))
	orbit.dist = 95000.0
	orbit.pitch = deg_to_rad(80.0)
	orbit.yaw = deg_to_rad(-100.0)
	orbit.snap()
	var t := Vector3(float(dest.get("x", NAN)), float(dest.get("y", NAN)), float(dest.get("z", NAN)))
	if t.is_finite() and td.grid.contains_xy(t.x, -t.z, -25000.0):   # within 25 km of the site (regional model)
		t.y = td.h(t.x, -t.z)
		orbit.fly_to(t, clampf(float(dest.get("dist", 1900.0)), 40.0, 60000.0), float(dest.get("yaw", -2.6)),
			clampf(float(dest.get("pitch", 0.47)), deg_to_rad(3.0), deg_to_rad(89.0)), duration)
	else:
		orbit.fly_to(home_target(), 1900.0, deg_to_rad(-150.0), deg_to_rad(27.0), duration)


## The orbit view to remember between runs; from the helmet, a view looking down on where you stand.
func camera_state() -> Dictionary:
	if mode == "walk":
		var p := td.world_at(walker.xy())
		return {"x": p.x, "y": p.y, "z": p.z, "dist": 260.0, "yaw": orbit.yaw, "pitch": deg_to_rad(30.0)}
	var t := orbit.target
	return {"x": t.x, "y": t.y, "z": t.z, "dist": orbit.dist, "yaw": fposmod(orbit.yaw, TAU), "pitch": orbit.pitch}


## Centre of the EVA: between the habitat and the stops.
func home_target() -> Vector3:
	var c := Mission.hab_xy()
	var n := 1
	for s in Mission.stops:
		c += Mission.xy_of(float(s["lon"]), float(s["lat"]))
		n += 1
	c /= float(n)
	return td.world_at(c)


func home_view() -> void:
	orbit.fly_to(home_target(), 1900.0, deg_to_rad(-150.0), deg_to_rad(27.0))


func rebuild_markers() -> void:
	if not ready_terrain:
		return
	for c in markers_root.get_children():
		c.queue_free()
	stop_nodes.clear()
	shelter_nodes.clear()
	pr_node = null
	relay_nodes.clear()
	light_nodes.clear()
	var hab := Mission.hab_xy()
	hab_node = Models.habitat()
	# sunk 0.4 m at its centre, but lifted if need be so the airlock's landing clears the ground there (the model
	# reaches about a metre down everywhere, so the rest never floats)
	var landing := model_to_site(hab, deg_to_rad(HAB_YAW_DEG), 13.4, 0.0)
	hab_node.position = Vector3(hab.x, maxf(td.h(hab.x, hab.y) - 0.4, td.h(landing.x, landing.y) - 0.45), -hab.y)
	hab_node.rotation.y = deg_to_rad(HAB_YAW_DEG)
	markers_root.add_child(hab_node)
	light_nodes.append_array(hab_node.get_meta("lights", []))
	var i := 1
	for s in Mission.stops:
		var kind := str(s.get("kind", "custom"))
		var col: Color = STOP_COLORS.get(kind, STOP_COLORS["custom"])
		var b := Models.beacon(col, 55.0)
		b.position = td.world_at(Mission.xy_of(float(s["lon"]), float(s["lat"])))
		b.set_meta("phase", i * 1.3)
		markers_root.add_child(b)
		stop_nodes[str(s["id"])] = b
		i += 1
	for sh in Mission.site.get("shelters", []):
		var pr := Models.pressurized_rover()
		var p := Mission.xy_of(float(sh["lon"]), float(sh["lat"]))
		pr.position = td.world_at(p, -0.1)
		pr.rotation.y = deg_to_rad(35.0)
		_align_to_ground(pr, p, 3.5)
		markers_root.add_child(pr)
		shelter_nodes.append(pr)
		light_nodes.append_array(pr.get_meta("lights", []))
		if pr_node == null and str(sh.get("kind", "")) == "rover":
			pr_node = pr
			pr_home = p
			pr_home_yaw = pr.rotation.y
			pr_yaw = pr_home_yaw
	for r in Mission.relays:
		var m := Models.relay_mast(float(r.get("height_m", 3.0)))
		m.position = td.world_at(Mission.xy_of(float(r["lon"]), float(r["lat"])))
		markers_root.add_child(m)
		relay_nodes.append(m)
	var rv: Dictionary = Mission.site.get("rover", {})
	if rv.has("latest_lonlat"):
		rover_node = Models.curiosity()
		var ll: Array = rv["latest_lonlat"]
		var p2 := Mission.xy_of(float(ll[0]), float(ll[1]))
		rover_node.position = td.world_at(p2, -0.05)
		rover_node.rotation.y = deg_to_rad(130.0)
		_align_to_ground(rover_node, p2, 1.2)
		markers_root.add_child(rover_node)
	crew = []
	for k in 2:
		var a := Models.astronaut(Color("ff7a3d") if k == 0 else Color("4fd1ff"))
		a.visible = false
		markers_root.add_child(a)
		crew.append(a)
		light_nodes.append_array(a.get_meta("lights", []))
	_build_obstacles()
	_update_marker_rings()
	_apply_lights()
	_on_time(Mission.eva_t)


func _align_to_ground(n: Node3D, p: Vector2, half: float) -> void:
	var hx := td.h(p.x + half, p.y) - td.h(p.x - half, p.y)
	var hy := td.h(p.x, p.y + half) - td.h(p.x, p.y - half)
	n.rotation.x = atan2(-hy, 2.0 * half) * 0.8
	n.rotation.z = atan2(hx, 2.0 * half) * 0.8


func _update_marker_rings() -> void:
	if not terrain_mesh:
		return
	var m := []
	var c := []
	var hab := Mission.hab_xy()
	m.append(Vector4(hab.x, hab.y, 26.0, 0.0))
	c.append(Vector4(C_HAB.r, C_HAB.g, C_HAB.b, 1.2))
	for s in Mission.stops:
		var p := Mission.xy_of(float(s["lon"]), float(s["lat"]))
		if str(s["id"]) == dragging_stop and _drag_xy.is_finite():
			p = _drag_xy
		var col: Color = STOP_COLORS.get(str(s.get("kind", "custom")), STOP_COLORS["custom"])
		m.append(Vector4(p.x, p.y, 14.0, 1.0 if str(s["id"]) == Mission.selected_stop else 0.0))
		c.append(Vector4(col.r, col.g, col.b, 1.4))
	for sh in Mission.site.get("shelters", []):
		var p2 := Mission.xy_of(float(sh["lon"]), float(sh["lat"]))
		if Mission.has_rover() and str(sh.get("kind", "")) == "rover":
			p2 = Mission.haven_xy()
		m.append(Vector4(p2.x, p2.y, 11.0, 0.0))
		c.append(Vector4(C_SHELTER.r, C_SHELTER.g, C_SHELTER.b, 1.0))
	for r in Mission.relays:
		var p3 := Mission.xy_of(float(r["lon"]), float(r["lat"]))
		m.append(Vector4(p3.x, p3.y, 6.0, 0.0))
		c.append(Vector4(0.4, 1.0, 0.7, 1.0))
	while m.size() > 16:
		m.pop_back()
		c.pop_back()
	var n := m.size()
	while m.size() < 16:
		m.append(Vector4.ZERO)
		c.append(Vector4.ZERO)
	terrain_mesh.set_param("markers", m)
	terrain_mesh.set_param("marker_colors", c)
	terrain_mesh.set_param("marker_count", n)


func _on_selection(id: String) -> void:
	_update_marker_rings()
	for k in stop_nodes:
		var b: Node3D = stop_nodes[k]
		var sm: ShaderMaterial = b.get_meta("column_mat")
		sm.set_shader_parameter("selected", 1.0 if k == id else 0.0)


func rebuild_traverse() -> void:
	if traverse_mi:
		traverse_mi.queue_free()
		traverse_mi = null
	var lines := []
	for f in Mission.traverse.get("features", []):
		var g: Dictionary = f.get("geometry", {})
		var parts: Array = []
		if str(g.get("type", "")) == "LineString":
			parts = [g["coordinates"]]
		elif str(g.get("type", "")) == "MultiLineString":
			parts = g["coordinates"]
		for coords in parts:
			var xy := PackedVector2Array()
			for c in coords:
				var p := Mission.xy_of(float(c[0]), float(c[1]))
				if td.grid.contains_xy(p.x, p.y, -200.0):
					xy.append(p)
			if xy.size() > 1:
				lines.append(Ribbon.drape(td, xy, 4.0))
	var mesh := Ribbon.build(lines)
	if mesh == null:
		return
	traverse_mi = MeshInstance3D.new()
	traverse_mi.name = "Traverse"
	traverse_mi.mesh = mesh
	var m := Ribbon.material(C_TRAVERSE, 0.9, 2.2, 1.6, 0.0)
	m.set_shader_parameter("dash_m", 7.0)
	traverse_mi.material_override = m
	traverse_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	traverse_mi.visible = show_traverse
	add_child(traverse_mi)


## Ingenuity's flights (data-use item D5): each path at the flight's top altitude (climbing out of and settling into
## its airfields), with a faint ground track underneath.
func rebuild_ingenuity() -> void:
	for mi in [heli_mi, heli_ground_mi]:
		if mi:
			(mi as Node).queue_free()
	heli_mi = null
	heli_ground_mi = null
	if not ready_terrain:
		return
	var air := []
	var ground := []
	for f in Mission.ingenuity.get("features", []):
		var props: Dictionary = (f as Dictionary).get("properties", {})
		if str(props.get("kind", "")) != "flight":
			continue
		var g: Dictionary = (f as Dictionary).get("geometry", {})
		var xy := PackedVector2Array()
		for c in g.get("coordinates", []):
			var p := Mission.xy_of(float(c[0]), float(c[1]))
			if td.grid.contains_xy(p.x, p.y, -300.0):
				xy.append(p)
		if xy.size() < 2:
			continue
		var d := Ribbon.drape(td, xy, 4.0)
		ground.append(d)
		var alt := maxf(3.0, float(props.get("max_alt_m", 10.0)))
		var up := PackedVector3Array()
		var n := d.size()
		for i in n:
			var k := minf(1.0, minf(float(i), float(n - 1 - i)) / 5.0)
			up.append(d[i] + Vector3(0.0, alt * k, 0.0))
		air.append(up)
	var mesh := Ribbon.build(air)
	if mesh == null:
		return
	heli_mi = MeshInstance3D.new()
	heli_mi.name = "IngenuityFlights"
	heli_mi.mesh = mesh
	var m := Ribbon.material(C_HELI, 0.8, 2.0, 2.2, 0.6)
	m.set_shader_parameter("dash_m", 3.0)
	heli_mi.material_override = m
	heli_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	heli_mi.visible = show_heli
	add_child(heli_mi)
	var gm := Ribbon.build(ground)
	if gm:
		heli_ground_mi = MeshInstance3D.new()
		heli_ground_mi.name = "IngenuityGroundTracks"
		heli_ground_mi.mesh = gm
		heli_ground_mi.material_override = Ribbon.material(Color(C_HELI, 0.35), 0.5, 1.2, 0.6, 0.0)
		heli_ground_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		heli_ground_mi.visible = show_heli
		add_child(heli_ground_mi)


## Beacons for the stops SUGGEST STOPS proposed (pink); their callouts add them to the route when clicked.
func rebuild_suggestions() -> void:
	if sug_root:
		sug_root.queue_free()
		sug_root = null
	if not ready_terrain or Mission.suggestions.is_empty():
		return
	sug_root = Node3D.new()
	sug_root.name = "Suggestions"
	add_child(sug_root)
	for sg in Mission.suggestions:
		var b := Models.beacon(C_SUGGEST, 32.0)
		b.position = td.world_at(Mission.xy_of(float(sg["lon"]), float(sg["lat"])))
		sug_root.add_child(b)


func _on_plan_changed() -> void:
	if not ready_terrain:
		return
	for n in [route_mi, rings_mi, crumbs, drive_mi]:
		if n:
			(n as Node).queue_free()
	route_mi = null
	rings_mi = null
	crumbs = null
	drive_mi = null
	var p: Dictionary = Mission.plan["profile"]
	var xy := PackedVector2Array()
	var lon: Array = p["lon"]
	var lat: Array = p["lat"]
	for i in lon.size():
		var q := Mission.xy_of(float(lon[i]), float(lat[i]))
		if xy.is_empty() or xy[xy.size() - 1].distance_to(q) > 0.05:
			xy.append(q)
	var pts := Ribbon.drape(td, xy, 2.0)
	route_mi = MeshInstance3D.new()
	route_mi.name = "Route"
	route_mi.mesh = Ribbon.build([pts])
	route_mat = Ribbon.material(C_ROUTE, 1.5, 4.0, 2.2, 6.0)
	var ghost := ShaderMaterial.new()
	ghost.shader = Ribbon.xray_shader()
	ghost.set_shader_parameter("color", Color(C_ROUTE.r, C_ROUTE.g, C_ROUTE.b, 0.22))
	ghost.set_shader_parameter("width_m", 1.2)
	ghost.set_shader_parameter("min_px", 2.5)
	ghost.set_shader_parameter("glow", 1.0)
	ghost.set_shader_parameter("hidden_alpha", 1.0)   # shows through ridges too
	route_mat.next_pass = ghost
	route_mi.material_override = route_mat
	route_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	route_mi.visible = show_route
	add_child(route_mi)
	_build_drive()
	_update_marker_rings()
	_build_crumbs(pts)
	_build_rings()
	_on_time(Mission.eva_t)
	var route_len := 0.0
	for i in range(1, pts.size()):
		route_len += Vector2(pts[i].x - pts[i - 1].x, pts[i].z - pts[i - 1].z).length()
	_sweep_in(route_len)


## The materials of everything drawn from the plan: route (and its x-ray pass), PR-2's drive, walk-back rings.
func _plan_materials(route_only := false) -> Array:
	var out: Array = []
	if route_mat:
		out.append(route_mat)
		if route_mat.next_pass:
			out.append(route_mat.next_pass)
	if route_only:
		return out
	for mi in [drive_mi, rings_mi]:
		if mi and (mi as MeshInstance3D).material_override:
			out.append((mi as MeshInstance3D).material_override)
	return out


## While a new plan computes, the route on screen is out of date: it greys out, dims and ripples until
## the answer arrives (or goes back to normal if planning fails).
func _set_route_stale(on: bool) -> void:
	var mats := _plan_materials()
	if mats.is_empty():
		return
	_kill("route_stale")
	var cur: Variant = (mats[0] as ShaderMaterial).get_shader_parameter("stale")
	var from := float(cur) if cur != null else 0.0
	var set_stale := func(v: float) -> void:
		for m in mats:
			(m as ShaderMaterial).set_shader_parameter("stale", v)
	var tw := create_tween()
	_tweens["route_stale"] = tw
	tw.tween_method(set_stale, from, 1.0 if on else 0.0, 0.4)


## A new plan arrived: its route draws itself from the start with a bright leading edge (about 1-2 s),
## while PR-2's drive and the walk-back rings fade in behind it.
func _sweep_in(length: float) -> void:
	_kill("route_sweep")
	var mats := _plan_materials(true)
	if mats.is_empty() or length <= 0.0:
		return
	var fades := _plan_materials().slice(mats.size())
	var dur := clampf(length / 2500.0, 0.9, 2.2)
	var set_reveal := func(v: float) -> void:
		for m in mats:
			(m as ShaderMaterial).set_shader_parameter("reveal_d", v)
	var set_fade := func(v: float) -> void:
		for m in fades:
			(m as ShaderMaterial).set_shader_parameter("opacity", v)
	set_reveal.call(0.0)
	set_fade.call(0.0)
	var tw := create_tween()
	_tweens["route_sweep"] = tw
	tw.set_parallel(true)
	tw.tween_method(set_reveal, 0.0, length + 45.0, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_method(set_fade, 0.0, 1.0, dur * 0.7).set_delay(dur * 0.3)
	tw.chain().tween_callback(func(): set_reveal.call(1.0e9))


## PR-2's drive out and back: a dashed green ribbon (the two drives mostly share one track).
func _build_drive() -> void:
	if not Mission.has_rover():
		return
	var lines := []
	for L in Mission.plan["rover"]["legs"]:
		var xy := PackedVector2Array()
		for c in L["path"]:
			var q := Mission.xy_of(float(c[0]), float(c[1]))
			if xy.is_empty() or xy[xy.size() - 1].distance_to(q) > 0.05:
				xy.append(q)
		if xy.size() > 1:
			lines.append(Ribbon.drape(td, xy, 2.0))
	var mesh := Ribbon.build(lines)
	if mesh == null:
		return
	drive_mi = MeshInstance3D.new()
	drive_mi.name = "RoverDrive"
	drive_mi.mesh = mesh
	var m := Ribbon.material(C_DRIVE, 1.8, 3.6, 2.0, 0.0)
	m.set_shader_parameter("dash_m", 9.0)
	drive_mi.material_override = m
	drive_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	drive_mi.visible = show_route
	add_child(drive_mi)


func _build_crumbs(pts: PackedVector3Array) -> void:
	var tr := []
	var dist := 0.0
	var last := -1e9
	for i in range(1, pts.size()):
		var a := pts[i - 1]
		var b := pts[i]
		dist += Vector2(b.x - a.x, b.z - a.z).length()
		if dist - last < 6.0:
			continue
		last = dist
		var dir := Vector3(b.x - a.x, 0, b.z - a.z).normalized()
		if dir.length_squared() < 0.5:
			continue
		var basis := Basis.looking_at(dir, Vector3.UP)
		tr.append([Transform3D(basis, b + Vector3(0, 0.1, 0)), dist])
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = Models.chevron(0.75)
	mm.instance_count = tr.size()
	for i in tr.size():
		mm.set_instance_transform(i, tr[i][0])
		mm.set_instance_custom_data(i, Color(float(tr[i][1]), 0, 0, 0))
	crumbs = MultiMeshInstance3D.new()
	crumbs.name = "Breadcrumbs"
	crumbs.multimesh = mm
	crumb_mat = ShaderMaterial.new()
	crumb_mat.shader = load("res://shaders/chevron.gdshader")
	crumbs.material_override = crumb_mat
	crumbs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	crumbs.visible = mode == "walk"
	add_child(crumbs)


func _build_rings() -> void:
	var rings: Variant = Mission.plan.get("rings")
	if not (rings is Dictionary):
		return
	var lines := []
	var cols := []
	var palette := {15: Color("3ddc84"), 30: Color("b7e35b"), 45: Color("ffd166"), 60: Color("ffb03b"), 90: Color("ff7a3d"), 120: Color("ff4d5e")}
	for f in (rings as Dictionary).get("features", []):
		var mins := int(f.get("properties", {}).get("minutes", 0))
		var col: Color = palette.get(mins, Color(1, 1, 1))
		var g: Dictionary = f.get("geometry", {})
		var parts: Array = []
		if str(g.get("type", "")) == "LineString":
			parts = [g["coordinates"]]
		elif str(g.get("type", "")) == "MultiLineString":
			parts = g["coordinates"]
		for coords in parts:
			if (coords as Array).size() < 6:
				continue
			var xy := PackedVector2Array()
			for c in coords:
				xy.append(Mission.xy_of(float(c[0]), float(c[1])))
			lines.append(Ribbon.drape(td, xy, 5.0))
			cols.append(col)
	var mesh := Ribbon.build(lines, cols)
	if mesh == null:
		return
	rings_mi = MeshInstance3D.new()
	rings_mi.name = "WalkbackRings"
	rings_mi.mesh = mesh
	var m := Ribbon.material(Color(1, 1, 1, 0.85), 0.8, 2.0, 1.5, 0.0)
	m.set_shader_parameter("use_vertex_color", true)
	rings_mi.material_override = m
	rings_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	rings_mi.visible = show_rings and mode == "orbit"
	add_child(rings_mi)


# ------------------------------------------------------------------ time, sun, lights
func _on_time(t: float) -> void:
	if Mission.start_unix > 0.0:
		set_time_unix(Mission.unix_at(t))
	if route_mat and Mission.has_plan():
		var st := Mission.state_at(t)
		var walked := float(st["d"]) if t > 1.0 else -1.0
		route_mat.set_shader_parameter("progress_d", walked)
		if crumb_mat:
			crumb_mat.set_shader_parameter("walked", walked)


func _on_conditions() -> void:
	var w: Dictionary = Mission.conditions.get("weather", {})
	tau = float(w.get("tau", tau))
	sky_mat.set_shader_parameter("tau", tau)


func set_time_unix(unix: float, force := false) -> void:
	if Mission.site.is_empty():
		return
	# The sun moves about 0.25° per Mars minute. Re-aiming it for every frame of playback re-rendered the
	# sky's radiance map (and re-lit everything) for changes nobody can see: wait for ~40 s of Mars time.
	if not force and absf(unix - _sun_unix) < 40.0:
		return
	_sun_unix = unix
	var mt := MarsTime.at(unix)
	var sp := MarsTime.sun_position(mt, Mission.site_lat(), Mission.site_lon())
	sun_elev = sp.x
	sun_az = sp.y
	var dir := MarsTime.sun_vector(sp.x, sp.y)
	sky_mat.set_shader_parameter("sun_dir", dir)
	var up := Vector3.UP if absf(dir.y) < 0.98 else Vector3.FORWARD
	sun.global_transform = Transform3D(Basis.looking_at(-dir, up), Vector3.ZERO)
	var s := sin(deg_to_rad(sp.x))
	daylight = smoothstep(-0.06, 0.22, s)
	sun.light_energy = 2.1 * smoothstep(-0.02, 0.12, s)
	sun.light_color = Color(1.0, 0.86 + 0.1 * daylight, 0.72 + 0.2 * daylight)
	sun.visible = s > -0.03
	moonlight.light_energy = 0.1 * (1.0 - daylight)
	env.ambient_light_energy = 0.18 + 0.3 * daylight
	env.fog_light_color = _horizon_color(sp.x)
	env.tonemap_exposure = lerpf(1.6, 0.92, daylight)
	_apply_lights()
	var devil_sun := 0.2 + 0.8 * daylight
	for d in devils:
		(d["mat"] as ShaderMaterial).set_shader_parameter("sun", devil_sun)


func _horizon_color(elev_deg: float) -> Color:
	var se := sin(deg_to_rad(elev_deg))
	var day := smoothstep(-0.1, 0.22, se)
	var twi := smoothstep(-0.3, 0.02, se) * (1.0 - smoothstep(0.02, 0.32, se))
	var k := maxf(0.04, maxf(day, twi * 0.5))
	return Color(0.8 * k, 0.62 * k, 0.45 * k)


func _apply_lights() -> void:
	var night := 1.0 - daylight
	for l in light_nodes:
		if not is_instance_valid(l):
			continue
		var light := l as Light3D
		if light is OmniLight3D:
			light.light_energy = 2.2 * night
		elif light is SpotLight3D:
			light.light_energy = 4.0 * night
		light.visible = night > 0.05


# ------------------------------------------------------------------ EV2 and the abort route
## EV2's position in the helmet view (not finite before EV2 has been placed).
func buddy_xy() -> Vector2:
	return _buddy


## The way back to the haven from `from`: steepest descent through the planner's walk-back field (seconds
## to the haven on the 4 m grid), which retraces the planner's own fastest way home around no-go ground.
func abort_path(from: Vector2) -> PackedVector2Array:
	var pts := PackedVector2Array([from])
	var haven := Mission.haven_xy()
	var p := from
	var v := td.layer_value("walkback", p.x, p.y, -1.0)
	if v >= 0.0:
		var dirs := [Vector2(4, 0), Vector2(-4, 0), Vector2(0, 4), Vector2(0, -4), Vector2(4, 4), Vector2(-4, 4), Vector2(4, -4), Vector2(-4, -4)]
		for i in 4000:
			if v <= 6.0 or p.distance_to(haven) < 8.0:
				break
			var best := v
			var best_p := p
			for dv in dirs:
				var q: Vector2 = p + (dv as Vector2)
				var w := td.layer_value("walkback", q.x, q.y, -1.0)
				if w >= 0.0 and w < best:
					best = w
					best_p = q
			if best_p == p:
				break   # a flat spot in the field: finish straight at the haven
			p = best_p
			v = best
			if pts[pts.size() - 1].distance_to(p) >= 12.0:
				pts.append(p)
	pts.append(haven)
	return route_around_structures(pts)


## A route kept out of the structures by walking it with the crew's own rule (outside_structures), so the red ribbon,
## its length and the walk along it go round the habitat, its solar field and the rovers, and a route ending at
## the haven's centre point ends at its door.
func route_around_structures(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 2 or obstacles.is_empty():
		return pts
	var p := outside_structures(pts[0], pts[0], false)
	var out := PackedVector2Array([p])
	var last_dir := Vector2.ZERO   # the way the route went at the last point kept
	var guard := 0
	for i in range(1, pts.size()):
		var goal := outside_structures(pts[i], p, false)   # where the crew can stand for this point
		while p.distance_to(goal) > 0.05 and guard < 20000:
			guard += 1
			var q := p.move_toward(outside_structures(goal, p), 1.0)
			if q.distance_to(p) < 1e-4:
				break
			var d := (q - p).normalized()
			p = q
			# keep a point where the way turns (tight round a wall) and every 12 m on the straight
			var since := p.distance_to(out[out.size() - 1])
			if last_dir == Vector2.ZERO:
				last_dir = d
			elif since >= 12.0 or (since >= 0.3 and absf(d.angle_to(last_dir)) > deg_to_rad(4.0)):
				out.append(p)
				last_dir = d
	if out[out.size() - 1].distance_to(p) > 0.05:
		out.append(p)
	return out


func abort_active() -> bool:
	return abort_route.size() >= 2


func abort_length() -> float:
	return _abort_cum[_abort_cum.size() - 1] if _abort_cum.size() > 0 else 0.0


## The point s metres along the abort route.
func abort_xy(s: float) -> Vector2:
	var n := abort_route.size()
	if n == 0:
		return Vector2.ZERO
	if s <= 0.0:
		return abort_route[0]
	for i in range(1, n):
		if _abort_cum[i] >= s:
			var seg := _abort_cum[i] - _abort_cum[i - 1]
			var f := (s - _abort_cum[i - 1]) / seg if seg > 1e-6 else 1.0
			return abort_route[i - 1].lerp(abort_route[i], f)
	return abort_route[n - 1]


## How far along the abort route its point nearest to p lies (to rejoin it after walking by hand).
func abort_nearest_s(p: Vector2) -> float:
	var best := 0.0
	var best_d := INF
	for i in range(1, abort_route.size()):
		var a := abort_route[i - 1]
		var ab := abort_route[i] - a
		var l2 := ab.length_squared()
		var f := clampf((p - a).dot(ab) / l2, 0.0, 1.0) if l2 > 1e-9 else 0.0
		var dd := (a + ab * f).distance_to(p)
		if dd < best_d:
			best_d = dd
			best = _abort_cum[i - 1] + f * sqrt(l2)
	return best


## Where the crew is on the abort walk, shaped like Mission.state_at() for the walker's autopilot.
func abort_state() -> Dictionary:
	# home: face the haven (the route's last metres run along its wall to the door)
	return {"xy": abort_xy(abort_s), "xy_ahead": Mission.haven_xy() if abort_done else abort_xy(abort_s + 6.0), "d": abort_s,
		"phase": "stop" if abort_done else "walk"}


## A point of a model (its own x and z, metres) on the site, for a model at `origin` turned by `yaw` (rotation.y).
static func model_to_site(origin: Vector2, yaw: float, mx: float, mz: float) -> Vector2:
	return origin + Vector2(mx * cos(yaw) + mz * sin(yaw), mx * sin(yaw) - mz * cos(yaw))


func _add_obstacle(name: String, a: Vector2, b: Vector2, r: float, side: Vector2, door := Vector2.INF) -> int:
	var o := {"name": name, "a": a, "b": b, "r": r, "side": side.normalized()}
	if door.is_finite():
		o["door"] = door
	obstacles.append(o)
	return obstacles.size() - 1


## PR-2 (models.gd pressurized_rover(): 7 m long with the cab, 3.7 m across the wheels): a capsule along its heading,
## and the way out behind it, at the suitports.
func _rover_capsule(i: int, at: Vector2, yaw: float) -> void:
	var o: Dictionary = obstacles[i]
	o["a"] = model_to_site(at, yaw, -1.6, 0.0)
	o["b"] = model_to_site(at, yaw, 2.0, 0.0)
	o["side"] = Vector2(-cos(yaw), -sin(yaw))
	o["door"] = model_to_site(at, yaw, -5.4, 0.0)   # 2 m behind its suitports (x -3.4)


## The habitat model (models.gd habitat(), turned by HAB_YAW_DEG) at `hab`: two capsules that do not touch.
func add_habitat_obstacles(hab: Vector2) -> void:
	var yaw := deg_to_rad(HAB_YAW_DEG)
	var door := model_to_site(hab, yaw, 1.0, 0.0) - hab
	# the main module (base 12.8 m) and the science module (6.6 m, at x -15 z 6) as one capsule; the crew goes in
	# and out by the airlock door (x 12.66), standing 3 m in front of it
	_add_obstacle("habitat", hab, model_to_site(hab, yaw, -8.6, 3.44), 13.2, door, model_to_site(hab, yaw, 15.6, 0.0))
	# the solar field: two rows of panels at chest height, x -16.3..14.3, z 17.7..24.9 (0.7-4 m clear of the habitat's)
	_add_obstacle("solar field", model_to_site(hab, yaw, -12.7, 21.3), model_to_site(hab, yaw, 10.7, 21.3), 4.0,
		model_to_site(hab, yaw, 0.0, 1.0) - hab)


func _build_obstacles() -> void:
	obstacles.clear()
	_pr_obstacle = -1
	add_habitat_obstacles(Mission.hab_xy())
	for k in shelter_nodes.size():
		var n: Node3D = shelter_nodes[k]
		var at := Vector2(n.position.x, -n.position.z)
		var i := _add_obstacle("PR-2", at, at, 2.3, Vector2.RIGHT)
		_rover_capsule(i, at, n.rotation.y)
		if n == pr_node:
			_pr_obstacle = i
	if rover_node:
		var c := Vector2(rover_node.position.x, -rover_node.position.z)
		_add_obstacle("Curiosity", c, c, 2.1, Vector2.RIGHT)
	walker.structures = obstacles


## The nearest point of an obstacle's core to q.
static func _core_pt(o: Dictionary, q: Vector2) -> Vector2:
	var a: Vector2 = o["a"]
	var b: Vector2 = o["b"]
	return a if a.distance_squared_to(b) < 1e-6 else Geometry2D.get_closest_point_to_segment(q, a, b)


## Where the crew stands to go into the haven: the habitat's airlock door, or PR-2's suitports on a rover-assisted
## EVA (before the models are built, the haven's centre point).
func haven_door() -> Vector2:
	var i := _pr_obstacle if Mission.has_rover() else 0
	if i < 0 or i >= obstacles.size() or not (obstacles[i] as Dictionary).has("door"):
		return Mission.haven_xy()
	return obstacles[i]["door"]


## How far q is outside the nearest structure's keep-out, in metres (negative: inside one).
func structure_clearance(q: Vector2) -> float:
	var best := INF
	for o in obstacles:
		best = minf(best, q.distance_to(_core_pt(o, q)) - float(o["r"]))
	return best


## Routes start and end at the habitat's (or the parked rover's) centre point, and the planner knows nothing of
## the models. For someone at `from` heading for `p`: a target inside the habitat or a rover becomes its door (the
## airlock, the suitports: where the airlock phases, the end of a walk and of an abort happen), one inside the
## solar field the point on its edge nearest to them; and (`around`) when the straight way to the target cuts through one, the next step aims a little
## further round its wall instead (step by step, at a walk), so nobody walks through the habitat, its solar
## field or a rover. Structures never overlap; a step round one that would go into another is pushed back out.
## Checked headless by tests/structures_check.gd (576 walks all round the habitat).
func outside_structures(p: Vector2, from: Vector2, around := true, beside := 0.0) -> Vector2:
	for o in obstacles:
		var r: float = o["r"]
		var kp := _core_pt(o, p)
		var dp := p.distance_to(kp)
		if dp < r:
			if dp > r - 1.0:   # just inside (a route grazing it): onto its wall right there
				p = kp + (p - kp) / dp * r
				continue
			if o.has("door"):   # the habitat or a rover: its way in (EV2 `beside` you, to one side of it)
				var sd: Vector2 = o["side"]
				p = (o["door"] as Vector2) + Vector2(-sd.y, sd.x) * beside
				continue
			var kf := _core_pt(o, from)
			var dir := from - kf
			if dir.length() < 0.3:
				dir = o["side"]
			p = kf + dir.normalized() * r
	if not around or structure_clearance(from) < -1.0:
		return p   # (someone inside a model walks straight out)
	# the structure in the way first (the straight line may cut several: go round the nearest one first)
	var hit: Dictionary = {}
	var hit_at := INF
	for o in obstacles:
		var r: float = o["r"]
		var a: Vector2 = o["a"]
		var b: Vector2 = o["b"]
		var gap: float
		var near: Vector2   # the point of the way that passes closest to the structure's core
		if a.distance_squared_to(b) < 1e-6:
			near = Geometry2D.get_closest_point_to_segment(a, from, p)
			gap = near.distance_to(a)
		else:
			var cross: Variant = Geometry2D.segment_intersects_segment(from, p, a, b)
			var cp := Geometry2D.get_closest_points_between_segments(from, p, a, b)
			near = cross if cross != null else cp[0]
			gap = 0.0 if cross != null else cp[0].distance_to(cp[1])
		if gap < r - 0.05 and from.distance_to(near) < hit_at:
			hit = o
			hit_at = from.distance_to(near)
	if hit.is_empty():
		return p
	var o := hit
	var r: float = o["r"]
	var a: Vector2 = o["a"]
	var b: Vector2 = o["b"]
	var kf := _core_pt(o, from)
	if from.distance_to(kf) > r + 1.5:
		# still well clear of it: straight on to where the way meets its wall (0.5 m out), and round it from there
		var lo := 0.0
		var hi := clampf(hit_at / maxf(from.distance_to(p), 1e-6), 0.0, 1.0)
		for k in 24:
			var mt := (lo + hi) * 0.5
			var q := from.lerp(p, mt)
			if q.distance_to(_core_pt(o, q)) > r + 0.5:
				lo = mt
			else:
				hi = mt
		return from.lerp(p, lo)
	var n := from - kf
	n = n.normalized() if n.length() > 0.3 else (o["side"] as Vector2)
	# round the short way: the turn about the structure's middle from you to the target sets the direction,
	# and it stays the same as you go (aiming along the wall at the target would dither when the target is
	# straight across a long wall, like the solar field's)
	var mid: Vector2 = (a + b) * 0.5
	var turn := wrapf((p - mid).angle() - (from - mid).angle(), -PI, PI)
	var t := Vector2(-n.y, n.x) if turn >= 0.0 else Vector2(n.y, -n.x)
	var step := AROUND_STEP * clampf(Mission.play_speed() if Mission.playing else 1.0, 1.0, 8.0)   # faster playback, faster walk
	var q := from + t * step
	var kq := _core_pt(o, q)
	# along the wall, closing in on it as fast as going round (from further out you spiral in to hug it)
	return _clear_of_others(kq + (q - kq).normalized() * maxf(r, from.distance_to(kf) - step), o)


## q moved out of every structure but `skip`, along each one's own normal: in the gap between two structures
## (0.7 m at its narrowest, between the habitat's science module and the solar field) a step round one must not
## go into the other. They never overlap, so a point on one's wall is clear of the rest.
func _clear_of_others(q: Vector2, skip: Dictionary) -> Vector2:
	for o in obstacles:
		if is_same(o, skip):
			continue
		var k := _core_pt(o, q)
		var r: float = o["r"]
		var d := q.distance_to(k)
		if d < r:
			q = k + ((q - k) / d if d > 1e-4 else (o["side"] as Vector2)) * r
	return q


## The crew's position: the walker in the helmet view; in orbit, the abort walk or the plan.
func crew_xy() -> Vector2:
	if mode == "walk":
		return walker.xy()
	if abort_active():
		return abort_xy(abort_s)
	return Mission.state_at(Mission.eva_t)["xy"] if Mission.has_plan() else Mission.hab_xy()


## The autopilot walks the abort route home at the walk-back pace, on the EVA clock (paused clock: no walking;
## walking by hand: you do the walking).
func _advance_abort(delta: float) -> void:
	if not abort_active() or abort_done:
		return
	if mode == "walk":
		# the helmet view: home when you are at the door yourself, by hand or on autopilot (which trails the
		# route's point a little, far more at high playback speeds: the clock keeps running till you are in)
		if walker.autopilot and Mission.playing:
			abort_s = minf(abort_length(), abort_s + abort_speed * Mission.play_speed() * delta)
		if walker.xy().distance_to(abort_route[abort_route.size() - 1]) > 1.5:
			return
	else:
		if not Mission.playing:
			return
		abort_s = minf(abort_length(), abort_s + abort_speed * Mission.play_speed() * delta)
		if abort_s < abort_length() - 0.01:   # the route ends at the haven's door (route_around_structures)
			return
	abort_s = abort_length()
	abort_done = true
	Mission.hold_at_end = false
	abort_arrived.emit()


## Show (or with an empty array, remove) the abort route: a red ribbon flowing towards the haven.
func set_abort_route(pts: PackedVector2Array) -> void:
	abort_route = pts
	_abort_cum = PackedFloat32Array()
	var acc := 0.0
	for i in pts.size():
		if i > 0:
			acc += pts[i - 1].distance_to(pts[i])
		_abort_cum.append(acc)
	abort_s = 0.0
	abort_done = pts.size() >= 2 and acc < 1.0   # already at the door
	Mission.hold_at_end = pts.size() >= 2 and not abort_done   # the clock must not stop (or rewind) before they are home
	if abort_mi:
		abort_mi.queue_free()
		abort_mi = null
	if pts.size() < 2:
		return
	var mesh := Ribbon.build([Ribbon.drape(td, pts, 2.0)])
	if mesh == null:
		return
	abort_mi = MeshInstance3D.new()
	abort_mi.name = "AbortRoute"
	abort_mi.mesh = mesh
	var am := Ribbon.material(Color(1.0, 0.27, 0.22, 0.95), 0.9, 4.5, 2.4, 10.0)
	am.set_shader_parameter("near_fade", 14.0)   # at your feet in the helmet it fades instead of filling the view
	am.set_shader_parameter("hidden_alpha", 0.35)   # and shows faintly through ridges, like the route's x-ray pass
	abort_mi.material_override = am
	abort_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(abort_mi)


# ------------------------------------------------------------------ overlays & effects
## Drape an analysis layer at `opacity` (the LAYERS slider's value for that layer).
func set_overlay(layer_id: String, tex: Texture2D, origin_xy: Vector2, opacity := 0.85) -> void:
	overlay_id = layer_id
	_kill("overlay")
	var tw := create_tween()
	_tweens["overlay"] = tw
	if tex == null:
		tw.tween_method(func(v): terrain_mesh.set_param("overlay_opacity", v), _param("overlay_opacity"), 0.0, 0.5)
		return
	terrain_mesh.set_param("overlay_tex", tex)
	terrain_mesh.set_param("overlay_origin", origin_xy)
	terrain_mesh.set_param("overlay_opacity", opacity)
	# fast start: the ground around you is covered at once, the ring then sweeps out to the horizon
	tw.tween_method(func(v): terrain_mesh.set_param("overlay_reveal", v), 0.0, 4800.0, 0.9).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): terrain_mesh.set_param("overlay_reveal", 1.0e9))


## Ways home (feature A1): the data picture that makes pulses run down the network toward the haven (null = off).
func set_flow(tex: Texture2D) -> void:
	if tex == null:
		_tween_param("flow_strength", 0.0, 0.4)
		return
	terrain_mesh.set_param("flow_tex", tex)
	_tween_param("flow_strength", 1.0, 0.9)


## Helmet: a faint line along the fastest way home from where you stand ("lost? walk downstream").
## An empty array removes it.
func set_way_home(pts: PackedVector2Array) -> void:
	way_home_pts = pts
	if way_home_mi:
		way_home_mi.queue_free()
		way_home_mi = null
	if pts.size() < 2:
		return
	var mesh := Ribbon.build([Ribbon.drape(td, pts, 2.0)])
	if mesh == null:
		return
	way_home_mi = MeshInstance3D.new()
	way_home_mi.name = "WayHome"
	way_home_mi.mesh = mesh
	var m := Ribbon.material(Color(1.0, 0.96, 0.88, 0.55), 0.45, 2.0, 1.4, 4.0)
	m.set_shader_parameter("near_fade", 6.0)
	m.set_shader_parameter("hidden_alpha", 0.2)
	way_home_mi.material_override = m
	way_home_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(way_home_mi)


## Same layer, new numbers (e.g. walk-back after the haven moved): swap the picture, keep opacity, no sweep.
func swap_overlay(layer_id: String, tex: Texture2D) -> void:
	if layer_id != overlay_id or tex == null:
		return
	terrain_mesh.set_param("overlay_tex", tex)


func set_overlay_opacity(v: float) -> void:
	terrain_mesh.set_param("overlay_opacity", v)


func _param(name: String) -> float:
	var v: Variant = terrain_mesh.material.get_shader_parameter(name)
	return float(v) if v != null else 0.0


func set_contours(on: bool) -> void:
	_tween_param("contour_strength", 1.0 if on else 0.0, 0.6)


func set_grid(on: bool) -> void:
	_tween_param("grid_strength", 1.0 if on else 0.0, 0.6)


func _tween_param(name: String, to: float, dur: float) -> void:
	_kill(name)
	var tw := create_tween()
	_tweens[name] = tw
	tw.tween_method(func(v): terrain_mesh.set_param(name, v), _param(name), to, dur)


func _kill(key: String) -> void:
	var t: Tween = _tweens.get(key)
	if t and t.is_valid():
		t.kill()


func scan_pulse(origin_xy: Vector2) -> void:
	_kill("scan")
	terrain_mesh.set_param("scan_origin", origin_xy)
	var tw := create_tween()
	_tweens["scan"] = tw
	tw.tween_method(func(v): terrain_mesh.set_param("scan_radius", v), 1.0, 2800.0, 3.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	tw.tween_callback(func(): terrain_mesh.set_param("scan_radius", -1.0))
	Sfx.play("scan", -4.0)


func set_layer_visible(what: String, on: bool) -> void:
	match what:
		"route":
			show_route = on
			if route_mi:
				route_mi.visible = on
			if drive_mi:
				drive_mi.visible = on
		"traverse":
			show_traverse = on
			if traverse_mi:
				traverse_mi.visible = on
		"ingenuity":
			show_heli = on
			if heli_mi:
				heli_mi.visible = on
			if heli_ground_mi:
				heli_ground_mi.visible = on
		"rings":
			show_rings = on
			if rings_mi:
				rings_mi.visible = on and mode == "orbit"
		"labels":
			show_labels = on
		"dust":
			for d in devils:
				(d["node"] as Node3D).visible = on


# ------------------------------------------------------------------ modes
func enter_walk() -> void:
	if mode == "walk" or not ready_terrain:
		return
	_blend_from = camera.global_transform
	_blend_fov = camera.fov
	_blend = 0.0
	mode = "walk"
	var st := Mission.state_at(Mission.eva_t)
	if abort_active():
		st = abort_state()   # an abort walk under way: you are on the red route home, not where the plan would be now
	var start: Vector2 = st["xy"] if Mission.has_plan() else Mission.hab_xy() + Vector2(14, -6)
	start = outside_structures(start, start)   # at T+0 the plan's point is the habitat's centre: start at its wall
	var ahead: Vector2 = st.get("xy_ahead", start + Vector2(0, 5))
	walker.place(start, Geo.bearing_deg(start, ahead) if ahead.distance_to(start) > 0.3 else 200.0)
	walker.autopilot = Mission.has_plan()
	_buddy = Vector2(INF, INF)
	_buddy_d = -1.0
	_buddy_vel = Vector2.ZERO
	_buddy_still = 0.0
	_buddy_side = 0.0
	_update_hover()   # mode is "walk" now: clears the orbit-view hover highlight
	terrain_mesh.walk_mode = true
	sun.directional_shadow_max_distance = float(Quality.get_value("shadow_dist_walk"))
	_shadow_bias(true)
	camera.near = 0.05
	_style_lines(true)
	rocks.visible = true
	rocks.update_around(walker.xy())
	if crumbs:
		crumbs.visible = true
	if rings_mi:
		rings_mi.visible = false
	dust.emitting = true
	mode_changed.emit(mode)


func exit_walk() -> void:
	if mode != "walk":
		return
	set_look_lock(false)
	_blend_from = camera.global_transform
	_blend_fov = camera.fov
	_blend = 0.0
	mode = "orbit"
	var p := Vector3(walker.x, walker.feet, -walker.y)
	orbit.target = p
	orbit.dist = 160.0
	orbit.pitch = deg_to_rad(26.0)
	orbit.yaw = walker.yaw + PI
	orbit.snap()
	orbit.fly_to(p, 420.0, orbit.yaw, deg_to_rad(30.0), 2.0)
	terrain_mesh.walk_mode = false
	sun.directional_shadow_max_distance = float(Quality.get_value("shadow_dist_orbit"))
	_shadow_bias(false)
	camera.near = 0.5
	_style_lines(false)
	rocks.visible = false
	if crumbs:
		crumbs.visible = false
	if rings_mi:
		rings_mi.visible = show_rings
	dust.emitting = false
	mode_changed.emit(mode)


## Route and traverse are bold in orbit view, subtle at ground level (chevrons lead the way there).
func _style_lines(walk: bool) -> void:
	if route_mat:
		route_mat.set_shader_parameter("width_m", 0.45 if walk else 1.5)
		route_mat.set_shader_parameter("min_px", 1.5 if walk else 4.0)
		route_mat.set_shader_parameter("glow", 0.95 if walk else 2.2)
		route_mat.set_shader_parameter("opacity", 0.5 if walk else 1.0)
		route_mat.set_shader_parameter("lift", 0.06 if walk else 0.35)
		route_mat.set_shader_parameter("near_fade", 16.0 if walk else 0.0)
		var g := route_mat.next_pass as ShaderMaterial
		if g:
			g.set_shader_parameter("opacity", 0.0 if walk else 1.0)
	if traverse_mi:
		var tm := traverse_mi.material_override as ShaderMaterial
		tm.set_shader_parameter("width_m", 0.25 if walk else 0.9)
		tm.set_shader_parameter("min_px", 1.0 if walk else 2.2)
		tm.set_shader_parameter("glow", 0.7 if walk else 1.6)
		tm.set_shader_parameter("opacity", 0.3 if walk else 1.0)
		tm.set_shader_parameter("lift", 0.05 if walk else 0.35)
		tm.set_shader_parameter("near_fade", 12.0 if walk else 0.0)


## Shadow bias per view. Orbit view looks at terrain whose far heights are filtered to the mesh spacing
## (smooth, gently sloped), seen through coarse shadow texels: grazing back slopes self-shadowed in
## stripes (acne) at the helmet's tight bias. The helmet keeps it, so contact shadows stay attached.
func _shadow_bias(walk: bool) -> void:
	sun.shadow_bias = 0.06 if walk else 0.12
	sun.shadow_normal_bias = 1.6 if walk else 3.2


## Mouse-look lock in the helmet: the cursor is hidden and every mouse move turns your head.
func set_look_lock(on: bool) -> void:
	look_locked = on and mode == "walk"
	_look_hold = false
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if look_locked else Input.MOUSE_MODE_VISIBLE
	look_lock_changed.emit(look_locked)


## Turn the autopilot on or off. Turning it on rejoins the route at the point nearest to you.
func toggle_autopilot() -> void:
	if walker.autopilot:
		walker.autopilot = false
		if Mission.playing:
			Mission.set_playing(false)
		manual_taken.emit()
	else:
		rejoin_route()
	Sfx.play("toggle")


## Move the EVA clock to the route point closest to where you stand, then follow the plan from there.
## During an abort: pick up the red route home where it passes closest, and walk it.
func rejoin_route() -> void:
	walker.autopilot = true
	if abort_active():
		abort_s = abort_nearest_s(walker.xy())   # (at the door, _advance_abort completes it this frame)
		Mission.hold_at_end = not abort_done
		if not abort_done and not Mission.playing:
			Mission.set_playing(true)
		return
	if not Mission.has_plan():
		return
	var p: Dictionary = Mission.plan["profile"]
	var lon: Array = p["lon"]
	var lat: Array = p["lat"]
	var ts: Array = p["t"]
	var me := walker.xy()
	var best := -1
	var best_d := INF
	for i in lon.size():
		var d := Mission.xy_of(float(lon[i]), float(lat[i])).distance_to(me)
		if d < best_d:
			best_d = d
			best = i
	if best >= 0 and best_d < 250.0:
		Mission.set_time(float(ts[best]))


func focus_xy(xy: Vector2, dist := 320.0) -> void:
	if mode == "walk":
		return
	orbit.fly_to(td.world_at(xy), dist, orbit.yaw, deg_to_rad(34.0))


# ------------------------------------------------------------------ frame
func _process(delta: float) -> void:
	# metres per screen pixel per metre of distance, for the ribbons' minimum width (ribbon.gdshader)
	RenderingServer.global_shader_parameter_set("ribbon_px_k", 2.0 * tan(deg_to_rad(camera.fov) * 0.5) / maxf(1.0, float(get_window().size.y)))
	if not ready_terrain:
		return
	var xf: Transform3D
	var target_fov := ORBIT_FOV
	_advance_abort(delta)
	if mode == "walk":
		var st := Mission.state_at(Mission.eva_t) if Mission.has_plan() else {}
		var ui_focus := get_viewport().gui_get_focus_owner() != null
		var was_auto := walker.autopilot
		var stick := Input.get_vector("look_left", "look_right", "look_up", "look_down")
		if stick != Vector2.ZERO and not ui_focus:
			walker.look(stick * delta * 900.0)   # gamepad right stick: ~2 rad/s at full tilt
		var auto_target: Dictionary = (abort_state() if abort_active() else st).duplicate()   # an abort: the autopilot walks home
		if auto_target.has("xy") and not bool(auto_target.get("ride", false)):   # stay outside the habitat and the parked rover
			var me := walker.xy()
			auto_target["xy"] = outside_structures(auto_target["xy"], me)   # (where you look stays: a building is fine)
		xf = walker.update(delta, auto_target if Mission.has_plan() else {}, not ui_focus)
		if was_auto and not walker.autopilot:
			if Mission.playing and not keep_clock:
				Mission.set_playing(false)
			manual_taken.emit()
		target_fov = Settings.walk_fov
		if walker.stepped:
			Sfx.play("step", -14.0, randf_range(0.85, 1.15))
		if walker.consume_jump_sound():
			Sfx.play("whoosh", -12.0, 1.6)
	else:
		if get_viewport().gui_get_focus_owner() == null:
			orbit.keyboard(delta)
		xf = orbit.update(delta)
		_hover_t += delta
		if _hover_t > 0.05:
			_hover_t = 0.0
			_update_hover()
	if _blend < 1.0:
		_blend = minf(1.0, _blend + delta / 1.9)
		var e := _ease_in_out(_blend)
		var a := _blend_from.origin
		var b := xf.origin
		var mid := a.lerp(b, e)
		mid.y += sin(PI * e) * minf(120.0, a.distance_to(b) * 0.15)
		xf = Transform3D(_blend_from.basis.slerp(xf.basis, e), mid)
		camera.fov = lerpf(_blend_fov, target_fov, e)
	else:
		camera.fov = lerpf(camera.fov, target_fov, minf(1.0, delta * 4.0))
	camera.global_transform = xf
	var cp := camera.global_position
	terrain_mesh.follow(cp, td.h(cp.x, -cp.z))
	_update_crew(delta)
	_update_pr(delta)
	_animate_markers(delta)
	_update_devils(delta)
	if dust.emitting:
		dust.global_position = cp + Vector3(0, -2, 0)
	if mode == "walk":
		rocks.update_around(walker.xy())


func _ease_in_out(x: float) -> float:
	return 4.0 * x * x * x if x < 0.5 else 1.0 - pow(-2.0 * x + 2.0, 3.0) / 2.0


func _update_crew(delta: float) -> void:
	if crew.size() < 2:
		return
	var has := Mission.has_plan()
	var st := Mission.state_at(Mission.eva_t) if has else {}
	var phase := str(st.get("phase", ""))
	var walking := (phase == "walk" or (abort_active() and not abort_done)) and Mission.playing
	if walking:
		_crew_phase += delta * clampf(Mission.play_speed() * 0.8, 3.0, 9.0)
	for k in 2:
		var a: Node3D = crew[k]
		if mode == "walk":
			a.visible = k == 1 and not bool(st.get("in_cabin", false))
			if a.visible:
				_update_buddy(delta, a, st)
			continue
		if abort_active():   # both walk the red route home, EV2 a few metres ahead
			var sa := abort_s + (0.0 if k == 0 else 4.0)
			var prev := Vector2(a.position.x, -a.position.z)
			var qa := outside_structures(abort_xy(sa), prev, false, 0.0 if k == 0 else 2.0)
			var qa2 := outside_structures(abort_xy(sa + 3.0), prev, false, 0.0 if k == 0 else 2.0)
			a.visible = true
			a.position = td.world_at(qa)
			if qa2.distance_to(qa) > 0.2:
				a.rotation.y = -atan2(qa2.x - qa.x, qa2.y - qa.y)
			Models.animate_astronaut(a, _crew_phase + k * 1.7, 1.0 if walking else 0.0)
			continue
		var show := has and phase != "egress" and phase != "ingress" and phase != "" and not bool(st.get("in_cabin", false))
		a.visible = show
		if not show:
			continue
		var d := maxf(float(st["d"]) + (-5.0 if k == 0 else 0.0), 0.0)
		var q := Mission.route_xy(d)
		var q2 := Mission.route_xy(d + 3.0)
		if phase == "stop":
			q += Vector2(2.0, 1.2) * (1.0 if k == 0 else -1.0)
		a.position = td.world_at(q)
		if q2.distance_to(q) > 0.2:
			a.rotation.y = -atan2(q2.x - q.x, q2.y - q.y)
		Models.animate_astronaut(a, _crew_phase + k * 1.7, 1.0 if walking else 0.0)


## PR-2 stands at its parking spot, or (rover-assisted EVA) drives the crew out to the drop-off and back.
func _update_pr(delta: float) -> void:
	if pr_node == null or not is_instance_valid(pr_node):
		return
	var p := pr_home
	if Mission.has_rover():
		var rs := Mission.rover_state(Mission.eva_t)
		p = rs["xy"]
		if bool(rs["moving"]):
			var ah: Vector2 = rs["xy_ahead"]
			pr_yaw = lerp_angle(pr_yaw, atan2(ah.y - p.y, ah.x - p.x), minf(1.0, delta * 4.0))
	else:
		pr_yaw = pr_home_yaw
	pr_node.position = td.world_at(p, -0.1)
	pr_node.rotation.y = pr_yaw
	_align_to_ground(pr_node, p, 3.5)
	if _pr_obstacle >= 0 and _pr_obstacle < obstacles.size():
		_rover_capsule(_pr_obstacle, p, pr_yaw)


## EV2 in the helmet view. On autopilot it walks the planned route a few metres ahead of you; when you
## walk by hand it keeps pace ahead-left of you, where you can see it. It always faces the way it is
## walking and only turns to look at you after standing still for a moment. (It used to stop and turn
## round every time it caught up with its target, which flickered back and forth while walking.)
func _update_buddy(delta: float, a: Node3D, st: Dictionary) -> void:
	var me := walker.xy()
	var want: Vector2
	if abort_active() and walker.autopilot:
		_buddy_d = -1.0   # an abort: EV2 leads the way home along the red route, 5 m ahead of where you are
		_buddy_side = 0.0   # (not of the clock's point: at high playback speeds you trail that by 100 m or more)
		var ahead := abort_xy(minf(abort_nearest_s(me) + 5.0, abort_length()))
		want = me + (ahead - me).limit_length(5.0)   # and beside you while you go round a structure off the route
	elif walker.autopilot and Mission.has_plan():
		var p: Dictionary = Mission.plan["profile"]
		var ds: Array = p["d"]
		var end_d := float(ds[ds.size() - 1])
		# 6 m ahead of where you actually are (you trail the plan a little at high playback speeds)
		var here: Vector2 = st.get("xy", me)
		var my_d := float(st.get("d", 0.0)) - minf(me.distance_to(here), 60.0)
		var target_d := clampf(my_d + 6.0, 0.0, end_d)
		if _buddy_d < 0.0 or absf(target_d - _buddy_d) > 60.0:
			_buddy_d = target_d   # first frame, or the timeline was scrubbed
		else:
			_buddy_d = lerpf(_buddy_d, target_d, 1.0 - exp(-delta * 8.0))
		want = Mission.route_xy(_buddy_d)
		var working := str(st.get("phase", "")) == "stop"
		_buddy_side = move_toward(_buddy_side, 1.0 if working else 0.0, delta * 0.4)
		want += Vector2(2.0, -1.5) * smoothstep(0.0, 1.0, _buddy_side)
	else:
		_buddy_d = -1.0
		_buddy_side = 0.0
		var fwd := Vector2(sin(walker.yaw), cos(walker.yaw))
		var right := Vector2(cos(walker.yaw), -sin(walker.yaw))
		want = me + fwd * 4.0 - right * 2.4
	if want.distance_to(me) < 2.0:   # never on top of you (at the door at the end of an abort): beside you, on your left
		var away := want - me
		want = me + (away.normalized() if away.length() > 0.3 else -Vector2(cos(walker.yaw), -sin(walker.yaw))) * 2.0
	if _buddy.is_finite():
		want = outside_structures(want, _buddy, true, 2.0)
	var prev := _buddy
	if not _buddy.is_finite() or _buddy.distance_to(want) > 30.0:
		_buddy = want
		prev = want
		_buddy_vel = Vector2.ZERO
	else:
		# smooth pursuit: the speed grows with the gap, so EV2 never stops and starts in little hops
		var step := (want - _buddy) * (1.0 - exp(-delta * (10.0 if walker.autopilot else 2.5)))
		if not walker.autopilot and step.length() > 6.0 * delta:
			step = step.normalized() * 6.0 * delta   # you spun round: walk over, don't glide
		_buddy += step
	var v := (_buddy - prev) / maxf(delta, 1e-4)
	_buddy_vel = _buddy_vel.lerp(v, 1.0 - exp(-delta * 6.0))
	var speed := _buddy_vel.length()
	if speed > 0.2:
		_buddy_still = 0.0
		a.rotation.y = lerp_angle(a.rotation.y, -atan2(_buddy_vel.x, _buddy_vel.y), minf(1.0, delta * 5.0))
	else:
		_buddy_still += delta
		var look := me - _buddy
		if _buddy_still > 1.5 and look.length() > 0.5:   # waited a moment: turn to look at you
			a.rotation.y = lerp_angle(a.rotation.y, -atan2(look.x, look.y), minf(1.0, delta * 2.0))
	_buddy_phase += (_buddy - prev).length() * 2.4
	a.position = td.world_at(_buddy)
	Models.animate_astronaut(a, _buddy_phase, clampf(speed / 1.1, 0.0, 1.0) if speed > 0.15 else 0.0)


func _animate_markers(delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	for k in stop_nodes:
		var b: Node3D = stop_nodes[k]
		var dia := b.get_node_or_null("Diamond") as Node3D
		if dia:
			dia.rotation.y += delta * 1.2
			var base := 9.0 if mode != "walk" else 3.2
			dia.position.y = base + sin(t * 1.6 + float(b.get_meta("phase", 0.0))) * 0.6
			var cam_d := camera.global_position.distance_to(b.global_position)
			var sc := clampf(cam_d / 260.0, 0.55, 7.0) if mode != "walk" else clampf(cam_d / 60.0, 0.35, 2.5)
			if k == hover_id:
				sc *= 1.35   # under the mouse: the diamond swells and the column brightens
			dia.scale = Vector3.ONE * sc
			var col := b.get_child(0) as Node3D
			var wide := clampf(cam_d / 320.0, 1.0, 9.0) if mode != "walk" else 1.0
			col.scale = Vector3(wide, 1.0 if mode != "walk" else 0.6, wide)
			col.position.y = 27.5 * col.scale.y
	var blink := fmod(t, 1.4) < 0.18
	for n in markers_root.get_children():
		_blink_walk(n, blink)


func _blink_walk(n: Node, on: bool) -> void:
	for c in n.get_children():
		if c.has_meta("blink"):
			(c as Node3D).visible = on
		if c.get_child_count() > 0 and c is Node3D and not (c is MeshInstance3D):
			_blink_walk(c, on)


func _update_devils(delta: float) -> void:
	var wind := 1.0
	for d in devils:
		var p: Vector2 = d["xy"]
		p += (d["vel"] as Vector2) * delta * wind
		if p.length() > 9000.0:
			p = -p.normalized() * 6000.0
		d["xy"] = p
		var n: Node3D = d["node"]
		n.position = Vector3(p.x, td.h(p.x, p.y) + float(d["h"]) * 0.5 - 4.0, -p.y)
		n.rotation.y += delta * 0.6


# ------------------------------------------------------------------ input
func _unhandled_input(event: InputEvent) -> void:
	if not ready_terrain:
		return
	if mode == "walk":
		# Look around: hold the right button (the cursor hides and the view turns as far as you like),
		# press F to keep it that way (F or Esc gives the cursor back), or drag with the left button.
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT and Settings.look_toggle:
			if (event as InputEventMouseButton).pressed:   # Settings "look_toggle": a click switches mouse-look on and off
				set_look_lock(not look_locked)
		elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_RIGHT:
			var held := (event as InputEventMouseButton).pressed
			if held and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
				_look_hold = true
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			elif not held and _look_hold:
				_look_hold = false
				if not look_locked:
					Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event is InputEventMouseMotion:
			var mm := event as InputEventMouseMotion
			if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED or (mm.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)):
				walker.look(mm.relative)
		elif event.is_action_pressed("lope") and Settings.lope_toggle:
			walker.lope_latched = not walker.lope_latched
		elif event.is_action_pressed("jump"):
			walker.jump()
		elif event.is_action_pressed("autopilot"):
			toggle_autopilot()
		elif event.is_action_pressed("mouse_lock"):
			set_look_lock(not look_locked)
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_press = true
				_press_pos = mb.position
				_dragged = false
				dragging_stop = ""
				_grab_stop = "" if mb.double_click else _stop_at(mb.position)
				if mb.double_click:
					_press = false   # the release must not also run the single-click action (inspect / select)
					var hit := _pick(mb.position)
					if hit != Vector3.INF:
						ground_double_clicked.emit(Geo.xy_of(hit))
						orbit.fly_to(hit, maxf(orbit.dist * 0.45, 60.0))
			else:
				if dragging_stop != "":
					_end_stop_drag()
				elif _press and not _dragged:
					_click(mb.position)
				_press = false
				_grab_stop = ""
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _press:
			if mm.position.distance_to(_press_pos) > 5.0:
				_dragged = true
			if _grab_stop != "" and _dragged:
				if dragging_stop == "":
					dragging_stop = _grab_stop
					# grabbed by the label (drawn above the beacon): keep that offset, so the beacon's foot
					# follows the cursor instead of jumping to the ground seen behind the label
					var b: Node3D = stop_nodes.get(dragging_stop)
					_drag_offset = camera.unproject_position(b.global_position) - _press_pos if b else Vector2.ZERO
				_drag_stop_to(mm.position + _drag_offset)
				return   # the camera stays put while a stop is dragged
		elif mm.button_mask == 0:
			_hover_pos = mm.position
	orbit.handle_input(event)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_MOUSE_EXIT:
		_hover_pos = Vector2(-1, -1)


## Every mouse move, before the panels see it. If the latest one never reached _unhandled_input, a panel
## took it: the mouse is over the interface and nothing in 3D is hovered.
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_motion_pos = (event as InputEventMouseMotion).position


## Stop under a screen point: its label, else within 22 px of its beacon. "" = none.
func _stop_at(screen: Vector2) -> String:
	if label_hit.is_valid():
		var h: Dictionary = label_hit.call(screen)
		if not h.is_empty():
			return str(h["id"]) if str(h["kind"]) == "stop" else ""
	var best := ""
	var best_d := 22.0
	for k in stop_nodes:
		var b: Node3D = stop_nodes[k]
		for anchor in [b.global_position, b.global_position + Vector3(0, 9, 0)]:
			if camera.is_position_behind(anchor):
				continue
			var dd := camera.unproject_position(anchor).distance_to(screen)
			if dd < best_d:
				best_d = dd
				best = str(k)
	return best


func _drag_stop_to(screen: Vector2) -> void:
	var hit := _pick(screen)
	if hit == Vector3.INF:
		return
	var xy := Geo.xy_of(hit)
	if not td.grid.contains_xy(xy.x, xy.y, 5.0):
		return   # stops live on the 1 m terrain model
	_drag_xy = xy
	var b: Node3D = stop_nodes.get(dragging_stop)
	if b:
		b.position = td.world_at(xy)
	_update_marker_rings()


func _end_stop_drag() -> void:
	var id := dragging_stop
	dragging_stop = ""
	if _drag_xy.is_finite():
		stop_moved.emit(id, _drag_xy)
	_drag_xy = Vector2(INF, INF)


## What the mouse is over in orbit view (throttled): a label of any kind, else a stop's beacon.
func _update_hover() -> void:
	var id := dragging_stop if mode == "orbit" else ""
	if mode == "orbit" and id == "" and not _press and _hover_pos.x >= 0.0 and _motion_pos == _hover_pos:
		if label_hit.is_valid():
			var h: Dictionary = label_hit.call(_hover_pos)
			id = str(h.get("id", ""))
		if id == "":
			id = _stop_at(_hover_pos)
	hover_id = id
	if _hover_drawn != hover_id:
		for k in [_hover_drawn, hover_id]:
			var b: Node3D = stop_nodes.get(k)
			if b:
				(b.get_meta("column_mat") as ShaderMaterial).set_shader_parameter("intensity", 5.5 if k == hover_id else 3.2)
		_hover_drawn = hover_id


func _pick(screen: Vector2) -> Vector3:
	var o := camera.project_ray_origin(screen)
	var d := camera.project_ray_normal(screen)
	return td.raycast(o, d, 200000.0)


func _click(screen: Vector2) -> void:
	# the floating labels are the biggest targets on screen: test them first
	if label_hit.is_valid():
		var h: Dictionary = label_hit.call(screen)
		if not h.is_empty():
			if str(h["kind"]) == "stop":
				stop_clicked.emit(str(h["id"]))
			else:
				focus_xy(Geo.xy_of(h["pos"]), 240.0)
				object_clicked.emit(h)
			return
	var best := ""
	var best_d := 28.0
	for k in stop_nodes:
		var b: Node3D = stop_nodes[k]
		for anchor in [b.global_position, b.global_position + Vector3(0, 9, 0)]:
			if camera.is_position_behind(anchor):
				continue
			var sp := camera.unproject_position(anchor)
			var dd := sp.distance_to(screen)
			if dd < best_d:
				best_d = dd
				best = str(k)
	if best != "":
		stop_clicked.emit(best)
		return
	var hit := _pick(screen)
	if hit != Vector3.INF:
		ground_clicked.emit(Geo.xy_of(hit))


## Labelled anchors for the 2D callout layer.
func callouts() -> Array:
	var out := []
	if not ready_terrain or not show_labels:
		return out
	var hab := Mission.hab_xy()
	out.append({"id": "hab", "kind": "hab", "title": str(Mission.habitat.get("name", "Habitat")), "sub": "HABITAT · 12 m MAST",
		"pos": td.world_at(hab, 14.0), "color": C_HAB})
	var i := 1
	for s in Mission.stops:
		var kind := str(s.get("kind", "custom"))
		var p := Mission.xy_of(float(s["lon"]), float(s["lat"]))
		if str(s["id"]) == dragging_stop and _drag_xy.is_finite():
			p = _drag_xy   # the label travels with the beacon while you drag it
		out.append({"id": str(s["id"]), "kind": "stop", "title": "%d · %s" % [i, str(s["name"])],
			"sub": "%s · %d min" % [kind.to_upper(), int(s.get("dwell_min", 20))],
			"pos": td.world_at(p, 15.0 if mode != "walk" else 5.0), "color": STOP_COLORS.get(kind, STOP_COLORS["custom"])})
		i += 1
	for sg in Mission.suggestions:
		var sp := Mission.xy_of(float(sg["lon"]), float(sg["lat"]))
		out.append({"id": str(sg.get("id", "")), "kind": "suggest", "title": "◆ %s" % str(sg.get("name", "Science stop")),
			"sub": "SUGGESTED · SCIENCE %.2f · CLICK TO ADD" % float(sg.get("score", 0.0)), "pos": td.world_at(sp, 12.0), "color": C_SUGGEST})
	for sh in Mission.site.get("shelters", []):
		var q := Mission.xy_of(float(sh["lon"]), float(sh["lat"]))
		var sub := "STORM SHELTER"
		if Mission.has_rover() and str(sh.get("kind", "")) == "rover":
			var rs := Mission.rover_state(Mission.eva_t)
			q = rs["xy"]
			sub = "DRIVING THE CREW" if bool(rs["moving"]) else ("CREW ABOARD" if Mission.in_cabin(Mission.eva_t) else "PARKED · SUITPORTS · SHELTER")
		out.append({"id": str(sh.get("id", "PR")), "kind": "shelter", "title": str(sh.get("id", "PR")), "sub": sub,
			"pos": td.world_at(q, 6.0), "color": C_SHELTER})
	if rover_node:
		var rv: Dictionary = Mission.site.get("rover", {})
		out.append({"id": "rover", "kind": "rover", "title": "%s" % str(Mission.site.get("rover_name", "Rover")),
			"sub": "SOL %d · LAST STOP" % int(rv.get("latest_sol", 0)), "pos": rover_node.global_position + Vector3(0, 4, 0), "color": C_TRAVERSE})
	return out
