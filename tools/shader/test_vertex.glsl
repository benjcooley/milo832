#version 300 es
precision mediump float;

// Vertex attributes
in vec3 a_position;
in vec2 a_texcoord;
in vec3 a_normal;
in vec4 a_color;

// Uniforms
uniform mat4 u_mvpMatrix;
uniform mat4 u_normalMatrix;

// Outputs to fragment shader
out vec2 v_texcoord;
out vec3 v_normal;
out vec4 v_color;

void main() {
    // Transform position
    vec4 pos = vec4(a_position, 1.0);
    
    // Transform normal
    v_normal = normalize(a_normal);
    
    // Pass through texture coords and color
    v_texcoord = a_texcoord;
    v_color = a_color;
}
