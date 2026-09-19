import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import ts from 'typescript';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openmri-timeline-test-'));
process.env.OPENMRI_DATA_DIR = root;
for (const name of ['library', 'focus-timeline', 'timeline-server']) {
  const text = fs.readFileSync(
    new URL(`../lib/${name}.ts`, import.meta.url),
    'utf8',
  );
  const compiled = ts
    .transpileModule(text, {
      compilerOptions: {
        target: ts.ScriptTarget.ES2022,
        module: ts.ModuleKind.ES2022,
      },
    })
    .outputText.replace(
      /from '\.\/(library|focus-timeline)'/g,
      "from './$1.mjs'",
    );
  fs.writeFileSync(path.join(root, name + '.mjs'), compiled);
}
const service = await import(
  pathToFileURL(path.join(root, 'timeline-server.mjs'))
);
const d = service.timelineDB();
for (const id of ['patient-a', 'patient-b'])
  d.prepare('INSERT INTO patients(id,name,created_at) VALUES(?,?,?)').run(
    id,
    id,
    '2026-01-01',
  );
for (const [id, patient, phase] of [
  ['study-a', 'patient-a', 'confirmed'],
  ['study-b', 'patient-a', 'confirmed'],
  ['study-c', 'patient-b', 'confirmed'],
  ['study-unknown', 'patient-a', 'unspecified'],
]) {
  fs.writeFileSync(path.join(root, id + '.nii.gz'), 'test-content-' + id);
  d.prepare('INSERT INTO assets(id,path,sha256,size) VALUES(?,?,?,?)').run(
    id,
    id + '.nii.gz',
    'unused',
    1,
  );
  const series = {
    id: 't1',
    label: 'T1',
    modality: 'MR',
    contrast: { status: phase },
    url: '/api/library/assets/' + id,
    displayRange: [0, 100],
  };
  d.prepare(
    'INSERT INTO studies(id,patient_id,study_uid,date,label,body_part,manifest,created_at) VALUES(?,?,?,?,?,?,?,?)',
  ).run(
    id,
    patient,
    id,
    '2026-01-01',
    id,
    'HEAD',
    JSON.stringify({ series: [series] }),
    '2026-01-01',
  );
}
after(() => {
  d.close();
  fs.rmSync(root, { recursive: true, force: true });
});
const input = {
  id: '',
  patientId: 'patient-a',
  studyId: 'study-a',
  seriesId: 't1',
  name: 'Region',
  point: [10, 10, 10],
  radius: 5,
};
const identity = [
  [1, 0, 0, 0],
  [0, 1, 0, 0],
  [0, 0, 1, 0],
  [0, 0, 0, 1],
];
function seedRegistration(
  id,
  source,
  patient = 'patient-a',
  fixedStudy = 'study-a',
) {
  d.prepare(
    'INSERT INTO registrations(id,patient_id,status,stage,request,result,updated_at) VALUES(?,?,?,?,?,?,?)',
  ).run(
    id,
    patient,
    'ready',
    'done',
    JSON.stringify({ fixedStudy, fixedSeries: 't1' }),
    JSON.stringify({
      referenceHash: source,
      transformRAS: identity,
      movingWorldToVoxel: identity,
      movingDimensions: [50, 50, 50],
    }),
    '2026-01-01',
  );
}
test('regions persist, isolate patients, retain verified provenance and invalidate reviews after a geometry edit', () => {
  let r = service.saveRegion(input);
  assert.equal(service.regions('patient-a')[0].id, r.id);
  assert.deepEqual(service.regions('patient-b'), []);
  assert.equal(r.sourceHash, service.source('patient-a', 'study-a', 't1').hash);
  assert.throws(() => service.saveRegion({ ...r, patientId: 'patient-b' }));
  seedRegistration('registered', r.sourceHash);
  const review = {
    patientId: 'patient-a',
    regionId: r.id,
    registrationId: 'registered',
    point: [12, 11, 10],
    status: 'corrected',
  };
  r = service.reviewRegion(review);
  assert.deepEqual(r.reviews.registered.point, [12, 11, 10]);
  assert.deepEqual(r.point, [10, 10, 10]);
  r = service.saveRegion({ ...r, name: 'Renamed' });
  assert.equal(r.reviews.registered.status, 'corrected');
  r = service.saveRegion({ ...r, point: [11, 10, 10] });
  assert.deepEqual(r.reviews, {});
  assert.throws(() => service.reviewRegion({ ...review, point: [500, 0, 0] }));
  assert.throws(() =>
    service.reviewRegion({ ...review, patientId: 'patient-b' }),
  );
  seedRegistration('stale', 'wrong-hash');
  assert.throws(() =>
    service.reviewRegion({ ...review, registrationId: 'stale' }),
  );
  seedRegistration('wrong-reference', r.sourceHash, 'patient-a', 'study-b');
  assert.throws(() =>
    service.reviewRegion({ ...review, registrationId: 'wrong-reference' }),
  );
});
test('registration rejects another patient and ambiguous contrast before starting a worker', () => {
  const request = {
    patientId: 'patient-a',
    fixedStudy: 'study-a',
    fixedSeries: 't1',
    movingStudy: 'study-c',
    movingSeries: 't1',
  };
  assert.throws(() => service.startRegistration(request), /patient/);
  assert.throws(
    () =>
      service.startRegistration({ ...request, movingStudy: 'study-unknown' }),
    /contrast phase/,
  );
  assert.throws(
    () => service.startRegistration({ ...request, movingStudy: 'study-a' }),
    /different date/,
  );
});
test('invalid region geometry and a changed source file cannot reuse saved coordinates', () => {
  assert.throws(() =>
    service.saveRegion({ ...input, point: [Infinity, 0, 0] }),
  );
  assert.throws(() => service.saveRegion({ ...input, radius: 0 }));
  assert.throws(() => service.saveRegion({ ...input, radius: 51 }));
  const r = service.saveRegion(input);
  fs.writeFileSync(path.join(root, 'study-a.nii.gz'), 'changed');
  assert.throws(() => service.saveRegion(r), /has changed/);
});
