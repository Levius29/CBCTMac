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
 * Qui si scelgono i file — o la cartella — nel pannello del browser, che è il gesto che tutti
 * conoscono. Il resto succede dopo: il server li raduna, ne fa l'archivio dove il motore se lo
 * aspetta, e da lì è un'importazione identica a quella di sempre.
 *
 * # Perché si caricano uno per uno
 *
 * Una CBCT sono seicento file per mezzo gigabyte. In un invio solo la memoria si riempie e non si
 * può dire a che punto si è: o finisce, o fallisce dopo due minuti di nulla. Uno per volta si
 * vede «142 di 600», e chi guarda sa che sta andando.
 *
 * Resta anche la strada del percorso: per una cartella molto grande, già sul computer, leggerla da
 * lì è più svelto che caricarla — e non passa da nessuna parte.
 */

import { useEffect, useRef, useState } from 'react';
import { FolderOpen, Files, LoaderCircle } from 'lucide-react';
import { Button } from '@/components/ui/button';

type Job = { status: string; stage?: string; error?: string };

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

export default function FolderImport({ onDone }: { onDone: () => void }) {
  const [chosen, setChosen] = useState<File[]>([]);
  const [folder, setFolder] = useState('');
  const [patient, setPatient] = useState('');
  const [stage, setStage] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const files = useRef<HTMLInputElement>(null);
  const directory = useRef<HTMLInputElement>(null);

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
    if (picked.length) setFolder('');
  }

  /** Aspetta che il lavoro dell'originale arrivi in fondo, confermando il paziente al momento giusto. */
  async function follow(id: string) {
    let confirmed = false;
    for (let attempt = 0; attempt < 3600; attempt += 1) {
      await sleep(1000);
      const job = await api<Job>(`/api/library/imports/${id}`);
      if (job.stage) setStage(job.stage);
      if (job.status === 'error')
        throw new Error(job.error || 'The import stopped');
      if (job.status === 'review' && !confirmed) {
        confirmed = true;
        await api(
          `/api/library/imports/${id}`,
          post({ patient: { name: patient.trim() } }),
        );
      }
      if (job.status === 'complete') return;
    }
    throw new Error('The import is taking too long. Check the server log.');
  }

  async function run() {
    if (!patient.trim() || (!chosen.length && !folder.trim())) return;
    setBusy(true);
    setError('');
    try {
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
        await follow(id);
      } else {
        setStage('Reading the folder');
        const started = await api<{ id: string; files: number }>(
          '/api/dental/folder',
          post({ folder }),
        );
        setStage(`${started.files} files · inspecting`);
        await follow(started.id);
      }

      setStage('Done');
      setChosen([]);
      setFolder('');
      setPatient('');
      if (files.current) files.current.value = '';
      if (directory.current) directory.current.value = '';
      onDone();
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  const ready = patient.trim() && (chosen.length > 0 || folder.trim());

  return (
    <section className="border-border bg-card grid gap-3 rounded-xl border p-3 text-xs">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-medium">Open a CBCT</span>
        <span className="text-muted-foreground">
          Choose the DICOM files, or the folder that holds them. No ZIP needed.
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
        <label className="flex w-56 flex-col gap-1">
          <span className="text-muted-foreground">Patient name</span>
          <input
            className="border-border bg-background h-8 rounded-lg border px-2"
            placeholder="Rossi Mario"
            value={patient}
            onChange={(event) => setPatient(event.target.value)}
          />
        </label>
        <Button onClick={() => void run()} disabled={busy || !ready}>
          {busy ? <LoaderCircle className="animate-spin" /> : null}
          Import
        </Button>
        <span className="text-muted-foreground">
          {chosen.length
            ? `${chosen.length} files chosen · ${(
                chosen.reduce((total, file) => total + file.size, 0) /
                1024 ** 2
              ).toFixed(0)} MB`
            : 'nothing chosen yet'}
        </span>
      </div>

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
                if (event.target.value) setChosen([]);
              }}
            />
          </label>
          <span>
            The server reads it from the disk instead of uploading it. Nothing
            leaves this computer either way.
          </span>
        </div>
      </details>

      {busy || stage ? <p className="text-muted-foreground">{stage}</p> : null}
      {error ? (
        <p className="border-destructive/40 bg-destructive/10 text-destructive rounded-lg border p-2">
          {error}
        </p>
      ) : null}
    </section>
  );
}
