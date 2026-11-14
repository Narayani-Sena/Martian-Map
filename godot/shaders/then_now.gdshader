shader_type canvas_item;
// Then and now (feature E3): the rover's photo left of the wipe, the live terrain render right of it, a bright
// line at the wipe with a soft glow so the eye can follow the ridges across it.

uniform float split = 0.5;

void fragment() {
	vec4 c = texture(TEXTURE, UV);
	float d = abs(UV.x - split);
	float line = 1.0 - smoothstep(0.0012, 0.0028, d);
	float glow = (1.0 - smoothstep(0.0, 0.02, d)) * 0.35;
	float photo = 1.0 - smoothstep(split - 0.0008, split + 0.0008, UV.x);
	vec3 col = mix(c.rgb, vec3(1.0, 0.88, 0.62), line);
	COLOR = vec4(col, clamp(photo + line + glow * (1.0 - photo), 0.0, 1.0));
	if (photo < 0.5 && line < 0.01) {
		COLOR = vec4(1.0, 0.86, 0.6, glow * 0.6);
	}
}
