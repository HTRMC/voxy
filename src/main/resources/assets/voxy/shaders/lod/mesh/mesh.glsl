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

taskNV in Task {
    //Tightly packed, prefix sum + offset
    uvec4 binA;
    uvec4 binB;
    //uint bins[8];

    vec3 cameraOffset;
    uint lodLvl;

    uint baseQuad;
    uint quadCount;
} task;


uint getQuadId() {
    uint mid = gl_GlobalInvocationID.x;
    //Funny method
    uint cv = (mid<<16)|0xFFFFu;
    uvec4 a = mix(uvec4(0), uvec4( 1, 2, 4,  8), lessThanEqual(task.binA, uvec4(cv))) +
              mix(uvec4(0), uvec4(16,32,64,128), lessThanEqual(task.binB, uvec4(cv)));
    uint act = a.x+a.y+a.z+a.w;
    uint id = findLSB(act^(act>>1));

    //uint point = mix(binB, binA, id<4)[id&3u];
    uint point = mix(task.binB[id&3u], task.binA[id&3u], id<4);

    return (point&0xFFFFu)+(mid-(point>>16));

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

//===============
vec3 cornerPos;
vec2 axisFaceSize;
uint face;
void setup(Quad quad) {
    face = extractFace(quad);
    uint modelId = extractStateId(quad);
    BlockModel model = modelData[modelId];
    uint faceData = model.faceData[face];
    bool isTranslucent = modelIsTranslucent(model);
    bool hasAO = modelHasMipmaps(model);//TODO: replace with per face AO flag
    bool isShaded = hasAO;//TODO: make this a per face flag

    ivec2 quadSize = extractSize(quad);

    vec4 faceSize = getFaceSize(faceData);

    cornerPos = extractPos(quad);
    float depthOffset = extractFaceIndentation(faceData);
    cornerPos += swizzelDataAxis(face>>1, vec3(faceSize.xz, mix(depthOffset, 1-depthOffset, float(face&1u))));
    cornerPos *= (1<<task.lodLvl);
    cornerPos += task.cameraOffset;

    axisFaceSize = (faceSize.yw + quadSize - 1);

    //uv = faceSize.xz + axisFaceSize*vec2((cornerIdx>>1)&1, cornerIdx&1);

}

vec4 emitVertexPos(int corner) {
    vec3 pointPos = swizzelDataAxis(face>>1,vec3(axisFaceSize*mix(vec2(0),vec2(1<<task.lodLvl),bvec2((corner>>1)&1, corner&1)),0))+cornerPos;
    return MVP*vec4(pointPos, 1.0);
}

bvec2 whatRender(vec4 p1, vec4 p2, vec4 p0, vec4 p3) {
    vec2 ssmin = ((p1.xy/p1.w)+1)*screenSize;
    vec2 ssmax = ssmin;

    vec2 point = ((p2.xy/p2.w)+1)*screenSize;
    ssmin = min(ssmin, point);
    ssmax = max(ssmax, point);

    point = ((p0.xy/p0.w)+1)*screenSize;
    vec2 t0min = min(ssmin, point);
    vec2 t0max = max(ssmax, point);

    point = ((p3.xy/p3.w)+1)*screenSize;
    vec2 t1min = min(ssmin, point);
    vec2 t1max = max(ssmax, point);

    //Possibly cull the triangles if they dont cover the center of a pixel on the screen (degen)
    float degenBias = 0.001f;
    bool t0draw = all(notEqual(round(t0min-degenBias),round(t0max+degenBias)));
    bool t1draw = all(notEqual(round(t1min-degenBias),round(t1max+degenBias)));
    return bvec2(t0draw, t1draw);
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


    bool render = dot(faceNormal(face), cornerPos) <= 0;

    if (render) {
        vec4 p1 = emitVertexPos(1);
        vec4 p2 = emitVertexPos(2);
        vec4 p0 = emitVertexPos(0);
        vec4 p3 = emitVertexPos(3);
        bvec2 what = whatRender(p1, p2, p0, p3);
        uint c = uint(what.x)+uint(what.y);
        if (c == 0) {
            return;//Early exit
        }
        uint triId_ = subgroupExclusiveAdd(c);
        uint triId = triId_;
        uint vertId_ = subgroupExclusiveAdd(c==1?3:4);
        uint vertId = vertId_;
        uint idxId = triId*3;

        //Emit common
        gl_MeshVerticesNV[vertId++].gl_Position = p1;
        gl_MeshVerticesNV[vertId++].gl_Position = p2;
        if (what.x) {
            gl_PrimitiveIndicesNV[idxId++] = vertId_+0;
            gl_PrimitiveIndicesNV[idxId++] = vertId_+1;
            gl_PrimitiveIndicesNV[idxId++] = vertId;

            gl_MeshVerticesNV[vertId++].gl_Position = p0;

            gl_MeshPrimitivesNV[triId++].gl_PrimitiveID = int(qid);
        }
        if (what.y) {
            gl_PrimitiveIndicesNV[idxId++] = vertId_+0;
            gl_PrimitiveIndicesNV[idxId++] = vertId;
            gl_PrimitiveIndicesNV[idxId++] = vertId_+1;

            gl_MeshVerticesNV[vertId++].gl_Position = p3;

            gl_MeshPrimitivesNV[triId++].gl_PrimitiveID = int(qid);
        }


        subgroupBarrier();
        uint count = subgroupMax(triId_+c);
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