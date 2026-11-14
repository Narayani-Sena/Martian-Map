// Glowing ribbon draped over the terrain (route, Curiosity's traverse, walk-back rings).
// The mesh carries the centre line; the side vector rides in NORMAL and the ribbon is widened
// here so it never gets thinner than `min_px` pixels, however far the camera is.
//
// Depth is tested here, not by the hardware: far away the terrain is drawn from a smoothed height model
// that lies several metres above the floor of narrow hollows (where routes like to run), and a plain depth
// test buried the line there. A fragment only counts as hidden when the terrain in front of it is closer
// by more than `occlusion_tol` of its distance, so the line shows in hollows yet still disappears behind
// real ridges. `hidden_alpha` lets an x-ray copy show through those ridges.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, depth_test_disabled, cull_disabled, shadows_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
// Metres one screen pixel covers per metre of distance, set by world.gd every frame from the camera's field
// of view and the window height (the vertex stage's VIEWPORT_SIZE / PROJECTION_MATRIX gave a far too small
// pixel size here, so the min_px floor never acted and distant lines shrank below a pixel and vanished).
global uniform float ribbon_px_k;
uniform float occlusion_tol = 0.03;   // share of the distance terrain may stand in front without hiding the line
uniform float hidden_alpha = 0.0;     // how much of a hidden stretch still shows (1 = always on top)

uniform vec4 color : source_color = vec4(0.31, 0.82, 1.0, 1.0);
uniform float glow = 1.8;
uniform float width_m = 1.2;
uniform float min_px = 3.0;
uniform float lift = 0.35;
uniform float flow_speed = 0.0;   // chevrons per second along the ribbon (m/s)
uniform float chevron_m = 9.0;
uniform float dash_m = 0.0;       // 0 = solid
uniform float progress_d = -1.0;  // metres already walked (shown dimmer)
uniform float opacity = 1.0;
uniform bool use_vertex_color = false;
uniform float near_fade = 0.0;   // metres: fade the ribbon out close to the camera
// Re-planning: the old line is out of date while the server computes (stale -> 1: grey, dim, a slow
// ripple runs along it), then the new one sweeps in from the start (drawn up to reveal_d metres,
// with a bright leading edge).
uniform float stale = 0.0;
uniform float reveal_d = 1.0e9;
uniform float reveal_head = 40.0;

varying float v_along;
varying float v_across;
varying vec4 v_col;
varying float v_cam;

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float cam_d = length(wp - CAMERA_POSITION_WORLD);
	float px = cam_d * ribbon_px_k;
	float w = max(width_m, min_px * px);
	VERTEX += NORMAL * (UV.y - 0.5) * w;
	VERTEX.y += lift + cam_d * 0.0016;
	v_along = UV.x;
	v_across = UV.y;
	v_col = COLOR;
	v_cam = cam_d;
}

void fragment() {
	if (dash_m > 0.0 && fract(v_along / dash_m) > 0.58) {
		discard;
	}
	if (v_along > reveal_d) {
		discard;
	}
	vec3 col = use_vertex_color ? v_col.rgb : color.rgb;
	float edge = 1.0 - pow(abs(v_across - 0.5) * 2.0, 4.0);
	float core = 1.0 - smoothstep(0.0, 0.32, abs(v_across - 0.5));
	vec3 c = col * (0.75 + 0.6 * core);
	if (flow_speed != 0.0) {
		float f = fract((v_along - TIME * flow_speed) / chevron_m - abs(v_across - 0.5) * 0.9);
		float chev = smoothstep(0.0, 0.12, f) * (1.0 - smoothstep(0.22, 0.36, f));
		c = mix(c, vec3(1.0), chev * 0.55);
	}
	float a = color.a * opacity * edge;
	float scene = texture(depth_tex, SCREEN_UV).r;
	vec4 sv = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, scene, 1.0);
	float scene_z = -sv.z / sv.w;
	float frag_z = -VERTEX.z;
	float tol = max(0.25, frag_z * occlusion_tol);
	float hidden = smoothstep(scene_z + tol * 0.5, scene_z + tol, frag_z);
	a *= mix(1.0, hidden_alpha, hidden);
	if (near_fade > 0.0) {
		a *= smoothstep(near_fade * 0.25, near_fade, v_cam);
	}
	if (progress_d >= 0.0 && v_along < progress_d) {
		c *= 0.55;
		a *= 0.7;
	}
	if (stale > 0.0) {
		float ripple = 0.5 + 0.5 * sin(v_along * 0.045 - TIME * 3.5);
		c = mix(c, vec3(dot(c, vec3(0.3333))) * 0.75, stale * 0.8);
		a *= mix(1.0, 0.22 + 0.22 * ripple, stale);
	}
	if (reveal_d < 1.0e8) {
		float head = smoothstep(reveal_d - reveal_head, reveal_d, v_along);
		c = mix(c, vec3(1.0, 1.0, 1.0) * 1.4, head * 0.75);
		a = max(a, head * edge * opacity);
	}
	ALBEDO = c * glow;
	ALPHA = clamp(a, 0.0, 1.0);
}
