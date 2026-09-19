import { failure } from '@/lib/library';
import { registration } from '@/lib/timeline-server';
export async function GET(_r: Request, c: { params: Promise<{ id: string }> }) {
  try {
    return Response.json(registration((await c.params).id), {
      headers: { 'Cache-Control': 'no-store' },
    });
  } catch (e) {
    return failure(e);
  }
}
