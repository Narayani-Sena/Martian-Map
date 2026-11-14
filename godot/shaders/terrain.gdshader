// Gale crater terrain: one camera-centred "clipmap" grid displaced on the GPU.
// Inside the site the 1 m HiRISE DTM is used; outside, the 200 m regional model (Mount Sharp),
// blended across a band at the site edge. Inside the site, lighting uses the pipeline's 0.8 m
// normal map (east, north, up), so every boxwork ridge is shaded even where the mesh is coarse.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx, cull_back;

uniform sampler2D dem_tex : filter_nearest, repeat_disable;
uniform sampler2D reg_tex : filter_nearest, repeat_disable;
// the same two height models through a trilinear sampler, for coarse vertices (see height_lod)
uniform sampler2D dem_lin : filter_linear_mipmap, repeat_disable;
uniform sampler2D reg_lin : filter_linear_mipmap, repeat_disable;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D albedo_reg_tex : source_color, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_disable;
uniform sampler2D overlay_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform bool has_normal_map = false;
// Close-up ground detail from two small tiling noise textures (TerrainClipmap.detail_textures): a
// Perlin normal map (xy = slope of the bumps) and value noise. One fetch per scale replaces the ~50
// per-pixel hash evaluations the procedural noise needed.
uniform sampler2D detail_nrm : filter_linear_mipmap, repeat_enable;
uniform sampler2D detail_val : filter_linear_mipmap, repeat_enable;
const float DETAIL_CELLS = 32.0;   // noise cells across one tile of the detail textures
const mat2 ROT_A = mat2(vec2(0.8, -0.6), vec2(0.6, 0.8));      // turn each scale a little so the
const mat2 ROT_B = mat2(vec2(0.28, 0.96), vec2(-0.96, 0.28));  // tiles never line up

uniform vec4 site_rect = vec4(-1624.0, 1632.0, 3248.0, 3264.0); // x_min, y_max, width, height (m)
uniform float site_res = 1.0;
uniform ivec2 dem_dims = ivec2(3248, 3264);
uniform vec4 reg_rect = vec4(-47400.0, 47400.0, 94800.0, 94800.0);
uniform float reg_res = 200.0;
uniform ivec2 reg_dims = ivec2(474, 474);
uniform float reg_offset = 0.0;
uniform bool has_regional = true;
uniform float elev_ref = -3898.0;
uniform float edge_blend = 90.0;
// Height filtering for coarse vertices: both models carry mipmaps (averaged heights). A vertex samples
// the level matching its real spacing in metres (UV.x x the grid's scale k), so far terrain is a smooth
// surface rather than point samples of 1 m detail that shimmer as the grid slides. Only the uniform
// inner rings (UV.x = 1) really double their spacing when k steps x2 with the camera height; there the
// filter follows lod_k, the same scale without the steps, so a level change doesn't pop. (Further out,
// the spacing at a given distance hardly changes with k, and scaling the filter by lod_k there made it
// jump x2 at every step.)
uniform float lod_k = 1.0;
uniform int dem_max_lod = 0;
uniform int reg_max_lod = 0;

uniform vec3 tint : source_color = vec3(1.0);
uniform vec3 reg_tint = vec3(1.5, 0.8, 0.52);     // CTX is greyscale: colour it like the HiRISE mosaic
uniform vec3 site_tint = vec3(1.52, 0.82, 0.55);  // same for the greyscale strips of the HiRISE mosaic
uniform float albedo_gain = 1.0;
uniform float saturation = 1.0;
uniform float detail_strength = 1.0;
uniform float normal_strength = 1.0;

uniform float overlay_opacity = 0.0;
uniform float overlay_reveal = 1.0e9;
uniform float overlay_edge = 35.0;   // soft edge of the reveal (m); 2.5 for the data flashlight (feature A7)
uniform vec3 wb_gain = vec3(1.0);     // geologist's white balance (feature G6): Earth-like light
uniform vec2 overlay_origin = vec2(0.0);
uniform vec3 accent : source_color = vec3(0.31, 0.82, 1.0);

// Ways home (feature A1): flow_tex R = line strength, G = minutes from home / 150 (x254, 255 = no way home).
// Pulses run down every line toward the haven, one every FLOW_EVERY minutes of walking.
uniform sampler2D flow_tex : filter_linear, repeat_disable;
uniform float flow_strength = 0.0;
const float FLOW_EVERY = 1.4;

// Flood the crater (feature A4): world Y of the ancient lake's surface (-1e9 = no lake), and its one body of water
// on the regional grid (R > 0.5 = lake), so a low plain outside the crater rim stays dry.
uniform float lake_y = -1.0e9;
uniform sampler2D lake_tex : filter_linear, repeat_disable;

// the shrinking world (feature A3): in the suit-leak drill, ground the crew can no longer walk to and get home from
// on the secondary oxygen pack dims and turns red behind a glowing edge that tightens as the minutes run down
uniform float reach_min = -1.0;      // minutes of oxygen left (< 0: off)
uniform sampler2D reach_tex : filter_nearest, repeat_disable;   // minutes x 10: R high byte, G low byte; A = 0 impossible
uniform vec4 reach_rect = vec4(0.0, 0.0, 1.0, 1.0);             // x_min, y_max, width, height (m) of the 4 m grid
uniform ivec2 reach_dims = ivec2(1, 1);

uniform float contour_strength = 0.0;
uniform float contour_interval = 5.0;
uniform float contour_glow = 0.0;   // synthetic vision (feature B6): the lines glow, readable in dust or dusk
uniform float grid_strength = 0.0;
uniform float grid_spacing = 100.0;

uniform float scan_radius = -1.0;
uniform vec2 scan_origin = vec2(0.0);

uniform int marker_count = 0;
uniform vec4 markers[16];        // x, y, radius (m), selected (0/1)
uniform vec4 marker_colors[16];  // rgb, intensity

varying vec3 v_world;

// minutes from home -> colour (white at home, cyan, sky blue, blue, violet), as in server/flow.py
vec3 flow_ramp(float m) {
	vec3 c0 = vec3(1.0, 0.969, 0.91);
	vec3 c1 = vec3(0.737, 0.941, 1.0);
	vec3 c2 = vec3(0.463, 0.8, 1.0);
	vec3 c3 = vec3(0.408, 0.573, 1.0);
	vec3 c4 = vec3(0.58, 0.44, 0.988);
	vec3 c5 = vec3(0.769, 0.361, 0.925);
	if (m < 15.0) return mix(c0, c1, m / 15.0);
	if (m < 30.0) return mix(c1, c2, (m - 15.0) / 15.0);
	if (m < 60.0) return mix(c2, c3, (m - 30.0) / 30.0);
	if (m < 90.0) return mix(c3, c4, (m - 60.0) / 30.0);
	return mix(c4, c5, clamp((m - 90.0) / 40.0, 0.0, 1.0));
}

float dem_fetch(ivec2 p) { return texelFetch(dem_tex, clamp(p, ivec2(0), dem_dims - ivec2(1)), 0).r; }
float reg_fetch(ivec2 p) { return texelFetch(reg_tex, clamp(p, ivec2(0), reg_dims - ivec2(1)), 0).r; }

float dem_h(vec2 xy) {
	vec2 cr = vec2(xy.x - site_rect.x, site_rect.y - xy.y) / site_res - 0.5;
	vec2 c0 = floor(cr);
	vec2 f = cr - c0;
	ivec2 i = ivec2(c0);
	float a = dem_fetch(i);
	float b = dem_fetch(i + ivec2(1, 0));
	float c = dem_fetch(i + ivec2(0, 1));
	float d = dem_fetch(i + ivec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float reg_h(vec2 xy) {
	vec2 cr = vec2(xy.x - reg_rect.x, reg_rect.y - xy.y) / reg_res - 0.5;
	vec2 c0 = floor(cr);
	vec2 f = cr - c0;
	ivec2 i = ivec2(c0);
	float a = reg_fetch(i);
	float b = reg_fetch(i + ivec2(1, 0));
	float c = reg_fetch(i + ivec2(0, 1));
	float d = reg_fetch(i + ivec2(1, 1));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) + reg_offset;
}

// Filtered height for coarse vertices: ONE trilinear fetch (the texture unit blends 8 texels across two
// mip levels). The exact 4-fetch bilinear (dem_h) is kept where vertices are 1 m apart, so the ground you
// stand on still matches the CPU heights the walker uses.
float dem_lod(vec2 xy, float lod) {
	vec2 uv = vec2(xy.x - site_rect.x, site_rect.y - xy.y) / site_rect.zw;
	return textureLod(dem_lin, uv, clamp(lod, 0.0, float(max(dem_max_lod - 1, 0)))).r;
}

float reg_lod(vec2 xy, float lod) {
	vec2 uv = vec2(xy.x - reg_rect.x, reg_rect.y - xy.y) / reg_rect.zw;
	return textureLod(reg_lin, uv, clamp(lod, 0.0, float(max(reg_max_lod - 1, 0)))).r + reg_offset;
}

float inside_w(vec2 xy) {
	float dx = min(xy.x - site_rect.x, site_rect.x + site_rect.z - xy.x);
	float dy = min(site_rect.y - xy.y, xy.y - (site_rect.y - site_rect.w));
	return clamp(min(dx, dy) / edge_blend, 0.0, 1.0);
}

float height_abs(vec2 xy) {
	float w = inside_w(xy);
	if (w >= 1.0 || !has_regional) {
		return dem_h(xy);
	}
	float r = reg_h(xy);
	if (w <= 0.0) {
		return r;
	}
	return mix(r, dem_h(xy), smoothstep(0.0, 1.0, w));
}

// height filtered to a vertex spacing of `spacing` metres (exact 1 m model where spacing <= 1 m)
float height_lod(vec2 xy, float spacing) {
	if (dem_max_lod <= 1 || spacing <= site_res * 1.05) {
		return height_abs(xy);
	}
	float w = inside_w(xy);
	float ls = log2(spacing / site_res);
	if (w >= 1.0 || !has_regional) {
		return dem_lod(xy, ls);
	}
	float r = reg_max_lod > 1 ? reg_lod(xy, log2(max(spacing / reg_res, 1.0))) : reg_h(xy);
	if (w <= 0.0) {
		return r;
	}
	return mix(r, dem_lod(xy, ls), smoothstep(0.0, 1.0, w));
}

// value noise with one noise cell per unit of p (0..1)
float tnoise(vec2 p) {
	return texture(detail_val, p / DETAIL_CELLS).r;
}

// slope of the noise bumps at p, roughly the size the old analytic gradient had
vec2 tgrad(vec2 p) {
	return (texture(detail_nrm, p / DETAIL_CELLS).rg * 2.0 - 1.0) * 1.6;
}

void vertex() {
	vec3 w = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec2 xy = vec2(w.x, -w.z);
	float k = length(MODEL_MATRIX[0].xyz);
	float spacing = max(UV.x * k, lod_k);
	float h = height_lod(xy, spacing) - elev_ref;
	VERTEX.y = h;
	// coarse normal over the local mesh spacing (UV.x), used for far terrain and shadow bias
	float e = max(site_res * 2.0, UV.x * k);
	float hx = height_lod(xy + vec2(e, 0.0), spacing) - elev_ref;
	float hy = height_lod(xy + vec2(0.0, e), spacing) - elev_ref;
	vec3 n = normalize(vec3(-(hx - h), e, hy - h));
	NORMAL = normalize(vec3(n.x * k, n.y, n.z * k));
	v_world = vec3(w.x, h, w.z);
}

float reach_need(ivec2 p) {
	ivec2 q = clamp(p, ivec2(0), reach_dims - ivec2(1));
	vec4 t = texelFetch(reach_tex, q, 0);
	return t.a < 0.5 ? 999.0 : min((t.r * 255.0 * 256.0 + t.g * 255.0) / 10.0, 999.0);
}

void fragment() {
	vec2 xy = vec2(v_world.x, -v_world.z);
	float cam_d = length(v_world - CAMERA_POSITION_WORLD);
	float w = inside_w(xy);
	vec2 uv_site = vec2((xy.x - site_rect.x) / site_rect.z, (site_rect.y - xy.y) / site_rect.w);

	vec3 n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	if (has_normal_map && w > 0.0) {
		vec3 t = texture(normal_tex, uv_site).rgb * 2.0 - 1.0;
		t.xy *= normal_strength;
		vec3 nm = normalize(vec3(t.x, t.z, -t.y));
		n = normalize(mix(n, nm, w));
	}
	float steep = 1.0 - n.y;
	float near_f = (1.0 - smoothstep(10.0, 120.0, cam_d)) * w * detail_strength;
	float sandy = 0.0;
	if (near_f > 0.001) {
		// sand ripples on flat ground, knobbly bedrock on slopes
		sandy = (1.0 - smoothstep(0.04, 0.16, steep)) * smoothstep(0.35, 0.65, tnoise(xy * 0.11));
		vec2 g = tgrad(xy * 0.85) * 0.22 + tgrad(ROT_A * xy * 3.6 + 7.1) * 0.12 + tgrad(ROT_B * xy * 12.5 + 3.3) * 0.05;
		vec2 rd = normalize(vec2(0.83, 0.55));
		float rp = dot(xy, rd) * 4.6 + tnoise(xy * 0.6 + 11.0) * 5.0;
		vec2 rg = rd * cos(rp) * 0.3 * sandy;
		g = mix(g, g * 0.35, sandy) + rg;
		n = normalize(n + vec3(-g.x, 0.0, g.y) * near_f);
	}
	NORMAL = normalize((VIEW_MATRIX * vec4(n, 0.0)).xyz);

	vec3 alb = texture(albedo_tex, uv_site).rgb;
	// HiRISE colour only covers a central swath of each image: recolour grey pixels, and fill
	// the mosaic's no-data holes from the regional imagery
	float a_lum = dot(alb, vec3(0.299, 0.587, 0.114));
	float a_sat = max(alb.r, max(alb.g, alb.b)) - min(alb.r, min(alb.g, alb.b));
	alb = mix(vec3(a_lum) * site_tint, alb, smoothstep(0.012, 0.05, a_sat));
	vec2 uv_reg = vec2((xy.x - reg_rect.x) / reg_rect.z, (reg_rect.y - xy.y) / reg_rect.w);
	float hole = 1.0 - smoothstep(0.003, 0.02, a_lum);
	if ((w < 1.0 || hole > 0.0) && has_regional) {
		vec3 ar = texture(albedo_reg_tex, uv_reg).rgb;
		float l = dot(ar, vec3(0.3333));
		ar = vec3(l) * reg_tint * (0.88 + 0.24 * tnoise(xy * 0.0021));
		alb = mix(alb, ar, hole);
		alb = mix(ar, alb, smoothstep(0.0, 1.0, w));
	}
	if (near_f > 0.001) {
		float grain = tnoise(xy * 9.0 + 5.0) * 0.6 + tnoise(ROT_A * xy * 31.0) * 0.4;
		vec3 sand_col = alb * vec3(1.06, 1.0, 0.93);
		vec3 rock_col = alb * vec3(0.7, 0.66, 0.64);
		vec3 detail = mix(alb * (0.92 + 0.16 * grain), sand_col, sandy * 0.6);
		detail = mix(detail, rock_col, smoothstep(0.22, 0.55, steep) * 0.35);
		alb = mix(alb, detail, near_f);
	}
	float lum = dot(alb, vec3(0.299, 0.587, 0.114));
	alb = mix(vec3(lum), alb, saturation) * tint * albedo_gain * wb_gain;

	vec3 emit = vec3(0.0);

	// the ancient lake: ground under the water reads as a lake bed (darker and bluer the more water lies in front of
	// it), caustics in the shallows, wet ground just above the waterline and a pale line where the water meets it
	if (lake_y > -1.0e8) {
		float fw_h = max(fwidth(v_world.y), 0.03);
		if (texture(lake_tex, uv_reg).r > 0.5) {
			float ld = lake_y - v_world.y;   // metres of water over this ground
			if (ld > 0.0) {
				float path = CAMERA_POSITION_WORLD.y < lake_y ? cam_d : ld * 2.2;
				float dk = 1.0 - exp(-path / 26.0);
				alb = mix(alb * vec3(0.7, 0.86, 0.9), vec3(0.03, 0.13, 0.16), dk * 0.88);
				float c1 = tnoise(xy * 0.31 + vec2(TIME * 0.07, TIME * 0.05));
				float c2 = tnoise(ROT_A * xy * 0.43 - vec2(TIME * 0.06, -TIME * 0.04));
				float caus = pow(clamp(1.0 - abs(c1 - c2) * 2.4, 0.0, 1.0), 7.0);
				emit += vec3(0.55, 0.92, 1.0) * caus * exp(-ld / 7.0) * 0.3 * (1.0 - smoothstep(60.0, 500.0, cam_d));
			} else {
				alb *= mix(0.68, 1.0, smoothstep(0.0, 1.8, -ld));
			}
			float shore = 1.0 - smoothstep(0.0, 0.35 + fw_h * 1.5, abs(ld));
			emit += vec3(0.85, 0.97, 1.0) * shore * 0.3 * (1.0 - smoothstep(1500.0, 6000.0, cam_d));
		}
	}

	// draped analysis layer with a radial "scan" reveal
	if (overlay_opacity > 0.001 && w > 0.0) {
		vec4 ov = texture(overlay_tex, uv_site);
		float d = length(xy - overlay_origin);
		float shown = 1.0 - smoothstep(overlay_reveal - overlay_edge, overlay_reveal, d);
		float a = ov.a * overlay_opacity * shown * w;
		alb = mix(alb, ov.rgb, a);
		emit += ov.rgb * a * 0.10;
		if (overlay_reveal < 9000.0) {
			float front = exp(-pow((d - overlay_reveal) / max(min(5.0, overlay_edge * 0.5), cam_d * 0.004), 2.0));
			emit += accent * front * (overlay_edge < 10.0 ? 0.55 : 2.2);   // a soft torch rim for the data flashlight
		}
	}

	// ways home: pulses flowing down the network toward the haven
	if (flow_strength > 0.001 && w > 0.0) {
		vec4 fl = texture(flow_tex, uv_site);
		if (fl.g < 0.995 && fl.r > 0.03) {
			float mins = fl.g * 255.0 / 254.0 * 150.0;
			float ph = fract(mins / FLOW_EVERY + TIME * 0.55);
			float pulse = smoothstep(0.0, 0.06, ph) * (1.0 - smoothstep(0.1, 0.42, ph));
			float fade = 1.0 - smoothstep(3000.0, 9000.0, cam_d);
			emit += flow_ramp(mins) * fl.r * flow_strength * (0.12 + 1.9 * pulse) * fade;
		}
	}

	// contour lines
	if (contour_strength > 0.001) {
		float hc = v_world.y + elev_ref;
		float fw = max(fwidth(hc), 0.001);
		float f = abs(fract(hc / contour_interval + 0.5) - 0.5) * contour_interval;
		float minor = 1.0 - smoothstep(0.0, fw * 1.4, f);
		float big = contour_interval * 5.0;
		float f2 = abs(fract(hc / big + 0.5) - 0.5) * big;
		float major = 1.0 - smoothstep(0.0, fw * 2.2, f2);
		float fade = 1.0 - smoothstep(2500.0, 9000.0, cam_d);
		alb = mix(alb, vec3(0.03, 0.04, 0.05), max(minor * 0.3, major * 0.55) * contour_strength * fade);
		emit += vec3(1.0, 0.86, 0.62) * major * 0.12 * contour_strength * fade;
		emit += vec3(0.35, 0.9, 1.0) * (minor * 0.55 + major * 1.1) * contour_glow * fade * (1.0 - smoothstep(250.0, 1400.0, cam_d));
	}

	// 100 m survey grid
	if (grid_strength > 0.001) {
		vec2 gp = xy / grid_spacing;
		vec2 gw = max(fwidth(gp), vec2(1e-5));
		vec2 gl = abs(fract(gp - 0.5) - 0.5) / gw;
		float line = 1.0 - min(min(gl.x, gl.y), 1.0);
		emit += accent * line * 0.35 * grid_strength * w;
	}

	// expanding scan pulse
	if (scan_radius > 0.0) {
		float d = length(xy - scan_origin);
		float wid = max(4.0, cam_d * 0.003);
		float ring = exp(-pow((d - scan_radius) / wid, 2.0));
		float trail = smoothstep(scan_radius - 160.0, scan_radius, d) * step(d, scan_radius) * 0.18;
		float fade = 1.0 - smoothstep(700.0, 2600.0, scan_radius);
		emit += accent * (ring * 1.8 + trail) * fade;
	}

	// ground rings under the habitat / stops / shelters
	for (int i = 0; i < marker_count; i++) {
		vec4 m = markers[i];
		float d = length(xy - m.xy);
		float r = m.z;
		if (d > r * 1.8) {
			continue;
		}
		vec4 c = marker_colors[i];
		float wid = max(r * 0.05, cam_d * 0.0025);
		float ring = 1.0 - smoothstep(0.0, wid, abs(d - r));
		float ph = fract(TIME * 0.45 + float(i) * 0.37);
		float wave = (1.0 - smoothstep(0.0, wid * 0.8, abs(d - r * ph))) * (1.0 - ph);
		float fill = (1.0 - smoothstep(0.0, r, d)) * (0.06 + 0.1 * m.w);
		float sel = m.w * (1.0 - smoothstep(0.0, wid, abs(d - r * 1.35))) * (0.6 + 0.4 * sin(TIME * 5.0));
		emit += c.rgb * c.a * (ring + wave * 0.9 + fill + sel);
	}

	// the shrinking world: out of reach on what is left of the oxygen
	if (reach_min >= 0.0) {
		vec2 ruv = vec2((xy.x - reach_rect.x) / reach_rect.z, (reach_rect.y - xy.y) / reach_rect.w);
		if (ruv.x > 0.0 && ruv.x < 1.0 && ruv.y > 0.0 && ruv.y < 1.0) {
			vec2 pc = ruv * vec2(reach_dims) - 0.5;
			ivec2 p0 = ivec2(floor(pc));
			vec2 f = pc - floor(pc);
			float n00 = reach_need(p0);
			float n10 = reach_need(p0 + ivec2(1, 0));
			float n01 = reach_need(p0 + ivec2(0, 1));
			float n11 = reach_need(p0 + ivec2(1, 1));
			float need = mix(mix(n00, n10, f.x), mix(n01, n11, f.x), f.y);
			// next to a no-go cell the field jumps to 999: no edge there (no-go ground is simply dimmed)
			float valid = step(max(max(n00, n10), max(n01, n11)), 998.0);
			float over = need - reach_min;
			float fw = clamp(fwidth(need), 0.02, 1.5);
			float out_f = smoothstep(-fw, fw, over);
			alb = mix(alb, alb * vec3(0.5, 0.26, 0.24), out_f * 0.82);
			float edge = (1.0 - smoothstep(0.0, fw * 2.0 + 0.12, abs(over))) * valid;
			float pulse = 0.75 + 0.25 * sin(TIME * 4.0);
			emit += vec3(1.0, 0.24, 0.16) * edge * 1.8 * pulse;
			emit += vec3(1.0, 0.1, 0.05) * out_f * 0.03;
		}
	}

	ALBEDO = alb;
	ROUGHNESS = 0.94;
	SPECULAR = 0.2;
	EMISSION = emit;
}
