import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import ts from 'typescript';

// The library module keeps a single connection, so the data directory has to be
// chosen and seeded before the module is imported for the first time.
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'openmri-legacy-'));
process.env.OPENMRI_DATA_DIR = root;
const bundled = (id) =>
  JSON.stringify({ series: [{ id, url: `volumes/${id}.nii.gz` }] });
const library = (id) =>
  JSON.stringify({ series: [{ id, url: `/api/library/assets/${id}` }] });
const seed = new DatabaseSync(path.join(root, 'library.sqlite'));
seed.exec(`
  CREATE TABLE patients(id TEXT PRIMARY KEY,name TEXT NOT NULL,birth_date TEXT DEFAULT '',sex TEXT DEFAULT '',notes TEXT DEFAULT '',created_at TEXT NOT NULL);
  CREATE TABLE studies(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL REFERENCES patients(id),study_uid TEXT NOT NULL,date TEXT NOT NULL,label TEXT NOT NULL,body_part TEXT DEFAULT '',manifest TEXT NOT NULL,source_hash TEXT DEFAULT '',created_at TEXT NOT NULL,UNIQUE(patient_id,study_uid));
  CREATE TABLE focus_regions(id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), payload TEXT NOT NULL);
  INSERT INTO patients VALUES
    ('mixed','Mixed','','','','now'),
    ('imported','Imported','','','','now'),
    ('orphan','Orphan','','','','now'),
    ('tracked','Tracked','','','','now');
  INSERT INTO studies VALUES('bundled','mixed','1.2','2020-01-01','MR','HEAD','${bundled('a')}','seed:x','now');
  INSERT INTO studies VALUES('converted','mixed','1.3','2021-01-01','MR','HEAD','${library('b')}','seed:y','now');
  INSERT INTO studies VALUES('regular','imported','1.4','2022-01-01','MR','HEAD','${library('c')}','abc','now');
  INSERT INTO studies VALUES('only-bundled','orphan','1.5','2020-02-02','MR','HEAD','${bundled('d')}','seed:z','now');
  INSERT INTO studies VALUES('tracked-bundled','tracked','1.6','2020-03-03','MR','HEAD','${bundled('e')}','seed:w','now');
  INSERT INTO focus_regions VALUES('region','tracked','{}');
`);
seed.close();
const code = ts.transpileModule(
  fs.readFileSync(new URL('../lib/library.ts', import.meta.url), 'utf8'),
  {
    compilerOptions: {
      target: ts.ScriptTarget.ES2022,
      module: ts.ModuleKind.ES2022,
    },
  },
).outputText;
const { db } = await import(
  `data:text/javascript;base64,${Buffer.from(code).toString('base64')}`
);
const d = db();
const ids = (table) =>
  d
    .prepare(`SELECT id FROM ${table} ORDER BY id`)
    .all()
    .map((r) => r.id);
after(() => {
  d.close();
  fs.rmSync(root, { recursive: true, force: true });
});

test('opening the library drops studies whose volumes lived in the retired bundle', () => {
  assert.deepEqual(ids('studies'), ['converted', 'regular']);
});

test('a patient left with nothing goes with its last retired study', () => {
  // 'mixed' keeps a study served from the library and 'imported' is untouched.
  assert.equal(ids('patients').includes('orphan'), false);
  assert.equal(ids('patients').includes('mixed'), true);
  assert.equal(ids('patients').includes('imported'), true);
});

test('a patient still referenced by a saved region survives the cleanup', () => {
  // Deleting it would break the foreign key and leave the app unable to start.
  assert.equal(ids('patients').includes('tracked'), true);
  assert.deepEqual(ids('focus_regions'), ['region']);
});
