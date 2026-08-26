# CBCTMac — Architettura e contratti fondanti

Questo documento è **normativo**. Ogni modulo, ogni specifica passata a un assistente di
codifica e ogni revisione si misurano su quanto segue. I quattro contratti del capitolo 1 sono
le decisioni che, se sbagliate, non si correggono con una patch: costringono a riscrivere.

Prosa in italiano, identificatori e codice in inglese.

---

## 1. I cinque contratti

### Contratto 1 — Tre spazi di coordinate, una sola matrice

Esistono esattamente tre spazi. Non se ne inventano altri.

| Spazio | Unità | Descrizione |
|---|---|---|
| **Voxel** | indici | `(i, j, k)` — `i` colonna, `j` riga, `k` slice. Interi ai centri dei voxel. |
| **Patient** | **millimetri** | LPS standard DICOM: `+x` = Left, `+y` = Posterior, `+z` = Superior. |
| **World** | millimetri | Patient dopo il riorientamento utente (piano occlusale/Frankfort). |

`VolumeGeometry` è l'unico proprietario della conversione ed espone `voxelToPatient` e la sua
inversa `patientToVoxel`, entrambe di tipo `Transform3D` (affine in Double, definita in
`Sources/DICOMCore/Geometry.swift`). Non si usa `simd` in DICOMCore: è Float-centrico e
Apple-only, mentre qui servono Double per precisione e portabilità dei test. La discesa a
`simd_float4x4` avviene solo al confine con Metal, tramite `columnMajorFloat4x4()`.

**Regola inderogabile**: ogni annotazione, misura, tracciato nervoso, impianto e mesh è
memorizzato in **millimetri nello spazio Patient**. Mai in pixel, mai in coordinate schermo,
mai in indici voxel. È ciò che rende le misure invarianti a zoom, riorientamento,
ricampionamento e cambio di layout. Una misura salvata in pixel è una misura sbagliata appena
l'utente tocca lo zoom.

#### Costruzione della matrice (DICOM PS3.3 C.7.6.2.1.1)

Dati, dalla **prima slice dopo l'ordinamento**:

- `ImageOrientationPatient (0020,0037)` = `[Xx,Xy,Xz, Yx,Yy,Yz]`
  – `X` = coseni direttori lungo le **colonne crescenti** (`i`)
  – `Y` = coseni direttori lungo le **righe crescenti** (`j`)
- `ImagePositionPatient (0020,0032)` = `S`, centro del voxel `(0,0,0)`
- `PixelSpacing (0028,0030)` = `[Δrow, Δcol]`
- `N = normalize(X × Y)` — normale alla slice
- `Δk` = passo fra slice, ricavato dalle posizioni (§ Contratto 2)

```
                | Xx·Δcol   Yx·Δrow   Nx·Δk   Sx |
voxelToPatient= | Xy·Δcol   Yy·Δrow   Ny·Δk   Sy |     applicata a (i, j, k, 1)
                | Xz·Δcol   Yz·Δrow   Nz·Δk   Sz |
                | 0         0         0       1  |
```

> **Trappola da non sbagliare.** `PixelSpacing` è nell'ordine `[spaziatura fra righe,
> spaziatura fra colonne]`. La spaziatura fra righe è quella **verticale**, quindi va con `j`
> (vettore `Y`); quella fra colonne è **orizzontale** e va con `i` (vettore `X`). Invertirle
> non produce errori visibili su voxel isotropici — e le CBCT sono quasi sempre isotropiche —
> ma corrompe silenziosamente tutto il resto appena ne capita una che non lo è.

Su CBCT `X` e `Y` sono quasi sempre `[1,0,0]` e `[0,1,0]`, ma **non si assume**: si legge il tag.

#### Convenzione di visualizzazione

Convenzione radiologica: la destra del paziente sta a sinistra dello schermo.

| Vista | Asse orizzontale (→) | Asse verticale (↓) |
|---|---|---|
| Assiale | `+L` (`+x`) | `+P` (`+y`) |
| Coronale | `+L` (`+x`) | `+I` (`−z`) |
| Sagittale | `+P` (`+y`) | `+I` (`−z`) |

### Contratto 2 — Ordinamento delle slice per proiezione

**Non si ordina mai per `InstanceNumber` (0020,0013).** È inaffidabile, incoerente fra
produttori e su molte CBCT semplicemente assente.

Algoritmo:

1. `N = normalize(X × Y)` dai coseni direttori (identici per tutte le slice della serie;
   se differiscono di oltre `1e-4`, la serie non è un volume regolare → errore esplicito).
2. Per ogni slice, `d = dot(ImagePositionPatient, N)`.
3. Ordinare per `d` crescente.
4. `Δk = (d_last − d_first) / (nSlices − 1)`.
5. **Verificare l'uniformità**: se un qualsiasi `|d[n+1] − d[n] − Δk| > 0.01 mm`, non si
   ignora il problema — si popola `VolumeSpacingIssue` e la UI mostra un avviso. Un volume a
   spaziatura irregolare trattato come regolare produce misure sbagliate lungo l'asse `k`
   senza alcun segno visibile sull'immagine.
6. Slice duplicate (stesso `d` entro `1e-4`) vengono scartate con segnalazione.

`SliceThickness (0018,0050)` e `SpacingBetweenSlices (0018,0088)` si usano **solo come
riscontro** e per la diagnostica, mai come fonte di `Δk`: descrivono lo spessore del fascio,
non la distanza fra i centri ricostruiti.

### Contratto 3 — Doppia rappresentazione del volume

Il volume esiste in due copie con due scopi distinti, ed è sbagliato usarne una al posto
dell'altra.

**GPU — `MTLTextureType.type3D`, formato `.r16Unorm`, `storageModeShared`.**

Il vincolo di partenza è che il **filtraggio trilineare hardware non funziona sui formati
interi** (`.r16Sint` / `.r16Uint`). Senza di esso ogni MPR obliquo, il panorex e il raycasting
verrebbero a blocchi, oppure imporrebbero un'interpolazione manuale nello shader, molto più
lenta. Serve quindi un formato filtrabile.

`.r16Unorm` è quello giusto. Interi a 16 bit senza segno presentati allo shader come float in
[0, 1]: sedici bit pieni, **nessuna perdita di precisione**, filtraggio hardware disponibile.

`.r16Float` sarebbe la scelta sbagliata, e per un motivo non ovvio: `Float16` ha 11 bit di
mantissa, quindi rappresenta esattamente gli interi solo fino a 2048. Da lì in su compaiono
buchi — passo 2 fino a 4096, passo 4 fino a 8192 — e i valori CBCT cadono proprio in
quell'intervallo. Si perderebbero i bit bassi senza alcun segno visibile sull'immagine.

Conversione, esatta e reversibile: `Int16` → `UInt16` sommando 32768 in fase di upload; nello
shader si recupera il valore grezzo con `raw = sampled · 65535 − 32768`.

Su Apple Silicon `storageModeShared` sfrutta la memoria unificata: niente copia CPU→GPU.

**CPU — `[Int16]` grezzi, più `rescaleSlope` / `rescaleIntercept`.**
**Tutte le statistiche ROI si calcolano qui.** Leggere le statistiche dalla texture filtrata
restituisce valori interpolati: una media plausibile e sbagliata, un minimo e un massimo mai
realmente presenti nel dato. Per una misura di densità è inaccettabile.

Ordine di grandezza: una CBCT `640³` a 16 bit occupa ~520 MB per copia. Conseguenze pratiche:
- il 3D interattivo campiona una versione a metà risoluzione durante la rotazione e passa alla
  piena risoluzione al rilascio;
- il caricamento è streaming con progresso annullabile, mai un blocco monolitico;
- si evita accuratamente di duplicare il buffer CPU nei passaggi fra moduli (`UnsafeBufferPointer`,
  non `Array` per valore).

### Contratto 4 — Si scrive «GV», non «HU»

I valori delle CBCT **non sono unità Hounsfield**. La ricostruzione parte da dati di proiezione
incompleti, lo scattering è elevato e il valore dipende da apparecchio, FOV e posizione
nell'immagine. La correlazione con la TC multistrato è solo moderata e non trasferibile fra
macchine diverse.

Quindi:
- la UI etichetta ogni lettura di densità come **GV** (valore grigio), con tooltip esplicativo;
- l'identificatore nel codice è `greyValue`, mai `hounsfield` o `hu`;
- se `Modality` è `CT` **e** `RescaleIntercept` è `−1024` **e** la sorgente non è riconosciuta
  come CBCT, si può esporre «HU (dichiarati)» — con l'avvertenza che resta quanto dichiara il
  produttore, non una garanzia.

Un software che stampa «HU» su una CBCT sta dando al clinico un numero che sembra confrontabile
con la letteratura e non lo è.

---

### Contratto 5 — Nessun numero dichiara più precisione di quanta ne abbia

Il programma scriveva `12,47 mm`: due decimali sono dieci micrometri, su un volume campionato a
duecento. È precisione inventata di un fattore venti, e non è un problema estetico. Chi legge
`12,47` e poi `12,49` conclude che sono due misure diverse, mentre sono la stessa misura
ripetuta; e su una decisione implantare — «restano 1,8 mm sopra il canale» — la differenza fra un
numero e un numero **con la sua incertezza** è la differenza fra un dato e un'impressione.

**Il modello.** Per un'estremità posata a mano su una vista MPR concorrono due contributi
indipendenti, entrambi modellati come uniformi su una dimensione di voxel `s`:

1. *campionamento e volume parziale* — il contorno vero sta da qualche parte dentro il voxel che
   lo contiene: `s/√12`;
2. *localizzazione dell'operatore* — anche su un contorno osseo netto, due posature dello stesso
   punto differiscono dell'ordine di un voxel: `s/√12`.

Per estremità `σₚ = s·√(2/12)`; per una lunghezza fra due estremità indipendenti
`σ_L = √2·σₚ = s/√3 ≈ 0,58·s`. A 0,2 mm di voxel fa **0,12 mm**, che è l'ordine di grandezza
riportato in letteratura per l'accuratezza lineare delle CBCT dentali. Su volumi anisotropi
comanda l'asse peggiore, non la media: una misura obliqua ne raccoglie il contributo e quale
direzione avrà non si sa in anticipo.

**Come si scrive.** Regola metrologica: l'incertezza si arrotonda a una cifra significativa e il
valore si riporta alla stessa posizione decimale. A 0,2 mm di voxel si scrive `12,5 mm`, non
`12,47`.

**Lo slab non entra nel ±.** Sarebbe la cosa comoda e sarebbe sbagliata. Entrambe le estremità
stanno *sul piano* per costruzione, quindi la distanza misurata è una distanza nel piano ed è
esatta come tale. Ciò che una proiezione a massima intensità rende ignoto è **dove stiano** le due
strutture lungo la normale: la distanza vera è `√(L² + Δ²)`, quindi sempre **maggiore o uguale**
a quella misurata. È un limite inferiore, e va dichiarato come tale invece di essere sciolto in un
± che suggerirebbe simmetria. Lo stesso vale per una misura presa sulla panorex, che è una
distanza fra due punti della *superficie ricostruita* e non fra due strutture anatomiche.

Il contesto di acquisizione — voxel, spessore, tipo di proiezione, natura del volume — si
fotografa **al momento della posa** e viaggia con l'annotazione: chi assottiglia lo slab dopo aver
misurato non rende retroattivamente attendibile una misura presa su venti millimetri di
proiezione.

---

## 2. Moduli

Dipendenze solo verso il basso: nessun ciclo, nessun modulo conosce la UI.

```
App (SwiftUI)
 ├── VolumeKit ──── DICOMCore
 ├── MeasureKit ─── DICOMCore
 └── DICOMCore ──── DCMTKBridge (C++)
```

| Modulo | Responsabilità | Non fa |
|---|---|---|
| `DCMTKBridge` | Decodifica pixel per sintassi compresse | Nessuna logica applicativa |
| `DICOMCore` | Scansione, parsing tag, `VolumeGeometry`, `Volume` | Non tocca Metal né UI |
| `VolumeKit` | MPR, slab, raycasting, transfer function | Non conosce il DICOM |
| `MeasureKit` | Annotazioni, misure, statistiche ROI, `.cbctplan` | Non disegna |
| `App` | Viste, interazione, documento | Nessun algoritmo |

Fasi successive: `DentalKit` (panorex, sezioni, nervo), `ImplantKit`, `MeshKit`, `GuideKit`,
`SegmentKit`. Vedi il piano di progetto.

---

## 3. Regole trasversali

**Concorrenza.** Swift 6 strict concurrency. `Volume` è immutabile e `Sendable` una volta
costruito. Il caricamento gira su un attore dedicato; la UI resta `@MainActor`.

**Errori.** Niente `try!`, niente `fatalError` su dati d'ingresso: un DICOM malformato è
normale amministrazione, non un bug. Ogni fallimento di parsing indica il file e il tag.

**Precisione.** `Float` per il rendering, **`Double` per la geometria e le misure**. Un errore
di arrotondamento su una distanza implanto‑nervo non è accettabile. Conversione a `Float` solo
all'ingresso dello shader.

**Unità.** Ogni valore in millimetri porta il suffisso nel nome (`lengthMM`, `spacingMM`).
Gli angoli sono in radianti internamente, in gradi solo in UI.

**Pannelli.** Da ogni stato dell'interfaccia si deve poter tornare indietro, e nessun pannello
ne nasconde un altro. Tre regole lo tengono fermo, ciascuna con il suo controllo in `Tools/`:

- *Una modale per volta, e nessuna richiesta perduta.* La presentazione passa da `activeSheet` e
  da `ModalRouter`, non da un booleano per finestra: `.sheet(isPresented:)` impilati se ne
  perdono uno e lasciano l'interruttore acceso, e da lì in poi quel comando non apre più niente
  (`check-modal-routes.py`).
- *Ogni stato che si accende si spegne.* Un booleano del modello con un `= true` e nessun
  `= false` è un vicolo cieco: chi ci finisce dentro non ha un gesto per uscirne
  (`check-panel-exits.py`).
- *L'ispettore mostra elenchi, non catene di `else`.* Quali sezioni e quali contesti si vedano lo
  decide `InspectorSections`, in StudyKit, dove i test percorrono per intero le combinazioni di
  scheda, disposizione e riquadro a fuoco (`check-inspector-routes.py`).

Il difetto che le ha motivate tutte e tre si descriveva così: «se apro una cosa, poi non posso
più aprirne altre».

---

## 4. Uso previsto e limiti

Software **non certificato come dispositivo medico**, destinato a uso personale, di studio e di
ricerca. Non va usato per formulare diagnosi né per pianificare interventi su pazienti.

L'impalcatura predisposta in vista di un eventuale percorso normativo futuro
(MDR Classe IIa, Regola 11) comprende: banner permanente di uso non diagnostico, versione e
build impresse in ogni esportazione, log di sessione in sola aggiunta, requisiti numerati in
`docs/requirements/` richiamati dai test, analisi dei rischi in `docs/risk/`.

Una dima chirurgica stampata (Fase 5) è un **dispositivo su misura** ai sensi dell'Allegato XIII
MDR: gli obblighi ricadono su chi la produce e sono distinti da quelli del software.
