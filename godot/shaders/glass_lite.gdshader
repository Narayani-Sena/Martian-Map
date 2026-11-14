// Panel look without the blur: same parameters as glass.gdshader, but nothing reads the screen, so
// the renderer skips the full-screen copy and blur chain every frame (a real cost on integrated GPUs).
// The panel's own colour is made more opaque instead, so text stays readable over the 3D view.
shader_type canvas_item;

uniform float blur = 3.0;   // unused here; kept so the two shaders can be swapped on one material
uniform float grain = 0.018;
uniform float scan = 0.022;
uniform float opacity_gain = 1.45;

void fragment() {
	vec4 src = COLOR;
	vec3 col = src.rgb;
	col *= 1.0 - scan * (0.5 + 0.5 * sin(FRAGCOORD.y * 1.7));
	COLOR = vec4(col, clamp(src.a * opacity_gain, 0.0, 0.94));
}
