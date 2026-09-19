import { db, failure, localMutation } from '@/lib/library';
export async function GET() {
  try {
    const d = db();
    return Response.json(
      {
        patients: d.prepare('SELECT * FROM patients ORDER BY created_at').all(),
        studies: d
          .prepare(
            'SELECT id,patient_id,date,label,body_part,created_at FROM studies ORDER BY date DESC',
          )
          .all(),
        jobs: d
          .prepare(
            "SELECT id,status,stage,progress,filename,error FROM jobs WHERE status NOT IN ('complete','cancelled') ORDER BY created_at DESC LIMIT 20",
          )
          .all(),
        cache: d
          .prepare(
            'SELECT count(*) AS files,coalesce(sum(size),0) AS bytes FROM assets',
          )
          .get(),
      },
      { headers: { 'Cache-Control': 'no-store' } },
    );
  } catch (e) {
    return failure(e, 500);
  }
}
export async function PATCH(request: Request) {
  try {
    localMutation(request);
    const p = (await request.json()) as Record<string, unknown>;
    if (
      typeof p.id !== 'string' ||
      typeof p.name !== 'string' ||
      !p.name.trim() ||
      p.name.length > 160
    )
      throw new Error('Enter a patient name');
    db()
      .prepare(
        'UPDATE patients SET name=?,birth_date=?,sex=?,notes=? WHERE id=?',
      )
      .run(
        p.name.trim(),
        (typeof p.birth_date === 'string' ? p.birth_date : '').slice(0, 10),
        (typeof p.sex === 'string' ? p.sex : '').slice(0, 12),
        (typeof p.notes === 'string' ? p.notes : '').slice(0, 4000),
        p.id,
      );
    return Response.json({ ok: true });
  } catch (e) {
    return failure(e);
  }
}
