# Piano di lavoro

Traduce [`docs/cs3d-teardown.md`](cs3d-teardown.md) in lotti eseguibili, ordinati e assegnati.
È il documento che dice **chi fa cosa e in che ordine**, e va aggiornato man mano.

---

## 1. Il principio che decide le assegnazioni

Codex produce molto codice in fretta e con qualità alta quando la specifica è precisa. Ha però un
limite che non dipende da lui: **nel suo ambiente non c'è `swift`**, quindi non può compilare né
eseguire nulla. Lo ha dichiarato onestamente a ogni consegna, e in due casi su cinque il codice
consegnato non compilava — errori piccoli, trovati qui in quindici secondi.

Io ho l'opposto: la toolchain Swift installata in questo ambiente, quindi compilo ed eseguo la
suite, ma **il target dell'applicazione non compila qui** perché importa SwiftUI, AppKit e Metal.
Quella parte la verifica solo un Mac, e ogni errore là costa un giro completo.

Da questi due limiti discende la regola che governa tutto il piano:

> **Ogni funzione si spezza in un nucleo verificabile e una vista sottile.**
> Il nucleo è Swift puro, senza SwiftUI né Metal, e finisce in un modulo con i suoi test: lo scrive
> Codex e lo verifico qui prima che tocchi il tuo Mac. La vista è quanto più sottile possibile —
> legge il nucleo e disegna — perché è la sola parte che nessuno può verificare prima della
> compilazione su macOS.

Non è una divisione burocratica: sposta il codice non verificabile da centinaia di righe a decine.
Un esempio concreto dal lotto B — la striscia di sezioni trasversali. La versione ingenua è una
vista SwiftUI di duecento righe che calcola posizioni, pagine e selezione mentre disegna: tutto non
verificabile. La versione giusta è un `CrossSectionBrowser` di centocinquanta righe, testato qui su
posizioni, paginazione e conversioni, più una vista di cinquanta righe che gli chiede cosa
disegnare.

Corollario pratico: **il codice Metal resta mio** in ogni caso, perché Codex non può nemmeno
scriverlo alla cieca con profitto — gli shader falliscono a runtime, non in compilazione.

---

## 2. Stato attuale

| Modulo | Contenuto | Autore | Stato |
|---|---|---|---|
| DICOMCore | parser, geometria, decoder RLE e JPEG Lossless | Codex + me | verificato |
| MeasureKit | annotazioni, ROI, `.cbctplan` | me | verificato |
| VolumeKit | MPR, raycasting, transfer function | me | verificato |
| DentalKit | arcata, panorex, sezioni | me | verificato |
| ImplantKit | nervo, impianti, allarmi | me | verificato |
| MeshKit | STL/PLY/OBJ, Horn, ICP | Codex | verificato |
| GuideKit | campi scalari, marching cubes, dime | Codex | verificato |
| SegmentKit | ritaglio, soglie, morfologia, componenti | Codex | verificato |
| ArtifactKit | strie da metallo, provenienza | Codex | **in corso** |

286 test in 38 suite. L'applicazione compila su macOS.

---

## 3. I lotti

Ordinati per quanto si toccano in una giornata di lavoro, non per difficoltà. La colonna «dip.»
indica da cosa dipendono.

| # | Lotto | Autore | Dip. | Brief |
|---|---|---|---|---|
| **0** | ArtifactKit — strie da metallo | Codex | SegmentKit | [scritto](codex-brief-artifactkit.md) |
| **A** | Riformattazione: ricampionamento del volume | Codex | SegmentKit | da scrivere |
| **B** | Navigazione delle sezioni trasversali | Codex | DentalKit | da scrivere |
| **C** | Spessore e proiezione per riquadro | me | — | — |
| **D** | Geometria delle sovraimpressioni 3D | Codex | VolumeKit | da scrivere |
| **E** | Modello degli oggetti del piano | Codex | tutti | da scrivere |
| **F** | Collocazione delle etichette con richiamo | Codex | E | da scrivere |
| **G** | Disegno dei piani nel raycaster | me | D | — |
| **H** | Viste: barre dei riquadri, elenco oggetti, riformattazione | Codex | A, B, E | da scrivere |
| **I** | Maniglie del mirino sui bordi | me | — | — |
| **J** | Schede «personalizzato» e «obliquo» | me | — | — |

### Lotto A — Ricampionamento del volume

Divario **7**. `SegmentKit.VolumeCrop` ritaglia; manca il ricampionamento a un passo di voxel
diverso, che è ciò che rende praticabile lavorare a piena risoluzione su una regione senza tenere
in memoria l'intero FOV.

Nucleo, tutto verificabile: `VolumeResampler.resampled(_:toIsotropicMM:)` con interpolazione
trilineare, la geometria nuova ricavata da `patientPoint` e non dall'aritmetica sulle spaziature,
un limite di memoria che rifiuta invece di allocare, e la conservazione di slope, intercetta e
unità.

**Prova che conta**: il cubo del fantoccio misura 20,00 mm anche dopo il ricampionamento a 0,15,
0,3 e 0,5 mm, e la densità nel cubo resta 1200 GV. Se il ricampionamento sposta la geometria, ogni
misura successiva è falsa e nessuna ispezione visiva lo rivela.

### Lotto B — Navigazione delle sezioni trasversali

Divario **3**, quello che hai chiamato «per i fatti loro». Nucleo: `CrossSectionBrowser`, una
struttura Sendable che tiene passo, larghezza, altezza, indice selezionato e pagina, e risponde a
domande — quali sezioni mostrare, a che lunghezza d'arco cade ciascuna, quale sezione corrisponde a
un punto cliccato sul panorex, dove disegnare i segni sull'assiale.

Tutte queste sono funzioni pure di dati semplici, quindi **tutte verificabili qui**. La vista
diventa una griglia che chiede al browser cosa mettere in ogni cella.

**Prova che conta**: la posizione in millimetri di ogni sezione coincide con la lunghezza d'arco
del suo piano, andata e ritorno, e la sezione più vicina a un punto cliccato è davvero la più
vicina — verificato per forza bruta su tutte.

### Lotto C — Spessore e proiezione per riquadro *(mio)*

Divario **2**, il controllo più toccato. Non lo delego perché tocca `MPRPlane`, `AppModel` e le
quattro viste insieme, cioè è più orchestrazione che volume di codice. La scala dei valori è già
in `PanoramicLayout.slabThicknessPresetsMM`.

### Lotto D — Geometria delle sovraimpressioni 3D

Divario **4**, il migliore per rapporto fra resa e costo. Nucleo: dato un `VolumeCamera` e un
piano, produrre i **segmenti in coordinate schermo** della sua cornice — rettangolo per una
`MPRPlane`, striscia estrusa per la banda dell'arcata, parallelepipedo per il riquadro di ritaglio,
con il taglio contro il volume e l'indicazione di quali spigoli sono nascosti.

È geometria proiettiva pura: nessun Metal, tutto verificabile. Il disegno vero e proprio, nel
raycaster, resta a me (lotto G).

### Lotto E — Modello degli oggetti del piano

Divario **5**. Oggi impianti, nervi, curve e annotazioni vivono in quattro elenchi separati con
regole diverse. Serve un modello unico: identità, nome, visibilità, colore, blocco, ordine, e la
serializzazione in `.cbctplan` con migrazione dal formato attuale.

**Trappola da nominare nel brief**: la migrazione. Un `.cbctplan` salvato oggi deve continuare ad
aprirsi, e il formato nuovo deve essere leggibile dal vecchio o rifiutato con un messaggio chiaro —
mai aperto a metà.

### Lotto F — Collocazione delle etichette

Divario **6**. Non è grafica: è un problema di collocazione. Date *n* etichette ancorate a *n*
punti in un riquadro, trovare posizioni che non si sovrappongano fra loro, non escano dal riquadro,
e stiano il più vicino possibile all'ancora, con una linea di richiamo che non attraversi altre
etichette. Algoritmo puro, verificabile per intero.

### Lotto H — Viste

Le viste SwiftUI dei lotti precedenti: barre dei riquadri con spessore e proiezione, pannello
elenco oggetti, finestra di riformattazione con i riquadri di ritaglio collegati. Va a Codex **dopo**
che i nuclei esistono, così ogni vista è sottile e il rischio si concentra dove è inevitabile.

---

## 4. Come procede la coda

Codex lavora a un lotto per volta, in quest'ordine: **0 → A → B → D → E → F → H**. Ogni consegna
passa da qui prima di arrivare sul Mac: compilo, eseguo la suite, reviso i punti che il brief
segnala come critici, e solo allora committo.

Io procedo in parallelo su **C**, **G**, **I**, **J**, che sono interazione e Metal.

Il criterio per aggiungere un lotto alla coda: deve avere un nucleo verificabile qui. Se una
funzione è tutta vista, va nel lotto H o resta a me — non perché Codex non sappia scriverla, ma
perché nessuno saprebbe dire se funziona finché non la compili tu.
