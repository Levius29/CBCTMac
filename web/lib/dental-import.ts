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
import { createHash } from 'node:crypto';
import { createReadStream, existsSync, statSync } from 'node:fs';
import { copyFile, mkdir, rm } from 'node:fs/promises';
import path from 'node:path';
import {
  SETUP_HINT,
  dataRoot,
  db,
  identifier,
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

/** Dove si radunano i file che arrivano dal browser, prima di diventare un archivio. */
export function uploadDirectory(id: string) {
  return path.join(dataRoot(), 'jobs', identifier(id), 'incoming');
}

/**
 * Chiude un caricamento: dai file arrivati fa l'archivio e consegna il lavoro al motore.
 *
 * È lo stesso passaggio dell'importazione da cartella — stessa compressione, stesse funzioni
 * dell'originale — e cambia solo da dove vengono i file: lì stavano già su disco, qui sono appena
 * arrivati dal browser.
 */
export async function finishUpload(id: string) {
  const folder = uploadDirectory(id);
  const archive = path.join(dataRoot(), 'jobs', id, 'source.zip');
  try {
    db()
      .prepare("UPDATE jobs SET stage='Packing the files' WHERE id=?")
      .run(id);
    const summary = JSON.parse(
      await runPython(
        'scripts/zip_folder.py',
        [folder, archive],
        ZIP_TIMEOUT_MS,
      ),
    ) as { files: number; bytes: number; sha256: string };

    db()
      .prepare(
        "UPDATE jobs SET sha256=?,status='inspecting',stage='Inspecting DICOM',updated_at=? WHERE id=?",
      )
      .run(summary.sha256, new Date().toISOString(), id);
    startWorker(id, 'inspect');
    // I file sciolti non servono più: l'archivio li contiene, e lasciarli raddoppierebbe lo
    // spazio occupato da ogni importazione.
    await rm(folder, { recursive: true, force: true });
    return { id, ...summary };
  } catch (error) {
    db()
      .prepare("UPDATE jobs SET status='error',error=? WHERE id=?")
      .run(
        error instanceof Error ? error.message : 'The files could not be read',
        id,
      );
    throw error;
  }
}

/** Un percorso scritto o scelto, reso assoluto e controllato prima di toccarlo. */
export function describePath(chosen: string) {
  const full = path.resolve(
    chosen.trim().replace(/^~(?=\/|$)/, process.env.HOME || '~'),
  );
  if (!existsSync(full)) throw new Error(`There is nothing at «${full}».`);
  return full;
}

/** Che cosa c'è dentro la cartella, prima di toccarla. */
export function describeFolder(folder: string) {
  const full = describePath(folder);
  if (!statSync(full).isDirectory())
    throw new Error(`There is no folder at «${full}».`);
  return full;
}

async function sha256(file: string) {
  const hash = createHash('sha256');
  for await (const chunk of createReadStream(file))
    hash.update(chunk as Buffer);
  return hash.digest('hex');
}

/**
 * Prepara l'importazione di ciò che si è scelto e la consegna al motore di OpenMRI.
 *
 * Cartelle, file `.dcm`, o un misto: nell'app del Mac il pannello accetta tutto, perché chi ha in
 * mano una CBCT non deve sapere se il programma vuole la cartella o i file. Un archivio ZIP scelto
 * da solo è già ciò che il motore vuole, e si copia com'è.
 *
 * Restituisce l'identificativo del lavoro: da lì in avanti valgono le rotte dell'originale —
 * `GET /api/library/imports/<id>` per seguirlo, `POST` con il paziente per confermarlo.
 */
export async function importPaths(chosen: string[]) {
  if (!chosen.length) throw new Error('Choose a folder or the DICOM files.');
  const paths = chosen.map(describePath);
  const single = paths.length === 1 ? paths[0] : '';
  const id = newJob(path.basename(single || path.dirname(paths[0])) || 'CBCT');
  const archive = path.join(dataRoot(), 'jobs', id, 'source.zip');

  try {
    db()
      .prepare(
        "UPDATE jobs SET status='uploading',stage='Reading the files' WHERE id=?",
      )
      .run(id);
    let summary: {
      files: number;
      bytes: number;
      sha256: string;
      folder?: string;
    };
    if (single && /\.zip$/i.test(single) && statSync(single).isFile()) {
      await mkdir(path.dirname(archive), { recursive: true });
      await copyFile(single, archive);
      summary = {
        files: 1,
        bytes: statSync(archive).size,
        sha256: await sha256(archive),
        folder: path.dirname(single),
      };
    } else {
      summary = JSON.parse(
        await runPython(
          'scripts/zip_folder.py',
          [...paths, archive],
          ZIP_TIMEOUT_MS,
        ),
      ) as typeof summary;
    }

    db()
      .prepare(
        "UPDATE jobs SET sha256=?,status='inspecting',stage='Inspecting DICOM',updated_at=? WHERE id=?",
      )
      .run(summary.sha256, new Date().toISOString(), id);
    startWorker(id, 'inspect');
    return { id, ...summary, paths };
  } catch (error) {
    db()
      .prepare("UPDATE jobs SET status='error',error=? WHERE id=?")
      .run(
        error instanceof Error ? error.message : 'The files could not be read',
        id,
      );
    throw error;
  }
}

/** La cartella scritta a mano: la stessa importazione, con un percorso solo. */
export function importFolder(folder: string) {
  return importPaths([describeFolder(folder)]);
}
