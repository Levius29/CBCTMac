import { buildDental } from '@/lib/dental';
import { failure, localMutation } from '@/lib/library';

/**
 * Ricostruisce panoramica e sezioni per una serie.
 *
 * È un POST e non un GET perché può durare minuti e scrive su disco: un GET lungo lo ripeterebbe
 * ogni ricarica di pagina, e un proxy potrebbe tenerselo in cache. La cache vera sta a valle, in
 * `buildDental`, ed è indicizzata dalle opzioni.
 */
export async function POST(request: Request) {
  try {
    localMutation(request);
    const body = (await request.json()) as Record<string, unknown>;
    if (typeof body.seriesId !== 'string')
      throw new Error('Choose a series to reconstruct.');
    return Response.json(await buildDental(body.seriesId, body.options));
  } catch (e) {
    return failure(e);
  }
}
