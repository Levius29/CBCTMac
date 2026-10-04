'use strict';

// OpenMRI Dental come applicazione del Mac.
//
// # Che cosa fa, in una riga
//
// Avvia il motore di OpenMRI — il suo server, con il suo Python — dentro l'applicazione, e lo
// mostra in una finestra sua. Niente browser, niente terminale, niente da installare: Node,
// Python e le librerie viaggiano dentro il pacchetto, costruito da Tools/make-mac-app.sh.
//
// # Perché un guscio e non un'altra applicazione
//
// Perché OpenMRI è il motore: la visualizzazione, l'importazione, la libreria sono le sue, e
// riscriverle significherebbe perderle. Il guscio aggiunge solo ciò che una pagina web non può
// avere — un'icona nel Dock, una finestra senza barra degli indirizzi, il pannello del Mac per
// scegliere una cartella — e non tocca niente di loro.
//
// # Il difetto che il primo pacchetto aveva
//
// Il primo `OpenMRI Dental.app` cercava Node e Python sul sistema, con il PATH che il Finder dà
// alle applicazioni, cioè quasi vuoto; e se li trovava, apriva Chrome. Sul Mac di prova non è
// partito, e nessuno ha mai saputo perché. Qui tutto ciò che serve è dentro il pacchetto, con
// percorsi assoluti, e ogni passo dell'avvio finisce in un registro che il menu sa aprire.

const { app, BrowserWindow, Menu, dialog, ipcMain, shell } = require('electron');
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const path = require('node:path');

const NAME = 'OpenMRI Dental';
/** Quanto si aspetta il primo segno di vita del motore, prima di dichiararlo fermo. */
const START_TIMEOUT_MS = 120 * 1000;

app.setName(NAME);

// Dove stanno i pezzi. Nel pacchetto, accanto all'applicazione; durante le prove, dove dicono le
// variabili d'ambiente, così lo stesso codice gira anche fuori dal pacchetto.
const resources = process.resourcesPath;
const paths = {
  web: process.env.OPENMRI_DESKTOP_WEB || path.join(resources, 'openmri'),
  node: process.env.OPENMRI_DESKTOP_NODE || path.join(resources, 'node', 'bin', 'node'),
  python:
    process.env.OPENMRI_DESKTOP_PYTHON || path.join(resources, 'python', 'bin', 'python3'),
};
// La libreria e il registro stanno dove il Mac li vuole: fuori dal pacchetto, che si può
// sostituire a ogni aggiornamento senza perdere un esame.
const libraryDir = path.join(app.getPath('userData'), 'library');
const logDir = app.getPath('logs');
const logFile = path.join(logDir, 'engine.log');

let engine = null;
let origin = '';
let mainWindow = null;
let quitting = false;

function log(line) {
  try {
    fs.mkdirSync(logDir, { recursive: true });
    fs.appendFileSync(logFile, `[${new Date().toISOString()}] ${line}\n`);
  } catch {
    // Un registro che non si scrive non deve fermare il programma.
  }
}

/** Una porta libera: la 4173 di OpenMRI può essere occupata da un server lanciato a mano. */
function freePort() {
  return new Promise((resolve, reject) => {
    const probe = net.createServer();
    probe.unref();
    probe.on('error', reject);
    probe.listen(0, '127.0.0.1', () => {
      const { port } = probe.address();
      probe.close(() => resolve(port));
    });
  });
}

function startEngine(port) {
  for (const [what, where] of Object.entries(paths)) {
    if (!fs.existsSync(where)) throw new Error(`The ${what} part of the app is missing: ${where}`);
  }
  const vinext = JSON.parse(
    fs.readFileSync(path.join(paths.web, 'node_modules', 'vinext', 'package.json'), 'utf8'),
  );
  const bin = typeof vinext.bin === 'string' ? vinext.bin : Object.values(vinext.bin)[0];
  const cli = path.join(paths.web, 'node_modules', 'vinext', bin);

  fs.mkdirSync(libraryDir, { recursive: true });
  fs.mkdirSync(logDir, { recursive: true });
  const output = fs.openSync(logFile, 'a');
  log(`Starting the engine on 127.0.0.1:${port} — library in ${libraryDir}`);

  const child = spawn(paths.node, [cli, 'start', '-H', '127.0.0.1', '-p', String(port)], {
    cwd: paths.web,
    env: {
      ...process.env,
      NODE_ENV: 'production',
      // I moduli Python sono già compilati nel pacchetto: scriverne altri lo modificherebbe dopo
      // la firma.
      PYTHONDONTWRITEBYTECODE: '1',
      OPENMRI_PYTHON: paths.python,
      OPENMRI_DATA_DIR: libraryDir,
      // Il PATH del Finder è quasi vuoto, e non deve contare: ciò che serve è qui dentro.
      PATH: [
        path.dirname(paths.python),
        path.dirname(paths.node),
        '/usr/bin',
        '/bin',
        '/usr/sbin',
        '/sbin',
      ].join(':'),
    },
    stdio: ['ignore', output, output],
  });
  child.on('exit', (code, signal) => {
    log(`The engine stopped (code ${code}, signal ${signal})`);
    engine = null;
    if (!quitting) showError(`The local engine stopped unexpectedly (code ${code}).`);
  });
  return child;
}

/** Aspetta che il motore risponda su /api/health, o che muoia provandoci. */
function waitForEngine(port) {
  const deadline = Date.now() + START_TIMEOUT_MS;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      if (!engine) return reject(new Error('The local engine stopped while starting.'));
      const request = http.get(
        { host: '127.0.0.1', port, path: '/api/health', timeout: 2000 },
        (response) => {
          response.resume();
          if (response.statusCode === 200) return resolve();
          retry();
        },
      );
      request.on('error', retry);
      request.on('timeout', () => request.destroy());
    };
    const retry = () => {
      if (Date.now() > deadline)
        return reject(new Error('The local engine did not answer within two minutes.'));
      setTimeout(attempt, 300);
    };
    attempt();
  });
}

function showError(message) {
  log(`Error shown: ${message}`);
  if (!mainWindow || mainWindow.isDestroyed()) return;
  mainWindow.loadFile(path.join(__dirname, 'loading.html'), {
    query: { error: message, log: logFile },
  });
}

/** Vero per le pagine del motore e per la pagina d'attesa: tutto il resto va nel browser. */
function isOurs(url) {
  return (origin && url.startsWith(`${origin}/`)) || url === origin || url.startsWith('file:');
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 920,
    minWidth: 1024,
    minHeight: 680,
    title: NAME,
    backgroundColor: '#0a0a0b',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      sandbox: true,
    },
  });
  mainWindow.loadFile(path.join(__dirname, 'loading.html'));

  // Un collegamento esterno — il repository dell'originale, la licenza — si apre nel browser:
  // dentro la finestra non ci sarebbe modo di tornare indietro.
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    if (isOurs(url)) return { action: 'allow' };
    shell.openExternal(url);
    return { action: 'deny' };
  });
  mainWindow.webContents.on('will-navigate', (event, url) => {
    if (isOurs(url)) return;
    event.preventDefault();
    shell.openExternal(url);
  });
  mainWindow.on('closed', () => {
    mainWindow = null;
  });
}

/**
 * Il pannello del Mac per scegliere un esame: **cartelle o file**, anche più d'uno.
 *
 * La prima versione sceglieva solo cartelle, e dentro la cartella dell'esame i `.dcm` comparivano
 * in grigio: chi li vedeva concludeva che non si apriva nessun file. Il pannello di OpenMRI, dal
 * canto suo, voleva solo ZIP. Qui va bene tutto ciò che si ha in mano. Su Linux un pannello non
 * può essere insieme di file e di cartelle, e Electron lo fa di sole cartelle.
 */
async function chooseExam(window) {
  const result = await dialog.showOpenDialog(window, {
    title: 'Open a CBCT',
    message: 'Choose the folder of the exam, or the DICOM files in it. A CD or USB stick works too.',
    buttonLabel: 'Open',
    properties: ['openFile', 'openDirectory', 'multiSelections'],
  });
  return result.canceled ? [] : result.filePaths;
}

/**
 * Ciò che si è scelto con ⌘O o con un pulsante d'importazione, in attesa che la pagina dentale lo
 * ritiri. Non viaggia nell'indirizzo: chi apre la cartella e seleziona tutti i `.dcm` sceglie
 * seicento percorsi, cinquanta kilobyte, e Node rifiuta un indirizzo oltre i sedici.
 */
let chosenExam = [];

/** ⌘O e i pulsanti d'importazione: si sceglie, e la pagina dentale importa. */
async function openExam(window) {
  if (!window || window.isDestroyed() || !origin) return;
  const paths = await chooseExam(window);
  if (!paths.length) return;
  chosenExam = paths;
  window.loadURL(`${origin}/dental?import=chosen`);
}

function buildMenu() {
  const mac = process.platform === 'darwin';
  const template = [
    ...(mac ? [{ role: 'appMenu' }] : []),
    {
      label: 'File',
      submenu: [
        { label: 'Open CBCT…', accelerator: 'CmdOrCtrl+O', click: () => openExam(mainWindow) },
        { label: 'Home', accelerator: 'CmdOrCtrl+Shift+H', click: () => origin && mainWindow?.loadURL(`${origin}/`) },
        { type: 'separator' },
        { label: 'Show Engine Log', click: () => shell.openPath(logFile) },
        { label: 'Show Library Folder', click: () => shell.openPath(libraryDir) },
        { type: 'separator' },
        mac ? { role: 'close' } : { role: 'quit' },
      ],
    },
    { role: 'editMenu' },
    {
      label: 'View',
      submenu: [
        { role: 'reload' },
        { role: 'toggleDevTools' },
        { type: 'separator' },
        { role: 'resetZoom' },
        { role: 'zoomIn' },
        { role: 'zoomOut' },
        { type: 'separator' },
        { role: 'togglefullscreen' },
      ],
    },
    { role: 'windowMenu' },
  ];
  Menu.setApplicationMenu(Menu.buildFromTemplate(template));
}

function stopEngine() {
  quitting = true;
  if (!engine) return;
  const child = engine;
  child.kill('SIGTERM');
  // Un'importazione in corso può tardare a chiudere: dopo tre secondi si chiude per lei.
  setTimeout(() => {
    if (child.exitCode === null) child.kill('SIGKILL');
  }, 3000).unref();
}

// Solo le pagine del motore possono chiedere il pannello, non una pagina finita qui per caso.
const fromEngine = (event) => isOurs(event.senderFrame?.url || '');

ipcMain.handle('openmri:choose-exam', (event) => {
  if (!fromEngine(event)) return [];
  return chooseExam(BrowserWindow.fromWebContents(event.sender));
});

ipcMain.handle('openmri:open-exam', (event) => {
  if (!fromEngine(event)) return;
  return openExam(BrowserWindow.fromWebContents(event.sender));
});

// Si ritira una volta sola: ricaricare la pagina non deve importare due volte lo stesso esame.
ipcMain.handle('openmri:take-chosen-exam', (event) => {
  if (!fromEngine(event)) return [];
  const paths = chosenExam;
  chosenExam = [];
  return paths;
});

if (!app.requestSingleInstanceLock()) {
  // Un secondo doppio clic non deve avviare un secondo motore sulla stessa libreria.
  app.quit();
} else {
  app.on('second-instance', () => {
    if (!mainWindow) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
  });

  app.whenReady().then(async () => {
    buildMenu();
    createWindow();
    try {
      const port = await freePort();
      engine = startEngine(port);
      await waitForEngine(port);
      origin = `http://127.0.0.1:${port}`;
      log(`The engine answers at ${origin}`);
      if (mainWindow) mainWindow.loadURL(`${origin}/`);
    } catch (error) {
      showError(error instanceof Error ? error.message : String(error));
    }
  });

  // Chiudere la finestra chiude il programma, anche sul Mac: il motore non deve restare acceso
  // senza che nessuno lo veda.
  app.on('window-all-closed', () => app.quit());
  app.on('before-quit', stopEngine);
}
