shader_type canvas_item;
// Under the ancient lake (feature A4): the visor view tinted by the water above, light shafts swaying down from the
// surface, darker with depth and towards the edges.

uniform float strength = 0.0;   // 0 = dry, 1 = under water
uniform float depth_m = 0.0;    // metres of water over the crew

void fragment() {
	vec2 uv = UV;
	float dk = clamp(depth_m / 60.0, 0.0, 1.0);
	vec3 top = mix(vec3(0.42, 0.78, 0.8), vec3(0.15, 0.4, 0.46), dk);
	vec3 bot = mix(vec3(0.05, 0.2, 0.24), vec3(0.01, 0.07, 0.1), dk);
	vec3 c = mix(top, bot, smoothstep(0.0, 1.0, uv.y));
	float x = uv.x + (1.0 - uv.y) * 0.18 * sin(TIME * 0.21);
	float shafts = pow(0.5 + 0.5 * sin(x * 31.0 + sin(x * 9.0 + TIME * 0.5) * 2.4 + TIME * 0.35), 6.0);
	c += vec3(0.75, 0.95, 1.0) * shafts * (1.0 - uv.y) * (1.0 - dk * 0.8) * 0.22;
	float vig = smoothstep(0.35, 0.95, length(uv - 0.5) * 1.3);
	float a = (0.16 + 0.2 * uv.y + 0.2 * dk) * strength;
	COLOR = vec4(c * (1.0 - 0.4 * vig), clamp(a + vig * 0.25 * strength, 0.0, 0.85));
}
