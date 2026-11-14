extends Node
## User settings (autoload "Settings"), saved in user://settings.cfg: graphics, display, HUD, alerts,
## controls and sound, plus where the window and the camera were last time (state) and the key bindings
## you changed (controls). Read the hot values straight from the properties; set anything with set_value(),
## which saves and emits `changed`.

signal changed(key: String)

const PATH := "user://settings.cfg"
const DEFAULTS := {
	# graphics
	"quality": "auto",      # auto | low | medium | high (mesh size and textures apply on the next start)
	"glass": "auto",        # auto | on | off: frosted (blurred) panels; auto = off on the low preset
	"visor_fx": true,       # helmet lens curvature, tint, breath fog
	"walk_fov": 72.0,       # helmet field of view (degrees)
	"render_scale": "auto", # auto (the preset's) | 0.5 .. 1.0: 3D resolution, FSR-upscaled below 1
	"fps_cap": 0,           # 0 = no cap | 30 | 60 | 90 | 120
	"vsync": true,
	"show_fps": false,
	# display
	"ui_scale": "auto",     # auto | 0.9 | 1.0 | 1.15 | 1.3 (on top of fitting 1600x900 to the window)
	"min_text": 11,         # smallest text, design px: 11 | 13 | 16 (16 = NASA's 12 pt label minimum)
	"palette": "standard",  # standard | cvd (colour-blind safe)
	"reduce_flashing": false,
	"pressure_unit": "kPa", # kPa | psi (suit pressure and ppO2; ppCO2 is always mmHg, as NASA states its limits)
	# HUD
	"hud_declutter": "full",  # full | essential | minimal
	"hud_opacity": 1.0,       # 0.4 .. 1.0 (alerts always stay fully opaque)
	"hud_tint": "cyan",       # cyan | green | amber | white
	# alerts
	"vol_alerts": 0.8,        # 0.3 .. 1 (an alarm can be turned down, never off)
	"speech": "warnings",     # off | warnings | all: spoken alerts
	"advisory_tones": true,   # NASA lets crews silence advisory tones for sleep and quiet periods
	"cw_inhibited": [],       # alert ids taken out of service (reported every 5 minutes)
	# controls
	"mouse_sens": 1.0,      # 0.4 .. 2.0
	"invert_y": false,      # helmet
	"invert_orbit": false,  # orbit view tilt
	"deadzone": 0.2,        # gamepad sticks, 0.05 .. 0.5
	"zoom_speed": 1.0,      # 0.5 .. 2.0
	"pan_speed": 1.0,       # 0.5 .. 2.0 (keyboard and stick panning)
	"lope_toggle": false,   # Shift / LB toggles loping instead of holding it
	"look_toggle": false,   # the right button toggles mouse-look instead of holding it
	"glove_mode": false,    # bigger targets; every crew action on the cuff menu
	"voice_commands": false,
	# sound
	"vol_ui": 0.8,          # 0 .. 1
	"vol_ambience": 0.8,
	"first_run_done": false,
}

var mouse_sens := 1.0
var invert_y := false
var invert_orbit := false
var walk_fov := 72.0
var visor_fx := true
var deadzone := 0.2
var zoom_speed := 1.0
var pan_speed := 1.0
var lope_toggle := false
var look_toggle := false
var pressure_unit := "kPa"
var _cfg := ConfigFile.new()
var _dirty := false


func _ready() -> void:
	_cfg.load(PATH)   # a missing file just means defaults
	_refresh_cache()


func get_value(key: String) -> Variant:
	return _cfg.get_value("settings", key, DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	_cfg.set_value("settings", key, value)
	_cfg.save(PATH)
	_refresh_cache()
	changed.emit(key)


## Remembered state (window placement, camera per site): saved together, without a `changed` signal.
func get_state(key: String, fallback: Variant = null) -> Variant:
	if not _cfg.has_section_key("state", key):
		return fallback   # (ConfigFile.get_value logs an error for a missing key with a null default)
	return _cfg.get_value("state", key, fallback)


func set_state(key: String, value: Variant) -> void:
	_cfg.set_value("state", key, value)
	_dirty = true


func save_state() -> void:
	if _dirty:
		_cfg.save(PATH)
		_dirty = false


## Key and button bindings you changed (action -> Array of event descriptors, see Controls).
func get_binding(action: String) -> Variant:
	if not _cfg.has_section_key("controls", action):
		return null
	return _cfg.get_value("controls", action)


func set_binding(action: String, events: Variant) -> void:
	if events == null:
		if _cfg.has_section_key("controls", action):
			_cfg.erase_section_key("controls", action)
	else:
		_cfg.set_value("controls", action, events)
	_cfg.save(PATH)
	changed.emit("binding")


func clear_bindings() -> void:
	if _cfg.has_section("controls"):
		_cfg.erase_section("controls")
	_cfg.save(PATH)
	changed.emit("binding")


func _refresh_cache() -> void:
	mouse_sens = float(get_value("mouse_sens"))
	invert_y = bool(get_value("invert_y"))
	invert_orbit = bool(get_value("invert_orbit"))
	walk_fov = float(get_value("walk_fov"))
	visor_fx = bool(get_value("visor_fx"))
	deadzone = clampf(float(get_value("deadzone")), 0.05, 0.5)
	zoom_speed = clampf(float(get_value("zoom_speed")), 0.5, 2.0)
	pan_speed = clampf(float(get_value("pan_speed")), 0.5, 2.0)
	lope_toggle = bool(get_value("lope_toggle"))
	look_toggle = bool(get_value("look_toggle"))
	pressure_unit = str(get_value("pressure_unit"))


## dB for a 0..1 volume slider (0 = silent).
static func volume_db(v: float) -> float:
	return -80.0 if v <= 0.001 else linear_to_db(v)
