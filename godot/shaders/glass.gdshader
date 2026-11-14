// Frosted-glass panel: blurs whatever is behind it (the 3D scene) and tints it with the
// StyleBox colour. Faint animated grain and scanlines give it a display feel.
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur = 3.0;
uniform float grain = 0.018;
uniform float scan = 0.022;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec4 src = COLOR;
	vec3 bg = textureLod(screen_tex, SCREEN_UV, blur).rgb;
	vec3 col = mix(bg, src.rgb, clamp(src.a, 0.0, 1.0));
	col += (hash(FRAGCOORD.xy + vec2(fract(TIME * 7.0) * 100.0)) - 0.5) * grain;
	col *= 1.0 - scan * (0.5 + 0.5 * sin(FRAGCOORD.y * 1.7));
	COLOR = vec4(col, smoothstep(0.0, 0.05, src.a));
}
