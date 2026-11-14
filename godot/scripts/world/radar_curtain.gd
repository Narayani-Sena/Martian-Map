class_name RadarCurtain
extends Node3D
## Ground radar under the rover's track (feature E1). Shift+J hangs Perseverance's RIMFAX radargrams under its
## track as a curtain from the ground down to about 5 m: each sol's radargram laid along that sol's drive. Light and
## dark bands are echoes of opposite sign from buried layers and rocks (the chevrons are echoes off buried boulders).
## The curtain is drawn through the ground near it and fades behind hills. Depth assumes a relative permittivity of
## 9 (0.1 m/ns); from orbit the curtain is drawn 2.5 times deeper so it can be seen. Gale has none: of the two
## rovers, only Perseverance carries a ground radar.

const ORBIT_SCALE := 2.5
const REVEAL_S := 1.8

var world: MarsWorld
var toast: Callable = func(_t: String, _k: String) -> void: pass
var on := false
var doc: Dictionary = {}
var runs: Array = []
var n_cols := 0
var tex_size := Vector2i.ZERO
var _mi: MeshInstance3D
var _mat: ShaderMaterial
var _req := 0
var _building := false
var _tween: Tween
var _scale := -1.0


func setup(w: MarsWorld, toast_cb: Callable) -> void:
	world = w
	toast = toast_cb
	Mission.site_loaded.connect(_on_site)


func available() -> bool:
	return Mission.site.get("radar") is Dictionary


func _on_site() -> void:
	_req += 1
	on = false
	doc = {}
	runs = []
	n_cols = 0
	tex_size = Vector2i.ZERO
	if _tween:
		_tween.kill()
	if _mi:
		_mi.queue_free()
		_mi = null


func toggle() -> void:
	set_on(not on)


## Shift+J: unroll the curtain into the ground, or take it away.
func set_on(v: bool, quiet := false) -> void:
	if not v:
		if not on:
			return
		on = false
		if _mi:
			_animate(0.0, 0.7, true)
		if not quiet:
			toast.call("Ground radar curtain off", "info")
		return
	if not available():
		toast.call("No ground radar at this site: of the two rovers, only Perseverance carries one (RIMFAX)", "info")
		return
	on = true
	if _mi == null:
		if _building:
			return
		_building = true
		var ok := await _build()
		_building = false
		if not ok:
			on = false
			return
	if not on:
		return
	_mi.visible = true
	_apply_mode(true)
	_animate(1.0, REVEAL_S)
	if not quiet:
		toast.call("Ground radar: %d sols of Perseverance's RIMFAX radar, %.1f km of track, %d m down%s. Light and dark bands are buried layers; chevrons are echoes off buried rocks." % [
			(doc.get("sols", []) as Array).size(), float(doc.get("length_m", 0.0)) / 1000.0, int(round(float(doc.get("depth_m", 5.0)))),
			" (drawn ×%.1f deeper from orbit)" % ORBIT_SCALE if world.mode != "walk" else ""], "ok")


## The nearest radar column to a site point: {run, sol, utc, i, dist_m, xy}, or {} when there is no radar.
func nearest(xy: Vector2) -> Dictionary:
	var best := {}
	var bd := INF
	for run in runs:
		var lon: Array = run["lon"]
		var lat: Array = run["lat"]
		var step := maxi(1, lon.size() / 400)
		for k in range(0, lon.size(), step):
			var p := Mission.xy_of(float(lon[k]), float(lat[k]))
			var d := p.distance_squared_to(xy)
			if d < bd:
				bd = d
				best = {"run": run, "sol": int(run["sol"]), "utc": str(run.get("utc", "")), "i": k, "dist_m": sqrt(d), "xy": p}
	return best


func _build() -> bool:
	var me := _req
	var r: Dictionary = await Api.get_json("/api/sites/%s/radar" % Mission.site_id, 60.0)
	if me != _req:
		return false
	if not r["ok"] or not (r["data"] is Dictionary) or ((r["data"] as Dictionary).get("runs", []) as Array).is_empty():
		toast.call("The ground radar could not be loaded", "bad")
		return false
	doc = r["data"]
	var tex: Texture2D = await Api.get_texture("/api/sites/%s/radar/atlas.png" % Mission.site_id, "", true)
	if me != _req:
		return false
	if tex == null:
		toast.call("The ground radar's radargrams could not be loaded", "bad")
		return false
	tex_size = Vector2i(tex.get_width(), tex.get_height())
	var at: Dictionary = doc["atlas"]
	var W := float(at["w"])
	var H := float(at["h"])
	var sh := float(at["strip_h"])
	var rows := float(doc["rows"])
	runs = doc["runs"]
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var uv2s := PackedVector2Array()
	var idx := PackedInt32Array()
	n_cols = 0
	for run in runs:
		var lon: Array = run["lon"]
		var lat: Array = run["lat"]
		for pc in run.get("pieces", []):
			var strip := float(pc[0])
			var x0 := float(pc[1])
			var n := int(pc[2])
			var at0 := int(pc[3])
			var v0 := strip * sh / H
			var v1 := (strip * sh + rows) / H
			for j in n:
				var k := at0 + j
				var xy := Mission.xy_of(float(lon[k]), float(lat[k]))
				var y := world.td.h(xy.x, xy.y)
				var u := (x0 + float(j) + 0.5) / W
				var base := verts.size()
				verts.append(Vector3(xy.x, y + 0.05, -xy.y))
				uvs.append(Vector2(u, v0))
				uv2s.append(Vector2(0.0, 0.0))
				verts.append(Vector3(xy.x, y + 0.05, -xy.y))
				uvs.append(Vector2(u, v1))
				uv2s.append(Vector2(0.0, 1.0))
				if j > 0:
					idx.append_array(PackedInt32Array([base - 2, base - 1, base, base, base - 1, base + 1]))
			n_cols += n
	if verts.is_empty():
		return false
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_TEX_UV2] = uv2s
	arrays[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/radar_curtain.gdshader")
	_mat.set_shader_parameter("atlas", tex)
	_mat.set_shader_parameter("atlas_size", Vector2(W, H))
	_mat.set_shader_parameter("depth_m", float(doc.get("depth_m", 5.0)))
	_mat.set_shader_parameter("reveal", 0.0)
	_mi = MeshInstance3D.new()
	_mi.name = "RadarCurtainMesh"
	_mi.mesh = mesh
	_mi.material_override = _mat
	_mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_mi.extra_cull_margin = float(doc.get("depth_m", 5.0)) * ORBIT_SCALE + 5.0
	_mi.visible = false
	add_child(_mi)
	return true


func _animate(to: float, dur: float, then_hide := false) -> void:
	if _tween:
		_tween.kill()
	var from := float(_mat.get_shader_parameter("reveal")) if _mat else 0.0
	_tween = create_tween()
	_tween.tween_method(func(x: float): _mat.set_shader_parameter("reveal", x), from, to, dur) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT if to > from else Tween.EASE_IN)
	if then_hide:
		_tween.tween_callback(_hide_if_off)


func _hide_if_off() -> void:
	if _mi and not on:
		_mi.visible = false


## True depth in the helmet; deeper from orbit (and the x-ray reaches further through the ground with it).
func _apply_mode(force := false) -> void:
	if _mat == null:
		return
	var s := 1.0 if world.mode == "walk" else ORBIT_SCALE
	if not force and is_equal_approx(s, _scale):
		return
	_scale = s
	_mat.set_shader_parameter("depth_scale", s)
	_mat.set_shader_parameter("xray_near", 25.0 * s)
	_mat.set_shader_parameter("xray_far", 80.0 * s)


func _process(_delta: float) -> void:
	if on and _mi:
		_apply_mode()
