import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';

const source = fs.readFileSync(
  new URL('../app/dental/curve.ts', import.meta.url),
  'utf8',
);
const compiled = ts.transpileModule(source, {
  compilerOptions: {
    target: ts.ScriptTarget.ES2022,
    module: ts.ModuleKind.ES2022,
  },
}).outputText;
const { catmullRom, insertionIndex, worldFromPixels } = await import(
  `data:text/javascript;base64,${Buffer.from(compiled).toString('base64')}`
);

const arch = [
  [10, 50],
  [30, 20],
  [50, 10],
  [70, 20],
  [90, 50],
];

test('the preview passes through every point that was placed', () => {
  const dense = catmullRom(arch);
  for (const [x, y] of arch)
    assert.ok(
      dense.some(([u, v]) => Math.hypot(u - x, v - y) < 1e-9),
      `the curve misses ${x},${y}`,
    );
});

test('the first points of a curve are appended in the order they are clicked', () => {
  assert.equal(insertionIndex([], 10, 10), 0);
  assert.equal(insertionIndex([[10, 50]], 30, 20), 1);
});

test('a click near the middle of a stretch goes between its two ends', () => {
  assert.equal(insertionIndex(arch, 40, 14), 2);
});

test('a click beyond either end extends the curve instead of folding it back', () => {
  assert.equal(insertionIndex(arch, 100, 70), arch.length);
  assert.equal(insertionIndex(arch, 0, 70), 0);
});

test('clicks become millimetres with the transformation the reconstruction wrote', () => {
  const affine = { x: [-0.5, 0, 40], y: [0, -0.5, 30], z: 6 };
  assert.deepEqual(
    worldFromPixels(
      [
        [0, 0],
        [80, 60],
      ],
      affine,
    ),
    [
      [40, 30, 6],
      [0, 0, 6],
    ],
  );
});
