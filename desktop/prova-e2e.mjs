// Prova l'app desktop come la userebbe una persona, dal doppio clic al visore 3D.
//
// # Perché esiste
//
// Il primo pacchetto per il Mac non è mai partito sul Mac di chi lo usa, e nessuna prova se ne
// poteva accorgere. Il secondo è partito, e il primo clic non apriva niente: il pulsante viola
// della schermata iniziale apriva il pannello ZIP di OpenMRI, con i `.dcm` in grigio. Nessuna
// prova cliccava quel pulsante. Questa clicca quelli veri, nell'ordine in cui li clicca chi usa
// il programma, e a ogni passo scatta una foto.
//
// Il pannello del sistema è l'unica cosa finta: un pannello nativo non si clicca da qui, e la
// prova lo sostituisce, nel processo principale, con uno che risponde da solo — una volta la
// cartella dell'esame, una volta i file che ci stanno dentro, come farebbe una persona.
//
// # Come si lancia
//
// Su Linux, dove l'app per Linux esce dallo stesso script, con uno schermo virtuale:
//
//     npm i playwright-core@1
//     xvfb-run -a node desktop/prova-e2e.mjs "OpenMRI Dental-linux" <cartella-dicom> <cartella-foto>
//
// Senza scheda grafica il visore 3D dice che WebGL 2 non c'è: si aggiunge il rendering software,
// lento ma vero, con EXTRA_ARGS="--enable-unsafe-swiftshader --use-angle=swiftshader" e un'attesa
// più lunga prima della foto del visore, VIEW_WAIT=45000.
//
// Su un Mac il primo argomento è l'eseguibile: "OpenMRI Dental.app/Contents/MacOS/Electron".

import { _electron as electron } from 'playwright-core';
import { mkdtempSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const [appPath, folder, out] = process.argv.slice(2);
if (!appPath || !folder || !out) {
  console.error('Uso: node desktop/prova-e2e.mjs <app> <cartella-dicom> <cartella-foto>');
  process.exit(2);
}
const executable = statSync(appPath).isDirectory() ? path.join(appPath, 'electron') : appPath;
// Una casa nuova a ogni giro: la libreria parte vuota, e la prova non dipende da quella di prima.
const home = mkdtempSync(path.join(tmpdir(), 'openmri-home-'));
const extra = process.env.EXTRA_ARGS ? process.env.EXTRA_ARGS.split(' ') : [];

/** I file dentro la cartella dell'esame: ciò che sceglie chi apre la cartella e seleziona tutto. */
function filesIn(directory) {
  const found = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const full = path.join(directory, entry.name);
    if (entry.isDirectory()) found.push(...filesIn(full));
    else if (entry.isFile() && !entry.name.startsWith('.')) found.push(full);
  }
  return found;
}

const shot = async (page, name) => {
  await page.screenshot({ path: path.join(out, name), timeout: 240_000 });
  console.log(`  foto: ${name}`);
};
const step = (text) => console.log(`▸ ${text}`);

/** Il pannello del sistema risponderà `paths` la prossima volta che si apre. */
async function panelWillAnswer(app, paths) {
  await app.evaluate(({ dialog }, answer) => {
    dialog.showOpenDialog = async () => ({ canceled: false, filePaths: answer });
  }, paths);
}

/** Aspetta la fine dell'importazione: la riga «Imported», o l'errore scritto. */
async function importOutcome(page) {
  return Promise.race([
    page
      .getByText('Imported. The exam is in the library.')
      .waitFor({ timeout: 600_000 })
      .then(() => 'ok'),
    page
      .locator('.text-destructive')
      .first()
      .waitFor({ timeout: 600_000 })
      .then(async () => `errore: ${await page.locator('.text-destructive').first().innerText()}`),
  ]);
}

const started = Date.now();
const app = await electron.launch({
  executablePath: executable,
  args: process.platform === 'linux' ? ['--no-sandbox', ...extra] : extra,
  env: { ...process.env, HOME: home },
  timeout: 60_000,
});
try {
  const page = await app.firstWindow();
  page.on('console', (message) => {
    if (message.type() === 'error') console.log(`  console: ${message.text().slice(0, 200)}`);
  });

  step('attendo il motore');
  const deadline = Date.now() + 120_000;
  while (!/^http:\/\/127\.0\.0\.1:\d+\/$/.test(page.url())) {
    if (Date.now() > deadline) throw new Error(`il motore non è arrivato: ${page.url()}`);
    await page.waitForTimeout(250);
  }
  const origin = new URL(page.url()).origin;
  await page.waitForLoadState('networkidle');
  console.log(`  pronto in ${((Date.now() - started) / 1000).toFixed(1)} s su ${origin}`);
  await shot(page, '01-home.png');

  step('i collegamenti fra le pagine: Dental dalla schermata iniziale, Library dalla dentale');
  // Con vinext 1.0.0-beta.5 `next/link` non navigava: il clic moriva in silenzio, ed era il primo
  // clic di chi apriva l'app. Qui si clicca davvero, e si guarda dove si arriva.
  await page.getByRole('link', { name: /Dental/ }).first().click();
  await page.waitForURL(`${origin}/dental`, { timeout: 30_000 });
  await page.getByRole('link', { name: 'Library' }).click();
  await page.waitForURL(`${origin}/`, { timeout: 30_000 });
  await page.waitForLoadState('networkidle');
  console.log('  Dental e Library portano dove dicono');

  // Il pulsante viola riceve i file — chi apre la cartella e preme ⌘A ne sceglie centinaia, e
  // non devono passare dall'indirizzo della pagina — e «Open CBCT…» la cartella.
  const files = filesIn(folder).filter((file) => path.basename(file) !== 'DICOMDIR');
  step(`il pulsante viola della schermata iniziale, con ${files.length} file scelti`);
  await panelWillAnswer(app, files);
  let importStarted = Date.now();
  await page.getByRole('button', { name: /Import (your first|a new) MRI/ }).click();
  let outcome = await importOutcome(page);
  console.log(`  importazione: ${outcome} in ${((Date.now() - importStarted) / 1000).toFixed(1)} s`);
  await shot(page, '02-importata.png');
  if (outcome !== 'ok') throw new Error(outcome);

  step('dritto al visore 3D');
  await page.getByRole('link', { name: 'Open in the 3D viewer' }).click();
  await page.waitForURL(/\/\?study=/, { timeout: 30_000 });
  await page.getByText('CURRENT SERIES', { exact: false }).first().waitFor({ timeout: 60_000 });
  await page.waitForTimeout(Number(process.env.VIEW_WAIT || 8000));
  await shot(page, '03-visore.png');

  step('«Open CBCT…» nella pagina dentale, con la cartella dell\'esame');
  await page.goto(`${origin}/dental`);
  await page.getByRole('button', { name: 'Import folder' }).click();
  await panelWillAnswer(app, [folder]);
  importStarted = Date.now();
  await page.getByRole('button', { name: 'Open CBCT…' }).click();
  outcome = await importOutcome(page);
  console.log(`  importazione: ${outcome} in ${((Date.now() - importStarted) / 1000).toFixed(1)} s`);
  await shot(page, '04-cartella-importata.png');
  if (outcome !== 'ok') throw new Error(outcome);

  step('ritento lo stesso esame: deve riaprirlo, non fermarsi con un errore');
  // Chi non vede succedere niente ritenta, e la seconda importazione dello stesso archivio con un
  // paziente nuovo si fermava su «already imported for another patient».
  await page.goto(`${origin}/dental`);
  await page.getByRole('button', { name: 'Import folder' }).click();
  await panelWillAnswer(app, [folder]);
  await page.getByRole('button', { name: 'Open CBCT…' }).click();
  outcome = await importOutcome(page);
  console.log(`  seconda importazione: ${outcome}`);
  if (outcome !== 'ok') throw new Error(outcome);

  step('un file solo, come chi apre la cartella e clicca una fetta');
  // Una fetta non è un volume: il convertitore si fermava con «could not build a volume». Ora si
  // prendono le fette sorelle, e l'esame si importa intero.
  const slices = filesIn(folder).filter((file) => /IM\d+$|\.dcm$/i.test(file));
  await page.goto(`${origin}/dental`);
  await page.getByRole('button', { name: 'Import folder' }).click();
  await panelWillAnswer(app, [slices[Math.floor(slices.length / 2)]]);
  await page.getByRole('button', { name: 'Open CBCT…' }).click();
  outcome = await importOutcome(page);
  console.log(`  una fetta scelta: ${outcome}`);
  if (outcome !== 'ok') throw new Error(outcome);

  step('panoramica');
  await page.getByRole('button', { name: /Reconstruct|Rebuild/ }).click();
  await page.getByText('Arch curve').waitFor({ timeout: 300_000 });
  await page.waitForTimeout(3000);
  await shot(page, '05-panoramica.png');
  console.log('FATTO');
} catch (error) {
  // La foto dell'errore vale più del messaggio: dice che cosa c'era sullo schermo.
  const page = await app.firstWindow();
  console.log(`  pagina al momento dell'errore: ${page.url()}`);
  await shot(page, 'errore.png').catch(() => {});
  throw error;
} finally {
  await app.close();
}
