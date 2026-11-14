class_name ThenNow
extends Node
## Then and now (feature E3). Shift+P stands a camera exactly where the rover's navigation camera stood, pointing
## where it pointed (the raw-image feed's camera model and rover attitude, via /then-now), and wipes between the
## rover's own photo and the 1 m terrain model rendered from the same spot. It shows what the crew will see at a
## place, and how well the terrain model matches the real ground. Shift+P again: the next photo; Esc: back.

const MARGIN := 0.84         # the photo fills 84 % of the screen's limiting side, so the render shows round it
const SWEEP_S := 7.0         # one sweep of the wipe, left and back

var app                      # main.gd
var world: MarsWorld
var toast: Callable = func(_t: String, _k: String) -> void: pass
var active := false
var photos: Array = []
var idx := -1
var current: Dictionary = {}
var split := 0.5
var tex: Texture2D
var _cam: Camera3D
var _layer: CanvasLayer
var _photo: TextureRect
var _frame: Panel
var _mat: ShaderMaterial
var _title: Label
var _sub: Label
var _t := 0.0
var _caption: Control
var _hold_until := 0.0
var _was_mode := "orbit"
var _req := 0


func setup(app_node, w: MarsWorld, toast_cb: Callable) -> void:
	app = app_node
	world = w
	toast = toast_cb
	Mission.site_loaded.connect(func():
		stop()
		photos = []
		idx = -1)
	_build_ui()


## Shift+P: the nearest photo first, then the next one along.
func next() -> void:
	if photos.is_empty():
		_req += 1
		var me := _req
		toast.call("Finding the rover's photos and where they were taken…", "info")
		var r: Dictionary = await Api.get_json("/api/sites/%s/then-now" % Mission.site_id, 90.0)
		if me != _req:
			return
		photos = (r["data"] as Dictionary).get("photos", []) if r["ok"] and r["data"] is Dictionary else []
		if photos.is_empty():
			toast.call("No rover photos with a camera pose for this site (the raw-image feed may be offline)", "bad")
			return
		idx = _nearest_index() - 1
	idx = (idx + 1) % photos.size()
	await show_photo(photos[idx])


func _nearest_index() -> int:
	var here := world.walker.xy() if world.mode == "walk" else Geo.xy_of(world.orbit.target)
	var best := 0
	var bd := INF
	for i in photos.size():
		var p: Dictionary = photos[i]
		var d := Mission.xy_of(float(p["lon"]), float(p["lat"])).distance_to(here)
		if d < bd:
			bd = d
			best = i
	return best


func show_photo(p: Dictionary) -> void:
	_req += 1
	var me := _req
	if not active:
		_was_mode = world.mode
	current = p
	var xy := Mission.xy_of(float(p["lon"]), float(p["lat"]))
	var d: Array = p["dir"]
	var u: Array = p["up"]
	var dir := Vector3(float(d[0]), float(d[1]), float(d[2])).normalized()
	var up := Vector3(float(u[0]), float(u[1]), float(u[2])).normalized()
	# the walker stands there too, so the terrain is drawn at full detail round the camera
	if world.mode != "walk":
		app._set_mode("walk")
		await app._wait(1.0)
		if me != _req:
			return
	world.walker.autopilot = false
	world.walker.place(xy, rad_to_deg(atan2(dir.x, -dir.z)))
	var url := "/api/image-proxy" + Api.q({"url": str(p.get("url", "")), "max_px": 1600})
	var t: Texture2D = await Api.get_texture(url, "", false)
	if me != _req:
		return
	if t == null:
		toast.call("The rover's photo could not be loaded (sol %s)" % str(p.get("sol", "?")), "bad")
		return
	tex = t
	var pos := Vector3(xy.x, world.td.h(xy.x, xy.y) + float(p.get("cam_h_m", 2.0)), -xy.y)
	if _cam == null:
		_cam = Camera3D.new()
		_cam.name = "ThenNowCamera"
		world.add_child(_cam)
	_cam.near = 0.05
	_cam.far = world.camera.far
	_cam.environment = world.camera.environment
	_cam.attributes = world.camera.attributes
	_cam.global_transform = Transform3D(Basis.looking_at(dir, up), pos)
	_cam.current = true
	active = true
	app.hud.visible = false
	app.ui.visible = false        # alerts, toasts and panels step aside
	app.visor.visible = false     # and the visor's dust
	if world.dust:
		world.dust.visible = false   # airborne dust near the camera would sit over the photo
	_photo.texture = tex
	_layer.visible = true
	_fit()
	var rover := str(Mission.site.get("rover_name", "the rover"))
	_title.text = "THEN · %s's %s, sol %d (%s)   ⇄   NOW · the 1 m terrain model from the same spot" % [
		rover, str(p.get("camera", "Navcam")), int(float(p.get("sol", 0))), str(p.get("date_taken", "")).substr(0, 10)]
	_sub.text = "Camera %.1f m above the ground, looking %s at %+d°, %d° wide · photo %d of %d · Shift+P next · Esc back · move the mouse to wipe" % [
		float(p.get("cam_h_m", 2.0)), _compass(float(p.get("az", 0.0))), int(round(float(p.get("el", 0.0)))),
		int(round(float(p.get("hfov", 0.0)))), idx + 1, photos.size()]
	_t = 0.0


func stop() -> void:
	_req += 1
	if not active:
		return
	active = false
	_layer.visible = false
	if _cam:
		_cam.current = false
	world.camera.current = true
	app.ui.visible = true
	app.visor.visible = Settings.visor_fx and world.mode == "walk"
	if world.dust:
		world.dust.visible = true
	app.hud.visible = not app.ui_hidden and world.mode == "walk"
	if _was_mode != "walk":
		app._set_mode(_was_mode)


## Field of view and the photo's place on screen: the photo fills MARGIN of the screen's limiting side, and the
## camera's view is widened to match, so its angles land exactly on the photo's pixels.
func _fit() -> void:
	if current.is_empty() or _cam == null:
		return
	var vp: Vector2 = app.get_viewport().get_visible_rect().size
	var aspect: float = vp.x / maxf(vp.y, 1.0)
	var tx := tan(deg_to_rad(float(current.get("hfov", 45.0))) * 0.5)
	var ty := tan(deg_to_rad(float(current.get("vfov", 30.0))) * 0.5)
	var cam_ty: float
	var fw: float
	var fh: float
	if tx / ty > aspect:      # wide photo: fit its width
		cam_ty = tx / aspect / MARGIN
		fw = MARGIN
		fh = ty / cam_ty
	else:                      # tall photo: fit its height
		cam_ty = ty / MARGIN
		fh = MARGIN
		fw = tx / (cam_ty * aspect)
	_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_cam.fov = rad_to_deg(2.0 * atan(cam_ty))
	var size := Vector2(vp.x * fw, vp.y * fh)
	var at: Vector2 = (vp - size) * 0.5
	_photo.position = at
	_photo.size = size
	_frame.position = at - Vector2(2, 2)
	_frame.size = size + Vector2(4, 4)
	_place_caption()


## The caption sits under the photo (over the render's ground when the photo fills the height).
func _place_caption() -> void:
	if _caption == null:
		return
	var vp: Vector2 = app.get_viewport().get_visible_rect().size
	var below := _photo.position.y + _photo.size.y + 8.0
	_caption.position = Vector2((vp.x - _caption.size.x) * 0.5, minf(below, vp.y - _caption.size.y - 8.0))


func _process(delta: float) -> void:
	if not active:
		return
	_t += delta
	var now := Time.get_ticks_msec() / 1000.0
	if now >= _hold_until:   # the wipe sweeps by itself unless the mouse has just moved it
		split = 0.5 + 0.42 * sin(_t * TAU / SWEEP_S)
	_mat.set_shader_parameter("split", split)


func _input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseMotion:
		var r := Rect2(_photo.position, _photo.size)
		if r.has_point(event.position):
			split = clampf((event.position.x - r.position.x) / maxf(r.size.x, 1.0), 0.0, 1.0)
			_hold_until = Time.get_ticks_msec() / 1000.0 + 2.5
	elif event.is_action_pressed("back"):
		stop()
		get_viewport().set_input_as_handled()


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "ThenNow"
	_layer.layer = 40
	_layer.visible = false
	add_child(_layer)
	_frame = Panel.new()
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_frame.add_theme_stylebox_override("panel", UiKit.box(Color(0, 0, 0, 0), Color(1.0, 0.86, 0.6, 0.75), 3, 2, 0))
	_layer.add_child(_frame)
	_photo = TextureRect.new()
	_photo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_photo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_photo.stretch_mode = TextureRect.STRETCH_SCALE
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/then_now.gdshader")
	_photo.material = _mat
	_layer.add_child(_photo)
	var top := PanelContainer.new()
	top.add_theme_stylebox_override("panel", UiKit.box(Color(0.02, 0.03, 0.05, 0.82), Color(1.0, 0.86, 0.6, 0.35), 8, 1, 10))
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.position = Vector2(0, 12)
	var v := UiKit.vbox(2)
	top.add_child(v)
	_title = UiKit.label("", 15, UiKit.TEXT, 600)
	v.add_child(_title)
	_sub = UiKit.caps("", Color(1.0, 0.86, 0.6, 0.9), 11)
	v.add_child(_sub)
	_layer.add_child(top)
	_caption = top
	top.resized.connect(_place_caption)
	app.get_viewport().size_changed.connect(_fit)


static func _compass(az: float) -> String:
	var names := ["north", "north-east", "east", "south-east", "south", "south-west", "west", "north-west"]
	return names[int(round(fposmod(az, 360.0) / 45.0)) % 8]
