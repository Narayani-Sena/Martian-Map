// AR breadcrumbs on the ground in walk mode. INSTANCE_CUSTOM.x = metres along the route;
// a bright pulse runs forward along the chevrons, and the part already walked fades.
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

uniform vec4 color : source_color = vec4(0.31, 0.82, 1.0, 1.0);
uniform float intensity = 2.2;
uniform float walked = -1.0;
uniform float near_fade = 5.0;

varying float v_d;
varying float v_cam;

void vertex() {
	v_d = INSTANCE_CUSTOM.x;
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_cam = length(wp - CAMERA_POSITION_WORLD);
}

void fragment() {
	float wave = 0.3 + 0.7 * pow(0.5 + 0.5 * sin(v_d * 0.2 - TIME * 4.0), 6.0);
	float done = (walked >= 0.0 && v_d < walked) ? 0.18 : 1.0;
	float fade = smoothstep(near_fade * 0.6, near_fade * 1.4, v_cam) * (1.0 - smoothstep(60.0, 140.0, v_cam));
	ALBEDO = color.rgb * intensity * wave * done * fade;
}
