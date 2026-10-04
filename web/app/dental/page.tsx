import DentalWorkspace from './dental-workspace';

/**
 * Due modi di arrivare qui con un esame già scelto, letti sul server perché il pannello
 * d'importazione nasca aperto e l'importazione parta da sola:
 *
 * - `?import=chosen` — dall'app del Mac: ⌘O, o un pulsante d'importazione, ha aperto il pannello
 *   del sistema, e ciò che si è scelto aspetta nell'app che la pagina lo ritiri;
 * - `?path=` — un percorso per parametro, scritto a mano o da uno script.
 */
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { path, import: chosen } = await searchParams;
  const initialPaths = (Array.isArray(path) ? path : [path]).filter(
    (item): item is string => typeof item === 'string' && !!item,
  );
  return (
    <DentalWorkspace
      initialPaths={initialPaths}
      chosenInApp={chosen === 'chosen'}
    />
  );
}
