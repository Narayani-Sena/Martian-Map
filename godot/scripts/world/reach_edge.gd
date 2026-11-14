class_name ReachEdge
extends Node
## The shrinking world in the 3D console (feature A3). In the suit-leak drill the crew breathes from the secondary
## oxygen pack, about 30 minutes (Apollo's Oxygen Purge System gave about that). The terrain shows everywhere they
## can still walk to and get home from on what is left: the rest dims and turns red behind a glowing edge that
## tightens as the minutes run down, and a banner says which havens are still in reach. The minutes run with the
## EVA clock (x1 in the helmet, faster when the EVA plays fast); the field is the server's /envelope from the crew's
## position, fetched again when they have moved 30 m.

const BUDGET_MIN := 30.0
const REFETCH_M := 30.0

var world: MarsWorld
var app                          # main.gd
var on := false
var minutes_left := NAN
var havens: Array = []           # [{name, needs_min}] from the last field
var _field_xy := Vector2.INF
var _tex: ImageTexture
var _req := 0
var _busy := false
var _banner: PanelContainer
var _b_title: Label
var _b_text: Label


func setup(w: MarsWorld, app_node) -> void:
	world = w
	app = app_node
	Mission.site_loaded.connect(func(): _stop())
	_banner = PanelContainer.new()
	_banner.name = "ReachBanner"
	_banner.add_theme_stylebox_override("panel", UiKit.box(Color(0.1, 0.01, 0.01, 0.84), Color(1.0, 0.3, 0.25, 0.75), 8, 1, 10))
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := UiKit.vbox(2)
	_banner.add_child(v)
	_b_title = UiKit.caps("", Color(1.0, 0.45, 0.4), 12)
	v.add_child(_b_title)
	_b_text = UiKit.label("", 15, UiKit.TEXT)
	v.add_child(_b_text)
	_banner.visible = false
	app.ui.add_child(_banner)


func _crew_xy() -> Vector2:
	if world.mode == "walk":
		return world.walker.xy()
	var st := Mission.state_at(Mission.eva_t)
	return st.get("xy", Mission.hab_xy())


func _process(delta: float) -> void:
	if world == null or not world.ready_terrain or not Mission.has_plan():
		return
	var leaking := Mission.suit_fault == "leak"
	if leaking and not on:
		_start()
	elif not leaking and on:
		_stop()
	if not on:
		return
	var rate := Mission.play_speed() if Mission.playing else 1.0
	minutes_left = maxf(0.0, minutes_left - delta * maxf(rate, 1.0) / 60.0)
	world.terrain_mesh.set_param("reach_min", minutes_left if _tex != null else -1.0)
	var here := _crew_xy()
	if not _busy and (not _field_xy.is_finite() or here.distance_to(_field_xy) > REFETCH_M):
		_fetch(here)
	_update_banner()


func _start() -> void:
	on = true
	minutes_left = BUDGET_MIN
	havens = []
	_field_xy = Vector2.INF
	_tex = null


func _stop() -> void:
	_req += 1
	on = false
	_busy = false
	minutes_left = NAN
	havens = []
	if world and world.terrain_mesh:
		world.terrain_mesh.set_param("reach_min", -1.0)
	if _banner:
		_banner.visible = false


func _fetch(xy: Vector2) -> void:
	_busy = true
	_req += 1
	var me := _req
	var ll := Mission.grid.to_lonlat(xy.x, xy.y)
	var hab := Mission.hab_xy()
	var hl := Mission.grid.to_lonlat(hab.x, hab.y)
	var q := Api.q({"lon": "%.7f" % ll.x, "lat": "%.7f" % ll.y, "hab_lon": "%.7f" % hl.x, "hab_lat": "%.7f" % hl.y,
		"minutes_left": "%.1f" % minutes_left, "reserve_min": "0"})
	var r: Dictionary = await Api.get_json("/api/sites/%s/envelope%s" % [Mission.site_id, q], 60.0)
	if me != _req:
		return
	_busy = false
	if not r["ok"] or not (r["data"] is Dictionary):
		_field_xy = xy   # try again after the next 30 m
		return
	var d: Dictionary = r["data"]
	var uri := str(d.get("needed_png", ""))
	var comma := uri.find(",")
	if comma < 0:
		return
	var img := Image.new()
	if img.load_png_from_buffer(Marshalls.base64_to_raw(uri.substr(comma + 1))) != OK:
		return
	_tex = ImageTexture.create_from_image(img)
	havens = d.get("havens", [])
	_field_xy = xy
	var g: Geo = Mission.grid4
	var tm: Variant = world.terrain_mesh
	tm.set_param("reach_tex", _tex)
	tm.set_param("reach_rect", Vector4(g.x_min, g.y_max, g.width * g.res, g.height * g.res))
	tm.set_param("reach_dims", Vector2i(img.get_width(), img.get_height()))


func _update_banner() -> void:
	var walk := world.mode == "walk"
	_banner.visible = on and not app.ui_hidden and (not walk or app.hud.visible)
	if not _banner.visible:
		return
	_b_title.text = "Suit leak · secondary oxygen · %d min left" % int(ceil(minutes_left))
	var parts := PackedStringArray()
	for h in havens:
		var need: Variant = h.get("needs_min")
		var nm := str(h.get("name", "haven")).to_upper()
		if need == null:
			parts.append("%s no way back" % nm)
		elif float(need) <= minutes_left:
			parts.append("%s IN REACH (%d min)" % [nm, int(ceil(float(need)))])
		else:
			parts.append("%s OUT OF REACH (needs %d min)" % [nm, int(ceil(float(need)))])
	_b_text.text = " · ".join(parts) if not parts.is_empty() else "Working out where you can still get home from…"
	_banner.reset_size()
	# helmet: above the minimap; orbit: above the timeline dock (the leak's alert card fills the top centre)
	var y: float = (app.ui.size.y - 300.0) if walk else (app.ui.size.y - 285.0)
	_banner.position = Vector2((app.ui.size.x - _banner.size.x) * 0.5, y)
