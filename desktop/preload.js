'use strict';

// Il solo ponte fra la pagina e il Mac: scegliere un esame con il pannello del sistema.
//
// Tutto il resto la pagina lo fa da sé, parlando con il server come farebbe in un browser. Il
// ponte resta stretto di proposito — percorsi in uscita, nient'altro — perché ogni funzione
// esposta qui è una funzione che una pagina qualunque, caricata per sbaglio nella finestra,
// potrebbe chiamare. Il tipo che la pagina vede sta in web/lib/desktop.ts.

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('openmriDesktop', {
  /** Cartelle o file scelti nel pannello del Mac; vuoto se si annulla. */
  chooseExam: () => ipcRenderer.invoke('openmri:choose-exam'),
  /** Lo stesso pannello, e poi la pagina dentale che importa ciò che si è scelto. */
  openExam: () => ipcRenderer.invoke('openmri:open-exam'),
  /** Ciò che `openExam` ha fatto scegliere, ritirato una volta sola dalla pagina dentale. */
  takeChosenExam: () => ipcRenderer.invoke('openmri:take-chosen-exam'),
});
