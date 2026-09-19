import type { Niivue } from '@niivue/niivue';

/** Uses the source volume's own texture and patient geometry; no synthetic image planes. */
export class SlicePlanesController {
  enabled = true;
  opacity = 0.65;
  private readonly original: Niivue['drawImage3D'];
  constructor(private readonly nv: Niivue) {
    this.original = nv.drawImage3D.bind(nv);
    nv.initRenderShader(nv.renderSliceShader!, -1);
    nv.drawImage3D = (mvp, azimuth, elevation) => {
      this.original(mvp, azimuth, elevation);
      if (!this.enabled || !nv.volumes.length || nv.uiData.mouseDepthPicker)
        return;
      const gl = nv.gl;
      const shader = nv.renderSliceShader!;
      const previousShader = nv.renderShader;
      const previousGradient = nv.gradientTextureAmount;
      const previousProgram = gl.getParameter(gl.CURRENT_PROGRAM);
      const depthTest = gl.isEnabled(gl.DEPTH_TEST);
      const depthWrite = gl.getParameter(gl.DEPTH_WRITEMASK);
      const { vox, volScale } = nv.sliceScale(true);
      shader.use(gl);
      gl.uniform3fv(shader.uniforms.texVox, vox);
      gl.uniform3fv(shader.uniforms.volScale, volScale);
      gl.uniform1f(shader.uniforms.backOpacity, this.opacity);
      // This native shader samples source T1 at the planes. The difference
      // overlay is drawn by the preceding volume pass and in the 2D views.
      gl.uniform1f(shader.uniforms.overlays, 0);
      gl.uniform1f(shader.uniforms.renderOverlayBlend, 0);
      gl.uniform4fv(shader.uniforms.clipPlaneColor, [0, 0, 0, 0]);
      try {
        gl.disable(gl.DEPTH_TEST);
        gl.depthMask(false);
        nv.renderShader = shader;
        nv.gradientTextureAmount = -1;
        this.original(mvp, azimuth, elevation);
      } finally {
        nv.renderShader = previousShader;
        nv.gradientTextureAmount = previousGradient;
        gl.depthMask(depthWrite);
        if (depthTest) gl.enable(gl.DEPTH_TEST);
        else gl.disable(gl.DEPTH_TEST);
        gl.useProgram(previousProgram);
      }
    };
  }
  dispose() {
    this.nv.drawImage3D = this.original;
  }
}
