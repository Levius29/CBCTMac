import { useSyncExternalStore } from 'react';

/**
 * Il ponte verso l'app del Mac, quando la pagina gira lì dentro.
 *
 * Lo espone `desktop/preload.js`, e nel browser non c'è: ogni chiamata passa da qui, così una
 * pagina sa sempre se può chiedere il pannello del sistema o deve ripiegare su quello del browser.
 */

export type DesktopBridge = {
  /** Il pannello del Mac: cartelle o file, anche più d'uno. Vuoto se si annulla. */
  chooseExam: () => Promise<string[]>;
  /** Lo stesso pannello, e poi la pagina che importa ciò che si è scelto. */
  openExam: () => Promise<void>;
  /** Ciò che `openExam` ha fatto scegliere: la pagina dentale lo ritira, una volta sola. */
  takeChosenExam: () => Promise<string[]>;
};

declare global {
  interface Window {
    openmriDesktop?: DesktopBridge;
  }
}

export function desktopBridge(): DesktopBridge | undefined {
  return typeof window === 'undefined' ? undefined : window.openmriDesktop;
}

const neverChanges = () => () => {};

/**
 * Vero dentro l'app del Mac. Il server non lo sa, e il primo disegno nel client deve dire la
 * stessa cosa del server: React chiede `false` durante l'idratazione e ridisegna subito dopo.
 */
export function useDesktop() {
  return useSyncExternalStore(
    neverChanges,
    () => !!desktopBridge(),
    () => false,
  );
}
