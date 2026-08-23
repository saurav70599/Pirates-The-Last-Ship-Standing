shader_type spatial;
render_mode cull_disabled, depth_draw_opaque;

uniform sampler2D albedo_texture : source_color, filter_linear_mipmap;

// Wind Uniforms
uniform float wind_speed = 2.0;
uniform float wind_strength = 0.15;
uniform vec2 wind_direction = vec2(1.0, 0.5);

void vertex() {
    // Get the world position of the plant to offset the wind phase (so plants don't all move in perfect sync)
    vec3 world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
    
    // Calculate a gentle sway using a sine wave
    float sway = sin(TIME * wind_speed + world_pos.x * 0.5 + world_pos.z * 0.5);
    
    // We only want the top of the plant to sway, not the roots.
    // By multiplying by VERTEX.y, the movement gets stronger the higher the vertex is.
    float weight = max(0.0, VERTEX.y); 
    
    VERTEX.x += sway * wind_direction.x * wind_strength * weight;
    VERTEX.z += sway * wind_direction.y * wind_strength * weight;
}

void fragment() {
    vec4 tex_color = texture(albedo_texture, UV);
    ALBEDO = tex_color.rgb;
    ALPHA = tex_color.a;
    ALPHA_SCISSOR_THRESHOLD = 0.5; // Keeps the leaf edges crisp
}