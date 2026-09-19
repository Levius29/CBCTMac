import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
const code = ts.transpileModule(
  fs.readFileSync(
    new URL('../lib/analysis-contract.ts', import.meta.url),
    'utf8',
  ),
  {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ES2022,
    },
  },
).outputText;
const { validateAnalysisSource } = await import(
  `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`
);
test('model adapter rejects results from another patient, series, geometry, or coordinate system', () => {
  const request = {
    patientId: 'a',
    studyId: 'b',
    seriesId: 'c',
    sourceSha256: 'abc',
    modality: 'MR',
    bodyPart: 'SPINE',
    dimensions: [10, 20, 30],
    affineRASmm: [
      [1, 0, 0, 0],
      [0, 1, 0, 0],
      [0, 0, 1, 0],
      [0, 0, 0, 1],
    ],
  };
  const result = {
    request,
    model: { id: 'test', version: '1' },
    coordinateSystem: 'RAS-mm',
    findings: [
      { id: 'f', label: 'test', pointRASmm: [1, 2, 3], confidence: 0.5 },
    ],
  };
  assert.doesNotThrow(() => validateAnalysisSource(result, request));
  for (const key of ['patientId', 'studyId', 'seriesId', 'sourceSha256'])
    assert.throws(() =>
      validateAnalysisSource(
        { ...result, request: { ...request, [key]: 'other' } },
        request,
      ),
    );
  assert.throws(() =>
    validateAnalysisSource({ ...result, coordinateSystem: 'LPS-mm' }, request),
  );
  assert.throws(() =>
    validateAnalysisSource(
      { ...result, request: { ...request, dimensions: [20, 20, 30] } },
      request,
    ),
  );
  assert.throws(() =>
    validateAnalysisSource(
      {
        ...result,
        findings: [{ ...result.findings[0], pointRASmm: [NaN, 1, 2] }],
      },
      request,
    ),
  );
});
