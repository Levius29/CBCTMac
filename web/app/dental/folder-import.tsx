'use client';

/**
 * Importare una cartella di DICOM senza comprimerla.
 *
 * Il pannello fa da sé tutto il giro dell'importazione — prepara l'archivio, aspetta
 * l'ispezione, conferma il paziente, aspetta la conversione — perché chi ha in mano una cartella
 * vuole un gesto solo, non una procedura in quattro schermate. Ciò che si vede mentre lavora è la
 * riga di stato che manda il motore dell'originale, non una nostra invenzione: se si ferma, si
 * ferma dicendo dove.
 */

import { useState } from 'react';
import { FolderOpen, LoaderCircle } from 'lucide-react';
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

export default function FolderImport({ onDone }: { onDone: () => void }) {
  const [folder, setFolder] = useState('');
  const [patient, setPatient] = useState('');
  const [stage, setStage] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function choose() {
    setError('');
    try {
      const result = await api<{ folder: string }>(
        '/api/dental/folder',
        post({ action: 'choose' }),
      );
      if (result.folder) setFolder(result.folder);
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function run() {
    if (!folder.trim() || !patient.trim()) return;
    setBusy(true);
    setError('');
    setStage('Reading the folder');
    try {
      const started = await api<{ id: string; files: number }>(
        '/api/dental/folder',
        post({ folder }),
      );
      setStage(`${started.files} files · inspecting`);

      let confirmed = false;
      for (let attempt = 0; attempt < 1800; attempt += 1) {
        await sleep(1000);
        const job = await api<Job>(`/api/library/imports/${started.id}`);
        if (job.stage) setStage(job.stage);
        if (job.status === 'error')
          throw new Error(job.error || 'The import stopped');
        if (job.status === 'review' && !confirmed) {
          confirmed = true;
          await api(
            `/api/library/imports/${started.id}`,
            post({ patient: { name: patient.trim() } }),
          );
        }
        if (job.status === 'complete') {
          setStage('Done');
          setFolder('');
          setPatient('');
          onDone();
          return;
        }
      }
      throw new Error('The import is taking too long. Check the server log.');
    } catch (e) {
      setError((e as Error).message);
    } finally {
      setBusy(false);
    }
  }

  return (
    <section className="border-border bg-card grid gap-3 rounded-xl border p-3 text-xs">
      <div className="flex flex-wrap items-center gap-2">
        <span className="text-sm font-medium">
          Import a folder of DICOM files
        </span>
        <span className="text-muted-foreground">
          No ZIP needed: the program reads the folder from this computer.
        </span>
      </div>
      <div className="flex flex-wrap items-end gap-2">
        <label className="flex min-w-[22rem] flex-1 flex-col gap-1">
          <span className="text-muted-foreground">Folder</span>
          <input
            className="border-border bg-background h-8 rounded-lg border px-2"
            placeholder="/Users/you/Desktop/CBCT"
            value={folder}
            onChange={(event) => setFolder(event.target.value)}
          />
        </label>
        <Button variant="outline" onClick={() => void choose()} disabled={busy}>
          <FolderOpen /> Choose…
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
        <Button
          onClick={() => void run()}
          disabled={busy || !folder.trim() || !patient.trim()}
        >
          {busy ? <LoaderCircle className="animate-spin" /> : null}
          Import
        </Button>
      </div>
      {busy || stage ? <p className="text-muted-foreground">{stage}</p> : null}
      {error ? (
        <p className="border-destructive/40 bg-destructive/10 text-destructive rounded-lg border p-2">
          {error}
        </p>
      ) : null}
    </section>
  );
}
