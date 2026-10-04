'use strict';

// Il solo ponte fra la pagina e il Mac: scegliere una cartella con il pannello del sistema.
//
// Tutto il resto la pagina lo fa da sé, parlando con il server come farebbe in un browser. Il
// ponte resta stretto di proposito — un percorso in uscita, nient'altro — perché ogni funzione
// esposta qui è una funzione che una pagina qualunque, caricata per sbaglio nella finestra,
// potrebbe chiamare.

const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('openmriDesktop', {
  /** Il percorso della cartella scelta, o una stringa vuota se si annulla. */
  chooseFolder: () => ipcRenderer.invoke('openmri:choose-folder'),
});
