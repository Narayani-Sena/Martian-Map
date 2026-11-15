extends Node
## Martian Map · EVA Console — application shell.
## Builds the 3D world and the interface layers, runs the boot sequence against the FastAPI
## backend, routes input between panels and the 3D view, and drives alerts and visor effects.
##
## Command line (after `--`):  --capture=<dir>  scripted screenshot tour, then quit
##                             --tour=rover   only the rover-assisted part of the tour
##                             --tour=buddy   EV2's follow behaviour on autopilot (prints a metric)
##                             --tour=layers  how fast the drapes switch (prints per-layer timings)
##                             --quality=low|medium|high   --api=http://host:port   --mute

var world: MarsWorld
var ui: Control
var visor_layer: CanvasLayer
var visor: ColorRect
var visor_mat: ShaderMaterial
var plan_ui: Control
var top_bar: TopBar
var plan_panel: PlanPanel
var info: InfoPanel
var dock: BottomDock
var hud: HelmetHud
var tools: HelmetTools
var lake: LakeWater            # flood the crater (I): the ancient lake in 3D
var tower: LayerTower          # TOWER: the data layers lift off the terrain as a stack
var live: LiveLink             # the helmet's live link to the habitat console (web planner)
var radar: RadarCurtain        # Shift+J: Perseverance's ground radar hung under its track (Jezero)
var then_now: ThenNow          # Shift+P: the rover's photo where it was taken, wiped against the render
var reach: ReachEdge           # suit-leak drill: where the crew can still get home from on the secondary O2
var callouts: Callouts
var alerts: Alerts
var lightbox: Lightbox
var boot: BootScreen
var help: PanelContainer
var settings_panel: SettingsPanel
var coach: Coach
var director: Director
var cw_panel: CwPanel          # caution & warning list, log and catalogue (F3)
var cuff_menu: CuffMenu        # every crew action on big buttons (X / L3)
var voice: VoiceControl        # offline voice commands (Settings → CONTROLS)
var fps_label: Label
var tel := Telemetry.new()     # EV1's state for the HUD, the alarms and the voice status report
var monitor := CwMonitor.new() # telemetry -> caution & warning conditions
var _tel_acc := 0.0
var _fps_acc := 0.0
var _abort_hold := -1.0        # seconds End / R3 has been held: ABORT is a hold-to-confirm command
var _voice_abort_at := -1      # msec "suit abort" was heard: "suit confirm abort" within 6 s aborts
var _voice_testing := false
var _plan_t0 := 0
var tool := ""
var ui_hidden := false
var follow_crew := false
var capture_dir := ""
var tour := "full"
var _glitch := 0.0
var _alarm := 0.0
var _overlay_cache := {}        # url -> Texture2D, the last few drapes (switching back is instant)
var _overlay_order: Array = []
var _overlay_req := 0           # newest layer request; a slower earlier one must not overwrite it
var _overlay_layer := {}        # the draped layer's manifest entry ({} = imagery only)
var _overlay_url_now := ""      # the URL it was drawn from (dynamic layers change it with the plan)
const OVERLAY_KEEP := 16       # every layer of a site (~14 MB each at 1632 px with mipmaps)
# Drapes that depend only on the site build (the API also keeps them on disk): cached in user://cache too.
const STATIC_DRAPES := ["slope", "roughness", "sand", "elevation", "shielding", "skyview", "thermal", "thermal_day", "boulders", "geology",
	"science", "sand_conf", "terrain_conf", "scouted"]
var _alert_acc := 0.0
var _last_phase := ""
var _orbit_speed_index := 2
var _manual_hint_shown := false
var _cursor := -1   # Input.CursorShape currently set for the 3D view
var _boot_frames := 0       # frames drawn during the boot screen (-1 once the console is up)
var _boot_worst_ms := 0.0
var _boot_slow := 0
var _remember := true       # keep the window and camera between runs (off for capture tours)
var _guard_t := 0.0         # frame-rate guard: seconds and frames measured in this window
var _guard_frames := 0
var _guard_cool := 12.0     # seconds before it looks (boot, first shader compiles), and between steps
var _guard_steps := 0
var _guard_quiet := false   # a guard step is applying a setting: its own toast says why


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--capture="):
			capture_dir = a.substr(10)
		elif a.begins_with("--tour="):
			tour = a.substr(7)
	Controls.setup()
	UiKit.set_palette(str(Settings.get_value("palette")))
	UiKit.MIN_FONT = int(Settings.get_value("min_text"))
	UiKit.glove = bool(Settings.get_value("glove_mode"))
	UiKit.reduce_flashing = bool(Settings.get_value("reduce_flashing"))
	CW.reset()   # an autoload: after a site switch the conditions are checked afresh
	Mission.pick_initial_site()
	Quality.level = Quality.detect()
	UiKit.glass_blur = _glass_on()
	get_window().title = "Martian Map · EVA Console"
	get_window().min_size = Vector2i(1280, 720)
	_remember = capture_dir == ""   # scripted tours always start from the defaults
	if _remember:
		_restore_window()
	world = MarsWorld.new()
	world.name = "World"
	add_child(world)
	_build_ui()
	_apply_ui_scale()
	get_window().size_changed.connect(_apply_ui_scale)
	Settings.changed.connect(_on_setting_changed)
	Sfx.apply_volumes()
	_apply_render_settings()
	_boot()


## Frosted (blurred) panels: on, off, or auto = off on the Low preset (the blur is a full-screen copy
## and mip chain every frame: ~2 ms of a ~37 ms frame on the UHD 620).
func _glass_on() -> bool:
	var g := str(Settings.get_value("glass"))
	return g == "on" or (g == "auto" and Quality.level != "low")


func _apply_ui_scale() -> void:
	UiKit.apply_ui_scale(get_window(), str(Settings.get_value("ui_scale")))
	var w := get_window()
	if _remember and w.mode == Window.MODE_WINDOWED:
		Settings.set_state("window_size", w.size)   # the windowed size, kept while fullscreen too


## Last run's window: size and place (if that spot is still on a screen), or maximised / fullscreen.
func _restore_window() -> void:
	var w := get_window()
	var sz: Variant = Settings.get_state("window_size")
	var pos: Variant = Settings.get_state("window_pos")
	if sz is Vector2i and pos is Vector2i:
		for i in DisplayServer.get_screen_count():
			var r := DisplayServer.screen_get_usable_rect(i)
			if r.has_point((pos as Vector2i) + Vector2i(60, 12)):   # the title bar must be reachable
				w.size = (sz as Vector2i).clamp(w.min_size, r.size)
				w.position = pos
				break
	match str(Settings.get_state("window_mode", "windowed")):
		"fullscreen":
			w.mode = Window.MODE_FULLSCREEN
		"maximized":
			w.mode = Window.MODE_MAXIMIZED


## Window and camera for next time (on closing, and before switching sites).
func _save_state() -> void:
	if not _remember:
		return
	var w := get_window()
	match w.mode:
		Window.MODE_FULLSCREEN, Window.MODE_EXCLUSIVE_FULLSCREEN:
			Settings.set_state("window_mode", "fullscreen")
		Window.MODE_MAXIMIZED:
			Settings.set_state("window_mode", "maximized")
		_:
			Settings.set_state("window_mode", "windowed")
			Settings.set_state("window_size", w.size)
			Settings.set_state("window_pos", w.position)
	if world and world.ready_terrain and Mission.site_id != "":
		Settings.set_state("camera_" + Mission.site_id, world.camera_state())
	Settings.save_state()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		_save_state()


## A setting changed in the settings panel: apply it straight away.
func _on_setting_changed(key: String) -> void:
	match key:
		"glass":
			UiKit.set_glass_blur(_glass_on())
		"ui_scale":
			_apply_ui_scale()
		"quality":
			Quality.level = Quality.detect()
			Quality.apply(get_viewport(), world.env, world.sun)
			_apply_render_settings()
			world.sun.directional_shadow_max_distance = float(Quality.get_value("shadow_dist_walk" if world.mode == "walk" else "shadow_dist_orbit"))
			world.dust.amount = int(Quality.get_value("dust"))
			UiKit.set_glass_blur(_glass_on())
			if not _guard_quiet:
				alerts.toast("Quality: %s. The terrain mesh and texture sizes follow on the next start." % Quality.level.capitalize(), "info")
		"visor_fx":
			visor.visible = Settings.visor_fx and world.mode == "walk"
		"vol_ui", "vol_ambience", "vol_alerts":
			Sfx.apply_volumes()
		"render_scale", "fps_cap", "vsync", "show_fps":
			_apply_render_settings()
		"palette":
			UiKit.set_palette(str(Settings.get_value("palette")))
			alerts.toast("Status colours: %s. Panels pick them up as they refresh; everything on the next start." % ("colour-blind safe" if UiKit.palette_name == "cvd" else "standard"), "info")
		"min_text":
			UiKit.set_min_font(int(Settings.get_value("min_text")), ui)
		"glove_mode":
			UiKit.glove = bool(Settings.get_value("glove_mode"))
			ui.theme = UiKit.theme()
			_rebuild_hud()
			alerts.toast("Glove mode %s. X (or L3) opens the cuff menu with every crew action." % ("on: bigger buttons" if UiKit.glove else "off"), "info")
		"reduce_flashing":
			UiKit.reduce_flashing = bool(Settings.get_value("reduce_flashing"))
		"hud_declutter", "hud_opacity":
			hud.apply_view_settings()
		"hud_tint":
			HelmetHud.set_tint(str(Settings.get_value("hud_tint")))
			_rebuild_hud()
		"deadzone":
			Controls.set_deadzone(Settings.deadzone)
		"voice_commands":
			_apply_voice()


## Render scale override, frame-rate cap, v-sync and the FPS readout (Settings → GRAPHICS).
func _apply_render_settings() -> void:
	var vp := get_viewport()
	var rs := str(Settings.get_value("render_scale"))
	var sc := clampf(rs.to_float(), 0.5, 1.0) if rs.is_valid_float() else float(Quality.get_value("scale"))
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if sc < 0.99 else Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = sc
	if capture_dir == "":   # scripted tours and benchmarks keep the engine's frame pacing
		Engine.max_fps = int(Settings.get_value("fps_cap"))
	if not OS.get_cmdline_args().has("--disable-vsync"):
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(Settings.get_value("vsync")) else DisplayServer.VSYNC_DISABLED)
	if fps_label:
		fps_label.visible = _fps_wanted()


## Frame-rate guard: a console that crawls is worse than a plainer one. After 6 s under 20 FPS in normal use it
## steps the graphics down one notch: the frosted glass first, then the quality preset this GPU is detected for
## (a saved High on an integrated GPU runs at about 8 FPS), then the 3D render scale. Each step is saved and said in a
## toast; the settings take it back. Never during scripted tours or recordings, nor while the window is in the
## background.
const GUARD_FPS := 20.0
const GUARD_WINDOW_S := 6.0


func _frame_guard(delta: float) -> void:
	if capture_dir != "" or _boot_frames >= 0 or _guard_steps >= 3:
		return
	var w := get_window()
	if not w.has_focus() or w.mode == Window.MODE_MINIMIZED or delta > 0.5:   # away, or a loading hitch
		_guard_t = 0.0
		_guard_frames = 0
		return
	if _guard_cool > 0.0:
		_guard_cool -= delta
		return
	_guard_t += delta
	_guard_frames += 1
	if _guard_t < GUARD_WINDOW_S:
		return
	var fps := _guard_frames / _guard_t
	_guard_t = 0.0
	_guard_frames = 0
	if fps >= GUARD_FPS:
		return
	_guard_quiet = true
	var step := _guard_step()
	_guard_quiet = false
	if step == "":
		_guard_steps = 3   # nothing left to lower
		return
	_guard_steps += 1
	_guard_cool = 5.0
	print("frame guard: %.1f fps -> %s" % [fps, step])
	alerts.toast("Running at %d FPS, so %s to keep the console smooth. Settings (F2) → Graphics changes it back." % [int(round(fps)), step], "info")


## One notch down; what it did, or "" when there is nothing left to lower.
func _guard_step() -> String:
	if _glass_on():
		Settings.set_value("glass", "off")
		return "the frosted glass is off"
	var order := ["low", "medium", "high"]
	var gpu := Quality.detect_gpu()
	var at := order.find(Quality.level)
	if at > order.find(gpu) or (at > 0 and _guard_steps >= 1):
		var to: String = gpu if at > order.find(gpu) else order[at - 1]
		Settings.set_value("quality", to)
		return "the quality is now %s (mesh and texture sizes follow on the next start)" % to.capitalize()
	var rs := str(Settings.get_value("render_scale"))
	var sc := clampf(rs.to_float(), 0.5, 1.0) if rs.is_valid_float() else float(Quality.get_value("scale"))
	if sc > 0.61:
		Settings.set_value("render_scale", "0.6")
		return "the 3D render scale is 60 %"
	return ""


## The FPS readout, when it is switched on in the settings (never in a trailer recording).
func _fps_wanted() -> bool:
	return bool(Settings.get_value("show_fps")) and not tour.begins_with("trailer")


## The helmet HUD again from scratch (its colours and button sizes are set when it is built).
func _rebuild_hud() -> void:
	if hud == null:
		return
	var was := hud.visible
	var idx := hud.get_index()
	hud.queue_free()
	hud = HelmetHud.new()
	hud.world = world
	hud.tel = tel
	hud.tools = tools
	ui.add_child(hud)
	ui.move_child(hud, idx)
	_connect_hud()
	_feed_minimap()
	if was:
		hud.power_on()


func _connect_hud() -> void:
	hud.exit_requested.connect(func(): _set_mode("orbit"))
	hud.play_requested.connect(_walk_play_toggle)
	hud.autopilot_requested.connect(func(): world.toggle_autopilot())
	hud.abort_requested.connect(_toggle_abort)
	hud.menu_requested.connect(_open_cuff_menu)


# ------------------------------------------------------------------ UI construction
func _build_ui() -> void:
	visor_layer = CanvasLayer.new()
	visor_layer.layer = 1
	add_child(visor_layer)
	visor = ColorRect.new()
	visor.set_anchors_preset(Control.PRESET_FULL_RECT)
	visor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	visor_mat = ShaderMaterial.new()
	visor_mat.shader = load("res://shaders/visor.gdshader")
	visor.material = visor_mat
	visor.visible = false
	visor_layer.add_child(visor)

	var layer := CanvasLayer.new()
	layer.layer = 2
	add_child(layer)
	ui = Control.new()
	ui.name = "UI"
	ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.theme = UiKit.theme()
	layer.add_child(ui)

	callouts = Callouts.new()
	callouts.world = world
	ui.add_child(callouts)

	plan_ui = Control.new()
	plan_ui.set_anchors_preset(Control.PRESET_FULL_RECT)
	plan_ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(plan_ui)
	top_bar = TopBar.new()
	plan_ui.add_child(top_bar)
	plan_panel = PlanPanel.new()
	plan_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	plan_panel.offset_left = 14
	plan_panel.offset_top = 72
	plan_panel.offset_right = 14 + 352
	plan_panel.offset_bottom = -222
	plan_ui.add_child(plan_panel)
	info = InfoPanel.new()
	info.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	info.offset_left = -14 - 360
	info.offset_right = -14
	info.offset_top = 72
	info.offset_bottom = -222
	plan_ui.add_child(info)
	dock = BottomDock.new()
	dock.world = world
	dock.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	dock.offset_left = 14
	dock.offset_right = -14
	dock.offset_top = -208
	dock.offset_bottom = -12
	plan_ui.add_child(dock)

	hud = HelmetHud.new()
	hud.world = world
	hud.tel = tel
	tel.world = world
	ui.add_child(hud)
	alerts = Alerts.new()
	ui.add_child(alerts)
	tools = HelmetTools.new()
	tools.name = "HelmetTools"
	tools.app = self
	add_child(tools)
	tools.setup(world, func(t: String, k: String): alerts.toast(t, k), _flashlight_layer)
	hud.tools = tools
	lake = LakeWater.new()
	lake.name = "LakeWater"
	add_child(lake)
	lake.setup(world, self, func(t: String, k: String): alerts.toast(t, k))
	lake.level_changed.connect(func(lv: float):
		if is_finite(lv) and str(_overlay_layer.get("id", "")) == "lake":
			_on_overlay(_overlay_layer, true))   # the draped depth map follows the water
	radar = RadarCurtain.new()
	radar.name = "RadarCurtain"
	world.add_child(radar)
	radar.setup(world, func(t: String, k: String): alerts.toast(t, k))
	reach = ReachEdge.new()
	reach.name = "ReachEdge"
	add_child(reach)
	reach.setup(world, self)
	then_now = ThenNow.new()
	then_now.name = "ThenNow"
	add_child(then_now)
	then_now.setup(self, world, func(t: String, k: String): alerts.toast(t, k))
	tower = LayerTower.new()
	tower.name = "LayerTower"
	world.add_child(tower)
	tower.setup(world, ui)
	live = LiveLink.new()
	live.name = "LiveLink"
	add_child(live)
	live.setup(self)
	help = _build_help()
	ui.add_child(help)
	settings_panel = SettingsPanel.new()
	ui.add_child(settings_panel)
	settings_panel.tour_requested.connect(_start_coach)
	settings_panel.export_requested.connect(_export_mission)
	settings_panel.import_requested.connect(_import_mission)
	settings_panel.test_alarms_requested.connect(func():
		settings_panel.close()
		CW.test_annunciators())
	settings_panel.alert_list_requested.connect(func():
		settings_panel.close()
		cw_panel.toggle(ui.size, "CATALOGUE"))
	settings_panel.voice_test_requested.connect(_voice_self_test)
	cw_panel = CwPanel.new()
	ui.add_child(cw_panel)
	cuff_menu = CuffMenu.new()
	cuff_menu.provider = _cuff_items
	cuff_menu.action.connect(_on_cuff_action)
	ui.add_child(cuff_menu)
	voice = VoiceControl.new()
	add_child(voice)
	voice.command.connect(_on_voice)
	voice.state_changed.connect(_on_voice_state)
	lightbox = Lightbox.new()
	ui.add_child(lightbox)
	coach = Coach.new()
	ui.add_child(coach)
	coach.finished.connect(func(_skipped: bool): Settings.set_value("first_run_done", true))
	director = Director.new()
	add_child(director)
	director.setup(self, ui)

	var fps_layer := CanvasLayer.new()
	fps_layer.layer = 4
	add_child(fps_layer)
	fps_label = UiKit.label("", 11, UiKit.TEXT, 500, true)
	fps_label.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	fps_label.position = Vector2(-10, -10)
	fps_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	fps_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	fps_label.add_theme_stylebox_override("normal", UiKit.box(Color(0, 0, 0, 0.55), Color(0, 0, 0, 0), 4, 0, 4))
	fps_label.visible = _fps_wanted()
	fps_layer.add_child(fps_label)

	var boot_layer := CanvasLayer.new()
	boot_layer.layer = 5
	add_child(boot_layer)
	boot = BootScreen.new()
	boot.theme = ui.theme
	boot_layer.add_child(boot)

	top_bar.mode_requested.connect(_set_mode)
	top_bar.help_requested.connect(_toggle_help)
	top_bar.settings_requested.connect(func(): settings_panel.toggle(ui.size))
	top_bar.demo_requested.connect(_play_demo)
	top_bar.tower_requested.connect(_toggle_tower)
	top_bar.site_requested.connect(_switch_site)
	top_bar.cw_requested.connect(func(): cw_panel.toggle(ui.size))
	alerts.list_requested.connect(func(): cw_panel.toggle(ui.size, "ACTIVE"))
	info.suit_drill_requested.connect(_suit_drill)
	plan_panel.stop_activated.connect(_select_stop)
	plan_panel.tool_changed.connect(_set_tool)
	plan_panel.undo_requested.connect(func(): _undo(false))
	info.overlay_requested.connect(_on_overlay)
	info.opacity_changed.connect(func(v: float): world.set_overlay_opacity(v))
	info.layer_toggled.connect(_on_layer_toggled)
	info.add_stop_here.connect(_add_stop)
	info.photo_requested.connect(func(item: Dictionary, tex: Texture2D): lightbox.show_photo(item, tex))
	info.ping_requested.connect(func(): world.scan_pulse(Mission.hab_xy()))
	info.drill_requested.connect(_storm_drill)
	dock.follow_toggled.connect(func(on: bool): follow_crew = on)
	world.stop_clicked.connect(_select_stop)
	world.label_hit = callouts.hit
	world.object_clicked.connect(_on_object_clicked)
	world.abort_arrived.connect(_on_abort_arrived)
	Mission.suggestions_changed.connect(func(): world.rebuild_suggestions())
	Mission.time_changed.connect(_on_time_for_sun)
	world.ground_clicked.connect(_on_ground_click)
	world.stop_moved.connect(_on_stop_moved)
	world.mode_changed.connect(_on_mode_changed)
	_connect_hud()
	world.manual_taken.connect(_on_manual_taken)
	Mission.playing_changed.connect(_on_playing_changed)
	alerts.glitch.connect(func(v: float): _glitch = maxf(_glitch, v))
	Mission.notify.connect(func(text: String, kind: String): alerts.toast(text, kind))
	Mission.plan_changed.connect(_on_plan_changed)
	Mission.plan_started.connect(func():
		_plan_t0 = Time.get_ticks_msec()
		top_bar.set_go(null))
	Mission.plan_failed.connect(func(msg: String): alerts.toast("Planning failed after %.1f s: %s" % [(Time.get_ticks_msec() - _plan_t0) / 1000.0, msg], "bad"))
	Mission.space_weather_changed.connect(func(): top_bar.set_space_weather(Mission.space_weather))
	Mission.selection_changed.connect(_on_selection)
	plan_ui.visible = false


func _on_selection(id: String) -> void:
	callouts.selected = id
	if info.current == "ROVER CAM":
		info.refresh_camera()


func _build_help() -> PanelContainer:
	var p := UiKit.glass(12, UiKit.PANEL_SOLID, Color(UiKit.ACCENT, 0.5), 18)
	p.custom_minimum_size = Vector2(900, 0)
	p.visible = false
	var v := UiKit.vbox(8)
	p.add_child(v)
	v.add_child(UiKit.label("Controls", 20, UiKit.TEXT, 700))
	var cols := UiKit.hbox(36)
	v.add_child(cols)
	var keys := [["Orbit view", ""], ["Left-drag", "rotate"], ["Right/middle-drag", "pan (the ground stays under the cursor)"], ["Wheel", "zoom toward the cursor"],
		["WASD · Q/E · R/F", "pan · turn · tilt"], ["Click a stop / label / the ground", "select · fly there · inspect"], ["Drag a stop or its label", "move it (re-plans)"], ["Double-click", "fly to point"],
		["Helmet view", ""], ["WASD / Shift / Space", "walk · lope · jump"], ["Hold right button · F", "look around · lock mouse-look"], ["Tab", "autopilot on/off"],
		["Anywhere", ""], ["V", "orbit ⇄ helmet"], ["Space / P", "play · pause the EVA"], ["[  ]", "slower / faster"], ["Home", "back to egress / home view"],
		["Ctrl+Z · Ctrl+Y", "undo · redo a mission edit"],
		["Caution & warning", ""], ["Enter · Shift+Enter", "acknowledge the top alert · all of them"], ["Backspace", "silence the alarm tone"],
		["F3", "alert list, log, catalogue"], ["Hold End", "ABORT EVA (hold again to cancel)"], ["X", "cuff menu (every crew action)"],
		["Helmet tools", ""], ["K · O", "ghost pacer · data flashlight"], ["N · B", "synthetic vision and snow poles · Earth light"],
		["T · Shift+T", "tag a hazard · a find where you look"], ["U · Y", "HUD-failure drill · skyline fix"],
		["I", "flood the crater: the ancient lake rises, then drains"],
		["H", "hide the interface"], ["C · G · L · J", "contours · grid · labels · terrain ping"], ["M · F11", "mute (alarms still sound) · fullscreen"], ["F2", "settings"], ["Esc", "back to the map · close"]]
	var pad := [["Gamepad", ""], ["Left stick", "walk (how far you push sets the pace) · pan the map"], ["Right stick", "look around · rotate and tilt the map"],
		["LB or L3 · A", "lope · jump"], ["RB", "autopilot on/off"], ["Triggers", "zoom in (right) · out (left)"], ["X · Y", "play/pause · orbit ⇄ helmet"],
		["B", "back · close"], ["D-pad ◀ ▶", "slower / faster"], ["D-pad ▲ ▼", "acknowledge · silence"], ["L3 · hold R3", "cuff menu · ABORT"],
		["Start · Back", "this help · hide the interface"], ["Voice", "\"suit status\", \"suit acknowledge\", \"suit next waypoint\" … (Settings → CONTROLS)"]]
	cols.add_child(_help_grid(keys))
	var right := UiKit.vbox(10)
	right.add_child(_help_grid(pad))
	right.add_child(UiKit.spacer(4.0))
	right.add_child(UiKit.wrap("New here? The guided tour points at each part of the console; the demo flies through a whole EVA on its own.", 13, UiKit.DIM))
	var acts := UiKit.hbox(8)
	acts.add_child(UiKit.button("SHOW ME AROUND", func():
		_toggle_help()
		_start_coach(), "The guided tour of the console"))
	acts.add_child(UiKit.button("▶ PLAY DEMO", func():
		_toggle_help()
		_play_demo(), "A hands-free fly-through: orbit, chase and helmet. Any input takes over."))
	right.add_child(acts)
	cols.add_child(right)
	v.add_child(UiKit.caps("press F1 or ? to close", UiKit.FAINT, 10))
	return p


func _help_grid(rows: Array) -> GridContainer:
	var g := UiKit.grid(2, 18, 4)
	for row in rows:
		var heading := str(row[1]) == ""
		g.add_child(UiKit.label(str(row[0]), 13, UiKit.ACCENT if heading else UiKit.TEXT, 600 if heading else 500, not heading))
		g.add_child(UiKit.label(str(row[1]), 13, UiKit.DIM))
	return g


# ------------------------------------------------------------------ boot
func _boot() -> void:
	boot.step("EVA console · %s preset on %s" % [Quality.level.to_upper(), RenderingServer.get_video_adapter_name()])
	boot.progress(0.04)
	await get_tree().create_timer(0.35).timeout
	boot.step("Linking to the mission server at %s" % Api.base_url)
	var ok := await Api.ensure_backend(func(t: String): boot.step(t))
	while not ok:
		boot.done("FAIL")
		boot.step("Mission server unreachable — retrying in 4 s")
		await get_tree().create_timer(4.0).timeout
		ok = await Api.ensure_backend()
	boot.failed = false
	boot.progress(0.12)
	await Mission.load_sites()
	var entry := Mission.site_entry(Mission.site_id)
	boot.set_subtitle("EVA console · %s" % str(entry.get("name", Mission.site_id)))
	boot.step("Site manifest: %s" % str(entry.get("name", Mission.site_id)))
	if not await Mission.load_site():
		boot.done("FAIL")
		return
	top_bar.set_site(str(Mission.site.get("name", "")))
	top_bar.set_sites(Mission.sites, Mission.site_id)
	get_window().title = "Martian Map · EVA Console · %s" % str(Mission.site.get("short_name", ""))
	boot.progress(0.2)
	var steps := {}
	var on_progress := func(text: String, p: float):
		if not steps.has(text):
			steps[text] = true
			boot.step(text)
		boot.progress(0.2 + p * 0.5)
	var ok2 := await Mission.load_terrain(on_progress)
	if not ok2:
		boot.done("FAIL")
		return
	var n := 2 * int(Quality.get_value("clip_n")) + 1
	boot.step("Building the terrain clipmap (%d vertices, GPU displacement)" % (n * n))
	await get_tree().process_frame
	world.setup_terrain()
	boot.progress(0.76)
	var clock := Mission.now_clock()
	boot.step("Mars24 clock locked: sol %d, %s LTST, Ls %.1f°" % [int(clock["sol"]), MarsTime.hms(float(clock["ltst"]), false), float(clock["ls"])])
	Mission.refresh_conditions()
	Mission.refresh_space_weather()
	Mission.refresh_weather_live()
	boot.step("Planning the EVA: A* over the 2 m cost grid, suit consumables, radio and dose")
	await Mission.request_plan()
	boot.progress(0.97)
	if Mission.has_plan():
		var tt: Dictionary = Mission.plan["totals"]
		boot.step("Plan %s · %s · %s · margin %d min" % ["GO" if bool(tt["go"]) else "NO-GO", Geo.fmt_dist(float(tt["dist_m"])), MarsTime.dur(float(tt["total_s"])), int(float(tt["min_margin_min"]))])
	else:
		boot.done("WARN")
	await get_tree().create_timer(0.5).timeout
	if capture_dir != "":
		await _shot("00_boot.png")
	boot.finish()
	var saved: Variant = Settings.get_state("camera_" + Mission.site_id) if _remember else null
	world.cinematic_intro(7.0, saved if saved is Dictionary else {})
	Sfx.loop("wind", true, -20.0)
	await get_tree().create_timer(1.3).timeout
	_reveal_ui()
	if capture_dir == "":
		_prefetch_drapes()
	if capture_dir != "":
		_capture_tour()


func _reveal_ui() -> void:
	if capture_dir != "":
		print("boot: %d frames, longest %.0f ms, %d over 100 ms" % [_boot_frames, _boot_worst_ms, _boot_slow])
	_boot_frames = -1   # stop counting
	plan_ui.visible = true
	UiKit.slide_in(top_bar, Vector2(0, -70), 0.0, 0.8)
	UiKit.slide_in(plan_panel, Vector2(-380, 0), 0.25, 0.9)
	UiKit.slide_in(info, Vector2(380, 0), 0.4, 0.9)
	UiKit.slide_in(dock, Vector2(0, 230), 0.55, 0.9)
	Sfx.play("whoosh", -12.0)
	await get_tree().create_timer(1.2).timeout
	_apply_voice()
	if capture_dir == "" and not bool(Settings.get_value("first_run_done")):
		await get_tree().create_timer(0.8).timeout
		_start_coach()   # first run: the guided tour instead of the welcome line
		return
	alerts.toast("Welcome to %s. Click a stop or the ground, press V for the helmet view, Space to play the EVA. F1 lists every key." % str(Mission.site.get("region", Mission.site.get("name", "Mars"))), "info")


## Switching sites reloads the console: ask first [V2 10080] (tours pass ask = false).
func _switch_site(id: String, ask := true) -> void:
	if id == Mission.site_id or Mission.planning:
		return
	var e := Mission.site_entry(id)
	if ask:
		UiKit.confirm(ui, "Switch to %s?" % str(e.get("name", id)),
			"The console reloads that site's terrain and plan. Your %s mission is saved and comes back when you return." % str(Mission.site.get("short_name", Mission.site_id)),
			"SWITCH SITE", func(): _switch_site(id, false))
		return
	alerts.toast("Switching to %s — loading its terrain and plan" % str(e.get("name", id)), "info")
	Sfx.play("whoosh", -10.0)
	_save_state()   # this site's camera, for when you come back
	await get_tree().create_timer(0.4).timeout
	Mission.switch_site(id)
	get_tree().reload_current_scene()


# ------------------------------------------------------------------ actions
func _select_stop(id: String) -> void:
	Mission.select_stop(id)
	var s := Mission.stop_by_id(id)
	if s.is_empty():
		return
	world.focus_xy(Mission.xy_of(float(s["lon"]), float(s["lat"])), 420.0)
	alerts.toast("%s — %s" % [str(s["name"]), str(s.get("science", "")).substr(0, 140)], "info")


func _set_tool(t: String) -> void:
	tool = t
	plan_panel.set_tool(t)
	if t == "add-stop":
		alerts.toast("Click the terrain to drop a new stop. Esc cancels.", "info")
	elif t == "place-pr":
		alerts.toast("Click the terrain to park PR-2 there (level, drivable ground). Esc cancels.", "info")
	_update_cursor()


## One owner for the 3D view's cursor: a tool's crosshair, a dragged stop, the hand over a stop or label.
func _update_cursor() -> void:
	var want := Input.CURSOR_ARROW
	if tool != "":
		want = Input.CURSOR_CROSS
	elif world.dragging_stop != "":
		want = Input.CURSOR_MOVE
	elif world.mode == "orbit" and world.hover_id != "":
		want = Input.CURSOR_POINTING_HAND
	if want != _cursor:
		_cursor = want
		Input.set_default_cursor_shape(want)


## A stop's beacon was dragged across the terrain: move it there and plan again.
func _on_stop_moved(id: String, xy: Vector2) -> void:
	var s := Mission.stop_by_id(id)
	if s.is_empty():
		return
	var ll := Mission.grid.to_lonlat(xy.x, xy.y)
	Mission.move_stop(id, ll.x, ll.y)
	Mission.select_stop(id)
	alerts.toast("Moved %s — re-planning. Ctrl+Z puts it back." % str(s.get("name", id)), "ok")
	Mission.request_plan()


func _on_ground_click(xy: Vector2) -> void:
	var ll := Mission.grid.to_lonlat(xy.x, xy.y)
	if not Mission.grid.contains_xy(xy.x, xy.y, 5.0):
		alerts.toast("That point is outside the 1 m terrain model.", "warn")
		return
	if tool == "add-stop":
		_add_stop(ll)
		_set_tool("")
		return
	if tool == "place-pr":
		Mission.set_dropoff(ll.x, ll.y)
		_set_tool("")
		alerts.toast("PR-2 drop-off placed — re-planning the drives and the walk", "ok")
		Mission.request_plan()
		return
	info.inspect(ll)


## The guided tour: shown once on the first run, and from SHOW ME AROUND in the settings and help.
## Each step rings a real control and says what it does (see Coach).
func _start_coach() -> void:
	if director.running:
		director.stop(true)
	if help.visible:
		_toggle_help()
	settings_panel.close()
	if world.mode == "walk":
		_set_mode("orbit")
		await get_tree().create_timer(1.2).timeout
	if ui_hidden:   # the tour points at the panels: bring them back
		ui_hidden = false
		_fade_plan_ui(true)
		await get_tree().create_timer(0.5).timeout
	var view := func() -> Rect2:
		var l := plan_panel.get_global_rect().end.x + 24.0
		var r := info.get_global_rect().position.x - 24.0
		var t := top_bar.get_global_rect().end.y + 24.0
		var b := dock.get_global_rect().position.y - 24.0
		return Rect2(l, t, r - l, b - t)
	var tabs := func() -> Rect2:
		var r := Rect2()
		for b in info._tab_btns.values():
			r = (b as Control).get_global_rect() if r.size == Vector2.ZERO else r.merge((b as Control).get_global_rect())
		return r
	coach.start([
		{"title": "Welcome to the EVA console", "text": "A one-minute tour of the controls. The console plans a walk on Mars over real HiRISE terrain, checks it for safety, and lets you walk it yourself in the helmet view.\n\nEnter or NEXT goes on; Esc skips."},
		{"title": "The stops", "text": "The EVA visits these stations in order. Click one to fly there. ADD STOP drops a new one on the terrain, and dragging a stop's marker on the map moves it. Each edit plans the route again, and Ctrl+Z undoes it.",
			"enter": func(): _scroll_plan_to(plan_panel._stops_box),
			"rect": func() -> Rect2: return plan_panel._stops_box.get_global_rect().intersection((plan_panel.get_child(0) as Control).get_global_rect())},
		{"title": "The 3D view", "text": "Left-drag rotates, right-drag pans (the ground stays under the cursor) and the wheel zooms toward the cursor. Click the ground to inspect it, double-click to fly there.",
			"rect": view},
		{"title": "Mission data", "text": "Conditions (sun, temperature, dust), space weather, the rover's camera, LAYERS to drape on the terrain (slope, hazard, walk-back time, radio coverage) and INSPECT for any point you click.",
			"rect": tabs},
		{"title": "The EVA timeline", "text": "The whole EVA from egress to ingress. Space plays it, click or drag to scrub, [ and ] change the speed. The suit consumables follow the playhead.",
			"rect": func() -> Rect2: return dock.get_global_rect()},
		{"title": "Into the helmet", "text": "HELMET (or V) puts you on the ground as EV1. Walk the route by hand with WASD, or let the autopilot walk it while the visor shows suit, navigation and walk-back time.",
			"rect": func() -> Rect2: return top_bar.mode_rect()},
		{"title": "Settings, help and the demo", "text": "The gear holds quality, text size, mouse and sound (F2), ? lists every key (F1), and DEMO flies through a whole EVA by itself. This tour is under the gear and in the help.",
			"rect": func() -> Rect2: return top_bar.demo_btn.get_global_rect().merge(top_bar.help_btn.get_global_rect())},
	])


## Scroll the plan panel so `c` (one of its rows) sits just under the panel's top.
func _scroll_plan_to(c: Control) -> void:
	var sc := plan_panel.get_child(0) as ScrollContainer
	var content := sc.get_child(0) as Control
	sc.scroll_vertical = maxi(0, int(c.global_position.y - content.global_position.y - 34.0))


func _play_demo() -> void:
	if coach.active():
		coach.stop(true)
	if help.visible:
		_toggle_help()
	settings_panel.close()
	director.play()


## TOWER (feature A2): the data layers lift off the terrain as a stack and settle back. Again stops it.
func _toggle_tower() -> void:
	if tower.running:
		tower.stop()
		return
	await play_tower()


## The tower shot: orbit view, the panels and stop labels out of the way, the camera beside the stack, the sheets
## up, a slow turn, and down again. interruptible: a key or click ends it (the demo handles input itself).
func play_tower(hold := LayerTower.HOLD_S, interruptible := true) -> void:
	if not world.ready_terrain or not Mission.has_plan() or tower.running:
		return
	if world.mode == "walk":
		_set_mode("orbit")
		await _wait(1.2)
	if not tower.load_sheets_ready():
		alerts.toast("Composing the layer tower on the mission server…", "info")
	if not await tower.load_sheets():
		alerts.toast("The layer tower could not be loaded from the mission server", "bad")
		return
	var labels_were := world.show_labels
	world.set_layer_visible("labels", false)
	if plan_ui.visible:
		_fade_plan_ui(false)
	var cam_was := {"t": world.orbit.target, "d": world.orbit.dist, "y": world.orbit.yaw, "p": world.orbit.pitch}
	world.orbit.fly_to(tower.focus(), tower.span() * 2.0 + 2600.0, world.orbit.yaw, deg_to_rad(24.0), 2.2)
	tower.interruptible = interruptible
	await tower.play(hold)
	world.set_layer_visible("labels", labels_were)
	if not ui_hidden and world.mode == "orbit":
		_fade_plan_ui(true)
	if interruptible and world.mode == "orbit":
		world.orbit.fly_to(cam_was["t"], cam_was["d"], cam_was["y"], cam_was["p"], 1.8)


## Ctrl+Z / Ctrl+Y: step through the mission's edit history and re-plan.
func _undo(redo: bool) -> void:
	var what := Mission.redo() if redo else Mission.undo()
	if what == "":
		alerts.toast("Nothing to %s" % ("redo" if redo else "undo"), "info")
		return
	alerts.toast("%s: %s — re-planning" % ["Redone" if redo else "Undone", what], "ok")
	Mission.request_plan()


func _add_stop(ll: Vector2) -> void:
	var s := Mission.add_stop(ll.x, ll.y)
	alerts.toast("Added %s — re-planning the EVA" % str(s["name"]), "ok")
	Mission.request_plan()


func _overlay_size() -> int:
	return 1632 if Quality.level == "low" else 2048


func _overlay_url(L: Dictionary) -> String:
	var id := str(L["id"])
	var q := {"size": _overlay_size()}
	var dyn := str(L.get("dynamic", ""))
	if dyn == "walk" or dyn == "walkback":
		q.merge(Mission.walk_query())
	if dyn == "walkback":
		var hv := Mission.haven_lonlat()
		q["hab_lon"] = hv.x
		q["hab_lat"] = hv.y
	if dyn == "comms":
		q["obs"] = Mission.observers()
		q["tgt"] = 2.0
	if dyn == "sun":   # terrain shadow at the EVA clock, in 2-minute steps (the sun moves 0.5 deg in that time)
		q["utc"] = MarsTime.to_iso(Mission.start_unix + snappedf(Mission.eva_t, 120.0))
	if dyn == "havens":   # ways home: every cell's fastest walk to the nearest haven (hab, PR-2)
		q.merge(Mission.walk_query())
		q["havens"] = Mission.havens_param()
	if dyn == "level" and lake != null and is_finite(lake.level):   # the lake's depth map at the 3D water's level
		q["level"] = lake.level
	return "/api/sites/%s/overlay/%s.png" % [Mission.site_id, id] + Api.q(q)


## Disk-cache name for drapes that only change when the site is rebuilt ("" = always ask the API).
func _overlay_disk_name(L: Dictionary) -> String:
	var id := str(L["id"])
	if str(L.get("dynamic", "")) != "" or not (STATIC_DRAPES.has(id) or id.begins_with("crism_")):
		return ""
	var stamp := str(Mission.site.get("built_utc", "")).md5_text().substr(0, 8)
	return "%s_%s_drape_%s_%d.png" % [Mission.site_id, stamp, id, _overlay_size()]


## The data flashlight needs a draped layer: pick one by id from the site's layer list.
func _flashlight_layer(id: String) -> void:
	for L in Mission.site.get("layers", []):
		if str(L.get("id", "")) == id:
			_on_overlay(L)
			return


## Drape layer L on the terrain. refresh = the same layer again because the plan changed under it
## (hazard, walk-back and radio depend on the plan): swap the picture in place, no toast or scan sweep.
func _on_overlay(L: Dictionary, refresh := false) -> void:
	var id := str(L["id"])
	_overlay_req += 1
	var my_req := _overlay_req
	if id == "":
		_overlay_layer = {}
		_overlay_url_now = ""
		world.set_overlay("", null, Mission.hab_xy())
		world.set_flow(null)
		world.set_way_home(PackedVector2Array())
		return
	if id == "lake" and not refresh and lake != null and not lake.on:
		lake.cycle()   # the lake layer brings the water up too (its level is set before the first await)
	var url := _overlay_url(L)
	_overlay_layer = L
	_overlay_url_now = url
	var t0 := Time.get_ticks_msec()
	var tex: Texture2D = _overlay_cache.get(url)
	if tex == null:
		if not refresh:
			alerts.toast("Draping %s …" % str(L["name"]), "info")
		tex = await Api.get_texture(url, _overlay_disk_name(L), true)
		if tex:
			_overlay_cache[url] = tex
			_overlay_order.append(url)
			while _overlay_order.size() > OVERLAY_KEEP:
				_overlay_cache.erase(_overlay_order.pop_front())
	if capture_dir != "":
		print("overlay %s ready in %d ms, size %s" % [id, Time.get_ticks_msec() - t0, str(tex.get_size()) if tex else "null"])
	if my_req != _overlay_req:
		return  # another layer was picked while this one loaded
	if tex == null:
		alerts.toast("Layer %s could not be loaded" % str(L["name"]), "bad")
		return
	_set_flow_for(L)
	if refresh:
		world.swap_overlay(id, tex)
		return
	var origin: Vector2 = Geo.xy_of(world.orbit.target) if world.mode == "orbit" else world.walker.xy()
	world.set_overlay(id, tex, origin, info.opacity())
	Sfx.play("scan", -6.0)


## Ways home (feature A1): with that layer draped, pulses run down the network toward the haven, and in the
## helmet a faint line marks the fastest way home from where you stand.
func _set_flow_for(L: Dictionary) -> void:
	if str(L.get("id", "")) != "ways_home":
		world.set_flow(null)
		world.set_way_home(PackedVector2Array())
		return
	var url := _overlay_url(L).replace("/overlay/ways_home.png", "/overlay/ways_home_data.png").replace("size=%d" % _overlay_size(), "size=1024")
	var tex: Texture2D = _overlay_cache.get(url)
	if tex == null:
		tex = await Api.get_texture(url, "", false)
		if tex:
			_overlay_cache[url] = tex
	if str(_overlay_layer.get("id", "")) == "ways_home":
		world.set_flow(tex)
	_way_home_from = Vector2.INF


var _way_home_from := Vector2.INF   # where the helmet's way-home line was last traced from
var _way_home_busy := false
var _way_home_acc := 0.0


func _update_way_home(delta: float) -> void:
	if world.mode != "walk" or str(_overlay_layer.get("id", "")) != "ways_home":
		if not world.way_home_pts.is_empty():
			world.set_way_home(PackedVector2Array())
			_way_home_from = Vector2.INF
		return
	_way_home_acc += delta
	var here: Vector2 = world.walker.xy()
	if _way_home_busy or _way_home_acc < 1.5 or (_way_home_from != Vector2.INF and here.distance_to(_way_home_from) < 8.0):
		return
	_way_home_acc = 0.0
	_way_home_busy = true
	_way_home_from = here
	var ll: Vector2 = Mission.grid.to_lonlat(here.x, here.y)
	var q := Mission.walk_query()
	q.merge({"lon": ll.x, "lat": ll.y, "havens": Mission.havens_param()})
	var r := await Api.get_json("/api/sites/%s/ways-home/path" % Mission.site_id + Api.q(q), 20.0)
	_way_home_busy = false
	if not r["ok"] or not (r["data"] is Dictionary) or not bool(r["data"].get("ok", false)):
		return
	var pts := PackedVector2Array([here])
	for c in r["data"]["path"]:
		pts.append(Mission.xy_of(float(c[0]), float(c[1])))
	world.set_way_home(pts)
	hud_way_home = {"minutes": float(r["data"].get("start_minutes", 0.0)), "haven": str(r["data"].get("haven", "Hab"))}


var hud_way_home := {}   # {"minutes", "haven"} for the HUD's "lost? walk downstream" line


func _on_object_clicked(h: Dictionary) -> void:
	Sfx.play("click", -6.0)
	if str(h.get("kind", "")) == "suggest":   # a SUGGEST STOPS beacon: add it to the route
		for sg in Mission.suggestions:
			if str((sg as Dictionary).get("id", "")) == str(h.get("id", "")):
				Mission.accept_suggestion(sg)
				alerts.toast("Added %s to the route — re-planning" % str((sg as Dictionary).get("name", "the stop")), "ok")
				Mission.request_plan()
				return
	alerts.toast("%s — %s" % [str(h.get("title", "")), str(h.get("sub", "")).to_lower()], "info")


## The terrain-shadow drape follows the EVA clock (a new picture every 2 minutes of EVA time).
func _on_time_for_sun(_t: float) -> void:
	if not _overlay_layer.is_empty() and str(_overlay_layer.get("dynamic", "")) == "sun":
		_refresh_dynamic_overlay()


## Re-fetch the draped layer when it depends on the plan and the plan's inputs changed.
func _refresh_dynamic_overlay() -> void:
	if _overlay_layer.is_empty() or str(_overlay_layer.get("dynamic", "")) == "":
		return
	if _overlay_url(_overlay_layer) != _overlay_url_now:
		_on_overlay(_overlay_layer, true)


## Fill user://cache with the site's static drapes in the background, so the first switch is instant too.
func _prefetch_drapes() -> void:
	await get_tree().create_timer(5.0).timeout
	for L in Mission.site.get("layers", []):
		var name := _overlay_disk_name(L)
		if name == "" or FileAccess.file_exists(Api.CACHE_DIR.path_join(name)):
			continue
		await Api.get_cached(_overlay_url(L), name)


func _on_layer_toggled(what: String, on: bool) -> void:
	match what:
		"contours":
			world.set_contours(on)
		"grid":
			world.set_grid(on)
		_:
			world.set_layer_visible(what, on)


func _storm_drill() -> void:
	if not Mission.sep_active:
		Mission.push_undo("start the storm drill")
	Mission.sep_active = true
	_alarm = 1.0   # the caution & warning monitor raises SOLAR PARTICLE EVENT from sep_active
	Mission.request_plan()


## Suit emergency drills: a leak (emergency) or a CO2 breakthrough (caution, warning, then emergency).
func _suit_drill(kind: String) -> void:
	Mission.set_drill(kind)
	if kind == "":
		alerts.toast("Drill ended: the suit is healthy again. Acknowledge any alerts still listed (Enter).", "ok")
		return
	alerts.toast({"leak": "SUIT LEAK DRILL: pressure is falling. Watch the alarm, acknowledge it (Enter), then abort (hold End).",
		"co2": "CO₂ DRILL: the scrubber is breaking through. Watch ppCO₂ climb through caution, warning and emergency."}[kind], "warn")
	if world.mode != "walk" and not Mission.playing:
		Mission.set_playing(true)   # the suit is only monitored while the EVA runs


func _set_mode(mode: String) -> void:
	if mode == "walk":
		world.enter_walk()
	else:
		world.exit_walk()


func _on_mode_changed(mode: String) -> void:
	top_bar.set_mode(mode)
	Sfx.play("whoosh", -8.0, 0.9 if mode == "walk" else 1.2)
	if mode == "walk":
		_fade_plan_ui(false)
		visor.visible = Settings.visor_fx
		var tw := create_tween()
		visor_mat.set_shader_parameter("strength", 0.0)
		visor_mat.set_shader_parameter("flicker", 1.0)
		tw.tween_interval(0.6)
		tw.tween_method(func(v: float): visor_mat.set_shader_parameter("strength", v), 0.0, 1.0, 1.0)
		tw.parallel().tween_method(func(v: float): visor_mat.set_shader_parameter("flicker", v), 1.0, 0.0, 1.2)
		_orbit_speed_index = Mission.speed_index
		var walking_home: bool = world.abort_active() and not world.abort_done and Mission.playing
		Mission.set_playing(false)
		Mission.speed_index = 0   # real time: you walk at the planned pace
		if walking_home:
			Mission.set_playing(true)   # an abort walk goes on, in real time: nobody stands still in an abort
		Mission.playing_changed.emit(Mission.playing)
		await get_tree().create_timer(0.9).timeout
		if world.mode != "walk":
			return   # left again during the transition
		hud.power_on()
		Sfx.loop("suit", true, -22.0)
		Sfx.loop("breath", true, -18.0)
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if not director.running:
			alerts.toast("Helmet view. Hold the right button (or press F) to look around, WASD to walk, P to walk the plan. MAP VIEW (or V / Esc) brings you back.", "info")
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		Mission.speed_index = _orbit_speed_index
		Mission.playing_changed.emit(Mission.playing)
		hud.power_off()
		Sfx.loop("suit", false)
		Sfx.loop("breath", false)
		var tw2 := create_tween()
		tw2.tween_method(func(v: float): visor_mat.set_shader_parameter("strength", v), 1.0, 0.0, 0.6)
		tw2.tween_callback(func(): visor.visible = false)
		if not ui_hidden:
			_fade_plan_ui(true)


func _fade_plan_ui(show: bool) -> void:
	var tw := create_tween()
	if show:
		plan_ui.visible = true
		tw.tween_property(plan_ui, "modulate:a", 1.0, 0.5)
	else:
		tw.tween_property(plan_ui, "modulate:a", 0.0, 0.4)
		tw.tween_callback(func(): plan_ui.visible = false)


func _toggle_help() -> void:
	help.visible = not help.visible
	if help.visible:
		help.reset_size()
		help.position = (ui.size - help.size) * 0.5
		UiKit.appear(help, 0.0, 0.25)
	Sfx.play("toggle", -6.0)


func _on_plan_changed() -> void:
	var tt: Dictionary = Mission.plan["totals"]
	top_bar.set_go(bool(tt["go"]))
	var route := PackedVector2Array()
	var p: Dictionary = Mission.plan["profile"]
	var lons: Array = p["lon"]
	var lats: Array = p["lat"]
	for i in range(0, lons.size(), 2):
		route.append(Mission.xy_of(float(lons[i]), float(lats[i])))
	tel.route = route
	_feed_minimap()
	_refresh_dynamic_overlay()
	if _plan_t0 > 0:   # the result, within a second of it arriving (NASA-STD-3001 Table 10.2-1)
		alerts.toast("Plan ready in %.1f s: %s · %s · margin %d min" % [(Time.get_ticks_msec() - _plan_t0) / 1000.0, "GO" if bool(tt["go"]) else "NO-GO",
			Geo.fmt_dist(float(tt["dist_m"])), int(float(tt["min_margin_min"]))], "ok" if bool(tt["go"]) else "warn")
	if tel.abort_active:   # the plan changed under an abort: redraw the way home from where the crew is
		var here := world.crew_xy()
		_end_abort(true)
		_start_abort(true, here)


func _feed_minimap() -> void:
	hud.minimap.route = tel.route
	hud.minimap.grid = Mission.grid
	hud.minimap.tex = Mission.site_texture


## Play in the helmet: if you were walking by hand, pick the plan up from the nearest route point.
func _walk_play_toggle() -> void:
	if Mission.playing:
		Mission.set_playing(false)
		return
	if not world.walker.autopilot:
		world.rejoin_route()
	Mission.set_playing(true)


func _on_manual_taken() -> void:
	if not _manual_hint_shown:
		_manual_hint_shown = true
		alerts.toast("Walking by hand: the EVA clock is paused and EV2 sticks with you. Tab or P picks the plan up again from the nearest point of the route.", "info")


## When playback starts in orbit view close to the crew, follow them so they don't walk out of frame.
func _on_playing_changed(on: bool) -> void:
	if not on or world.mode != "orbit" or follow_crew or not Mission.has_plan() or not world.ready_terrain:
		return
	var st := Mission.state_at(Mission.eva_t)
	var crew_p := world.td.world_at(st["xy"])
	if world.camera.global_position.distance_to(crew_p) < 1500.0:
		follow_crew = true
		dock.set_follow(true)
		alerts.toast("The camera follows the crew while the EVA plays. Switch off FOLLOW CREW to look around freely.", "info")


# ------------------------------------------------------------------ abort, cuff menu, voice, files
## ABORT EVA (hold End / R3, the HUD button, the cuff menu or "suit abort … confirm abort"): a red route
## straight back to the haven and the HUD navigating to it. The crew turns for home at once: on autopilot (and in
## the orbit view) they walk the red route on the EVA clock at the planner's walk-back pace; walking by hand you
## keep control and follow the chevrons, and TAB hands the walk home to the autopilot. Works with the interface
## hidden: an emergency response that does not depend on the display [V2 10178]. The same commands cancel it.
func _toggle_abort() -> void:
	if tel.abort_active:
		_end_abort()
	else:
		_start_abort()


func _end_abort(quiet := false) -> void:
	tel.abort_active = false
	world.set_abort_route(PackedVector2Array())
	CW.acknowledge("abort")
	dock._on_time(Mission.eva_t)   # the phase chip goes back to the plan's
	if not quiet:
		alerts.toast("Abort cancelled: back on the plan.", "ok")


## quiet: a re-plan redrawing the way home from where the crew is (no toast, the clock left as it was).
func _start_abort(quiet := false, from_xy := Vector2.INF) -> void:
	if not world.ready_terrain or not Mission.has_plan():
		return
	var walk := world.mode == "walk"
	if Mission.in_cabin(Mission.eva_t) or (walk and world.walker.riding):
		if not quiet:
			alerts.toast("The crew is aboard %s: they are already in the safe haven, and the drive home goes on." % Mission.haven_name(), "info")
		return
	var from: Vector2 = from_xy if from_xy.is_finite() else world.crew_xy()
	var pts := world.abort_path(from)
	world.set_abort_route(pts)
	tel.abort_active = true
	tel.abort_target = Mission.haven_xy()
	var wb := world.td.layer_value("walkback", from.x, from.y, -1.0)
	var length := world.abort_length()
	world.abort_speed = clampf(length / wb, 0.3, 1.5) if wb > 1.0 and length > 1.0 else 0.75
	dock._on_time(Mission.eva_t)
	if quiet:
		return
	if world.abort_done:
		alerts.toast("EVA ABORT: the crew is already at %s. Hold End again to cancel." % Mission.haven_name(), "bad")
		return
	var auto := not walk or world.walker.autopilot
	if auto and not world.abort_done:
		Mission.set_playing(true)   # nobody stands still in an abort
	var how := ("the autopilot is walking the crew home along the red route (×%d; P pauses)" % int(Mission.play_speed())) if auto \
		else "follow the red chevrons, or press TAB and the autopilot walks you home"
	alerts.toast("EVA ABORT: %s walk back to %s; %s. Hold End again to cancel." % [MarsTime.dur(wb) if wb >= 0.0 else "an unknown", Mission.haven_name(), how], "bad")


func _on_abort_arrived() -> void:
	Mission.set_playing(false)
	CW.acknowledge("abort")   # home: the abort is complete, so its warning ("abort under way") leaves the banner (the log keeps it)
	alerts.toast("Abort complete: the crew is back at %s at %s. CANCEL ABORT returns to the plan." % [Mission.haven_name(), MarsTime.clock(Mission.eva_t)], "ok")


func _open_cuff_menu() -> void:
	if cuff_menu.visible:
		cuff_menu.close()
	else:
		cuff_menu.open(ui.size)


func _cuff_items() -> Array:
	var walk := world.mode == "walk"
	var top := CW.top()
	return [
		{"id": "ack", "text": "ACKNOWLEDGE · " + (str(top["title"]) if not top.is_empty() else "no alert"), "enabled": not top.is_empty()},
		{"id": "silence", "text": "SILENCE THE ALARM TONE", "enabled": not top.is_empty()},
		{"id": "status", "text": "STATUS REPORT (spoken)"},
		{"id": "task", "text": "TICK THE NEXT TASK", "enabled": not Mission.cuff_station(Mission.eva_t).is_empty()},
		{"id": "auto", "text": "AUTOPILOT OFF" if world.walker.autopilot else "AUTOPILOT ON", "enabled": walk},
		{"id": "play", "text": "PAUSE THE EVA" if Mission.playing else "PLAY THE EVA", "enabled": Mission.has_plan()},
		{"id": "view", "text": "MAP VIEW" if walk else "HELMET VIEW"},
		{"id": "list", "text": "ALERT LIST AND LOG"},
		{"id": "cancel_abort" if tel.abort_active else "abort", "text": "CANCEL ABORT" if tel.abort_active else "ABORT EVA (press twice)"},
	]


func _on_cuff_action(id: String) -> void:
	match id:
		"ack":
			CW.acknowledge()
		"silence":
			CW.silence()
		"status":
			var t := tel.status_report()
			CW.say(t)
			alerts.toast(t, "info")
		"task":
			var n := hud.tick_next_task()
			alerts.toast(("Ticked: " + n) if n != "" else "Every task here is ticked.", "ok")
		"auto":
			world.toggle_autopilot()
		"play":
			if world.mode == "walk":
				_walk_play_toggle()
			else:
				Mission.set_playing(not Mission.playing)
		"view":
			_set_mode("orbit" if world.mode == "walk" else "walk")
		"list":
			cw_panel.toggle(ui.size)
		"abort", "cancel_abort":
			_toggle_abort()


func _apply_voice() -> void:
	if voice == null or capture_dir != "":
		return
	if bool(Settings.get_value("voice_commands")):
		voice.start()
	else:
		voice.stop()


func _on_voice_state(state: String, detail: String) -> void:
	var col: Color = {"listening": UiKit.GOOD, "error": UiKit.BAD, "starting": UiKit.CAUTION, "test": UiKit.CAUTION}.get(state, UiKit.DIM)
	settings_panel.set_voice_status("Voice: %s%s" % [state, (" · " + detail) if detail != "" else ""], col)
	if _voice_testing and state == "off":
		_voice_testing = false
		alerts.toast("Voice self-test FAILED: the recogniser heard nothing it knew.", "bad")
		_apply_voice()
	elif state == "listening" and not _voice_testing:
		alerts.toast("Voice commands on: say \"suit status\", \"suit acknowledge\", \"suit next waypoint\", \"suit turn back time\" …", "info")
	elif state == "error":
		alerts.toast("Voice commands unavailable: %s" % detail, "warn")
		_voice_testing = false


func _voice_self_test() -> void:
	_voice_testing = true
	voice.self_test("suit status")


func _on_voice(text: String, conf: float) -> void:
	if _voice_testing:
		_voice_testing = false
		var ok := text == "suit status"
		alerts.toast("Voice self-test %s: heard \"%s\" (confidence %.2f)." % ["PASSED" if ok else "FAILED", text, conf], "ok" if ok else "bad")
		settings_panel.set_voice_status("Voice self-test %s: \"%s\" %.2f" % ["passed" if ok else "failed", text, conf], UiKit.GOOD if ok else UiKit.BAD)
		voice.stop()
		_apply_voice()
		return
	alerts.toast("Voice: \"%s\"" % text, "info")
	match text:
		"suit acknowledge":
			if not CW.acknowledge():
				CW.say("Nothing to acknowledge.")
		"suit silence":
			CW.silence()
		"suit status":
			CW.say(tel.status_report())
		"suit next waypoint":
			var tgt := Mission.next_target(Mission.eva_t)
			if not tgt.is_empty():
				var xy: Vector2 = tel.d.get("xy", Mission.hab_xy())
				var txy: Vector2 = tgt["xy"]
				CW.say("Next, %s, %d metres, bearing %03d." % [str(tgt["name"]), int(xy.distance_to(txy)), int(Geo.bearing_deg(xy, txy))])
		"suit turn back time":
			var m := float(tel.d.get("turn_in_min", NAN))
			CW.say("Turn back in %d minutes, by %s local time." % [int(maxf(m, 0.0)), str(tel.d.get("turn_by", ""))] if is_finite(m) else "No plan yet.")
		"suit autopilot on":
			if world.mode == "walk" and not world.walker.autopilot:
				world.toggle_autopilot()
		"suit autopilot off":
			if world.mode == "walk" and world.walker.autopilot:
				world.toggle_autopilot()
		"suit play":
			if world.mode == "walk":
				if not Mission.playing:
					_walk_play_toggle()
			else:
				Mission.set_playing(true)
		"suit pause":
			Mission.set_playing(false)
		"suit helmet view":
			_set_mode("walk")
		"suit map view":
			_set_mode("orbit")
		"suit check task":
			var n := hud.tick_next_task()
			CW.say(("Checked, " + n) if n != "" else "All tasks are checked.")
		"suit abort":
			_voice_abort_at = Time.get_ticks_msec()
			CW.say("Say confirm abort to abort the EVA.")
		"suit confirm abort":
			if _voice_abort_at >= 0 and Time.get_ticks_msec() - _voice_abort_at < 6000 and not tel.abort_active:
				_toggle_abort()
				CW.say("Aborting. Follow the red route home.")
			_voice_abort_at = -1
		"suit cancel abort":
			if tel.abort_active:
				_toggle_abort()
		"suit alert list":
			cw_panel.toggle(ui.size)
		"suit cuff menu":
			_open_cuff_menu()


func _export_mission() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.json ; Martian Map mission"])
	fd.current_file = "%s_mission.json" % Mission.site_id
	fd.title = "Export mission"
	fd.file_selected.connect(func(path: String):
		var ok := Mission.export_mission(path)
		alerts.toast(("Mission saved: " + path) if ok else ("Could not write " + path), "ok" if ok else "bad")
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	ui.add_child(fd)
	fd.popup_centered_ratio(0.6)


func _import_mission() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.filters = PackedStringArray(["*.json ; Martian Map mission"])
	fd.title = "Import mission"
	fd.file_selected.connect(func(path: String):
		var err := Mission.import_mission(path)
		if err == "":
			alerts.toast("Mission loaded from %s: re-planning. Ctrl+Z undoes it." % path.get_file(), "ok")
			Mission.request_plan()
		else:
			alerts.toast("Not imported: " + err, "bad")
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	ui.add_child(fd)
	fd.popup_centered_ratio(0.6)


# ------------------------------------------------------------------ frame + input
func _process(delta: float) -> void:
	if _boot_frames >= 0:   # boot screen: how smooth is it?
		_boot_frames += 1
		if _boot_frames > 2:   # the first frames include the window opening
			_boot_worst_ms = maxf(_boot_worst_ms, delta * 1000.0)
			if delta > 0.1:
				_boot_slow += 1
	_update_cursor()
	_frame_guard(delta)
	_tel_acc += delta
	if _tel_acc >= 0.12:   # EV1's state ~8 times a second, then the caution & warning checks
		_tel_acc = 0.0
		tel.demo = director.running or tour.begins_with("trailer")   # a recording is one demo: no mode-change notes
		tel.update()
		monitor.check(tel.d)
	alerts.set_helmet(world.mode == "walk" and hud.visible)
	_update_way_home(delta)
	if _abort_hold >= 0.0:
		_abort_hold += delta
		if _abort_hold >= HelmetHud.HOLD_S:
			_abort_hold = -1.0
			_toggle_abort()
	if fps_label and fps_label.visible:
		_fps_acc += delta
		if _fps_acc > 0.5:
			_fps_acc = 0.0
			var fps := Engine.get_frames_per_second()
			fps_label.text = " %d FPS · %.1f ms · %s %d%% " % [int(fps), 1000.0 / maxf(fps, 1.0), Quality.level, int(round(get_viewport().scaling_3d_scale * 100.0))]
	_glitch = maxf(0.0, _glitch - delta * 1.6)
	if Mission.sep_active and world.mode == "walk":
		_alarm = maxf(_alarm - delta * 0.4, 0.35)
	else:
		_alarm = maxf(0.0, _alarm - delta * 0.4)
	if visor.visible:
		visor_mat.set_shader_parameter("glitch", _glitch)
		visor_mat.set_shader_parameter("yaw", world.walker.yaw)
		var met := float(hud.info.get("met", 200.0))
		visor_mat.set_shader_parameter("fog", clampf((met - 250.0) / 300.0, 0.0, 0.6))
		visor_mat.set_shader_parameter("alarm", Color(1.0, 0.2, 0.15, _alarm * 0.35))
		Sfx.set_loop_pitch("breath", clampf(met / 260.0, 0.8, 1.5))
	if follow_crew and world.mode == "orbit" and Mission.has_plan() and Mission.playing:
		world.orbit.target = world.td.world_at(world.crew_xy())   # the plan, or the walk home during an abort
		if not director.running:   # the demo's chase camera rides closer than this
			world.orbit.dist = clampf(world.orbit.dist, 60.0, 600.0)
	_alert_acc += delta
	if _alert_acc > 0.5 and world.mode == "orbit" and Mission.playing and not world.abort_active():   # no plan toasts on the way home
		_alert_acc = 0.0
		var st2 := Mission.state_at(Mission.eva_t)
		var ev: Dictionary = st2["event"]
		var phase := "%s|%s" % [str(st2["phase"]), str(ev.get("name", ""))]
		if phase != _last_phase:
			_last_phase = phase
			var kind := str(ev.get("kind", ""))
			if kind == "walk":   # arriving on station is an advisory from the caution & warning monitor
				alerts.toast("Walking: %s" % str(ev["name"]), "info")
			elif kind == "drive":
				alerts.toast("%s — crew in shirt-sleeves, suits on the suitports" % str(ev["name"]), "info")
			elif kind == "ingress":
				alerts.toast("Back in PR-2 through the suitports" if Mission.has_rover() else "Back at the habitat — ingress", "ok")


## Shortcuts, as input actions (see Controls): keyboard and gamepad buttons alike.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_released("abort"):
		_abort_hold = -1.0   # let go before the second was up: no abort
		return
	if not (event is InputEventKey or event is InputEventJoypadButton) or not event.is_pressed() or event.is_echo():
		return
	if event.is_action_pressed("redo", false, true):
		_undo(true)
	elif event.is_action_pressed("undo", false, true):
		_undo(false)
	elif event.is_action_pressed("alarm_ack_all", false, true):
		var n := CW.acknowledge_all()
		if n > 0:
			alerts.toast("Acknowledged %d alert%s" % [n, "" if n == 1 else "s"], "ok")
	elif event is InputEventKey and (event as InputEventKey).ctrl_pressed:
		return   # Ctrl+letter is not a single-letter shortcut
	elif event.is_action_pressed("alarm_ack"):
		CW.acknowledge()
	elif event.is_action_pressed("alarm_silence"):
		CW.silence()
	elif event.is_action_pressed("cw_panel"):
		cw_panel.toggle(ui.size)
	elif event.is_action_pressed("abort"):
		_abort_hold = 0.0
		alerts.toast("Keep holding to %s …" % ("cancel the abort" if tel.abort_active else "ABORT the EVA"), "warn")
	elif event.is_action_pressed("cuff_menu"):
		_open_cuff_menu()
	elif event.is_action_pressed("settings"):
		settings_panel.toggle(ui.size)
	elif event.is_action_pressed("back"):
		var dlg := ui.get_node_or_null("Confirm")
		if dlg:
			dlg.queue_free()
		elif cw_panel.visible:
			cw_panel.close()
		elif lightbox.visible:
			lightbox.close()
		elif settings_panel.visible:
			settings_panel.close()
		elif help.visible:
			_toggle_help()
		elif tool != "":
			_set_tool("")
		elif world.mode == "walk" and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
			world.set_look_lock(false)   # first Esc gives the cursor back, the next one leaves the helmet
		elif world.mode == "walk":
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			_set_mode("orbit")
	elif event.is_action_pressed("toggle_view"):
		_set_mode("orbit" if world.mode == "walk" else "walk")
	elif event.is_action_pressed("jump") and world.mode != "walk":
		Mission.set_playing(not Mission.playing)   # Space plays the EVA in orbit view (it jumps in the helmet)
	elif event.is_action_pressed("then_now", false, true):
		then_now.next()
	elif event.is_action_pressed("play_pause"):
		if world.mode == "walk":
			_walk_play_toggle()
		else:
			Mission.set_playing(not Mission.playing)
	elif event.is_action_pressed("speed_down"):
		Mission.cycle_speed(-1)
	elif event.is_action_pressed("speed_up"):
		Mission.cycle_speed(1)
	elif event.is_action_pressed("home"):
		if world.mode == "orbit":
			world.home_view()
		else:
			Mission.set_time(0.0)
	elif event.is_action_pressed("hide_ui"):
		ui_hidden = not ui_hidden
		if world.mode == "orbit":
			_fade_plan_ui(not ui_hidden)
		hud.visible = not ui_hidden and world.mode == "walk"
	elif event.is_action_pressed("mute"):
		Sfx.set_enabled(not Sfx.enabled)
		alerts.toast("Sound on" if Sfx.enabled else "Interface and ambience muted. Alarms still sound (Backspace silences one).", "info")
	elif event.is_action_pressed("contours"):
		world.set_contours(world._param("contour_strength") < 0.5)
	elif event.is_action_pressed("grid"):
		world.set_grid(world._param("grid_strength") < 0.5)
	elif event.is_action_pressed("labels"):
		world.set_layer_visible("labels", not world.show_labels)
	elif event.is_action_pressed("radar", false, true):
		radar.toggle()
	elif event.is_action_pressed("ping"):
		world.scan_pulse(world.walker.xy() if world.mode == "walk" else Geo.xy_of(world.orbit.target))
	elif event.is_action_pressed("help"):
		_toggle_help()
	elif event.is_action_pressed("tag_find", false, true):
		if world.mode == "walk":
			tools.tag("find")
	elif event.is_action_pressed("tag_hazard", false, true):
		if world.mode == "walk":
			tools.tag("hazard")
	elif event.is_action_pressed("white_balance"):
		tools.set_earth_light(not tools.earth_light)
	elif event.is_action_pressed("synthetic_vision"):
		tools.set_synthetic(not tools.synthetic_on)
	elif event.is_action_pressed("flashlight"):
		if world.mode == "walk":
			tools.set_flashlight(not tools.flashlight_on)
		else:
			alerts.toast("The data flashlight works in the helmet view (V)", "info")
	elif event.is_action_pressed("ghost"):
		tools.set_ghost(not tools.ghost_on)
	elif event.is_action_pressed("lake"):
		lake.cycle()
	elif event.is_action_pressed("hud_drill"):
		tools.toggle_drill()
	elif event.is_action_pressed("skyline_fix"):
		tools.skyline_fix()
	elif event.is_action_pressed("fullscreen"):
		var w := get_window()
		w.mode = Window.MODE_WINDOWED if w.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
	else:
		for i in 5:
			if event.is_action_pressed("cuff_%d" % (i + 1)):
				if world.mode == "walk":
					hud.toggle_cuff_task(i)
				else:
					info.show_tab(InfoPanel.TABS[i])
				break


# ------------------------------------------------------------------ capture tour (verification)
func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(capture_dir.path_join(name))
	print("shot ", name, "  fps=", Engine.get_frames_per_second())


## G4 trailer: the hands-free demo, recorded frame by frame by Godot's movie writer (run_godot.ps1 -Trailer).
## --tour=trailer (run_godot.ps1 -Trailer): the hands-free demo, and at a site with a published lake level the
## crater flooding, recorded with the movie writer. The camera rolls once the console has finished loading;
## trailer_marks.txt (in the capture folder) says where, so the launcher can cut the loading out.
func _trailer() -> void:
	alerts.muted = true
	await _await_plan()
	var waited := 0.0
	while not tower.load_sheets_ready() and waited < 300.0:
		await _wait(0.5)
		waited += 0.5
	await _wait(2.0)
	_quiet_alerts()
	_trailer_mark("start")
	director.play()
	await director.ended
	var L := lake.levels()
	if not L.is_empty() and bool(L[0].get("published", false)):
		await _trailer_lake()
	if radar.available():
		await _trailer_radar()
	await _trailer_then_now()
	await _wait(1.0)
	_trailer_mark("end")
	await _wait(0.5)


## The ancient lake fills the crater from orbit, then the view from its shore.
func _trailer_lake() -> void:
	if world.mode != "orbit":
		_set_mode("orbit")
		await _wait(1.2)
	var labels_were := world.show_labels
	world.set_layer_visible("labels", false)
	_fade_plan_ui(false)
	_quiet_alerts()
	world.orbit.fly_to(world.td.world_at(Mission.hab_xy()), 5600.0, world.orbit.yaw + 0.7, deg_to_rad(27.0), 2.6)
	var lv: Dictionary = lake.levels()[0]
	director.caption("Flood the crater", "The ancient lake at %s m (%s), a level recorded in the delta front's beds: the mudstones the samples come from settled out of this water." % [
		LakeWater.fmt_elev(float(lv["elev"])), str(lv["name"])])
	await _wait(2.8)
	lake.cycle()
	await _wait(LakeWater.RISE_S + 3.0)
	var sp := lake.shore_point()
	if not sp.is_empty():
		_set_mode("walk")
		await _wait(1.2)
		world.walker.autopilot = false
		var p: Vector2 = sp[0]
		var down: Vector2 = sp[1]
		world.walker.place(p - down * 6.0, rad_to_deg(atan2(down.x, down.y)))
		world.walker.pitch = -0.04
		director.caption("On the shore", "In the helmet the visor gives the metres of water overhead, and the view is tinted while under it.")
		await _wait(5.0)
		world.walker.place(world.haven_door(), 200.0)
		await _wait(4.0)
		_set_mode("orbit")
		await _wait(1.0)
	director.hide_caption()
	lake.set_off()
	await _wait(2.5)
	world.set_layer_visible("labels", labels_were)
	_fade_plan_ui(true)


## Under the rover's track: Perseverance's ground radar unrolls into the ground, seen from orbit.
func _trailer_radar() -> void:
	if world.mode != "orbit":
		_set_mode("orbit")
		await _wait(1.2)
	var shot: Dictionary = await radar_viewpoint()
	if shot.is_empty():
		return
	var labels_were := world.show_labels
	world.set_layer_visible("labels", false)
	_fade_plan_ui(false)
	_quiet_alerts()
	world.orbit.fly_to(world.td.world_at(shot["xy"]), 420.0, float(shot["yaw"]), deg_to_rad(21.0), 2.6)
	director.caption("Under the rover's track", "Perseverance's RIMFAX radar sounded the ground every 10 cm as it drove. Each sol's radargram hangs along that sol's drive, 5 m down (drawn 2.5 times deeper from orbit).")
	await _wait(2.4)
	radar.set_on(true, true)
	var waited := 0.0
	while radar._mi == null and waited < 60.0:
		await _wait(0.5)
		waited += 0.5
	await _wait(RadarCurtain.REVEAL_S + 4.0)
	director.caption("Buried layers and rocks", "Light and dark bands are echoes from layer boundaries; the chevrons are echoes off buried boulders. Data: NASA PDS, Mars 2020 RIMFAX.")
	world.orbit.fly_to(world.td.world_at(shot["xy"]), 260.0, float(shot["yaw"]) + 0.5, deg_to_rad(14.0), 5.0)
	await _wait(6.0)
	director.hide_caption()
	radar.set_on(false, true)
	await _wait(1.5)
	world.set_layer_visible("labels", labels_were)
	_fade_plan_ui(true)


## Then and now: one of the rover's photos, wiped against the terrain model from the pose it was taken at.
func _trailer_then_now() -> void:
	director.hide_caption()
	then_now.next()
	var waited := 0.0
	while not then_now.active and waited < 60.0:
		await _wait(0.5)
		waited += 0.5
	if not then_now.active:
		return
	await _wait(ThenNow.SWEEP_S + 1.5)
	then_now.stop()
	_quiet_alerts()
	await _wait(1.2)


## --tour=trailer30 (run_godot.ps1 -Trailer -Short): the 30-second cut. The demo's short form, then the lake, the
## radar and a rover photo, one line each, and a closing card. The launcher keeps only the stretches between an
## "in" and an "out" mark (trailer_marks.txt), so loading and mode switches never show.
func _trailer_short() -> void:
	alerts.muted = true
	await _await_plan()
	var waited := 0.0
	while not tower.load_sheets_ready() and waited < 300.0:
		await _wait(0.5)
		waited += 0.5
	await radar_viewpoint()   # the radar runs are fetched before the camera rolls (nothing to do without radar)
	await _wait(2.0)
	_quiet_alerts()
	_trailer_mark("start")
	director.play_short()
	await director.ended
	var L := lake.levels()
	if not L.is_empty() and bool(L[0].get("published", false)):
		await _short_lake()
	if radar.available():
		await _short_radar()
	await _short_then_now()
	await _short_end()
	_trailer_mark("end")
	await _wait(0.5)


func _short_lake() -> void:
	if world.mode != "orbit":
		_set_mode("orbit")
		await _wait(1.2)
	world.set_layer_visible("labels", false)
	_fade_plan_ui(false)
	_quiet_alerts()
	world.orbit.auto_rotate = false
	world.orbit.fly_to(world.td.world_at(Mission.hab_xy()), 5600.0, world.orbit.yaw + 0.7, deg_to_rad(27.0), 1.0)
	await _wait(1.3)
	_trailer_mark("in")
	var lv: Dictionary = lake.levels()[0]
	director.caption("Flood the crater", "The ancient lake, at the level its delta recorded (%s m)." % LakeWater.fmt_elev(float(lv["elev"])))
	lake.cycle()
	await _wait(LakeWater.RISE_S + 0.3)
	_trailer_mark("out")
	director.hide_caption()
	lake.set_off(true)
	await _wait(0.6)


func _short_radar() -> void:
	var shot: Dictionary = await radar_viewpoint()
	if shot.is_empty():
		return
	if world.mode != "orbit":
		_set_mode("orbit")
		await _wait(1.2)
	world.set_layer_visible("labels", false)
	_fade_plan_ui(false)
	world.orbit.auto_rotate = false
	# low over the track and looking along it: the radargram's own texture near the camera, its glow further off
	_quiet_alerts()
	world.orbit.fly_to(world.td.world_at(shot["xy"]), 75.0, float(shot["along_yaw"]), deg_to_rad(10.0), 1.0)
	await _wait(1.3)
	await radar.set_on(true, true)   # builds the curtain first, out of the cut
	_trailer_mark("in")
	director.caption("Under the rover's track", "Perseverance's ground radar, hung 5 m into the ground.")
	await _wait(RadarCurtain.REVEAL_S + 1.8)
	_trailer_mark("out")
	director.hide_caption()
	radar.set_on(false, true)
	await _wait(0.8)


func _short_then_now() -> void:
	director.hide_caption()
	then_now.next()
	var waited := 0.0
	while not then_now.active and waited < 60.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if not then_now.active:
		return
	_trailer_mark("in")
	await _wait(ThenNow.SWEEP_S * 0.55)
	_trailer_mark("out")
	then_now.stop()
	await _wait(1.2)


func _short_end() -> void:
	if world.mode != "orbit":
		_set_mode("orbit")
		await _wait(1.2)
	world.set_layer_visible("labels", true)
	_fade_plan_ui(true)
	_quiet_alerts()
	world.home_view()
	world.orbit.auto_rotate = true
	await _wait(2.2)
	_quiet_alerts()
	_trailer_mark("in")
	director.caption("Martian Map · NASA Space Apps 2026", "Plan the walk, see every way home, then walk it.")
	await _wait(2.2)
	_trailer_mark("out")


## A place to look at the radar curtain from: the middle of its longest run, seen side-on. {xy, yaw} or {}.
func radar_viewpoint() -> Dictionary:
	if not radar.available():
		return {}
	if radar.runs.is_empty():
		var r: Dictionary = await Api.get_json("/api/sites/%s/radar" % Mission.site_id, 60.0)
		if not r["ok"] or not (r["data"] is Dictionary):
			return {}
		radar.runs = (r["data"] as Dictionary).get("runs", [])
	var best: Dictionary = {}
	for run in radar.runs:
		if best.is_empty() or int(run["n"]) > int(best["n"]):
			best = run
	if best.is_empty():
		return {}
	var lon: Array = best["lon"]
	var lat: Array = best["lat"]
	var n := lon.size()
	var a := Mission.xy_of(float(lon[int(n * 0.35)]), float(lat[int(n * 0.35)]))
	var b := Mission.xy_of(float(lon[int(n * 0.65)]), float(lat[int(n * 0.65)]))
	var mid := Mission.xy_of(float(lon[n / 2]), float(lat[n / 2]))
	var along := (b - a).normalized()
	# orbit yaw -atan2(x, y) looks along the site direction (x, y): across the track for "yaw", along it for "along_yaw"
	var yaw := -atan2(along.y, -along.x)
	return {"xy": mid, "yaw": yaw, "along_yaw": -atan2(along.x, along.y)}


## Trailer shots start without latched cautions on screen (the shore and photo shots leave the route on purpose).
func _quiet_alerts() -> void:
	CW.silence()
	CW.acknowledge_all()


func _trailer_mark(name: String) -> void:
	if capture_dir == "":
		return
	var path := capture_dir.path_join("trailer_marks.txt")
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f:
		f.seek_end()
		f.store_line("%s %d" % [name, Engine.get_frames_drawn()])
		f.close()


func _wait(s: float) -> void:
	await get_tree().create_timer(s).timeout


func _capture_tour() -> void:
	await _wait(7.0)
	if tour == "rover":
		await _rover_tour()
		get_tree().quit()
		return
	if tour == "buddy":
		await _buddy_tour()
		get_tree().quit()
		return
	if tour == "layers":
		await _layers_tour()
		get_tree().quit()
		return
	if tour == "bench":
		await _bench_tour()
		get_tree().quit()
		return
	if tour == "lod":
		await _lod_tour()
		get_tree().quit()
		return
	if tour == "profile":
		await _profile_tour()
		get_tree().quit()
		return
	if tour == "nasa":
		await NasaTour.new(self).run()
		get_tree().quit()
		return
	if tour == "abort":
		await AbortTour.new(self).run()
		get_tree().quit()
		return
	if tour == "models":
		await ModelsTour.new(self).run()
		get_tree().quit()
		return
	if tour == "datause":
		await DataUseTour.new(self).run()
		get_tree().quit()
		return
	if tour == "tools":
		await ToolsTour.new(self).run()
		get_tree().quit()
		return
	if tour == "lake":
		await ToolsTour.new(self).run_lake()
		get_tree().quit()
		return
	if tour == "tower":
		await ToolsTour.new(self).run_tower()
		get_tree().quit()
		return
	if tour == "live":
		await ToolsTour.new(self).run_live()
		get_tree().quit()
		return
	if tour == "radar":
		await ToolsTour.new(self).run_radar()
		get_tree().quit()
		return
	if tour == "reach":
		await ToolsTour.new(self).run_reach()
		get_tree().quit()
		return
	if tour == "thennow":
		await ToolsTour.new(self).run_thennow()
		get_tree().quit()
		return
	if tour == "demo30" or tour == "fulltour":
		await load("res://scripts/app/%s_tour.gd" % tour).new(self).run()
		get_tree().quit()
		return
	if tour == "trailer":
		await _trailer()
		get_tree().quit()
		return
	if tour == "trailer30":
		await _trailer_short()
		get_tree().quit()
		return
	if tour == "fixes":
		await _fixes_tour()
		get_tree().quit()
		return
	if tour == "camera":
		await _camera_tour()
		get_tree().quit()
		return
	if tour == "replan":
		await _check_replan()
		get_tree().quit()
		return
	if tour == "walk":
		await _walk_tour()
		get_tree().quit()
		return
	if tour == "gamepad":
		await _gamepad_tour()
		get_tree().quit()
		return
	if tour == "polish":
		await _polish_tour()
		get_tree().quit()
		return
	if tour == "settings":
		await _settings_tour()
		get_tree().quit()
		return
	await _shot("01_overview.png")
	if world.route_mat:   # the planned route must be drawn in full, not stuck mid-sweep or greyed out
		print("route: visible %s, reveal %s, stale %s" % [world.route_mi.visible, str(world.route_mat.get_shader_parameter("reveal_d")),
			str(world.route_mat.get_shader_parameter("stale"))])
	_select_stop(str(Mission.stops[1]["id"]))
	await _wait(3.2)
	await _shot("02_stop_selected.png")
	info.show_tab("LAYERS")
	info.select_layer("slope")
	await _wait(1.0)
	await _shot("03_layer_reveal.png")
	await _wait(2.5)
	await _shot("04_slope_layer.png")
	info.select_layer("crism_hyd")
	await _wait(12.0)
	await _shot("04b_crism_sulfates.png")
	info.select_layer("boulders")
	await _wait(5.0)
	await _shot("04c_boulders.png")
	info.select_layer("comms")
	info.show_tab("SPACE WX")
	Mission.set_time(2200.0)
	await _wait(3.0)
	await _shot("05_space_weather.png")
	info.show_tab("CONDITIONS")
	Mission.set_playing(true)
	await _wait(2.0)
	await _shot("06_conditions_playing.png")
	Mission.set_playing(false)
	info.scroll_to_end("CONDITIONS")
	await _wait(0.6)
	await _shot("06b_measured_weather.png")
	info.show_tab("ROVER CAM")
	await _wait(9.0)
	await _shot("07_rover_cam.png")
	world.set_overlay("", null, Mission.hab_xy())
	Mission.set_time(1500.0)
	_set_mode("walk")
	await _wait(4.0)
	hud.toggle_cuff_task(0)   # tick the first task on the cuff, as the 1 key does
	await _wait(0.5)
	await _shot("08_helmet.png")
	# walking by hand: the clock pauses and EV2 keeps pace beside you
	Mission.set_playing(true)
	world.toggle_autopilot()
	var start := world.walker.xy()
	for i in 60:
		world.walker.x += sin(world.walker.yaw) * 0.45
		world.walker.y += cos(world.walker.yaw) * 0.45
		await get_tree().process_frame
	await _wait(1.5)
	print("manual: moved %.0f m, playing=%s, t=%.0f" % [world.walker.xy().distance_to(start), Mission.playing, Mission.eva_t])
	await _shot("08b_manual_buddy.png")
	_walk_play_toggle()
	await _wait(3.0)
	print("rejoin: autopilot=%s playing=%s speed=x%d t=%.0f" % [world.walker.autopilot, Mission.playing, int(Mission.play_speed()), Mission.eva_t])
	await _shot("08c_rejoin_play.png")
	Mission.set_playing(false)
	_storm_drill()
	await _wait(1.6)   # the caution & warning monitor raises it after its 0.6 s hold
	await _shot("09_alert.png")
	world.walker.yaw += 2.6
	await _wait(2.5)
	await _shot("10_helmet_turn.png")
	CW.acknowledge_all()   # alerts now stay until acknowledged: clear the strip for the rest of the tour
	_set_mode("orbit")
	await _wait(3.0)
	_toggle_help()
	await _wait(0.6)
	await _shot("11_help.png")
	_toggle_help()
	await _rover_tour()
	get_tree().quit()


## EV2 on autopilot must keep facing the way it walks: it used to turn round to face you about once
## a second. Counts the frames in which EV2 faces the camera while the crew is walking.
func _buddy_tour() -> void:
	await _await_plan()
	Mission.set_time(1500.0)
	_set_mode("walk")
	await _wait(3.0)
	for si in [0, 1, 2]:   # x1, x10, x30
		Mission.speed_index = si
		Mission.set_playing(true)
		var frames := 0
		var facing_you := 0
		var flips := 0
		var last := 0.0
		var t_start := Time.get_ticks_msec() + 1500   # first 1.5 s: EV2 turns from waiting (facing you) to walking
		var t_end := t_start + 6000
		var was_facing := false
		var turn_rounds := 0
		while Time.get_ticks_msec() < t_end:
			await get_tree().process_frame
			if Time.get_ticks_msec() < t_start:
				continue
			var st := Mission.state_at(Mission.eva_t)
			if str(st.get("phase", "")) != "walk" or world.crew.size() < 2:
				continue
			var ev2: Node3D = world.crew[1]
			var ry := ev2.rotation.y
			var facing := Vector2(-sin(ry), cos(ry))
			var to_you := world.walker.xy() - Vector2(ev2.position.x, -ev2.position.z)
			frames += 1
			var now_facing := to_you.length() > 0.5 and facing.dot(to_you.normalized()) > 0.5
			if now_facing:
				facing_you += 1
				if not was_facing:
					turn_rounds += 1
			was_facing = now_facing
			if frames > 1 and absf(angle_difference(last, ry)) > deg_to_rad(45.0):
				flips += 1
			last = ry
		Mission.set_playing(false)
		print("buddy x%d: %d walking frames, faced the camera in %d (%.0f %%), turned round %d times, heading jumps > 45 deg: %d" % [
			int(Mission.play_speed()), frames, facing_you, 100.0 * facing_you / maxf(1.0, frames), turn_rounds, flips])
		if si == 0:
			await _shot("15_buddy_follow.png")
		await _wait(0.5)


## Switch through every drape three times: first fetch, again from memory, and from the disk cache.
func _layers_tour() -> void:
	await _await_plan()
	info.show_tab("LAYERS")
	var layers: Array = []
	for L in Mission.site.get("layers", []):
		if str(L["id"]) != "hillshade":
			layers.append(L)
	for pass_name in ["first fetch", "memory", "disk cache"]:
		if pass_name == "disk cache":
			_overlay_cache.clear()
			_overlay_order.clear()
		var times := PackedStringArray()
		var total := 0
		var worst := 0
		for L in layers:
			var t0 := Time.get_ticks_msec()
			await _on_overlay(L)
			var ms := Time.get_ticks_msec() - t0
			total += ms
			worst = maxi(worst, ms)
			times.append("%s %d" % [str(L["id"]), ms])
		print("layers [%s]: %d layers, avg %d ms, worst %d ms  |  %s" % [pass_name, layers.size(), total / maxi(1, layers.size()), worst, ", ".join(times)])
	for L in layers:
		if str(L["id"]) == "crism_hyd":
			await _on_overlay(L)
	await _wait(0.5)
	await _shot("16_layer_crism.png")


func _check(n: int, ok: bool, detail: String) -> void:
	print("CHECK %d %s  %s" % [n, "PASS" if ok else "FAIL", detail])


## Runtime checks for the fixes in the console review list (items 1-7). Prints one CHECK line per item.
func _fixes_tour() -> void:
	await _await_plan()
	# 2. the mouse wheel over a planner slider scrolls the panel and leaves the slider alone
	var sc := plan_panel.get_child(0) as ScrollContainer
	var sl: HSlider = plan_panel._start_slider
	sc.ensure_control_visible(sl)
	await _wait(0.3)
	var v0 := sl.value
	var s0 := sc.scroll_vertical
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	wheel.position = sl.get_global_rect().get_center()
	get_viewport().push_input(wheel, true)
	var up := wheel.duplicate() as InputEventMouseButton
	up.pressed = false
	get_viewport().push_input(up, true)
	await _wait(0.3)
	_check(2, is_equal_approx(sl.value, v0), "slider %.2f -> %.2f, panel scroll %d -> %d" % [v0, sl.value, s0, sc.scroll_vertical])
	# 3. layer opacity is kept per layer and follows the API default
	info.show_tab("LAYERS")
	info.select_layer("slope")
	await _wait(2.5)
	info._opacity.value = 0.4
	await _wait(0.2)
	info.select_layer("roughness")
	await _wait(2.5)
	var rough := world._param("overlay_opacity")
	info.select_layer("slope")
	await _wait(1.0)
	var slope_back := world._param("overlay_opacity")
	_check(3, is_equal_approx(slope_back, 0.4) and not is_equal_approx(rough, 0.4),
		"slope set to 0.40 -> roughness drawn at %.2f (its default) -> slope again at %.2f" % [rough, slope_back])
	# 4. a plan-dependent drape (walk-back) is fetched again when the plan changes under it
	info.select_layer("walkback")
	await _wait(3.0)
	var u0 := _overlay_url_now
	var was_rover := Mission.rover_enabled
	Mission.set_rover(not was_rover)
	await Mission.request_plan()
	await _wait(4.0)
	var u1 := _overlay_url_now
	_check(4, u0 != u1 and world.overlay_id == "walkback", "walk-back drape refreshed after the haven moved: %s" % str(u0 != u1))
	Mission.set_rover(was_rover)
	await Mission.request_plan()
	_on_overlay({"id": ""})
	# 5. clicking the label of a stop selects that stop
	world.home_view()
	await _wait(4.0)
	var picked := {}
	for h in callouts._hits:
		if str(h["kind"]) == "stop" and str(h["id"]) != Mission.selected_stop:
			picked = h
			break
	if picked.is_empty():
		_check(5, false, "no stop label on screen")
	else:
		var r: Rect2 = picked["rect"]
		var at := Vector2(r.get_center().x, r.position.y + 6.0)   # the top of the tag, far from the beacon
		var beacon := world.camera.unproject_position((world.stop_nodes[picked["id"]] as Node3D).global_position)
		world._click(at)
		await _wait(0.2)
		_check(5, Mission.selected_stop == str(picked["id"]), "clicked the tag of %s %.0f px above its beacon -> selected '%s'" % [picked["id"], beacon.distance_to(at), Mission.selected_stop])
	# 6. a double-click runs the single-click action once, not twice
	await _wait(3.5)
	var clicks := [0]
	var count := func(_a): clicks[0] += 1
	world.ground_clicked.connect(count)
	world.stop_clicked.connect(count)
	world.object_clicked.connect(count)
	var p := Vector2(get_viewport().get_visible_rect().size.x * 0.5, get_viewport().get_visible_rect().size.y * 0.62)
	for k in 4:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.position = p
		ev.pressed = k % 2 == 0
		ev.double_click = k == 2
		world._unhandled_input(ev)
	world.ground_clicked.disconnect(count)
	world.stop_clicked.disconnect(count)
	world.object_clicked.disconnect(count)
	_check(6, clicks[0] == 1, "click actions for one double-click: %d" % clicks[0])
	await _wait(2.5)
	# 7. undo / redo of a stop removal
	var ids0 := PackedStringArray()
	for s in Mission.stops:
		ids0.append(str(s["id"]))
	Mission.remove_stop(ids0[ids0.size() - 1])
	var n_removed := Mission.stops.size()
	var u_label := Mission.undo()
	var n_undone := Mission.stops.size()
	Mission.redo()
	var n_redone := Mission.stops.size()
	Mission.undo()
	var ids1 := PackedStringArray()
	for s in Mission.stops:
		ids1.append(str(s["id"]))
	_check(7, n_removed == ids0.size() - 1 and n_undone == ids0.size() and n_redone == ids0.size() - 1 and ids1 == ids0,
		"stops %d -> remove %d -> undo ('%s') %d -> redo %d -> undo %s" % [ids0.size(), n_removed, u_label, n_undone, n_redone, ",".join(ids1)])
	await _check_replan()
	Mission.clear_history()


## Item 1: two quick edits while a plan computes. The second must be planned, not dropped.
## (Each plan takes about a minute on the dev laptop, so this check is also run alone: --tour=replan.)
func _check_replan() -> void:
	await _await_plan()
	var algo0 := Mission.algorithm
	var load0: Variant = Mission.walk.get("load_kg", 8.0)
	Mission.walk["load_kg"] = 20.0
	Mission.request_plan()
	await _wait(0.05)
	var queued_before := Mission._replan_queued
	Mission.algorithm = "dijkstra" if algo0 == "astar" else "astar"
	var want := Mission.algorithm
	Mission.request_plan()   # arrives while the first plan is still computing
	var queued := Mission._replan_queued
	await _await_plan(400.0)
	var got := str(Mission.plan["totals"]["algorithm"])
	_check(1, got == want and queued and not queued_before, "second edit while planning: queued %s, plan algorithm '%s', wanted '%s'" % [str(queued), got, want])
	Mission.algorithm = algo0
	Mission.walk["load_kg"] = load0
	Mission.save_mission()   # the saved mission keeps the user's settings, not the test's


## Frame-time benchmark: fixed views held for 6 s each (after 2 s to settle), no screenshots in between.
## Prints the average FPS, the 95th-percentile and worst frame time, and the frames over 50 ms per view.
func _bench_tour() -> void:
	await _await_plan()
	for v in ["orbit_home", "orbit_layer", "orbit_play_x30", "helmet_stand", "helmet_lope", "helmet_play_x30"]:
		match v:
			"orbit_home":
				world.home_view()
			"orbit_layer":
				for L in Mission.site.get("layers", []):
					if str(L["id"]) == "slope":
						await _on_overlay(L)
			"orbit_play_x30":
				world.set_overlay("", null, Mission.hab_xy())
				Mission.set_time(600.0)
				Mission.speed_index = 2
				follow_crew = true
				Mission.set_playing(true)
			"helmet_stand":
				Mission.set_playing(false)
				follow_crew = false
				Mission.set_time(1500.0)
				_set_mode("walk")
			"helmet_lope":
				world.toggle_autopilot()
				_bench_key(KEY_SHIFT, true)
				_bench_key(KEY_W, true)
			"helmet_play_x30":
				_bench_key(KEY_W, false)
				_bench_key(KEY_SHIFT, false)
				_walk_play_toggle()
				Mission.speed_index = 2
				Mission.playing_changed.emit(Mission.playing)
		await _wait(2.0)
		var frames := PackedFloat32Array()
		var t_end := Time.get_ticks_msec() + 6000
		while Time.get_ticks_msec() < t_end:
			await get_tree().process_frame
			frames.append(get_process_delta_time() * 1000.0)
		var sorted := frames.duplicate()
		sorted.sort()
		var total := 0.0
		var slow := 0
		for f in frames:
			total += f
			if f > 50.0:
				slow += 1
		var avg := total / maxf(1.0, frames.size())
		print("bench %-16s %5.1f fps  avg %5.1f ms  p95 %5.1f ms  worst %6.1f ms  >50ms %d/%d" % [v, 1000.0 / avg, avg,
			sorted[int(sorted.size() * 0.95)], sorted[sorted.size() - 1], slow, frames.size()])
	Mission.set_playing(false)
	_set_mode("orbit")


## Where the frame time goes: switches one cost off at a time (orbit view, then the helmet) and
## prints the average frame time for each, next to the baseline measured before and after.
func _profile_tour() -> void:
	await _await_plan()
	world.home_view()
	await _wait(5.0)
	for c in ["base", "glass blur", "ui panels", "labels", "shadows", "glow+fog", "sky", "scale 0.5", "terrain", "base"]:
		await _profile_case("orbit", c)
	Mission.set_time(1500.0)
	_set_mode("walk")
	await _wait(4.0)
	for c in ["base", "visor", "hud", "near detail", "rocks", "dust", "shadows", "scale 0.5", "terrain", "base"]:
		await _profile_case("helmet", c)
	_set_mode("orbit")


func _profile_case(view: String, cost: String) -> void:
	_profile_set(cost, true)
	await _wait(1.0)
	var total := 0.0
	var n := 0
	var t_end := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		total += get_process_delta_time() * 1000.0
		n += 1
	print("profile %-7s without %-12s %6.1f ms  %5.1f fps" % [view, cost, total / maxi(n, 1), 1000.0 * n / maxf(total, 1.0)])
	_profile_set(cost, false)


## off = true switches that cost off; false puts it back.
func _profile_set(cost: String, off: bool) -> void:
	match cost:
		"glass blur":
			UiKit.set_glass_blur(not off)
		"ui panels":
			plan_ui.visible = not off and world.mode == "orbit"
		"labels":
			callouts.visible = not off
		"shadows":
			world.sun.shadow_enabled = not off
		"glow+fog":
			world.env.glow_enabled = not off
			world.env.fog_enabled = not off
		"sky":
			world.env.background_mode = Environment.BG_COLOR if off else Environment.BG_SKY
			world.env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR if off else Environment.AMBIENT_SOURCE_SKY
		"scale 0.5":
			get_viewport().scaling_3d_scale = 0.5 if off else float(Quality.get_value("scale"))
		"terrain":
			world.terrain_mesh.visible = not off
		"visor":
			visor.visible = not off and world.mode == "walk"
		"hud":
			hud.visible = not off and world.mode == "walk"
		"near detail":
			world.terrain_mesh.set_param("detail_strength", 0.0 if off else 1.0)
		"rocks":
			world.rocks.visible = not off and world.mode == "walk"
		"dust":
			world.dust.visible = not off


func _bench_key(code: Key, down: bool) -> void:
	var ev := InputEventKey.new()
	ev.keycode = code
	ev.physical_keycode = code
	ev.pressed = down
	Input.parse_input_event(ev)


func _mouse(kind: String, at: Vector2, button := MOUSE_BUTTON_LEFT, rel := Vector2.ZERO, mask := 0) -> void:
	var ev: InputEvent
	if kind == "move":
		var mm := InputEventMouseMotion.new()
		mm.position = at
		mm.relative = rel
		mm.button_mask = mask
		ev = mm
	else:
		var mb := InputEventMouseButton.new()
		mb.button_index = button
		mb.position = at
		mb.pressed = kind == "down"
		ev = mb
	get_viewport().push_input(ev, true)


## Runtime checks for the orbit-view handling (items 8, 9, 10, 13). Prints one CHECK line per item.
func _camera_tour() -> void:
	await _await_plan()
	world.home_view()
	await _wait(4.5)
	var vs := get_viewport().get_visible_rect().size
	# 13. hovering a stop's label: the beacon/label highlight and the hand cursor
	var lab := {}
	for h in callouts._hits:
		if str(h["kind"]) == "stop":
			lab = h
			break
	if lab.is_empty():
		_check(13, false, "no stop label on screen")
	else:
		_mouse("move", (lab["rect"] as Rect2).get_center())
		await _wait(0.3)
		_check(13, world.hover_id == str(lab["id"]) and _cursor == Input.CURSOR_POINTING_HAND,
			"hover over %s's label -> hover '%s', hand cursor %s" % [lab["id"], world.hover_id, str(_cursor == Input.CURSOR_POINTING_HAND)])
		_mouse("move", Vector2(vs.x * 0.5, vs.y * 0.08))   # over the top bar: hover clears
		await _wait(0.3)
		print("   hover over the top bar -> '%s'" % world.hover_id)
	# 8. zoom toward the cursor: the ground point under it stays there
	var at := Vector2(vs.x * 0.66, vs.y * 0.6)
	var p0 := world._pick(at)
	var d0 := world.orbit.dist
	for i in 3:
		_mouse("down", at, MOUSE_BUTTON_WHEEL_UP)
		await _wait(0.12)
	await _wait(1.6)
	var err8 := world.camera.unproject_position(p0).distance_to(at)
	_check(8, err8 < 20.0 and world.orbit.dist < d0 * 0.75, "3 notches in (%.0f -> %.0f m): the point under the cursor moved %.1f px" % [d0, world.orbit.dist, err8])
	# 9. right-drag holds the grabbed ground under the cursor
	var g0 := Vector2(vs.x * 0.45, vs.y * 0.62)
	var grabbed := world._pick(g0)
	_mouse("down", g0, MOUSE_BUTTON_RIGHT)
	var g1 := g0 + Vector2(230.0, -70.0)
	for i in 14:
		_mouse("move", g0.lerp(g1, (i + 1) / 14.0), MOUSE_BUTTON_LEFT, (g1 - g0) / 14.0, MOUSE_BUTTON_MASK_RIGHT)
		await get_tree().process_frame
	await _wait(0.4)   # hold still before letting go: no fling
	_mouse("up", g1, MOUSE_BUTTON_RIGHT)
	await _wait(1.2)
	var err9 := world.camera.unproject_position(grabbed).distance_to(g1)
	# ...and a quick drag let go while moving glides on
	var t_before := world.orbit.target
	_mouse("down", g1, MOUSE_BUTTON_RIGHT)
	for i in 4:
		_mouse("move", g1 + Vector2(-30.0 * (i + 1), 0.0), MOUSE_BUTTON_LEFT, Vector2(-30, 0), MOUSE_BUTTON_MASK_RIGHT)
		await get_tree().process_frame
	_mouse("up", g1 + Vector2(-120.0, 0.0), MOUSE_BUTTON_RIGHT)
	var t_release := world.orbit.target
	await _wait(1.5)
	var glide := Vector2(world.orbit.target.x - t_release.x, world.orbit.target.z - t_release.z).length()
	var dragged := Vector2(t_release.x - t_before.x, t_release.z - t_before.z).length()
	_check(9, err9 < 20.0 and glide > 0.1 * dragged, "grabbed point %.1f px from the cursor after the drag; fling glided %.0f m after a %.0f m flick" % [err9, glide, dragged])
	# 10. drag a stop's label to a new spot: the stop moves and the EVA is re-planned
	world.home_view()
	await _wait(4.5)
	var st := {}
	for h in callouts._hits:
		if str(h["kind"]) == "stop":
			st = h
			break
	if st.is_empty():
		_check(10, false, "no stop label on screen")
	else:
		var sid := str(st["id"])
		var s0 := Mission.stop_by_id(sid)
		var xy0 := Mission.xy_of(float(s0["lon"]), float(s0["lat"]))
		var from := (st["rect"] as Rect2).get_center()
		_mouse("down", from)
		var to := from + Vector2(70.0, 25.0)
		for i in 10:
			_mouse("move", from.lerp(to, (i + 1) / 10.0), MOUSE_BUTTON_LEFT, (to - from) / 10.0, MOUSE_BUTTON_MASK_LEFT)
			await get_tree().process_frame
		var mid_drag := world.dragging_stop
		_mouse("up", to)
		await get_tree().process_frame
		var planning_started := Mission.planning
		await _await_plan()
		var s1 := Mission.stop_by_id(sid)
		var moved := Mission.xy_of(float(s1["lon"]), float(s1["lat"])).distance_to(xy0)
		_check(10, mid_drag == sid and moved > 5.0 and planning_started and Mission.has_plan(),
			"dragged %s: moved %.0f m, re-planned %s, plan %s" % [sid, moved, str(planning_started), "GO" if bool(Mission.plan["totals"]["go"]) else "NO-GO"])
		Mission.undo()
		await Mission.request_plan()
	Mission.clear_history()


func _joy(axis: JoyAxis, value: float) -> void:
	var ev := InputEventJoypadMotion.new()
	ev.axis = axis
	ev.axis_value = value
	Input.parse_input_event(ev)


func _joy_button(b: JoyButton, down: bool) -> void:
	var ev := InputEventJoypadButton.new()
	ev.button_index = b
	ev.pressed = down
	Input.parse_input_event(ev)


## Runtime checks for the helmet (items 11, 12, 14): speed ramps, boulders, mouse-look lock, actions and gamepad.
func _walk_tour() -> void:
	await _await_plan()
	Mission.set_time(1500.0)
	_set_mode("walk")
	await _wait(3.0)
	var wk := world.walker
	# 11a. by hand the speed ramps up and down instead of jumping
	world.toggle_autopilot()
	_bench_key(KEY_W, true)
	await _wait(0.25)
	var v_early := wk.vel.length()
	await _wait(1.0)
	var v_full := wk.vel.length()
	_bench_key(KEY_W, false)
	var xy_release := wk.xy()
	await _wait(0.12)
	var v_after := wk.vel.length()
	await _wait(1.0)
	var coast := wk.xy().distance_to(xy_release)
	_check(11, v_early > 0.2 and v_early < v_full * 0.85 and v_after > 0.1 and wk.vel.length() < 0.01,
		"speed 0.25 s after W: %.2f m/s, after 1.25 s: %.2f m/s; 0.12 s after letting go %.2f m/s, coasted %.2f m, then stopped" % [v_early, v_full, v_after, coast])
	# 11b. boulders: walk straight at one and get pushed round it
	var target := Vector4.ZERO
	var td := world.td
	for i in td.boulders.size() / 4:
		var b := Vector4(td.boulders[i * 4], td.boulders[i * 4 + 1], td.boulders[i * 4 + 2], td.boulders[i * 4 + 3])
		if b.w < Walker.STEP_OVER + 0.1 or b.z < 1.2 or b.z > 2.2 or not td.grid.contains_xy(b.x, b.y, 200.0):
			continue
		# a rock you can walk round: gentle ground all the way round it (big ones are steep bumps in the DTM)
		var rc := clampf(b.z, 0.6, 4.0) * 0.45 + Walker.BODY_R + 0.4
		var flat := td.slope_deg(b.x - 5.0, b.y, 2.0) < 10.0
		for k in 8:
			var a := TAU * k / 8.0
			flat = flat and td.slope_deg(b.x + cos(a) * rc, b.y + sin(a) * rc, 0.75) < 18.0
		if flat:
			target = b
			break
	if target == Vector4.ZERO:
		_check(11, false, "no suitable boulder found")
	else:
		var r_contact := clampf(target.z, 0.6, 4.0) * 0.45 + Walker.BODY_R
		# facing east, aimed a little off-centre: you are pushed round the rock, never through it
		wk.place(Vector2(target.x - 4.0 - target.z * 0.5, target.y + r_contact * 0.55), 90.0)
		wk.vel = Vector2.ZERO
		var closest := INF
		var bumps := 0
		var blocked := 0
		_bench_key(KEY_W, true)
		var t_end := Time.get_ticks_msec() + 6000
		while Time.get_ticks_msec() < t_end:
			await get_tree().process_frame
			closest = minf(closest, wk.xy().distance_to(Vector2(target.x, target.y)))
			if wk.bumped:
				bumps += 1
			if wk.blocked:
				blocked += 1
		_bench_key(KEY_W, false)
		_check(11, closest >= r_contact - 0.05 and bumps > 0 and wk.xy().x > target.x,
			"walked at a %.1f m boulder (%.1f m high): closest %.2f m (contact %.2f m), pushed round it in %d frames (slope-blocked %d), ended %s of it" % [
				target.z, target.w, closest, r_contact, bumps, blocked, "east" if wk.xy().x > target.x else "west"])
	# 12. mouse-look lock: F captures the mouse, F again frees it (switched straight back: the desktop mouse is not held)
	var ev := InputEventKey.new()
	ev.physical_keycode = KEY_F
	ev.pressed = true
	world._unhandled_input(ev)
	var locked := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and world.look_locked
	world._unhandled_input(ev)
	var freed := Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and not world.look_locked
	_check(12, locked and freed, "F -> captured %s, F again -> visible %s" % [str(locked), str(freed)])
	# 14. actions: the left stick walks, the right stick turns, gamepad Y switches the view
	wk.place(wk.xy(), 0.0)
	wk.vel = Vector2.ZERO
	var y0 := wk.yaw
	var p0 := wk.xy()
	_joy(JOY_AXIS_LEFT_Y, -1.0)
	_joy(JOY_AXIS_RIGHT_X, 0.6)
	await _wait(1.5)
	_joy(JOY_AXIS_LEFT_Y, 0.0)
	_joy(JOY_AXIS_RIGHT_X, 0.0)
	await _wait(0.8)
	var walked := wk.xy().distance_to(p0)
	var turned := rad_to_deg(angle_difference(y0, wk.yaw))
	_joy_button(JOY_BUTTON_Y, true)
	_joy_button(JOY_BUTTON_Y, false)
	await _wait(0.5)
	var view_now := world.mode
	_check(14, walked > 0.8 and turned > 20.0 and view_now == "orbit", "left stick walked %.1f m, right stick turned %.0f°, Y switched the view to %s" % [walked, turned, view_now])
	await _wait(2.5)


func _pad(b: JoyButton) -> void:
	_joy_button(b, true)
	_joy_button(b, false)
	await get_tree().process_frame


## Item 29: the whole gamepad, driven by injected joypad events (what a real pad sends). Orbit view
## (sticks, trigger, d-pad, X, Start, B), then the helmet (Y, RB, analog pace, LB lope, A, right stick, B).
func _gamepad_tour() -> void:
	await _await_plan()
	world.home_view()
	await _wait(4.5)
	var t0 := world.orbit.target
	var y0 := world.orbit.yaw
	var d0 := world.orbit.dist
	_joy(JOY_AXIS_LEFT_Y, -1.0)
	_joy(JOY_AXIS_RIGHT_X, 1.0)
	_joy(JOY_AXIS_TRIGGER_RIGHT, 1.0)
	await _wait(1.0)
	_joy(JOY_AXIS_LEFT_Y, 0.0)
	_joy(JOY_AXIS_RIGHT_X, 0.0)
	_joy(JOY_AXIS_TRIGGER_RIGHT, 0.0)
	await _wait(0.8)
	var panned := Vector2(world.orbit.target.x - t0.x, world.orbit.target.z - t0.z).length()
	var turned := rad_to_deg(absf(angle_difference(y0, world.orbit.yaw)))
	_check(29, panned > 20.0 and turned > 15.0 and world.orbit.dist < d0 * 0.9,
		"orbit: left stick panned %.0f m, right stick turned %.0f°, right trigger zoomed %.0f -> %.0f m" % [panned, turned, d0, world.orbit.dist])
	var s0 := Mission.speed_index
	await _pad(JOY_BUTTON_DPAD_RIGHT)
	var s1 := Mission.speed_index
	await _pad(JOY_BUTTON_DPAD_LEFT)
	var s2 := Mission.speed_index
	var p0 := Mission.playing
	await _pad(JOY_BUTTON_X)
	var p1 := Mission.playing
	await _pad(JOY_BUTTON_X)
	var p2 := Mission.playing
	await _pad(JOY_BUTTON_START)
	var h1 := help.visible
	await _pad(JOY_BUTTON_B)
	var h2 := help.visible
	await _pad(JOY_BUTTON_BACK)
	var hid1 := ui_hidden
	await _pad(JOY_BUTTON_BACK)
	var hid2 := ui_hidden
	await _wait(0.6)
	_check(29, s1 == s0 + 1 and s2 == s0 and p1 != p0 and p2 == p0 and h1 and not h2 and hid1 and not hid2,
		"d-pad speed x%d -> x%d -> x%d; X playing %s -> %s -> %s; Start help %s, B closed it %s; Back hid the interface %s, then showed it %s" % [
			int(Mission.SPEEDS[s0]), int(Mission.SPEEDS[s1]), int(Mission.SPEEDS[s2]), p0, p1, p2, h1, not h2, hid1, not hid2])
	# into the helmet with Y, take the walk by hand with RB
	Mission.set_time(1500.0)
	await _pad(JOY_BUTTON_Y)
	await _wait(3.0)
	var wk := world.walker
	var in_helmet := world.mode == "walk"
	var a0 := wk.autopilot
	await _pad(JOY_BUTTON_RIGHT_SHOULDER)
	var a1 := wk.autopilot
	wk.place(Mission.hab_xy() + Vector2(25.0, 0.0), 0.0)
	var speeds: Array = []
	for spec in [[-0.6, false], [-1.0, false], [-1.0, true]]:
		wk.vel = Vector2.ZERO
		if bool(spec[1]):
			_joy_button(JOY_BUTTON_LEFT_SHOULDER, true)
		_joy(JOY_AXIS_LEFT_Y, float(spec[0]))
		await _wait(2.0)
		speeds.append(wk.vel.length())
		_joy(JOY_AXIS_LEFT_Y, 0.0)
		if bool(spec[1]):
			_joy_button(JOY_BUTTON_LEFT_SHOULDER, false)
		await _wait(1.2)
	await _pad(JOY_BUTTON_A)
	var jumped := not wk.grounded or wk.vz > 0.0
	await _wait(1.5)
	var yaw0 := wk.yaw
	_joy(JOY_AXIS_RIGHT_X, -0.8)
	await _wait(0.8)
	_joy(JOY_AXIS_RIGHT_X, 0.0)
	var looked := rad_to_deg(absf(angle_difference(yaw0, wk.yaw)))
	await _shot("29_gamepad_helmet.png")
	await _pad(JOY_BUTTON_B)
	await _wait(2.0)
	var half := float(speeds[0]) / maxf(float(speeds[1]), 0.01)
	_check(29, in_helmet and a0 and not a1 and half > 0.35 and half < 0.65 and float(speeds[2]) > 1.8 * float(speeds[1]) and jumped and looked > 30.0 and world.mode == "orbit",
		"Y -> helmet %s; RB autopilot %s -> %s; stick at 0.6: %.2f m/s, full: %.2f m/s (ratio %.2f), + LB lope: %.2f m/s; A jumped %s; right stick looked %.0f°; B -> %s" % [
			in_helmet, a0, a1, float(speeds[0]), float(speeds[1]), half, float(speeds[2]), jumped, looked, world.mode])


## Items 22-28: HUD fit at the largest text, re-plan dim + sweep, audio, remembered view, the guided tour
## and the demo. One CHECK line per item.
func _polish_tour() -> void:
	await _await_plan()
	world.home_view()
	await _wait(4.0)
	# 22. the top bar fits (auto size, then the largest), and the helmet HUD at the largest size: no two
	# panels overlap, all on screen
	var bar_fit := PackedStringArray()
	var bar_ok := true
	var scale_before: Variant = Settings.get_value("ui_scale")
	for choice in ["auto", "1.3"]:
		Settings.set_value("ui_scale", choice)   # as the settings panel does (a resize re-applies the setting)
		await _wait(0.8)
		var right := top_bar.help_btn.get_global_rect().end.x
		bar_fit.append("%s: last button ends at %.0f of %.0f px" % [choice, right, ui.size.x])
		bar_ok = bar_ok and right <= ui.size.x and top_bar.demo_btn.get_global_rect().position.x > top_bar.mode_rect().end.x
		if choice == "1.3":
			await _shot("22_topbar_largest.png")
	Mission.set_time(1500.0)
	_set_mode("walk")
	await _wait(3.5)
	var rects: Array = []
	var names: Array = []
	for c in [hud.compass, hud._panels[1], hud._panels[2], hud._panels[3], hud._cuff, hud.minimap, hud._controls, hud._l["hint"], hud._l["auto"]]:
		rects.append((c as Control).get_global_rect())
		names.append((c as Control).get_class() if not (c is Label) else "label")
	var clash := PackedStringArray()
	var screen := Rect2(Vector2.ZERO, hud.size)
	for i in rects.size():
		if not screen.encloses(rects[i] as Rect2):
			clash.append("%d off screen" % i)
		for j in range(i + 1, rects.size()):
			if (rects[i] as Rect2).grow(-1.0).intersects((rects[j] as Rect2).grow(-1.0)):
				clash.append("%d/%d" % [i, j])
	await _shot("22_hud_largest.png")
	_check(22, clash.is_empty() and bar_ok, "top bar %s; helmet HUD at interface size x1.3 (%.0f x %.0f design px): %d panels, overlaps/off-screen: %s" % ["; ".join(bar_fit), hud.size.x, hud.size.y, rects.size(), ", ".join(clash) if not clash.is_empty() else "none"])
	_set_mode("orbit")
	Settings.set_value("ui_scale", scale_before)
	await _wait(2.5)
	# 24. while a plan computes the old route dims; the new one sweeps in, then is drawn whole
	world.home_view()
	await _wait(3.0)
	Mission.request_plan()
	await _wait(0.8)
	var stale := float(world.route_mat.get_shader_parameter("stale"))
	await _shot("24_replan_dim.png")
	while Mission.planning:
		await get_tree().process_frame
	await _wait(0.35)
	var rev_mid: Variant = world.route_mat.get_shader_parameter("reveal_d")
	await _shot("24_replan_sweep.png")
	await _wait(2.6)
	var rev_end: Variant = world.route_mat.get_shader_parameter("reveal_d")
	var stale_new: Variant = world.route_mat.get_shader_parameter("stale")
	_check(24, stale > 0.9 and rev_mid != null and float(rev_mid) < 1.0e8 and float(rev_end) >= 1.0e9 and (stale_new == null or float(stale_new) < 0.01),
		"planning: old route stale %.2f; new route drawn to %.0f m 0.35 s after it arrived, then whole (%s)" % [stale, float(rev_mid) if rev_mid != null else -1.0, str(float(rev_end) >= 1.0e9)])
	# 25. audio: the wind loop has no fade at its seam; hover blips are rate-limited; alerts are never cut off
	var wind: AudioStreamWAV = Sfx._streams.get("wind")
	var seam := "no wind stream"
	var seam_ok := false
	if wind:
		var pcm := wind.data
		var n := pcm.size() / 2
		var rms := func(a: int, b: int) -> float:
			var acc := 0.0
			for i in range(a, b):
				var v := pcm.decode_s16(i * 2) / 32000.0
				acc += v * v
			return sqrt(acc / maxf(1.0, b - a))
		var q := int(0.25 * Sfx.RATE)
		var head: float = rms.call(0, q)
		var tail: float = rms.call(n - q, n)
		var mid: float = rms.call(n / 2 - q, n / 2 + q)
		var jump := absf(pcm.decode_s16(0) - pcm.decode_s16((n - 1) * 2)) / 32000.0
		var step_rms: float = 0.0
		for i in range(n / 2, n / 2 + 2000):
			step_rms += pow((pcm.decode_s16((i + 1) * 2) - pcm.decode_s16(i * 2)) / 32000.0, 2.0)
		step_rms = sqrt(step_rms / 2000.0)
		seam_ok = head > 0.5 * mid and tail > 0.5 * mid and jump < 6.0 * step_rms + 0.01
		seam = "wind RMS start %.3f / middle %.3f / end %.3f, seam step %.4f (typical %.4f)" % [head, mid, tail, jump, step_rms]
	var was_enabled := Sfx.enabled
	var master := AudioServer.get_bus_index("Master")
	AudioServer.set_bus_mute(master, true)
	Sfx.enabled = true
	await _wait(0.2)
	var hovers := 0
	for i in 10:
		Sfx.play("hover")
	for p in Sfx._pool:
		if p.playing and p.stream == Sfx._streams["hover"]:
			hovers += 1
	for p in Sfx._pool:
		p.stop()
	for i in 10:
		Sfx.play("alert")
	Sfx.play("click")
	var alerts_kept := 0
	for p in Sfx._pool:
		if p.playing and p.stream == Sfx._streams["alert"]:
			alerts_kept += 1
	for p in Sfx._pool:
		p.stop()
	for i in 10:
		Sfx.play("click")
		await get_tree().process_frame
	Sfx.play("alert")
	var alert_in := 0
	for p in Sfx._pool:
		if p.playing and p.stream == Sfx._streams["alert"]:
			alert_in += 1
	for p in Sfx._pool:
		p.stop()
	Sfx.enabled = was_enabled
	AudioServer.set_bus_mute(master, false)
	var buses := AudioServer.get_bus_index(Sfx.BUS_UI) >= 0 and AudioServer.get_bus_index(Sfx.BUS_AMB) >= 0
	_check(25, seam_ok and hovers == 1 and alerts_kept == 10 and alert_in == 1 and buses,
		"%s; 10 hover blips at once -> %d played; 10 alerts + a click -> %d alerts kept; 10 clicks + an alert -> alert played %s; UI/Ambience buses %s" % [seam, hovers, alerts_kept, str(alert_in == 1), buses])
	# 26. the view you left is where the next start flies to (window state is restored the same way)
	world.orbit.fly_to(world.td.world_at(Mission.hab_xy() + Vector2(400.0, -250.0)), 620.0, 1.1, deg_to_rad(38.0), 0.6)
	await _wait(1.4)
	var saved := world.camera_state()
	world.home_view()
	await _wait(2.5)
	world.cinematic_intro(1.0, saved)
	await _wait(2.0)
	var tgt := Vector3(float(saved["x"]), float(saved["y"]), float(saved["z"]))
	var off := Vector2(world.orbit.target.x - tgt.x, world.orbit.target.z - tgt.z).length()
	var dd := absf(world.orbit.dist - float(saved["dist"]))
	var ok_cam := off < 1.0 and dd < 1.0 and absf(angle_difference(world.orbit.yaw, float(saved["yaw"]))) < 0.01
	var w := get_window()
	var size0 := w.size
	var want := (size0 - Vector2i(40, 20)).max(w.min_size)
	var keep := [Settings.get_state("window_size"), Settings.get_state("window_pos"), Settings.get_state("window_mode")]
	Settings.set_state("window_size", want)
	Settings.set_state("window_pos", w.position)
	Settings.set_state("window_mode", "windowed")
	_restore_window()
	await _wait(0.5)
	var size1 := w.size
	w.size = size0
	for k in 3:
		if keep[k] == null:
			Settings._cfg.erase_section_key("state", ["window_size", "window_pos", "window_mode"][k])
		else:
			Settings.set_state(["window_size", "window_pos", "window_mode"][k], keep[k])
	_check(26, ok_cam and size1 == want, "start flew to the saved view: %.1f m from its target, distance off %.1f m; window restored at %s (saved %s)" % [off, dd, str(size1), str(want)])
	await _wait(1.0)
	# 27. the guided tour: steps ring the real controls, the bubble never covers its control, Esc ends it
	var first_run: Variant = Settings.get_value("first_run_done")
	world.home_view()
	await _wait(2.0)
	_start_coach()
	await _wait(0.8)
	var steps_ok := 0
	var notes := PackedStringArray()
	var total := coach._steps.size()
	for i in total:
		await _wait(0.7)
		var hole: Rect2 = coach._hole_to
		var bub := Rect2(coach._bubble.position, coach._bubble.size)
		var inside := Rect2(Vector2.ZERO, coach.size).encloses(bub)
		var clear := hole.size == Vector2.ZERO or not bub.intersects(hole)
		var ring_on := hole.size == Vector2.ZERO or Rect2(Vector2.ZERO, coach.size).has_point(hole.get_center())
		if inside and clear and ring_on and coach.step() == i:
			steps_ok += 1
		else:
			notes.append("step %d: bubble inside %s, clear %s, ring on screen %s" % [i + 1, inside, clear, ring_on])
		if i == 1 or i == 3:
			await _shot("27_coach_step%d.png" % (i + 1))
		if i < total - 1:
			var ev := InputEventKey.new()
			ev.keycode = KEY_ENTER
			ev.pressed = true
			Input.parse_input_event(ev)
			await get_tree().process_frame
	var esc := InputEventKey.new()
	esc.keycode = KEY_ESCAPE
	esc.physical_keycode = KEY_ESCAPE
	esc.pressed = true
	Input.parse_input_event(esc)
	await _wait(0.5)
	var ended := not coach.active() and bool(Settings.get_value("first_run_done"))
	Settings.set_value("first_run_done", first_run)   # leave the real first run alone
	_check(27, steps_ok == total and ended, "%d/%d steps ringed their control with the bubble clear of it and on screen%s; Esc ended the tour %s" % [steps_ok, total, (" (" + "; ".join(notes) + ")") if not notes.is_empty() else "", ended])
	# 28. the demo: runs every shot by itself, and any input hands control back at once
	var speed0 := Mission.speed_index
	_play_demo()
	var seen := {}
	var t_end := Time.get_ticks_msec() + 110000   # the demo opens with the layer tower (sheets load on first use)
	var behind := -1.0
	while director.running and Time.get_ticks_msec() < t_end:
		await get_tree().process_frame
		if not seen.has(director.shot):
			seen[director.shot] = Time.get_ticks_msec()
			if director.shot in ["chase", "helmet"]:
				_shot_later("28_demo_%s.png" % director.shot, 4.0)
		if director.shot == "chase" and behind < 0.0 and Time.get_ticks_msec() - int(seen["chase"]) > 7000:
			var st := Mission.state_at(Mission.eva_t)
			var dir: Vector2 = (st["xy_ahead"] as Vector2) - (st["xy"] as Vector2)
			behind = rad_to_deg(absf(angle_difference(world.orbit.yaw, -atan2(dir.x, dir.y))))
	seen.erase("")
	var full_run := not director.running and seen.has("tower") and seen.has("overview") and seen.has("chase") and seen.has("station") and seen.has("helmet") and seen.has("outro") and world.mode == "orbit" and Mission.speed_index == speed0
	await _wait(1.5)
	_play_demo()
	await _wait(9.0)
	var shot_then := director.shot
	var k := InputEventKey.new()
	k.keycode = KEY_K
	k.physical_keycode = KEY_K
	k.pressed = true
	Input.parse_input_event(k)
	await get_tree().process_frame
	var handed := not director.running and not Mission.playing
	_check(28, full_run and behind >= 0.0 and behind < 45.0 and handed,
		"shots %s; chase camera %.0f° off straight behind the crew; ended in orbit at speed x%d; a key press during '%s' handed control back %s" % [
			", ".join(PackedStringArray(seen.keys())), behind, int(Mission.play_speed()), shot_then, handed])
	await _wait(1.0)


## Item 23: the settings panel. Each setting is changed through its control and must take effect at once
## and be in user://settings.cfg; afterwards every setting goes back to what it was.
func _settings_tour() -> void:
	await _await_plan()
	var before := {}
	for key in Settings.DEFAULTS:
		before[key] = Settings.get_value(key)
	settings_panel.toggle(ui.size)
	await _wait(0.6)
	await _shot("23_settings.png")
	var c: Dictionary = settings_panel._controls
	var pick := func(key: String, value: String) -> void:
		var ob := c[key] as OptionButton
		for i in ob.item_count:
			if str(ob.get_item_metadata(i)) == value:
				ob.select(i)
				ob.item_selected.emit(i)
	var res := PackedStringArray()
	var ok := true
	# graphics: quality preset and glass, live
	pick.call("quality", "medium")
	var q_ok := Quality.level == "medium" and is_equal_approx(get_viewport().scaling_3d_scale, float(Quality.PRESETS["medium"]["scale"]))
	pick.call("quality", "low")
	q_ok = q_ok and Quality.level == "low"
	pick.call("glass", "on")
	var g_on := UiKit.glass_blur
	pick.call("glass", "auto")
	var g_auto := UiKit.glass_blur
	res.append("quality medium/low live %s; glass on -> blur %s, auto on Low -> blur %s" % [q_ok, g_on, g_auto])
	ok = ok and q_ok and g_on and not g_auto
	# interface size
	pick.call("ui_scale", "1.3")
	await get_tree().process_frame
	var fit := minf(get_window().size.x / 1600.0, get_window().size.y / 900.0)
	var sc_ok := is_equal_approx(get_window().content_scale_factor, 1.3)
	pick.call("ui_scale", "auto")
	await get_tree().process_frame
	var auto_f := get_window().content_scale_factor
	res.append("interface x1.3 %s, auto -> x%.2f (window fits the design at x%.2f)" % [sc_ok, auto_f, fit])
	ok = ok and sc_ok and auto_f >= 1.0
	# mouse: sensitivity doubles a look; invert flips it
	(c["mouse_sens"] as HSlider).value = 2.0
	var p0 := world.walker.pitch
	world.walker.look(Vector2(0, 10))
	var down2 := p0 - world.walker.pitch
	(c["mouse_sens"] as HSlider).value = 1.0
	world.walker.pitch = p0
	world.walker.look(Vector2(0, 10))
	var down1 := p0 - world.walker.pitch
	(c["invert_y"] as CheckButton).button_pressed = true
	world.walker.pitch = p0
	world.walker.look(Vector2(0, 10))
	var inv := p0 - world.walker.pitch
	(c["invert_y"] as CheckButton).button_pressed = false
	world.walker.pitch = p0
	var m_ok := is_equal_approx(down2, 2.0 * down1) and is_equal_approx(inv, -down1)
	res.append("look x2 turns %.3f vs %.3f rad, inverted %.3f %s" % [down2, down1, inv, m_ok])
	ok = ok and m_ok
	# sound buses
	(c["vol_ui"] as HSlider).value = 0.5
	(c["vol_ambience"] as HSlider).value = 0.0
	var ui_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(Sfx.BUS_UI))
	var amb_db := AudioServer.get_bus_volume_db(AudioServer.get_bus_index(Sfx.BUS_AMB))
	var v_ok := absf(ui_db - linear_to_db(0.5)) < 0.1 and amb_db <= -79.0
	res.append("UI bus %.1f dB, ambience %.0f dB %s" % [ui_db, amb_db, v_ok])
	ok = ok and v_ok
	# helmet: field of view and visor effects
	settings_panel.close()
	(c["walk_fov"] as HSlider).value = 84.0
	(c["visor_fx"] as CheckButton).button_pressed = false
	Mission.set_time(1500.0)
	_set_mode("walk")
	await _wait(3.5)
	var fov := world.camera.fov
	var visor_off := not visor.visible
	(c["visor_fx"] as CheckButton).button_pressed = true
	var visor_on := visor.visible
	await _shot("23_fov84.png")
	var h_ok := absf(fov - 84.0) < 1.0 and visor_off and visor_on
	res.append("helmet FOV %.1f° (set 84), visor off %s, back on %s" % [fov, visor_off, visor_on])
	ok = ok and h_ok
	_set_mode("orbit")
	await _wait(2.0)
	# saved: a fresh read of the file has the last values
	var cf := ConfigFile.new()
	var err := cf.load(Settings.PATH)
	var saved_ok := err == OK and is_equal_approx(float(cf.get_value("settings", "walk_fov", 0.0)), 84.0) and float(cf.get_value("settings", "vol_ambience", 1.0)) == 0.0
	res.append("saved to %s %s" % [Settings.PATH, saved_ok])
	ok = ok and saved_ok
	for key in before:
		Settings.set_value(key, before[key])
	settings_panel.sync()
	_check(23, ok, "; ".join(res))


## Screenshot after a delay, without holding up the caller.
func _shot_later(name: String, after: float) -> void:
	await _wait(after)
	await _shot(name)


## Item 20 check: terrain LOD pop and shimmer with the camera held still. Only the terrain grid moves:
## a helper re-places it (TerrainClipmap.follow) for a pretend camera just before each frame is drawn,
## and everything else that moves is hidden, so two screenshots differ only where the terrain changed.
## pop: the grid steps a level (pretend height 515 -> 525 m above the ground; the spacing doubles at
## 520 m), next to 505 -> 515 m (no step). shimmer: the grid slides sideways one snap step (2 m at 600 m
## height) at a time, as when the camera pans. Mean luminance change (0-255) over the top 55 % of the view.
func _lod_tour() -> void:
	await _await_plan()
	ui.visible = false
	for c in world.get_children():
		if c == world.terrain_mesh or c == world.camera or c is Light3D or not (c is Node3D):
			continue
		(c as Node3D).visible = false
	world.terrain_mesh.set_param("marker_count", 0)
	world.orbit.auto_rotate = false
	var helper := Node.new()
	var s := GDScript.new()
	s.source_code = "extends Node\nvar cb: Callable\nfunc _process(_d: float) -> void:\n\tif cb.is_valid():\n\t\tcb.call()\n"
	s.reload()
	helper.set_script(s)
	helper.process_priority = 1000   # after the world has placed the grid for the real camera
	add_child(helper)
	helper.set("cb", _lod_apply)
	await _lod_place(world.home_target(), 515.0)
	await _wait(1.5)
	var imgs: Array = []
	for above in [505.0, 515.0, 525.0]:
		_lod_force = {"dx": 0.0, "above": above}
		imgs.append(await _lod_grab())
	var still := _img_diff(imgs[0], imgs[1])
	var cross := _img_diff(imgs[1], imgs[2])
	print("lod pop (camera still): 505->515 m %.3f, 515->525 m across the level step %.3f" % [still, cross])
	var tag := "new" if FileAccess.file_exists("res://scripts/core/settings.gd") else "orig"
	for j in 3:
		(imgs[j] as Image).save_png(capture_dir.path_join("lod_%s_%d.png" % [tag, j]))
	var prev: Image = null
	var total := 0.0
	var worst := 0.0
	var steps := 0
	for i in 9:
		_lod_force = {"dx": 2.0 * i, "above": 600.0}
		var img: Image = await _lod_grab()
		if prev:
			var dv := _img_diff(prev, img)
			total += dv
			worst = maxf(worst, dv)
			steps += 1
		prev = img
	print("lod shimmer (camera still): %.3f per 2 m grid step, worst %.3f (%d steps)" % [total / maxf(1.0, steps), worst, steps])
	_lod_force = {}
	helper.queue_free()
	ui.visible = true


var _lod_force := {}   # {"dx": m, "above": m}: where _lod_apply pretends the camera is


func _lod_apply() -> void:
	if _lod_force.is_empty():
		return
	var cp: Vector3 = world.camera.global_position
	world.terrain_mesh.follow(cp + Vector3(float(_lod_force["dx"]), 0.0, 0.0), cp.y - float(_lod_force["above"]))


func _lod_place(tgt: Vector3, above: float) -> void:
	var o = world.orbit
	o.target = tgt
	o.yaw = -2.6
	o.pitch = deg_to_rad(22.0)
	var d := above / sin(deg_to_rad(22.0))
	for it in 4:
		o.dist = d
		o.snap()
		await get_tree().process_frame
		var cp: Vector3 = world.camera.global_position
		var a: float = cp.y - world.td.h(cp.x, -cp.z)
		d *= above / maxf(a, 1.0)
	o.dist = d
	o.snap()
	for k in 3:
		await get_tree().process_frame


func _lod_grab() -> Image:
	await get_tree().process_frame
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## Mean absolute luminance change (0-255) over the top 55 % of the view, every third pixel.
func _img_diff(a: Image, b: Image) -> float:
	var w := mini(a.get_width(), b.get_width())
	var h := int(mini(a.get_height(), b.get_height()) * 0.55)
	var acc := 0.0
	var n := 0
	for y in range(0, h, 3):
		for x in range(0, w, 3):
			acc += absf(a.get_pixel(x, y).get_luminance() - b.get_pixel(x, y).get_luminance())
			n += 1
	return acc / maxf(1.0, float(n)) * 255.0


func _await_plan(limit := 240.0) -> float:
	var waited := 0.0
	# at boot the first plan's request may not have gone out yet: wait for it to start (or give up after 20 s)
	while not Mission.has_plan() and not Mission.planning and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	while Mission.planning and waited < limit:
		await get_tree().process_frame
		waited += get_process_delta_time()
	return waited


## Rover-assisted EVA: PR-2 drives the crew out to a drop-off near the stops and back.
func _rover_tour() -> void:
	var was_rover := Mission.rover_enabled
	var was_drop := Mission.rover_dropoff.duplicate()
	var was_sep := Mission.sep_active
	await _await_plan()   # a re-plan still in flight (e.g. the storm drill) would swallow ours
	Mission.sep_active = false
	Mission.rover_dropoff = {}
	Mission.set_rover(true)
	Mission.request_plan()
	var waited := await _await_plan()
	await _wait(1.0)
	if Mission.has_rover():
		var drive_t := float(Mission.plan["events"][0]["t1"])
		print("rover plan: drive %.0f m / %.0f s, walk %.0f m, wait %.0f s" % [float(Mission.plan["totals"]["drive_m"]), float(Mission.plan["totals"]["drive_s"]),
			float(Mission.plan["totals"]["dist_m"]), waited])
		Mission.set_time(drive_t * 0.55)
		world.focus_xy(Mission.rover_state(Mission.eva_t)["xy"], 240.0)
		await _wait(4.0)
		await _shot("12_rover_drive.png")
		_set_mode("walk")
		Mission.set_time(drive_t * 0.6)
		await _wait(4.0)
		await _shot("13_rover_ride.png")
		Mission.set_time(drive_t + 1200.0)
		await _wait(2.5)
		await _shot("14_rover_parked_walk.png")
		_set_mode("orbit")
		# the PLACE tool: park PR-2 by hand 60 m east of the automatic drop-off
		var auto_xy := Mission.haven_xy()
		_set_tool("place-pr")
		_on_ground_click(auto_xy + Vector2(60.0, 0.0))
		await _await_plan()
		var d: Dictionary = Mission.plan.get("rover", {}).get("dropoff", {})
		print("place tool: dropoff auto=%s moved %.0f m, drive %.0f m" % [str(d.get("auto", "?")), Mission.haven_xy().distance_to(auto_xy),
			float(Mission.plan["totals"].get("drive_m", 0.0))])
	else:
		print("rover plan failed: '%s' (waited %.0f s)" % [Mission.plan_error, waited])
	Mission.rover_dropoff = was_drop
	Mission.rover_enabled = was_rover
	Mission.sep_active = was_sep
	Mission.save_mission()
