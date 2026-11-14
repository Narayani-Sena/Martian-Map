// Vertical light column over a stop: additive, fades with height, rippling pulses rise up it.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(1.0, 0.48, 0.24, 1.0);
uniform float intensity = 2.2;
uniform float column_height = 60.0;
uniform float selected = 0.0;

varying float v_h;

void vertex() {
	v_h = clamp(VERTEX.y / column_height + 0.5, 0.0, 1.0);
}

void fragment() {
	float fade = pow(1.0 - v_h, 1.6);
	float pulse = 0.65 + 0.35 * sin(TIME * 3.0 - v_h * 14.0);
	float rim = pow(1.0 - abs(dot(NORMAL, VIEW)), 1.5);
	float sel = 1.0 + selected * (0.8 + 0.4 * sin(TIME * 6.0));
	ALBEDO = color.rgb * intensity * fade * pulse * (0.25 + rim) * sel;
}
