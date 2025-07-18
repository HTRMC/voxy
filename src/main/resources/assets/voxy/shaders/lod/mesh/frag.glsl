#version 460 core

#extension GL_NV_fragment_shader_barycentric : require

layout(binding = 0) uniform sampler2D blockModelAtlas;
layout(binding = 2) uniform sampler2D depthTex;

perprimitiveNV in uvec4 primData;
perprimitiveNV in vec4 uvData;

layout(location = 0) out vec4 outColour;

vec4 uint2vec4RGBA(uint colour) {
    return vec4((uvec4(colour)>>uvec4(24,16,8,0))&uvec4(0xFF))/255.0;
}

bool useMipmaps() {
    return (primData.x&2u)==0u;
}

bool useTinting() {
    return (primData.x&4u)!=0u;
}

bool useCutout() {
    return (primData.x&1u)==1u;
}

vec4 computeColour(vec4 colour) {
    //Conditional tinting, TODO: FIXME: REPLACE WITH MASK OR SOMETHING, like encode data into the top bit of alpha
    if (useTinting() && abs(colour.r-colour.g) < 0.02f && abs(colour.g-colour.b) < 0.02f) {
        colour *= uint2vec4RGBA(primData.z).yzwx;
    }
    return (colour * uint2vec4RGBA(primData.y)) + vec4(0,0,0,float(primData.w&0xFFu)/255);
}


uint getFace() {
    return (primData.w>>8)&7u;
}

vec2 getBaseUV() {
    uint face = getFace();
    uint modelId = primData.x>>16;
    vec2 modelUV = vec2(modelId&0xFFu, (modelId>>8)&0xFFu)*(1.0/(256.0));
    return modelUV + (vec2(face>>1, face&1u) * (1.0/(vec2(3.0, 2.0)*256.0)));
}

bool isTri0() {
    return (gl_PrimitiveID&(1<<31))==0;
}

void main() {
    bool tri0 = isTri0();
    //1,2,0
    //1,3,2
    //vec2((corner>>1)&1u, corner&1u)

    //vec2(0,gl_BaryCoordNV.x)+vec2(gl_BaryCoordNV.y,0)+vec2(0,0);
    //vec2(0,gl_BaryCoordNV.x)+vec2(gl_BaryCoordNV.y,gl_BaryCoordNV.y)+vec2(gl_BaryCoordNV.z,0);


    vec2 uv = fma(mix(gl_BaryCoordNV.zx+gl_BaryCoordNV.y, gl_BaryCoordNV.yx, bvec2(tri0)), uvData.zw, uvData.xy);
    //Need to interpolate

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

    if (any(notEqual(clamp(tile, vec2(0), vec2((primData.x>>8)&0xFu, (primData.x>>12)&0xFu)), tile))) {
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


    /*
    uint hash = gl_PrimitiveID*1231421+123141;
    hash ^= hash>>16;
    hash = hash*1231421+123141;
    hash ^= hash>>16;
    hash = hash * 1827364925 + 123325621;
    outColour = vec4(float(hash&15u)/15, float((hash>>4)&15u)/15, float((hash>>8)&15u)/15, 0);
    */
}