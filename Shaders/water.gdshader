shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// The wave math here MUST match ocean_buoyancy.gd, including the shore scaling (height_scale / push_scale), the per-wave seed, the wind angle, the amplitude/wiggle noise, and the island wrap / lee shadow weights.

uniform vec4 shallow_color : source_color = vec4(0.10, 0.55, 0.55, 1.0);
uniform vec4 deep_color : source_color = vec4(0.02, 0.10, 0.25, 1.0);
uniform float depth_fade_distance : hint_range(0.1, 50.0) = 8.0;

uniform sampler2D normal_map : hint_normal;
uniform float normal_scroll_speed = 0.05;
uniform float normal_tiling = 8.0;

uniform float fresnel_power : hint_range(0.1, 8.0) = 3.0;
uniform float roughness_val : hint_range(0.0, 1.0) = 0.05;

uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

uniform vec2 wave1_dir = vec2(1.0, 0.2);
uniform float wave1_steepness = 0.30;
uniform float wave1_length = 17.3;

uniform vec2 wave2_dir = vec2(0.8, 0.65);
uniform float wave2_steepness = 0.20;
uniform float wave2_length = 9.1;

uniform vec2 wave3_dir = vec2(1.0, -0.35);
uniform float wave3_steepness = 0.14;
uniform float wave3_length = 4.3;

uniform vec2 wave4_dir = vec2(0.5, 1.0);
uniform float wave4_steepness = 0.08;
uniform float wave4_length = 2.1;

uniform vec2 wave5_dir = vec2(1.0, 0.9);
uniform float wave5_steepness = 0.10;
uniform float wave5_length = 11.7;

uniform vec2 wave6_dir = vec2(0.9, -0.7);
uniform float wave6_steepness = 0.06;
uniform float wave6_length = 5.9;

uniform float wind_angle : hint_range(-180.0, 180.0) = 0.0;
uniform float wave_variation : hint_range(0.0, 0.9) = 0.5;
uniform float wiggle_strength : hint_range(0.0, 1.5) = 0.5;
uniform float wiggle_cells : hint_range(1.0, 12.0) = 4.0;
uniform float variation_scale = 0.018;
uniform float variation_speed = 0.02;

uniform vec2 island_center = vec2(0.0, 0.0);
uniform float island_radius = 70.0;
uniform float island_wrap_range = 90.0;
uniform float island_wrap_strength : hint_range(0.0, 1.0) = 0.85;
uniform float lee_shadow : hint_range(0.0, 1.0) = 0.6;

uniform float distortion_strength = 2.5;
uniform float chop_strength = 0.4;

uniform sampler2D terrain_heightmap : hint_default_black, filter_linear, repeat_disable;
uniform vec2 terrain_origin = vec2(-256.0, -256.0);
uniform vec2 terrain_size = vec2(512.0, 512.0);
uniform float terrain_min_height = -100.0;
uniform float terrain_max_height = 20.0;

uniform float shore_depth = 8.0;
uniform float break_depth = 2.0;
uniform float shoal_height_gain = 0.6;
uniform float shoal_steepen = 0.6;
uniform float surf_height_decay = 0.25;
uniform float runup_height = 0.6;
uniform float swash_film = 0.03;

uniform vec4 foam_color : source_color = vec4(0.95, 0.98, 1.0, 1.0);
uniform float foam_edge_width = 0.4;
uniform float foam_scale = 1.5;

varying vec3 world_pos;
varying vec3 world_normal;
varying float v_foam;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float value_noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

float fbm_noise(vec2 p, float time) {
	float n = 0.0;
	n += value_noise(p * 1.0 + time * 0.05) * 0.5;
	n += value_noise(p * 2.3 - time * 0.08) * 0.25;
	n += value_noise(p * 4.1 + time * 0.13) * 0.125;
	return n;
}

float terrain_height_at(vec2 world_xz) {
	vec2 uv = (world_xz - terrain_origin) / terrain_size;
	float inside = step(0.0, uv.x) * step(uv.x, 1.0) * step(0.0, uv.y) * step(uv.y, 1.0);
	float h = mix(terrain_min_height, terrain_max_height, textureLod(terrain_heightmap, uv, 0.0).r);
	return mix(terrain_min_height, h, inside);
}

vec3 gerstner_wave(vec2 dir, float steepness, float wavelength, vec2 pos, float time, float height_scale, float push_scale, float seed, inout vec3 tangent, inout vec3 binormal) {
	float k = 2.0 * PI / wavelength;
	float c = sqrt(9.8 / k);

	float amp_n = value_noise(pos * variation_scale + vec2(seed * 17.3, seed * 9.7) + time * variation_speed);
	float amp = mix(1.0 - wave_variation, 1.0 + wave_variation * 0.5, amp_n);

	float warp_n = value_noise(pos / (wavelength * wiggle_cells) + vec2(seed * 5.1, seed * 13.9) - time * variation_speed);
	vec2 d0 = normalize(dir);
	float wa = radians(wind_angle);
	vec2 d = vec2(d0.x * cos(wa) - d0.y * sin(wa), d0.x * sin(wa) + d0.y * cos(wa));
	float phase_off = seed * 2.399 + (warp_n - 0.5) * 4.0 * PI * wiggle_strength;

	vec2 rel = pos - island_center;
	float r = length(rel);
	vec2 d_in = -rel / max(r, 0.001);
	float w_radial = island_wrap_strength * (1.0 - smoothstep(island_radius, island_radius + island_wrap_range, r));

	float along = dot(rel, d);
	float lateral = abs(dot(rel, vec2(-d.y, d.x)));
	float lee = smoothstep(0.0, island_radius, along) * (1.0 - smoothstep(island_radius * 0.8, island_radius * 1.6, lateral));
	float w_planar = (1.0 - w_radial) * (1.0 - lee_shadow * lee);

	float f_p = k * (dot(d, pos) - c * time) + phase_off;
	float f_r = k * (-r - c * time) + phase_off;
	float sp = sin(f_p);
	float cp = cos(f_p);
	float sr = sin(f_r);
	float cr = cos(f_r);

	float steep_v = steepness * height_scale * amp;
	float steep_h = steepness * push_scale * amp;
	float av = steep_v / k;
	float ah = steep_h / k;

	tangent += w_planar * vec3(
		-d.x * d.x * steep_h * sp,
		d.x * steep_v * cp,
		-d.x * d.y * steep_h * sp
	) + w_radial * vec3(
		-d_in.x * d_in.x * steep_h * sr,
		d_in.x * steep_v * cr,
		-d_in.x * d_in.y * steep_h * sr
	);
	binormal += w_planar * vec3(
		-d.x * d.y * steep_h * sp,
		d.y * steep_v * cp,
		-d.y * d.y * steep_h * sp
	) + w_radial * vec3(
		-d_in.x * d_in.y * steep_h * sr,
		d_in.y * steep_v * cr,
		-d_in.y * d_in.y * steep_h * sr
	);

	return w_planar * vec3(
		d.x * ah * cp,
		av * sp,
		d.y * ah * cp
	) + w_radial * vec3(
		d_in.x * ah * cr,
		av * sr,
		d_in.y * ah * cr
	);
}

void vertex() {
	vec2 pos2d = VERTEX.xz;
	float time = TIME;

	vec3 flat_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float water_level = flat_world.y;
	float terrain_h = terrain_height_at(flat_world.xz);
	float depth = water_level - terrain_h;

	float shoal = 1.0 - smoothstep(break_depth, shore_depth, depth);
	float surf = 1.0 - smoothstep(0.0, break_depth, depth);
	float height_scale = (1.0 + shoal_height_gain * shoal) * mix(1.0, surf_height_decay, surf);
	float push_scale = (1.0 + shoal_steepen * shoal) * (1.0 - 0.6 * surf);

	float distortion = fbm_noise(pos2d * 0.15, time) * distortion_strength;
	vec2 distorted_pos = pos2d + vec2(distortion, distortion * 0.7);

	vec3 tangent = vec3(1.0, 0.0, 0.0);
	vec3 binormal = vec3(0.0, 0.0, 1.0);
	vec3 offset = vec3(0.0);

	offset += gerstner_wave(wave1_dir, wave1_steepness, wave1_length, distorted_pos, time, height_scale, push_scale, 1.0, tangent, binormal);
	offset += gerstner_wave(wave2_dir, wave2_steepness, wave2_length, distorted_pos, time, height_scale, push_scale, 2.0, tangent, binormal);
	offset += gerstner_wave(wave3_dir, wave3_steepness, wave3_length, distorted_pos, time, height_scale, push_scale, 3.0, tangent, binormal);
	offset += gerstner_wave(wave4_dir, wave4_steepness, wave4_length, distorted_pos, time, height_scale, push_scale, 4.0, tangent, binormal);
	offset += gerstner_wave(wave5_dir, wave5_steepness, wave5_length, distorted_pos, time, height_scale, push_scale, 5.0, tangent, binormal);
	offset += gerstner_wave(wave6_dir, wave6_steepness, wave6_length, distorted_pos, time, height_scale, push_scale, 6.0, tangent, binormal);

	float chop_noise = fbm_noise(pos2d * 0.6, time * 1.5) - 0.5;
	offset.y += chop_noise * chop_strength * (1.0 - surf);

	float crest = clamp(0.5 + 0.5 * offset.y / 1.4, 0.0, 1.0);

	float reach = runup_height * pow(crest, 1.5);
	float wet = 1.0 - smoothstep(reach * 0.7, reach + 0.001, -depth);
	float sheet_y = mix(terrain_h - 0.5, terrain_h + swash_film, wet) - water_level;
	float land_w = 1.0 - smoothstep(-0.1, 0.4, depth);
	offset = mix(offset, vec3(0.0, sheet_y, 0.0), land_w);

	float break_zone = 1.0 - smoothstep(break_depth * 0.8, break_depth * 1.3, depth);
	v_foam = clamp(break_zone * smoothstep(0.55, 0.95, crest) + surf * 0.3, 0.0, 1.0);

	VERTEX += offset;
	NORMAL = normalize(mix(cross(binormal, tangent), vec3(0.0, 1.0, 0.0), land_w));

	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 warp = vec2(fbm_noise(world_pos.xz * 0.05, TIME), fbm_noise(world_pos.xz * 0.05 + 31.7, TIME)) - 0.35;
	vec2 uv1 = UV * normal_tiling + warp * 0.6 + vec2(TIME * normal_scroll_speed, TIME * normal_scroll_speed * 0.5);
	vec2 uv2 = UV * normal_tiling * 1.7 - warp * 0.4 - vec2(TIME * normal_scroll_speed * 0.7, TIME * normal_scroll_speed * 0.3);
	vec3 n1 = texture(normal_map, uv1).rgb * 2.0 - 1.0;
	vec3 n2 = texture(normal_map, uv2).rgb * 2.0 - 1.0;
	vec3 detail_normal = normalize(vec3(n1.xy + n2.xy, n1.z + n2.z));

	NORMAL_MAP = detail_normal * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 0.6;

	float depth_tex = texture(depth_texture, SCREEN_UV).r;
	vec4 world_pos_from_depth = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0, depth_tex, 1.0);
	world_pos_from_depth.xyz /= world_pos_from_depth.w;
	float depth_meters = max(world_pos.y - world_pos_from_depth.y, 0.0);
	float depth_diff = clamp(depth_meters / depth_fade_distance, 0.0, 1.0);

	ALBEDO = mix(shallow_color.rgb, deep_color.rgb, depth_diff);

	float fresnel = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), fresnel_power);
	SPECULAR = 0.5;
	ROUGHNESS = mix(roughness_val, 0.3, fresnel);
	METALLIC = 0.0;

	ALPHA = mix(0.85, 1.0, depth_diff);

	float foam_edge = 1.0 - smoothstep(0.0, foam_edge_width, depth_meters);
	float foam = clamp(v_foam + foam_edge, 0.0, 1.0);
	vec2 fp = world_pos.xz * foam_scale;
	float foam_noise = value_noise(fp + vec2(TIME * 0.2, 0.0)) * 0.65 + value_noise(fp * 2.7 - vec2(0.0, TIME * 0.3)) * 0.35;
	float foam_mask = smoothstep(1.0 - foam, 1.0 - foam + 0.2, foam_noise);

	ALBEDO = mix(ALBEDO, foam_color.rgb, foam_mask);
	ALPHA = mix(ALPHA, 1.0, foam_mask);
	ROUGHNESS = mix(ROUGHNESS, 0.85, foam_mask);
}