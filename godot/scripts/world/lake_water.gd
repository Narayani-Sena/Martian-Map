class_name LakeWater
extends Node
## Flood the crater (feature A4) in the 3D world. I raises the ancient lake through the site's levels, then drains
## it. At Jezero the levels are the published ones (Mangold et al., LPSC 2024: the delta front records a lake falling
## from about -2,410 m to -2,500 m, below the eastern breach at about -2,400 m); other sites get what-if levels over
## the habitat. The water rises as one body of water (the server's mask on the regional terrain), the lake bed under
## it is tinted by depth with caustics in the shallows, and in the helmet the visor says how much water stood over
## the crew, with the view tinted while under it.

signal level_changed(level: float)   # NAN = no lake

const RISE_S := 4.0
const DRAIN_S := 2.2

var world: MarsWorld
var app                          # main.gd: the visor and UI layers, the HUD
var toast: Callable = func(_t: String, _k: String) -> void: pass
var on := false
var level := NAN                 # m (areoid) of the surface the water rises to
var level_name := ""
var surface := NAN               # m (areoid) of the surface now (it animates)
var stats := {}                  # /lake at this level: share of the site under water, depth over the hab and stops
var under := 0.0                 # 0..1, how far the visor view is under water (eased)
var depth_here := NAN            # m of water over the walker (negative: above the shore)
var _levels: Array = []          # [{name, elev, published}] lowest first
var _idx := -1
var _plane: MeshInstance3D
var _mat: ShaderMaterial
var _tint: ColorRect
var _tint_mat: ShaderMaterial
var _banner: PanelContainer
var _b_title: Label
var _b_text: Label
var _tween: Tween
var _req := 0


func setup(w: MarsWorld, app_node, toast_cb: Callable) -> void:
	world = w
	app = app_node
	toast = toast_cb
	Mission.site_loaded.connect(_on_site)
	_build_overlays()


func _on_site() -> void:
	set_off(true)
	_levels.clear()


## The site's lake levels, lowest first: the published ones from the site config, else what-ifs over the habitat.
func levels() -> Array:
	if not _levels.is_empty():
		return _levels
	for L in Mission.site.get("layers", []):
		if str(L.get("id", "")) == "lake":
			for v in L.get("levels", []):
				if v is Dictionary and v.has("elev"):
					_levels.append({"name": str(v.get("name", "")), "elev": float(v["elev"]), "published": true})
	if _levels.is_empty() and world != null and world.td != null:
		var hab := Mission.hab_xy()
		var he := world.td.height_abs(hab.x, hab.y)
		for dz in [8.0, 30.0, 70.0]:
			_levels.append({"name": "what-if, %d m over the habitat" % int(dz), "elev": snappedf(he + dz, 1.0), "published": false})
	_levels.sort_custom(func(a, b): return float(a["elev"]) < float(b["elev"]))
	return _levels


## I: the water rises to the next level; after the highest it drains away.
func cycle() -> void:
	var L := levels()
	if L.is_empty():
		toast.call("No lake levels for this site", "info")
		return
	_idx += 1
	if _idx >= L.size():
		set_off()
		return
	var v: Dictionary = L[_idx]
	show_level(float(v["elev"]), str(v["name"]), bool(v.get("published", false)))


func show_level(elev: float, name: String, published := true) -> void:
	if world == null or not world.ready_terrain:
		return
	_req += 1
	var me := _req
	level = elev
	level_name = name
	var tex: Texture2D = await Api.get_texture("/api/sites/%s/lake/mask.png?level=%.1f" % [Mission.site_id, elev], "", false)
	if me != _req:
		return
	if tex == null:
		toast.call("The lake could not be drawn: no regional terrain for this site", "bad")
		level = NAN
		return
	_ensure_plane()
	_mat.set_shader_parameter("mask_tex", tex)
	world.terrain_mesh.set_param("lake_tex", tex)
	var from := surface if is_finite(surface) else _floor_elev()
	on = true
	_plane.visible = true
	_animate(from, elev, RISE_S if from < elev else DRAIN_S)
	level_changed.emit(level)
	var r := await Api.get_json("/api/sites/%s/lake?level=%.1f" % [Mission.site_id, elev], 30.0)
	if me != _req:
		return
	stats = r["data"] if r["ok"] and r["data"] is Dictionary else {}
	var hab := ""
	for p in stats.get("points", []):
		if str(p.get("name", "")) == "Hab":
			var d := float(p.get("depth_m", 0.0))
			hab = ("%d m of water over the habitat" % int(round(d))) if d > 0.0 else ("the habitat %d m above the shore" % int(round(-d)))
	var src := "Mangold et al. 2024" if published else "no published level for this site"
	toast.call("Ancient lake at %s m (%s, %s): %d %% of the site under water, %s" % [fmt_elev(elev), name, src,
		int(round(100.0 * float(stats.get("share_under", 0.0)))), hab], "ok")


## Drain the lake (instant: just hide it).
func set_off(instant := false) -> void:
	_req += 1
	_idx = -1
	var was := on
	on = false
	level = NAN
	level_name = ""
	stats = {}
	level_changed.emit(NAN)
	if instant or not was or world == null or not world.ready_terrain or not is_finite(surface):
		_hide_now()
		return
	toast.call("The lake drains away", "info")
	_animate(surface, _floor_elev(), DRAIN_S, true)


## For checks and tours: the water at a level now, without the rise.
func settle() -> void:
	if _tween:
		_tween.kill()
	if on and is_finite(level):
		_set_surface(level)


## A place a few metres above the water near the habitat, and the way downhill from it (to look out over the
## lake): [xy, down], or [] if there is no shore within about a kilometre.
func shore_point() -> Array:
	if not is_finite(level) or world == null:
		return []
	var hab := Mission.hab_xy()
	for ring in range(1, 40):
		for k in 24:
			var p := hab + Vector2.from_angle(TAU * k / 24.0) * ring * 30.0
			var above := world.td.height_abs(p.x, p.y) - level
			if above > 1.5 and above < 5.0:
				var e := 6.0
				var grad := Vector2(world.td.height_abs(p.x + e, p.y) - world.td.height_abs(p.x - e, p.y),
					world.td.height_abs(p.x, p.y + e) - world.td.height_abs(p.x, p.y - e))
				return [p, -grad.normalized() if grad.length() > 0.01 else Vector2(0, 1)]
	return []


func _floor_elev() -> float:
	return float(Mission.site.get("elev_min", level - 60.0)) - 20.0


func _animate(from: float, to: float, dur: float, then_hide := false) -> void:
	if _tween:
		_tween.kill()
	_set_surface(from)
	_tween = create_tween()
	_tween.tween_method(_set_surface, from, to, dur).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	if then_hide:
		_tween.tween_callback(_hide_now)


func _set_surface(e: float) -> void:
	surface = e
	var y := e - world.td.elev_ref
	if _plane:
		_plane.position.y = y
	if world.terrain_mesh:
		world.terrain_mesh.set_param("lake_y", y)


func _hide_now() -> void:
	if _tween:
		_tween.kill()
	surface = NAN
	if _plane:
		_plane.visible = false
	if world and world.terrain_mesh:
		world.terrain_mesh.set_param("lake_y", -1.0e9)


## One flat sheet over the regional terrain (the whole crater), clipped by the mask in its shader.
func _ensure_plane() -> void:
	var g: Variant = Mission.site.get("regional_grid")
	if not (g is Dictionary) or (g as Dictionary).is_empty():
		g = Mission.site.get("grid", {})
	var x0 := float(g.get("x_min", -2000.0))
	var y1 := float(g.get("y_max", 2000.0))
	var wm := float(g.get("width", 1)) * float(g.get("res", 1.0))
	var hm := float(g.get("height", 1)) * float(g.get("res", 1.0))
	if _plane == null:
		_plane = MeshInstance3D.new()
		_plane.name = "AncientLake"
		_plane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_mat = ShaderMaterial.new()
		_mat.shader = load("res://shaders/lake_water.gdshader")
		_plane.material_override = _mat
		world.add_child(_plane)
	var pm := PlaneMesh.new()
	pm.size = Vector2(wm, hm)
	_plane.mesh = pm
	_plane.position = Vector3(x0 + wm * 0.5, _plane.position.y, -(y1 - hm * 0.5))
	_mat.set_shader_parameter("reg_rect", Vector4(x0, y1, wm, hm))


func _build_overlays() -> void:
	_tint = ColorRect.new()
	_tint.name = "Underwater"
	_tint.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tint_mat = ShaderMaterial.new()
	_tint_mat.shader = load("res://shaders/underwater.gdshader")
	_tint.material = _tint_mat
	_tint.visible = false
	app.visor_layer.add_child(_tint)
	app.visor_layer.move_child(_tint, 0)   # under the visor frame

	_banner = PanelContainer.new()
	_banner.name = "LakeBanner"
	_banner.add_theme_stylebox_override("panel", UiKit.box(Color(0.01, 0.06, 0.08, 0.8), Color(0.4, 0.85, 0.95, 0.55), 8, 1, 10))
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := UiKit.vbox(2)
	_banner.add_child(v)
	_b_title = UiKit.caps("", Color(0.55, 0.92, 1.0), 12)
	v.add_child(_b_title)
	_b_text = UiKit.label("", 15, UiKit.TEXT)
	v.add_child(_b_text)
	_banner.visible = false
	app.ui.add_child(_banner)


func _process(_delta: float) -> void:
	if world == null or not world.ready_terrain:
		return
	var wet := is_finite(surface)
	var walk := world.mode == "walk"
	var cam_under := false
	depth_here = NAN
	if wet and walk:
		var me := world.walker.xy()
		depth_here = surface - world.td.height_abs(me.x, me.y)
		cam_under = world.camera.global_position.y < surface - world.td.elev_ref
	under = lerpf(under, 1.0 if cam_under else 0.0, 0.12)
	if under < 0.005:
		under = 0.0
	_tint.visible = under > 0.0
	if _tint.visible:
		_tint_mat.set_shader_parameter("strength", under)
		_tint_mat.set_shader_parameter("depth_m", maxf(depth_here, 0.0) if is_finite(depth_here) else 0.0)
	# the banner: in the helmet only while the HUD is up (the HUD-failure drill turns it dark)
	# (a trailer's orbit shots have their own caption in that place)
	_banner.visible = on and not app.ui_hidden and (not walk or app.hud.visible) and (walk or not str(app.tour).begins_with("trailer"))
	if not _banner.visible:
		return
	var published := _idx >= 0 and _idx < _levels.size() and bool(_levels[_idx].get("published", false))
	_b_title.text = "Ancient lake · " + level_name
	var head := "Water surface %s m" % fmt_elev(level) if published else "What-if water surface %s m" % fmt_elev(level)
	if walk and is_finite(depth_here):
		if depth_here > 0.0:
			_b_text.text = "%s: %d m of water over you%s" % [head, int(round(depth_here)), ", about 3.5 billion years ago" if published else ""]
		else:
			_b_text.text = "%s: you stand %d m above the shore" % [head, int(round(-depth_here))]
	else:
		_b_text.text = "%s: %d %% of the site under water · I raises it, then drains it" % [head, int(round(100.0 * float(stats.get("share_under", 0.0))))]
	_banner.reset_size()
	# orbit: under the top bar; helmet: above the minimap (the top centre is where the visor's alert banner goes)
	var y: float = (app.ui.size.y - 250.0) if walk else 86.0
	_banner.position = Vector2((app.ui.size.x - _banner.size.x) * 0.5, y)


## -2500 -> "−2,500" (a real minus sign and a thousands comma)
static func fmt_elev(e: float) -> String:
	if not is_finite(e):
		return "?"
	var n := int(round(absf(e)))
	var s := str(n) if n < 1000 else "%d,%03d" % [n / 1000, n % 1000]
	return ("−" if e < 0.0 else "") + s
