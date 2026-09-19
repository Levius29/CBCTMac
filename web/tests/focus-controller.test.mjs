import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';

const source = fs.readFileSync(
  new URL('../app/focus-controller.ts', import.meta.url),
  'utf8',
);
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ES2022,
  },
}).outputText;
const { FocusController } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`
);

function fixture(reducedMotion = false) {
  let sequence = 0;
  const frames = new Map();
  globalThis.requestAnimationFrame = (callback) => {
    const id = ++sequence;
    frames.set(id, callback);
    return id;
  };
  globalThis.cancelAnimationFrame = (id) => frames.delete(id);
  globalThis.window = { matchMedia: () => ({ matches: reducedMotion }) };
  let wheel;
  const projected = [];
  const locations = [];
  const canvas = {
    width: 600,
    height: 600,
    clientWidth: 600,
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 600, height: 600 }),
    addEventListener: (_, fn) => {
      wheel = fn;
    },
    removeEventListener: () => {
      wheel = null;
    },
  };
  const patientMm = (frac) => [
    frac[0] * 210 - 100,
    frac[1] * 190 - 90,
    frac[2] * 160 - 80,
    1,
  ];
  const gl = {
    DEPTH_TEST: 1,
    BLEND: 2,
    SRC_ALPHA: 3,
    ONE_MINUS_SRC_ALPHA: 4,
    isEnabled: () => false,
    disable() {},
    enable() {},
    blendFunc() {},
    viewport() {},
    getParameter: () => [0, 0, 600, 600],
    depthMask() {},
    blendFuncSeparate() {},
    bindVertexArray() {},
    useProgram() {},
  };
  const base = () => ({
    canvas,
    screenSlices: [{ axCorSag: 4, leftTopWidthHeight: [0, 0, 600, 600] }],
    gl,
    scene: {
      crosshairPos: [0.5, 0.5, 0.5],
      renderAzimuth: 120,
      renderElevation: 10,
    },
    opts: {},
    volumes: [{ dimsRAS: [3, 384, 320, 160] }],
    frac2mm: (frac, _volume, world) => {
      assert.equal(world, true);
      return patientMm(frac);
    },
    drawImage3D() {},
    drawSceneCore() {},
    drawScene() {
      this.drawSceneCore();
    },
  });
  const render = {
    ...base(),
    calculateMvpMatrix: () => [[]],
    calculateScreenPoint: (point) => {
      projected.push(point);
      return [300, 300, 0.3, 1];
    },
    drawCircle() {},
    drawLine() {},
    drawRect() {},
    drawText() {},
  };
  const slices = {
    ...base(),
    screenSlices: [{ axCorSag: 0 }, { axCorSag: 1 }, { axCorSag: 2 }],
    tileIndex: (_x, y) => Math.floor(y / 200),
  };
  const controller = new FocusController(render, slices, (value) =>
    locations.push(value),
  );
  controller.reset([0.5, 0.5, 0.5]);
  const step = (offset = 300) => {
    const queued = [...frames.values()];
    frames.clear();
    for (const fn of queued) fn(performance.now() + offset);
  };
  const scroll = (y, deltaY, deltaMode = 0) => {
    let prevented = false;
    wheel({
      clientX: 100,
      clientY: y,
      deltaY,
      deltaMode,
      preventDefault: () => {
        prevented = true;
      },
      stopImmediatePropagation() {},
    });
    return prevented;
  };
  return {
    controller,
    render,
    slices,
    locations,
    projected,
    step,
    scroll,
    frames,
    wheelExists: () => !!wheel,
  };
}

test('a slice click moves both views smoothly and reaches its exact 3D patient coordinate', () => {
  const f = fixture();
  f.slices.onLocationChange({ frac: [0.2, 0.7, 0.8] });
  assert.deepEqual(f.render.scene.crosshairPos, [0.5, 0.5, 0.5]);
  assert.equal(f.frames.size, 1);
  f.step();
  assert.deepEqual(f.render.scene.crosshairPos, [0.2, 0.7, 0.8]);
  assert.deepEqual(f.slices.scene.crosshairPos, f.render.scene.crosshairPos);
  assert.deepEqual(f.projected.at(-1), [-58, 43, 48]);
  assert.equal(f.locations.at(-1).visible, true);
  f.controller.dispose();
});

test('a new click cancels the old transition and ends only at the newest point', () => {
  const f = fixture();
  f.slices.onLocationChange({ frac: [0.1, 0.1, 0.1] });
  f.step(40);
  const midway = [...f.render.scene.crosshairPos];
  assert.ok(midway[0] < 0.5 && midway[0] > 0.1);
  f.slices.onLocationChange({ frac: [0.9, 0.8, 0.7] });
  assert.equal(f.frames.size, 1);
  f.step();
  assert.deepEqual(f.render.scene.crosshairPos, [0.9, 0.8, 0.7]);
  f.controller.dispose();
});

test('wheel deltas accumulate without losing slices and map axial/coronal/sagittal to Z/Y/X', () => {
  const f = fixture();
  assert.equal(f.scroll(100, 25), true);
  f.scroll(100, 25);
  f.scroll(300, 50);
  f.scroll(500, 50);
  f.step();
  const actual = f.render.scene.crosshairPos;
  const expected = [0.5 + 1 / 384, 0.5 + 1 / 320, 0.5 + 1 / 160];
  expected.forEach((value, i) =>
    assert.ok(Math.abs(value - actual[i]) < 1e-12),
  );
  f.controller.dispose();
});

test('boundaries clamp, pause cancels work, and disposal removes the wheel listener', () => {
  const f = fixture();
  f.controller.moveTo([-1, 3, 0.4]);
  f.step();
  assert.deepEqual(f.render.scene.crosshairPos, [0, 1, 0.4]);
  f.controller.moveTo([0.2, 0.3, 0.4]);
  f.controller.pause();
  assert.equal(f.frames.size, 0);
  f.controller.dispose();
  assert.equal(f.wheelExists(), false);
});

test('reduced motion reaches exact coordinates immediately without animation', () => {
  const f = fixture(true);
  f.controller.moveTo([0.2, 0.3, 0.4]);
  assert.deepEqual(f.render.scene.crosshairPos, [0.2, 0.3, 0.4]);
  assert.equal(f.frames.size, 0);
  f.controller.dispose();
});

function peerFixture(f) {
  const native = (frac) => [
    frac[0] * 210 - 100,
    frac[1] * 190 - 90,
    frac[2] * 160 - 80,
  ];
  const inverse = (mm) => [
    (mm[0] + 100) / 210,
    (mm[1] + 90) / 190,
    (mm[2] + 80) / 160,
  ];
  f.slices.mm2frac = (mm, _index, world) => {
    assert.equal(world, true);
    return inverse(mm);
  };
  let peerWheel;
  const peer = {
    ...f.slices,
    canvas: {
      ...f.slices.canvas,
      addEventListener: (_, callback) => {
        peerWheel = callback;
      },
      removeEventListener: () => {
        peerWheel = null;
      },
    },
    opts: { isSliceMM: true },
    scene: { crosshairPos: [0.5, 0.5, 0.5] },
    // A different FOV and oblique affine: copying fractions would be wrong.
    mm2frac: (mm, _index, world) => {
      assert.equal(world, true);
      return [
        (mm[0] + 75) / 150,
        (mm[1] + 100 - 0.2 * mm[2]) / 230,
        (mm[2] + 110) / 220,
      ];
    },
    frac2mm: (frac) => [
      frac[0] * 150 - 75,
      frac[1] * 230 - 100 + 0.2 * (frac[2] * 220 - 110),
      frac[2] * 220 - 110,
    ],
    drawScene() {},
  };
  const bounds = [];
  f.controller.setPeer(peer, (value) => bounds.push(value));
  return { peer, bounds, native, inverse, hasWheel: () => !!peerWheel };
}

test('comparison shares physical coordinates bidirectionally across different oblique geometries', () => {
  const f = fixture(true);
  const p = peerFixture(f);
  f.controller.moveTo([0.25, 0.6, 0.7]);
  const expected = p.native([0.25, 0.6, 0.7]);
  p.peer
    .frac2mm(p.peer.scene.crosshairPos)
    .forEach((v, i) => assert.ok(Math.abs(v - expected[i]) < 1e-10));
  p.peer.onLocationChange({ mm: [21, 19, 16] });
  f.controller
    .getWorldPoint()
    .forEach((v, i) => assert.ok(Math.abs(v - [21, 19, 16][i]) < 1e-10));
  f.controller.setPeer(null);
  assert.equal(p.hasWheel(), false);
  f.controller.dispose();
});

test('comparison preserves out-of-field coordinates instead of substituting a clamped point', () => {
  const f = fixture(true);
  const p = peerFixture(f);
  f.controller.moveTo([1, 0.6, 0.7]);
  assert.equal(p.bounds.at(-1), false);
  assert.ok(p.peer.scene.crosshairPos[0] > 1);
  assert.ok(
    Math.abs(p.peer.frac2mm(p.peer.scene.crosshairPos)[0] - 110) < 1e-10,
  );
  f.controller.dispose();
});

test('world-aligned scrolling changes only its requested world axis', () => {
  const f = fixture(true);
  peerFixture(f);
  f.slices.opts.isSliceMM = true;
  // Introduce an oblique primary transform so this fails if voxel fractions are stepped.
  f.slices.frac2mm = (frac) => [
    frac[0] * 210 - 100,
    frac[1] * 190 - 90 + 0.3 * (frac[2] * 160 - 80),
    frac[2] * 160 - 80,
  ];
  f.slices.mm2frac = (mm) => [
    (mm[0] + 100) / 210,
    (mm[1] + 90 - 0.3 * mm[2]) / 190,
    (mm[2] + 80) / 160,
  ];
  const before = f.controller.getWorldPoint();
  f.scroll(100, 50);
  const after = f.controller.getWorldPoint();
  assert.ok(Math.abs(after[0] - before[0]) < 1e-10);
  assert.ok(Math.abs(after[1] - before[1]) < 1e-10);
  assert.ok(Math.abs(after[2] - before[2] - 1) < 1e-10);
  f.controller.dispose();
});

test('focus uses the actual rendered matrix and rejects non-finite coordinates', () => {
  const f = fixture(true);
  const matrix = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1];
  let seenMatrix;
  f.render.calculateScreenPoint = (_point, m) => {
    seenMatrix = m;
    return [300, 300, 0, 1];
  };
  f.render.drawImage3D(matrix, 120, 10);
  f.controller.moveTo([0.2, 0.3, 0.4]);
  assert.equal(seenMatrix, matrix);
  assert.equal(f.render.opts.show3Dcrosshair, false);
  f.controller.moveTo([NaN, 0.2, 0.3]);
  assert.deepEqual(f.render.scene.crosshairPos, [0.2, 0.3, 0.4]);
  f.controller.dispose();
});

test('a 2D-only layout never reuses a stale 3D marker projection', () => {
  const f = fixture();
  f.render.screenSlices = [
    { axCorSag: 0, leftTopWidthHeight: [0, 0, 600, 600] },
  ];
  f.controller.reset([0.5, 0.5, 0.5], true);
  assert.equal(f.projected.length, 0);
  f.controller.dispose();
});
