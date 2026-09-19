import { createReadStream, existsSync, statSync } from 'node:fs';
import path from 'node:path';
import { Readable } from 'node:stream';
import { outputDirectory } from '@/lib/dental';
import { failure, identifier } from '@/lib/library';

/**
 * Serve un'immagine ricostruita.
 *
 * Il percorso arriva dall'esterno, quindi ogni pezzo viene **riconosciuto**, non ripulito: la
 * serie e la chiave passano da `identifier`, il resto deve corrispondere a uno dei due nomi che
 * questo modulo produce. Un elenco di nomi ammessi non ha traversali da sanificare, perché non
 * accetta niente che non sia in elenco.
 */
const allowed = /^(panorama\.png|axial\.png|sections\/\d{4}\.png)$/;

export async function GET(
  request: Request,
  context: { params: Promise<{ path: string[] }> },
) {
  try {
    const segments = (await context.params).path ?? [];
    if (segments.length < 3) throw new Error('File not found');
    const [series, key, ...rest] = segments;
    const name = rest.join('/');
    if (!allowed.test(name)) throw new Error('File not found');

    const file = path.join(
      outputDirectory(identifier(series), identifier(key)),
      name,
    );
    if (!existsSync(file)) return failure(new Error('File not found'), 404);

    const size = statSync(file).size;
    const etag = `"${key}-${name.replace(/\W/g, '')}-${size}"`;
    if (request.headers.get('if-none-match') === etag)
      return new Response(null, { status: 304 });

    return new Response(
      Readable.toWeb(createReadStream(file)) as ReadableStream,
      {
        headers: {
          'Content-Type': 'image/png',
          'Content-Length': String(size),
          // La chiave contiene le opzioni, quindi un'immagine a quella chiave non cambia mai.
          'Cache-Control': 'private,max-age=31536000,immutable',
          ETag: etag,
          'X-Content-Type-Options': 'nosniff',
        },
      },
    );
  } catch (e) {
    return failure(e, 404);
  }
}
