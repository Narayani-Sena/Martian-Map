// A distant dust devil: a twisted cone of scrolling noise, thicker at the base, fading upward.
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

uniform vec4 color : source_color = vec4(0.8, 0.62, 0.46, 0.42);
uniform float column_height = 400.0;
uniform float speed = 1.0;
uniform float sun = 1.0;

varying float v_h;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

void vertex() {
	v_h = clamp(VERTEX.y / column_height + 0.5, 0.0, 1.0);
	float twist = sin(v_h * 6.0 + TIME * 0.7) * 0.08 * column_height * v_h;
	VERTEX.x += twist;
}

void fragment() {
	vec2 p = vec2(UV.x * 9.0 + v_h * 4.0 - TIME * speed * 1.6, v_h * 7.0 - TIME * speed * 0.9);
	float n = vnoise(p * 1.4) * 0.6 + vnoise(p * 4.3) * 0.4;
	float rim = abs(dot(NORMAL, VIEW));
	float fade = smoothstep(0.0, 0.06, v_h) * (1.0 - smoothstep(0.45, 1.0, v_h));
	ALBEDO = color.rgb * (0.75 + 0.45 * n) * (0.25 + 0.75 * sun);
	ALPHA = color.a * fade * smoothstep(0.3, 0.75, n) * (0.25 + 0.75 * rim);
}
