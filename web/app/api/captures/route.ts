import { mkdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
import { dataRoot } from '@/lib/library';

export async function POST(request: Request) {
  const url = new URL(request.url);
  const origin = request.headers.get('origin');
  if (
    origin !== url.origin ||
    !['127.0.0.1', 'localhost', '[::1]'].includes(url.hostname)
  ) {
    return Response.json(
      { error: 'Only local application requests are accepted.' },
      { status: 403 },
    );
  }
  if (request.headers.get('content-type') !== 'image/png')
    return new Response('PNG required', { status: 415 });
  const limit = 16 * 1024 * 1024;
  if (Number(request.headers.get('content-length')) > limit)
    return new Response('Image too large', { status: 413 });
  const reader = request.body?.getReader();
  if (!reader) return new Response('Image required', { status: 400 });
  const chunks: Uint8Array[] = [];
  let length = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    length += value.byteLength;
    if (length > limit) {
      await reader.cancel();
      return new Response('Image too large', { status: 413 });
    }
    chunks.push(value);
  }
  const bytes = Buffer.concat(chunks);
  if (
    bytes.length < 24 ||
    !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  )
    return new Response('Invalid PNG', { status: 400 });
  const id = `OpenMRI-${randomUUID()}.png`;
  // Captures live beside the library data, never inside the source tree.
  const directory = path.join(dataRoot(), 'captures');
  await mkdir(directory, { recursive: true, mode: 0o700 });
  await writeFile(path.join(directory, id), bytes, { flag: 'wx', mode: 0o600 });
  return Response.json(
    { id, url: `/api/captures/${id}` },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}
