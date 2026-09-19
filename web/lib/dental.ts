/**
 * Panoramica ricostruita e sezioni trasversali: il lato server.
 *
 * File nostro, aggiunto al tree di OpenMRI: non tocca nessun loro file, quindi gli aggiornamenti
 * dell'originale continuano ad arrivare puliti. Il calcolo sta in `scripts/dental_panorama.py` e
 * gira nell'ambiente Python che OpenMRI ha già — nessuna dipendenza nuova da installare.
 *
 * Qui dentro c'è solo il contorno: dove sta il volume di una serie, quali opzioni sono ammesse,
 * dove finiscono le immagini e come si evita di rifare due volte lo stesso lavoro.
 */
import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import {
  SETUP_HINT,
  dataRoot,
  db,
  identifier,
  pythonPath,
} from '@/lib/library';

/** Quanto si aspetta una ricostruzione prima di dichiararla persa. */
const TIMEOUT_MS = 10 * 60 * 1000;

export type DentalOptions = {
  /** Millimetri per pixel della panoramica. La scala è isotropa: vale per entrambi gli assi. */
  mmPerPixel: number;
  /** Estensione verticale della panoramica. */
  heightMM: number;
  /**
   * Spessore campionato attorno alla curva, lungo la normale vestibolo-linguale.
   *
   * Sotto i 10 mm si vede una fetta sola e i denti fuori dalla curva spariscono; sopra i 30 tutto
   * si sovrappone e l'immagine diventa una nebbia.
   */
  slabThicknessMM: number;
  projection: 'maximum' | 'average';
  sectionIntervalMM: number;
  sectionWidthMM: number;
  sectionHeightMM: number;
  sectionThicknessMM: number;
  sectionMmPerPixel: number;
  /** Quota della fetta su cui cercare l'arcata. `null` la fa scegliere al rilevamento. */
  archVerticalMM: number | null;
};

export const defaultOptions: DentalOptions = {
  mmPerPixel: 0.2,
  heightMM: 80,
  slabThicknessMM: 20,
  projection: 'maximum',
  sectionIntervalMM: 2,
  sectionWidthMM: 32,
  sectionHeightMM: 45,
  sectionThicknessMM: 1,
  sectionMmPerPixel: 0.15,
  archVerticalMM: null,
};

/** I limiti di ciascuna opzione: minimo, massimo. Il confine è qui, non nella pagina. */
const limits: Partial<Record<keyof DentalOptions, [number, number]>> = {
  mmPerPixel: [0.05, 1],
  heightMM: [20, 200],
  slabThicknessMM: [0, 40],
  sectionIntervalMM: [0.5, 10],
  sectionWidthMM: [10, 80],
  sectionHeightMM: [10, 90],
  sectionThicknessMM: [0, 10],
  sectionMmPerPixel: [0.05, 1],
};

export function normaliseOptions(input: unknown): DentalOptions {
  const given = (input ?? {}) as Record<string, unknown>;
  const result = { ...defaultOptions };
  for (const [key, range] of Object.entries(limits)) {
    const value = given[key];
    if (!range || typeof value !== 'number' || !Number.isFinite(value))
      continue;
    (result as Record<string, unknown>)[key] = Math.min(
      Math.max(value, range[0]),
      range[1],
    );
  }
  if (given.projection === 'average' || given.projection === 'maximum')
    result.projection = given.projection;
  if (
    typeof given.archVerticalMM === 'number' &&
    Number.isFinite(given.archVerticalMM)
  )
    result.archVerticalMM = given.archVerticalMM;
  return result;
}

/**
 * Il file NIfTI preparato per una serie.
 *
 * È lo stesso volume che il visore mostra, cioè quello ricampionato all'importazione a un massimo
 * di 320 voxel per asse. Su una CBCT a campo grande questo significa mezzo millimetro di voxel
 * invece di un quarto: la panoramica ne risente poco, le sezioni trasversali sì. Rifare la
 * conversione a piena risoluzione per il dentale è il passo successivo, e va fatto sapendo che
 * costa memoria.
 */
export function seriesVolumePath(seriesId: string) {
  const asset = db()
    .prepare('SELECT path FROM assets WHERE id=?')
    .get(identifier(seriesId));
  if (!asset) throw new Error('This series is not in the library yet.');
  const stored = String(asset.path);
  return path.isAbsolute(stored) ? stored : path.join(dataRoot(), stored);
}

export function outputDirectory(seriesId: string, key: string) {
  return path.join(dataRoot(), 'dental', identifier(seriesId), identifier(key));
}

type PythonResult = Record<string, unknown> & {
  sections: { count: number; directory: string };
  axial: Record<string, unknown> | null;
};

export type DentalBuild = PythonResult & {
  key: string;
  cached: boolean;
  images: { panorama: string; axial: string | null; sections: string[] };
};

/**
 * Ricostruisce panoramica e sezioni per una serie, o restituisce quelle già fatte.
 *
 * La chiave della cache comprende **tutte** le opzioni: cambiarne una qualsiasi produce una
 * cartella nuova invece di sovrascrivere quella di prima, così tornare indietro su un parametro
 * non costa un secondo giro di calcolo.
 */
export async function buildDental(
  seriesId: string,
  input: unknown,
): Promise<DentalBuild> {
  const options = normaliseOptions(input);
  const volume = seriesVolumePath(seriesId);
  const key = createHash('sha256')
    .update(JSON.stringify(options))
    .digest('hex')
    .slice(0, 16);
  const directory = outputDirectory(seriesId, key);
  const resultPath = path.join(directory, 'result.json');
  const images = (result: PythonResult) => ({
    panorama: `/api/dental/image/${seriesId}/${key}/panorama.png`,
    axial: result.axial
      ? `/api/dental/image/${seriesId}/${key}/axial.png`
      : null,
    sections: Array.from(
      { length: result.sections.count },
      (_, index) =>
        `/api/dental/image/${seriesId}/${key}/sections/${String(index).padStart(4, '0')}.png`,
    ),
  });

  if (existsSync(resultPath)) {
    const cached = JSON.parse(readFileSync(resultPath, 'utf8')) as PythonResult;
    return { ...cached, key, cached: true, images: images(cached) };
  }

  const python = pythonPath();
  if (!existsSync(python)) throw new Error(SETUP_HINT);
  mkdirSync(directory, { recursive: true, mode: 0o700 });

  const stdout = await new Promise<string>((resolve, reject) => {
    execFile(
      python,
      [
        path.join(process.cwd(), 'scripts/dental_panorama.py'),
        volume,
        directory,
        JSON.stringify(options),
      ],
      { timeout: TIMEOUT_MS, maxBuffer: 64 * 1024 * 1024 },
      (error, out, errorOutput) => {
        if (!error) return resolve(out);
        // L'ultima riga di un traceback Python è il messaggio, ed è l'unica parte che dice
        // qualcosa a chi guarda lo schermo. Il resto finisce nel registro del server.
        const lines = String(errorOutput || '')
          .trim()
          .split('\n');
        const last = lines[lines.length - 1] || '';
        const message = last.replace(/^\w*(Error|Exception):\s*/, '');
        console.error('dental_panorama.py failed:', errorOutput);
        reject(new Error(message || 'The reconstruction failed.'));
      },
    );
  });

  const result = JSON.parse(stdout) as PythonResult;
  writeFileSync(resultPath, JSON.stringify(result), { mode: 0o600 });
  return { ...result, key, cached: false, images: images(result) };
}
