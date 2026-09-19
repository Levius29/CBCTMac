import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { dataRoot } from '@/lib/library';
export async function GET(
  _request: Request,
  context: { params: Promise<{ id: string }> },
) {
  const { id } = await context.params;
  if (!/^OpenMRI-[0-9a-f-]{36}\.png$/.test(id))
    return new Response('Not found', { status: 404 });
  try {
    const data = await readFile(path.join(dataRoot(), 'captures', id));
    return new Response(data, {
      headers: {
        'Content-Type': 'image/png',
        'Content-Disposition': `inline; filename="${id}"`,
        'Cache-Control': 'no-store',
        'X-Content-Type-Options': 'nosniff',
      },
    });
  } catch {
    return new Response('Not found', { status: 404 });
  }
}
