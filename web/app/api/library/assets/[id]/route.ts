import { createReadStream } from 'node:fs';
import { Readable } from 'node:stream';
import path from 'node:path';
import { db, dataRoot, identifier, failure } from '@/lib/library';
export async function GET(
  request: Request,
  c: { params: Promise<{ id: string }> },
) {
  try {
    const a = db()
      .prepare('SELECT * FROM assets WHERE id=?')
      .get(identifier((await c.params).id));
    if (!a) return failure(new Error('File not found'), 404);
    const etag = `"${String(a.sha256)}"`;
    if (request.headers.get('if-none-match') === etag)
      return new Response(null, { status: 304 });
    return new Response(
      Readable.toWeb(
        createReadStream(
          path.isAbsolute(String(a.path))
            ? String(a.path)
            : path.join(dataRoot(), String(a.path)),
        ),
      ) as ReadableStream,
      {
        headers: {
          'Content-Type': 'application/octet-stream',
          'Content-Length': String(a.size),
          'Cache-Control': 'private,max-age=31536000,immutable',
          ETag: etag,
          'X-Content-Type-Options': 'nosniff',
        },
      },
    );
  } catch (e) {
    return failure(e);
  }
}
