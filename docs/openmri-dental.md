# La base è OpenMRI

Questo documento registra il cambio di base del progetto: che cosa si è deciso, su quali fatti, e
che cosa ne consegue per chi ci lavora. Non è una cronaca: è il posto dove si torna quando fra sei
mesi qualcuno chiede «perché il programma è in TypeScript e la matematica in Swift?».

## Che cosa è cambiato

Il programma **non è più** l'applicazione SwiftUI. Il programma è
[OpenMRI](https://github.com/lev1nson/OpenMRI), copiato in `web/`, e su di esso si innestano le
funzioni dentali. I moduli Swift restano dov'erano e diventano **la riserva**: matematica già
provata da cui si porta una funzione per volta.

## I fatti su cui si è deciso

Contati leggendo il codice, non a impressione.

| | OpenMRI | Riserva Swift |
|---|---|---|
| Righe di codice proprio | ~4.900 TypeScript | ~55.000 Swift |
| Segmentazione | **nessuna**: `lib/analysis-contract.ts` valida un risultato che nessuno produce | soglia, crescita di regione e competitiva, morfologia, taglio minimo, denti automatici |
| Misure | **nessuna**: il README dichiara «does not detect, measure, or diagnose» | distanze, angoli, ROI, incertezza dichiarata |
| Dentale | niente | panorex, curva d'arcata, canale alveolare, impianti, dime, cefalometria |
| Rendering | NiiVue, tre palette, un piano di taglio | Metal: MPR, slab, raycasting, transfer function |
| Import | dcm2niix + pydicom: mangia qualunque DICOM e i NIfTI | parser DICOM nostro, nativo, RLE e JPEG Lossless |
| **Funziona oggi** | **sì**: un comando, uno studio demo, una schermata d'ingresso curata | compila e ha 1.046 prove verdi; l'interfaccia non è mai stata percorsa a mano |

L'ultima riga è quella che ha deciso. Un visore che si apre stasera con i propri esami vale più di
un visore migliore che nessuno ha ancora visto funzionare.

## Le otto decisioni

1. **Dove**: `web/`, copia intatta. Nessuna collisione con i nostri file, e l'aggancio
   all'originale resta possibile.
2. **La riserva Swift resta.** Non è il prodotto e non si cancella: è il magazzino.
3. **Lo studio demo non si versiona.** 46 MB che non cambiano mai; `Tools/fetch-demo-study.sh` lo
   scarica quando serve. Il filmato d'ingresso, 2,7 MB, resta dentro.
4. **Restiamo agganciati all'originale**: `Tools/update-openmri.sh` porta dentro le loro novità.
5. **Il nome è OpenMRI Dental**, fork dichiarato. Dice che cos'è e da dove viene.
6. **L'interfaccia parla inglese**, come l'originale. Documenti, commit e commenti restano in
   italiano, come dice `CLAUDE.md`. Tradurre le loro schermate significherebbe toccare i loro
   file, cioè comprarsi un conflitto a ogni aggiornamento, in cambio di niente che si veda.
7. **La prima funzione dentale da portare è la panoramica con la curva d'arcata**: è ciò che
   distingue un visore CBCT da un visore qualunque.
8. **Il calcolo pesante gira in Python**, accanto all'import e alla registrazione che già ci
   girano. Nessun ambiente nuovo da installare.

## Le regole per non rompere l'aggancio

**Dentro `web/` si tocca il meno possibile.** Ogni riga cambiata nei loro file è un conflitto che
torna al prossimo aggiornamento. Ciò che aggiungiamo va in **file nostri**, dentro `web/` dove
serve, e si innesta nei loro nei punti più stretti possibile.

### Modifiche locali al tree copiato

Due, e l'elenco va tenuto corto:

- `web/.gitignore` — tolta l'eccezione `!/demo/jane-head-mri.zip`. Senza, un `git add -A` si
  porterebbe dentro i 46 MB dello studio demo per sempre.
- `web/app/viewer.tsx` — un collegamento alla pagina dentale nella barra in alto, più il suo
  `import`. È l'unico punto in cui l'interfaccia dell'originale nomina roba nostra; tutto il resto
  della ricostruzione dentale sta in file nostri.

E i file nostri aggiunti là dentro, che non possono entrare in conflitto con niente:

- `web/.upstream-commit` — da quale commit dell'originale siamo partiti.
- `web/scripts/dental_panorama.py`, `web/tests/test_dental_panorama.py`, `web/lib/dental.ts`,
  `web/app/api/dental/**`, `web/app/dental/**` — la ricostruzione dentale.

### Una regola dell'originale che qui non vale

`web/AGENTS.md` dice: «OpenMRI is a viewer: it must not detect, measure, or diagnose». È la regola
del **loro** progetto, ed è giusta per un visore generico. Questo fork esiste per fare di più, e la
differenza va detta invece che lasciata intendere: la ricostruzione dentale **ricostruisce viste**
— una panoramica e sezioni perpendicolari all'arcata — e continua a non diagnosticare niente.
L'avviso di uso non diagnostico resta dov'è, in fondo alla pagina e nel README.

## Tirare gli aggiornamenti dall'originale

```sh
Tools/update-openmri.sh
```

Scarica il loro repository in una copia nascosta, elenca i commit nuovi, calcola la differenza dal
commit registrato in `web/.upstream-commit` e la applica a `web/` in tre vie. Le nostre modifiche
locali, se toccano le stesse righe, diventano un conflitto marcato invece di sparire. Dopo:

```sh
cd web && npm ci && npm run check
```

## Portare una funzione dalla riserva

La ricetta, nell'ordine in cui conviene:

1. **Leggere il modulo Swift** e i suoi test: lì c'è il contratto, i casi limite e — nei commenti
   — il difetto che ogni scelta corregge. È il motivo per cui la riserva non si cancella.
2. **Riscrivere il calcolo in Python**, accanto a `web/scripts/import_mri.py`, con le sue prove
   (`npm run test:import`). I contratti di `docs/architecture.md` valgono lì come valevano in
   Swift: coordinate Patient in millimetri, ordinamento delle slice per proiezione, «GV» e non
   «HU», nessun numero con più precisione di quanta ne abbia.
3. **Esporre il risultato** con una route in `web/app/api/`, in un file nostro.
4. **Disegnare** in un componente nostro, in inglese, agganciato al visore nel punto più stretto
   possibile.

## La ricostruzione dentale

La prima funzione portata dalla riserva, ed è quella senza cui una CBCT dentale non si legge: i
denti stanno su una curva, e qualunque taglio piatto li attraversa di sbieco.

- `web/scripts/dental_panorama.py` — il calcolo: rilevamento automatico dell'arcata, panoramica
  come slab curvo, sezioni perpendicolari. È il porto fedele di `Sources/DentalKit` e di
  `Sources/SegmentKit/ArchDetection.swift`, scelte non ovvie comprese — Catmull-Rom, passo d'arco
  costante, scala isotropa, slab centrato, soglia di Otsu, i tre criteri di rifiuto.
- `web/tests/test_dental_panorama.py` — diciassette prove su un'arcata **nota per costruzione**:
  la curva trovata deve coincidere con quella vera, la banda d'osso deve cadere alla quota giusta,
  la sezione deve tagliare il tubo d'osso al centro, e un blocco pieno o un volume vuoto devono
  essere **rifiutati**.
- `web/lib/dental.ts` e `web/app/api/dental/**` — il contorno: dove sta il volume, quali opzioni
  sono ammesse, la cache indicizzata sulle opzioni.
- `web/app/dental/**` — la pagina: panoramica in alto, fetta assiale con la curva disegnata sopra,
  sezione trasversale, e i comandi che rifanno la ricostruzione.

### L'importazione da cartella, e il pacchetto macOS

Due cose che l'originale non fa, e che su un computer di studio pesano più di quanto sembri.

- `web/app/api/dental/upload/` e `web/app/dental/folder-import.tsx` — si aprono i **`.dcm`
  direttamente**, scegliendoli nel pannello del browser: file singoli o una cartella intera. Si
  caricano uno per volta — una CBCT sono seicento file per mezzo gigabyte, e in un invio solo la
  memoria si riempie senza poter dire a che punto si è — e il server ne fa l'archivio nel punto
  esatto in cui il motore dell'originale se lo aspetta. Da lì è un'importazione identica a quella
  di sempre.
- `web/scripts/zip_folder.py` e `web/lib/dental-import.ts` — la stessa cosa per una cartella che
  sta **già** sul computer: si incolla il percorso e il server la legge dal disco invece di
  farsela caricare. Per una cartella da un gigabyte è la strada svelta.

### Il pacchetto macOS, tentato e messo da parte

`Tools/make-mac-app.sh` costruisce un `OpenMRI Dental.app` che avvia il server e apre una finestra
dedicata. **Sul Mac di prova non è partito**, e il perché non si sa ancora — serve
`~/Library/Logs/OpenMRI Dental.log`. Finché non si sa, il README non lo propone: la strada buona
resta `npm run up` e il browser.

Gli script restano perché il lavoro è fatto e il difetto è probabilmente piccolo — il PATH di
un'applicazione lanciata dal Finder, o il permesso d'esecuzione perso nel clone. Quando arriva il
registro si chiude in dieci minuti. Un'applicazione nativa vera — Electron, Tauri — è un'altra
cosa ancora, e costa duecento megabyte o una catena di compilazione in Rust.

**Il limite da sapere.** Il volume su cui si ricostruisce è quello che OpenMRI prepara
all'importazione, ricampionato a un massimo di 320 voxel per asse: su una CBCT a campo grande
significa mezzo millimetro di voxel invece di un quarto. La panoramica ne risente poco, le sezioni
trasversali sì. Il passo successivo è una conversione a piena risoluzione riservata al dentale, e
va fatta sapendo che costa memoria.

**Perché la curva si guarda sulla fetta assiale.** Il rilevamento è un'euristica, e una proposta
sbagliata è peggio di nessuna proposta: chi la riceve la corregge invece di rifarla. La fetta con
la curva sopra è l'unica immagine su cui si può giudicare, e sta nella pagina per questo, non per
decorazione.

## Le prove, e una che chiede una cosa in più

```sh
cd web
npm run check                     # lint, tipi, prove Node
Tools/../../Tools/fetch-demo-study.sh   # solo la prima volta
npm run test:import               # 26 prove Python, 17 nostre
```

Una delle prove dell'originale importa lo studio demo, che qui non è versionato: senza,
`npm run test:import` fallisce su quella sola con un `FileNotFoundError`. Si scarica una volta con
`Tools/fetch-demo-study.sh` e non se ne parla più.

## Che cosa resta da decidere

- Se e quando portare nel web la registrazione fra date diverse: la riserva la contiene in Swift
  (`Sources/FollowUpKit`), OpenMRI la fa già in Python con SimpleITK. Finché la base è questa,
  vince la loro — la nostra resta come riferimento e come implementazione senza dipendenze.
- L'avviso di uso non diagnostico: nel `README` c'è, e nella pagina dentale pure, in fondo. Nel
  resto dell'interfaccia dell'originale c'è la loro dicitura, più blanda.

## Il prossimo passo dal magazzino

Nell'ordine in cui conviene, ciascuno con il suo modulo Swift già provato da cui leggere:

1. **Correggere la curva a mano** — trascinare i punti di controllo sulla fetta assiale.
   `Sources/DentalKit/ArchEditing.swift`. È la cosa che manca di più: il rilevamento automatico
   funziona o non funziona, e quando non funziona adesso non c'è rimedio dentro la pagina.
2. **Misure sulle sezioni** — altezza e spessore della cresta, con l'incertezza dichiarata
   (Contratto 5). `Sources/MeasureKit`.
3. **Canale alveolare e impianti** — `Sources/ImplantKit`, che è il cuore del pianificatore e
   pretende le misure già pronte sotto.
4. **Volume a piena risoluzione** per il dentale, vedi il limite qui sopra.
