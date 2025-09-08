package me.cortex.voxy.client.core.rendering.section;


import me.cortex.voxy.client.RenderStatistics;
import me.cortex.voxy.client.core.AbstractRenderPipeline;
import me.cortex.voxy.client.core.gl.Capabilities;
import me.cortex.voxy.client.core.gl.GlBuffer;
import me.cortex.voxy.client.core.gl.GlTexture;
import me.cortex.voxy.client.core.gl.GlVertexArray;
import me.cortex.voxy.client.core.gl.shader.Shader;
import me.cortex.voxy.client.core.gl.shader.ShaderType;
import me.cortex.voxy.client.core.model.ModelStore;
import me.cortex.voxy.client.core.rendering.section.geometry.BasicSectionGeometryData;
import me.cortex.voxy.client.core.rendering.util.DownloadStream;
import me.cortex.voxy.client.core.rendering.util.LightMapHelper;
import me.cortex.voxy.client.core.rendering.util.SharedIndexBuffer;
import me.cortex.voxy.client.core.rendering.util.UploadStream;
import me.cortex.voxy.common.Logger;
import me.cortex.voxy.common.world.WorldEngine;
import org.joml.Matrix4f;
import org.lwjgl.system.MemoryUtil;

import java.util.List;

import static me.cortex.voxy.client.core.gl.EXTMeshShader.glDrawMeshTasksIndirectEXT;
import static org.lwjgl.opengl.GL11.*;
import static org.lwjgl.opengl.GL11C.GL_UNSIGNED_INT;
import static org.lwjgl.opengl.GL15.GL_ELEMENT_ARRAY_BUFFER;
import static org.lwjgl.opengl.GL15.glBindBuffer;
import static org.lwjgl.opengl.GL30.glBindBufferBase;
import static org.lwjgl.opengl.GL30.glBindVertexArray;
import static org.lwjgl.opengl.GL30C.GL_R32UI;
import static org.lwjgl.opengl.GL30C.GL_RED_INTEGER;
import static org.lwjgl.opengl.GL31.GL_UNIFORM_BUFFER;
import static org.lwjgl.opengl.GL33.glBindSampler;
import static org.lwjgl.opengl.GL40C.GL_DRAW_INDIRECT_BUFFER;
import static org.lwjgl.opengl.GL42.glMemoryBarrier;
import static org.lwjgl.opengl.GL43.*;
import static org.lwjgl.opengl.GL45.*;
import static org.lwjgl.opengl.NVRepresentativeFragmentTest.GL_REPRESENTATIVE_FRAGMENT_TEST_NV;

//Uses MDIC to render the sections
public class MeshEXTSectionRenderer extends AbstractSectionRenderer<MeshViewport, BasicSectionGeometryData> {
    private static final int STATISTICS_BUFFER_BINDING = 8;
    private final Shader terrainShader = Shader.make()
            .define("MESH_SIZE", 32)//16

            .defineIf("HAS_STATISTICS", RenderStatistics.enabled)
            .defineIf("STATISTICS_BUFFER_BINDING", RenderStatistics.enabled, STATISTICS_BUFFER_BINDING)

            .add(ShaderType.TASK, "voxy:lod/meshext/task.glsl")
            .add(ShaderType.MESH, "voxy:lod/meshext/mesh.glsl")
            .add(ShaderType.FRAGMENT, "voxy:lod/meshext/frag.glsl")
            .compile();

    private final Shader cullShader = Shader.make()
            .add(ShaderType.VERTEX, "voxy:lod/gl46/cull/raster.vert")
            .add(ShaderType.FRAGMENT, "voxy:lod/gl46/cull/raster.frag")
            .compile();

    private final GlBuffer uniform = new GlBuffer(1024).zero();
    private final GlBuffer cullAndMeshDrawCommand = new GlBuffer(8*4).zero();//TODO: this needs tobe in the viewport

    //Statistics
    private final GlBuffer statisticsBuffer = new GlBuffer(1024).zero();

    private final AbstractRenderPipeline pipeline;
    public MeshEXTSectionRenderer(AbstractRenderPipeline pipeline, ModelStore modelStore, BasicSectionGeometryData geometryData) {
        super(modelStore, geometryData);
        this.pipeline = pipeline;
        glClearNamedBufferSubData(this.cullAndMeshDrawCommand.id, GL_R32UI,0, 4, GL_RED_INTEGER, GL_UNSIGNED_INT, new int[]{6*2*3});//count
        glClearNamedBufferSubData(this.cullAndMeshDrawCommand.id, GL_R32UI,8, 4, GL_RED_INTEGER, GL_UNSIGNED_INT, new int[]{(1<<16)*6*2});//firstIndex
        glClearNamedBufferSubData(this.cullAndMeshDrawCommand.id, GL_R32UI,5*4+4, 4, GL_RED_INTEGER, GL_UNSIGNED_INT, new int[]{1});//y
        glClearNamedBufferSubData(this.cullAndMeshDrawCommand.id, GL_R32UI,5*4+8, 4, GL_RED_INTEGER, GL_UNSIGNED_INT, new int[]{1});//z
    }

    private void uploadUniformBuffer(MeshViewport viewport) {
        long ptr = UploadStream.INSTANCE.upload(this.uniform, 0, 1024);
        
        var mat = new Matrix4f(viewport.MVP);
        mat.translate(-viewport.innerTranslation.x, -viewport.innerTranslation.y, -viewport.innerTranslation.z);
        mat.getToAddress(ptr); ptr += 4*4*4;

        viewport.section.getToAddress(ptr); ptr += 4*3;

        if (viewport.frameId<0) {
            Logger.error("Frame ID negative, this will cause things to break, wrapping around");
            viewport.frameId &= 0x7fffffff;
        }
        MemoryUtil.memPutInt(ptr, viewport.frameId&0x7fffffff); ptr += 4;
        viewport.innerTranslation.getToAddress(ptr); ptr += 4*3;

        ptr += 4;// padd

        MemoryUtil.memPutFloat(ptr, viewport.width); ptr += 4;
        MemoryUtil.memPutFloat(ptr, viewport.height); ptr += 4;

        UploadStream.INSTANCE.commit();
    }


    private void bindRenderingBuffers(MeshViewport viewport) {
        glBindBufferBase(GL_UNIFORM_BUFFER, 0, this.uniform.id);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, viewport.getRenderList().id);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, this.geometryManager.getMetadataBuffer().id);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, viewport.visibilityBuffer.id);
        glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 4, this.geometryManager.getGeometryBuffer().id);
        this.modelStore.bind(5, 6, 0);
        LightMapHelper.bind(1);
        glBindTextureUnit(2, viewport.depthBoundingBuffer.getDepthTex().id);

        glBindBuffer(GL_DRAW_INDIRECT_BUFFER, this.cullAndMeshDrawCommand.id);

        if (RenderStatistics.enabled) {
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, STATISTICS_BUFFER_BINDING, this.statisticsBuffer.id);
        }
    }

    private void renderTerrain(MeshViewport viewport) {
        //RenderLayer.getCutoutMipped().startDrawing();
        glDisable(GL_CULL_FACE);
        glEnable(GL_DEPTH_TEST);
        this.terrainShader.bind();
        this.pipeline.setupAndBindOpaque(viewport);
        this.bindRenderingBuffers(viewport);

        glMemoryBarrier(GL_COMMAND_BARRIER_BIT|GL_SHADER_STORAGE_BARRIER_BIT);//Barrier everything is needed

        glDrawMeshTasksIndirectEXT(20);

        glEnable(GL_CULL_FACE);
        glBindSampler(0, 0);
        glBindTextureUnit(0, 0);
        glBindSampler(1, 0);
        glBindTextureUnit(1, 0);

        //RenderLayer.getCutoutMipped().endDrawing();
    }

    @Override
    public void renderOpaque(MeshViewport viewport) {
        if (this.geometryManager.getSectionCount() == 0) return;

        this.uploadUniformBuffer(viewport);

        this.renderTerrain(viewport);

        //We need todo the statistics here as rastering is part of them, download then clear
        if (RenderStatistics.enabled) {
            DownloadStream.INSTANCE.download(this.statisticsBuffer, down->{
                final int LAYERS = WorldEngine.MAX_LOD_LAYER+1;
                for (int i = 0; i < LAYERS; i++) {
                    RenderStatistics.visibleSections[i] = MemoryUtil.memGetInt(down.address+i*4L);
                }

                for (int i = 0; i < LAYERS; i++) {
                    RenderStatistics.quadCount[i] = MemoryUtil.memGetInt(down.address+LAYERS*4L+i*4L);
                }
            });

            this.statisticsBuffer.zero();
        }
    }

    @Override
    public void renderTranslucent(MeshViewport viewport) {
        return;
    }

    @Override
    public void buildDrawCalls(MeshViewport viewport) {
        if (this.geometryManager.getSectionCount() == 0) return;
        this.uploadUniformBuffer(viewport);
        //Can do a sneeky trick, since the sectionRenderList is a list to things to render, it invokes the culler
        // which only marks visible sections


        {//Test occlusion
            glCopyNamedBufferSubData(viewport.getRenderList().id, this.cullAndMeshDrawCommand.id, 0, 4, 4);//Copy counts to the draw buffer
            glCopyNamedBufferSubData(viewport.getRenderList().id, this.cullAndMeshDrawCommand.id, 0, 20, 4);//Copy counts to the draw buffer

            this.cullShader.bind();
            if (Capabilities.INSTANCE.repFragTest) {
                glEnable(GL_REPRESENTATIVE_FRAGMENT_TEST_NV);
            }
            glBindVertexArray(GlVertexArray.STATIC_VAO);
            glBindBufferBase(GL_UNIFORM_BUFFER, 0, this.uniform.id);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 1, this.geometryManager.getMetadataBuffer().id);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 2, viewport.visibilityBuffer.id);
            glBindBufferBase(GL_SHADER_STORAGE_BUFFER, 3, viewport.getRenderList().id);
            glBindBuffer(GL_DRAW_INDIRECT_BUFFER, this.cullAndMeshDrawCommand.id);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, SharedIndexBuffer.INSTANCE.id());
            glEnable(GL_DEPTH_TEST);
            glColorMask(false, false, false, false);
            glDepthMask(false);
            glMemoryBarrier(GL_SHADER_STORAGE_BARRIER_BIT|GL_COMMAND_BARRIER_BIT);
            glDrawElementsIndirect(GL_TRIANGLES, GL_UNSIGNED_BYTE, 0);
            glDepthMask(true);
            glColorMask(true, true, true, true);
            glDisable(GL_DEPTH_TEST);
            if (Capabilities.INSTANCE.repFragTest) {
                glDisable(GL_REPRESENTATIVE_FRAGMENT_TEST_NV);
            }
        }
    }

    @Override
    public void renderTemporal(MeshViewport viewport) {
        return;
    }

    @Override
    public void addDebug(List<String> lines) {
        super.addDebug(lines);
        //lines.add("SC/GS: " + this.geometryManager.getSectionCount() + "/" + (this.geometryManager.getGeometryUsed()/(1024*1024)));//section count/geometry size (MB)
    }

    @Override
    public MeshViewport createViewport() {
        return new MeshViewport(this.geometryManager.getMaxSectionCount());
    }

    @Override
    public void free() {
        this.cullAndMeshDrawCommand.free();
        this.uniform.free();
        this.terrainShader.free();
        this.cullShader.free();
        this.statisticsBuffer.free();
    }
}
