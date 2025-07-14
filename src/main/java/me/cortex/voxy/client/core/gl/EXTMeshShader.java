package me.cortex.voxy.client.core.gl;

import org.lwjgl.opengl.GL;
import org.lwjgl.system.JNI;

public class EXTMeshShader {
    public static final int
            GL_MESH_SHADER_EXT = 0x9559,
            GL_TASK_SHADER_EXT = 0x955A;

    private static final long glDrawMeshTasksIndirectEXT_ptr;
    static {
        if (GL.getFunctionProvider() == null) {
            throw new IllegalStateException("Class must be initalized after gl context has been created");
        }
        glDrawMeshTasksIndirectEXT_ptr = GL.getFunctionProvider().getFunctionAddress("glDrawMeshTasksIndirectEXT");
    }

    public static void glDrawMeshTasksIndirectEXT(long indirect) {
        if (glDrawMeshTasksIndirectEXT_ptr == 0) {
            throw new IllegalStateException("glDrawMeshTasksIndirectEXT not supported");
        }
        JNI.callV(indirect, glDrawMeshTasksIndirectEXT_ptr);
    }
}
