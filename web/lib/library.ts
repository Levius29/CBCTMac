import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, existsSync, openSync, closeSync } from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';

/** An existing pre-rename library keeps working without moving files. */
const legacyDataDir = () => {
  const legacy = path.join(process.cwd(), '.neurospace');
  return !existsSync(path.join(process.cwd(), '.openmri')) && existsSync(legacy)
    ? legacy
    : '';
};
export const SETUP_HINT =
  'The Python processing environment is missing. Run: npm run setup';
/** Interpreter of the project virtualenv created by scripts/setup.mjs. */
export const pythonPath = () =>
  process.env.OPENMRI_PYTHON ||
  process.env.NEUROSPACE_PYTHON ||
  path.join(
    process.cwd(),
    process.platform === 'win32'
      ? '.venv/Scripts/python.exe'
      : '.venv/bin/python',
  );
export const dataRoot = () =>
  path.resolve(
    process.env.OPENMRI_DATA_DIR ||
      process.env.NEUROSPACE_DATA_DIR ||
      legacyDataDir() ||
      path.join(process.cwd(), '.openmri'),
  );
let connection: DatabaseSync | undefined;
export function db() {
  if (connection) return connection;
  mkdirSync(dataRoot(), { recursive: true, mode: 0o700 });
  const d = new DatabaseSync(path.join(dataRoot(), 'library.sqlite'));
  d.exec(`PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; PRAGMA busy_timeout=10000;
    CREATE TABLE IF NOT EXISTS patients(id TEXT PRIMARY KEY,name TEXT NOT NULL,birth_date TEXT DEFAULT '',sex TEXT DEFAULT '',notes TEXT DEFAULT '',created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS studies(id TEXT PRIMARY KEY,patient_id TEXT NOT NULL REFERENCES patients(id),study_uid TEXT NOT NULL,date TEXT NOT NULL,label TEXT NOT NULL,body_part TEXT DEFAULT '',manifest TEXT NOT NULL,source_hash TEXT DEFAULT '',created_at TEXT NOT NULL,UNIQUE(patient_id,study_uid));
    CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY,path TEXT NOT NULL,sha256 TEXT NOT NULL,size INTEGER NOT NULL);
    CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,status TEXT NOT NULL,stage TEXT NOT NULL,progress INTEGER DEFAULT 0,filename TEXT NOT NULL,sha256 TEXT DEFAULT '',preview TEXT DEFAULT '{}',result TEXT DEFAULT '{}',error TEXT DEFAULT '',created_at TEXT NOT NULL,updated_at TEXT NOT NULL,pid INTEGER DEFAULT 0);
  `);
  removeLegacyStudies(d);
  connection = d;
  return d;
}
/**
 * Earlier versions shipped a bundled demo dataset whose studies referenced
 * volumes through a static route that no longer exists. They have no source
 * archive to rebuild from, so they can never be opened or reconverted. Drop
 * them once, and drop the patient too when nothing else is attached to it.
 * A failure here must never stop the application from starting.
 */
function removeLegacyStudies(d: DatabaseSync) {
  try {
    const rows = d.prepare('SELECT id,patient_id,manifest FROM studies').all();
    for (const row of rows) {
      let series: { url?: unknown }[] = [];
      try {
        series = JSON.parse(String(row.manifest)).series ?? [];
      } catch {
        continue;
      }
      const stale = series.some(
        (s) =>
          typeof s.url === 'string' &&
          !s.url.startsWith('/api/library/assets/'),
      );
      if (!stale) continue;
      const patientId = String(row.patient_id);
      d.prepare('DELETE FROM studies WHERE id=?').run(String(row.id));
      // Saved regions and registrations reference the patient, and foreign keys
      // are on, so the patient row only goes once nothing points at it.
      const referenced = ['focus_regions', 'registrations'].some(
        (table) =>
          !!d
            .prepare(
              "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?",
            )
            .get(table) &&
          !!d
            .prepare(`SELECT 1 FROM ${table} WHERE patient_id=? LIMIT 1`)
            .get(patientId),
      );
      if (!referenced)
        d.prepare(
          'DELETE FROM patients WHERE id=? AND NOT EXISTS (SELECT 1 FROM studies WHERE patient_id=?)',
        ).run(patientId, patientId);
    }
  } catch (error) {
    console.warn('Could not clean up retired studies:', error);
  }
}
export function localMutation(request: Request) {
  const url = new URL(request.url);
  const origin = request.headers.get('origin');
  if (
    (origin && origin !== url.origin) ||
    request.headers.get('sec-fetch-site') === 'cross-site'
  )
    throw new Error('This request is only accepted from the local app.');
}
export function identifier(value: string) {
  if (!/^[a-zA-Z0-9-]{1,80}$/.test(value))
    throw new Error('Invalid identifier');
  return value;
}
export function job(id: string):
  | (Record<string, unknown> & {
      status: string;
      preview: unknown;
      result: unknown;
    })
  | null {
  const row = db().prepare('SELECT * FROM jobs WHERE id=?').get(identifier(id));
  if (!row) return null;
  if (
    ['inspecting', 'processing'].includes(String(row.status)) &&
    Number(row.pid) > 0
  ) {
    try {
      process.kill(Number(row.pid), 0);
    } catch {
      db()
        .prepare(
          "UPDATE jobs SET status='error',error=? WHERE id=? AND status IN ('inspecting','processing')",
        )
        .run(
          'Processing was interrupted. Discard the draft and upload the archive again.',
          id,
        );
      return job(id);
    }
  }
  return {
    ...row,
    status: String(row.status),
    preview: JSON.parse(String(row.preview)),
    result: JSON.parse(String(row.result)),
  };
}
export function startWorker(id: string, action: 'inspect' | 'convert') {
  identifier(id);
  const python = pythonPath();
  if (!existsSync(python)) {
    db()
      .prepare("UPDATE jobs SET status='error',error=? WHERE id=?")
      .run(SETUP_HINT, id);
    throw new Error(SETUP_HINT);
  }
  const logDir = path.join(dataRoot(), 'jobs', id);
  mkdirSync(logDir, { recursive: true });
  const log = openSync(path.join(logDir, 'worker.log'), 'a', 0o600);
  const p = spawn(
    python,
    [path.join(process.cwd(), 'scripts/import_mri.py'), dataRoot(), id, action],
    {
      detached: true,
      stdio: ['ignore', log, log],
      env: { ...process.env, PYTHONUNBUFFERED: '1' },
    },
  );
  closeSync(log);
  p.on('error', () =>
    db()
      .prepare("UPDATE jobs SET status='error',error=?,updated_at=? WHERE id=?")
      .run(
        'The processing worker could not be started',
        new Date().toISOString(),
        id,
      ),
  );
  db()
    .prepare('UPDATE jobs SET pid=? WHERE id=?')
    .run(p.pid || 0, id);
  p.unref();
}
export function newJob(filename: string) {
  const id = randomUUID(),
    now = new Date().toISOString();
  db()
    .prepare(
      'INSERT INTO jobs(id,status,stage,filename,created_at,updated_at) VALUES(?,?,?,?,?,?)',
    )
    .run(
      id,
      'created',
      'Waiting for the archive',
      filename.slice(0, 240),
      now,
      now,
    );
  return id;
}
export function failure(error: unknown, status = 400) {
  return Response.json(
    {
      error: error instanceof Error ? error.message : 'The action failed',
    },
    { status },
  );
}
