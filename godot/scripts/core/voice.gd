class_name VoiceControl
extends Node
## Hands-free commands through Windows' own offline speech recogniser (System.Speech, no download, no
## cloud). A small PowerShell script (written to user:// at start) listens for a fixed grammar of "suit …"
## phrases and prints what it heard; this node reads its output on a thread and emits `command`.
## A fixed grammar with a "suit" prefix keeps false triggers low, the way SUITS-style helmet displays do.
## self_test() synthesises a phrase with Windows' voice into a WAV and feeds it to the recogniser, so the
## whole chain can be checked without a microphone.

signal command(text: String, confidence: float)
signal state_changed(state: String, detail: String)   # off | starting | listening | error | test

const PHRASES := ["suit acknowledge", "suit silence", "suit status", "suit next waypoint", "suit turn back time",
	"suit autopilot on", "suit autopilot off", "suit play", "suit pause", "suit helmet view", "suit map view",
	"suit check task", "suit abort", "suit confirm abort", "suit cancel abort", "suit alert list", "suit cuff menu"]

const SCRIPT := """param([string]$WaveFile = "", [string]$SynthText = "", [string]$SynthOut = "", [double]$MinConfidence = 0.55, [string]$Phrases = "")
$ErrorActionPreference = "Stop"
function Say([string]$t) { [Console]::Out.WriteLine($t); [Console]::Out.Flush() }
try { Add-Type -AssemblyName System.Speech } catch { Say ("ERROR System.Speech is not available: " + $_.Exception.Message); exit 2 }
if ($SynthText -ne "") {
  $s = New-Object System.Speech.Synthesis.SpeechSynthesizer
  $fmt = New-Object System.Speech.AudioFormat.SpeechAudioFormatInfo(16000, [System.Speech.AudioFormat.AudioBitsPerSample]::Sixteen, [System.Speech.AudioFormat.AudioChannel]::Mono)
  $s.SetOutputToWaveFile($SynthOut, $fmt); $s.Speak($SynthText); $s.Dispose(); Say "SYNTH OK"; exit 0
}
$rec = $null
foreach ($r in [System.Speech.Recognition.SpeechRecognitionEngine]::InstalledRecognizers()) { if ($r.Culture.TwoLetterISOLanguageName -eq "en") { $rec = New-Object System.Speech.Recognition.SpeechRecognitionEngine($r); break } }
if ($rec -eq $null) { Say "ERROR no English speech recogniser is installed (Windows Settings > Time & language > Speech)"; exit 3 }
$choices = New-Object System.Speech.Recognition.Choices
foreach ($p in $Phrases.Split("|")) { if ($p -ne "") { $choices.Add($p) } }
$gb = New-Object System.Speech.Recognition.GrammarBuilder
$gb.Culture = $rec.RecognizerInfo.Culture
$gb.Append($choices)
$rec.LoadGrammar((New-Object System.Speech.Recognition.Grammar($gb)))
try { if ($WaveFile -ne "") { $rec.SetInputToWaveFile($WaveFile) } else { $rec.SetInputToDefaultAudioDevice() } } catch { Say ("ERROR no audio input: " + $_.Exception.Message); exit 4 }
Say ("READY " + $rec.RecognizerInfo.Culture.Name)
while ($true) {
  $res = $rec.Recognize()
  if ($res -eq $null) { if ($WaveFile -ne "") { break } else { continue } }
  if ($res.Confidence -ge $MinConfidence -or $WaveFile -ne "") { Say ("CMD " + $res.Text + "|" + $res.Confidence.ToString("0.00", [System.Globalization.CultureInfo]::InvariantCulture)) }
}
Say "END"
"""

var state := "off"
var _pid := -1
var _pipe: FileAccess
var _thread: Thread
var _mutex := Mutex.new()
var _lines: Array[String] = []
var _script_path := ""


func _ready() -> void:
	var path := "user://voice_listener.ps1"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(SCRIPT)
		f.close()
	_script_path = ProjectSettings.globalize_path(path)


func available() -> bool:
	return OS.get_name() == "Windows"


## Start listening on the default microphone (or a WAV file, for tests).
func start(wave_file := "") -> void:
	stop()
	if not available():
		_set_state("error", "voice commands need Windows' speech recogniser")
		return
	var args := PackedStringArray(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", _script_path,
		"-Phrases", "|".join(PackedStringArray(PHRASES))])
	if wave_file != "":
		args.append_array(["-WaveFile", wave_file])
	var r := OS.execute_with_pipe("powershell.exe", args, true)
	if r.is_empty():
		_set_state("error", "could not start PowerShell")
		return
	_pid = int(r["pid"])
	_pipe = r["stdio"]
	_set_state("starting", "loading the recogniser")
	_thread = Thread.new()
	_thread.start(_read_loop)


func stop() -> void:
	if _pid > 0:
		OS.kill(_pid)
		_pid = -1
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	_pipe = null
	if state != "off":
		_set_state("off", "")


func _exit_tree() -> void:
	stop()


## Runs on the thread: blocking reads of the listener's lines.
func _read_loop() -> void:
	while _pipe and _pipe.is_open():
		var line := _pipe.get_line()
		if line == "" and _pipe.get_error() != OK:
			break
		if line != "":
			_mutex.lock()
			_lines.append(line.strip_edges())
			_mutex.unlock()
	_mutex.lock()
	_lines.append("EXIT")
	_mutex.unlock()


func _process(_d: float) -> void:
	if _lines.is_empty():
		return
	_mutex.lock()
	var batch := _lines.duplicate()
	_lines.clear()
	_mutex.unlock()
	for line in batch:
		var s := str(line)
		if s.begins_with("READY"):
			_set_state("listening", s.substr(6))
		elif s.begins_with("ERROR"):
			_set_state("error", s.substr(6))
		elif s.begins_with("CMD "):
			var bits := s.substr(4).split("|")
			command.emit(bits[0], float(bits[1]) if bits.size() > 1 else 1.0)
		elif s == "EXIT" and state != "error":
			_set_state("off", "listener stopped")


func _set_state(s: String, detail: String) -> void:
	state = s
	state_changed.emit(s, detail)


## Synthesise `text` with Windows' voice into a WAV (blocking, ~1-2 s). Returns the WAV path or "".
func synth_wav(text: String) -> String:
	var out := ProjectSettings.globalize_path("user://voice_test.wav")
	var o := []
	OS.execute("powershell.exe", PackedStringArray(["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", _script_path,
		"-SynthText", text, "-SynthOut", out]), o, true)
	return out if FileAccess.file_exists("user://voice_test.wav") and "\n".join(PackedStringArray(o)).contains("SYNTH OK") else ""


## No-microphone check: Windows' voice says `text`, the recogniser listens to the WAV.
func self_test(text := "suit status") -> void:
	_set_state("test", "synthesising \"%s\"" % text)
	var wav := await _synth_async(text)
	if wav == "":
		_set_state("error", "could not synthesise a test phrase")
		return
	start(wav)


func _synth_async(text: String) -> String:
	var result := [""]
	var task := WorkerThreadPool.add_task(func(): result[0] = synth_wav(text))
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)
	return str(result[0])
