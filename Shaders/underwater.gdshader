shader_type spatial;
render_mode unshaded, cull_disabled, depth_test_disabled;

// --- 1. IMPORT SHARED WAVE MATH ---
#include "res://others/wave_math.gdshaderinc"

uniform float height_offset = 0.0;
uniform vec3 underwater_color : source_color = vec3(0.02, 0.18, 0.25);
uniform float absorption_strength : hint_range(0.0, 2.0) = 0.35; 
uniform float deep_tint_strength : hint_range(0.0, 1.0) = 0.65; 

uniform float refraction_amount : hint_range(0.0, 0.015) = 0.004;
uniform float refraction_speed : hint_range(0.0, 3.0) = 0.7;
uniform float water_level_fudge : hint_range(-1.5, 1.5) = 0.0;
uniform sampler2D shore_mask : hint_default_white, filter_linear;
uniform float ocean_size = 2000.0;
uniform float tide_speed : hint_range(0.0, 5.0) = 1.0;
uniform float tide_amount : hint_range(0.0, 0.2) = 0.03;

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;
uniform sampler2D DEPTH_TEXTURE : hint_depth_texture, filter_linear_mipmap;

void vertex() {
    // 1. Force the quad to act as a perfect fullscreen filter 
    // Z is set to 0.5 to safely sit in the middle of the clipping frustum
    POSITION = vec4(VERTEX.xy, 0.5, 1.0);
}

void fragment() {
    // 2. GET ACTIVE CAMERA LOCATION
    // This dynamically finds the exact world position of WHICHEVER camera is looking
    vec3 cam_pos = INV_VIEW_MATRIX[3].xyz;

    // 3. RECONSTRUCT FRAGMENT WORLD POSITION
    // We shoot a ray through the screen to find where this exact pixel sits in 3D space
    vec2 ndc_xy = SCREEN_UV * 2.0 - 1.0;
    vec4 view_pt = INV_PROJECTION_MATRIX * vec4(ndc_xy, 0.5, 1.0);
    view_pt.xyz /= view_pt.w;
    vec3 ray_dir_view = normalize(view_pt.xyz);
    vec3 ray_dir_world = (INV_VIEW_MATRIX * vec4(ray_dir_view, 0.0)).xyz;
    
    // Project slightly forward to simulate the physical lens
    vec3 frag_world_pos = cam_pos + ray_dir_world * 0.1;

    // 4. DYNAMIC SPLIT-SCREEN LOGIC (UPDATED WITH MASK)
    vec2 mask_uv = (frag_world_pos.xz / ocean_size) + 0.5;
    float base_shore_weight = textureLod(shore_mask, mask_uv, 0.0).r;
    float tide = sin(TIME * tide_speed) * tide_amount;
    float shore_weight = clamp(base_shore_weight + tide, 0.0, 1.0);
    
    float raw_frag_wave = -map(vec3(frag_world_pos.x, 0.0, frag_world_pos.z), TIME) + height_offset + water_level_fudge;
    float frag_wave_h = mix(-5.0, raw_frag_wave, shore_weight);
    
    if (frag_world_pos.y > frag_wave_h) {
        discard; // Pixel is physically above water. Shut off the fog.
    }

    // 5. REFRACTION WOBBLE
    vec2 uv_screen = SCREEN_UV;
    vec2 noise_dir = vec2(
        noise(uv_screen * 12.0 + TIME * refraction_speed * vec2(1.0, 0.4)),
        noise(uv_screen * 12.0 + TIME * refraction_speed * vec2(0.6, 1.0))
    ) * 2.0 - 1.0;
    
    vec2 offset = noise_dir * refraction_amount;
    vec2 uv_distorted = uv_screen + offset;
    vec3 scene_color = texture(SCREEN_TEXTURE, uv_distorted).rgb;

    // 6. BACKGROUND DEPTH RECONSTRUCTION
    float depth_raw = texture(DEPTH_TEXTURE, uv_distorted).x;
    vec3 ndc_bg = vec3(uv_distorted * 2.0 - 1.0, depth_raw);
    
    #if CURRENT_RENDERER == RENDERER_COMPATIBILITY
        ndc_bg.z = depth_raw * 2.0 - 1.0;
    #endif
    
    vec4 view_bg = INV_PROJECTION_MATRIX * vec4(ndc_bg, 1.0);
    view_bg.xyz /= view_bg.w;
    vec3 world_bg = (INV_VIEW_MATRIX * vec4(view_bg.xyz, 1.0)).xyz;

    // 7. THICKNESS AND CEILING RAYCAST (UPDATED WITH MASK)
    float thickness = length(world_bg - cam_pos);
    
    if (ray_dir_world.y > 0.0) {
        vec2 cam_mask_uv = (cam_pos.xz / ocean_size) + 0.5;
        float cam_base_shore_weight = textureLod(shore_mask, cam_mask_uv, 0.0).r;
        float cam_shore_weight = clamp(cam_base_shore_weight + tide, 0.0, 1.0);
        
        float raw_cam_wave = -map(vec3(cam_pos.x, 0.0, cam_pos.z), TIME) + height_offset + water_level_fudge;
        float cam_wave_h = mix(-5.0, raw_cam_wave, cam_shore_weight);
        
        float dist_to_ceiling = (cam_wave_h - cam_pos.y) / ray_dir_world.y;
        if (dist_to_ceiling > 0.0) {
            thickness = min(thickness, dist_to_ceiling);
        }
    }

    // 8. FINAL COLOR BLENDING
    float transmittance = exp(-thickness * absorption_strength);
    vec3 tinted = mix(scene_color, underwater_color, deep_tint_strength);
    vec3 final_color = tinted * transmittance;

    float fog = 1.0 - exp(-thickness * absorption_strength * 0.7);
    final_color = mix(final_color, underwater_color, fog * 0.85);

    ALBEDO = final_color;
}