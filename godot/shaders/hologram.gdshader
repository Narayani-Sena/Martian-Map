// Floating holographic marker (diamonds over stops, AR chevrons): emissive, scanlines, flicker.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(0.31, 0.82, 1.0, 1.0);
uniform float intensity = 2.0;
uniform float scan_speed = 1.5;
uniform float flow = 0.0;      // >0: brightness wave travels along local -Z (for chevrons)
uniform float phase = 0.0;

void fragment() {
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float lines = 0.75 + 0.25 * sin(wp.y * 40.0 - TIME * scan_speed * 6.0);
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.2);
	float fl = 0.92 + 0.08 * sin(TIME * 23.0 + phase * 3.0);
	float wave = 1.0;
	if (flow > 0.0) {
		wave = 0.35 + 0.65 * pow(0.5 + 0.5 * sin(phase - TIME * flow), 6.0);
	}
	ALBEDO = color.rgb * intensity * lines * (0.45 + rim) * fl * wave;
}
