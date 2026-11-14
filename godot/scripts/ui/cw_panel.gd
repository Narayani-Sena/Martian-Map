class_name CwPanel
extends PanelContainer
## Caution & warning list (F3, or click the master alarm): the active alerts with ACK, SHELVE and INHIBIT,
## the event log, and the catalogue of every alert, what it watches and whether it is in service.
## NASA-STD-3001 Vol 2 [V2 10154-10156] (enable, inhibit, audit), [V2 10177] (suppress), [V2 10117] (test).

var _tab := "ACTIVE"
var _box: VBoxContainer
var _scroll: ScrollContainer
var _tab_btns := {}
var _status: Label


func _init() -> void:
	material = UiKit.glass_material(3.0)
	add_theme_stylebox_override("panel", UiKit.box(UiKit.PANEL_SOLID, Color(UiKit.ACCENT, 0.5), 12, 1, 18))
	custom_minimum_size = Vector2(760, 0)
	visible = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	var v := UiKit.vbox(10)
	add_child(v)
	var head := UiKit.hbox(8)
	var tv := UiKit.vbox(0)
	tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tv.add_child(UiKit.label("Caution & Warning", 20, UiKit.TEXT, 700))
	tv.add_child(UiKit.label("NASA-STD-3001 alert classes: emergency (flashing red) · warning (red) · caution (yellow) · advisory (blue)", 11, UiKit.DIM))
	head.add_child(tv)
	head.add_child(UiKit.button("✕", func(): close(), "Close  [F3 / Esc]"))
	v.add_child(head)
	var tabs := UiKit.hbox(6)
	var group := ButtonGroup.new()
	for t in ["ACTIVE", "LOG", "CATALOGUE"]:
		var name: String = t
		var b := UiKit.button(name, func():
			_tab = name
			_rebuild(), "", true)
		b.button_group = group
		b.button_pressed = name == _tab
		tabs.add_child(b)
		_tab_btns[name] = b
	_status = UiKit.label("", 12, UiKit.DIM)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tabs.add_child(_status)
	v.add_child(tabs)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, 400)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(_scroll)
	_box = UiKit.vbox(8)
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_box)
	v.add_child(UiKit.hline())
	var acts := UiKit.hbox(8)
	acts.add_child(UiKit.button("ACKNOWLEDGE ALL", func(): CW.acknowledge_all(), "Acknowledge every active alert  [Shift+Enter]"))
	acts.add_child(UiKit.button("SILENCE", func(): CW.silence(), "Stop the tones; alerts stay listed until acknowledged  [Backspace]"))
	acts.add_child(UiKit.button("TEST ALARMS", func():
		close()
		CW.test_annunciators(), "Annunciator test: each class's banner, colour, tone and voice in turn"))
	acts.add_child(UiKit.button("SAVE LOG", _save_log, "Write the alert log as CSV into the user folder and open the folder"))
	var sp := UiKit.spacer(0, true)
	acts.add_child(sp)
	acts.add_child(UiKit.button("CLOSE", func(): close(), "[F3 / Esc]"))
	v.add_child(acts)
	CW.changed.connect(func():
		if visible and _tab != "LOG":
			_rebuild())
	CW.logged.connect(func(_e: Dictionary):
		if visible and _tab == "LOG":
			_rebuild())


func toggle(host_size: Vector2, tab := "") -> void:
	if visible and tab == "":
		close()
		return
	if tab != "":
		_tab = tab
		(_tab_btns[tab] as Button).set_pressed_no_signal(true)
	_rebuild()
	visible = true
	reset_size()
	position = (host_size - size) * 0.5
	UiKit.appear(self, 0.0, 0.2)
	Sfx.play("toggle", -6.0)


func close() -> void:
	if visible:
		visible = false
		Sfx.play("toggle", -8.0)


func _rebuild() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()
	var m := CW.master()
	var inh := CW.inhibited()
	_status.text = "%d active · %d unacknowledged · %d inhibited" % [int(m["total"]), int(m["n"]), inh.size()]
	match _tab:
		"ACTIVE":
			_active()
		"LOG":
			_log()
		_:
			_catalogue()


func _active() -> void:
	var list := CW.active()
	if list.is_empty():
		_box.add_child(UiKit.label("All clear: no active alerts.", 15, UiKit.GOOD, 600))
		_box.add_child(UiKit.wrap("Alerts appear here while their condition holds and stay until acknowledged. Advisories (blue) end by themselves.", 12, UiKit.DIM))
	for a in list:
		var row := PanelContainer.new()
		var col := UiKit.level_col(str(a["level"]))
		row.add_theme_stylebox_override("panel", UiKit.box(Color(col, 0.08), Color(col, 0.5 if not bool(a["acked"]) else 0.2), 8, 1, 10))
		var h := UiKit.hbox(10)
		row.add_child(h)
		var chip := UiKit.chip(str(a["level"]), col, not bool(a["acked"]))
		chip.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		h.add_child(chip)
		var tv := UiKit.vbox(2)
		tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		tv.add_child(UiKit.label(str(a["title"]), 14, UiKit.TEXT, 700))
		tv.add_child(UiKit.wrap(str(a["text"]), 12, UiKit.TEXT))
		var states := []
		states.append("event" if bool(a.get("event", false)) else ("cleared" if bool(a["cleared"]) else "active"))
		states.append("acknowledged" if bool(a["acked"]) else "NOT ACKNOWLEDGED")
		if bool(a["silenced"]) and not bool(a["acked"]):
			states.append("silenced")
		if bool(a["shelved"]):
			states.append("shelved")
		tv.add_child(UiKit.label("raised at EVA %s · %s" % [str(a["eva"]), " · ".join(PackedStringArray(states))], 11, UiKit.DIM))
		h.add_child(tv)
		var bv := UiKit.vbox(4)
		var id := str(a["id"])
		if not bool(a["acked"]):
			bv.add_child(UiKit.button("ACK", func(): CW.acknowledge(id), "Acknowledge"))
		if CW.is_shelved(id):
			bv.add_child(UiKit.button("UNSHELVE", func(): CW.unshelve(id), "Annunciate it again"))
		elif not id.begins_with("test_"):
			bv.add_child(UiKit.button("SHELVE 10 MIN", func(): CW.shelve(id, 10.0), "Suppress for 10 minutes: still listed and logged, no banner or tone"))
		h.add_child(bv)
		_box.add_child(row)


func _log() -> void:
	var entries := CW.log_entries
	if entries.is_empty():
		_box.add_child(UiKit.label("The log is empty.", 13, UiKit.DIM))
		return
	for i in range(entries.size() - 1, maxi(-1, entries.size() - 201), -1):
		var e: Dictionary = entries[i]
		var h := UiKit.hbox(10)
		h.add_child(UiKit.label(str(e["clock"]), 12, UiKit.DIM, 500, true))
		h.add_child(UiKit.label(str(e["eva"]), 12, UiKit.DIM, 500, true))
		var lv := str(e["level"])
		var what := UiKit.label(str(e["what"]), 12, UiKit.level_col(lv) if lv != "" else UiKit.TEXT, 600)
		what.custom_minimum_size.x = 170
		h.add_child(what)
		var t := UiKit.wrap("%s%s" % [str(e["title"]), (" — " + str(e["text"])) if str(e["text"]) != "" else ""], 12, UiKit.TEXT)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(t)
		_box.add_child(h)


func _catalogue() -> void:
	_box.add_child(UiKit.wrap("Every alert the console watches for. Untick IN SERVICE to inhibit one (it is then neither checked nor logged, and the console reminds you of it every 5 minutes); tick it to enable it again.", 12, UiKit.DIM))
	var groups := {}
	for id in CW.CATALOG:
		if str(id).begins_with("test_"):
			continue
		var g := str(CW.CATALOG[id]["group"])
		if not groups.has(g):
			groups[g] = []
		(groups[g] as Array).append(str(id))
	for g in ["Suit", "Consumables", "Crew", "Environment", "Comms", "Navigation", "Mission"]:
		if not groups.has(g):
			continue
		_box.add_child(UiKit.caps(g, UiKit.ACCENT, 11))
		for id in groups[g]:
			var c: Dictionary = CW.CATALOG[id]
			var h := UiKit.hbox(10)
			var chip := UiKit.chip(str(c["level"]), UiKit.level_col(str(c["level"])))
			chip.custom_minimum_size.x = 92
			chip.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			h.add_child(chip)
			var tv := UiKit.vbox(1)
			tv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tv.add_child(UiKit.label(str(c["title"]), 13, UiKit.TEXT, 600))
			tv.add_child(UiKit.wrap(str(c["watch"]), 11, UiKit.DIM))
			h.add_child(tv)
			var aid: String = id
			var chk := UiKit.check("IN SERVICE", not CW.is_inhibited(aid), func(on: bool): CW.set_inhibited(aid, not on))
			chk.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
			h.add_child(chk)
			_box.add_child(h)


func _save_log() -> void:
	var path := CW.export_log()
	if path != "":
		OS.shell_show_in_file_manager(path)
