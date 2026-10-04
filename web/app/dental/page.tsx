import DentalWorkspace from './dental-workspace';

/**
 * `?folder=` arriva dall'app del Mac: ⌘O sceglie la cartella e apre questa pagina con il percorso
 * già scritto. Letto qui, sul server, il pannello nasce aperto e compilato — invece di aprirsi un
 * istante dopo, quando il browser avrebbe letto l'indirizzo da sé.
 */
export default async function Page({
  searchParams,
}: {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { folder } = await searchParams;
  return (
    <DentalWorkspace initialFolder={typeof folder === 'string' ? folder : ''} />
  );
}
