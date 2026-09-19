import { createHash, randomUUID } from 'node:crypto';
import {
  existsSync,
  mkdirSync,
  openSync,
  closeSync,
  readFileSync,
} from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { db, dataRoot, identifier, pythonPath, SETUP_HINT } from './library';
import {
  compatible,
  covered,
  validPoint,
  type FocusRegion,
  type TimelineSeries,
  type TimelineStudy,
} from './focus-timeline';
const ALGORITHM = 'rigid-mi-v1';
export function timelineDB() {
  const d = db();
  d.exec(`CREATE TABLE IF NOT EXISTS focus_regions(id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), payload TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS registrations(id TEXT PRIMARY KEY, patient_id TEXT NOT NULL REFERENCES patients(id), status TEXT NOT NULL, stage TEXT NOT NULL, request TEXT NOT NULL, result TEXT DEFAULT '{}', error TEXT DEFAULT '', pid INTEGER DEFAULT 0, updated_at TEXT NOT NULL);`);
  return d;
}
export function timelineCatalog(patientId: string) {
  identifier(patientId);
  return timelineDB()
    .prepare(
      'SELECT id,date,label,body_part,manifest FROM studies WHERE patient_id=? ORDER BY date,id',
    )
    .all(patientId)
    .map((row) => ({
      id: String(row.id),
      date: String(row.date),
      label: String(row.label),
      body_part: String(row.body_part),
      series: JSON.parse(String(row.manifest)).series as TimelineSeries[],
    })) satisfies TimelineStudy[];
}
export function source(patientId: string, studyId: string, seriesId: string) {
  const study = timelineCatalog(patientId).find((s) => s.id === studyId);
  const series = study?.series.find((s) => s.id === seriesId);
  if (!series || !study)
    throw new Error('The series does not belong to the selected patient');
  if (!series.url.startsWith('/api/library/assets/'))
    throw new Error('The series is not a cached library volume');
  const asset = db()
    .prepare('SELECT path FROM assets WHERE id=?')
    .get(identifier(series.url.split('/').pop()!));
  if (!asset) throw new Error('The source file was not found');
  const filename = path.resolve(dataRoot(), String(asset.path));
  const hash = createHash('sha256')
    .update(readFileSync(filename))
    .digest('hex');
  return { study, series, filename, hash };
}
export function regions(patientId: string): FocusRegion[] {
  return timelineDB()
    .prepare('SELECT payload FROM focus_regions WHERE patient_id=?')
    .all(identifier(patientId))
    .map((r) => JSON.parse(String(r.payload)));
}
export function saveRegion(input: FocusRegion) {
  if (
    !input ||
    !validPoint(input.point) ||
    !Number.isFinite(input.radius) ||
    input.radius < 1 ||
    input.radius > 50 ||
    typeof input.name !== 'string' ||
    !input.name.trim()
  )
    throw new Error(
      'Provide a name, a point, and a radius between 1 and 50 mm',
    );
  const src = source(input.patientId, input.studyId, input.seriesId);
  const existing = input.id
    ? regions(input.patientId).find((r) => r.id === identifier(input.id))
    : undefined;
  if (input.id && !existing)
    throw new Error('The region was not found for this patient');
  if (
    existing &&
    (existing.studyId !== input.studyId ||
      existing.seriesId !== input.seriesId ||
      existing.sourceHash !== src.hash)
  )
    throw new Error('The reference study has changed. Create a new region.');
  const changed =
    existing &&
    (JSON.stringify(existing.point) !== JSON.stringify(input.point) ||
      existing.radius !== input.radius);
  const region: FocusRegion = {
    id: existing?.id || randomUUID(),
    patientId: input.patientId,
    studyId: input.studyId,
    seriesId: input.seriesId,
    sourceHash: src.hash,
    name: input.name.trim().slice(0, 100),
    point: input.point,
    radius: input.radius,
    reviews: changed ? {} : existing?.reviews || {},
  };
  timelineDB()
    .prepare(
      'INSERT INTO focus_regions(id,patient_id,payload) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload',
    )
    .run(region.id, region.patientId, JSON.stringify(region));
  return region;
}
export function registration(id: string) {
  const d = timelineDB();
  let row = d
    .prepare('SELECT * FROM registrations WHERE id=?')
    .get(identifier(id));
  if (!row) throw new Error('Registration not found');
  if (['queued', 'running'].includes(String(row.status)) && Number(row.pid)) {
    try {
      process.kill(Number(row.pid), 0);
    } catch {
      d.prepare(
        "UPDATE registrations SET status='error',error=? WHERE id=?",
      ).run('Processing was interrupted. Use "Retry registration".', id);
      row = d.prepare('SELECT * FROM registrations WHERE id=?').get(id)!;
    }
  }
  return {
    id,
    status: String(row.status),
    stage: String(row.stage),
    error: String(row.error),
    result: JSON.parse(String(row.result)),
    patientId: String(row.patient_id),
  };
}
export function startRegistration(input: {
  patientId: string;
  fixedStudy: string;
  fixedSeries: string;
  movingStudy: string;
  movingSeries: string;
  allowMismatch?: boolean;
}) {
  const a = source(input.patientId, input.fixedStudy, input.fixedSeries),
    b = source(input.patientId, input.movingStudy, input.movingSeries);
  if (a.study.id === b.study.id) throw new Error('Choose a different date');
  // NIfTI imports carry no body part; DICOM imports must say HEAD or BRAIN.
  const head = (part: string) => !part || /HEAD|BRAIN/i.test(part);
  if (!head(a.study.body_part) || !head(b.study.body_part))
    throw new Error(
      'Automatic registration currently supports head MRI (DICOM body part HEAD or BRAIN, or NIfTI without a body part)',
    );
  if (a.series.modality === 'CT' || b.series.modality === 'CT')
    throw new Error('This mode registers MRI series only');
  if (!compatible(a.series, b.series) && input.allowMismatch !== true)
    throw new Error(
      'The series differ in type or contrast phase. Confirm the manual choice.',
    );
  const id = createHash('sha256')
    .update(
      JSON.stringify([
        ALGORITHM,
        input.patientId,
        input.fixedStudy,
        input.fixedSeries,
        a.hash,
        input.movingStudy,
        input.movingSeries,
        b.hash,
      ]),
    )
    .digest('hex');
  const d = timelineDB();
  if (d.prepare('SELECT id FROM registrations WHERE id=?').get(id)) {
    const old = registration(id);
    if (old.status !== 'error') return old;
  }
  const python = pythonPath();
  if (!existsSync(python)) throw new Error(SETUP_HINT);
  const request = {
    ...input,
    algorithm: ALGORITHM,
    fixed: a.filename,
    moving: b.filename,
    referenceHash: a.hash,
    movingHash: b.hash,
  };
  d.prepare(
    `INSERT INTO registrations(id,patient_id,status,stage,request,updated_at) VALUES(?,?,'queued','Queued',?,?) ON CONFLICT(id) DO UPDATE SET status='queued',stage='Queued',error='',result='{}',pid=0,updated_at=excluded.updated_at`,
  ).run(id, input.patientId, JSON.stringify(request), new Date().toISOString());
  const dir = path.join(dataRoot(), 'registrations', id);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  const log = openSync(path.join(dir, 'worker.log'), 'a', 0o600);
  const p = spawn(
    python,
    [path.join(process.cwd(), 'scripts/register_mri.py'), dataRoot(), id],
    {
      detached: true,
      stdio: ['ignore', log, log],
      env: { ...process.env, PYTHONUNBUFFERED: '1' },
    },
  );
  closeSync(log);
  p.on('error', () =>
    d
      .prepare(
        "UPDATE registrations SET status='error',error='The processing worker could not be started' WHERE id=?",
      )
      .run(id),
  );
  d.prepare('UPDATE registrations SET pid=? WHERE id=?').run(p.pid || 0, id);
  p.unref();
  return registration(id);
}
export function reviewRegion(input: {
  patientId: string;
  regionId: string;
  registrationId: string;
  point: unknown;
  status: string;
}) {
  const region = regions(input.patientId).find((r) => r.id === input.regionId);
  const reg = registration(input.registrationId);
  const row = timelineDB()
    .prepare('SELECT request FROM registrations WHERE id=?')
    .get(reg.id)!;
  const request = JSON.parse(String(row.request));
  if (
    !region ||
    reg.patientId !== input.patientId ||
    reg.status !== 'ready' ||
    request.fixedStudy !== region.studyId ||
    request.fixedSeries !== region.seriesId ||
    reg.result.referenceHash !== region.sourceHash ||
    !validPoint(input.point) ||
    !['checked', 'corrected'].includes(input.status)
  )
    throw new Error('The review does not match the region or registration');
  if (
    !covered(
      reg.result,
      input.status === 'checked' ? region.point : input.point,
    )
  )
    throw new Error('The point lies outside the original scanned field');
  region.reviews[reg.id] = {
    registrationId: reg.id,
    status: input.status as 'checked' | 'corrected',
    point: input.status === 'checked' ? region.point : input.point,
    at: new Date().toISOString(),
  };
  timelineDB()
    .prepare('UPDATE focus_regions SET payload=? WHERE id=? AND patient_id=?')
    .run(JSON.stringify(region), region.id, region.patientId);
  return region;
}
