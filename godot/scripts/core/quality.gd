class_name Quality
extends RefCounted
## Rendering presets. "low" keeps integrated GPUs (e.g. Intel UHD) interactive; "high" is for
## discrete cards. Picked automatically from the GPU, or forced with `-- --quality=low|medium|high`.

const PRESETS := {
	"low": {"clip_n": 168, "msaa": 0, "fxaa": true, "ssao": false, "splits": 2, "shadow": 2048, "scale": 0.77,
		"tex": 2048, "dust": 500, "rock_radius": 2, "glow": true, "shadow_dist_walk": 160.0, "shadow_dist_orbit": 1800.0},
	"medium": {"clip_n": 208, "msaa": 0, "fxaa": true, "ssao": true, "splits": 4, "shadow": 4096, "scale": 1.0,
		"tex": 4096, "dust": 1000, "rock_radius": 3, "glow": true, "shadow_dist_walk": 300.0, "shadow_dist_orbit": 2600.0},
	"high": {"clip_n": 256, "msaa": 2, "fxaa": false, "ssao": true, "splits": 4, "shadow": 4096, "scale": 1.0,
		"tex": 4096, "dust": 1400, "rock_radius": 3, "glow": true, "shadow_dist_walk": 420.0, "shadow_dist_orbit": 3000.0},
}

static var level := "medium"


## Preset to use: `--quality=` on the command line, else the Settings choice, else by GPU.
static func detect() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--quality="):
			var q := a.substr(10)
			if PRESETS.has(q):
				return q
	var chosen := str(Settings.get_value("quality"))
	if PRESETS.has(chosen):
		return chosen
	return detect_gpu()


## What "auto" picks on this machine.
static func detect_gpu() -> String:
	var name := RenderingServer.get_video_adapter_name().to_lower()
	var kind := RenderingServer.get_video_adapter_type()
	if kind == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU or name.contains("intel") or name.contains("uhd") or name.contains("iris"):
		return "low"
	if kind == RenderingDevice.DEVICE_TYPE_CPU or kind == RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
		return "low"
	return "high"


static func get_value(key: String) -> Variant:
	return PRESETS[level][key]


static func apply(viewport: Viewport, env: Environment, sun: DirectionalLight3D) -> void:
	var p: Dictionary = PRESETS[level]
	viewport.msaa_3d = Viewport.MSAA_2X if int(p["msaa"]) == 2 else Viewport.MSAA_DISABLED
	viewport.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA if bool(p["fxaa"]) else Viewport.SCREEN_SPACE_AA_DISABLED
	var sc := float(p["scale"])
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if sc < 0.99 else Viewport.SCALING_3D_MODE_BILINEAR
	viewport.scaling_3d_scale = sc
	viewport.fsr_sharpness = 0.5
	if env:
		env.ssao_enabled = bool(p["ssao"])
		env.glow_enabled = bool(p["glow"])
	if sun:
		sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if int(p["splits"]) == 2 else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	RenderingServer.directional_shadow_atlas_set_size(int(p["shadow"]), true)
	if level == "low":
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
	else:
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_MEDIUM)
