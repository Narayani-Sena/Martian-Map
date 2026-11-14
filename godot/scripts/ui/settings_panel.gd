class_name SettingsPanel
extends PanelContainer
## Settings (F2 or the gear in the top bar), in tabs: GRAPHICS, DISPLAY, HUD, ALERTS, CONTROLS, SOUND, DATA.
## Every change applies straight away (main.gd listens to Settings.changed) and is saved to
## user://settings.cfg. CONTROLS rebinds any key or gamepad button (press the new one; a clash with another
## action is shown, not blocked, since some keys are shared on purpose).

signal tour_requested
signal export_requested
signal import_requested
signal test_alarms_requested
signal alert_list_requested
signal voice_test_requested

const TABS := ["GRAPHICS", "DISPLAY", "HUD", "ALERTS", "CONTROLS", "SOUND", "DATA"]
var _controls := {}   # setting key -> its control, refreshed by sync()
var _tab := "GRAPHICS"
var _pages := {}
var _tab_btns := {}
var _bind_box: VBoxContainer
var _capture := {}    # {"action", "pad", "button"} while waiting for a key
var _voice_status: Label
var _note: Label
var _scroll: ScrollContainer


func _init() -> void:
	material = UiKit.glass_material(3.0)
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL_SOLID, Color(UiKit.ACCENT, 0.5), 12, 1, 18))
	custom_minimum_size = Vector2(720, 0)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UiKit.vbox(9)
	add_child(v)
	var head := UiKit.hbox(8)
	var title := UiKit.label("Settings", 20, UiKit.TEXT, 700)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	head.add_child(UiKit.button("✕", func(): close(), "Close  [F2 / Esc]"))
	v.add_child(head)
	var tabs := UiKit.hbox(4)
	var group := ButtonGroup.new()
	for t in TABS:
		var name: String = t
		var b := UiKit.button(name, func(): show_tab(name), "", true)
		b.button_group = group
		b.add_theme_font_size_override("font_size", 12)
		tabs.add_child(b)
		_tab_btns[name] = b
	v.add_child(tabs)
	var sc := ScrollContainer.new()
	_scroll = sc
	sc.custom_minimum_size = Vector2(0, 430)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(sc)
	var holder := UiKit.vbox(0)
	holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(holder)
	for t in TABS:
		var page := UiKit.vbox(9)
		page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		page.visible = false
		holder.add_child(page)
		_pages[t] = page
	_build_graphics(_pages["GRAPHICS"])
	_build_display(_pages["DISPLAY"])
	_build_hud(_pages["HUD"])
	_build_alerts(_pages["ALERTS"])
	_build_controls(_pages["CONTROLS"])
	_build_sound(_pages["SOUND"])
	_build_data(_pages["DATA"])
	v.add_child(UiKit.hline())
	_note = UiKit.wrap("", 11, UiKit.DIM)
	v.add_child(_note)
	var acts := UiKit.hbox(8)
	var tour := UiKit.button("SHOW ME AROUND", func():
		close()
		tour_requested.emit(), "The first-run tour of the console again")
	tour.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	acts.add_child(tour)
	acts.add_child(UiKit.button("DEFAULTS", _ask_reset, "Put every setting back to its default (asks first)"))
	acts.add_child(UiKit.button("CLOSE", func(): close(), "[F2 / Esc]"))
	v.add_child(acts)
	show_tab("GRAPHICS")


func show_tab(name: String) -> void:
	_tab = name
	for t in TABS:
		(_pages[t] as Control).visible = t == name
		(_tab_btns[t] as Button).set_pressed_no_signal(t == name)
	if name == "CONTROLS":
		_fill_bindings()
	_note.text = {
		"GRAPHICS": "Shadows, anti-aliasing and render scale change now; terrain mesh size and texture resolution on the next start.",
		"DISPLAY": "NASA-STD-3001: labels at least 12 pt [V2 10066]; colour never the only cue [V2 10045]; consistent units [V2 10046].",
		"HUD": "A helmet display must leave the view clear [V2 11022]. Alerts always stay fully visible, whatever the declutter level.",
		"ALERTS": "Alarm tones per NASA-STD-3001 Table 10.3-1. They can be turned down, never off; M mutes only the interface and ambience.",
		"CONTROLS": "Click a binding, then press the new key or gamepad button (Esc cancels). Clashes are shown, not blocked.",
		"SOUND": "Interface blips and the suit ambience. Alarm volume is under ALERTS.",
		"DATA": "Mission files hold the stops, habitat, relays, walk, suit and rover settings of one site.",
	}.get(name, "")
	reset_size()


func toggle(host_size: Vector2) -> void:
	if visible:
		close()
		return
	sync()
	_scroll.custom_minimum_size.y = clampf(host_size.y - 330.0, 240.0, 470.0)   # the whole panel fits the window
	visible = true
	reset_size()
	position = ((host_size - size) * 0.5).max(Vector2(8, 8))
	UiKit.appear(self, 0.0, 0.25)
	Sfx.play("toggle", -6.0)


func close() -> void:
	_capture = {}
	if visible:
		visible = false
		Sfx.play("toggle", -8.0)


func set_voice_status(text: String, col: Color) -> void:
	if _voice_status:
		_voice_status.text = text
		_voice_status.add_theme_color_override("font_color", col)


# ------------------------------------------------------------------ pages
func _build_graphics(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Rendering", UiKit.ACCENT, 11))
	_option(v, "quality", "Quality preset", [["auto", "Auto (%s here)" % Quality.detect_gpu().capitalize()], ["low", "Low"], ["medium", "Medium"], ["high", "High"]],
		"Shadows, anti-aliasing and render scale change now; terrain mesh size and texture resolution on the next start.")
	_option(v, "render_scale", "3D render scale", [["auto", "Auto (the preset's)"], ["0.5", "50 % (fastest)"], ["0.6", "60 %"], ["0.7", "70 %"], ["0.77", "77 %"], ["0.85", "85 %"], ["1.0", "100 % (sharpest)"]],
		"Below 100 % the 3D view is drawn smaller and upscaled with AMD FSR; on the UHD 620 50 % saves 5-10 ms a frame.")
	_option(v, "glass", "Frosted glass panels", [["auto", "Auto (off on Low)"], ["on", "On"], ["off", "Off (faster)"]],
		"Blurring the 3D view behind the panels costs a full-screen copy every frame.")
	v.add_child(UiKit.caps("Frame rate", UiKit.ACCENT, 11))
	_option(v, "fps_cap", "Frame-rate cap", [[0, "No cap"], [30, "30 FPS"], [60, "60 FPS"], [90, "90 FPS"], [120, "120 FPS"]],
		"A cap keeps a laptop cooler and quieter; NASA asks for on-screen motion at 15 Hz or better (Table 10.2-1).")
	_check(v, "vsync", "V-sync (no tearing; frames wait for the screen)")
	_check(v, "show_fps", "Show the frame rate and frame time")
	v.add_child(UiKit.caps("Helmet", UiKit.ACCENT, 11))
	_check(v, "visor_fx", "Helmet visor effects (lens curve, tint, breath fog)")
	_slider(v, "walk_fov", "Helmet field of view", 60.0, 90.0, 1.0, func(x: float) -> String: return "%d°" % int(x))


func _build_display(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Size and legibility", UiKit.ACCENT, 11))
	_option(v, "ui_scale", "Interface size", [["auto", "Auto"], ["0.9", "Smaller"], ["1.0", "Normal"], ["1.15", "Larger"], ["1.3", "Largest"]],
		"Auto makes small laptop screens a little larger so the smallest text stays readable.")
	_option(v, "min_text", "Smallest text", [[11, "11 px (compact)"], [13, "13 px"], [16, "16 px · NASA 12 pt minimum"]],
		"Raises every caption and label to at least this size. NASA-STD-3001 [V2 10066] asks for 12 pt (16 px at 96 dpi).")
	v.add_child(UiKit.caps("Colour and motion", UiKit.ACCENT, 11))
	_option(v, "palette", "Status colours", [["standard", "Standard"], ["cvd", "Colour-blind safe (Okabe–Ito)"]],
		"Red, yellow, green and blue keep their NASA meanings in both palettes, and every status also has a word or symbol.")
	_check(v, "reduce_flashing", "Reduce flashing: steady alarms, no visor glitches, no flicker")
	v.add_child(UiKit.caps("Units", UiKit.ACCENT, 11))
	_option(v, "pressure_unit", "Suit pressure and ppO₂", [["kPa", "kPa"], ["psi", "psi"]],
		"ppCO₂ is always in mmHg, the unit NASA states its CO₂ limits in. Every value shows its unit [V2 10046].")


func _build_hud(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Helmet HUD", UiKit.ACCENT, 11))
	_option(v, "hud_declutter", "Declutter", [["full", "Full"], ["essential", "Essential (no minimap, ECG, pitch ladder, key hints)"], ["minimal", "Minimal (suit in one line, navigation and alerts)"]],
		"Less on the visor leaves more of the view clear. The alert strip and the master alarm always show.")
	_slider(v, "hud_opacity", "HUD brightness", 0.4, 1.0, 0.05, func(x: float) -> String: return "%d %%" % int(round(x * 100.0)))
	_option(v, "hud_tint", "HUD colour", [["cyan", "Cyan"], ["green", "Green"], ["amber", "Amber"], ["white", "White"]],
		"Pick what reads best against the terrain and the sky. Alert colours do not change.")


func _build_alerts(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Caution and warning", UiKit.ACCENT, 11))
	_slider(v, "vol_alerts", "Alarm volume", 0.3, 1.0, 0.05, func(x: float) -> String: return "%d %%" % int(round(x * 100.0)))
	_option(v, "speech", "Spoken alerts", [["off", "Off"], ["warnings", "Warnings and emergencies"], ["all", "All alerts, advisories too"]],
		"Windows' built-in voice says the alert after its tone (\"Warning. Turn back now.\").")
	_check(v, "advisory_tones", "Advisory tones (NASA allows silencing them for sleep and quiet periods)")
	var h := UiKit.hbox(8)
	h.add_child(UiKit.button("TEST ALARMS", func(): test_alarms_requested.emit(), "Each class in turn: banner, colour, tone and voice [V2 10117]"))
	h.add_child(UiKit.button("ALERT LIST, LOG, CATALOGUE  F3", func(): alert_list_requested.emit(), "Active alerts, the event log, and every alert's limits; take an alert out of service there"))
	v.add_child(h)
	v.add_child(UiKit.wrap("Enter acknowledges the top alert, Shift+Enter all of them, Backspace silences the tone. On a gamepad: d-pad up acknowledges, down silences.", 12, UiKit.DIM))


func _build_controls(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Mouse and sticks", UiKit.ACCENT, 11))
	_slider(v, "mouse_sens", "Look sensitivity", 0.4, 2.0, 0.05, func(x: float) -> String: return "x%.2f" % x)
	_check(v, "invert_y", "Invert vertical look (helmet)")
	_check(v, "invert_orbit", "Invert tilt (orbit view)")
	_slider(v, "deadzone", "Stick dead zone", 0.05, 0.5, 0.01, func(x: float) -> String: return "%d %%" % int(round(x * 100.0)))
	_slider(v, "zoom_speed", "Zoom speed", 0.5, 2.0, 0.05, func(x: float) -> String: return "x%.2f" % x)
	_slider(v, "pan_speed", "Pan speed (keys and stick)", 0.5, 2.0, 0.05, func(x: float) -> String: return "x%.2f" % x)
	_check(v, "lope_toggle", "Lope toggles (press once) instead of hold")
	_check(v, "look_toggle", "Right button toggles mouse-look instead of hold")
	v.add_child(UiKit.caps("Suited operation", UiKit.ACCENT, 11))
	_check(v, "glove_mode", "Glove mode: bigger buttons and grabbers; use the cuff menu (X / L3) for every crew action")
	_check(v, "voice_commands", "Voice commands (Windows speech recognition, offline): say \"suit status\", \"suit acknowledge\" …")
	var vh := UiKit.hbox(8)
	_voice_status = UiKit.label("Voice: off", 12, UiKit.DIM)
	_voice_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vh.add_child(_voice_status)
	vh.add_child(UiKit.button("VOICE SELF-TEST", func(): voice_test_requested.emit(), "Synthesise \"suit status\" with Windows' voice and feed it to the recogniser (no microphone needed)"))
	v.add_child(vh)
	var bh := UiKit.hbox(8)
	var cap := UiKit.caps("Key and button bindings", UiKit.ACCENT, 11)
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bh.add_child(cap)
	bh.add_child(UiKit.button("RESET BINDINGS", func():
		Controls.reset_all()
		_fill_bindings(), "Every key and button back to the default"))
	v.add_child(bh)
	_bind_box = UiKit.vbox(3)
	v.add_child(_bind_box)


func _build_sound(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Sound", UiKit.ACCENT, 11))
	_slider(v, "vol_ui", "Interface sounds", 0.0, 1.0, 0.05, func(x: float) -> String: return "%d %%" % int(round(x * 100.0)))
	_slider(v, "vol_ambience", "Wind, suit fan and breathing", 0.0, 1.0, 0.05, func(x: float) -> String: return "%d %%" % int(round(x * 100.0)))


func _build_data(v: VBoxContainer) -> void:
	v.add_child(UiKit.caps("Mission files", UiKit.ACCENT, 11))
	var h := UiKit.hbox(8)
	h.add_child(UiKit.button("EXPORT MISSION…", func(): export_requested.emit(), "Save this site's mission (stops, habitat, relays, walk, suit, rover) as a .json file"))
	h.add_child(UiKit.button("IMPORT MISSION…", func(): import_requested.emit(), "Load a mission file for this site (Ctrl+Z undoes it)"))
	v.add_child(h)
	v.add_child(UiKit.wrap("The console also keeps your mission for each site automatically, so a crash or a restart loses nothing (NASA-STD-3001 [V2 10129]).", 12, UiKit.DIM))
	v.add_child(UiKit.caps("Folders", UiKit.ACCENT, 11))
	var h2 := UiKit.hbox(8)
	h2.add_child(UiKit.button("OPEN USER FOLDER", func(): OS.shell_open(ProjectSettings.globalize_path("user://")), "Settings, saved missions, alert logs and the download cache"))
	v.add_child(h2)


# ------------------------------------------------------------------ bindings
func _fill_bindings() -> void:
	if _bind_box == null:
		return
	for c in _bind_box.get_children():
		_bind_box.remove_child(c)
		c.queue_free()
	var group := ""
	for row in Controls.ACTIONS:
		if str(row[2]) != group:
			group = str(row[2])
			_bind_box.add_child(UiKit.caps(group, UiKit.DIM, 10))
		var h := UiKit.hbox(8)
		var l := UiKit.label(str(row[1]), 13, UiKit.TEXT)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		var action := str(row[0])
		for pad in [false, true]:
			var is_pad: bool = pad
			var b := UiKit.button(Controls.binding_text(action, is_pad), func(): _start_capture(action, is_pad), "Click, then press the new %s" % ("gamepad button" if is_pad else "key"))
			b.custom_minimum_size.x = 150
			h.add_child(b)
		_bind_box.add_child(h)


func _start_capture(action: String, pad: bool) -> void:
	_capture = {"action": action, "pad": pad}
	_note.text = "Press the new %s for \"%s\" … (Esc cancels)" % ["gamepad button" if pad else "key", action]
	_note.add_theme_color_override("font_color", UiKit.CAUTION)


func _input(event: InputEvent) -> void:
	if _capture.is_empty() or not visible or not event.is_pressed() or event.is_echo():
		return
	var pad := bool(_capture["pad"])
	if event is InputEventKey and (event as InputEventKey).keycode == KEY_ESCAPE:
		_capture = {}
		show_tab(_tab)
		get_viewport().set_input_as_handled()
		return
	var ok := (not pad and event is InputEventKey) or (pad and (event is InputEventJoypadButton or (event is InputEventJoypadMotion and absf((event as InputEventJoypadMotion).axis_value) > 0.6)))
	if not ok:
		return
	get_viewport().set_input_as_handled()
	var action := str(_capture["action"])
	_capture = {}
	var ev: InputEvent = event
	if event is InputEventJoypadMotion:
		var m := InputEventJoypadMotion.new()
		m.axis = (event as InputEventJoypadMotion).axis
		m.axis_value = signf((event as InputEventJoypadMotion).axis_value)
		ev = m
	var clash := Controls.conflicts(ev, action)
	Controls.rebind(action, ev, pad)
	_fill_bindings()
	_note.text = "%s → %s.%s" % [action, Controls.event_text(ev), ("  Also used by: " + ", ".join(PackedStringArray(clash)) + ".") if not clash.is_empty() else ""]
	_note.add_theme_color_override("font_color", UiKit.CAUTION if not clash.is_empty() else UiKit.GOOD)
	Sfx.play("confirm", -8.0)


# ------------------------------------------------------------------ values
## Show the saved values (on open, and after DEFAULTS).
func sync() -> void:
	for key in _controls:
		var c: Control = _controls[key]
		var val: Variant = Settings.get_value(key)
		if c is OptionButton:
			var ob := c as OptionButton
			for i in ob.item_count:
				if str(ob.get_item_metadata(i)) == str(val):
					ob.select(i)
		elif c is CheckButton:
			(c as CheckButton).set_pressed_no_signal(bool(val))
		elif c is HSlider:
			(c as HSlider).set_value_no_signal(float(val))
			var lbl: Label = c.get_meta("value_label")
			var fmt: Callable = c.get_meta("fmt")
			lbl.text = fmt.call(float(val))
	if _tab == "CONTROLS":
		_fill_bindings()


## DEFAULTS is irreversible: ask first [V2 10080].
func _ask_reset() -> void:
	UiKit.confirm(get_parent() as Control, "Reset every setting?", "Graphics, display, HUD, alert, control and sound settings go back to their defaults. Key bindings, inhibited alerts and your missions are kept.", "RESET SETTINGS", _reset, true)


func _reset() -> void:
	for key in Settings.DEFAULTS:
		if key != "first_run_done" and key != "cw_inhibited":
			Settings.set_value(key, Settings.DEFAULTS[key])
	sync()


func _row(parent: Control, text: String, tip := "") -> HBoxContainer:
	var h := UiKit.hbox(10)
	var l := UiKit.label(text, 13, UiKit.TEXT)
	l.custom_minimum_size = Vector2(250, 0)
	l.tooltip_text = tip
	l.mouse_filter = Control.MOUSE_FILTER_PASS if tip != "" else Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	parent.add_child(h)
	return h


func _option(parent: Control, key: String, text: String, items: Array, tip := "") -> void:
	var h := _row(parent, text, tip)
	var ob := OptionButton.new()
	ob.focus_mode = Control.FOCUS_NONE
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.tooltip_text = tip
	for i in items.size():
		ob.add_item(str(items[i][1]), i)
		ob.set_item_metadata(i, items[i][0])
	ob.item_selected.connect(func(i: int):
		var raw: Variant = ob.get_item_metadata(i)
		Settings.set_value(key, raw)
		Sfx.play("click", -8.0))
	h.add_child(ob)
	_controls[key] = ob


func _check(parent: Control, key: String, text: String) -> void:
	var c := UiKit.check(text, bool(Settings.get_value(key)), func(on: bool): Settings.set_value(key, on))
	parent.add_child(c)
	_controls[key] = c


func _slider(parent: Control, key: String, text: String, lo: float, hi: float, step: float, fmt: Callable) -> void:
	var h := _row(parent, text)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.scrollable = false
	s.focus_mode = Control.FOCUS_NONE
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var val := UiKit.label("", 13, UiKit.DIM, 500, true)
	val.custom_minimum_size = Vector2(64, 0)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	s.set_meta("value_label", val)
	s.set_meta("fmt", fmt)
	s.value_changed.connect(func(x: float):
		val.text = fmt.call(x)
		Settings.set_value(key, x))
	h.add_child(s)
	h.add_child(val)
	_controls[key] = s
