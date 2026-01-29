#version 300 es
precision mediump float;

// Inputs from vertex shader
in vec2 v_texcoord;
in vec3 v_normal;
in vec4 v_color;

// Uniforms
uniform sampler2D u_texture;
uniform vec3 u_lightDir;
uniform float u_ambient;

// Output
out vec4 fragColor;

void main() {
    // Sample texture
    vec4 texColor = texture(u_texture, v_texcoord);
    
    // Simple diffuse lighting
    float diffuse = max(dot(v_normal, u_lightDir), 0.0);
    float light = u_ambient + diffuse;
    
    // Combine
    vec3 color = texColor.rgb * v_color.rgb * light;
    fragColor = vec4(color, texColor.a * v_color.a);
}
