import { chooseFolder, importFolder } from '@/lib/dental-import';
import { failure, localMutation } from '@/lib/library';

/**
 * Importa una cartella di DICOM, o chiede al sistema quale.
 *
 * Due gesti sulla stessa rotta perché sono lo stesso gesto diviso in due: `choose` apre il
 * pannello del sistema e restituisce un percorso, `import` prende un percorso e avvia
 * l'importazione. Chi non è su macOS salta il primo e scrive il percorso a mano.
 */
export async function POST(request: Request) {
  try {
    localMutation(request);
    const body = (await request.json()) as Record<string, unknown>;

    if (body.action === 'choose')
      return Response.json({ folder: await chooseFolder() });

    if (typeof body.folder !== 'string' || !body.folder.trim())
      throw new Error('Choose the folder with the DICOM files.');
    return Response.json(await importFolder(body.folder.trim()));
  } catch (e) {
    return failure(e);
  }
}
