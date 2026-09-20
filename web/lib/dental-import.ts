/**
 * Importare una **cartella** di DICOM, senza comprimerla a mano.
 *
 * # Il difetto che questo file toglie di mezzo
 *
 * L'importatore accetta un archivio ZIP, perché un browser sa dare un file e non una cartella. Ma
 * ciò che si ha in mano è una cartella — la chiavetta del centro radiologico, l'esportazione
 * dell'apparecchio — e comprimerla in Finder prima di ogni paziente è un passo in più che non
 * serve a niente: il programma gira sullo stesso computer dove sta la cartella, quindi il server
 * può leggerla da sé.
 *
 * # Come si innesta senza toccare niente di loro
 *
 * Non si duplica l'importazione: si prepara l'archivio dove il loro lavoro se lo aspetta —
 * `jobs/<id>/source.zip` — e poi si consegna il lavoro al loro motore, con le loro funzioni. Da
 * quel momento in poi è un'importazione identica a quella che partirebbe dal browser: stessa
 * ispezione, stessa conferma del paziente, stessa conversione.
 */
import { execFile } from 'node:child_process';
import { existsSync, statSync } from 'node:fs';
import path from 'node:path';
import {
  SETUP_HINT,
  dataRoot,
  db,
  newJob,
  pythonPath,
  startWorker,
} from '@/lib/library';

/** Quanto si aspetta la compressione di una cartella grande. */
const ZIP_TIMEOUT_MS = 15 * 60 * 1000;

function runPython(script: string, args: string[], timeout: number) {
  const python = pythonPath();
  if (!existsSync(python)) throw new Error(SETUP_HINT);
  return new Promise<string>((resolve, reject) => {
    execFile(
      python,
      [path.join(process.cwd(), script), ...args],
      { timeout, maxBuffer: 8 * 1024 * 1024 },
      (error, stdout, stderr) => {
        if (!error) return resolve(stdout);
        const lines = String(stderr || '')
          .trim()
          .split('\n');
        const last = lines[lines.length - 1] || '';
        reject(
          new Error(
            last.replace(/^\w*(Error|Exception):\s*/, '') ||
              'The folder could not be read.',
          ),
        );
      },
    );
  });
}

/**
 * Apre il pannello di scelta della cartella del sistema.
 *
 * Solo su macOS, e senza fingere altrove: un campo di testo in cui incollare il percorso resta la
 * strada che funziona ovunque, e questo la accorcia dove si può. `osascript` è parte del sistema,
 * quindi non aggiunge niente da installare.
 */
export function chooseFolder() {
  if (process.platform !== 'darwin')
    throw new Error(
      'Choosing a folder only works on macOS. Type the path instead.',
    );
  return new Promise<string>((resolve) => {
    execFile(
      '/usr/bin/osascript',
      [
        '-e',
        'POSIX path of (choose folder with prompt "Choose the folder with the DICOM files")',
      ],
      { timeout: 5 * 60 * 1000 },
      (error, stdout) => {
        // Annullare il pannello non è un guasto: è una risposta, e vale «nessuna cartella».
        if (error) return resolve('');
        resolve(stdout.trim());
      },
    );
  });
}

/** Che cosa c'è dentro la cartella, prima di toccarla. */
export function describeFolder(folder: string) {
  const full = path.resolve(
    folder.replace(/^~(?=\/|$)/, process.env.HOME || '~'),
  );
  if (!existsSync(full) || !statSync(full).isDirectory())
    throw new Error(`There is no folder at «${full}».`);
  return full;
}

/**
 * Prepara l'importazione di una cartella e la consegna al motore di OpenMRI.
 *
 * Restituisce l'identificativo del lavoro: da lì in avanti valgono le rotte dell'originale —
 * `GET /api/library/imports/<id>` per seguirlo, `POST` con il paziente per confermarlo.
 */
export async function importFolder(folder: string) {
  const full = describeFolder(folder);
  const id = newJob(path.basename(full) || 'folder');
  const archive = path.join(dataRoot(), 'jobs', id, 'source.zip');

  try {
    db()
      .prepare(
        "UPDATE jobs SET status='uploading',stage='Reading the folder' WHERE id=?",
      )
      .run(id);
    const summary = JSON.parse(
      await runPython('scripts/zip_folder.py', [full, archive], ZIP_TIMEOUT_MS),
    ) as { files: number; bytes: number; sha256: string };

    db()
      .prepare(
        "UPDATE jobs SET sha256=?,status='inspecting',stage='Inspecting DICOM',updated_at=? WHERE id=?",
      )
      .run(summary.sha256, new Date().toISOString(), id);
    startWorker(id, 'inspect');
    return { id, ...summary, folder: full };
  } catch (error) {
    db()
      .prepare("UPDATE jobs SET status='error',error=? WHERE id=?")
      .run(
        error instanceof Error ? error.message : 'The folder could not be read',
        id,
      );
    throw error;
  }
}
