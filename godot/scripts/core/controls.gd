class_name Controls
extends RefCounted
## Input actions for the keyboard and a gamepad, registered at start-up (project.godot stays short), and
## the rebinding behind Settings → CONTROLS. Movement keys are bound by their physical position, so
## WASD / QE / RF work on AZERTY and other layouts too; shortcut letters (H, M, C, …) by their letter.
## Bindings you change are saved in user://settings.cfg [controls] and applied over these defaults.
##
## Gamepad: left stick walks (pans in orbit view), right stick looks (rotates and tilts in orbit),
## triggers zoom, A jump · B back · X play/pause · Y helmet/orbit, LB lope, RB autopilot, L3 cuff menu,
## hold R3 abort, d-pad up acknowledge · down silence · left/right playback speed, Start help, Back hides
## the interface.

const DEADZONE := 0.2

## Every action you can rebind: [action, what it does, group].
const ACTIONS := [
	["move_forward", "Walk forward · pan", "Walking and camera"], ["move_back", "Walk back · pan", "Walking and camera"],
	["move_left", "Step left · pan", "Walking and camera"], ["move_right", "Step right · pan", "Walking and camera"],
	["lope", "Lope (faster)", "Walking and camera"], ["jump", "Jump", "Walking and camera"],
	["autopilot", "Autopilot on / off", "Walking and camera"], ["mouse_lock", "Lock mouse-look", "Walking and camera"],
	["rotate_left", "Turn the map left", "Walking and camera"], ["rotate_right", "Turn the map right", "Walking and camera"],
	["tilt_up", "Tilt the map up", "Walking and camera"], ["tilt_down", "Tilt the map down", "Walking and camera"],
	["zoom_in", "Zoom in", "Walking and camera"], ["zoom_out", "Zoom out", "Walking and camera"],
	["alarm_ack", "Acknowledge the top alert", "Caution and warning"], ["alarm_silence", "Silence the alarm tone", "Caution and warning"],
	["cw_panel", "Alert list, log and catalogue", "Caution and warning"], ["abort", "ABORT EVA (hold)", "Caution and warning"],
	["cuff_menu", "Cuff menu", "Caution and warning"],
	["toggle_view", "Orbit ⇄ helmet", "Console"], ["play_pause", "Play / pause the EVA", "Console"],
	["speed_down", "Slower", "Console"], ["speed_up", "Faster", "Console"], ["home", "Home view / back to egress", "Console"],
	["hide_ui", "Hide the interface", "Console"], ["mute", "Mute (alarms keep sounding)", "Console"],
	["contours", "Contours", "Console"], ["grid", "Survey grid", "Console"], ["labels", "Labels", "Console"],
	["ping", "Terrain scan", "Console"], ["help", "Help", "Console"], ["settings", "Settings", "Console"],
	["fullscreen", "Fullscreen", "Console"], ["back", "Back / close", "Console"],
]

static var _defaults := {}   # action -> Array of event descriptors, as registered by setup()


static func setup() -> void:
	if InputMap.has_action("move_forward"):
		return
	# walking (helmet) and panning (orbit)
	_phys("move_forward", KEY_W)
	_key("move_forward", KEY_UP)
	_axis("move_forward", JOY_AXIS_LEFT_Y, -1.0)
	_phys("move_back", KEY_S)
	_key("move_back", KEY_DOWN)
	_axis("move_back", JOY_AXIS_LEFT_Y, 1.0)
	_phys("move_left", KEY_A)
	_axis("move_left", JOY_AXIS_LEFT_X, -1.0)
	_phys("move_right", KEY_D)
	_axis("move_right", JOY_AXIS_LEFT_X, 1.0)
	_key("turn_left", KEY_LEFT)
	_key("turn_right", KEY_RIGHT)
	_phys("lope", KEY_SHIFT)
	_button("lope", JOY_BUTTON_LEFT_SHOULDER)
	_phys("jump", KEY_SPACE)
	_button("jump", JOY_BUTTON_A)
	_phys("autopilot", KEY_TAB)
	_button("autopilot", JOY_BUTTON_RIGHT_SHOULDER)
	_phys("mouse_lock", KEY_F)
	# looking (helmet) / rotating and tilting (orbit)
	_axis("look_left", JOY_AXIS_RIGHT_X, -1.0)
	_axis("look_right", JOY_AXIS_RIGHT_X, 1.0)
	_axis("look_up", JOY_AXIS_RIGHT_Y, -1.0)
	_axis("look_down", JOY_AXIS_RIGHT_Y, 1.0)
	_phys("rotate_left", KEY_Q)
	_phys("rotate_right", KEY_E)
	_phys("tilt_up", KEY_R)
	_phys("tilt_down", KEY_F)
	_key("zoom_in", KEY_PAGEUP)
	_key("zoom_in", KEY_EQUAL)
	_axis("zoom_in", JOY_AXIS_TRIGGER_RIGHT, 1.0)
	_key("zoom_out", KEY_PAGEDOWN)
	_key("zoom_out", KEY_MINUS)
	_axis("zoom_out", JOY_AXIS_TRIGGER_LEFT, 1.0)
	# caution and warning
	_key("alarm_ack", KEY_ENTER)
	_key("alarm_ack", KEY_KP_ENTER)
	_button("alarm_ack", JOY_BUTTON_DPAD_UP)
	_key("alarm_ack_all", KEY_ENTER, false, true)
	_key("alarm_silence", KEY_BACKSPACE)
	_button("alarm_silence", JOY_BUTTON_DPAD_DOWN)
	_key("cw_panel", KEY_F3)
	_key("abort", KEY_END)
	_button("abort", JOY_BUTTON_RIGHT_STICK)
	_key("cuff_menu", KEY_X)
	_button("cuff_menu", JOY_BUTTON_LEFT_STICK)
	# anywhere
	_key("back", KEY_ESCAPE)
	_button("back", JOY_BUTTON_B)
	_key("toggle_view", KEY_V)
	_button("toggle_view", JOY_BUTTON_Y)
	_key("play_pause", KEY_P)
	_button("play_pause", JOY_BUTTON_X)
	_key("speed_down", KEY_BRACKETLEFT)
	_button("speed_down", JOY_BUTTON_DPAD_LEFT)
	_key("speed_up", KEY_BRACKETRIGHT)
	_button("speed_up", JOY_BUTTON_DPAD_RIGHT)
	_key("home", KEY_HOME)
	_key("hide_ui", KEY_H)
	_button("hide_ui", JOY_BUTTON_BACK)
	_key("mute", KEY_M)
	_key("contours", KEY_C)
	_key("grid", KEY_G)
	_key("labels", KEY_L)
	_key("ping", KEY_J)
	_key("help", KEY_F1)
	_key("help", KEY_SLASH)
	_key("help", KEY_QUESTION)
	_button("help", JOY_BUTTON_START)
	_key("fullscreen", KEY_F11)
	_key("settings", KEY_F2)
	for i in 5:
		_key("cuff_%d" % (i + 1), KEY_1 + i)
	_key("undo", KEY_Z, true)
	_key("redo", KEY_Y, true)
	_key("redo", KEY_Z, true, true)
	for a in InputMap.get_actions():
		if not str(a).begins_with("ui_"):
			_defaults[str(a)] = _descs(str(a))
	apply_overrides()
	set_deadzone(Settings.deadzone)


# ------------------------------------------------------------------ rebinding
## Put the saved bindings over the defaults (on start-up and after a reset).
static func apply_overrides() -> void:
	for a in _defaults:
		var saved: Variant = Settings.get_binding(str(a))
		var list: Array = saved if saved is Array else _defaults[a]
		InputMap.action_erase_events(str(a))
		for dsc in list:
			var ev := desc_to_event(dsc)
			if ev:
				InputMap.action_add_event(str(a), ev)
	set_deadzone(Settings.deadzone)


## Replace the keyboard (pad = false) or gamepad (pad = true) binding of `action` with `ev`, and save it.
static func rebind(action: String, ev: InputEvent, pad: bool) -> void:
	var keep := []
	var replaced := false
	for e in InputMap.action_get_events(action):
		var is_pad := e is InputEventJoypadButton or e is InputEventJoypadMotion
		if is_pad == pad and not replaced:
			keep.append(event_to_desc(ev))   # the first binding of that kind is the one shown and changed
			replaced = true
		else:
			keep.append(event_to_desc(e))
	if not replaced:
		keep.append(event_to_desc(ev))
	Settings.set_binding(action, keep)
	apply_overrides()


static func reset_all() -> void:
	Settings.clear_bindings()
	apply_overrides()


## Other rebindable actions already using `ev` (shown as a warning; shared keys are allowed on purpose).
static func conflicts(ev: InputEvent, except_action: String) -> Array:
	var out := []
	for row in ACTIONS:
		var a := str(row[0])
		if a == except_action:
			continue
		for e in InputMap.action_get_events(a):
			if _same(e, ev):
				out.append(str(row[1]))
	return out


## The first keyboard / gamepad binding of an action, as text ("—" if none).
static func binding_text(action: String, pad: bool) -> String:
	for e in InputMap.action_get_events(action):
		var is_pad := e is InputEventJoypadButton or e is InputEventJoypadMotion
		if is_pad == pad:
			return event_text(e)
	return "—"


static func event_text(e: InputEvent) -> String:
	if e is InputEventKey:
		var k := e as InputEventKey
		var code := k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode
		var name := OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(code) if k.physical_keycode != KEY_NONE else code)
		var mods := ""
		if k.ctrl_pressed:
			mods += "Ctrl+"
		if k.shift_pressed:
			mods += "Shift+"
		if k.alt_pressed:
			mods += "Alt+"
		return mods + name
	if e is InputEventJoypadButton:
		var names := {JOY_BUTTON_A: "Pad A", JOY_BUTTON_B: "Pad B", JOY_BUTTON_X: "Pad X", JOY_BUTTON_Y: "Pad Y", JOY_BUTTON_LEFT_SHOULDER: "LB",
			JOY_BUTTON_RIGHT_SHOULDER: "RB", JOY_BUTTON_LEFT_STICK: "L3", JOY_BUTTON_RIGHT_STICK: "R3", JOY_BUTTON_START: "Start",
			JOY_BUTTON_BACK: "Back", JOY_BUTTON_DPAD_UP: "D-pad ▲", JOY_BUTTON_DPAD_DOWN: "D-pad ▼", JOY_BUTTON_DPAD_LEFT: "D-pad ◀",
			JOY_BUTTON_DPAD_RIGHT: "D-pad ▶"}
		return str(names.get((e as InputEventJoypadButton).button_index, "Pad button %d" % (e as InputEventJoypadButton).button_index))
	if e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		var axes := {JOY_AXIS_LEFT_X: ["Left stick ◀", "Left stick ▶"], JOY_AXIS_LEFT_Y: ["Left stick ▲", "Left stick ▼"],
			JOY_AXIS_RIGHT_X: ["Right stick ◀", "Right stick ▶"], JOY_AXIS_RIGHT_Y: ["Right stick ▲", "Right stick ▼"],
			JOY_AXIS_TRIGGER_LEFT: ["LT", "LT"], JOY_AXIS_TRIGGER_RIGHT: ["RT", "RT"]}
		var pair: Array = axes.get(m.axis, ["Axis %d -" % m.axis, "Axis %d +" % m.axis])
		return str(pair[0] if m.axis_value < 0.0 else pair[1])
	return "?"


static func event_to_desc(e: InputEvent) -> Dictionary:
	if e is InputEventKey:
		var k := e as InputEventKey
		return {"t": "key", "phys": int(k.physical_keycode), "code": int(k.keycode), "ctrl": k.ctrl_pressed, "shift": k.shift_pressed, "alt": k.alt_pressed}
	if e is InputEventJoypadButton:
		return {"t": "joyb", "b": int((e as InputEventJoypadButton).button_index)}
	if e is InputEventJoypadMotion:
		var m := e as InputEventJoypadMotion
		return {"t": "joya", "a": int(m.axis), "v": -1.0 if m.axis_value < 0.0 else 1.0}
	return {}


static func desc_to_event(d: Variant) -> InputEvent:
	if not (d is Dictionary):
		return null
	var dd: Dictionary = d
	match str(dd.get("t", "")):
		"key":
			var k := InputEventKey.new()
			k.physical_keycode = int(dd.get("phys", 0)) as Key
			k.keycode = int(dd.get("code", 0)) as Key
			k.ctrl_pressed = bool(dd.get("ctrl", false))
			k.shift_pressed = bool(dd.get("shift", false))
			k.alt_pressed = bool(dd.get("alt", false))
			return k
		"joyb":
			var b := InputEventJoypadButton.new()
			b.button_index = int(dd.get("b", 0)) as JoyButton
			return b
		"joya":
			var m := InputEventJoypadMotion.new()
			m.axis = int(dd.get("a", 0)) as JoyAxis
			m.axis_value = float(dd.get("v", 1.0))
			return m
	return null


## Stick dead zone for every action with a stick or trigger binding.
static func set_deadzone(v: float) -> void:
	for a in InputMap.get_actions():
		for e in InputMap.action_get_events(a):
			if e is InputEventJoypadMotion:
				InputMap.action_set_deadzone(a, v)
				break


static func _same(a: InputEvent, b: InputEvent) -> bool:
	if a is InputEventKey and b is InputEventKey:
		var ka := a as InputEventKey
		var kb := b as InputEventKey
		var same_key := (ka.physical_keycode != KEY_NONE and ka.physical_keycode == kb.physical_keycode) or (ka.keycode != KEY_NONE and ka.keycode == kb.keycode)
		return same_key and ka.ctrl_pressed == kb.ctrl_pressed and ka.shift_pressed == kb.shift_pressed
	if a is InputEventJoypadButton and b is InputEventJoypadButton:
		return (a as InputEventJoypadButton).button_index == (b as InputEventJoypadButton).button_index
	if a is InputEventJoypadMotion and b is InputEventJoypadMotion:
		var ma := a as InputEventJoypadMotion
		var mb := b as InputEventJoypadMotion
		return ma.axis == mb.axis and signf(ma.axis_value) == signf(mb.axis_value)
	return false


static func _descs(action: String) -> Array:
	var out := []
	for e in InputMap.action_get_events(action):
		out.append(event_to_desc(e))
	return out


static func _add(action: String) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action, DEADZONE)


## Bound by the key's position on the keyboard (layout-independent).
static func _phys(action: String, code: Key) -> void:
	_add(action)
	var e := InputEventKey.new()
	e.physical_keycode = code
	InputMap.action_add_event(action, e)


## Bound by the character on the key.
static func _key(action: String, code: Key, ctrl := false, shift := false) -> void:
	_add(action)
	var e := InputEventKey.new()
	e.keycode = code
	e.ctrl_pressed = ctrl
	e.shift_pressed = shift
	InputMap.action_add_event(action, e)


static func _button(action: String, b: JoyButton) -> void:
	_add(action)
	var e := InputEventJoypadButton.new()
	e.button_index = b
	InputMap.action_add_event(action, e)


static func _axis(action: String, axis: JoyAxis, dir: float) -> void:
	_add(action)
	var e := InputEventJoypadMotion.new()
	e.axis = axis
	e.axis_value = dir
	InputMap.action_add_event(action, e)
