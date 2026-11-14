// Helmet visor: slight lens curvature, chromatic fringe at the rim, tint, a reflection streak
// that drifts as you turn your head, breath condensation, power-on flicker and alert glitches.
shader_type canvas_item;

// No mipmaps: with a mipmapped screen texture the engine blurs the whole screen into a mip chain every frame,
// although only fogged pixels need a blur. Those take a small ring of samples instead (blur_ring below).
uniform sampler2D screen_tex : hint_screen_texture, filter_linear;
uniform float strength = 1.0;
uniform float aberration = 0.0022;
uniform float vignette = 0.8;
uniform float fog = 0.0;
uniform float flicker = 0.0;
uniform float glitch = 0.0;
uniform float yaw = 0.0;
uniform float dust = 0.0;
uniform vec4 tint : source_color = vec4(0.86, 0.95, 1.0, 0.035);
uniform vec4 alarm : source_color = vec4(1.0, 0.25, 0.2, 0.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// A soft blur around p from two rings of samples (about the look of mip level 4.5 at 1600 px wide).
vec3 blur_ring(vec2 p) {
	vec3 s = textureLod(screen_tex, p, 0.0).rgb * 0.12;
	for (int i = 0; i < 8; i++) {
		float a = float(i) * 0.7853982 + 0.39;
		vec2 d = vec2(cos(a), sin(a) * 1.78);
		s += textureLod(screen_tex, p + d * 0.007, 0.0).rgb * 0.055;
		s += textureLod(screen_tex, p + d * 0.015, 0.0).rgb * 0.055;
	}
	return s;
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - 0.5;
	float r2 = dot(c, c);
	vec2 duv = 0.5 + c * (1.0 - 0.06 * r2 * strength);
	if (glitch > 0.0) {
		float band = floor(uv.y * 28.0 + floor(TIME * 18.0) * 3.0);
		float on = step(0.72, hash(vec2(band, floor(TIME * 24.0))));
		duv.x += (hash(vec2(band, 7.0 + floor(TIME * 30.0))) - 0.5) * 0.05 * glitch * on;
	}
	float ab = aberration * strength * (0.4 + 3.0 * r2) + glitch * 0.007;
	vec3 col;
	col.r = textureLod(screen_tex, duv + c * ab, 0.0).r;
	col.g = textureLod(screen_tex, duv, 0.0).g;
	col.b = textureLod(screen_tex, duv - c * ab, 0.0).b;
	float fm = fog * smoothstep(0.5, 1.0, uv.y) * (0.65 + 0.35 * sin(uv.x * 7.0 + TIME * 0.6));
	fm += dust * 0.35 * smoothstep(0.35, 0.9, length(c * vec2(1.6, 1.0)));
	if (fm > 0.002) {
		vec3 blurred = blur_ring(duv);
		col = mix(col, blurred * 1.08 + vec3(0.035, 0.035, 0.04), clamp(fm, 0.0, 0.85));
	}
	col = mix(col, tint.rgb, tint.a * strength);
	float sx = uv.x + uv.y * 0.42 - (0.12 + fract(yaw * 0.11) * 1.4);
	col += vec3(0.85, 0.92, 1.0) * smoothstep(0.07, 0.0, abs(sx)) * 0.045 * strength;
	col *= 1.0 - 0.028 * strength * (0.5 + 0.5 * sin(FRAGCOORD.y * 2.4));
	float v = smoothstep(0.98, 0.32, length(c * vec2(1.0, 1.32)));
	col *= mix(1.0, v, vignette * strength);
	col = mix(col, alarm.rgb, alarm.a * (0.55 + 0.45 * sin(TIME * 9.0)) * smoothstep(0.3, 0.75, length(c * vec2(1.0, 1.3))));
	col *= 1.0 - flicker * (0.35 + 0.65 * hash(vec2(floor(TIME * 45.0), 3.0)));
	COLOR = vec4(col, 1.0);
}
