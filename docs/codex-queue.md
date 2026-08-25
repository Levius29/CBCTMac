# Coda dei lotti per Codex

Tutti i lotti rimanenti del [piano di lavoro](work-plan.md), in ordine, ciascuno pronto da
incollare. Uno per volta: ogni consegna viene compilata e verificata prima della successiva.

## Da incollare a mano non serve più

Questo documento è nato quando Codex, da dentro la sessione, non si raggiungeva: il token OAuth
in `CODEX_AUTH_JSON` era scaduto con il refresh già consumato, e il login interattivo vuole un
browser che qui non c'è. Da lì la modalità copia-e-incolla, e i blocchi delimitati da marcatori
perché fossero autosufficienti.

**Il 25 agosto 2026 la credenziale è stata rinnovata e Codex risponde direttamente.** Verificato
con una chiamata vera, non con il solo stato del login — che l'altra volta diceva «autenticato»
mentre ogni richiesta moriva con 401.

Resta una cosa da sapere: il contenitore è effimero, e `~/.codex/auth.json` non sopravvive a un
riavvio. La credenziale sì, perché sta nelle variabili d'ambiente. Per rimetterla:

```
mkdir -p ~/.codex && printenv CODEX_AUTH_JSON > ~/.codex/auth.json && chmod 600 ~/.codex/auth.json
```

Metterla nello script di avvio dell'ambiente la renderebbe automatica.

I blocchi qui sotto restano validi e restano autosufficienti: servono comunque a delimitare un
lotto per volta, che è la ragione vera per cui esistono. Cambia solo che non li si incolla più.

**Il messaggio da mandare, ogni volta:**

```
Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi docs/codex-queue.md, esegui SOLO il lotto <LETTERA> — il blocco fra i marcatori
▼ LOTTO <LETTERA> e ▲ FINE LOTTO <LETTERA> — e fermati.
```

Ordine: **D → E → F → O → L → M → N → J → H**.

L'ordine non è per peso. **E prima di F, O, J e H** perché tutti e cinque poggiano sul modello
degli oggetti, e rifarlo dopo costerebbe più di quanto renda anticiparlo. **H per ultimo** perché
le viste devono trovare i nuclei già pronti, così restano sottili — è la regola che governa tutto
il piano: ogni funzione si spezza in un nucleo verificabile e una vista sottile.

## Vincoli comuni a ogni lotto

Valgono per tutti, non si ripetono nei singoli blocchi:

- Swift 6, concorrenza stretta, tutti i tipi pubblici `Sendable`.
- Solo `Foundation` più i target del progetto già esistenti. **Niente `simd`, niente Metal,
  niente AppKit, niente SwiftUI**, nessuna dipendenza esterna, nessun C. Deve compilare su Linux.
- Niente `try!`, niente `fatalError`, niente force-unwrap. Ogni fallimento nomina la causa.
- Commenti di documentazione in **italiano**, identificatori in **inglese**. Il *perché* va scritto
  dove c'è una trappola.
- Aggiungere file ai target **esistenti** quando indicato; toccare `Package.swift` solo se il lotto
  lo chiede, e in quel caso **appendendo** alle costanti tipizzate già presenti — mai spostando i
  target dentro `Package(...)`, mai aggiungendo `swiftSettings`, mai cambiando la tools-version.
- Ogni lotto porta i propri test. Costruire i dati in memoria: nessun file di riferimento.

## Perché i test contano più del codice, qui

Nel tuo ambiente non c'è `swift`: non compili e non esegui. Lo hai dichiarato onestamente a ogni
consegna, ed è corretto. La verifica avviene dall'altra parte, dove la toolchain c'è, e i tuoi test
sono ciò che rende quella verifica utile invece che superficiale.

Un test che non può fallire è peggio di nessun test, perché dà fiducia senza fondamento. In una
consegna precedente una prova confrontava un salto con il **massimo** degli altri salti: bastava un
valore anomalo altrove perché l'asticella si alzasse abbastanza da far passare qualunque difetto.
Quando scrivi un test, chiediti quale mutazione del codice lo farebbe fallire; se non ne trovi
nessuna, il test non serve.

---

## ▼ LOTTO D — Geometria delle sovraimpressioni 3D

Aggiungi a `Sources/VolumeKit/` la geometria che serve a disegnare, nel riquadro 3D, le cornici dei
piani di taglio: il rettangolo del piano assiale, quelli di coronale e sagittale, la banda
dell'arcata, il riquadro di ritaglio. **Non** scrivere il disegno: quello è Metal e non è tuo.
Produci le coordinate schermo.

Nel riquadro 3D oggi c'è solo il volume: si vede l'anatomia ma non dove la stanno tagliando le
altre tre viste. Le cornici sono ciò che lega le quattro viste fra loro.

### Tipi esistenti da usare

```swift
// DICOMCore
public struct Vec3: Hashable, Sendable, Codable { /* x, y, z; +,-,*,/, dot, cross, length,
    lengthSquared, normalized -> Vec3?, distance(to:), lerp(to:t:), isFinite */ }
public struct VolumeGeometry { public var boundingBoxCornersMM: [Vec3]; public var centerMM: Vec3 }

// VolumeKit
public struct VolumeCamera: Hashable, Sendable {
    public var azimuth: Double        // radianti attorno all'asse verticale del paziente
    public var elevation: Double      // limitata a ±1,5 rad
    public var halfHeightMM: Double   // semi-altezza inquadrata: è lo zoom
    public var targetMM: Vec3
    public var forward: Vec3          // dalla camera verso il bersaglio
    public var right: Vec3            // destra dello schermo, in Patient
    public var down: Vec3             // basso dello schermo, in Patient
}
public struct MPRPlane: Hashable, Sendable {
    public var centerMM: Vec3, rightMM: Vec3, downMM: Vec3
    public var widthMM: Double, heightMM: Double
    public var normalMM: Vec3
    public var topLeftMM: Vec3
}
```

**La proiezione è ortografica**, e questo semplifica tutto: non c'è divisione per la profondità.
Un punto Patient `p` si proietta con

```
u = (p − target) · right / (halfHeight · aspetto)
v = (p − target) · down  / halfHeight
profondità = (p − target) · forward
```

dove `u` e `v` stanno in `[-1, 1]` al bordo del riquadro. La conversione in pixel è
`x = (u + 1)/2 · larghezza`, `y = (v + 1)/2 · altezza`.

### Deliverable 1 — `Sources/VolumeKit/ScreenProjection.swift`

```swift
/// Punto proiettato: pixel nel riquadro più la profondità con segno lungo la vista.
public struct ProjectedPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double
    /// Distanza con segno lungo `forward`. Serve a decidere cosa sta davanti a cosa.
    public let depthMM: Double
}

/// Segmento da disegnare, con l'indicazione se è nascosto dietro il volume.
public struct ScreenSegment: Hashable, Sendable {
    public let from: ProjectedPoint
    public let to: ProjectedPoint
    public let isHidden: Bool
}

public struct ScreenProjector: Hashable, Sendable {
    public init(camera: VolumeCamera, pixelWidth: Int, pixelHeight: Int)
    public func project(_ pointMM: Vec3) -> ProjectedPoint
    /// Inverso sul piano perpendicolare alla vista passante per il bersaglio.
    public func unproject(x: Double, y: Double) -> Vec3
}
```

> **L'aspetto va nella proiezione, non nel disegno.** `halfHeightMM` è una semi-**altezza**: la
> semi-larghezza vale `halfHeightMM · larghezza/altezza`. Dimenticarlo produce cornici che
> sembrano giuste su un riquadro quadrato e si allargano su uno panoramico, cioè il caso normale.
> Il modo di accorgersene è il test 1: proiettare e riproiettare deve dare l'identità **su un
> riquadro non quadrato**.

### Deliverable 2 — `Sources/VolumeKit/PlaneFrameGeometry.swift`

```swift
public enum PlaneFrameGeometry {
    /// Cornice di un piano MPR, **tagliata** contro il riquadro contenitore del volume.
    public static func outline(
        of plane: MPRPlane,
        clippedTo geometry: VolumeGeometry,
        projector: ScreenProjector
    ) -> [ScreenSegment]

    /// Spigoli del riquadro contenitore del volume.
    public static func boundingBoxEdges(
        of geometry: VolumeGeometry,
        projector: ScreenProjector
    ) -> [ScreenSegment]

    /// Riquadro di ritaglio arbitrario, dati i suoi otto vertici.
    public static func boxEdges(
        corners: [Vec3],
        projector: ScreenProjector
    ) -> [ScreenSegment]

    /// Banda dell'arcata: una striscia estrusa in verticale lungo una polilinea.
    ///
    /// Riceve i punti già campionati, così questo modulo non dipende da DentalKit.
    public static func ribbon(
        alongMM points: [Vec3],
        upAxis: Vec3,
        halfHeightMM: Double,
        projector: ScreenProjector
    ) -> [ScreenSegment]
}
```

> **Il taglio contro il volume non è opzionale.** Un piano MPR è più largo del volume quasi sempre:
> disegnarne la cornice intera produce un rettangolo che galleggia nel vuoto attorno all'anatomia e
> non dice più dove taglia. Taglia il rettangolo contro il parallelepipedo del volume — è un
> ritaglio di poligono convesso contro sei semispazi, e Sutherland–Hodgman lo risolve in poche
> righe. Il risultato è un poligono con da tre a sei lati, non necessariamente un rettangolo.
>
> **Il caso degenere è il piano visto di taglio.** Quando la normale del piano è perpendicolare
> alla direzione di vista, la cornice si proietta su un segmento. Non è un errore e non va evitato:
> va restituito il segmento. Ciò che non deve accadere è una divisione per zero o un `NaN` che si
> propaga nei pixel — che poi nel disegno diventa una riga che attraversa lo schermo.
>
> **`isHidden` si decide con la profondità, non con l'orientamento.** Un lato è nascosto se il suo
> punto medio sta oltre la superficie del volume lungo la vista. Il criterio della faccia rivolta
> all'indietro funziona per un solido chiuso e qui non c'è nessun solido: c'è un rettangolo dentro
> una scatola. Per approssimarlo basta confrontare la profondità del punto medio con quella del
> centro del volume: dichiara nel commento che è un'approssimazione e perché è accettabile.

### Deliverable 3 — Test in `Tests/VolumeKitTests/`

1. **Proiezione e inversa sono l'identità su un riquadro non quadrato** — 1280×720. Con l'aspetto
   dimenticato questo test fallisce e su un riquadro quadrato no: è la ragione per cui specifica
   le dimensioni.
2. Il centro del volume si proietta al centro del riquadro, per almeno cinque coppie
   rotazione/elevazione diverse.
3. Un piano più grande del volume viene tagliato: il poligono risultante sta dentro la proiezione
   del riquadro contenitore, e il suo perimetro è minore di quello del rettangolo intero.
4. Un piano interamente dentro il volume non viene tagliato: quattro lati, e i vertici coincidono
   con quelli proiettati del rettangolo.
5. Un piano che non interseca affatto il volume produce **zero** segmenti, non un poligono vuoto
   con vertici a `NaN`.
6. **Il piano visto di taglio** produce segmenti finiti: nessuna coordinata `NaN` o infinita.
   Costruisci il caso mettendo la normale del piano perpendicolare a `forward`.
7. Gli spigoli del riquadro contenitore sono dodici, e a rotazione ed elevazione nulle esattamente
   quattro risultano nascosti.
8. La banda dell'arcata su una polilinea di *n* punti produce il numero atteso di segmenti, e a
   `halfHeightMM` nullo degenera nella sola polilinea invece di produrre lati di lunghezza zero.

## ▲ FINE LOTTO D

---

## ▼ LOTTO E — Modello degli oggetti del piano

Oggi impianti, canali nervosi, curve d'arcata e annotazioni vivono in quattro elenchi separati con
regole diverse: alcuni hanno un colore, altri no; nessuno ha visibilità, blocco o nome. Serve un
modello unico, perché l'interfaccia che li elenca — con occhio, colore e cestino — deve poterli
trattare allo stesso modo.

Aggiungi a `Sources/MeasureKit/`.

### Deliverable 1 — `Sources/MeasureKit/PlanObject.swift`

```swift
/// Che cosa è un oggetto del piano. Determina l'icona e il pannello contestuale.
public enum PlanObjectKind: String, Hashable, Sendable, Codable, CaseIterable {
    case implant
    case nerveCanal
    case archCurve
    case annotation
    case mesh
    case guideDesign
}

/// Attributi comuni a ogni oggetto del piano, indipendenti dal suo contenuto.
///
/// Deliberatamente **non** contiene la geometria: quella resta nei tipi specifici, in ImplantKit,
/// DentalKit e qui. Questo è ciò che l'elenco degli oggetti deve sapere per mostrarli, e tenerlo
/// separato evita che MeasureKit debba dipendere da ogni modulo che definisce un oggetto.
public struct PlanObjectInfo: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var kind: PlanObjectKind
    public var name: String
    public var isVisible: Bool
    public var isLocked: Bool
    /// Colore in esadecimale `RRGGBB`, senza cancelletto.
    public var colorHex: String
    /// Nota libera dell'utente.
    public var note: String
    /// Posizione nell'elenco, dentro il proprio tipo.
    public var order: Int

    public init(id: UUID, kind: PlanObjectKind, name: String, order: Int)
}

/// Registro degli oggetti del piano.
public struct PlanObjectRegistry: Hashable, Sendable, Codable {
    public init()
    public private(set) var objects: [PlanObjectInfo]

    public mutating func register(_ info: PlanObjectInfo)
    public mutating func remove(id: UUID)
    public mutating func removeAll(of kind: PlanObjectKind)
    public subscript(id: UUID) -> PlanObjectInfo? { get set }

    public func objects(of kind: PlanObjectKind) -> [PlanObjectInfo]
    public func isVisible(_ id: UUID) -> Bool
    public mutating func setVisible(_ visible: Bool, id: UUID)
    public mutating func setLocked(_ locked: Bool, id: UUID)
    public mutating func rename(_ name: String, id: UUID)
    public mutating func move(id: UUID, toOrder: Int)

    /// Nome proposto per un oggetto nuovo: «Impianto 3», «Canale destro 1»…
    public func suggestedName(for kind: PlanObjectKind) -> String
    /// Colore proposto, scelto da una tavolozza in modo che due oggetti vicini differiscano.
    public func suggestedColorHex(for kind: PlanObjectKind) -> String
}
```

> **Un oggetto sconosciuto è visibile.** `isVisible(_:)` su un identificatore non registrato deve
> restituire `true`, non `false`. La ragione è pratica: la registrazione avviene in un punto e il
> disegno in un altro, e se il disegno arriva prima l'oggetto sparisce senza che nessuno capisca
> perché. Con il valore prudente al più compare qualcosa che si poteva nascondere; con l'altro
> sparisce qualcosa che c'è.
>
> **`suggestedColorHex` deve essere deterministico e non ripetersi fra vicini.** Un colore casuale
> cambia a ogni riapertura del piano, e due impianti adiacenti dello stesso colore rendono inutile
> il colore. Prendi da una tavolozza fissa scorrendola in ordine, saltando quelli già usati nello
> stesso tipo.

### Deliverable 2 — Migrazione di `.cbctplan`

Il formato attuale è in `Sources/MeasureKit/PlanDocument.swift`: **leggilo prima**. Aggiungi il
registro al documento alzando la versione del formato.

> **Un piano salvato oggi deve continuare ad aprirsi.** Se il registro manca, va ricostruito dagli
> oggetti presenti, con nomi proposti, visibili e sbloccati. Un documento di versione **futura**
> va rifiutato con un errore che nomina le due versioni — mai aperto a metà, perché aprire a metà
> e poi salvare cancella in silenzio ciò che non si è saputo leggere. Il rifiuto esplicito è la
> differenza fra un fastidio e una perdita di dati.

### Deliverable 3 — Test

1. Registrazione, rinomina, visibilità, blocco, rimozione, rimozione per tipo.
2. **Un identificatore sconosciuto risulta visibile**, non nascosto.
3. `suggestedName` non produce due volte lo stesso nome nello stesso tipo, nemmeno dopo aver
   cancellato un oggetto in mezzo.
4. `suggestedColorHex` è deterministico — due chiamate sullo stesso stato danno lo stesso colore —
   e non ripete un colore già in uso nello stesso tipo finché la tavolozza non è esaurita.
5. `move(id:toOrder:)` produce un ordinamento senza buchi né duplicati, verificato confrontando
   l'insieme degli ordini con `0..<n`.
6. **Andata e ritorno** del documento con il registro: codifica, decodifica, confronto.
7. **Migrazione**: un documento nella versione precedente, scritto a mano nel test come JSON, si
   apre e produce un registro coerente con gli oggetti presenti.
8. Un documento con versione futura viene **rifiutato** con l'errore nominato.

## ▲ FINE LOTTO E

---

## ▼ LOTTO F — Collocazione delle etichette

Le etichette degli impianti — `Ø 3,85 · L 8,00` e simili — vanno mostrate accanto all'oggetto senza
coprire l'anatomia e senza sovrapporsi fra loro, collegate all'ancora da una linea di richiamo.

Non è grafica: è un problema di collocazione, e si risolve e si verifica per intero senza disegnare
nulla. Aggiungi a `Sources/MeasureKit/`.

### Deliverable — `Sources/MeasureKit/LabelLayout.swift`

```swift
public struct LabelRequest: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Punto a cui l'etichetta si riferisce, in pixel del riquadro.
    public var anchorX: Double
    public var anchorY: Double
    public var width: Double
    public var height: Double
    /// Priorità: a parità di spazio vince la più alta. L'oggetto selezionato ha priorità massima.
    public var priority: Int
}

public struct PlacedLabel: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Angolo alto-sinistro dell'etichetta collocata.
    public let x: Double
    public let y: Double
    /// Punto da cui parte la linea di richiamo, sul bordo dell'etichetta.
    public let leaderX: Double
    public let leaderY: Double
    /// Falso quando non c'è stato posto: chi disegna la omette invece di sovrapporla.
    public let isPlaced: Bool
}

public enum LabelLayout {
    public static func place(
        _ requests: [LabelRequest],
        inWidth width: Double,
        height: Double,
        marginPoints: Double = 4
    ) -> [PlacedLabel]
}
```

Regole: nessuna etichetta esce dal riquadro; nessuna si sovrappone a un'altra; ognuna sta il più
vicino possibile alla propria ancora; la linea di richiamo parte dal lato dell'etichetta rivolto
verso l'ancora.

> **La proprietà che conta più di tutte è la stabilità.** Le ancore si muovono in continuazione —
> si scorre una fetta, si ruota il 3D — e un algoritmo che ricolloca tutto da capo a ogni
> fotogramma produce etichette che saltano. Saltare è peggio che sovrapporsi: l'occhio insegue il
> movimento e non riesce a leggere.
>
> Rendilo stabile per costruzione: colloca in ordine di priorità e, a parità, di identificatore —
> **mai** nell'ordine in cui arrivano — e prova le posizioni candidate sempre nella stessa sequenza
> attorno all'ancora. Uno spostamento piccolo dell'ancora deve produrre uno spostamento piccolo
> dell'etichetta. È il test 4, ed è quello che decide se il lotto è fatto bene.
>
> **Dichiarare «non collocata» è un risultato legittimo.** Con venti etichette in un riquadro
> piccolo non c'è posto per tutte, e sovrapporle è il peggiore degli esiti: illeggibili tutte
> invece che alcune. Chi disegna omette quelle con `isPlaced == false`.

### Test

1. Nessuna etichetta esce dal riquadro, su un centinaio di ancore casuali con seme fisso.
2. Nessuna coppia di etichette collocate si sovrappone.
3. A parità di condizioni, la priorità più alta viene collocata per prima e più vicino all'ancora.
4. **Stabilità**: spostando un'ancora di un pixel, nessuna etichetta si sposta di più di pochi
   pixel. Confronta le due collocazioni, non due esecuzioni identiche.
5. **Determinismo**: lo stesso ingresso in ordine mescolato produce la stessa uscita.
6. Con più etichette dello spazio disponibile, alcune risultano non collocate e **nessuna**
   sovrapposta.
7. Un'ancora sul bordo produce un'etichetta dentro il riquadro, dal lato che ha posto.
8. Il punto di partenza del richiamo sta sul bordo dell'etichetta, dal lato dell'ancora.

## ▲ FINE LOTTO F

---

## ▼ LOTTO O — Annulla e ripeti

È l'unica voce del catalogo che non compare in nessuna schermata: si nota solo quando manca.
Aggiungi a `Sources/MeasureKit/`.

### Deliverable — `Sources/MeasureKit/UndoHistory.swift`

```swift
/// Cronologia a istantanee di un valore.
///
/// A istantanee e non a comandi inversi: il documento di piano è piccolo — annotazioni, impianti,
/// curve, qualche decina di kilobyte — e una pila di comandi con il proprio inverso raddoppia il
/// codice da scrivere e da mantenere per ogni operazione nuova. Con le istantanee un'operazione
/// nuova non richiede nulla.
public struct UndoHistory<Value: Equatable & Sendable>: Sendable {
    public init(initial: Value, limit: Int = 64)

    public private(set) var current: Value
    public var canUndo: Bool { get }
    public var canRedo: Bool { get }

    /// Registra uno stato nuovo. Stati uguali al corrente non producono un passo.
    public mutating func commit(_ value: Value, label: String)
    /// Aggiorna l'ultimo passo invece di crearne uno nuovo, se ha la stessa etichetta e
    /// l'ultimo aggiornamento è recente.
    public mutating func coalesce(_ value: Value, label: String, within seconds: TimeInterval)

    @discardableResult public mutating func undo() -> Value?
    @discardableResult public mutating func redo() -> Value?

    public var undoLabel: String? { get }
    public var redoLabel: String? { get }
}
```

> **Il raggruppamento è la parte che rende utile la funzione.** Trascinando un impianto si
> producono centinaia di stati intermedi: senza raggrupparli, annullare richiede duecento
> pressioni per disfare un gesto solo, e la cronologia si riempie di rumore fino a espellere le
> operazioni che contavano. `coalesce` aggiorna l'ultimo passo quando l'etichetta coincide e
> l'ultimo aggiornamento è recente, così un trascinamento intero è **un** passo.
>
> **Registrare uno stato nuovo cancella la coda del ripeti.** È il comportamento atteso ovunque, e
> ometterlo produce un «ripeti» che riporta a uno stato incompatibile con quello corrente — cioè
> corrompe il documento invece di ripristinarlo.
>
> **Il limite si applica dalla coda, non dalla testa.** Superati i passi consentiti si scarta il
> **più vecchio**. Scartare il più recente sembra equivalente e non lo è: renderebbe «annulla»
> inefficace proprio sull'ultima cosa fatta.

### Test

1. Annulla e ripeti percorrono la cronologia in entrambi i versi, con i valori giusti.
2. Uno stato uguale al corrente non produce un passo.
3. Registrare dopo un annulla **cancella** la coda del ripeti.
4. `coalesce` con la stessa etichetta entro la finestra aggiorna l'ultimo passo: cento chiamate
   producono un passo solo, e annullare una volta riporta allo stato di partenza.
5. `coalesce` con etichetta diversa, o fuori dalla finestra, crea un passo nuovo.
6. Superato il limite si scarta il **più vecchio**: dopo `limit + 10` registrazioni la cronologia
   ha `limit` passi e il più recente è ancora raggiungibile.
7. Le etichette di annulla e ripeti sono quelle attese in ogni punto della cronologia.
8. Annulla su una cronologia vuota restituisce `nil` senza alterare nulla.

## ▲ FINE LOTTO O

---

## ▼ LOTTO L — Varianti di misura

`MeasureKit` misura distanze fra due punti e angoli fra tre. Nei visori commerciali il righello ha
varianti, e servono davvero: la lunghezza di una cresta non è un segmento, e l'angolo fra due
impianti non si misura con tre punti.

Aggiungi a `Sources/MeasureKit/`, riusando i tipi di `Annotation.swift` — **leggilo prima**.

### Deliverable

```swift
/// Spezzata: somma dei segmenti. Chiusa, misura anche l'area del poligono.
public struct PolylineMeasurement: Hashable, Sendable, Codable, Identifiable {
    public var pointsMM: [Vec3]
    public var isClosed: Bool
    public var lengthMM: Double { get }
    /// Area in mm², solo se chiusa e **complanare** entro una tolleranza. `nil` altrimenti.
    public var areaMM2: Double? { get }
}

/// Angolo fra due rette definite da due punti ciascuna, invece che da un vertice comune.
public struct LineAngleMeasurement: Hashable, Sendable, Codable, Identifiable {
    public var firstStartMM: Vec3, firstEndMM: Vec3
    public var secondStartMM: Vec3, secondEndMM: Vec3
    /// Angolo acuto fra le due direzioni, in gradi, in `0...90`.
    public var acuteDegrees: Double { get }
    /// Distanza minima fra le due rette. Zero se si intersecano.
    public var minimumDistanceMM: Double { get }
}
```

> **L'area di un poligono nello spazio richiede la complanarità.** Tre punti sono sempre
> complanari, quattro quasi mai. La formula del laccio di scarpe vale nel piano, e applicarla a
> punti sghembi restituisce un numero che sembra un'area e non lo è. Verifica la complanarità
> contro il piano ai minimi quadrati dei punti e restituisci `nil` oltre la tolleranza, invece di
> un valore plausibile e falso.
>
> **L'angolo fra due rette è quello acuto.** Due rette formano due angoli supplementari, e quale
> dei due si ottiene dipende dal verso in cui l'utente ha tracciato i segmenti — cioè da nulla di
> significativo. Restituire sempre l'acuto rende la misura riproducibile. Dichiaralo nel commento,
> perché è una scelta e non un'ovvietà.
>
> **La distanza minima fra due rette sghembe** ha una formula chiusa che degenera quando sono
> parallele: il prodotto vettoriale delle direzioni si annulla. Tratta quel caso a parte,
> restituendo la distanza punto-retta.

### Test

1. Lunghezza di una spezzata nota, aperta e chiusa, calcolata a mano.
2. Area di un quadrato da 10 mm nel piano assiale: 100 mm² esatti; in un piano **obliquo**: sempre
   100 mm², perché l'area non dipende da come il quadrato è orientato nello spazio.
3. Quattro punti **sghembi** producono `areaMM2 == nil`.
4. Una spezzata aperta produce `areaMM2 == nil` anche se complanare.
5. Angolo fra due rette a 30° noto per costruzione, con i quattro versi possibili dei due
   segmenti: **sempre 30°**, mai 150°.
6. Due rette parallele: angolo nullo e distanza pari alla loro separazione.
7. Due rette incidenti: distanza nulla entro 1e-9.
8. Due rette sghembe con distanza nota per costruzione.

## ▲ FINE LOTTO L

---

## ▼ LOTTO M — Oggetti protesici e pianificazione guidata dalla protesi

In coDiagnostiX si posiziona **prima il dente protesico e poi l'impianto sotto di esso**. È
l'ordine clinicamente corretto — l'impianto serve la protesi, non il contrario — e da noi manca.

Aggiungi a `Sources/ImplantKit/`. Leggi prima `Implant.swift`.

### Deliverable

```swift
/// Dente protesico parametrico, come sagoma di riferimento.
///
/// Geometria generica e non da catalogo: le forme dei denti dei produttori sono materiale
/// protetto, e per pianificare serve l'ingombro, non la fedeltà estetica.
public struct ProstheticTooth: Hashable, Sendable, Codable, Identifiable {
    public var toothNumber: Int          // notazione FDI: 11…48
    public var positionMM: Vec3          // centro della corona
    public var axisMM: Vec3              // dall'occlusale verso l'apice
    public var widthMM: Double
    public var heightMM: Double
    public var depthMM: Double
    public static func standard(forToothNumber: Int) -> ProstheticTooth
}

/// Vincolo fra un dente protesico e l'impianto che lo sostiene.
public struct ProstheticConstraint: Hashable, Sendable {
    public let toothAxisMM: Vec3
    public let implantAxisMM: Vec3
    /// Angolo fra i due assi, in gradi.
    public var divergenceDegrees: Double { get }
    /// Punto in cui l'asse dell'impianto, prolungato, incontra il piano occlusale del dente.
    public var emergenceMM: Vec3? { get }
    /// Scostamento fra l'emergenza e il centro della corona, in millimetri.
    public var emergenceOffsetMM: Double? { get }
    public var severity: ConstraintSeverity { get }
}

public enum ConstraintSeverity: Hashable, Sendable, Codable {
    case acceptable
    case caution
    case unacceptable
}
```

Le soglie: fino a 15° accettabile, fino a 25° attenzione, oltre inaccettabile — sono le soglie
comunemente citate per un moncone angolato. Rendile parametri con quei valori predefiniti, e
**dichiara nel commento che sono orientative e non una regola clinica**.

> **L'emergenza è il numero che conta più della divergenza.** Un impianto può essere molto
> divergente e restare protesicamente corretto se emerge nel punto giusto; e può essere quasi
> parallelo ed emergere fuori dalla corona, che è inservibile. Calcola l'intersezione fra l'asse
> prolungato e il piano occlusale, e restituisci `nil` quando l'asse è parallelo a quel piano
> invece di produrre un punto all'infinito.
>
> **Numerazione FDI, non progressiva.** I denti si chiamano 11–18, 21–28, 31–38, 41–48: il primo
> numero è il quadrante. Rifiuta i numeri che non appartengono a quegli intervalli invece di
> accettarli e collocare un dente in un quadrante inesistente.

### Test

1. `standard(forToothNumber:)` produce misure plausibili e diverse per un incisivo, un canino, un
   premolare e un molare — l'incisivo più stretto e più alto del molare.
2. I numeri FDI non validi — 0, 19, 29, 49, 50 — vengono rifiutati.
3. Divergenza nulla per assi paralleli, e valori noti per angoli costruiti a mano.
4. Le tre soglie di gravità scattano ai valori attesi, verificate anche appena sopra e appena sotto.
5. L'emergenza cade nel centro della corona per un impianto perfettamente allineato.
6. Un asse **parallelo** al piano occlusale produce `emergenceMM == nil`, non un punto lontanissimo.
7. Lo scostamento dell'emergenza cresce come atteso inclinando l'impianto di angoli noti.

## ▲ FINE LOTTO M

---

## ▼ LOTTO N — Riorientamento del volume e curva proposta

Due automatismi. Il primo pesa più di quanto sembri: nessuno se ne accorge finché non apre una CBCT
con la testa inclinata, cioè quasi sempre.

Aggiungi a `Sources/SegmentKit/`.

### Deliverable 1 — `Sources/SegmentKit/VolumeReorientation.swift`

```swift
/// Riorientamento del volume su un piano di riferimento.
public struct ReorientationPlan: Hashable, Sendable, Codable {
    /// Tre punti che definiscono il piano occlusale, in mm Patient.
    public var referencePointsMM: [Vec3]
    /// Rotazione che porta quel piano orizzontale.
    public func rotation() -> Transform3D?
    public func validate() -> [String]
}

public enum VolumeReorientation {
    /// Produce un volume nuovo, ricampionato secondo la rotazione.
    public static func reoriented(
        _ volume: Volume,
        plan: ReorientationPlan,
        spacingMM: Double
    ) throws -> Volume
}
```

> **La trappola qui è la stessa del ricampionamento, ed è più insidiosa.** Ruotare un volume
> significa produrre una geometria nuova con **direzioni di riga e colonna ruotate**, e le
> annotazioni salvate in mm Patient devono continuare a riferirsi agli stessi punti anatomici. Ci
> sono due strade e vanno distinte con chiarezza nel commento:
>
> - ruotare i **dati**, lasciando invariate le coordinate Patient: l'anatomia si raddrizza a
>   schermo e ogni punto Patient continua a indicare lo stesso tessuto. È ciò che serve.
> - ruotare il **sistema di riferimento**: l'immagine è identica e tutte le coordinate cambiano,
>   il che invalida ogni annotazione esistente.
>
> Fai la prima. Il test 2 la distingue dalla seconda, ed è la ragione per cui esiste.
>
> **Tre punti definiscono un piano solo se non sono allineati.** Verificalo e rifiuta con un errore
> nominato: tre punti quasi allineati producono una normale quasi nulla e una rotazione arbitraria,
> cioè un volume ruotato a caso.

### Deliverable 2 — `Sources/SegmentKit/ArchDetection.swift`

```swift
public enum ArchDetection {
    /// Punti di controllo proposti per la curva d'arcata, ricavati dall'anatomia.
    ///
    /// Restituisce `nil` quando l'immagine non contiene un'arcata riconoscibile, invece di una
    /// curva qualunque: una curva sbagliata proposta con sicurezza è peggio di nessuna proposta.
    public static func suggestArchPoints(
        in volume: Volume,
        atVerticalMM: Double,
        thresholdGV: Double?,
        pointCount: Int
    ) -> [Vec3]?
}
```

Metodo suggerito: soglia sull'osso alla quota indicata, componente connessa maggiore, e adattamento
di una parabola ai suoi punti in coordinate polari attorno al baricentro. Dichiara nel commento il
metodo scelto e che è euristico.

> **Deve poter dire di no.** Su una CBCT parziale, su un'arcata edentula o su una fetta presa
> troppo in alto non c'è un'arcata da trovare. Restituire comunque una parabola produce
> esattamente la situazione che questo progetto ha già attraversato una volta: una curva imposta
> che non somiglia all'anatomia, e un utente convinto che il programma faccia di testa propria.
> Un criterio di rifiuto esplicito — pochi voxel oltre soglia, componente troppo piccola, residuo
> dell'adattamento troppo alto — vale più della qualità della proposta.

### Test

1. La rotazione porta la normale del piano di riferimento sull'asse verticale, entro 1e-9.
2. **Le coordinate Patient conservano il significato**: un punto anatomico noto — il centro del cubo
   del fantoccio — ha la stessa densità prima e dopo il riorientamento, allo stesso punto Patient.
   Con il sistema di riferimento ruotato invece che i dati, questo test fallisce.
3. Tre punti allineati vengono rifiutati con un errore nominato.
4. Un piano già orizzontale produce una rotazione identità entro 1e-12.
5. Su un fantoccio con un'arcata sintetica — un arco di corticale che costruisci nel test —
   `suggestArchPoints` produce punti che stanno sull'arco entro pochi millimetri.
6. Su un volume di solo tessuto molle restituisce `nil`.
7. Su un volume vuoto restituisce `nil` senza andare in errore.

## ▲ FINE LOTTO N

---

## ▼ LOTTO J — Relazione ed esportazione

La scheda «Rivedi» dei visori commerciali produce una relazione impaginata con immagini, misure e
dati del caso. Serve il **modello** della relazione e la sua impaginazione; il disegno delle
immagini resta fuori da questo lotto.

Aggiungi a `Sources/MeasureKit/`.

### Deliverable — `Sources/MeasureKit/ReportModel.swift`

```swift
public struct ReportSection: Hashable, Sendable, Codable, Identifiable {
    public enum Content: Hashable, Sendable, Codable {
        case heading(String)
        case paragraph(String)
        case measurementTable([ReportRow])
        case imagePlaceholder(caption: String, aspectRatio: Double)
        case pageBreak
    }
    public let id: UUID
    public var content: Content
}

public struct ReportRow: Hashable, Sendable, Codable {
    public var label: String
    public var value: String
    public var unit: String
}

public struct ReportDocument: Hashable, Sendable, Codable {
    public var title: String
    public var patientReference: String
    public var date: Date
    public var sections: [ReportSection]
    /// Avvertenza obbligatoria, non rimovibile.
    public var disclaimer: String { get }
    public func paginated(linesPerPage: Int) -> [[ReportSection]]
}
```

> **L'avvertenza non deve essere rimovibile.** Ogni pagina esportata da questo programma può
> finire in una cartella clinica, e deve dire che il software non è certificato come dispositivo
> medico e che l'uso non è diagnostico. Rendila una proprietà **calcolata**, non un campo
> modificabile: un campo si svuota, una proprietà calcolata no.
>
> **Le unità restano quelle del volume.** Se il volume porta valori grigi, la relazione scrive
> `GV`, mai `HU`. Vedi il Contratto 4 in `docs/architecture.md`. Il campo `unit` esiste proprio
> per non lasciare che qualcuno lo scriva a mano nella stringa del valore.
>
> **L'impaginazione non spezza una tabella lasciando l'intestazione sola** in fondo a una pagina.
> È il difetto classico dell'impaginazione ingenua, e su una relazione clinica produce una pagina
> che finisce con un titolo e nient'altro.

### Test

1. L'avvertenza è presente e non si può svuotare.
2. L'impaginazione rispetta il numero di righe per pagina.
3. Un'intestazione non resta sola in fondo a una pagina: se la tabella che segue non ci sta,
   scendono insieme.
4. Un'interruzione di pagina esplicita è rispettata.
5. Andata e ritorno della codifica.
6. Una relazione vuota produce una pagina sola con la sola avvertenza, non zero pagine.

## ▲ FINE LOTTO J

---

## ▼ LOTTO H — Viste SwiftUI

**Da eseguire per ultimo**, quando i nuclei dei lotti precedenti esistono già.

Questo lotto è l'unico in cui l'esclusione di SwiftUI non vale: qui si scrivono viste. Vale però
il suo corollario, e va preso alla lettera: **una vista che calcola è una vista scritta male**.
Ogni valore che compare a schermo deve venire da un tipo dei moduli, e la vista deve limitarsi a
leggerlo e disporlo. È ciò che rende verificabile un lotto che nessuno può compilare prima del Mac.

Il dettaglio delle viste da scrivere sta in `docs/work-plan.md` § 2, voci A1, A2, A4, A7, B12, B13,
I3, I7, K2, K3, K6, e nel file `docs/cs3d-teardown.md` che descrive come sono fatte nell'originale.

Il brief completo verrà scritto quando i lotti precedenti saranno integrati, perché le firme dei
nuclei che queste viste useranno non esistono ancora e citarle adesso significherebbe inventarle.

## ▲ FINE LOTTO H
