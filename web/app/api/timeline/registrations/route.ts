import { failure, localMutation } from '@/lib/library';
import { startRegistration } from '@/lib/timeline-server';
export async function POST(request: Request) {
  try {
    localMutation(request);
    return Response.json(startRegistration(await request.json()));
  } catch (e) {
    return failure(e);
  }
}
