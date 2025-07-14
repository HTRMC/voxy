#version 460 core

layout(binding = 0) uniform sampler2D blockModelAtlas;
layout(binding = 2) uniform sampler2D depthTex;

layout(location = 0) out vec4 colour;
void main() {

    uint hash = gl_PrimitiveID*1231421+123141;
    hash ^= hash>>16;
    hash = hash*1231421+123141;
    hash ^= hash>>16;
    hash = hash * 1827364925 + 123325621;
    colour = vec4(float(hash&63u)/63, float((hash>>6)&63u)/63, float((hash>>12)&63u)/63, 0);
}