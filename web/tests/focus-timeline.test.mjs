import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
const code = ts.transpileModule(
  fs.readFileSync(new URL('../lib/focus-timeline.ts', import.meta.url), 'utf8'),
  {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ES2022,
    },
  },
).outputText;
const { compatible, phase, covered, transformPoint, validPoint } = await import(
  `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`
);
test('series matching keeps unknown contrast separate and never substitutes another family', () => {
  const s = (label, status) => ({ label, contrast: { status } });
  assert.equal(
    compatible(s('T1 BRAVO', 'unspecified'), s('T1', 'confirmed')),
    false,
  );
  assert.equal(
    compatible(s('T1', 'confirmed'), s('FLAIR', 'confirmed')),
    false,
  );
  assert.equal(
    compatible(s('T1', 'confirmed'), s('T1 MPRAGE', 'confirmed')),
    true,
  );
  assert.equal(compatible(s('T1', 'pre'), s('T1', 'unspecified')), false);
  assert.equal(phase({ label: 'T1' }), 'unknown');
});
test('focus uses fixed-to-moving RAS transform and original acquisition coverage without clamping', () => {
  const identity = [
    [1, 0, 0, 0],
    [0, 1, 0, 0],
    [0, 0, 1, 0],
    [0, 0, 0, 1],
  ];
  const transform = [
    [1, 0, 0, 10],
    [0, 1, 0, -5],
    [0, 0, 1, 0],
    [0, 0, 0, 1],
  ];
  assert.deepEqual(transformPoint(transform, [1, 2, 3]), [11, -3, 3]);
  const r = {
    transformRAS: transform,
    movingWorldToVoxel: identity,
    movingDimensions: [30, 30, 30],
  };
  assert.equal(covered(r, [10, 15, 15]), true);
  assert.equal(covered(r, [25, 15, 15]), false);
  assert.equal(covered(r, [18, 15, 15], 5), false);
  assert.equal(covered(r, [10, 15, 15], 4), true);
  assert.equal(validPoint([NaN, 0, 0]), false);
  assert.equal(validPoint([0, 0]), false);
});
