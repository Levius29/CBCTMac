import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
const code = ts.transpileModule(
  fs.readFileSync(new URL('../lib/recent.ts', import.meta.url), 'utf8'),
  {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ES2022,
    },
  },
).outputText;
const { recentStudies, rememberOpened } = await import(
  `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`
);
const s = (id, created_at) => ({ id, created_at });
const catalogue = [
  s('a', '2026-01-01'),
  s('b', '2026-03-01'),
  s('c', '2026-02-01'),
  s('d', '2026-04-01'),
  s('e', '2026-05-01'),
  s('f', '2026-06-01'),
  s('g', '2026-07-01'),
];

test('recently opened studies lead, newest imports fill the rest, five at most', () => {
  const ids = recentStudies(catalogue, ['c', 'a']).map((x) => x.id);
  assert.deepEqual(ids, ['c', 'a', 'g', 'f', 'e']);
});

test('opened ids that were deleted or repeated do not break the list', () => {
  const ids = recentStudies(catalogue, ['gone', 'b', 'b'], 3).map((x) => x.id);
  assert.deepEqual(ids, ['b', 'g', 'f']);
});

test('without history the list is simply the newest imports', () => {
  assert.deepEqual(
    recentStudies(catalogue, []).map((x) => x.id),
    ['g', 'f', 'e', 'd', 'b'],
  );
  assert.deepEqual(recentStudies([], ['a']), []);
});

test('remembering a study moves it to the front and trims the history', () => {
  assert.deepEqual(rememberOpened(['a', 'b'], 'b'), ['b', 'a']);
  assert.deepEqual(rememberOpened(['a', 'b', 'c', 'd', 'e'], 'z'), [
    'z',
    'a',
    'b',
    'c',
    'd',
  ]);
});
