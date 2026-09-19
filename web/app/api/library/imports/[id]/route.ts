import { createWriteStream } from 'node:fs';
import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { createHash } from 'node:crypto';
import {
  db,
  dataRoot,
  job,
  startWorker,
  identifier,
  failure,
  localMutation,
} from '@/lib/library';
type Context = { params: Promise<{ id: string }> };
export async function GET(_request: Request, context: Context) {
  try {
    const j = job((await context.params).id);
    return j
      ? Response.json(j, { headers: { 'Cache-Control': 'no-store' } })
      : failure(new Error('Import not found'), 404);
  } catch (e) {
    return failure(e);
  }
}
export async function PUT(request: Request, context: Context) {
  let id = '';
  try {
    localMutation(request);
    id = identifier((await context.params).id);
    if (!request.body) throw new Error('The archive is empty');
    const updated = db()
      .prepare(
        "UPDATE jobs SET status='uploading',stage='Uploading the archive' WHERE id=? AND status='created'",
      )
      .run(id);
    if (!updated.changes)
      throw new Error('This archive is already being uploaded');
    const dir = path.join(dataRoot(), 'jobs', id);
    await mkdir(dir, { recursive: true });
    let size = 0;
    const hash = createHash('sha256');
    const guard = new Transform({
      transform(chunk, _encoding, cb) {
        size += chunk.length;
        if (size > 2 * 1024 ** 3)
          return cb(new Error('An archive can be at most 2 GB'));
        hash.update(chunk);
        cb(null, chunk);
      },
    });
    await pipeline(
      Readable.fromWeb(request.body as never),
      guard,
      createWriteStream(path.join(dir, 'source.zip'), {
        flags: 'wx',
        mode: 0o600,
      }),
    );
    db()
      .prepare(
        "UPDATE jobs SET sha256=?,status='inspecting',stage='Inspecting DICOM',updated_at=? WHERE id=?",
      )
      .run(hash.digest('hex'), new Date().toISOString(), id);
    startWorker(id, 'inspect');
    return Response.json({ id });
  } catch (e) {
    if (id)
      db()
        .prepare(
          "UPDATE jobs SET status='error',error=? WHERE id=? AND status='uploading'",
        )
        .run(e instanceof Error ? e.message : 'Upload failed', id);
    return failure(e);
  }
}
export async function POST(request: Request, context: Context) {
  try {
    localMutation(request);
    const id = identifier((await context.params).id),
      body = (await request.json()) as {
        patient?: {
          id?: string;
          name?: string;
          birth_date?: string;
          sex?: string;
          notes?: string;
        };
      };
    const j = job(id);
    if (!j || j.status !== 'review')
      throw new Error('Wait for the archive inspection to finish first');
    const patient = body.patient;
    if (
      !patient ||
      (patient.id &&
        !db()
          .prepare('SELECT id FROM patients WHERE id=?')
          .get(String(patient.id)))
    )
      throw new Error('Patient not found');
    if (
      !patient.id &&
      (typeof patient.name !== 'string' || !patient.name.trim())
    )
      throw new Error('Enter a patient name');
    const result = {
      patient: {
        id: patient.id || '',
        name: String(patient.name || '').slice(0, 160),
        birth_date: String(patient.birth_date || '').slice(0, 10),
        sex: String(patient.sex || '').slice(0, 12),
        notes: String(patient.notes || '').slice(0, 4000),
      },
    };
    const updated = db()
      .prepare(
        "UPDATE jobs SET status='processing',stage='Preparing volumes',result=?,updated_at=? WHERE id=? AND status='review'",
      )
      .run(JSON.stringify(result), new Date().toISOString(), id);
    if (!updated.changes) throw new Error('The import has already started');
    startWorker(id, 'convert');
    return Response.json({ id });
  } catch (e) {
    return failure(e);
  }
}
export async function DELETE(request: Request, context: Context) {
  try {
    localMutation(request);
    const id = identifier((await context.params).id);
    const j = job(id);
    if (!j || !['created', 'review', 'error'].includes(String(j.status)))
      throw new Error('Wait for processing to finish');
    await rm(path.join(dataRoot(), 'jobs', id), {
      recursive: true,
      force: true,
    });
    db().prepare("UPDATE jobs SET status='cancelled' WHERE id=?").run(id);
    return Response.json({ ok: true });
  } catch (e) {
    return failure(e);
  }
}
