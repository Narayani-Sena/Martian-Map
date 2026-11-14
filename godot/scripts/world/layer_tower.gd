class_name LayerTower
extends Node3D
## The layer tower (feature A2) in the 3D console. The brief asks for "a layered, integrated view": the site's data
## layers lift off the terrain one by one as a stack of glass sheets, each named with its mission and instrument
## (HiRISE imagery and terrain, THEMIS heat, CRISM minerals, then the hazard, science and ways-home layers made from
## them), a needle runs through the stack at the habitat, and the sheets settle back into the one surface.
## The TOWER button plays it; the demo opens with it. The sheets are the server's /tower pictures on flat quads, so
## it costs no extra terrain on the UHD 620.

signal finished

const RISE_S := 1.6
const STAGGER_S := 0.38
const HOLD_S := 6.5
const FALL_S := 1.1
const SHEET_PX := 1024

var world: MarsWorld
var running := false
var interruptible := false    # a key or click stops it (off while the demo drives it: the demo has its own)
var sheets: Array = []        # [{node, label, mat, id}] bottom first; label = a 2D tag beside the sheet
var _tags: Control            # holds the 2D tags, over the 3D view
var _half := Vector2.ZERO     # half the sheet size (m)
var _needle: MeshInstance3D
var _needle_mat: StandardMaterial3D
var _site := ""
var _base_y := 0.0
var _gap := 280.0
var _center := Vector3.ZERO
var _run := 0


func setup(w: MarsWorld, ui: Control) -> void:
	world = w
	visible = false
	_tags = Control.new()
	_tags.name = "TowerTags"
	_tags.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tags.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tags.visible = false
	ui.add_child(_tags)
	Mission.site_loaded.connect(_clear)
	Mission.plan_changed.connect(_preload_later)


## Compose the sheets a little after the first plan, so TOWER and the demo start at once (the ways-home sheet
## takes the server several seconds).
func _preload_later() -> void:
	if _site == Mission.site_id or running:
		return
	var site := Mission.site_id
	await get_tree().create_timer(12.0).timeout
	if site == Mission.site_id and _site != site and not running:
		await load_sheets()


func _clear() -> void:
	_run += 1
	for s in sheets:
		(s["node"] as Node).queue_free()
		(s["label"] as Node).queue_free()
	sheets.clear()
	if _needle:
		_needle.queue_free()
		_needle = null
	_site = ""
	running = false
	visible = false


## Height of the middle of the stack and the stack's centre (for the camera).
func focus() -> Vector3:
	return _center + Vector3(0.0, _gap * maxf(sheets.size() - 1, 0) * 0.5, 0.0)


func span() -> float:
	return _gap * maxf(sheets.size() - 1, 1)


func load_sheets_ready() -> bool:
	return _site == Mission.site_id and not sheets.is_empty()


## The sheets for this site, loaded once. False if the server has none.
func load_sheets() -> bool:
	if _site == Mission.site_id and not sheets.is_empty():
		return true
	_clear()
	var me := _run
	var r := await Api.get_json("/api/sites/%s/tower" % Mission.site_id, 60.0)
	if me != _run or not r["ok"] or not (r["data"] is Dictionary):
		return false
	var g: Dictionary = Mission.site.get("grid", {})
	var x0 := float(g.get("x_min", 0.0))
	var y1 := float(g.get("y_max", 0.0))
	var wm := float(g.get("width", 1)) * float(g.get("res", 1.0))
	var hm := float(g.get("height", 1)) * float(g.get("res", 1.0))
	_gap = maxf(wm, hm) * 0.085
	_half = Vector2(wm, hm) * 0.5
	_base_y = float(Mission.site.get("elev_max", 0.0)) - world.td.elev_ref + 40.0
	_center = Vector3(x0 + wm * 0.5, _base_y, -(y1 - hm * 0.5))
	var q := {"size": SHEET_PX}
	q.merge(Mission.walk_query())
	q["havens"] = Mission.havens_param()
	var hv := Mission.haven_lonlat()
	q["hab_lon"] = hv.x
	q["hab_lat"] = hv.y
	var shader := load("res://shaders/tower_sheet.gdshader")
	for sd in r["data"].get("sheets", []):
		var id := str(sd.get("id", ""))
		var tex := await Api.get_texture("/api/sites/%s/tower/%s.jpg" % [Mission.site_id, id] + Api.q(q), "", true)
		if me != _run:
			return false
		if tex == null:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Sheet_" + id
		var pm := PlaneMesh.new()
		pm.size = Vector2(wm, hm)
		mi.mesh = pm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var mat := ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("tex", tex)
		mat.set_shader_parameter("fade", 0.0)
		mi.material_override = mat
		mi.position = _center
		add_child(mi)
		# the tag: what the sheet is and where it comes from, drawn beside the sheet's right-hand corner
		var tag := PanelContainer.new()
		tag.add_theme_stylebox_override("panel", UiKit.box(Color(0.01, 0.03, 0.05, 0.74), Color(0.31, 0.82, 1.0, 0.4), 5, 1, 6))
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 0)
		v.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.add_child(v)
		v.add_child(UiKit.caps(str(sd.get("kind", "")), Color(0.45, 0.88, 1.0), 11))
		v.add_child(UiKit.label(str(sd.get("line", "")), 12, UiKit.TEXT))
		tag.modulate.a = 0.0
		_tags.add_child(tag)
		sheets.append({"node": mi, "label": tag, "mat": mat, "id": id})
	if sheets.is_empty():
		return false
	# the needle through the stack, at the habitat
	var hab := Mission.hab_xy()
	_needle = MeshInstance3D.new()
	_needle.name = "DataCore"
	var cm := CylinderMesh.new()
	cm.top_radius = 4.0
	cm.bottom_radius = 4.0
	cm.height = span() + _gap
	cm.radial_segments = 8
	_needle.mesh = cm
	_needle_mat = StandardMaterial3D.new()
	_needle_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_needle_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_needle_mat.albedo_color = Color(0.45, 0.95, 1.0, 0.0)
	_needle.material_override = _needle_mat
	_needle.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_needle.position = Vector3(hab.x, _base_y + span() * 0.5, -hab.y)
	add_child(_needle)
	_site = Mission.site_id
	return true


## Lift the sheets one by one, hold, and let them settle back. Await it or listen for `finished`.
func play(hold := HOLD_S) -> void:
	if running:
		return
	running = true
	if not await load_sheets():
		running = false
		finished.emit()
		return
	running = true   # (loading clears the old sheets, and the flag with them)
	_run += 1
	var me := _run
	visible = true
	var n := sheets.size()
	for i in n:
		var s: Dictionary = sheets[i]
		var node: MeshInstance3D = s["node"]
		node.position.y = _base_y - _gap * 0.6
		var tw := create_tween()
		tw.tween_interval(i * STAGGER_S)
		tw.tween_property(node, "position:y", _base_y + i * _gap, RISE_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.parallel().tween_method(func(v: float): (s["mat"] as ShaderMaterial).set_shader_parameter("fade", v), 0.0, 1.0, RISE_S * 0.6)
		tw.parallel().tween_property(s["label"], "modulate:a", 1.0, RISE_S).set_delay(RISE_S * 0.4)
	var up := n * STAGGER_S + RISE_S
	var tn := create_tween()
	tn.tween_interval(up)
	tn.tween_property(_needle_mat, "albedo_color:a", 0.85, 0.6)
	if not await _hold(me, up + hold):
		return
	# settle back, the top sheet first
	var tn2 := create_tween()
	tn2.tween_property(_needle_mat, "albedo_color:a", 0.0, 0.4)
	for i in n:
		var s: Dictionary = sheets[n - 1 - i]
		var tw := create_tween()
		tw.tween_interval(i * STAGGER_S * 0.5)
		tw.tween_property(s["node"], "position:y", _base_y - _gap * 0.6, FALL_S).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		tw.parallel().tween_method(func(v: float): (s["mat"] as ShaderMaterial).set_shader_parameter("fade", v), 1.0, 0.0, FALL_S)
		tw.parallel().tween_property(s["label"], "modulate:a", 0.0, FALL_S * 0.5)
	if not await _hold(me, n * STAGGER_S * 0.5 + FALL_S + 0.1):
		return
	visible = false
	running = false
	finished.emit()


## A slow turn around the stack while it stands (the orbit camera's own idle turn waits 40 s), and the tags kept
## beside each sheet's right-most corner on screen.
func _process(delta: float) -> void:
	_tags.visible = visible
	if not visible:
		return
	if running and world.mode == "orbit" and not world.orbit.flying():
		world.orbit.yaw += delta * 0.07
	var cam := world.camera
	var screen_w := _tags.size.x
	for s in sheets:
		var node: Node3D = s["node"]
		var tag: Control = s["label"]
		var right := Vector2(-INF, 0.0)
		var left := Vector2(INF, 0.0)
		for c in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var p := node.global_position + Vector3(c.x * _half.x, 0.0, c.y * _half.y)
			if cam.is_position_behind(p):
				continue
			var sp := cam.unproject_position(p)
			if sp.x > right.x:
				right = sp
			if sp.x < left.x:
				left = sp
		if right.x == -INF:
			tag.visible = false
			continue
		tag.visible = true
		tag.reset_size()
		if right.x + 10.0 + tag.size.x <= screen_w - 8.0 or left.x - 10.0 - tag.size.x < 8.0:
			tag.position = Vector2(right.x + 10.0, right.y - tag.size.y * 0.5)   # beside the right-most corner
		else:
			tag.position = Vector2(left.x - 10.0 - tag.size.x, left.y - tag.size.y * 0.5)   # no room: the left one


func _input(event: InputEvent) -> void:
	if not running or not interruptible:
		return
	var take := (event is InputEventKey and event.is_pressed() and not event.is_echo()) \
		or (event is InputEventMouseButton and event.is_pressed()) \
		or (event is InputEventJoypadButton and event.is_pressed())
	if take:
		stop()
		get_viewport().set_input_as_handled()


## Stop at once (any input during the demo, a site switch).
func stop() -> void:
	if not running:
		return
	_run += 1
	running = false
	visible = false
	_tags.visible = false
	finished.emit()


func _hold(me: int, s: float) -> bool:
	var left := s
	while left > 0.0:
		await get_tree().process_frame
		left -= get_process_delta_time()
		if me != _run:
			return false
	return true
