class_name LiveLink
extends Node
## Habitat and suit, live (feature D1): the helmet's half. Twice a second the console sends EV1's state (position,
## heading, suit, alerts, margin) to the mission server's relay at /ws/live/<site> as the "helmet"; a crew member
## inside the habitat follows it on the web planner (Earth link → Habitat console) and can push a waypoint or a
## message into the visor. Earth is 3 to 22 light-minutes away, too far to direct an EVA, so the habitat does.
## Reconnects by itself (2, 5, 10, then every 30 s) whenever the server is reachable.

const SEND_EVERY := 0.5
const RETRY_S := [2.0, 5.0, 10.0, 30.0]
const WP_COLOR := Color(0.35, 1.0, 0.6)

var app                          # main.gd: telemetry, alerts, monitor, world
var connected := false
var waypoint := {}               # {lon, lat, name, xy}: pushed by the habitat
var last_message := ""
var received := 0                # commands from the habitat (for checks)
var sent := 0                    # telemetry messages sent
var _ws := WebSocketPeer.new()
var _state := WebSocketPeer.STATE_CLOSED
var _site := ""
var _acc := 0.0
var _retry_at := 0.0
var _fails := 0
var _beacon: Node3D
var _beacon_label: Label3D


func setup(app_node) -> void:
	app = app_node
	Mission.site_loaded.connect(func():
		_clear_waypoint()
		if _state == WebSocketPeer.STATE_OPEN:
			_ws.close())


func _url() -> String:
	var b := str(Api.base_url)
	return "%s/ws/live/%s" % [b.replace("https://", "wss://").replace("http://", "ws://"), Mission.site_id]


func _process(delta: float) -> void:
	if not Api.online or not Mission.has_plan():
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st != _state:
		_state = st
		if st == WebSocketPeer.STATE_OPEN:
			connected = true
			_fails = 0
			_site = Mission.site_id
			_ws.send_text(JSON.stringify({"type": "hello", "role": "helmet"}))
		elif st == WebSocketPeer.STATE_CLOSED:
			connected = false
			_retry_at = Time.get_ticks_msec() / 1000.0 + float(RETRY_S[mini(_fails, RETRY_S.size() - 1)])
			_fails += 1
	if st == WebSocketPeer.STATE_CLOSED:
		if Time.get_ticks_msec() / 1000.0 >= _retry_at:
			_ws = WebSocketPeer.new()
			if _ws.connect_to_url(_url()) != OK:
				_retry_at = Time.get_ticks_msec() / 1000.0 + 30.0
			_state = _ws.get_ready_state()
		return
	if st != WebSocketPeer.STATE_OPEN:
		return
	while _ws.get_available_packet_count() > 0:
		var msg: Variant = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if msg is Dictionary:
			_on_message(msg)
	if _site != Mission.site_id:   # a new site: a new relay
		_ws.close()
		return
	_acc += delta
	if _acc >= SEND_EVERY:
		_acc = 0.0
		_send_telemetry()


func _send_telemetry() -> void:
	var d: Dictionary = app.tel.d
	if d.is_empty() or not bool(d.get("has", false)):
		return
	var xy: Vector2 = d.get("xy", Vector2.ZERO)
	var ll := Mission.grid.to_lonlat(xy.x, xy.y)
	var walk := bool(d.get("walk", false))
	var wk: Walker = app.world.walker
	var al: Array = []
	for a in CW.active():
		al.append(str(a.get("title", a.get("id", ""))))
		if al.size() >= 6:
			break
	var msg := {"type": "telemetry", "source": "helmet", "lon": ll.x, "lat": ll.y, "eva_t": float(d.get("t", 0.0)),
		"mode": str(d.get("mode", "")) if walk else "ORBIT", "speed": wk.speed_now if walk else 0.0,
		"hr_bpm": float(d.get("hr", 0.0)), "met_w": float(d.get("met_w", 0.0)), "suit_kpa": float(d.get("p_suit", 0.0)),
		"ppco2_mmhg": float(d.get("ppco2", 0.0)), "phase": str(d.get("phase", "")), "drill": str(d.get("fault", "")),
		"autopilot": wk.autopilot, "playing": Mission.playing, "alerts": al}
	if walk:
		msg["heading"] = fposmod(rad_to_deg(wk.yaw), 360.0)
	for k in ["o2_pct", "battery_pct", "water_pct", "dose_usv", "margin_min"]:
		var v := float(d.get(k, NAN))
		if is_finite(v):
			msg[k] = v
	var co2 := float(d.get("scrubber_pct", NAN))
	if is_finite(co2):
		msg["co2_pct"] = co2
	var wb := float(d.get("walkback_s", -2.0))
	if wb >= 0.0 and is_finite(wb):
		msg["walkback_min"] = wb / 60.0
	var ev: Variant = d.get("event", {})
	if ev is Dictionary and (ev as Dictionary).has("name"):
		msg["next_wp"] = str(ev["name"])
	_ws.send_text(JSON.stringify(msg))
	sent += 1


func _on_message(msg: Dictionary) -> void:
	match str(msg.get("type", "")):
		"waypoint":
			received += 1
			_set_waypoint(float(msg.get("lon", 0.0)), float(msg.get("lat", 0.0)), str(msg.get("name", "Habitat waypoint")))
		"message":
			received += 1
			last_message = str(msg.get("text", ""))
			Sfx.play("alert", -8.0)
			app.alerts.toast("HABITAT: " + last_message, "info")
		"clear_waypoint":
			received += 1
			_clear_waypoint()
			app.alerts.toast("HABITAT: waypoint cleared", "info")


## A waypoint from the habitat: a green beacon in the world, named, and where it is from EV1.
func _set_waypoint(lon: float, lat: float, name: String) -> void:
	var xy := Mission.xy_of(lon, lat)
	waypoint = {"lon": lon, "lat": lat, "name": name, "xy": xy}
	if _beacon == null:
		_beacon = Models.beacon(WP_COLOR, 70.0)
		_beacon.name = "HabitatWaypoint"
		_beacon_label = Label3D.new()
		_beacon_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_beacon_label.fixed_size = true
		_beacon_label.pixel_size = 0.001
		_beacon_label.font_size = 30
		_beacon_label.outline_size = 8
		_beacon_label.modulate = WP_COLOR
		_beacon_label.no_depth_test = true
		_beacon_label.position = Vector3(0.0, 76.0, 0.0)
		_beacon.add_child(_beacon_label)
		app.world.add_child(_beacon)
	_beacon.position = app.world.td.world_at(xy)
	_beacon_label.text = "HABITAT · " + name
	_beacon.visible = true
	var me: Vector2 = app.tel.d.get("xy", xy)
	Sfx.play("confirm", -4.0)
	app.alerts.toast("HABITAT: new waypoint %s, %03d° · %d m" % [name, int(round(Geo.bearing_deg(me, xy))) % 360, int(me.distance_to(xy))], "ok")
	app.world.scan_pulse(xy)


func _clear_waypoint() -> void:
	waypoint = {}
	if _beacon:
		_beacon.visible = false
