shader_type spatial;

// --- 1. IMPORT SHARED WAVE MATH ---
#include "res://others/wave_math.gdshaderinc" 

varying vec3 world_vert;
varying vec3 vertex_normal_world;

uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

uniform float max_depth : hint_range(0.1, 50.0, 0.1) = 10.0;
uniform float water_level : hint_range(-10.0, 10.0, 0.1) = 0.0;
uniform sampler2D shore_mask : hint_default_white, filter_linear;
uniform float ocean_size = 2000.0;
uniform float tide_speed : hint_range(0.0, 5.0) = 1.0;
uniform float tide_amount : hint_range(0.0, 0.2) = 0.03;

uniform vec3 underwater_fog_color : source_color = vec3(0.0, 0.05, 0.10);
uniform float fade_start_depth : hint_range(0.0, 50.0, 0.1) = 0.5;

uniform vec3 base_tint_color : source_color = vec3(0.439, 0.973, 1.0);
uniform vec3 deep_color : source_color = vec3(0.0, 0.341, 0.29);

// Beer-Lambert absorption
uniform vec3 water_absorption : source_color = vec3(0.3, 0.06, 0.02);

uniform float roughness : hint_range(0.0, 1.0) = 0.125;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float specular : hint_range(0.0, 1.0) = 0.5;

uniform int ITER_FRAGMENT = 5;

// --- REFRACTION & LOD UNIFORMS ---
uniform float refraction_strength : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float refraction_distance_fade : hint_range(0.0, 100.0, 1.0) = 5.0;
uniform float normal_epsilon : hint_range(0.001, 1.0) = 0.01;
uniform float normal_smoothness_dist : hint_range(0.0, 1000.0) = 50.0;

// --- CAUSTICS UNIFORMS ---
uniform sampler2D caustics_texture : filter_linear_mipmap, repeat_enable;
uniform float caustics_scale : hint_range(0.1, 10.0, 0.1) = 2.0;
uniform float caustics_speed : hint_range(0.0, 1.0, 0.01) = 0.1;
uniform float caustics_intensity : hint_range(0.0, 2.0, 0.1) = 0.8;
uniform float caustics_depth_fade : hint_range(0.0, 1.0, 0.01) = 0.7;

// --- FOAM UNIFORMS (FIXED) ---
uniform vec3 foam_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float foam_depth_start : hint_range(0.0, 5.0, 0.01) = 0.8;
uniform float foam_depth_end   : hint_range(0.0, 5.0, 0.01) = 0.0;
uniform float foam_noise_scale : hint_range(0.0, 10.0, 0.01) = 2.0;
uniform float foam_noise_speed : hint_range(0.0, 2.0, 0.01) = 1.0;
uniform float foam_cutoff      : hint_range(0.0, 1.0, 0.01) = 0.7;
uniform float foam_crest_threshold : hint_range(0.0, 1.0, 0.01) = 0.7;
uniform float foam_crest_amount    : hint_range(0.0, 10.0, 0.1) = 2.0;
uniform vec3 foam_edge_color : source_color = vec3(0.0, 0.0, 0.05);
uniform vec2 foam_edge_offset = vec2(0.02, 0.02);
uniform float voronoi_scale   : hint_range(0.0, 50.0) = 9.0;
uniform float voronoi_strength : hint_range(0.0, 8.0) = 0.8;

// --- CUSTOM PBR BLEND UNIFORMS ---
uniform vec3 horizon_color : source_color = vec3(0.75, 0.91, 1.0); 
uniform float horizon_distance : hint_range(50.0, 500.0, 10.0) = 250.0;
uniform float horizon_falloff : hint_range(0.1, 5.0, 0.1) = 2.0;
uniform float glitter_strength : hint_range(0.0, 10.0, 0.1) = 3.0;
uniform float glitter_size : hint_range(100.0, 1000.0, 10.0) = 400.0;
uniform float glitter_threshold : hint_range(0.0, 1.0, 0.01) = 0.8;
uniform vec3 glitter_color : source_color = vec3(1.0, 1.0, 1.0);

// --- 2. LOCAL FUNCTIONS ---

float map_detailed(vec3 p, float time) {
    float freq = sea_freq;
    float amp = sea_height;
    float choppy = sea_choppy;

    vec2 uv = p.xz;
    uv.x *= 0.75;
    float h = 0.0;

    for(int i = 0; i < ITER_FRAGMENT; i++) {
        float d = sea_octave((uv + time * sea_speed) * freq, choppy);
        d += sea_octave((uv - time * sea_speed) * freq, choppy);
        h += d * amp;
        uv *= octave_m;
        freq *= 1.9;
        amp *= 0.22;
        choppy = mix(choppy,1.0,0.2);
    }
    return p.y - h;
}

vec3 get_normal_detailed(vec3 p, float eps, float time) {
    vec3 n;
    n.y = map_detailed(p, time);
    n.x = map_detailed(vec3(p.x + eps, p.y, p.z), time) - n.y;
    n.z = map_detailed(vec3(p.x, p.y, p.z + eps), time) - n.y;
    n.y = eps;
    return normalize(n);
}

float hash13(vec3 p) {
    uvec3 q = uvec3(ivec3(p)) * uvec3(1597334677u, 3812015801u, 2798796415u);
    uint n = (q.x ^ q.y ^ q.z) * 1597334677u;
    return float(n) * (1.0 / 4294967295.0);
}

float hash3d(vec3 p) { return hash13(p); }

vec2 hash22(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

float voronoi(vec2 uv) {
    vec2 n = floor(uv);
    vec2 f = fract(uv);
    float m_dist = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            vec2 g = vec2(float(i), float(j));
            vec2 o = hash22(n + g);
            o = 0.5 + 0.5 * sin(TIME * foam_noise_speed + 6.2831 * o);
            vec2 r = g - f + o;
            float d = dot(r, r);
            m_dist = min(m_dist, d);
        }
    }
    return m_dist;
}

float noise3d(in vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(
        mix(
            mix(hash3d(i + vec3(0.0, 0.0, 0.0)), hash3d(i + vec3(1.0, 0.0, 0.0)), f.x),
            mix(hash3d(i + vec3(0.0, 1.0, 0.0)), hash3d(i + vec3(1.0, 1.0, 0.0)), f.x), f.y),
        mix(
            mix(hash3d(i + vec3(0.0, 0.0, 1.0)), hash3d(i + vec3(1.0, 0.0, 1.0)), f.x),
            mix(hash3d(i + vec3(0.0, 1.0, 1.0)), hash3d(i + vec3(1.0, 1.0, 1.0)), f.x), f.y), f.z);
}

float fbm_voronoi(vec2 uv) {
    float v = 0.0;
    float a = 0.5;
    vec2 shift = vec2(100.0);
    mat2 rot = mat2(vec2(cos(0.5), sin(0.5)), vec2(-sin(0.5), cos(0.5)));
    for (int i = 0; i < 3; i++) {
        float val = 1.0 - voronoi(uv);
        val = pow(val, 2.0); // sharpen bubbles
        v += a * val;
        uv = rot * uv * 2.0 + shift;
        a *= 0.5;
    }
    return v;
}

float get_linear_depth(sampler2D d_tex, vec2 uv, mat4 inv_proj) {
    float depth = texture(d_tex, uv).x;
    vec3 ndc = vec3(uv * 2.0 - 1.0, depth);
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
    ndc.z = depth * 2.0 - 1.0;
#endif
    vec4 view = inv_proj * vec4(ndc, 1.0);
    return -view.z / view.w;
}

// --- 3. VERTEX DISPLACEMENT ---

void vertex() {
    vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    
    // 1. Calculate the mask UV
    vec2 mask_uv = (world_pos.xz / ocean_size) + 0.5; 
    float base_shore_weight = textureLod(shore_mask, mask_uv, 0.0).r;
    
    // 2. THE MAGIC: Animate the mask to create an ebb and flow!
    // This creates a gentle pulse that moves the water up and down the slope of the beach.
    float tide = sin(TIME * tide_speed) * tide_amount;
    
    // Apply the tide to the mask and ensure it stays safely between 0.0 and 1.0
    float shore_weight = clamp(base_shore_weight + tide, 0.0, 1.0);
    
    // 3. Calculate the normal wave height
    float raw_wave = -map(world_pos, TIME);
    
    // 4. Mix the deep ocean waves with the animated underground shoreline
    float final_height = mix(-5.0, raw_wave, shore_weight);
    
    VERTEX.y = final_height;
    world_vert = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;

    // 5. Recalculate normals using the new animated depth
    float vertex_eps = 0.1;
    float h_x = mix(-5.0, -map(world_pos + vec3(vertex_eps, 0.0, 0.0), TIME), shore_weight);
    float h_z = mix(-5.0, -map(world_pos + vec3(0.0, 0.0, vertex_eps), TIME), shore_weight);

    vertex_normal_world = normalize(vec3(final_height - h_x, vertex_eps, final_height - h_z));
}

// --- 4. FRAGMENT PIXEL LOGIC ---

void fragment() {
    // --- DISTANCE LOD NORMALS ---
    float dist_to_cam = length(VERTEX);
    float lod_epsilon = max(normal_epsilon, dist_to_cam * 0.005);
    vec3 detailed_normal = get_normal_detailed(world_vert, lod_epsilon, TIME);
    float smooth_factor = clamp((dist_to_cam - normal_smoothness_dist) / 200.0, 0.0, 1.0);
    vec3 final_normal = mix(detailed_normal, vertex_normal_world, smooth_factor);
    NORMAL = (VIEW_MATRIX * vec4(final_normal, 0.0)).xyz;
	
    // --- DEPTH CALCULATIONS ---
    float water_linear_depth = -VERTEX.z;
    float bg_linear_depth = get_linear_depth(DEPTH_TEXTURE, SCREEN_UV, INV_PROJECTION_MATRIX);
    float thickness = max(0.0, bg_linear_depth - water_linear_depth);
	
    // --- REFRACTION DISTORTION & GHOSTING FIX ---
    vec3 view_vertex_normal = (VIEW_MATRIX * vec4(vertex_normal_world, 0.0)).xyz;
    vec2 normal_offset = NORMAL.xy - view_vertex_normal.xy;
    float ref_dist_factor = clamp(refraction_distance_fade / max(0.1, dist_to_cam), 0.0, 1.0);
    float ref_depth_mask = smoothstep(0.0, max_depth, thickness);
    
    vec2 refraction_offset = normal_offset * refraction_strength * ref_dist_factor * ref_depth_mask * 0.05;
    vec2 distorted_uv = SCREEN_UV + refraction_offset;

    float distorted_bg_depth = get_linear_depth(DEPTH_TEXTURE, distorted_uv, INV_PROJECTION_MATRIX);
    if (distorted_bg_depth < water_linear_depth - 0.001) {
        distorted_uv = SCREEN_UV;
        distorted_bg_depth = bg_linear_depth;
    }

    // --- OVERRIDE THICKNESS AND SCREEN COLOR ---
    vec3 screen_color = texture(SCREEN_TEXTURE, distorted_uv).rgb;
    thickness = max(0.0, distorted_bg_depth - water_linear_depth);
    float depth_ratio = clamp((thickness - fade_start_depth) / max(0.001, max_depth - fade_start_depth), 0.0, 1.0);

    // --- CAUSTICS ---
    vec4 bg_ndc = vec4(distorted_uv * 2.0 - 1.0, texture(DEPTH_TEXTURE, distorted_uv).x, 1.0);
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
        bg_ndc.z = bg_ndc.z * 2.0 - 1.0;
    #endif
    vec4 bg_world = INV_VIEW_MATRIX * INV_PROJECTION_MATRIX * bg_ndc;
    vec3 bg_world_pos = bg_world.xyz / bg_world.w;

    if (thickness > 0.0) {
        vec2 caustics_uv1 = bg_world_pos.xz * caustics_scale;
        caustics_uv1.x += TIME * caustics_speed;
        
        vec2 caustics_uv2 = bg_world_pos.xz * caustics_scale * 0.7;
        caustics_uv2.y -= TIME * caustics_speed * 0.8;
        
        float caustics_sample1 = texture(caustics_texture, caustics_uv1).r;
        float caustics_sample2 = texture(caustics_texture, caustics_uv2).r;
        float caustics_value = caustics_sample1 * caustics_sample2;
        
        float caustics_fade = 1.0 - clamp(thickness * caustics_depth_fade, 0.0, 1.0);
        screen_color += caustics_value * caustics_intensity * caustics_fade;
    }

    // --- ABSORPTION & COLOR BLENDING ---
    vec3 transmittance = exp(-thickness * water_absorption);
    vec3 water_volume_color = mix(base_tint_color, deep_color, depth_ratio);
    vec3 apparent_seabed_color = screen_color * water_volume_color; 
    
    ALBEDO = mix(underwater_fog_color, apparent_seabed_color, transmittance);

    // --- FOAM LOGIC (FIXED) ---
    float foam_mask_primary = 0.0;
    float foam_mask_shadow  = 0.0;

    float depth_foam_factor = smoothstep(foam_depth_start, foam_depth_end, thickness);
    float wave_crest_factor = smoothstep(foam_crest_threshold, foam_crest_threshold - 0.1, final_normal.y);
    wave_crest_factor *= foam_crest_amount;
    float foam_level = clamp(depth_foam_factor + wave_crest_factor, 0.0, 1.0);

    vec2 flow_uv = world_vert.xz * 0.5 + TIME * 0.05 * foam_noise_speed;
    vec2 warp = vec2(
        noise(flow_uv),
        noise(flow_uv + vec2(5.2, 1.3))
    ) * 0.5;

    if (distorted_bg_depth > water_linear_depth) {
        vec2 foam_uv = world_vert.xz * foam_noise_scale + warp;
        
        float emergence_noise = noise3d(vec3(world_vert.xz * 0.5, TIME * 0.2 * foam_noise_speed));
        emergence_noise = smoothstep(0.0, 1.0, emergence_noise * 0.5 + 0.5);
        float effective_emergence = mix(emergence_noise, 1.0, foam_level);

        float foam_noise_val = fbm_voronoi(foam_uv);
        foam_noise_val *= effective_emergence;

        vec2 foam_uv_shadow = (world_vert.xz + foam_edge_offset) * foam_noise_scale + warp;
        float foam_noise_shadow_val = fbm_voronoi(foam_uv_shadow);
        foam_noise_shadow_val *= effective_emergence;

        float combined_noise  = foam_noise_val + foam_level;
        float combined_shadow = foam_noise_shadow_val + foam_level;
        
        foam_mask_primary = smoothstep(foam_cutoff + 0.5, foam_cutoff + 0.6, combined_noise);
        float shadow_shape = smoothstep(foam_cutoff + 0.5, foam_cutoff + 0.6, combined_shadow);
        foam_mask_shadow = clamp(shadow_shape - foam_mask_primary, 0.0, 1.0);
    }

    float voronoi_val = 1.0 - sqrt(voronoi(world_vert.xz * voronoi_scale + warp));
    voronoi_val = smoothstep(0.2, 0.8, voronoi_val);
    float bubble_alpha = 1.0 - clamp((1.0 - voronoi_val) * voronoi_strength, 0.0, 1.0);

    ALBEDO = mix(ALBEDO, foam_edge_color, foam_mask_shadow);
    ALBEDO = mix(ALBEDO, foam_color, foam_mask_primary * bubble_alpha);
	
    // --- DISTANCE HORIZON BLEND (KEPT) ---
    float horizon_blend = smoothstep(horizon_distance * 0.5, horizon_distance, dist_to_cam);
    horizon_blend = pow(horizon_blend, horizon_falloff);
	
    ALBEDO = mix(ALBEDO, horizon_color, horizon_blend);
    
    // Mix the base roughness with the foam mask first, then apply the distance horizon logic
    float foam_roughness = mix(roughness, 0.8, clamp((foam_mask_primary * bubble_alpha) + foam_mask_shadow, 0.0, 1.0));
    ROUGHNESS = mix(mix(foam_roughness, 0.35, smooth_factor), 1.0, horizon_blend);
    
    METALLIC = mix(metallic, 0.0, horizon_blend);
    SPECULAR = mix(specular, 0.0, horizon_blend);
}

// --- 5. CUSTOM LIGHTING LOGIC ---

void light() {
    float NdotL = max(0.0, dot(NORMAL, LIGHT));
    vec3 base_lighting = ALBEDO * LIGHT_COLOR * NdotL * ATTENUATION;

    vec3 H = normalize(VIEW + LIGHT);
    float NdotH = max(0.0, dot(NORMAL, H));
    float glitter = pow(NdotH, glitter_size);
    glitter = smoothstep(glitter_threshold, 1.0, glitter) * glitter_strength;
    
    vec3 glitter_light = glitter_color * glitter * LIGHT_COLOR * ATTENUATION;

    DIFFUSE_LIGHT += base_lighting;
    SPECULAR_LIGHT += glitter_light; 
}