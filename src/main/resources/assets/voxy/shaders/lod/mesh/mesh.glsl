#version 460 core

#extension GL_NV_mesh_shader : require

#extension GL_ARB_gpu_shader_int64 : enable

#extension GL_KHR_shader_subgroup_arithmetic: require
#extension GL_KHR_shader_subgroup_basic : require
#extension GL_KHR_shader_subgroup_ballot : require
#extension GL_KHR_shader_subgroup_vote : require


//TODO: finetune the local size and emission size
layout(local_size_x = MESH_SIZE) in;
layout(triangles, max_vertices=(MESH_SIZE*4), max_primitives=(MESH_SIZE*2)) out;

layout(std430) taskNV in Task {
    //Tightly packed, prefix sum + offset
    //uvec4 binA;
    //uvec4 binB;
    uint bins[8];

    vec3 cameraOffset;
    uint lodLvl;

    uint baseQuad;
    uint quadCount;
} task;

layout(location=1) perprimitiveNV out PerPrimData {
    uvec4 data;
} primOut[];


uint getQuadId() {
    uint mid = gl_GlobalInvocationID.x;
    uint cv = (mid<<16)|0xFFFFu;
    /*
    //Funny method
    uvec4 a = mix(uvec4(0), uvec4( 1, 2, 4,  8), lessThanEqual(uvec4(task.bins[0],task.bins[1],task.bins[2],task.bins[3]), uvec4(cv))) +
              mix(uvec4(0), uvec4(16,32,64,128), lessThanEqual(uvec4(task.bins[4],task.bins[5],task.bins[6],task.bins[7]), uvec4(cv)));
    uint act = a.x+a.y+a.z+a.w;
    uint id = findLSB(act^(act>>1));

    //uint point = mix(binB, binA, id<4)[id&3u];
    uint point = task.bins[id];

    return (point&0xFFFFu)+(mid-(point>>16));
    */

    #pragma unroll
    for (uint i = 0; i<7; i++) {
        uint point = task.bins[i];
        if (point<=cv&&cv<task.bins[i+1]) {
            return (point&0xFFFFu)+(mid-(point>>16));
        }
    }
    return -1;



    /*
    for (uint i = 0; i<7; i++) {
        uint point = task.bins[i];
        if (point <= ((mid<<16)|0xFFFFu) && ((mid<<16)|0xFFFFu)<task.bins[i+1]) {
            binId = i;
            return (point&0xFFFFu)+(mid-(point>>16));
        }
    }
    return -1;
    */
}

#import <voxy:lod/quad_format.glsl>
#import <voxy:lod/block_model.glsl>

layout(binding = 0, std140) uniform SceneUniform {
    mat4 MVP;
    ivec3 baseSectionPos;
    uint frameId;
    vec3 cameraSubPos;
    uint pad_;
    vec2 screenSize;
};

layout(binding = 4, std430) readonly restrict buffer QuadBuffer {
    Quad quadData[];
};

layout(binding = 5, std430) readonly restrict buffer ModelBuffer {
    BlockModel modelData[];
};

layout(binding = 6, std430) readonly restrict buffer ModelColourBuffer {
    uint colourData[];
};

layout(binding = 1) uniform sampler2D lightSampler;
vec4 getLighting(uint index) {
    int i2 = int(index);
    return texture(lightSampler, clamp((vec2((i2>>4)&0xF, i2&0xF))/16, vec2(8.0f/255), vec2(248.0f/255)));
}

//===============


vec3 swizzelDataAxis(uint axis, vec3 data) {
    return mix(mix(data.zxy,data.xzy,bvec3(axis==0)),data,bvec3(axis==1));
}

vec4 getFaceSize(uint faceData) {
    float EPSILON = 0.00005f;

    vec4 faceOffsetsSizes = extractFaceSizes(faceData);

    //Expand the quads by a very small amount (because of the subtraction after this also becomes an implicit add)
    faceOffsetsSizes.xz -= vec2(EPSILON);

    //Make the end relative to the start
    faceOffsetsSizes.yw -= faceOffsetsSizes.xz;

    return faceOffsetsSizes;
}

vec3 faceNormal(uint face) {
    //TODO: optimize this garbage
    return vec3(uint((face>>1)==2), uint((face>>1)==0), uint((face>>1)==1)) * (float(int(face)&1)*2-1);
}

uint packVec4(vec4 vec) {
    uvec4 vec_=uvec4(vec*255)<<uvec4(24,16,8,0);
    return vec_.x|vec_.y|vec_.z|vec_.w;
}

//===============
vec3 cornerPos;//Does not include cameraSubPos to get exact need to - cameraSubPos
vec2 axisFaceSize;
uint face;

vec4 faceSize;

uint modelId;
BlockModel model;
uint faceData;
bool isTranslucent;
bool hasAO;
bool isShaded;

void setup(Quad quad) {
    face = extractFace(quad);
    modelId = extractStateId(quad);
    model = modelData[modelId];
    faceData = model.faceData[face];
    isTranslucent = modelIsTranslucent(model);
    hasAO = modelHasMipmaps(model);//TODO: replace with per face AO flag
    isShaded = hasAO;//TODO: make this a per face flag

    ivec2 quadSize = extractSize(quad);

    faceSize = getFaceSize(faceData);

    cornerPos = extractPos(quad);
    float depthOffset = extractFaceIndentation(faceData);
    cornerPos += swizzelDataAxis(face>>1, vec3(faceSize.xz, mix(depthOffset, 1-depthOffset, float(face&1u))));
    cornerPos *= (1<<task.lodLvl);
    cornerPos += task.cameraOffset;

    axisFaceSize = (faceSize.yw + quadSize - 1);

    //uv =

}

vec2 getUvCorner(uint corner) {
    return faceSize.xz + axisFaceSize*vec2((corner>>1)&1u, corner&1u);;
}

uvec4 createQuadData(Quad quad) {
    uint flags = faceHasAlphaCuttout(faceData);

    ivec2 quadSize = extractSize(quad);
    //We need to have a conditional override based on if the model size is < a full face + quadSize > 1
    flags |= uint(any(greaterThan(quadSize, ivec2(1)))) & faceHasAlphaCuttoutOverride(faceData);

    flags |= uint(!modelHasMipmaps(model))<<1;

    //Compute lighting
    vec4 tinting = getLighting(extractLightId(quad));

    //Apply model colour tinting
    uint tintColour = model.colourTint;
    if (modelHasBiomeLUT(model)) {
        tintColour = colourData[tintColour + extractBiomeId(quad)];
    }

    uint conditionalTinting = 0;
    if (tintColour != uint(-1)) {
        flags |= 1u<<2;
        conditionalTinting = tintColour;
    }

    uint addin = 0;
    if (!isTranslucent) {
        tinting.w = 0.0;
        //Encode the face, the lod level and
        uint encodedData = 0;
        encodedData |= face;
        encodedData |= (task.lodLvl<<3);
        encodedData |= uint(hasAO)<<6;
        addin = encodedData;
    }

    //Apply face tint
    if (isShaded) {
        //TODO: make branchless, infact apply ahead of time to the texture itself in ModelManager since that is
        // per face
        if ((face>>1) == 1) {//NORTH, SOUTH
            tinting.xyz *= 0.8f;
        } else if ((face>>1) == 2) {//EAST, WEST
            tinting.xyz *= 0.6f;
        } else if (face == 0) {//DOWN
            tinting.xyz *= 0.5f;
        }
    }



    uvec4 interData;

    interData.x = (modelId<<16) | flags | (uint(quadSize.x-1)<<8) | (uint(quadSize.y-1)<<12);

    interData.y = packVec4(tinting);
    interData.z = conditionalTinting;
    interData.w = addin|(face<<8);

    return interData;
}

vec4 emitVertexPos(int corner) {
    vec3 pointPos = swizzelDataAxis(face>>1,vec3(axisFaceSize*mix(vec2(0),vec2(1<<task.lodLvl),bvec2((corner>>1)&1, corner&1)),0))+cornerPos;
    return MVP*vec4(pointPos, 1.0);
}

#ifdef HAS_STATISTICS
layout(binding = STATISTICS_BUFFER_BINDING, std430) restrict buffer statisticsBuffer {
    uint visibleSectionCounts[5];
    uint quadCounts[5];
};
#endif

void main() {
    if (subgroupElect()) {
        gl_PrimitiveCountNV = 0;
    }
    if (task.quadCount<=gl_GlobalInvocationID.x) {
        return;//dont emit a quad
    }
    uint qid = getQuadId() + task.baseQuad;
    Quad quad = quadData[qid];
    setup(quad);

    subgroupBarrier();


    bool render = dot(faceNormal(face), cornerPos-cameraSubPos) <= 0;

    if (render) {
        vec4 p1 = emitVertexPos(1);
        vec4 p2 = emitVertexPos(2);
        vec4 p0 = emitVertexPos(0);
        vec4 p3 = emitVertexPos(3);

        uvec4 data = createQuadData(quad);

        subgroupBarrier();
        uint triId_ = subgroupExclusiveAdd(2);
        uint triId = triId_;
        uint vertId_ = subgroupExclusiveAdd(4);
        uint vertId = vertId_;
        uint idxId = triId*3;



        //Emit common
        gl_MeshVerticesNV[vertId++].gl_Position = p1;
        gl_MeshVerticesNV[vertId++].gl_Position = p2;

        {
            gl_PrimitiveIndicesNV[idxId++] = vertId_+0;
            gl_PrimitiveIndicesNV[idxId++] = vertId_+1;
            gl_PrimitiveIndicesNV[idxId++] = vertId;

            gl_MeshVerticesNV[vertId++].gl_Position = p0;

            primOut[triId].data = data;
            gl_MeshPrimitivesNV[triId++].gl_PrimitiveID = int(qid);
        }

        {
            gl_PrimitiveIndicesNV[idxId++] = vertId_+0;
            gl_PrimitiveIndicesNV[idxId++] = vertId;
            gl_PrimitiveIndicesNV[idxId++] = vertId_+1;

            gl_MeshVerticesNV[vertId++].gl_Position = p3;

            primOut[triId].data = data;
            gl_MeshPrimitivesNV[triId++].gl_PrimitiveID = int(qid);
        }


        subgroupBarrier();
        uint count = subgroupMax(triId_+2);
        if (subgroupElect()) {
            gl_PrimitiveCountNV = count;
            #ifdef HAS_STATISTICS
            atomicAdd(quadCounts[task.lodLvl], count);
            #endif
        }
    }

    /*
    uint triId = subgroupExclusiveAdd(render?2:0);
    uint vertId = subgroupExclusiveAdd(render?4:0);
    if (render) {
        //common corners
        gl_MeshVerticesNV[vertId+0].gl_Position = emitVertexPos(1);
        gl_MeshVerticesNV[vertId+1].gl_Position = emitVertexPos(2);

        //tri corners
        gl_MeshVerticesNV[vertId+2].gl_Position = emitVertexPos(0);
        gl_MeshVerticesNV[vertId+3].gl_Position = emitVertexPos(3);

        //Emit tris
        uint idxId = triId*3;
        gl_PrimitiveIndicesNV[idxId++] = vertId+0;
        gl_PrimitiveIndicesNV[idxId++] = vertId+1;
        gl_PrimitiveIndicesNV[idxId++] = vertId+2;

        gl_PrimitiveIndicesNV[idxId++] = vertId+0;
        gl_PrimitiveIndicesNV[idxId++] = vertId+3;
        gl_PrimitiveIndicesNV[idxId++] = vertId+1;

        gl_MeshPrimitivesNV[triId].gl_PrimitiveID = int(qid);
        gl_MeshPrimitivesNV[triId+1].gl_PrimitiveID = int(qid);
    }*/
}