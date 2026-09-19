import { failure, localMutation } from '@/lib/library';
import {
  timelineCatalog,
  regions,
  saveRegion,
  reviewRegion,
  timelineDB,
} from '@/lib/timeline-server';
export async function GET(request: Request) {
  try {
    const p = new URL(request.url).searchParams.get('patientId') || '';
    return Response.json(
      { studies: timelineCatalog(p), regions: regions(p) },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (e) {
    return failure(e);
  }
}
export async function POST(request: Request) {
  try {
    localMutation(request);
    return Response.json(saveRegion(await request.json()));
  } catch (e) {
    return failure(e);
  }
}
export async function PATCH(request: Request) {
  try {
    localMutation(request);
    return Response.json(reviewRegion(await request.json()));
  } catch (e) {
    return failure(e);
  }
}
export async function DELETE(request: Request) {
  try {
    localMutation(request);
    const { patientId, id } = (await request.json()) as {
      patientId: string;
      id: string;
    };
    timelineDB()
      .prepare('DELETE FROM focus_regions WHERE id=? AND patient_id=?')
      .run(id, patientId);
    return Response.json({ ok: true });
  } catch (e) {
    return failure(e);
  }
}
