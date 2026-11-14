extends Node
## HTTP client for the Martian Map FastAPI backend (../server).
## Every call is a coroutine: `var r := await Api.get_json("/api/health")`.
## Large binaries (DEMs, imagery) are cached under user://cache so later launches are instant and work offline.

signal link_changed(online: bool)
signal backend_log(text: String)

const CACHE_DIR := "user://cache"

var base_url := "http://127.0.0.1:8000"
var online := false
var requests_in_flight := 0
var _backend_pid := -1


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--api="):
			base_url = a.substr(6).rstrip("/")
	var env := OS.get_environment("MARTIAN_MAP_API")
	if env != "":
		base_url = env.rstrip("/")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(CACHE_DIR))


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		stop_backend()


func _set_online(v: bool) -> void:
	if v != online:
		online = v
		link_changed.emit(v)


## Raw request. Returns {ok, code, body: PackedByteArray, headers: {lowercase: value}, error}.
func request_raw(path: String, method := HTTPClient.METHOD_GET, body := "", timeout := 60.0, gzip := true) -> Dictionary:
	var req := HTTPRequest.new()
	req.use_threads = true
	req.timeout = timeout
	req.accept_gzip = gzip
	req.download_chunk_size = 1 << 20
	add_child(req)
	var headers := PackedStringArray(["Accept: */*", "User-Agent: martian-map-godot/1.0"])
	if method == HTTPClient.METHOD_POST:
		headers.append("Content-Type: application/json")
	var url := path if path.begins_with("http") else base_url + path
	requests_in_flight += 1
	var err := req.request(url, headers, method, body)
	if err != OK:
		requests_in_flight -= 1
		req.queue_free()
		return {"ok": false, "code": 0, "body": PackedByteArray(), "headers": {}, "error": "request failed: %s" % error_string(err)}
	var res: Array = await req.request_completed
	requests_in_flight -= 1
	req.queue_free()
	var result: int = res[0]
	var code: int = res[1]
	var hdrs := {}
	for line in (res[2] as PackedStringArray):
		var i := line.find(":")
		if i > 0:
			hdrs[line.substr(0, i).strip_edges().to_lower()] = line.substr(i + 1).strip_edges()
	var ok := result == HTTPRequest.RESULT_SUCCESS and code >= 200 and code < 300
	if not path.begins_with("http") or path.begins_with(base_url):
		_set_online(result == HTTPRequest.RESULT_SUCCESS)
	var out := {"ok": ok, "code": code, "body": res[3], "headers": hdrs, "error": ""}
	if not ok:
		out["error"] = _describe(result, code)
	return out


func _describe(result: int, code: int) -> String:
	match result:
		HTTPRequest.RESULT_SUCCESS:
			return "HTTP %d" % code
		HTTPRequest.RESULT_CANT_CONNECT, HTTPRequest.RESULT_CANT_RESOLVE, HTTPRequest.RESULT_CONNECTION_ERROR:
			return "Cannot reach the Martian Map API at %s" % base_url
		HTTPRequest.RESULT_TIMEOUT:
			return "The API took too long to answer"
		HTTPRequest.RESULT_TLS_HANDSHAKE_ERROR:
			return "TLS handshake failed"
		_:
			return "Network error (%d)" % result


func _with_json(r: Dictionary) -> Dictionary:
	var data: Variant = null
	var body: PackedByteArray = r["body"]
	if body.size() > 0:
		data = JSON.parse_string(body.get_string_from_utf8())
	if not r["ok"] and data is Dictionary and (data as Dictionary).has("detail"):
		r["error"] = str(data["detail"])
	r["data"] = data
	return r


func get_json(path: String, timeout := 60.0) -> Dictionary:
	var r := await request_raw(path, HTTPClient.METHOD_GET, "", timeout)
	return _with_json(r)


func post_json(path: String, payload: Variant, timeout := 180.0) -> Dictionary:
	var r := await request_raw(path, HTTPClient.METHOD_POST, JSON.stringify(payload), timeout)
	return _with_json(r)


## Run fn on a worker thread and wait for it without blocking frames (boot animation, the 3D view).
## fn must not touch the scene tree; hand results back through a captured Array or Dictionary.
func run_async(fn: Callable) -> void:
	var task := WorkerThreadPool.add_task(fn)
	while not WorkerThreadPool.is_task_completed(task):
		await get_tree().process_frame
	WorkerThreadPool.wait_for_task_completion(task)


## A whole file read on a worker thread (the 42 MB DEM took ~100 ms of one frame on the main thread).
func read_file_async(path: String) -> PackedByteArray:
	var out := [PackedByteArray()]
	await run_async(func(): out[0] = FileAccess.get_file_as_bytes(path))
	return out[0]


## GET a binary once and keep it in user://cache (falls back to a stale copy when offline).
func get_cached(path: String, cache_name: String, max_age_s := 86400.0 * 14.0) -> Dictionary:
	var cp := CACHE_DIR.path_join(cache_name)
	var meta_path := cp + ".meta.json"
	if FileAccess.file_exists(cp) and FileAccess.file_exists(meta_path):
		var meta: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if meta is Dictionary:
			var age := Time.get_unix_time_from_system() - float(meta.get("t", 0.0))
			if age < max_age_s:
				var body := await read_file_async(cp)
				return {"ok": true, "code": 200, "body": body, "headers": meta.get("headers", {}), "cached": true, "error": ""}
	var r := await request_raw(path, HTTPClient.METHOD_GET, "", 240.0, false)
	if r["ok"]:
		var f := FileAccess.open(cp, FileAccess.WRITE)
		if f:
			f.store_buffer(r["body"])
			f.close()
		var m := FileAccess.open(meta_path, FileAccess.WRITE)
		if m:
			m.store_string(JSON.stringify({"t": Time.get_unix_time_from_system(), "headers": r["headers"], "path": path}))
			m.close()
	elif FileAccess.file_exists(cp):
		var meta2: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path)) if FileAccess.file_exists(meta_path) else {}
		var hd: Variant = (meta2 as Dictionary).get("headers", {}) if meta2 is Dictionary else {}
		return {"ok": true, "code": 200, "body": FileAccess.get_file_as_bytes(cp), "headers": hd, "cached": true, "stale": true, "error": ""}
	return r


## Decode PNG / JPEG / WebP bytes into an Image (null on failure).
static func decode_image(body: PackedByteArray) -> Image:
	if body.size() < 8:
		return null
	var img := Image.new()
	var err := ERR_FILE_UNRECOGNIZED
	if body[0] == 0x89 and body[1] == 0x50:
		err = img.load_png_from_buffer(body)
	elif body[0] == 0xFF and body[1] == 0xD8:
		err = img.load_jpg_from_buffer(body)
	else:
		err = img.load_webp_from_buffer(body)
	return img if err == OK else null


func get_image(path: String, cache_name := "", mipmaps := false) -> Image:
	var r: Dictionary
	if cache_name != "":
		r = await get_cached(path, cache_name)
	else:
		r = await request_raw(path, HTTPClient.METHOD_GET, "", 90.0, false)
	if not r["ok"]:
		return null
	return await decode_async(r["body"], mipmaps)


## Decode (and build mipmaps) on a worker thread so big overlays don't stall the frame.
func decode_async(body: PackedByteArray, mipmaps: bool) -> Image:
	var out := [null]
	await run_async(func():
		var img := decode_image(body)
		if img and mipmaps:
			img.generate_mipmaps()
		out[0] = img)
	return out[0]


func get_texture(path: String, cache_name := "", mipmaps := true) -> ImageTexture:
	var img := await get_image(path, cache_name, mipmaps)
	if img == null:
		return null
	return ImageTexture.create_from_image(img)


static func q(params: Dictionary) -> String:
	var parts := PackedStringArray()
	for k in params:
		var v = params[k]
		if v == null or str(v) == "":
			continue
		parts.append("%s=%s" % [str(k).uri_encode(), str(v).uri_encode()])
	return "?" + "&".join(parts) if parts.size() > 0 else ""


# ------------------------------------------------------------------ local backend
func is_local() -> bool:
	return base_url.contains("127.0.0.1") or base_url.contains("localhost")


## Make sure the API answers. When running from the source tree and nothing is listening,
## start `uvicorn server.main:app` from ../.venv and wait for it.
func ensure_backend(on_status: Callable = Callable()) -> bool:
	var r := await request_raw("/api/health", HTTPClient.METHOD_GET, "", 3.0)
	if r["ok"]:
		return true
	if not is_local() or OS.has_feature("web"):
		return false
	var proj := ProjectSettings.globalize_path("res://").rstrip("/\\")
	var root := proj.get_base_dir()
	var py := root.path_join(".venv/Scripts/python.exe")
	if not FileAccess.file_exists(py):
		py = root.path_join(".venv/bin/python")
	if not FileAccess.file_exists(py) or not FileAccess.file_exists(root.path_join("server/main.py")):
		backend_log.emit("No local backend found next to the Godot project")
		return false
	var port := base_url.get_slice(":", 2).to_int()
	if port <= 0:
		port = 8000
	if on_status.is_valid():
		on_status.call("Starting the mission server (uvicorn)…")
	_backend_pid = OS.create_process(py, ["-m", "uvicorn", "server.main:app", "--app-dir", root, "--host", "127.0.0.1", "--port", str(port)], false)
	if _backend_pid <= 0:
		return false
	for i in 80:
		await get_tree().create_timer(0.5).timeout
		var h := await request_raw("/api/health", HTTPClient.METHOD_GET, "", 2.0)
		if h["ok"]:
			return true
	return false


func stop_backend() -> void:
	if _backend_pid > 0:
		OS.kill(_backend_pid)
		_backend_pid = -1
