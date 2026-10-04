// Prova l'app desktop come la userebbe una persona, dal doppio clic al visore 3D.
//
// # Perché esiste
//
// Il primo pacchetto per il Mac non è mai partito sul Mac di chi lo usa, e nessuna prova se ne
// poteva accorgere: ce n'erano per il server e per Python, nessuna per l'app intera. Questa avvia
// l'app costruita da Tools/make-mac-app.sh, aspetta il motore, sceglie una cartella come farebbe
// ⌘O, importa, ricostruisce la panoramica, apre il visore — e a ogni passo scatta una foto.
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
// più lunga prima dell'ultima foto, VIEW_WAIT=45000.
//
// Su un Mac il primo argomento è l'eseguibile: "OpenMRI Dental.app/Contents/MacOS/Electron".

import { _electron as electron } from 'playwright-core';
import { mkdtempSync, statSync } from 'node:fs';
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

const shot = async (page, name) => {
  await page.screenshot({ path: path.join(out, name), timeout: 240_000 });
  console.log(`  foto: ${name}`);
};
const step = (text) => console.log(`▸ ${text}`);

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

  step('come ⌘O: la pagina dentale con la cartella già scelta');
  await page.goto(`${origin}/dental?folder=${encodeURIComponent(folder)}`);
  await page.getByText(`Folder: ${folder}`).waitFor({ timeout: 30_000 });
  // Il ponte verso il pannello del Mac: senza, «Choose folder…» ripiegherebbe sul caricamento
  // dei file dal browser, e nessun altro controllo se ne accorgerebbe.
  const bridge = await page.evaluate(() => typeof window.openmriDesktop?.chooseFolder);
  if (bridge !== 'function') throw new Error(`il ponte verso il Mac manca: ${bridge}`);
  console.log('  ponte verso il Mac presente');
  await shot(page, '02-cartella.png');

  step('importo');
  await page.getByPlaceholder('Rossi Mario').fill('Prova Sintetica');
  const importStarted = Date.now();
  await page.getByRole('button', { name: 'Import', exact: true }).click();
  // Il pannello si chiude quando l'importazione è finita; un errore resta scritto.
  const outcome = await Promise.race([
    page
      .getByText('Open a CBCT')
      .waitFor({ state: 'detached', timeout: 600_000 })
      .then(() => 'ok'),
    page
      .locator('.text-destructive')
      .first()
      .waitFor({ timeout: 600_000 })
      .then(async () => `errore: ${await page.locator('.text-destructive').first().innerText()}`),
  ]);
  const seconds = ((Date.now() - importStarted) / 1000).toFixed(1);
  console.log(`  importazione: ${outcome} in ${seconds} s`);
  await shot(page, '03-importata.png');
  if (outcome !== 'ok') throw new Error(outcome);

  step('panoramica');
  await page.getByRole('button', { name: /Reconstruct|Rebuild/ }).click();
  await page.getByText('Arch curve').waitFor({ timeout: 300_000 });
  await page.waitForTimeout(3000);
  await shot(page, '04-panoramica.png');

  step('il visore di OpenMRI');
  await page.goto(`${origin}/`);
  await page.waitForLoadState('networkidle');
  await page.getByText('Prova Sintetica').first().click();
  await page.waitForTimeout(Number(process.env.VIEW_WAIT || 8000));
  await shot(page, '05-visore.png');
  console.log('FATTO');
} finally {
  await app.close();
}
