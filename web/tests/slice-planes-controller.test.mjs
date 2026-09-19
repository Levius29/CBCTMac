import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
const compiled = ts.transpileModule(
  fs.readFileSync(
    new URL('../app/slice-planes-controller.ts', import.meta.url),
    'utf8',
  ),
  {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ES2022,
    },
  },
).outputText;
const { SlicePlanesController } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`
);
function fixture() {
  let depth = true,
    write = true,
    program = 'volume';
  const uniforms = new Map(),
    passes = [];
  const gl = {
    CURRENT_PROGRAM: 1,
    DEPTH_WRITEMASK: 2,
    DEPTH_TEST: 3,
    getParameter: (key) => (key === 1 ? program : write),
    isEnabled: () => depth,
    disable: () => {
      depth = false;
    },
    enable: () => {
      depth = true;
    },
    depthMask: (value) => {
      write = value;
    },
    useProgram: (value) => {
      program = value;
    },
    uniform3fv() {},
    uniform4fv() {},
    uniform1f: (key, value) => uniforms.set(key, value),
  };
  const shader = {
    use: () => {
      program = 'planes';
    },
    uniforms: { backOpacity: 'alpha' },
  };
  const nv = {
    gl,
    renderShader: 'volumeShader',
    renderSliceShader: shader,
    gradientTextureAmount: 0.12,
    volumes: [{}],
    uiData: { mouseDepthPicker: false },
    initRenderShader: (s, quality) => {
      assert.equal(s, shader);
      assert.equal(quality, -1);
    },
    sliceScale: () => ({ vox: [100, 120, 80], volScale: [1, 1, 1] }),
    drawImage3D: function (mvp, az, el) {
      passes.push({
        shader: this.renderShader,
        gradient: this.gradientTextureAmount,
        mvp,
        az,
        el,
        depth,
        write,
      });
    },
  };
  const controller = new SlicePlanesController(nv);
  return {
    nv,
    controller,
    passes,
    uniforms,
    shader,
    state: () => ({ depth, write, program }),
  };
}
test('planes use a second source-volume pass, preserve camera and restore renderer state', () => {
  const f = fixture();
  const mvp = [1, 2, 3];
  f.nv.drawImage3D(mvp, 120, 10);
  assert.equal(f.passes.length, 2);
  assert.equal(f.passes[0].shader, 'volumeShader');
  assert.equal(f.passes[1].shader, f.shader);
  assert.equal(f.passes[1].mvp, mvp);
  assert.equal(f.passes[1].gradient, -1);
  assert.equal(f.passes[1].depth, false);
  assert.equal(f.passes[1].write, false);
  assert.equal(f.uniforms.get('alpha'), 0.65);
  assert.deepEqual(f.state(), { depth: true, write: true, program: 'volume' });
  assert.equal(f.nv.gradientTextureAmount, 0.12);
  assert.equal(f.nv.renderShader, 'volumeShader');
});
test('disabled planes and picking use only original rendering; dispose removes wrapper', () => {
  const f = fixture();
  f.controller.enabled = false;
  f.nv.drawImage3D([], 0, 0);
  assert.equal(f.passes.length, 1);
  f.controller.enabled = true;
  f.nv.uiData.mouseDepthPicker = true;
  f.nv.drawImage3D([], 0, 0);
  assert.equal(f.passes.length, 2);
  f.nv.uiData.mouseDepthPicker = false;
  f.controller.dispose();
  f.nv.drawImage3D([], 0, 0);
  assert.equal(f.passes.length, 3);
});
