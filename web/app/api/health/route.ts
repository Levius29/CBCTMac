export function GET() {
  return Response.json(
    { app: 'openmri', version: '2.0.0' },
    { headers: { 'Cache-Control': 'no-store' } },
  );
}
