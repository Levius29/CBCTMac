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
    // Il gesto sulla curva sta fuori dalle opzioni di proposito: salvare o dimenticare non cambia
    // l'immagine, quindi non deve cambiare la chiave della cache.
    const action =
      body.curveAction === 'save' || body.curveAction === 'forget'
        ? body.curveAction
        : undefined;
    return Response.json(
      await buildDental(body.seriesId, body.options, action),
    );
  } catch (e) {
    return failure(e);
  }
}
