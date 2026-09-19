import { db, identifier, failure } from '@/lib/library';
export async function GET(_r: Request, c: { params: Promise<{ id: string }> }) {
  try {
    const s = db()
      .prepare('SELECT manifest FROM studies WHERE id=?')
      .get(identifier((await c.params).id));
    return s
      ? Response.json(JSON.parse(String(s.manifest)), {
          headers: { 'Cache-Control': 'no-store' },
        })
      : failure(new Error('Study not found'), 404);
  } catch (e) {
    return failure(e);
  }
}
