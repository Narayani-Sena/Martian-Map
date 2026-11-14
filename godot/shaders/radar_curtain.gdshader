shader_type spatial;
// Ground radar under the rover's track (feature E1): Perseverance's RIMFAX radargrams hung as a curtain from the
// ground down to the radar's depth, each sol's radargram along that sol's drive. The atlas holds the signed traces
// in L (0.5 = no echo) and the echo strength in A. Up close the traces are drawn the way radargrams are read (one
// sign light, the other dark); further away, where the wiggles are finer than a pixel, the curtain glows with the
// echo strength instead. It is drawn through the ground near it (the metres of terrain between the eye and the
// curtain come from the depth buffer) and fades where a hill stands in front: an x-ray of the ground under the track.
render_mode unshaded, cull_disabled, depth_draw_never, depth_test_disabled, blend_mix, shadows_disabled, fog_disabled;

uniform sampler2D atlas : filter_linear_mipmap, repeat_disable;
uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec2 atlas_size = vec2(4096.0, 2718.0);
uniform float depth_m = 5.0;        // true depth of the curtain's lower edge
uniform float depth_scale = 1.0;    // drawn deeper from orbit so it can be seen
uniform float reveal = 1.0;         // 0..1: the curtain unrolls into the ground
uniform float opacity = 0.94;
uniform float xray_near = 25.0;     // metres of ground in front that are seen through fully
uniform float xray_far = 80.0;      // ... and where the curtain has faded out
uniform vec3 light_col : source_color = vec3(0.72, 0.96, 1.0);
uniform vec3 dark_col : source_color = vec3(0.0, 0.04, 0.09);
uniform vec3 deep_col : source_color = vec3(0.02, 0.07, 0.2);
uniform vec3 glow_col : source_color = vec3(0.3, 0.92, 1.0);
uniform vec3 edge_col : source_color = vec3(0.45, 0.95, 1.0);

varying float v_depth;   // 0 at the ground, 1 at the lower edge

void vertex() {
	v_depth = UV2.y;
	VERTEX.y -= UV2.y * depth_m * depth_scale * reveal;
}

void fragment() {
	// ground between the eye and this point of the curtain (Forward+: reversed-Z depth, as in the lake shader)
	float d_raw = texture(depth_tex, SCREEN_UV).r;
	vec4 vp = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, d_raw, 1.0);
	vp.xyz /= vp.w;
	float occ = max(length(VERTEX) - length(vp.xyz), 0.0);
	float see = 1.0 - smoothstep(xray_near, xray_far, occ);

	vec4 s = texture(atlas, UV);
	float v = s.r;
	float e = s.a;
	// texels per pixel: 1 or less up close (draw the traces), several far away (draw the echo strength)
	vec2 tpp = fwidth(UV) * atlas_size;
	float far = smoothstep(1.2, 3.5, max(tpp.x, tpp.y));
	vec3 near_col = mix(dark_col, light_col, smoothstep(0.06, 0.94, v));
	vec3 far_col = mix(deep_col, glow_col, smoothstep(0.05, 0.95, e)) * (0.7 + 0.3 * e);
	vec3 col = mix(near_col, far_col, far);
	float a = mix(0.68 + 0.32 * abs(v - 0.5) * 2.0, 0.26 + 0.5 * e, far);
	// a glowing frame: the ground line and the radar's depth limit
	float edge = (1.0 - smoothstep(0.0, 0.025, v_depth)) + 0.7 * (1.0 - smoothstep(0.0, 0.018, 1.0 - v_depth));
	// a scan line sweeping down, and a faint line every metre of true depth
	float scan = exp(-pow((v_depth - fract(TIME * 0.16)) * 28.0, 2.0)) * 0.4;
	float m = v_depth * depth_m;
	float dm = min(fract(m), 1.0 - fract(m));
	float tick = (1.0 - smoothstep(0.0, fwidth(m) * 1.3, dm)) * step(0.5, m) * 0.3;
	col = mix(col, edge_col, clamp(edge + scan + tick, 0.0, 1.0));
	ALBEDO = col;
	ALPHA = clamp((a + edge) * opacity * see, 0.0, 1.0);
}
