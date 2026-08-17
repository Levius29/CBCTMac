# CS 3D Imaging, smontato

Analisi di cinque schermate di **CS 3D Imaging v3.10.33** (Carestream), pannello per pannello.
Serve a produrre un piano di lavoro, non un elenco di desideri: la traduzione in lotti sta in
[`docs/work-plan.md`](work-plan.md).

Il caso mostrato è una mascella con quattro impianti e artefatti da metallo severi — visibili come
stelle nell'assiale della quarta schermata. È lo stesso genere di studio su cui lavoriamo.

---

## 1. Impalcatura generale

**Barra dei titoli**: nome del programma a sinistra, **nome del paziente al centro**, icona utente
e menu a destra. Il nome del paziente al centro non è vezzo: è ciò che si guarda per essere sicuri
di lavorare sul caso giusto, e sta nel punto di massima attenzione.

**Cinque schede**: `Sezionamento ortogonale`, `Sezionamento curvo`, `Sezionamento personalizzato`,
`Sezionamento obliquo`, `Rivedi`. Le schede sono **modi di lavoro**, non finestre: ognuna dispone i
riquadri come serve a quel compito. Noi abbiamo un selettore di layout, che è meno.

Le prime due le copriamo. `personalizzato` e `obliquo` sono ricostruzioni su piano arbitrario — il
nostro kernel MPR le sa già fare, manca l'interfaccia. `Rivedi` è la relazione finale.

**Colonna di sinistra**, quattro pannelli richiudibili:

| Pannello | Contenuto |
|---|---|
| Regolazioni | sei anteprime: preset di rendering, riorientamento del volume, e altro |
| Strumenti | griglia di icone; alcune con un triangolino, cioè con varianti |
| *contestuale* | cambia: `Impianto`, `Arcata`… — l'elenco degli oggetti del tipo attivo |
| Esporta | otto icone: relazione, stampa, appunti, foto, cartella, disco, note, invio |
| Galleria | richiuso in fondo |

Il pannello contestuale è il pezzo che ci manca di più a livello di impianto: **gli oggetti del
piano hanno un elenco**, e da lì si accendono, si colorano, si cancellano.

**Barra per riquadro**: ogni vista ha la propria, con salvataggio, adatta alla finestra,
istantanea, **disposizione** (`1x1`, `1x5`), **spessore** e **proiezione** (`AVG`). Da noi spessore
e proiezione sono globali nell'ispettore.

**Etichette d'orientamento** ai quattro bordi di ogni riquadro: `A`/`P`, `R`/`L`, `H`/`F`. E
`FDK` in basso a sinistra, cioè l'algoritmo di ricostruzione: dichiarare da dove vengono i dati.

---

## 2. Scheda «Sezionamento curvo»

Quattro riquadri: assiale con la curva, panorex, coronale, 3D, più la striscia di sezioni.

### 2.1 Assiale con la curva

`61,6 mm` e `zoom: 0,63` in alto a sinistra, in arancio. La quota **in millimetri**, non il numero
di fetta.

La curva è disegnata come **tre linee**: una bianca centrale e due rosse ai lati. Le rosse sono i
bordi dello slab, cioè si vede *quanto spesso* è il panorex che si sta guardando. Da noi lo
spessore è un numero nell'ispettore e non si vede sull'anatomia.

I punti di controllo sono **cerchi bianchi**; in modifica diventano **quadrati rossi** con gli
estremi bianchi. Due stati visivi distinti per due modi diversi.

Nella terza schermata la curva scende posteriormente fino ai rami mandibolari, **oltre l'arcata
dentale**. Non è un errore: la si estende per avere sezioni anche dove i denti non ci sono più.

**Frecce blu** partono dalla curva verso l'esterno: indicano quali sezioni trasversali sono
mostrate in basso e dove cadono. È il legame fra le due viste, e da noi non esiste.

### 2.2 Panorex

`−1,5 mm`, `0 µm`, `−150 µm` a seconda della schermata: lo **scostamento vestibolo-linguale**.
Già implementato, con il verso scritto per esteso invece del solo segno.

### 2.3 Coronale

Etichetta dell'impianto con linea di richiamo. **Maniglie blu** sopra e sotto, sui bordi: si
trascinano per spostare la fetta.

### 2.4 Riquadro 3D

Il pezzo più denso di informazione, e il più economico da imitare.

Compaiono le **cornici dei piani di taglio**: un cilindro rosso che è la banda dell'arcata estrusa
in verticale, un rettangolo azzurro che è la sezione corrente, un rombo giallo che è il piano
assiale, un rettangolo bianco che è il riquadro di ritaglio. Con un colpo d'occhio si sa dove si
sta guardando in tutte le altre viste.

Cubo di orientamento in basso a sinistra, con le lettere in arancio. Quello ce l'abbiamo.

### 2.5 Striscia di sezioni trasversali

Disposizione `1x5`, spessore `1,1 mm`, passo `150 µm`. Ogni riquadro porta la **posizione in
millimetri**: `71,7`, `72,8`, `73,8`, `74,8`, `75,9`. Noi scriviamo `1–10 di 51`, che non dice
niente: il numero d'ordine non è una grandezza.

L'impianto è disegnato come rettangolo bianco con **punti blu di manipolazione** e una linea gialla
che prosegue oltre l'apice — l'asse della fresa, cioè dove andrà il foro. Nella sezione più
distante l'impianto appare inclinato, perché quella sezione lo taglia di sbieco: il disegno
racconta l'obliquità invece di nasconderla.

---

## 3. Scheda «Sezionamento ortogonale»

Assiale, 3D, coronale, sagittale. Ogni 2D con quota e zoom.

**Maniglie del mirino sui bordi**: marcatori a T colorati — magenta, ciano, giallo — dello stesso
colore dei piani nel 3D. Si trascinano per spostare la fetta corrispondente. Il colore lega la
maniglia al piano, e il piano alla vista: tre cose collegate da un solo segno.

Il pannello Strumenti qui è più corto: gli strumenti sono quelli del contesto, non tutti sempre.

---

## 4. Strumento di riformattazione

Finestra a parte. Sagittale, coronale e assiale affiancate, ognuna con un **riquadro di ritaglio**
bianco con maniglie tonde agli angoli e a metà dei lati. I riquadri sono **collegati**: muovendone
uno si aggiornano gli altri, perché descrivono un unico parallelepipedo.

Sotto: `☑ Riquadro di ritaglio`, `Dimensione voxel: 150 µm`, `Nome volume`,
`Descrizione: Volume riformattato`, e i pulsanti `Ripristina` `Esci` `OK` `Salta`.

Produce un **volume nuovo**, più piccolo e ricampionato al passo scelto. È ciò che rende praticabile
lavorare su una regione a piena risoluzione senza tenere in memoria l'intero FOV.

`SegmentKit.VolumeCrop` fa già il ritaglio. Manca il **ricampionamento** a un passo diverso, e
l'interfaccia.

---

## 5. Riepilogo dei divari

| # | Cosa | Da noi | Peso |
|---|---|---|---|
| 1 | Scostamento vestibolo-linguale | ✅ fatto | — |
| 2 | Spessore e proiezione **per riquadro**, con preset | globali | **alto** |
| 3 | Sezioni: posizione in mm, passo, segni sull'assiale | numerate | **alto** |
| 4 | Piani di taglio disegnati nel 3D | assenti | **alto/costo basso** |
| 5 | Elenco degli oggetti con occhio, colore, cestino | solo annotazioni | alto |
| 6 | Etichette con linea di richiamo | assenti | medio |
| 7 | Riformattazione: ritaglio + ricampionamento | metà fatta | medio |
| 8 | Bordi dello slab disegnati sulla curva | assenti | medio |
| 9 | Maniglie del mirino sui bordi | assenti | medio |
| 10 | Quota in mm invece del numero di fetta | numero | basso/costo nullo |
| 11 | Schede «personalizzato» e «obliquo» | assenti | basso |
| 12 | Catalogo impianti con misure reali | generico | vincolo di IP |

---

## 6. Dove restiamo avanti, e perché non è vanto

Quattro cose, tutte conseguenze di scelte fatte all'inizio.

**Le misure sono verificabili da chi le usa.** `Tools/PhantomGenerator` genera una serie DICOM con
un cubo da 20,00 mm e sfere di densità note, e la rilegge con un parser indipendente. CS non offre
nulla di simile: ci si fida della validazione del produttore, il che per un dispositivo certificato
è legittimo e non è la stessa cosa.

**I valori sono etichettati GV.** CS scrive `FDK` in ogni riquadro, che è onesto, ma poi presenta i
valori come confrontabili. Noi diciamo che non lo sono.

**Il verso è scritto, non affidato al segno.** «1,50 mm linguale», non «−1,5 mm».

**La provenienza del volume**, che arriva con ArtifactKit: un volume corretto sarà marcato come
tale, e una ROI che cade in zona corretta lo dirà. In CS, applicata una correzione, le misure
successive non lo dicono.
