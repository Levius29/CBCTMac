'use client';

/**
 * Aprire una CBCT: i file `.dcm`, direttamente.
 *
 * # Il difetto che questo pannello toglie
 *
 * L'importatore dell'originale accetta un archivio ZIP. È sensato per un visore generico, ed è un
 * passo in più a ogni paziente per chi ha in mano una cartella di `.dcm`: bisogna ricordarsi di
 * comprimerla, e chi non ci pensa si trova un pannello che «non prende i dcm».
 *
 * # Nell'app del Mac
 *
 * Un pulsante solo, e il pannello del sistema che accetta **cartelle o file**. La prima versione
 * apriva un pannello di sole cartelle: dentro la cartella dell'esame i `.dcm` comparivano in
 * grigio, e chi lo usava concludeva — giustamente — che non si apriva nessun file. Ciò che si
 * sceglie non si carica: il motore lo legge dal disco. L'importazione parte appena si sceglie, e
 * il nome del paziente, se non lo si scrive, è quello che sta nel DICOM.
 *
 * # Nel browser
 *
 * Si scelgono i file, o la cartella, nel pannello del browser, e si caricano uno per volta: una
 * CBCT sono seicento file per mezzo gigabyte, e in un invio solo la memoria si riempie senza
 * poter dire a che punto si è. Resta anche la strada del percorso scritto a mano.
 */

import { useEffect, useEffectEvent, useRef, useState } from 'react';
import { FolderOpen, Files, LoaderCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';
import { desktopBridge, useDesktop } from '@/lib/desktop';

type Identity = { name?: string; birth_date?: string; sex?: string };
type Job = {
  status: string;
  stage?: string;
  error?: string;
  preview?: { patient?: Identity };
  result?: { patientId?: string; studyIds?: string[] };
};
export type Imported = { patientId?: string; studyIds?: string[] };

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function api<T>(route: string, init?: RequestInit): Promise<T> {
  const response = await fetch(route, init);
  const body = await response.json().catch(() => ({}));
  if (!response.ok)
    throw new Error(body.error || `${route}: ${response.status}`);
  return body as T;
}

const post = (payload: unknown) =>
  ({
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  }) satisfies RequestInit;

/** Quanti file viaggiano insieme: abbastanza per non aspettare, pochi per non ingolfare. */
const IN_FLIGHT = 4;

/** L'ultimo pezzo di un percorso: il nome di riserva quando il DICOM non ne porta uno. */
const lastName = (item: string) =>
  item.replace(/\/+$/, '').split('/').pop() || 'CBCT';

export default function FolderImport({
  onDone,
  initialPaths = [],
  chosenInApp = false,
}: {
  onDone: (imported: Imported) => void;
  /** Percorsi arrivati nell'indirizzo: si importano appena la pagina si apre. */
  initialPaths?: string[];
  /** Vero se l'app del Mac ha appena fatto scegliere un esame: lo si ritira e lo si importa. */
  chosenInApp?: boolean;
}) {
  const [chosen, setChosen] = useState<File[]>([]);
  const [paths, setPaths] = useState<string[]>(initialPaths);
  const [folder, setFolder] = useState('');
  const [patient, setPatient] = useState('');
  const [stage, setStage] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const desktop = useDesktop();
  const files = useRef<HTMLInputElement>(null);
  const directory = useRef<HTMLInputElement>(null);
  const started = useRef(false);

  // `webkitdirectory` non è un attributo che React conosca, ed è quello che trasforma il pannello
  // dei file nel pannello delle cartelle. Si mette a mano, una volta.
  useEffect(() => {
    directory.current?.setAttribute('webkitdirectory', '');
    directory.current?.setAttribute('directory', '');
  }, []);

  function pick(list: FileList | null) {
    setError('');
    const picked = Array.from(list ?? []).filter((file) => file.size > 0);
    setChosen(picked);
    if (picked.length) {
      setFolder('');
      setPaths([]);
    }
  }

  /**
   * Aspetta che il lavoro dell'originale arrivi in fondo, confermando il paziente al momento
   * giusto: con il nome scritto, o con quello che il DICOM dichiara.
   */
  async function follow(id: string, fallback: string): Promise<Imported> {
    let confirmed = false;
    for (let attempt = 0; attempt < 3600; attempt += 1) {
      await sleep(1000);
      const job = await api<Job>(`/api/library/imports/${id}`);
      if (job.stage) setStage(job.stage);
      if (job.status === 'error')
        throw new Error(job.error || 'The import stopped');
      if (job.status === 'review' && !confirmed) {
        confirmed = true;
        const dicom = job.preview?.patient ?? {};
        const typed = patient.trim();
        await api(
          `/api/library/imports/${id}`,
          post({
            patient: typed
              ? { name: typed }
              : {
                  name: dicom.name?.trim() || fallback,
                  birth_date: dicom.birth_date || '',
                  sex: dicom.sex || '',
                },
          }),
        );
      }
      if (job.status === 'complete') return job.result ?? {};
    }
    throw new Error('The import is taking too long. Check the engine log.');
  }

  async function run(selection: string[] = paths) {
    // Il primo cambio di stato dopo un'attesa: questa funzione parte anche all'apertura della
    // pagina, e lo stato non si cambia mentre React la sta ancora disegnando.
    await Promise.resolve();
    setBusy(true);
    setError('');
    if (selection.length) setPaths(selection);
    try {
      let imported: Imported;
      if (chosen.length) {
        setStage(`Sending ${chosen.length} files`);
        const { id } = await api<{ id: string }>(
          '/api/dental/upload',
          post({ action: 'start' }),
        );
        let sent = 0;
        for (let start = 0; start < chosen.length; start += IN_FLIGHT) {
          const batch = chosen.slice(start, start + IN_FLIGHT);
          await Promise.all(
            batch.map((file, offset) => {
              const index = start + offset;
              const name = encodeURIComponent(file.name);
              return fetch(
                `/api/dental/upload?id=${id}&index=${index}&name=${name}`,
                { method: 'PUT', body: file },
              ).then(async (response) => {
                if (!response.ok) {
                  const body = (await response.json().catch(() => ({}))) as {
                    error?: string;
                  };
                  throw new Error(body.error || `${file.name}: upload failed`);
                }
              });
            }),
          );
          sent += batch.length;
          setStage(`Sending files · ${sent} of ${chosen.length}`);
        }
        setStage('Packing the files');
        await api('/api/dental/upload', post({ action: 'finish', id }));
        imported = await follow(id, 'CBCT');
      } else {
        const sources = selection.length ? selection : [folder.trim()];
        setStage('Reading the files');
        const job = await api<{ id: string; files: number }>(
          '/api/dental/folder',
          post({ paths: sources }),
        );
        setStage(`${job.files} files · inspecting`);
        imported = await follow(job.id, lastName(sources[0]));
      }

      setStage('Done');
      setChosen([]);
      setPaths([]);
      setFolder('');
      setPatient('');
      if (files.current) files.current.value = '';
      if (directory.current) directory.current.value = '';
      onDone(imported);
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  // Dall'app del Mac si arriva qui con la scelta già fatta: si importa senza un clic in più. Il
  // segnale `started` fa sì che succeda una volta sola, qualunque sia il numero di disegni.
  const importChosen = useEffectEvent((selection: string[]) => {
    void run(selection);
  });
  useEffect(() => {
    if (started.current) return;
    const bridge = desktopBridge();
    const pending = initialPaths.length
      ? Promise.resolve(initialPaths)
      : chosenInApp && bridge
        ? bridge.takeChosenExam()
        : null;
    if (!pending) return;
    started.current = true;
    void pending.then((picked) => {
      if (picked.length) importChosen(picked);
    });
  }, [initialPaths, chosenInApp]);

  async function openExam() {
    const bridge = desktopBridge();
    if (!bridge) return;
    const picked = await bridge.chooseExam();
    if (!picked.length) return;
    setChosen([]);
    setFolder('');
    await run(picked);
  }

  const ready = chosen.length > 0 || paths.length > 0 || !!folder.trim();
  const summary = chosen.length
    ? `${chosen.length} files chosen · ${(
        chosen.reduce((total, file) => total + file.size, 0) /
        1024 ** 2
      ).toFixed(0)} MB`
    : paths.length === 1
      ? paths[0]
      : paths.length
        ? `${paths.length} items chosen`
        : folder.trim() || 'nothing chosen yet';

  return (
    <section className="border-border bg-card grid gap-3 rounded-xl border p-3 text-xs">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-medium">Open a CBCT</span>
        <span className="text-muted-foreground">
          {desktop
            ? 'Choose the folder of the exam, or the DICOM files in it. A CD or USB stick copy works as it is.'
            : 'Choose the DICOM files, or the folder that holds them. No ZIP needed.'}
        </span>
      </div>

      <input
        ref={files}
        className="hidden"
        type="file"
        multiple
        onChange={(event) => pick(event.target.files)}
      />
      <input
        ref={directory}
        className="hidden"
        type="file"
        multiple
        onChange={(event) => pick(event.target.files)}
      />

      <div className="flex flex-wrap items-end gap-2">
        {desktop ? (
          <Button disabled={busy} onClick={() => void openExam()}>
            {busy ? <LoaderCircle className="animate-spin" /> : <FolderOpen />}
            Open CBCT…
          </Button>
        ) : (
          <>
            <Button
              variant="outline"
              disabled={busy}
              onClick={() => files.current?.click()}
            >
              <Files /> Choose files…
            </Button>
            <Button
              variant="outline"
              disabled={busy}
              onClick={() => directory.current?.click()}
            >
              <FolderOpen /> Choose folder…
            </Button>
          </>
        )}
        <label className="flex w-56 flex-col gap-1">
          <span className="text-muted-foreground">Patient name (optional)</span>
          <input
            className="border-border bg-background h-8 rounded-lg border px-2"
            placeholder="from the DICOM files"
            value={patient}
            onChange={(event) => setPatient(event.target.value)}
          />
        </label>
        {desktop ? null : (
          <Button onClick={() => void run()} disabled={busy || !ready}>
            {busy ? <LoaderCircle className="animate-spin" /> : null}
            Import
          </Button>
        )}
        <span className="text-muted-foreground break-all">{summary}</span>
      </div>

      {desktop ? null : (
        <details className="text-muted-foreground">
          <summary className="cursor-pointer">
            A very large folder, already on this computer
          </summary>
          <div className="mt-2 flex flex-wrap items-end gap-2">
            <label className="flex min-w-[24rem] flex-1 flex-col gap-1">
              <span>Folder path</span>
              <input
                className="border-border bg-background h-8 rounded-lg border px-2"
                placeholder="/Users/you/Desktop/CBCT"
                value={folder}
                onChange={(event) => {
                  setFolder(event.target.value);
                  if (event.target.value) {
                    setChosen([]);
                    setPaths([]);
                  }
                }}
              />
            </label>
            <span>
              The server reads it from the disk instead of uploading it. Nothing
              leaves this computer either way.
            </span>
          </div>
        </details>
      )}

      {busy || stage ? <p className="text-muted-foreground">{stage}</p> : null}
      {error ? (
        <p className="border-destructive/40 bg-destructive/10 text-destructive rounded-lg border p-2">
          {error}
        </p>
      ) : null}
    </section>
  );
}
