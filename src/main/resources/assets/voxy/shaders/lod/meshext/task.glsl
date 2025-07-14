#version 460 core

#extension GL_EXT_mesh_shader : require

layout(local_size_x=1, local_size_y=1, local_size_z=1) in;

#import <voxy:lod/section.glsl>

layout(binding = 0, std140) uniform SceneUniform {
    mat4 MVP;
    ivec3 baseSectionPos;
    uint frameId;
    vec3 cameraSubPos;
    uint pad_;
    vec2 screenSize;
};

layout(binding = 1, std430) restrict readonly buffer IndirectSectionLookupBuffer {
    uint sectionCount;
    uint indirectLookup[];
};

layout(binding = 2, std430) restrict readonly buffer SectionBuffer {
    SectionMeta sectionData[];
};

layout(binding = 3, std430) restrict readonly buffer VisibilityBuffer {
    uint visibilityData[];
};

#ifdef HAS_STATISTICS
layout(binding = STATISTICS_BUFFER_BINDING, std430) restrict buffer statisticsBuffer {
    uint visibleSectionCounts[5];
    uint quadCounts[5];
};
#endif

taskPayloadSharedEXT out Task {
    //Tightly packed, prefix sum + offset
    //uvec4 binA;
    //uvec4 binB;
    uint bins[8];

    vec3 cameraOffset;
    uint lodLvl;

    uint baseQuad;
    uint quadCount;
} task;

#define BIN(br, cnt) if (br) { task.bins[i++] = (sum<<16)|off; sum += cnt; } off += cnt;
//#define BIN(br, cnt) if (br) { batch[i++] = (sum<<16)|off; sum += cnt; } off += cnt;

bvec3 and(bvec3 a, bvec3 b) {
    return bvec3(a.x&&b.x, a.y&&b.y, a.z&&b.z);
}
uint fillBins(uvec4 counts, ivec3 relative) {//Returns quad count
    #pragma unroll
    for (uint i = 0; i < 8; i++) task.bins[i] = uint(-1);

    uvec3 cA = counts.yzw&0xFFFFu;
    uvec3 cB = counts.yzw>>16;

    bvec3 a = and(notEqual(cA, uvec3(0)), lessThanEqual(ivec3(0), relative.yzx));
    bvec3 b = and(notEqual(cB, uvec3(0)), lessThanEqual(relative.yzx, ivec3(0)));

    uint dsc = counts.x>>16;//double sided quads
    uint sum = 0;
    uint off = counts.x&0xFFFFu;//translucent quads
    uint i = 0;

    //TODO: might need to move this into shared memory or somethign? so that compiler can reason about it (or make the bin an array in here and mesh)
    //uint batch[8] = {uint(-1), uint(-1), uint(-1), uint(-1), uint(-1),uint(-1),uint(-1),uint(-1)};

    BIN(dsc!=0, dsc);//Double sided quads

    //TODO: compute prefix sums and then jsut batch set into the array (this is an optimization)

    BIN(a.x, cA.x);//Down
    BIN(b.x, cB.x);//Up
    BIN(a.y, cA.y);//North
    BIN(b.y, cB.y);//South
    BIN(a.z, cA.z);//West
    BIN(b.z, cB.z);//East

    //task.binA = uvec4(batch[0], batch[1], batch[2], batch[3]);
    //task.binB = uvec4(batch[4], batch[5], batch[6], batch[7]);
    return sum;
}


void main() {
    uint secId = indirectLookup[gl_WorkGroupID.x];
    uint vis = visibilityData[secId];

    bool shouldRender = (vis&0x7fffffffu) == frameId-1;//-1 since we are technically in the next frame for the primary rasterization
    bool renderTemporally = (vis&0x80000000u)==0;

    task.quadCount = 0;

    if (shouldRender) {
        SectionMeta section = sectionData[secId];

        uint detail = extractDetail(section);
        ivec3 ipos = extractPosition(section);

        ivec3 relative = ipos-(baseSectionPos>>detail);

        #ifdef HAS_STATISTICS
        atomicAdd(visibleSectionCounts[detail], 1);
        #endif

        //TODO: here enqueue the id here for both translucent and temporal (if relevant) (* note technically dont need for temporal as can just check :tm: if we are in temporal render mode)

        task.baseQuad  = extractQuadStart(section);
        task.quadCount = fillBins(section.b, relative);

        task.cameraOffset = vec3(((ipos<<detail) - baseSectionPos)<<5);
        task.lodLvl = detail;
    }

    //It appears to be valid to read from taskPayloadSharedEXT
    EmitMeshTasksEXT((task.quadCount+(MESH_SIZE-1))/MESH_SIZE, 1, 1);
}