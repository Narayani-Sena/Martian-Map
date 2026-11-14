shader_type spatial;
// The ancient lake's surface (feature A4, Flood the crater). One flat sheet over the regional terrain, clipped to a
// single body of water by the server's mask; the terrain hides it wherever the ground stands above the level, so
// the shoreline is drawn by the 1 m terrain itself. The scene depth behind the sheet gives the water's thickness
// along the view: thin water shows the lake bed, thick water turns deep blue, and a pale line marks the shore.
// Ripples near the camera, a mirror further out, and the bright underside seen from below.
render_mode blend_mix, cull_disabled, specular_schlick_ggx;

uniform sampler2D mask_tex : filter_linear, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 reg_rect = vec4(-47400.0, 47400.0, 94800.0, 94800.0);   // x_min, y_max, width, height (m)
uniform vec3 shallow_col : source_color = vec3(0.22, 0.52, 0.5);
uniform vec3 deep_col : source_color = vec3(0.03, 0.16, 0.24);
uniform float glow = 0.35;       // some of the water's own colour, so it still reads as water under the butterscotch sky
uniform vec3 under_col : source_color = vec3(0.3, 0.6, 0.64);
uniform float clarity_m = 9.0;   // metres of water along the view that hide the bed by about two thirds
uniform float fade = 1.0;
uniform vec3 wb_gain = vec3(1.0);

varying vec3 v_world;

void vertex() {
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

// slope of a few travelling waves (m per m), for the ripple normal
vec2 waves(vec2 p, float t) {
	vec2 d1 = vec2(0.8, 0.6);
	vec2 d2 = vec2(-0.3, 0.954);
	vec2 d3 = vec2(0.968, -0.25);
	vec2 d4 = vec2(-0.707, -0.707);
	vec2 g = d1 * cos(dot(p, d1) * 0.9 - t * 1.1) * 0.032;
	g += d2 * cos(dot(p, d2) * 1.7 - t * 1.6) * 0.034;
	g += d3 * cos(dot(p, d3) * 3.1 - t * 2.3) * 0.037;
	g += d4 * cos(dot(p, d4) * 0.37 - t * 0.7) * 0.022;
	return g;
}

void fragment() {
	vec2 xy = vec2(v_world.x, -v_world.z);
	vec2 uv = vec2((xy.x - reg_rect.x) / reg_rect.z, (reg_rect.y - xy.y) / reg_rect.w);
	if (texture(mask_tex, uv).r < 0.5) {
		discard;
	}
	vec3 to_cam = CAMERA_POSITION_WORLD - v_world;
	float cam_d = length(to_cam);
	float near = 1.0 - smoothstep(150.0, 3000.0, cam_d);
	vec2 g = waves(xy, TIME) * near;
	vec3 n = normalize(vec3(-g.x, 1.0, g.y));
	bool below = CAMERA_POSITION_WORLD.y < v_world.y;
	if (below) {
		n = -n;
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);
	float ndv = clamp(dot(to_cam / max(cam_d, 1e-3), n), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 5.0);
	if (below) {
		// from under the water: a bright, rippling ceiling that turns to a mirror at grazing angles
		ALBEDO = under_col * wb_gain;
		EMISSION = under_col * wb_gain * (0.12 + 0.25 * fres);
		ROUGHNESS = 0.25;
		SPECULAR = 0.3;
		ALPHA = clamp(0.42 + 0.5 * (1.0 - ndv), 0.0, 0.93) * fade;
	} else {
		// water between this surface point and the ground behind it, along the view (Forward+: reversed-Z depth)
		float d_raw = texture(depth_tex, SCREEN_UV).r;
		vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d_raw, 1.0);
		vp.xyz /= vp.w;
		float thick = max(length(vp.xyz) - length(VERTEX), 0.0);
		float absorb = 1.0 - exp(-thick / clarity_m);
		vec3 col = mix(shallow_col, deep_col, smoothstep(0.0, 1.0, absorb));
		float foam = (1.0 - smoothstep(0.0, 0.6 + cam_d * 0.0008, thick)) * (1.0 - smoothstep(800.0, 5000.0, cam_d));
		col = mix(col, vec3(0.86, 0.93, 0.92), foam * 0.55);
		ALBEDO = col * wb_gain;
		EMISSION = col * wb_gain * glow * (1.0 - fres);
		ROUGHNESS = mix(0.03, 0.09, near);
		SPECULAR = 0.6;
		ALPHA = clamp(mix(0.22, 0.86, absorb) + fres * 0.35 + foam * 0.4, 0.0, 0.97) * fade;
	}
}
