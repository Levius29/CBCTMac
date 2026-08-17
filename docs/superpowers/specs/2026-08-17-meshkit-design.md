# MeshKit — specifica di progettazione

**Data:** 17 agosto 2026
**Stato:** approvato nel dialogo e aggiornato con le integrazioni di revisione
**Ramo:** `codex/meshkit`

## 1. Obiettivo e confini

MeshKit importa ed esporta mesh di superficie e registra rigidamente una scansione
intraorale nello spazio Patient della CBCT. Il modulo usa soltanto Foundation e DICOMCore,
compila in Swift 6 strict concurrency su macOS e Linux e non conosce UI, Metal o `simd`.

Il lavoro comprende:

- primitive e operazioni geometriche su mesh triangolari;
- import STL, PLY e OBJ ed export STL;
- registrazione rigida chiusa da coppie di punti;
- affinamento ICP con ricerca spaziale;
- maschera delle regioni escluse dalla registrazione;
- test costruiti interamente da byte e geometrie sintetiche.

Non comprende rendering, interazione grafica, segmentazione CBCT, estrazione di isosuperfici,
registrazione non rigida o decisioni cliniche sulla qualità del fit.

`Package.swift` aggiunge il prodotto e il target `MeshKit`, dipendente esclusivamente da
`DICOMCore`, e il target `MeshKitTests`. Nessun altro modulo applicativo viene modificato.

## 2. Regole trasversali

- Tutti i tipi pubblici sono `Sendable`.
- La geometria in memoria è sempre `Double`. I `Float32` presenti in STL e PLY vengono letti
  nel loro formato nativo e allargati immediatamente a `Double`; l'export effettua la
  conversione opposta soltanto nel momento in cui scrive il formato.
- Ogni lettura di byte verifica prima il range. Un input troncato genera un errore e non può
  causare un accesso fuori dai limiti.
- Ogni vertice importato viene verificato con `Vec3.isFinite` prima di entrare nella mesh.
  `NaN` e infinito sono valori rappresentabili nei formati floating-point, ma non coordinate
  valide: generano `MeshIOError.malformed` con nome del file e indice del vertice. Non vengono
  sostituiti con zero, perché ciò creerebbe un vertice fantasma all'origine.
- Ogni conversione da coordinata a indice di griglia verifica nuovamente `isFinite` e usa
  `Int(exactly: Foundation.floor(coordinate / cellSize))`. Questa seconda guardia è necessaria
  perché `Mesh.init` e gli array passati a ICP possono provenire dall'applicazione, non
  soltanto dai parser;
  `Int(Double.nan)` causa un trap a runtime.
- Gli errori di import nominano sempre il file e descrivono in italiano la causa.
- Nessun `try!`, `fatalError` o force unwrap viene usato su dati d'ingresso.
- I commenti e le doc comment sono in italiano; gli identificatori restano in inglese.
- I nuovi test usano XCTest, non macro, e non versionano fixture.

## 3. Mesh e geometria

`Triangle` conserva tre indici di vertice. `Mesh` conserva vertici in millimetri, triangoli e
nome della sorgente. Le operazioni che ricevono una mesh costruita manualmente trattano anche
indici non validi come dati malformati: ignorano il triangolo invece di eseguire un subscript
non sicuro.

Le proprietà derivate seguono queste regole:

- `boundsMM` è `nil` per una mesh senza vertici;
- `centroidMM` è la media aritmetica dei vertici e vale `.zero` quando non ve ne sono;
- la normale di faccia è il prodotto vettoriale normalizzato e vale `nil` per indici non
  validi, indici ripetuti o area nulla;
- le normali di vertice sommano i prodotti vettoriali non normalizzati, ottenendo una media
  pesata per area; un vertice isolato riceve `.zero`;
- l'area è metà della norma del prodotto vettoriale;
- il volume orientato è `dot(a, b × c) / 6`, sommato sulle facce. È significativo soltanto
  per una superficie chiusa e orientata coerentemente e la doc comment lo dichiara;
- una trasformazione applica `Transform3D.apply(toPoint:)` ai vertici e conserva topologia e
  nome.

### Welding

Il welding usa una griglia spaziale con cella pari alla tolleranza e cerca nelle 27 celle
adiacenti. Controllare solo la cella ottenuta per arrotondamento perderebbe duplicati situati
ai due lati di un confine. Il primo vertice incontrato diventa il rappresentante stabile e
tutti i triangoli vengono reindicizzati. Il metodo non elimina implicitamente le facce che
diventano degeneri: quella responsabilità resta a `removingDegenerateTriangles()`.

Un vertice non finito costruito direttamente dall'applicazione viene conservato come vertice
unico, ma non viene convertito in coordinate di cella né inserito nella griglia. In questo modo
`welded()` resta non fallibile e non può effettuare la conversione intrinsecamente pericolosa
da `NaN` o infinito a `Int`.

Una tolleranza non finita o non positiva restituisce la mesh invariata, perché l'API non è
fallibile e non deve inventare una distanza valida. `removingDegenerateTriangles()` scarta
indici ripetuti, indici fuori range e facce con area nulla.

## 4. Importazione ed esportazione

`MeshIO` espone soltanto le API pubbliche richieste. Un cursore privato legge interi e valori
floating-point byte per byte, senza caricare valori non allineati tramite puntatori.
`load(url:)` usa `lastPathComponent` come nome e converte anche gli errori Foundation in
`MeshIOError.malformed`, mantenendo il percorso nel dettaglio.

Una mesh importata deve contenere almeno un vertice e un triangolo; diversamente genera
`emptyMesh`. Gli indici delle facce vengono validati prima di costruire il risultato. Ogni
coordinata STL, PLY o OBJ viene inoltre validata immediatamente dopo la lettura: l'errore
`malformed` nomina il file e l'indice progressivo del vertice non finito.

### STL

Il riconoscimento controlla prima la struttura binaria:

1. se esistono almeno 84 byte, legge il conteggio little-endian agli offset 80...83;
2. calcola la dimensione attesa con aritmetica protetta da overflow;
3. considera il file STL binario soltanto se `data.count == 84 + 50 × count`;
4. soltanto quando la dimensione non coincide tenta STL ASCII.

Questa precedenza è obbligatoria perché molti STL binari iniziano con `solid`. Un conteggio
assurdo in un contenuto non testuale viene rifiutato con `tooManyTriangles` prima di qualsiasi
allocazione. Un vero testo ASCII resta libero di avere byte casuali agli offset 80...83.

Il parser binario ignora la normale memorizzata e legge i tre vertici `Float32`, allargandoli
subito a `Double`; salta in modo controllato l'attributo finale. Dopo il caricamento esegue
`welded()` perché STL non conserva condivisione dei vertici.

Il parser ASCII segue `solid`, `facet normal`, `outer loop`, tre righe `vertex`, `endloop` ed
`endfacet`; accetta whitespace arbitrario e la mancanza di `endsolid`, ma rifiuta facet
incomplete. Anche questo risultato viene saldato.

Gli exporter STL emettono soltanto triangoli con indici validi, calcolano la normale dalla
geometria e usano zero per una faccia degenere. L'header binario è lungo esattamente 80 byte;
il conteggio corrisponde sempre ai record effettivamente scritti.

### PLY

Il parser legge l'header una riga alla volta fino a `end_header`, registrando nell'ordine:

- formato ASCII, binary little-endian o binary big-endian;
- elementi e relativi conteggi;
- proprietà scalari e proprietà lista, inclusi tipo del conteggio e tipo degli elementi.

Sono riconosciuti gli alias PLY standard `char/int8`, `uchar/uint8`, `short/int16`,
`ushort/uint16`, `int/int32`, `uint/uint32`, `float/float32` e `double/float64`. Le coordinate
sono ricavate dalle proprietà nominate `x`, `y`, `z`, indipendentemente dalla loro posizione.
Normali, colori e altre proprietà vengono consumati usando il tipo dichiarato e poi ignorati;
questa lettura guidata dall'header evita lo slittamento del cursore nei file binari.

La faccia usa la proprietà lista `vertex_indices` o `vertex_index`; in assenza di questi nomi
usa l'unica proprietà lista disponibile, mentre configurazioni ambigue sono malformate. I
poligoni vengono triangolati a ventaglio. Elementi non utilizzati vengono comunque consumati
secondo le loro proprietà.

### OBJ

Il parser è line-based. Legge `v` e `f`, rimuove commenti e ignora `vt`, `vn`, `mtllib`,
`usemtl`, `o`, `g` e `s`. Ogni riferimento faccia usa la parte precedente al primo `/`, così
sono supportati `i`, `i/j`, `i//k` e `i/j/k`. Gli indici positivi sono 1-based; quelli
negativi sono relativi al numero di vertici già letto; zero e riferimenti fuori range sono
malformati. I poligoni vengono triangolati a ventaglio.

## 5. Registrazione chiusa con Horn

`PointRegistration.align` verifica conteggi uguali, almeno tre coppie, coordinate finite e
configurazione non collineare. Coincidenza e collinearità vengono determinate confrontando i
prodotti vettoriali con la scala del set, non con una soglia assoluta in millimetri.

L'algoritmo:

1. calcola i centroidi;
2. centra le coppie;
3. costruisce la covarianza 3×3;
4. assembla la matrice simmetrica 4×4 di Horn;
5. trova l'autovettore dell'autovalore massimo mediante rotazioni Jacobi;
6. normalizza il quaternione e lo converte nelle colonne della rotazione;
7. calcola `centroidTarget − R × centroidSource`;
8. misura RMS ed errore massimo su tutte le coppie.

La doc comment spiega entrambe le ragioni richieste. Una SVD scritta localmente sarebbe molto
più ampia del necessario; soprattutto, Kabsch può produrre una riflessione. Un quaternione
unitario non può rappresentare una riflessione, quindi il determinante positivo deriva dalla
costruzione e non da una correzione successiva.

La soluzione chiusa restituisce `iterations == 0` e `converged == true`.

## 6. ICP trimmed con griglia spaziale

ICP è soltanto un affinamento locale e la doc comment richiede esplicitamente un'inizializzazione
già vicina, tipicamente fornita dalle coppie di punti. Non viene presentato come registrazione
globale.

Il target viene inserito una sola volta in una griglia hash con cella uguale a
`maxCorrespondenceDistanceMM`. Per ogni sorgente trasformata si visitano soltanto la cella
corrente e le 26 vicine; con quella dimensione ogni punto entro la distanza massima deve
trovarsi in una di esse. Il campione sorgente è deterministico e distribuito uniformemente
nell'array, fino a `sampleLimit` punti.

Target non finiti vengono saltati prima di calcolare la chiave della griglia. Anche una
sorgente trasformata non finita viene saltata prima della query. Se le guardie lasciano meno
di tre corrispondenze, si applica la normale regola `didNotConverge`; nessuna coordinata non
finita raggiunge mai una conversione a `Int`.

Ogni iterazione:

1. trasforma il campione con la trasformazione corrente;
2. trova il target più vicino entro la distanza massima;
3. ordina le corrispondenze per distanza con una closure dai tipi espliciti;
4. calcola per difetto la frazione da conservare e interrompe con `didNotConverge` se
   resterebbero meno di tre punti;
5. allinea i punti già trasformati ai target con `PointRegistration.align`;
6. compone `delta.concatenating(current)`;
7. calcola RMS ed errore massimo residui;
8. verifica convergenza e divergenza.

Trimmed ICP non è facoltativo: la scansione intraorale rappresenta soprattutto corone, mentre
la superficie CBCT contiene anche osso, tessuti e artefatti senza controparte. Il peggior quinto
trascinerebbe il fit fuori dai denti se non venisse scartato.

Se `PointRegistration.align` rileva che le corrispondenze superstiti sono collineari o
altrimenti degeneri, il suo `RegistrationError.degenerateConfiguration` viene propagato senza
essere riclassificato come `didNotConverge`. Una configurazione geometrica insolubile e una
divergenza iterativa sono fallimenti distinti e il chiamante deve poterli distinguere.

### Terminazione ICP

- Se l'RMS è già entro `toleranceMM`, oppure un miglioramento non negativo è inferiore alla
  tolleranza, il risultato ha `converged == true`.
- Raggiungere `maxIterations` è ordinario: restituisce la trasformazione, gli errori finali e
  `converged == false`.
- Se meno di tre corrispondenze sopravvivono a cutoff e trimming, viene lanciato
  `didNotConverge` con l'iterazione e l'ultimo RMS disponibile. Prima del primo fit si usa
  l'RMS dei residui superstiti; senza alcun residuo si usa `.infinity`.
- Se l'RMS aumenta per cinque iterazioni consecutive, viene lanciato `didNotConverge` con
  iterazione e RMS corrente. La serie di aumenti consecutivi si azzera alla prima iterazione
  in cui l'RMS non cresce.

Il campo `pointCount` del risultato ICP è il numero di corrispondenze conservate nell'ultima
iterazione, non il numero totale di vertici sorgente.

## 7. Maschera delle regioni

`RegionMask` conserva un flag di inclusione per vertice. L'inizializzazione parte con tutti i
vertici inclusi. Le operazioni sferiche confrontano distanze al quadrato e visitano soltanto
l'intersezione fra dimensione della maschera e array dei vertici. Indici fuori range risultano
non inclusi; raggi negativi o non finiti non modificano la maschera.

La doc comment chiarisce lo scopo clinico: corone e otturazioni metalliche sono la causa più
comune di registrazioni CBCT-scan errate. Il pennello della UI esclude quelle regioni e la
maschera registra tale selezione, senza conoscere la UI.

## 8. Errori

`MeshIOError` usa esattamente i casi pubblici richiesti. Ogni `localizedDescription` è in
italiano e include `name`. Offset e dettagli vengono aggiunti dove disponibili.

`RegistrationError` usa i casi richiesti. `didNotConverge` non rappresenta il semplice
raggiungimento del limite, ma soltanto un fit non risolvibile per carenza di corrispondenze o
una divergenza misurata da cinque aumenti consecutivi.

Le opzioni ICP non finite o fuori dominio (`maxIterations <= 0`, `toleranceMM < 0`, distanza
non positiva, `trimFraction` fuori `(0, 1]`, `sampleLimit < 3`) generano
`degenerateConfiguration` con dettaglio italiano.

## 9. Strategia di test

I test usano XCTest e helper test-only espliciti per comporre byte little/big-endian. Ogni
aspettativa geometrica è derivata a mano e non riusa l'algoritmo sotto test.

La suite copre almeno:

- round trip STL binario;
- header STL binario che inizia con `solid`;
- STL ASCII con whitespace irregolare e senza `endsolid`;
- PLY ASCII, binario little-endian e binario big-endian;
- proprietà binarie extra per vertice, inclusi colori;
- PLY con coordinata `NaN` rifiutato con `malformed` invece di raggiungere la griglia;
- OBJ con quattro forme di indice, indici negativi e quad triangolato;
- input troncati e conteggio STL corrotto enorme;
- welding, area, facce degeneri e trasformazione;
- mesh costruita in memoria con un vertice `NaN` che attraversa `welded()` senza trap;
- recupero di rotazione e traslazione note con RMS sotto `1e-9`;
- impossibilità di restituire una riflessione;
- rifiuto di punti collineari;
- ICP da perturbazione piccola con RMS sotto `0.01 mm`;
- trimmed ICP con il 30% di punti senza controparte;
- propagazione di `degenerateConfiguration` da corrispondenze ICP collineari;
- limite iterazioni che restituisce `converged == false`;
- carenza di corrispondenze e cinque aumenti consecutivi;
- esclusione e reinclusione con `RegionMask`.

Nessun file mesh di fixture viene aggiunto al repository. I test di `load(url:)`, se necessari,
scrivono byte generati in memoria in una directory temporanea e la rimuovono al termine.
