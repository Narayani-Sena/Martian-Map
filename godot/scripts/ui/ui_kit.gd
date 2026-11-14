class_name UiKit
extends RefCounted
## Shared look & feel: palette, fonts (Windows system fonts — no font files shipped),
## the frosted-glass panel material, the Theme, and small animation helpers.

const ACCENT := Color("4fd1ff")
const MARS := Color("ff7a3d")
const TEXT := Color("e8eef4")
const DIM := Color("93a3b3")
const FAINT := Color("5d6d7c")
const PANEL := Color(0.028, 0.042, 0.058, 0.58)
const PANEL_SOLID := Color(0.022, 0.032, 0.046, 0.95)
const LINE := Color(0.31, 0.82, 1.0, 0.22)
const HAZARD_NAMES := ["EASY", "MODERATE", "DIFFICULT", "HAZARDOUS", "NO-GO"]
const COMMS_NAMES := ["NO LINK", "MARGINAL", "CLEAR"]

# Status colours: switchable palette (Settings "palette"). NASA-STD-3001 Table 10.4-3 / 10.3-1 meanings:
# red = warning / failed (flashing red = emergency), yellow = caution / off-nominal, green = good / on,
# blue = advisory. "cvd" is a colour-blind-safe set after Okabe and Ito; meaning is also always carried by
# text or shape [V2 10045], so no status depends on telling two colours apart.
const PALETTES := {
	"standard": {"GOOD": "3ddc84", "AMBER": "ffb03b", "BAD": "ff4d5e", "CAUTION": "ffd84a", "ADVISORY": "5aa0ff",
		"VIOLET": "b48cff", "HAZARD": ["3ddc84", "b7e35b", "ffd166", "ff8a3d", "ff4d5e"]},
	"cvd": {"GOOD": "33c1a1", "AMBER": "e69f00", "BAD": "f0642a", "CAUTION": "f0e442", "ADVISORY": "56b4e9",
		"VIOLET": "cc79a7", "HAZARD": ["33c1a1", "a6d8c4", "f0e442", "e69f00", "f0642a"]},
}
static var palette_name := "standard"
static var GOOD := Color("3ddc84")
static var AMBER := Color("ffb03b")
static var BAD := Color("ff4d5e")
static var CAUTION := Color("ffd84a")
static var ADVISORY := Color("5aa0ff")
static var VIOLET := Color("b48cff")
static var HAZARD: Array = [Color("3ddc84"), Color("b7e35b"), Color("ffd166"), Color("ff8a3d"), Color("ff4d5e")]
## Smallest text (design px). 11 keeps 9-10 px captions readable on a 1366x768 laptop; Settings "min_text"
## raises it (16 = NASA's 12 pt label minimum [V2 10066] at 96 dpi).
static var MIN_FONT := 11
static var glove := false             # glove mode: bigger buttons and grabbers (Settings "glove_mode")
static var reduce_flashing := false   # steady instead of flashing alarms and glitches (Settings)

static var _fonts := {}
static var _glass: Shader
static var _glass_lite: Shader
static var _glass_mats: Array = []   # weak refs to every panel material, so the look can be switched live
static var glass_blur := true         # false: plain see-through panels (no screen copy + blur each frame)
static var _icons := {}


static func font(weight := 400) -> Font:
	var key := "ui%d" % weight
	if not _fonts.has(key):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Bahnschrift", "Segoe UI", "Roboto", "Noto Sans", "Arial"])
		f.font_weight = weight
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		f.hinting = TextServer.HINTING_LIGHT
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_AUTO
		_fonts[key] = f
	return _fonts[key]


static func mono(weight := 500) -> Font:
	var key := "mono%d" % weight
	if not _fonts.has(key):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Cascadia Mono", "Consolas", "DejaVu Sans Mono", "Courier New"])
		f.font_weight = weight
		f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
		_fonts[key] = f
	return _fonts[key]


static func caps_font() -> Font:
	if not _fonts.has("caps"):
		var v := FontVariation.new()
		v.base_font = font(600)
		v.spacing_glyph = 1
		_fonts["caps"] = v
	return _fonts["caps"]


static func symbols() -> Font:
	if not _fonts.has("sym"):
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Segoe UI Symbol", "Segoe UI Emoji", "Noto Sans Symbols 2", "DejaVu Sans"])
		_fonts["sym"] = f
	return _fonts["sym"]


static func box(bg: Color, border := Color(0, 0, 0, 0), radius := 8, border_w := 1, pad := 8.0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(border_w if border.a > 0.0 else 0)
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad
	s.content_margin_right = pad
	s.content_margin_top = pad * 0.7
	s.content_margin_bottom = pad * 0.7
	s.anti_aliasing = true
	s.corner_detail = 6
	return s


static func circle_icon(d: int, c: Color, ring := false) -> ImageTexture:
	var key := "%d_%s_%s" % [d, c.to_html(), ring]
	if _icons.has(key):
		return _icons[key]
	var img := Image.create_empty(d, d, false, Image.FORMAT_RGBA8)
	var r := d * 0.5
	for y in d:
		for x in d:
			var dist := Vector2(x + 0.5 - r, y + 0.5 - r).length()
			var a := clampf(r - dist, 0.0, 1.0)
			if ring:
				a = minf(a, clampf(dist - (r - 3.0), 0.0, 1.0))
			img.set_pixel(x, y, Color(c, c.a * a))
	var t := ImageTexture.create_from_image(img)
	_icons[key] = t
	return t


## Switch the status palette ("standard" or "cvd"). Widgets read the colours when they draw or update.
static func set_palette(name: String) -> void:
	var p: Dictionary = PALETTES.get(name, PALETTES["standard"])
	palette_name = name if PALETTES.has(name) else "standard"
	GOOD = Color(str(p["GOOD"]))
	AMBER = Color(str(p["AMBER"]))
	BAD = Color(str(p["BAD"]))
	CAUTION = Color(str(p["CAUTION"]))
	ADVISORY = Color(str(p["ADVISORY"]))
	VIOLET = Color(str(p["VIOLET"]))
	HAZARD = []
	for h in p["HAZARD"]:
		HAZARD.append(Color(str(h)))


## Colour of an alert class (NASA-STD-3001 Table 10.3-1).
static func level_col(level: String) -> Color:
	match level:
		"emergency", "warning":
			return BAD
		"caution":
			return CAUTION
		"advisory":
			return ADVISORY
	return ACCENT


## Raise the text floor and re-apply it to every label under `root` (UiKit.label remembers what each asked for).
static func set_min_font(px: int, root: Node) -> void:
	MIN_FONT = px
	if root == null:
		return
	for n in root.find_children("*", "Label", true, false):
		var l := n as Label
		if l.has_meta("req_fs"):
			l.add_theme_font_size_override("font_size", maxi(int(l.get_meta("req_fs")), MIN_FONT))


static func theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(400)
	t.default_font_size = 14
	t.set_color("font_color", "Label", TEXT)
	var pad := 16.0 if glove else 10.0   # glove mode: taller buttons (about 48 px) that a gloved finger can hit
	var normal := box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.1), 7, 1, pad)
	t.set_stylebox("normal", "Button", normal)
	t.set_stylebox("hover", "Button", box(Color(ACCENT, 0.16), Color(ACCENT, 0.65), 7, 1, pad))
	t.set_stylebox("pressed", "Button", box(Color(ACCENT, 0.3), ACCENT, 7, 1, pad))
	t.set_stylebox("hover_pressed", "Button", box(Color(ACCENT, 0.36), ACCENT, 7, 1, pad))
	t.set_stylebox("disabled", "Button", box(Color(1, 1, 1, 0.02), Color(1, 1, 1, 0.05), 7, 1, pad))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", TEXT)
	t.set_color("font_hover_color", "Button", Color.WHITE)
	t.set_color("font_pressed_color", "Button", Color.WHITE)
	t.set_color("font_hover_pressed_color", "Button", Color.WHITE)
	t.set_color("font_focus_color", "Button", TEXT)
	t.set_color("font_disabled_color", "Button", FAINT)
	t.set_font("font", "Button", font(600))
	t.set_font_size("font_size", "Button", 13)
	t.set_stylebox("panel", "PanelContainer", box(PANEL, LINE, 12, 1, 12))
	t.set_stylebox("panel", "TooltipPanel", box(PANEL_SOLID, Color(ACCENT, 0.5), 6, 1, 8))
	t.set_color("font_color", "TooltipLabel", TEXT)
	t.set_font_size("font_size", "TooltipLabel", 13)
	var track := box(Color(1, 1, 1, 0.09), Color(0, 0, 0, 0), 3, 0, 0)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", box(Color(ACCENT, 0.6), Color(0, 0, 0, 0), 3, 0, 0))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(ACCENT, Color(0, 0, 0, 0), 3, 0, 0))
	t.set_icon("grabber", "HSlider", circle_icon(24 if glove else 14, Color.WHITE))
	t.set_icon("grabber_highlight", "HSlider", circle_icon(26 if glove else 16, ACCENT))
	for sb in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", sb, box(Color(1, 1, 1, 0.02), Color(0, 0, 0, 0), 3, 0, 0))
		t.set_stylebox("grabber", sb, box(Color(1, 1, 1, 0.14), Color(0, 0, 0, 0), 3, 0, 0))
		t.set_stylebox("grabber_highlight", sb, box(Color(ACCENT, 0.5), Color(0, 0, 0, 0), 3, 0, 0))
		t.set_stylebox("grabber_pressed", sb, box(ACCENT, Color(0, 0, 0, 0), 3, 0, 0))
	t.set_stylebox("normal", "LineEdit", box(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.12), 6, 1, 8))
	t.set_stylebox("focus", "LineEdit", box(Color(1, 1, 1, 0.07), ACCENT, 6, 1, 8))
	t.set_color("font_color", "LineEdit", TEXT)
	for c in ["CheckBox", "CheckButton"]:
		t.set_color("font_color", c, TEXT)
		t.set_color("font_hover_color", c, Color.WHITE)
		t.set_color("font_pressed_color", c, TEXT)
		t.set_color("font_hover_pressed_color", c, Color.WHITE)
		t.set_color("font_focus_color", c, TEXT)
		for st in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
			t.set_stylebox(st, c, box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 6, 0, 4))
		t.set_font_size("font_size", c, 13)
	return t


# ------------------------------------------------------------------ builders
static func label(text: String, size := 14, color := TEXT, weight := 400, is_mono := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", mono(weight) if is_mono else font(weight))
	l.add_theme_font_size_override("font_size", maxi(size, MIN_FONT))
	l.set_meta("req_fs", size)   # so set_min_font() can re-floor it later
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Interface size: Godot fits the 1600x900 design to the window (canvas_items stretch); on a small
## screen that shrinks text a lot (x0.83 at 1366x768). "auto" adds just enough to stay at >= x0.95 of
## the design; the other choices multiply the fitted size.
static func apply_ui_scale(win: Window, choice: String) -> void:
	var fit := minf(win.size.x / 1600.0, win.size.y / 900.0)
	var f := 1.0
	if choice == "auto" or not choice.is_valid_float():
		f = clampf(0.95 / fit, 1.0, 1.25) if fit > 0.0 and fit < 0.95 else 1.0
	else:
		f = clampf(choice.to_float(), 0.75, 1.5)
	win.content_scale_factor = f


static func caps(text: String, color := DIM, size := 11) -> Label:
	var l := label(text.to_upper(), size, color, 600)
	l.add_theme_font_override("font", caps_font())
	return l


static func wrap(text: String, size := 13, color := DIM) -> Label:
	var l := label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = 60
	return l


static func vbox(sep := 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func hbox(sep := 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func grid(cols: int, hsep := 6, vsep := 6) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", hsep)
	g.add_theme_constant_override("v_separation", vsep)
	return g


static func spacer(h := 6.0, expand := false) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	return c


static func hline(alpha := 0.1) -> ColorRect:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, alpha)
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func glass_material(blur := 3.0) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _glass_shader()
	m.set_shader_parameter("blur", blur)
	_glass_mats.append(weakref(m))
	if _glass_mats.size() > 64:   # toasts come and go: forget the freed ones now and then
		_glass_mats = _glass_mats.filter(func(w: WeakRef) -> bool: return w.get_ref() != null)
	return m


static func _glass_shader() -> Shader:
	if _glass == null:
		_glass = load("res://shaders/glass.gdshader")
		_glass_lite = load("res://shaders/glass_lite.gdshader")
	return _glass if glass_blur else _glass_lite


## Frosted (blurred) or plain panels, for every panel already on screen and those still to come.
static func set_glass_blur(on: bool) -> void:
	glass_blur = on
	var sh := _glass_shader()
	for w in _glass_mats:
		var m: ShaderMaterial = (w as WeakRef).get_ref()
		if m:
			m.shader = sh


static func glass(radius := 12, tint := PANEL, border := LINE, pad := 12.0) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(tint, border, radius, 1, pad))
	p.material = glass_material()
	return p


static func chip(text: String, color: Color, solid := false) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := box(Color(color, 0.85) if solid else Color(color, 0.14), Color(color, 0.6), 5, 1, 6)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	var l := caps(text, Color(0.02, 0.03, 0.04) if solid else color, 10)
	l.name = "Text"
	p.add_child(l)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


static func set_chip(p: PanelContainer, text: String, color: Color, solid := false) -> void:
	var sb := box(Color(color, 0.85) if solid else Color(color, 0.14), Color(color, 0.6), 5, 1, 6)
	sb.content_margin_top = 1
	sb.content_margin_bottom = 1
	p.add_theme_stylebox_override("panel", sb)
	var l := p.get_node("Text") as Label
	l.text = text.to_upper()
	l.add_theme_color_override("font_color", Color(0.02, 0.03, 0.04) if solid else color)


static func button(text: String, cb: Callable = Callable(), tip := "", toggle := false) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_NONE
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	if glove:
		b.custom_minimum_size.y = 46.0
	if cb.is_valid():
		b.pressed.connect(cb)
	b.mouse_entered.connect(func(): Sfx.play("hover", -12.0))
	b.pressed.connect(func():
		Sfx.play("click", -6.0)
		press_fx(b))
	return b


static func check(text: String, on: bool, cb: Callable) -> CheckButton:
	var c := CheckButton.new()
	c.text = text
	c.button_pressed = on
	c.focus_mode = Control.FOCUS_NONE
	c.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	c.toggled.connect(func(v: bool):
		Sfx.play("toggle", -6.0)
		cb.call(v))
	return c


# ------------------------------------------------------------------ animation helpers
static func press_fx(c: Control) -> void:
	c.pivot_offset = c.size * 0.5
	var tw := c.create_tween()
	tw.tween_property(c, "scale", Vector2(0.93, 0.93), 0.06)
	tw.tween_property(c, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


static func appear(c: CanvasItem, delay := 0.0, dur := 0.5) -> void:
	c.modulate.a = 0.0
	var tw := c.create_tween()
	tw.tween_interval(delay)
	tw.tween_property(c, "modulate:a", 1.0, dur).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## Slide a free-floating Control in from `from_offset` with a fade.
static func slide_in(c: Control, from_offset: Vector2, delay := 0.0, dur := 0.7) -> void:
	var end := c.position
	c.position = end + from_offset
	c.modulate.a = 0.0
	var tw := c.create_tween().set_parallel(true)
	tw.tween_property(c, "position", end, dur).set_delay(delay).set_trans(Tween.TRANS_EXPO).set_ease(Tween.EASE_OUT)
	tw.tween_property(c, "modulate:a", 1.0, dur * 0.6).set_delay(delay)


static func flash(c: CanvasItem, color := Color(1.6, 1.6, 1.6)) -> void:
	var tw := c.create_tween()
	tw.tween_property(c, "modulate", color, 0.08)
	tw.tween_property(c, "modulate", Color.WHITE, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


static func level_color(frac: float, warn := 0.3, bad := 0.15) -> Color:
	if frac <= bad:
		return BAD
	if frac <= warn:
		return AMBER
	return GOOD


static func fmt_min(m: float) -> String:
	return MarsTime.dur(m * 60.0)


## "42 s", "3 min", "2 h 05 min": how old a piece of data is.
static func fmt_age(s: float) -> String:
	if s < 90.0:
		return "%d s" % int(s)
	if s < 5400.0:
		return "%d min" % int(s / 60.0)
	return "%d h %02d min" % [int(s / 3600.0), int(fmod(s, 3600.0) / 60.0)]


## Standard stale-data look (NASA-STD-3001 [V2 10020]): the value greyed out with a STALE tag and its age.
## Every panel uses this one style, so stale data always looks the same.
static func mark_stale(l: Label, value: String, age_s: float) -> void:
	l.text = "%s  ◌ STALE %s" % [value, fmt_age(age_s)]
	l.add_theme_color_override("font_color", FAINT)


## A modal question with a dimmed backdrop: confirm before critical, irreversible or destructive commands
## (NASA-STD-3001 [V2 10080]). `cb` runs only on OK; Esc, the backdrop or CANCEL close it.
static func confirm(parent: Control, title: String, text: String, ok_text: String, cb: Callable, danger := false) -> Control:
	var back := ColorRect.new()
	back.color = Color(0, 0, 0, 0.55)
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_STOP
	back.name = "Confirm"
	parent.add_child(back)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", box(PANEL_SOLID, Color(BAD if danger else ACCENT, 0.7), 12, 1, 20))
	p.custom_minimum_size = Vector2(460, 0)
	back.add_child(p)
	var v := vbox(12)
	p.add_child(v)
	v.add_child(label(title, 18, TEXT, 700))
	var w := UiKit.wrap(text, 13, TEXT)
	w.custom_minimum_size.x = 420
	v.add_child(w)
	var h := hbox(10)
	h.alignment = BoxContainer.ALIGNMENT_END
	var close := func():
		if is_instance_valid(back):
			back.queue_free()
	var cancel := button("CANCEL", close)
	var ok := button(ok_text, func():
		close.call()
		cb.call())
	if danger:
		ok.add_theme_stylebox_override("normal", box(Color(BAD, 0.25), BAD, 7, 1, 10))
	h.add_child(cancel)
	h.add_child(ok)
	v.add_child(h)
	back.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed and not p.get_global_rect().has_point((ev as InputEventMouseButton).global_position):
			close.call())
	var place := func():
		if is_instance_valid(p):
			p.reset_size()
			p.position = (parent.size - p.size) * 0.5
	place.call_deferred()
	back.set_meta("ok", ok)
	back.set_meta("cancel", cancel)
	Sfx.play("toggle", -6.0)
	return back
