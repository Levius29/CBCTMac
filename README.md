# OpenMRI Dental

Visore per CBCT dentali, come applicazione del Mac. Il motore è
[OpenMRI](https://github.com/lev1nson/OpenMRI) di Maksim Khuzin — rendering 3D, tre sezioni legate
fra loro, libreria dei pazienti, confronto fra date diverse — e sopra ci entrano, una alla volta,
le funzioni dentali di 3DMED: per ora la panoramica con la curva d'arcata e le sezioni
trasversali. Nessuna immagine esce dal computer.

> ### ⚠️ Uso non diagnostico
>
> Software **non certificato come dispositivo medico**. Destinato a uso personale, di studio e
> di ricerca. Non va usato per formulare diagnosi né per pianificare interventi su pazienti.

---

## Sul Mac

Serve un Mac con **macOS 12 o successivo**, Apple Silicon o Intel, e per costruire l'app la prima
volta la rete e circa 2 GB liberi. Non serve installare nient'altro: Node, Python e le librerie
arrivano dentro l'app, in versioni fissate e verificate con la loro impronta.

```sh
git clone https://github.com/Levius29/CBCTMac.git
cd CBCTMac
./Tools/make-mac-app.sh --install
```

Il primo giro dura qualche minuto e scarica circa 400 MB; i successivi riusano ciò che c'è già.
Alla fine **OpenMRI Dental** sta in Applicazioni e nel Launchpad: doppio clic, e si apre nella sua
finestra.

### Aprire una CBCT

**File → Open DICOM Folder…**, oppure **⌘O**, e scegli la cartella dell'esame: quella che hai
copiato dal CD o dalla chiavetta del centro va bene così com'è, con il suo `DICOMDIR`, le
sottocartelle e il visualizzatore per Windows accanto. Niente ZIP: l'app legge la cartella dal
disco. Scrivi il nome del paziente e premi **Import**.

Si aprono anche le CBCT in un file solo (multiframe) e quelle compresse JPEG 2000 o JPEG-LS: il
motore le converte con `dcm2niix`.

Poi **Library** porta al visore di OpenMRI — volume 3D e le tre sezioni — e **Dental** alla
panoramica.

### Dove stanno le cose

- La libreria degli esami: `~/Library/Application Support/OpenMRI Dental/library`. Sostituire o
  ricostruire l'app non la tocca. **File → Show Library Folder** la apre.
- Il registro del motore: `~/Library/Logs/OpenMRI Dental/engine.log`. **File → Show Engine Log**.
  Se qualcosa non va, è il file da mandare.

### Prima di importare: si aprirà?

Per sapere in un secondo se una cartella passerà l'importatore, e se no perché, senza aprire
niente:

```sh
python3 Tools/inspect-dicom.py ~/Desktop/cartella-della-cbct
```

### Nel browser, per chi sviluppa

Il motore è lo stesso, e su Linux è l'unica strada: [Node.js](https://nodejs.org) 22.13 o
successivo e Python 3.12, 3.13 o 3.14.

```sh
cd web
npm ci
npm run setup
npm run build
npm run up
```

`npm run down` lo ferma. Il server ascolta **solo su 127.0.0.1**: non ha login, quindi non va
esposto in rete. Nel browser la pagina **Dental** importa anche scegliendo i file, che si
caricano uno per volta.

### La ricostruzione dentale

Il pulsante **Dental** in alto, o l'indirizzo `127.0.0.1:4173/dental`.

Scegli lo studio e la serie, premi **Reconstruct**. Il programma trova l'arcata da solo, distende
la **panoramica** lungo di essa e prepara le **sezioni trasversali**, perpendicolari alla curva —
quelle su cui si giudicano altezza e spessore della cresta. Un clic sulla panoramica sposta la
sezione, le frecce ← → la fanno scorrere.

**Guarda la curva prima di fidarti delle sezioni.** Il riquadro in basso a sinistra mostra la fetta
assiale con sopra la curva trovata: il rilevamento è un'euristica, e quella è l'unica immagine su
cui si vede se ha trovato l'arcata o la colonna cervicale. **Edit** la corregge a mano, punto per
punto, e la correzione resta.

I comandi in fondo rifanno la ricostruzione: spessore dello slab, altezza, passo e misure delle
sezioni, proiezione massima o media. Ogni combinazione resta in cache, quindi tornare su un valore
di prima è immediato.

> Una panoramica ricostruita **non è una radiografia panoramica**: è una superficie campionata, e
> una distanza presa su di essa è una distanza fra due punti di quella superficie. Per la distanza
> fra due strutture vale la sezione trasversale, dove il piano è piatto.

### Lo studio demo

Non è nel repository, perché pesa 46 MB e non cambia mai. Si scarica quando serve:

```sh
Tools/fetch-demo-study.sh
cd web && npm run demo
```

---

## Com'è fatto il repository

```
web/        Il motore. Copia intatta di OpenMRI più ciò che aggiungiamo noi.
desktop/    L'app del Mac: finestra, menu, pannello per le cartelle, e la sua prova completa.
Tools/      Utilità (app del Mac, controllo DICOM, scarico del demo) e i ventisei controlli.
Sources/    La riserva Swift: la matematica dentale, già provata, da portare nel web.
Tests/      Le sue prove.
docs/       Architettura, decisioni, piano di lavoro.
```

**`web/` si tocca il meno possibile.** Restiamo agganciati all'originale per poterne tirare le
correzioni e le funzioni nuove; ogni riga che cambiamo dentro i loro file è un conflitto che
torna al prossimo aggiornamento. Le aggiunte nostre vanno in file nostri. Le modifiche locali —
oggi **quattro** — sono elencate in [`docs/openmri-dental.md`](docs/openmri-dental.md).

### La riserva Swift

`Sources/` contiene quindici moduli e 1.109 prove: parser DICOM, MPR e raycasting Metal, panorex
e curva d'arcata, canale alveolare e impianti, dime chirurgiche, segmentazione dei denti,
cefalometria, e da oggi la registrazione fra due esami di date diverse. **Non è il programma**: è
il magazzino da cui si porta una funzione per volta, leggendo codice già provato invece di
ripensarlo. Si compila e si verifica come prima —
vedi [`docs/swift-reserve.md`](docs/swift-reserve.md):

```sh
swift test
for controllo in Tools/check-*.py; do python3 "$controllo" || break; done
```

### Che cosa manca, e in che ordine

Portate: **panoramica e curva d'arcata**, con le sezioni trasversali e la correzione a mano della
curva. Restano, in quest'ordine: la **piena risoluzione** — oggi il motore riduce ogni asse a 320
voxel, e su una CBCT da un quarto di millimetro le sezioni ne soffrono — poi le misure con
l'incertezza dichiarata, il canale alveolare con gli impianti e i loro allarmi, la segmentazione
di denti e osso con l'uscita STL, le scansioni intraorali, le dime, la cefalometria, i referti.
Ognuna arriva dal suo modulo della riserva, con le sue prove.

---

## Da dove viene

`web/` è [lev1nson/OpenMRI](https://github.com/lev1nson/OpenMRI) al commit `a881ba7`, licenza
MIT, © 2026 Maksim Khuzin: la sua licenza è conservata in `web/LICENSE` e vale per quel codice.
Il resto del repository è MIT, © 2026 Levius29 — vedi [`LICENSE`](LICENSE).

Grazie a chi ha scritto OpenMRI: la parte difficile — un visore locale che si installa con un
comando e funziona — era già fatta.
