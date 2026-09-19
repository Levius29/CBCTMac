import { newJob, failure, localMutation } from '@/lib/library';
export async function POST(request: Request) {
  try {
    localMutation(request);
    const { filename } = (await request.json()) as { filename?: unknown };
    if (typeof filename !== 'string' || !/\.zip$/i.test(filename))
      throw new Error('Choose a ZIP archive with DICOM or NIfTI files');
    return Response.json({ id: newJob(filename) });
  } catch (e) {
    return failure(e);
  }
}
