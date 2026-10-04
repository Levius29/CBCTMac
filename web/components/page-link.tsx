import type { ReactNode } from 'react';

/**
 * Un collegamento fra pagine che carica la pagina per intero.
 *
 * # Perché non `next/link`
 *
 * Perché in questa versione di vinext (1.0.0-beta.5) la navigazione dal lato del browser è rotta
 * nella compilazione di produzione: al clic il collegamento carica pigramente il modulo del
 * router e ne chiama `navigateClientSide`, che arriva `undefined`. Il clic muore con «e is not a
 * function» nella console, e a schermo non succede niente. È ciò che vedeva chi usava l'app:
 * «Dental · open .dcm files» non apriva nulla.
 *
 * OpenMRI non usa mai `next/link` — è una pagina sola che cambia stato — quindi il difetto
 * toccava soltanto i collegamenti aggiunti da noi. Un `<a>` normale ricarica la pagina, che su un
 * server locale costa un istante, e non dipende dal router. Quando vinext lo correggerà si potrà
 * tornare a `next/link`; `desktop/prova-e2e.mjs` clicca questi collegamenti e se ne accorgerebbe.
 */
export default function PageLink({
  href,
  className,
  children,
}: {
  href: string;
  className?: string;
  children: ReactNode;
}) {
  return (
    <a href={href} className={className}>
      {children}
    </a>
  );
}
