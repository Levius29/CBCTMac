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

Una sola, per ora. L'elenco va tenuto qui, corto:

- `web/.gitignore` — tolta l'eccezione `!/demo/jane-head-mri.zip`. Senza, un `git add -A` si
  porterebbe dentro i 46 MB dello studio demo per sempre.

E due file nostri aggiunti là dentro, che non possono entrare in conflitto con niente:

- `web/.upstream-commit` — da quale commit dell'originale siamo partiti.

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

## Che cosa resta da decidere

- Se e quando portare nel web la registrazione fra date diverse: la riserva la contiene in Swift
  (`Sources/FollowUpKit`), OpenMRI la fa già in Python con SimpleITK. Finché la base è questa,
  vince la loro — la nostra resta come riferimento e come implementazione senza dipendenze.
- Come collocare l'avviso di uso non diagnostico dentro l'interfaccia: nel `README` c'è, nello
  schermo non ancora.
