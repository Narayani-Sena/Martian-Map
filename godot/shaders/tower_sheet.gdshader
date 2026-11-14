shader_type spatial;
// One sheet of the layer tower (feature A2): a data layer composed over the site imagery by the server, drawn as a
// glass plate with a thin bright frame. Unshaded, so every layer shows its true colours whatever the sun does.
render_mode unshaded, cull_disabled, blend_mix;

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform float fade = 0.0;
uniform float opacity = 0.9;
uniform vec3 edge_col : source_color = vec3(0.31, 0.82, 1.0);

void fragment() {
	vec4 c = texture(tex, UV);
	vec2 e = min(UV, 1.0 - UV);
	float fw = max(fwidth(UV.x), fwidth(UV.y));
	float edge = 1.0 - smoothstep(fw * 1.2, fw * 2.6, min(e.x, e.y));
	ALBEDO = mix(c.rgb, edge_col, edge * 0.85);
	ALPHA = mix(opacity, 1.0, edge) * fade;
}
