// Mars sky: butterscotch by day (suspended dust), a blue glow around the Sun that dominates at
// sunset (dust forward-scatters blue light), stars and the two moons at night.
shader_type sky;
render_mode use_debanding;

uniform vec3 sun_dir = vec3(0.0, 1.0, 0.0);
uniform float tau = 0.5;
uniform float brightness = 1.0;
uniform float star_strength = 1.0;
uniform vec3 wb_gain = vec3(1.0);   // geologist's white balance (feature G6)
uniform vec3 phobos_dir = vec3(0.3, 0.4, -0.86);

float hash(vec3 p) {
	p = fract(p * 0.3183099 + 0.1);
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

vec3 lin(vec3 c) {
	return pow(c, vec3(2.2));
}

void sky() {
	vec3 d = normalize(EYEDIR);
	vec3 s = normalize(sun_dir);
	float h = clamp(d.y, -0.2, 1.0);
	float mu = dot(d, s);
	float se = s.y;
	float day = smoothstep(-0.10, 0.22, se);
	float twi = smoothstep(-0.30, 0.02, se) * (1.0 - smoothstep(0.02, 0.32, se));
	vec3 zenith = lin(vec3(0.36, 0.25, 0.18));
	vec3 horizon = lin(vec3(0.82, 0.63, 0.46));
	vec3 col = mix(horizon, zenith, pow(max(h, 0.0), 0.42));
	float dust = clamp(tau / 0.6, 0.4, 2.0);
	col = mix(col, horizon * 0.95, 0.15 * (dust - 1.0));
	float halo = pow(max(mu, 0.0), 10.0);
	float core = pow(max(mu, 0.0), 80.0);
	vec3 blue = lin(vec3(0.42, 0.60, 0.88));
	col = mix(col, blue, clamp(halo * (0.25 + 0.75 * twi) + core * 0.5, 0.0, 1.0));
	col *= mix(1.0, 0.18 + 0.82 * pow(max(mu * 0.5 + 0.5, 0.0), 3.0), twi);
	vec3 night = vec3(0.0009, 0.0010, 0.0016);
	col = mix(night, col, max(day, twi * 0.55));
	col *= brightness;
	if (!AT_CUBEMAP_PASS) {
		float vis = smoothstep(-0.03, 0.01, se);
		float disc = smoothstep(0.999986, 0.999995, mu);
		col += vec3(1.0, 0.97, 0.92) * disc * 60.0 * vis;
		col += vec3(1.0, 0.9, 0.78) * pow(max(mu, 0.0), 900.0) * 4.0 * vis;
		float star_amt = (1.0 - smoothstep(-0.18, -0.02, se)) * star_strength;
		if (star_amt > 0.0 && d.y > 0.0) {
			vec3 cell = floor(d * 380.0);
			float r = hash(cell);
			float st = step(0.9975, r) * (0.5 + 0.5 * hash(cell + 7.0));
			col += vec3(st) * star_amt * smoothstep(0.0, 0.15, d.y) * 2.0;
			// Phobos: a small grey disc that is only obvious at night
			float pm = dot(d, normalize(phobos_dir));
			col += vec3(0.55, 0.5, 0.45) * smoothstep(0.99996, 0.99998, pm) * star_amt * 0.8;
		}
	}
	col = mix(col, horizon * 0.55 * max(day, 0.05) * brightness, smoothstep(0.0, -0.08, d.y));
	COLOR = col * wb_gain;
}
