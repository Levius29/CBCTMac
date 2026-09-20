import { createWriteStream } from 'node:fs';
import { mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import { Readable, Transform } from 'node:stream';
import { pipeline } from 'node:stream/promises';
import { finishUpload, uploadDirectory } from '@/lib/dental-import';
import { db, failure, localMutation, newJob, identifier } from '@/lib/library';

/**
 * Caricare i `.dcm` **uno per uno**, direttamente dal browser.
 *
 * # Perché file per file e non tutti insieme
 *
 * Una CBCT sono seicento file per mezzo gigabyte. Mandarli in un solo invio significa tenerli
 * tutti in memoria — del browser e del server — e non poter dire a che punto si è: o finisce, o
 * fallisce dopo due minuti di nulla. Uno per volta ciascuno scorre su disco appena arriva, la
 * memoria resta piatta, e la pagina può dire «142 di 600».
 *
 * # Perché non serve comprimerli prima
 *
 * Perché lo fa il server alla fine, nel punto esatto in cui il motore dell'originale si aspetta
 * l'archivio. Chi usa il programma sceglie i file — o la cartella — nel pannello del browser, che
 * è il gesto che conosce, e non deve sapere che più a valle esiste uno ZIP.
 */

/** Il tetto complessivo di un'importazione, lo stesso dell'originale. */
const MAXIMUM_BYTES = 2 * 1024 ** 3;

/**
 * Il nome con cui un file arriva non è un nome di cui fidarsi: può contenere percorsi, due punti,
 * o caratteri che su un altro sistema significano altro. Si tiene solo ciò che serve a
 * distinguerlo, e l'ordine lo dà il numero.
 */
function safeName(index: number, name: string | null) {
  const base = (name ?? '')
    .split(/[\\/]/)
    .pop()!
    .replace(/[^A-Za-z0-9._-]/g, '')
    .slice(-60);
  return `${String(index).padStart(6, '0')}-${base || 'file'}`;
}

export async function POST(request: Request) {
  try {
    localMutation(request);
    const body = (await request.json()) as Record<string, unknown>;

    if (body.action === 'start') {
      const id = newJob('files');
      await mkdir(uploadDirectory(id), { recursive: true, mode: 0o700 });
      db()
        .prepare(
          "UPDATE jobs SET status='uploading',stage='Receiving files' WHERE id=?",
        )
        .run(id);
      return Response.json({ id });
    }

    if (body.action === 'finish') {
      if (typeof body.id !== 'string') throw new Error('Which upload?');
      return Response.json(await finishUpload(identifier(body.id)));
    }

    if (body.action === 'cancel') {
      if (typeof body.id !== 'string') throw new Error('Which upload?');
      const id = identifier(body.id);
      await rm(uploadDirectory(id), { recursive: true, force: true });
      db().prepare("UPDATE jobs SET status='cancelled' WHERE id=?").run(id);
      return Response.json({ id });
    }

    throw new Error('Unknown action');
  } catch (e) {
    return failure(e);
  }
}

export async function PUT(request: Request) {
  try {
    localMutation(request);
    const url = new URL(request.url);
    const id = identifier(url.searchParams.get('id') ?? '');
    const index = Number(url.searchParams.get('index') ?? '0');
    if (!Number.isInteger(index) || index < 0 || index > 60_000)
      throw new Error('Too many files: the limit is 60,000');
    if (!request.body) throw new Error('That file is empty');

    const destination = path.join(
      uploadDirectory(id),
      safeName(index, url.searchParams.get('name')),
    );
    let size = 0;
    const guard = new Transform({
      transform(chunk, _encoding, callback) {
        size += chunk.length;
        if (size > MAXIMUM_BYTES)
          return callback(new Error('A single file is too large'));
        callback(null, chunk);
      },
    });
    await pipeline(
      Readable.fromWeb(request.body as never),
      guard,
      createWriteStream(destination, { flags: 'w', mode: 0o600 }),
    );
    return Response.json({ bytes: size });
  } catch (e) {
    return failure(e);
  }
}
