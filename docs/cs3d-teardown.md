# Che cosa fa CS 3D Imaging, letto dalle sue schermate

Analisi di cinque schermate di **CS 3D Imaging v3.10.33** (Carestream), il programma con cui si
lavora davvero. Non è un elenco di desideri: ogni voce dice cosa fa loro, cosa fa il nostro, e se
vale la pena — con la stessa disciplina di `docs/competitive-analysis.md`.

Le schermate mostrano quattro schede: **Sezionamento ortogonale**, **curvo**, **personalizzato**,
**obliquo**, più **Rivedi**. Noi copriamo la prima e la seconda; le altre due sono ricostruzioni su
piano arbitrario, che il nostro motore MPR sa già fare — manca solo l'interfaccia.

---

## 1. Le cose che ci mancano e che si usano ogni minuto

### 1.1 Spessore e proiezione **per riquadro**, da un menu di valori fissi

Ogni riquadro ha la propria barra con uno spessore — la tendina mostra 150 µm, 449 µm, 750 µm,
1,1 mm, 1,9 mm, 2,9 mm, 4,0 mm, 5,0 mm, 10,0 mm, 14,8 mm, 19,9 mm, 29,8 mm, 40,0 mm, 49,9 mm — e
una proiezione (`AVG`). Da noi spessore e proiezione sono **globali**, nell'ispettore.

È il controllo che si tocca più spesso, ed è per riquadro perché serve così: l'assiale a fetta
sottile per vedere la corticale, il panorex a 20 mm per l'insieme, la sezione a 1 mm per misurare.
Con un valore solo condiviso si passa la giornata a cambiarlo avanti e indietro.

**Fatto**: `PanoramicLayout.slabThicknessPresetsMM` con la stessa scala.
**Da fare**: il controllo per riquadro, e `slabThicknessMM` per `MPRPlane` invece che globale.

### 1.2 Lo scostamento vestibolo-linguale del panorex ✅

Il pannello in alto al centro riporta `−1,5 mm`, `0 µm`, `−150 µm`: è lo scostamento **in
profondità** rispetto alla curva, non la posizione lungo l'arcata. Sfogliare l'arcata da
vestibolare a linguale è indispensabile con uno slab sottile, perché una curva d'arcata è
un'approssimazione e i denti stanno un po' più fuori o un po' più dentro.

**Fatto**: `PanoramicLayout.normalOffsetMM`, sulla rotella, con l'etichetta.
**Meglio di loro**: l'etichetta scrive il verso — «1,50 mm linguale» invece di «−1,5 mm». Il segno
da solo obbliga a ricordare una convenzione, e lo si legge nel momento in cui costa di più:
valutando lo spessore di corticale prima di posizionare un impianto.

### 1.3 Sezioni trasversali con passo e posizione dichiarati

La griglia in basso è `1×5`, con spessore `1,1 mm` e passo `150 µm`, e ogni riquadro porta la
propria posizione: `71,7 mm`, `72,8`, `73,8`, `74,8`, `75,9`. Sull'assiale, **frecce blu** indicano
quali sezioni sono mostrate e dove cadono.

Da noi le sezioni ci sono ma numerate `1–10 di 51`, senza posizione in millimetri e senza
riscontro sull'assiale. Il numero d'ordine non dice niente; la posizione lungo l'arcata sì.

**Da fare**: posizione in mm su ogni sezione, passo configurabile, e i segni sull'assiale.

### 1.4 Il 3D mostra i piani di taglio

Nel riquadro 3D compaiono le cornici colorate dei piani: il **cilindro rosso** che è la banda
dell'arcata, il **piano azzurro** della sezione corrente, il **rombo giallo** dell'assiale. Con un
colpo d'occhio si sa dove si sta guardando.

Noi abbiamo il cubo di orientamento, che dice *da che parte* si guarda ma non *dove taglia*.

**Da fare**: disegnare i piani nel raycaster. Costa poco ed è il pezzo che lega le quattro viste.

### 1.5 Maniglie del mirino sui bordi

Nella scheda ortogonale, ai bordi di ogni riquadro ci sono maniglie colorate a T, dello stesso
colore del piano corrispondente nel 3D: si trascinano per spostare la fetta. È più scopribile del
nostro «rotella per scorrere», che non si vede finché non lo si prova.

### 1.6 Elenco degli oggetti, con occhio e cestino

Il pannello a sinistra cambia in base a cosa si sta facendo: **Impianto** mostra la lista degli
impianti con lunghezza e diametro modificabili in linea, un occhio per la visibilità, un quadratino
di colore, un cestino; **Arcata** fa lo stesso per le curve.

Da noi le annotazioni stanno in un elenco nell'ispettore, ma impianti, nervi e curve no.

### 1.7 Etichette con linea di richiamo

Ogni impianto porta un'etichetta collegata da una linea sottile: `AlphaBiotec / DFI 3.75 /
L 8,00 mm / Ø 3,85 mm`. Compare **su tutte le viste**, 3D compreso, e non copre l'anatomia perché
la linea la porta fuori.

### 1.8 Strumento di riformattazione

Una finestra a parte con sagittale, coronale e assiale, un **riquadro di ritaglio** con maniglie
trascinabili su ogni vista, la scelta della **dimensione del voxel** (150 µm), un nome e una
descrizione. Produce un volume nuovo, più piccolo e ricampionato.

È esattamente ciò che `SegmentKit.VolumeCrop` sa già fare. Manca l'interfaccia e il
ricampionamento a un passo diverso.

---

## 2. Dove possiamo fare meglio, e non per presunzione

Tre cose sono conseguenze di scelte già fatte, non ambizioni.

**Le misure sono verificabili da chi le usa.** `Tools/PhantomGenerator` genera una serie DICOM con
un cubo da 20,00 mm e sfere di densità note, e la rilegge con un parser indipendente. CS non offre
nulla di simile: ci si fida della validazione del produttore. Per un dispositivo certificato è
legittimo; non è la stessa cosa.

**I valori sono etichettati GV, non HU.** CS scrive `FDK` in ogni riquadro — l'algoritmo di
ricostruzione — il che è onesto, ma poi tratta i valori come se fossero confrontabili. Noi diciamo
esplicitamente che non lo sono.

**Il verso è scritto, non affidato al segno.** Vale per lo scostamento vestibolo-linguale, e
varrà per ogni misura orientata.

E una quarta che arriverà con ArtifactKit: **la provenienza del volume**. In CS, se si applica una
correzione, le misure successive non lo dicono. Da noi un volume corretto sarà marcato come tale e
una ROI che cade in zona corretta lo dirà.

---

## 3. Ordine dei lavori

Ricalcolato su queste schermate. Le voci sono ordinate per quanto si toccano in una giornata di
lavoro, non per difficoltà.

```
1. Scostamento vestibolo-linguale del panorex          ✅ fatto
2. Spessore e proiezione per riquadro, con i preset     ← il controllo più usato
3. Sezioni: posizione in mm, passo, segni sull'assiale  ← «per i fatti loro», risolto
4. Piani di taglio disegnati nel 3D                     ← lega le quattro viste
5. Elenco oggetti: impianti, nervi, curve               ← con occhio, colore, cestino
6. Etichette con linea di richiamo                      ← su tutte le viste
7. Strumento di riformattazione                         ← SegmentKit c'è già
8. Maniglie del mirino sui bordi                        ← scopribilità
9. Schede "personalizzato" e "obliquo"                  ← il motore MPR c'è già
```

I punti 2 e 3 sono quelli che cambiano la giornata di chi usa il programma. Il 4 è il più
economico rispetto a quanto rende. Il 7 non richiede algoritmi nuovi, solo interfaccia.
