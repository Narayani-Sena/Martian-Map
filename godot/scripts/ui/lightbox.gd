class_name Lightbox
extends Control
## Full-screen viewer for a rover photo, with caption; click anywhere or Esc to close.

var _img: TextureRect
var _title: Label
var _caption: Label
var _spinner := 0.0
var _loading := false


func _init() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false


func _ready() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.82)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(dim)
	var v := UiKit.vbox(10)
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.offset_left = 80
	v.offset_right = -80
	v.offset_top = 50
	v.offset_bottom = -40
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	_title = UiKit.label("", 18, UiKit.TEXT, 600)
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_title)
	_img = TextureRect.new()
	_img.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_img.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_img.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_img.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_img)
	_caption = UiKit.wrap("", 13, UiKit.DIM)
	_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(_caption)
	var hint := UiKit.caps("click or esc to close", UiKit.FAINT, 10)
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(hint)


func show_photo(item: Dictionary, thumb: Texture2D) -> void:
	_title.text = "%s · sol %d · %s" % [str(item.get("camera", "")), int(item.get("sol", 0)), str(item.get("date_taken", "")).substr(0, 10)]
	_caption.text = str(item.get("caption", "")) if str(item.get("caption", "")) != "" else str(item.get("title", ""))
	_img.texture = thumb
	visible = true
	modulate.a = 0.0
	create_tween().tween_property(self, "modulate:a", 1.0, 0.25)
	Sfx.play("whoosh", -14.0, 1.4)
	_loading = true
	var url := "/api/image-proxy" + Api.q({"url": item.get("url", ""), "max_px": 1600})
	var tex := await Api.get_texture(url, "", false)
	_loading = false
	if tex and visible:
		_img.texture = tex
		UiKit.flash(_img, Color(1.25, 1.25, 1.25))


func close() -> void:
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, 0.2)
	tw.tween_callback(func(): visible = false)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		close()
		accept_event()


func _process(delta: float) -> void:
	if _loading:
		_spinner += delta
		queue_redraw()


func _draw() -> void:
	if _loading:
		var c := size * 0.5
		draw_arc(c, 22.0, _spinner * 5.0, _spinner * 5.0 + 4.0, 32, UiKit.ACCENT, 3.0, true)
