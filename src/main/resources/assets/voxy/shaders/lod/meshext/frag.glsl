#version 460 core

layout(binding = 0) uniform sampler2D blockModelAtlas;
layout(binding = 2) uniform sampler2D depthTex;

struct PerPrimData {
    uvec4 data;
};

layout(location=1) perprimitiveEXT PerPrimData primIn;

layout(location = 0) out vec4 outColour;

vec4 uint2vec4RGBA(uint colour) {
    return vec4((uvec4(colour)>>uvec4(24,16,8,0))&uvec4(0xFF))/255.0;
}

bool useMipmaps() {
    return (primIn.data.x&2u)==0u;
}

bool useTinting() {
    return (primIn.data.x&4u)!=0u;
}

bool useCutout() {
    return (primIn.data.x&1u)==1u;
}

vec4 computeColour(vec4 colour) {
    //Conditional tinting, TODO: FIXME: REPLACE WITH MASK OR SOMETHING, like encode data into the top bit of alpha
    if (useTinting() && abs(colour.r-colour.g) < 0.02f && abs(colour.g-colour.b) < 0.02f) {
        colour *= uint2vec4RGBA(primIn.data.z).yzwx;
    }
    return (colour * uint2vec4RGBA(primIn.data.y)) + vec4(0,0,0,float(primIn.data.w&0xFFu)/255);
}


uint getFace() {
    return (primIn.data.w>>8)&7u;
}

vec2 getBaseUV() {
    uint face = getFace();
    uint modelId = primIn.data.x>>16;
    vec2 modelUV = vec2(modelId&0xFFu, (modelId>>8)&0xFFu)*(1.0/(256.0));
    return modelUV + (vec2(face>>1, face&1u) * (1.0/(vec2(3.0, 2.0)*256.0)));
}


void main() {
    vec2 uv = vec2(0);

    //Tile is the tile we are in
    vec2 tile;
    vec2 uv2 = modf(uv, tile)*(1.0/(vec2(3.0,2.0)*256.0));
    vec4 colour;
    vec2 texPos = uv2 + getBaseUV();
    if (useMipmaps()) {
        vec2 uvSmol = uv*(1.0/(vec2(3.0,2.0)*256.0));
        vec2 dx = dFdx(uvSmol);//vec2(lDx, dDx);
        vec2 dy = dFdy(uvSmol);//vec2(lDy, dDy);
        colour = textureGrad(blockModelAtlas, texPos, dx, dy);
    } else {
        colour = textureLod(blockModelAtlas, texPos, 0);
    }

    if (any(notEqual(clamp(tile, vec2(0), vec2((primIn.data.x>>8)&0xFu, (primIn.data.x>>12)&0xFu)), tile))) {
        discard;
    }

    //Check the minimum bounding texture and ensure we are greater than it
    if (gl_FragCoord.z < texelFetch(depthTex, ivec2(gl_FragCoord.xy), 0).r) {
        discard;
    }


    //Also, small quad is really fking over the mipping level somehow
    if (useCutout() && (textureLod(blockModelAtlas, texPos, 0).a <= 0.1f)) {
        //This is stupidly stupidly bad for divergence
        //TODO: FIXME, basicly what this do is sample the exact pixel (no lod) for discarding, this stops mipmapping fucking it over
        #ifndef DEBUG_RENDER
        discard;
        #endif
    }

    colour = computeColour(colour);

    outColour = colour;
}