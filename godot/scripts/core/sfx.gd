extends Node
## Procedurally synthesised interface sounds and suit ambience (autoload "Sfx").
## Nothing is loaded from disk: every blip, alarm and the helmet fan hum is generated at start-up.
##
## Caution and warning tones follow NASA-STD-3001 Vol 2 Table 10.3-1 exactly (cw_emergency, cw_warning,
## cw_caution, cw_advisory). They play on their own "Alerts" bus: the mute key and the interface slider
## never silence them, and their volume slider stops at 30 % (an alarm must stay audible [V2 10056]).

const RATE := 22050
const CACHE_DIR := "user://cache/sfx_v4"   # bump the version whenever the synthesis below changes
const NAMES := ["hover", "click", "toggle", "confirm", "type", "boot", "ready", "alert", "warn", "scan", "whoosh", "step", "wind", "suit", "breath",
	"cw_emergency", "cw_warning", "cw_caution", "cw_advisory"]
const BUS_UI := "UI"              # blips (Settings "vol_ui")
const BUS_AMB := "Ambience"       # wind, suit fan, breathing, footsteps (Settings "vol_ambience")
const BUS_ALERT := "Alerts"       # caution and warning tones (Settings "vol_alerts", never below 30 %)
const ALERT_MIN_VOL := 0.3
## Length of one tone sequence (s), so the caution and warning system knows when to repeat it.
const ALERT_LEN := {"cw_emergency": 2.8, "cw_warning": 5.2, "cw_caution": 1.0, "cw_advisory": 0.318}
const AMBIENT := ["step"]         # one-shot sounds that belong with the ambience
# When all ten voices are busy, a new sound replaces the least important one playing (the oldest of
# those), never an alert; a sound less important than everything playing is dropped instead.
const PRIORITY := {"hover": 0, "type": 0, "step": 1, "click": 2, "toggle": 2, "scan": 2, "whoosh": 2,
	"confirm": 3, "ready": 3, "boot": 3, "warn": 4, "alert": 5}
const HOVER_GAP_MS := 70          # sweeping the mouse down a list: at most one hover blip per 70 ms

var enabled := true               # M mutes the interface and the ambience; alarms keep sounding
var cli_mute := false             # --mute on the command line (tours): nothing plays at all
var master_db := -8.0
var _alert_player: AudioStreamPlayer
var last_alert := {}              # {name, vol_db, msec}: what the alert channel last played (for checks)
var _streams := {}
var _pool: Array[AudioStreamPlayer] = []
var _voice := {}           # player -> [priority, start msec]
var _last_hover := -100000
var _loops := {}
var _pending_loops := {}   # loops asked for before the sounds were ready: started once they are
var _build_task := -1      # WorkerThreadPool task building the sounds (first run only)
var _rng := RandomNumberGenerator.new()


## The sounds used to be synthesised sample by sample on the main thread before the first frame (~0.8 s
## of a blank window). Now they load from user://cache, or on the very first run are built on a worker
## thread while the boot screen runs (a blip asked for before then is simply skipped).
func _ready() -> void:
	_rng.seed = 7
	_ensure_buses()
	for i in 10:
		var p := AudioStreamPlayer.new()
		p.bus = BUS_UI
		add_child(p)
		_pool.append(p)
	var verbose := false
	_alert_player = AudioStreamPlayer.new()
	_alert_player.bus = BUS_ALERT
	add_child(_alert_player)
	for a in OS.get_cmdline_user_args():
		if a == "--mute":
			enabled = false
			cli_mute = true
		elif a.begins_with("--capture="):
			verbose = true
	var t0 := Time.get_ticks_usec()
	var cached := _load_cached()
	if not cached:
		_build_async()
	if verbose:
		print("sfx: %s, %.0f ms on the main thread" % ["loaded from cache" if cached else "building on a worker", (Time.get_ticks_usec() - t0) / 1000.0])


func ready_to_play() -> bool:
	return _streams.size() == NAMES.size()


## Quitting while the first-run build is still going: the worker uses this node, so let it finish first.
func _exit_tree() -> void:
	if _build_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_build_task)
		_build_task = -1


## Buses under Master, so the settings can turn the interface sounds, the ambience and the alarms up or down.
func _ensure_buses() -> void:
	for b in [BUS_UI, BUS_AMB, BUS_ALERT]:
		if AudioServer.get_bus_index(b) < 0:
			var i := AudioServer.bus_count
			AudioServer.add_bus(i)
			AudioServer.set_bus_name(i, b)
			AudioServer.set_bus_send(i, "Master")


## Bus volumes from the settings (0..1 sliders).
func apply_volumes() -> void:
	_ensure_buses()
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_UI), Settings.volume_db(float(Settings.get_value("vol_ui"))))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_AMB), Settings.volume_db(float(Settings.get_value("vol_ambience"))))
	var va := maxf(ALERT_MIN_VOL, float(Settings.get_value("vol_alerts")))
	AudioServer.set_bus_volume_db(AudioServer.get_bus_index(BUS_ALERT), Settings.volume_db(va))


## One caution/warning tone sequence on the Alerts bus (replaces the one playing). Not muted by M.
func play_alert(sound: String, vol_db := 0.0) -> void:
	last_alert = {"name": sound, "vol_db": vol_db, "msec": Time.get_ticks_msec()}
	if cli_mute or not _streams.has(sound):
		return
	_alert_player.stream = _streams[sound]
	_alert_player.volume_db = master_db + 4.0 + vol_db
	_alert_player.play()


func stop_alert() -> void:
	if _alert_player:
		_alert_player.stop()


func alert_playing() -> bool:
	return _alert_player != null and _alert_player.playing


func _load_cached() -> bool:
	if not DirAccess.dir_exists_absolute(CACHE_DIR):
		return false
	var out := {}
	for n in NAMES:
		var p := CACHE_DIR.path_join(str(n) + ".res")
		if not FileAccess.file_exists(p):
			return false
		var s := ResourceLoader.load(p) as AudioStreamWAV
		if s == null:
			return false
		out[n] = s
	_streams = out
	return true


func _build_async() -> void:
	var built := {}
	_build_task = WorkerThreadPool.add_task(func(): _build_into(built))
	while not WorkerThreadPool.is_task_completed(_build_task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(_build_task)
	_build_task = -1
	_streams = built
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))
	for n in built:
		ResourceSaver.save(built[n], CACHE_DIR.path_join(str(n) + ".res"))
	for n in _pending_loops:
		var args: Array = _pending_loops[n]
		loop(str(n), bool(args[0]), float(args[1]), float(args[2]))
	_pending_loops.clear()


func play(sound: String, vol_db := 0.0, pitch := 1.0) -> void:
	if not enabled or not _streams.has(sound):
		return
	var now := Time.get_ticks_msec()
	if sound == "hover":
		if now - _last_hover < HOVER_GAP_MS:
			return
		_last_hover = now
	var prio := int(PRIORITY.get(sound, 2))
	var player := _free_voice(prio)
	if player == null:
		return   # every voice holds something more important
	player.stream = _streams[sound]
	player.bus = BUS_AMB if AMBIENT.has(sound) else BUS_UI
	player.volume_db = master_db + vol_db
	player.pitch_scale = pitch
	player.play()
	_voice[player] = [prio, now]


## An idle voice, else the least important busy one (the oldest of those) if it ranks no higher than prio.
func _free_voice(prio: int) -> AudioStreamPlayer:
	var best: AudioStreamPlayer = null
	var best_p := 1 << 20
	var best_t := 1 << 62
	for p in _pool:
		if not p.playing:
			return p
		var v: Array = _voice.get(p, [0, 0])
		var vp := int(v[0])
		var vt := int(v[1])
		if vp < best_p or (vp == best_p and vt < best_t):
			best = p
			best_p = vp
			best_t = vt
	return best if best_p <= prio else null


## Start/stop a looping ambience ("wind", "suit", "breath"); fades in and out.
func loop(sound: String, on: bool, vol_db := -14.0, pitch := 1.0) -> void:
	if not _streams.has(sound):
		if NAMES.has(sound):
			_pending_loops[sound] = [on, vol_db, pitch]   # still being built: start it when ready
		return
	var p: AudioStreamPlayer = _loops.get(sound)
	if p == null:
		p = AudioStreamPlayer.new()
		p.stream = _streams[sound]
		p.bus = BUS_AMB
		p.volume_db = -60.0
		add_child(p)
		_loops[sound] = p
	p.pitch_scale = pitch
	var tw := create_tween()
	if on and enabled:
		if not p.playing:
			p.play()
		tw.tween_property(p, "volume_db", master_db + vol_db, 1.2)
	else:
		tw.tween_property(p, "volume_db", -60.0, 0.8)
		tw.tween_callback(p.stop)


func set_loop_pitch(sound: String, pitch: float) -> void:
	var p: AudioStreamPlayer = _loops.get(sound)
	if p:
		p.pitch_scale = pitch


func set_enabled(on: bool) -> void:
	enabled = on
	if not on:
		for k in _loops:
			(_loops[k] as AudioStreamPlayer).stop()


# ------------------------------------------------------------------ synthesis
func _wav(s: PackedFloat32Array, looped := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(s.size() * 2)
	for i in s.size():
		data.encode_s16(i * 2, int(clampf(s[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if looped:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = s.size()
	return w


## Tone sweep from f0 to f1 with an attack/decay envelope; `harm` adds a soft octave.
func _sweep(f0: float, f1: float, dur: float, amp := 0.5, decay := 6.0, harm := 0.25) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var u := t / dur
		var f := lerpf(f0, f1, u)
		ph += TAU * f / RATE
		var env := minf(1.0, t / 0.004) * exp(-decay * u)
		s[i] = amp * env * (sin(ph) + harm * sin(2.0 * ph))
	return s


func _concat(parts: Array) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for p in parts:
		out.append_array(p)
	return out


func _silence(dur: float) -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(int(dur * RATE))
	return s


func _noise_burst(dur: float, amp: float, lp := 0.3, decay := 30.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var y := 0.0
	for i in n:
		y += lp * (_rng.randf_range(-1.0, 1.0) - y)
		s[i] = amp * y * exp(-decay * float(i) / n)
	return s


## Brown-ish noise loop with a slow gust envelope. The gusts repeat exactly over the loop; the noise is
## made seamless by cross-fading its extra tail into the start (it used to fade to silence every 8 s).
func _wind(dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var xf := int(0.5 * RATE)
	var s := PackedFloat32Array()
	s.resize(n + xf)
	var y := 0.0
	var y2 := 0.0
	for i in n + xf:
		y += 0.02 * (_rng.randf_range(-1.0, 1.0) - y)
		y2 += 0.08 * (y - y2)
		var u := float(i % n) / n
		var gust := 0.55 + 0.3 * sin(TAU * u * 2.0) + 0.15 * sin(TAU * u * 5.0 + 1.3)
		s[i] = y2 * 9.0 * gust
	return _loop_seam(s, n, xf, true)


func _suit_hum(dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var xf := int(0.1 * RATE)
	var s := PackedFloat32Array()
	s.resize(n + xf)
	var y := 0.0
	for i in n + xf:
		var t := float(i) / RATE   # whole numbers of cycles over the loop: the tones meet themselves
		y += 0.15 * (_rng.randf_range(-1.0, 1.0) - y)
		s[i] = 0.08 * sin(TAU * 110.0 * t) + 0.04 * sin(TAU * 220.0 * t) + 0.025 * sin(TAU * 331.0 * t) + 0.12 * y
	return _loop_seam(s, n, xf, false)   # linear: the tones are identical on both sides of the seam


## One breath cycle (in + out) of shaped noise.
func _breath(dur: float) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var y := 0.0
	var y2 := 0.0
	for i in n:
		var u := float(i) / n
		var env := 0.0
		if u < 0.38:
			env = sin(PI * u / 0.38) * 0.8
		elif u > 0.45 and u < 0.9:
			env = sin(PI * (u - 0.45) / 0.45)
		var lp := 0.25 if u < 0.42 else 0.12
		y += lp * (_rng.randf_range(-1.0, 1.0) - y)
		y2 += 0.5 * (y - y2)
		s[i] = y2 * env * 0.55
	return s


## s holds n + xf samples: blend the last xf (the loop running on past its end) into the first xf, then
## drop them. Sample n-1 is then followed by what came after it: no click, no dip. Equal-power curves for
## noise (uncorrelated), linear ones when both sides are the same signal.
func _loop_seam(s: PackedFloat32Array, n: int, xf: int, equal_power: bool) -> PackedFloat32Array:
	for i in xf:
		var f := float(i) / xf
		var a := sin(f * PI * 0.5) if equal_power else f
		var b := cos(f * PI * 0.5) if equal_power else 1.0 - f
		s[i] = s[i] * a + s[n + i] * b
	s.resize(n)
	return s


## Builds every sound into `out` (runs on a worker thread: touches nothing but its own data).
func _build_into(out: Dictionary) -> void:
	out["hover"] = _wav(_sweep(2400, 2600, 0.025, 0.12, 9.0, 0.0))
	out["click"] = _wav(_sweep(1500, 900, 0.05, 0.35, 7.0))
	out["toggle"] = _wav(_concat([_sweep(900, 1100, 0.035, 0.3, 6.0), _sweep(1300, 1500, 0.05, 0.3, 6.0)]))
	out["confirm"] = _wav(_concat([_sweep(660, 660, 0.07, 0.35, 3.0), _sweep(990, 990, 0.12, 0.35, 4.0)]))
	out["type"] = _wav(_noise_burst(0.012, 0.25, 0.6, 12.0))
	out["boot"] = _wav(_concat([_sweep(220, 880, 0.35, 0.4, 1.5, 0.4), _sweep(880, 1320, 0.25, 0.3, 5.0)]))
	out["ready"] = _wav(_concat([_sweep(523, 523, 0.09, 0.3, 3.0), _sweep(659, 659, 0.09, 0.3, 3.0), _sweep(784, 784, 0.22, 0.32, 3.5)]))
	out["alert"] = _wav(_concat([_sweep(880, 880, 0.14, 0.45, 1.0), _silence(0.04), _sweep(660, 660, 0.14, 0.45, 1.0),
		_silence(0.04), _sweep(880, 880, 0.14, 0.45, 1.0), _silence(0.04), _sweep(660, 660, 0.2, 0.45, 2.0)]))
	out["warn"] = _wav(_concat([_sweep(740, 740, 0.12, 0.35, 2.0), _silence(0.05), _sweep(740, 555, 0.22, 0.35, 3.0)]))
	out["scan"] = _wav(_concat([_sweep(1400, 1350, 0.9, 0.35, 5.0, 0.1), _sweep(1400, 1350, 0.5, 0.08, 6.0, 0.0)]))
	out["whoosh"] = _wav(_noise_burst(0.7, 0.6, 0.06, 4.0))
	out["step"] = _wav(_noise_burst(0.09, 0.35, 0.12, 9.0))
	out["wind"] = _wav(_wind(8.0), true)
	out["suit"] = _wav(_suit_hum(2.0), true)
	out["breath"] = _wav(_breath(4.2), true)
	out["cw_emergency"] = _wav(_nasa_emergency())
	out["cw_warning"] = _wav(_nasa_warning())
	out["cw_caution"] = _wav(_nasa_caution())
	out["cw_advisory"] = _wav(_nasa_advisory())


# ------------------------------------------------------------------ NASA-STD-3001 Table 10.3-1 tones
## Band-limited periodic wave from odd harmonics (amplitude 1/k): no aliasing at our 22 kHz rate.
func _odd_series_table(f: float, n := 2048) -> PackedFloat32Array:
	var t := PackedFloat32Array()
	t.resize(n)
	var kmax := int(floor((RATE * 0.45) / f))
	var peak := 0.0
	for i in n:
		var ph := TAU * float(i) / n
		var v := 0.0
		var k := 1
		while k <= kmax:
			v += sin(k * ph) / k
			k += 2
		t[i] = v
		peak = maxf(peak, absf(v))
	for i in n:
		t[i] /= maxf(peak, 1e-6)
	return t


func _tone_from_table(table: PackedFloat32Array, f: float, dur: float, amp: float, ramp := 0.004) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var m := table.size()
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := minf(1.0, minf(t / ramp, (dur - t) / ramp))
		var x := ph * m
		var j := int(x) % m
		var fr := x - floorf(x)
		s[i] = amp * env * lerpf(table[j], table[(j + 1) % m], fr)
		ph = fmod(ph + f / RATE, 1.0)
	return s


## Warning: square waves alternating 400 Hz and 1,024 Hz, 0.4 s each; two pairs (1.6 s), 1 s of silence,
## the whole sequence twice (5.2 s). The speech part ("Warning, <message>") is spoken by the C&W system.
func _nasa_warning() -> PackedFloat32Array:
	var lo := _odd_series_table(400.0)
	var hi := _odd_series_table(1024.0)
	var seq := _concat([_tone_from_table(lo, 400.0, 0.4, 0.28), _tone_from_table(hi, 1024.0, 0.4, 0.28),
		_tone_from_table(lo, 400.0, 0.4, 0.28), _tone_from_table(hi, 1024.0, 0.4, 0.28), _silence(1.0)])
	return _concat([seq, seq])


## Caution: a 512 Hz tone of odd harmonics (amplitude 1/k) for 1 s. The C&W system repeats it after a silence.
func _nasa_caution() -> PackedFloat32Array:
	return _tone_from_table(_odd_series_table(512.0), 512.0, 1.0, 0.3, 0.01)


## Advisory: 900 Hz sine, 106 ms, 106 ms silence, 106 ms; self-terminating (318 ms).
func _nasa_advisory() -> PackedFloat32Array:
	var n := int(0.106 * RATE)
	var beep := PackedFloat32Array()
	beep.resize(n)
	for i in n:
		var t := float(i) / RATE
		beep[i] = 0.35 * minf(1.0, minf(t / 0.004, (0.106 - t) / 0.004)) * sin(TAU * 900.0 * t)
	return _concat([beep, _silence(0.106), beep])


## Emergency (other than fire, e.g. pressure loss): a 2,560 Hz pulse train (2.1 ms on, 1.6 ms off) OR'd with
## a 256 Hz one (210 ms on, 70 ms off), four 280 ms pulses then 280 ms of silence, twice; DC removed.
func _nasa_emergency() -> PackedFloat32Array:
	var n := int(2.8 * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var mean := 0.0
	for i in n:
		var t := float(i) / RATE
		var cyc := fmod(t, 1.4)
		var v := 0.0
		if cyc < 1.12:
			var a := fmod(t, 0.0037) < 0.0021 and fmod(t * 2560.0, 1.0) < 0.5
			var b := fmod(cyc, 0.28) < 0.21 and fmod(t * 256.0, 1.0) < 0.5
			v = 1.0 if (a or b) else 0.0
		s[i] = v
		mean += v
	mean /= n
	var y := 0.0
	for i in n:
		y += 0.6 * ((s[i] - mean) - y)   # a touch of smoothing on the hard edges
		s[i] = 0.32 * y
	return s
