# Piano di lavoro completo

Catalogo **esaustivo** di ciò che si ricava dalle cinque schermate di CS 3D Imaging v3.10.33, e la
sua traduzione in lotti eseguibili. Nulla è stato scartato per priorità: le priorità stanno nella
colonna «peso» e nell'ordine della coda, non nella scelta di cosa elencare.

Osservazioni grezze in [`docs/cs3d-teardown.md`](cs3d-teardown.md).

---

## 1. Il principio che decide le assegnazioni

Codex produce molto codice in fretta e con qualità alta quando la specifica è precisa. Ha però un
limite che non dipende da lui: **nel suo ambiente non c'è `swift`**, quindi non compila e non
esegue nulla. Lo ha dichiarato a ogni consegna, e in due casi su cinque il codice non compilava —
errori piccoli, trovati qui in quindici secondi.

Io ho l'opposto: la toolchain Swift è installata in questo ambiente, quindi compilo ed eseguo la
suite; ma **il target dell'applicazione non compila qui** perché importa SwiftUI, AppKit e Metal.
Quella parte la verifica solo un Mac, e ogni errore là costa un giro completo.

> **Regola che governa tutto il piano: ogni funzione si spezza in un nucleo verificabile e una
> vista sottile.** Il nucleo è Swift puro con i suoi test — lo scrive Codex, lo verifico qui prima
> che tocchi il Mac. La vista legge il nucleo e disegna, ed è la sola parte non verificabile in
> anticipo.

Sposta il codice a rischio da centinaia di righe a decine. La striscia di sezioni trasversali,
scritta nel modo ovvio, sono duecento righe di vista che calcola mentre disegna; scritta così
diventa un `CrossSectionBrowser` testato più cinquanta righe di griglia.

Corollario: **il codice Metal resta mio** in ogni caso — gli shader falliscono a runtime, non in
compilazione, quindi Codex non può nemmeno scriverli alla cieca con profitto.

---

## 2. Catalogo completo

Stato: ✅ fatto · 🔶 parziale · ❌ assente.
Peso: **3** si tocca ogni pochi minuti · **2** ogni sessione · **1** raramente ma serve.

### A — Impalcatura dell'applicazione

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| A1 | Nome del paziente al centro della barra del titolo | ❌ | 2 | H |
| A2 | Versione del programma visibile | 🔶 | 1 | H |
| A3 | Cinque **modi di lavoro** a schede, non layout: ortogonale, curvo, personalizzato, obliquo, relazione | ✅ | 3 | K |
| A4 | Pannelli laterali richiudibili con memoria dello stato | ❌ | 2 | H |
| A5 | Pannello contestuale che cambia col tipo di oggetto attivo | ❌ | 3 | E, H |
| A6 | Galleria delle istantanee salvate | ❌ | 1 | J |
| A7 | Menu applicazione con impostazioni | 🔶 | 1 | H |

### B — Palette degli strumenti

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| B1 | Selezione/freccia | ✅ | 3 | — |
| B2 | Righello con **varianti** (distanza, spezzata, perimetro) | 🔶 | 3 | L |
| B3 | Goniometro con varianti (angolo a 3 punti, fra due rette) | 🔶 | 2 | L |
| B4 | Strumento arcata | ✅ | 3 | — |
| B5 | Strumento canale mandibolare | ✅ | 2 | — |
| B6 | Strumento impianto | ✅ | 3 | — |
| B7 | Strumento tessuto gengivale | ❌ | 1 | M |
| B8 | Strumento barra protesica | ❌ | 1 | M |
| B9 | Strumento dente protesico | ❌ | 2 | M |
| B10 | Profilo del viso / cefalometria | ❌ | 1 | M |
| B11 | Piano di taglio arbitrario con varianti | 🔶 | 2 | J |
| B12 | Strumenti **contestuali**: la palette cambia con la scheda | ❌ | 2 | H |
| B13 | Varianti raggiungibili dal triangolino, non da un menu lontano | ❌ | 2 | H |

### C — Oggetti del piano

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| C1 | Elenco degli oggetti per tipo | 🔶 | 3 | E |
| C2 | Visibilità per oggetto (occhio) | ❌ | 3 | E |
| C3 | Colore per oggetto, scelto o assegnato | 🔶 | 2 | E |
| C4 | Cancellazione per oggetto, e di tutto il tipo | 🔶 | 2 | E |
| C5 | Nota testuale allegata a un oggetto | ❌ | 1 | E |
| C6 | «Porta al centro» un oggetto: tutte le viste ci si spostano | ❌ | 3 | E |
| C7 | Selezione evidenziata, coerente fra elenco e viste | 🔶 | 3 | E |
| C8 | Parametri modificabili in linea con passo (L, Ø) | ❌ | 3 | E |
| C9 | Duplica oggetto | ❌ | 2 | E |
| C10 | Specchia oggetto sul lato opposto | ❌ | 2 | E |
| C11 | Blocco di un oggetto contro modifiche accidentali | ❌ | 1 | E |
| C12 | Ordine e rinomina | ❌ | 1 | E |

### D — Barra di ogni riquadro

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| D1 | **Spessore per riquadro**, da un elenco di 14 valori fissi | ✅ | 3 | C |
| D2 | **Proiezione per riquadro** (media, MIP, MinIP) | ✅ | 3 | C |
| D3 | Adatta alla finestra | ✅ | 3 | — |
| D4 | Istantanea del riquadro | ❌ | 2 | J |
| D5 | Salvataggio dell'immagine con dropdown di formati | 🔶 | 1 | J |
| D6 | Disposizione interna del riquadro (1×1, 1×5) | ✅ | 2 | B |
| D7 | Collegamento fra riquadri: zoom e finestra condivisi | ✅ | 2 | C |
| D8 | Passo di ricostruzione mostrato accanto allo spessore | ✅ | 2 | B |

### E — Sovraimpressioni dei riquadri 2D

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| E1 | **Quota in millimetri** invece del numero di fetta | ✅ | 3 | C |
| E2 | Fattore di zoom scritto | ✅ | 2 | C |
| E3 | Lettere d'orientamento ai quattro bordi | ✅ | 3 | C |
| E4 | Algoritmo di ricostruzione dichiarato | ✅ | 1 | C |
| E5 | Maniglie del mirino sui bordi, colorate come i piani 3D | ✅ | 2 | I |
| E6 | Etichette con **linea di richiamo** che non coprono l'anatomia | ❌ | 3 | F |
| E7 | Etichette visibili su tutte le viste, 3D compreso | ❌ | 2 | F |
| E8 | Barra di scala | ✅ | 2 | — |
| E9 | Finestra e livello mostrati nel riquadro | ✅ | 2 | — |

### F — Curva d'arcata e panorex

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| F1 | Curva disegnabile per punti | ✅ | 3 | — |
| F2 | Due curve indipendenti, superiore e inferiore | ✅ | 3 | — |
| F3 | **Bordi dello slab disegnati** ai lati della curva | ✅ | 3 | G |
| F4 | Punti di controllo con aspetto diverso in modifica | ✅ | 2 | G |
| F5 | Curva estendibile oltre l'arcata, fino ai rami | ✅ | 2 | — |
| F6 | Scostamento vestibolo-linguale sulla rotella | ✅ | 3 | — |
| F7 | Scorrimento lungo l'arcata, con ingrandimento | ✅ | 2 | — |
| F8 | **Frecce sull'assiale** che indicano le sezioni mostrate | ✅ | 3 | G |
| F9 | Anteprima della curva nell'elenco degli oggetti | ❌ | 1 | E |
| F10 | Curva proposta automaticamente dall'anatomia | 🔶 | 2 | N |

### G — Sezioni trasversali

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| G1 | **Posizione in millimetri** su ogni sezione | ✅ | 3 | B |
| G2 | Passo configurabile, fine (150 µm) | ✅ | 3 | B |
| G3 | Spessore configurabile per la striscia | ✅ | 3 | B |
| G4 | Disposizione 1×N scelta dall'utente | ✅ | 2 | B |
| G5 | Scorrimento della striscia legato al panorex e all'assiale | ✅ | 3 | B |
| G6 | Sezione corrente evidenziata | ✅ | 2 | B |
| G7 | Larghezza e altezza della sezione regolabili | ✅ | 2 | — |
| G8 | Clic su una sezione porta le altre viste lì | ✅ | 3 | B |

### H — Riquadro 3D

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| H1 | Rendering a preset di tessuto | ✅ | 3 | — |
| H2 | **Piano assiale disegnato** come cornice | ✅ | 3 | D, G |
| H3 | **Piani coronale e sagittale** disegnati, colorati | ✅ | 3 | D, G |
| H4 | **Banda dell'arcata** disegnata come superficie estrusa | ✅ | 2 | D, G |
| H5 | **Sezione corrente** disegnata come rettangolo | ✅ | 3 | D, G |
| H6 | **Riquadro di ritaglio** disegnato | ❌ | 2 | D, G |
| H7 | Colori dei piani coerenti con le maniglie del mirino | ✅ | 2 | I |
| H8 | Cubo di orientamento | ✅ | 2 | — |
| H9 | Impianti resi in 3D dentro il volume | ✅ | 2 | G |
| H10 | Spigoli nascosti resi diversamente da quelli in vista | ✅ | 1 | D |

### I — Riformattazione e volumi multipli

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| I1 | Ritaglio a un riquadro | ✅ (SegmentKit) | 2 | — |
| I2 | **Ricampionamento** a un passo scelto | ✅ | 2 | A |
| I3 | Riquadro di ritaglio con maniglie su tre viste | ✅ | 2 | A, H |
| I4 | Riquadri **collegati**: uno solo parallelepipedo | ✅ | 2 | A |
| I5 | Nome e descrizione del volume prodotto | ✅ | 1 | A |
| I6 | Più volumi nello studio, selezionabili | ✅ | 2 | K |
| I7 | Ripristina / Salta nella finestra | ❌ | 1 | H |
| I8 | Stima di memoria prima di procedere | ✅ | 2 | A |
| I9 | Riorientamento del volume (piano occlusale orizzontale) | ❌ | 3 | N |

### J — Esportazione e relazione

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| J1 | Relazione impaginata con immagini e misure | ❌ | 2 | J |
| J2 | Stampa | ❌ | 1 | J |
| J3 | Copia negli appunti | ❌ | 2 | J |
| J4 | Istantanea di un riquadro | 🔶 | 2 | J |
| J5 | Esportazione della cartella DICOM | ❌ | 1 | J |
| J6 | Esportazione su disco con visualizzatore | ❌ | 1 | — |
| J7 | Note del caso | ❌ | 1 | E |
| J8 | Esportazione del modello 3D (STL) | 🔶 | 2 | J |
| J9 | Scheda «Rivedi»: rilettura del piano finito | ✅ | 1 | K |

### K — Comportamenti trasversali

| # | Voce | Stato | Peso | Lotto |
|---|---|---|---|---|
| K1 | Annulla e ripeti | ❌ | 3 | O |
| K2 | Preset di rendering come anteprime cliccabili | 🔶 | 2 | H |
| K3 | Impostazioni del mouse configurabili | ❌ | 1 | H |
| K4 | Stato della sessione conservato fra le schede | ✅ | 2 | K |
| K5 | Salvataggio automatico del piano | ❌ | 2 | O |
| K6 | Scorciatoie da tastiera coerenti | 🔶 | 2 | H |

---

## 3. I lotti

| Lotto | Contenuto | Autore | Dipende da | Brief |
|---|---|---|---|---|
| **0** | ArtifactKit — strie da metallo | Codex | SegmentKit | ✅ **consegnato e verificato** |
| **A** | Ricampionamento e piano di riformattazione — I2, I3, I4, I5, I8 | Codex | SegmentKit | ✅ **fatto**, interfaccia compresa |
| **B** | Navigazione delle sezioni — G1…G8, D6, D8 | Codex + me | DentalKit | ✅ **fatto** |
| **C** | Spessore, proiezione e quote per riquadro — D1, D2, D7, E1…E4 | me | — | ✅ **fatto** |
| **D** | Geometria delle sovraimpressioni 3D — H2…H6, H10 | Codex | VolumeKit | ✅ **fatto** |
| **E** | Modello degli oggetti — C1…C12, A5, F9, J7 | Codex | tutti | ✅ **nucleo consegnato**, interfaccia nel lotto H |
| **F** | Collocazione delle etichette — E6, E7 | Codex | E | da scrivere |
| **G** | Disegno: piani nel raycaster, bordi slab, frecce — H2…H6, H9, F3, F4, F8 | me | D | ✅ **fatto**, tranne H6 (il ritaglio vive solo nella sua finestra) |
| **H** | Viste SwiftUI — A1, A2, A4, A7, B12, B13, I3, I7, K2, K3, K6 | Codex | A, B, D, E | da scrivere |
| **I** | Maniglie del mirino colorate — E5, H7 | me | — | ✅ **fatto** |
| **J** | Esportazione e relazione — J1…J5, J8, D4, D5, B11 | Codex | E | da scrivere |
| **K** | Modi di lavoro e volumi multipli — A3, I6, J9, K4 | me | A | ✅ **fatto** |
| **L** | Varianti di misura — B2, B3 | Codex | MeasureKit | da scrivere |
| **M** | Oggetti protesici — B7, B8, B9, B10 | Codex | ImplantKit | da scrivere |
| **N** | Automatismi — F10, I9 | Codex | SegmentKit | da scrivere |
| **O** | Annulla/ripeti e salvataggio automatico — K1, K5 | Codex | E | da scrivere |

### Note sui lotti meno ovvi

**Lotto D — geometria delle sovraimpressioni 3D.** Nucleo puramente proiettivo: dato un
`VolumeCamera` e un piano, produrre i segmenti in coordinate schermo della sua cornice, con il
taglio contro il volume e l'indicazione di quali spigoli sono nascosti. Nessun Metal, tutto
verificabile. Il disegno vero resta mio (lotto G).

**Lotto F — collocazione delle etichette.** Non è grafica, è un problema di collocazione: date *n*
etichette ancorate a *n* punti in un riquadro, trovare posizioni che non si sovrappongano fra loro,
non escano dal riquadro, stiano vicino all'ancora, e con richiami che non attraversino altre
etichette. Algoritmo puro, verificabile per intero.

**Lotto I — maniglie del mirino.** Piccolo ma di sistema: il colore lega la maniglia al piano nel
3D e il piano alla vista. Tre cose collegate da un segno solo, e va deciso una volta per tutte.

> Fatto. Nel farlo è emerso un difetto più grosso di quello che il lotto prometteva di risolvere:
> le due linee erano disegnate a metà riquadro *per definizione*, quindi dal primo taglio obliquo
> in poi mostravano una cosa diversa da quella che il volume stava tagliando. Ora sono
> l'intersezione vera, calcolata da `CrosshairGeometry` e provata sugli obliqui.

**Lotto K — modi di lavoro.** Fatto, con un limite da dichiarare: «personalizzato» e «obliquo»
esistono come schede, hanno la loro disposizione e la loro memoria, ma **non hanno ancora
strumenti propri**. Il piano si inclina già con le maniglie del mirino, e questo copre gran parte
di «obliquo»; manca la definizione di un piano per tre punti, che è il cuore di «personalizzato».
Quello arriva col lotto H. Nel frattempo ogni scheda dichiara in una riga a che serve, perché due
schede con la stessa disposizione e nessuna spiegazione sembrano un doppione.

**Lotto N — automatismi.** Il riorientamento del volume (I9) pesa 3 e nessuno se ne accorge finché
non si apre una CBCT con la testa inclinata, cioè quasi sempre: allineare il piano occlusale
all'orizzontale rende leggibili misure che altrimenti si leggono di traverso. La curva proposta
(F10) diventa possibile con SegmentKit.

**Lotto O — annulla/ripeti.** Pesa 3 ed è l'unica voce del catalogo che non si vede in nessuna
schermata: si nota solo quando manca. Va progettata sul modello degli oggetti del lotto E, non
aggiunta dopo.

---

## 4. Coda e ordine

Codex, un lotto per volta:

```
B → D → E → F → O → H → J → L → M → N
```

L'ordine non è per peso: **E prima di F, H, J e O** perché tutti e quattro poggiano sul modello
degli oggetti, e rifarlo dopo costerebbe più di quanto renda anticiparlo. **D prima di H** perché
la geometria delle cornici serve prima delle viste che le mostrano.

Io in parallelo: **C → G → I → K**.

Ogni consegna passa da qui prima del Mac: compilo, eseguo la suite, reviso i punti che il brief
segnala come critici, e solo allora committo.

Criterio per aggiungere un lotto: deve avere un nucleo verificabile qui. Se una funzione è tutta
vista, va nel lotto H o resta a me — non perché Codex non sappia scriverla, ma perché nessuno
saprebbe dire se funziona finché non la compili tu.
