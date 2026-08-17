# Brief per Codex — SegmentKit: ritaglio, soglie, maschere

Quinto lotto, ed è il collo di bottiglia di metà lavoro rimanente. Senza una maschera non si isola
il metallo per correggerne gli artefatti, non si scelgono i supporti di una dima, e non c'è nulla
con cui addestrare o valutare un modello. Vedi `docs/competitive-analysis.md` § 7.

**Il fatto strutturale da cui derivano tutte le decisioni.** Una CBCT dentale a 0,15 mm su un FOV
da 16 cm sono circa 10⁹ voxel; anche una da 0,3 mm su 8 cm sono 10⁷. Ogni operazione qui è O(voxel),
quindi ciò che si fa una volta per voxel va fatto bene e ciò che si può fare una volta sola per
*volume* non va fatto per voxel. Il punto più importante del brief è di questa natura, ed è la nota
sulle soglie al Deliverable 3.

Se Codex ha accesso alla repo, premetti:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi Sources/DICOMCore/Volume.swift, VolumeGeometry.swift e docs/architecture.md prima di
iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT planning application.
Your task: implement **SegmentKit** — volume cropping, threshold and region-growing segmentation,
morphology, connected components, and mask statistics. Do not write any other part of the app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **Only `Foundation`**, plus the existing `DICOMCore` target. No `simd`, no Metal, no AppKit, no
  third-party dependencies, no C interop. Compiles and tests on Linux.
- No `try!`, no `fatalError`, no force-unwraps. Every failure names what went wrong.
- **No recursion over voxels.** See the trap at Deliverable 4.
- Doc comments in **Italian**, identifiers in **English**. Explain *why* at the traps below.

### Existing types you must use — do not redefine

```swift
// DICOMCore
public struct Vec3: Hashable, Sendable, Codable { /* x, y, z; +,-,*,/, dot, cross, length,
    normalized -> Vec3?, distance(to:), isFinite, isApproximatelyEqual(to:tolerance:) */ }

public struct VolumeGeometry: Hashable, Sendable, Codable {
    public init(columnCount: Int, rowCount: Int, sliceCount: Int,
                columnSpacingMM: Double, rowSpacingMM: Double, sliceSpacingMM: Double,
                orientation: SliceOrientation, originMM: Vec3) throws
    public let columnCount: Int, rowCount: Int, sliceCount: Int
    public let columnSpacingMM: Double, rowSpacingMM: Double, sliceSpacingMM: Double
    public let orientation: SliceOrientation
    public let originMM: Vec3
    public func patientPoint(i: Int, j: Int, k: Int) -> Vec3
    public func patientPoint(fromVoxel v: Vec3) -> Vec3
    public func voxelPoint(fromPatient p: Vec3) -> Vec3
    public func containsVoxel(_ v: Vec3) -> Bool
    public var voxelCount: Int
    public var spacingMM: Vec3
    public var physicalSizeMM: Vec3
    public var centerMM: Vec3
    public var boundingBoxCornersMM: [Vec3]
}

public struct Volume: Sendable {
    public init(geometry: VolumeGeometry, samples: [Int16], rescaleSlope: Double = 1.0,
                rescaleIntercept: Double = 0.0, densityUnit: DensityUnit = .greyValue) throws
    public let geometry: VolumeGeometry
    /// Ordine k-major: indice = k*(colonne*righe) + j*colonne + i
    public let samples: [Int16]
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
    public let densityUnit: DensityUnit
    public let rawValueRange: ClosedRange<Int16>
    public func linearIndex(i: Int, j: Int, k: Int) -> Int
    public func isValidVoxel(i: Int, j: Int, k: Int) -> Bool
    public func rawValue(i: Int, j: Int, k: Int) -> Int16?
    public func densityValue(i: Int, j: Int, k: Int) -> Double?
    public func applyRescale(_ raw: Int16) -> Double
    public func withUnsafeSamples<R>(_ body: (UnsafeBufferPointer<Int16>) throws -> R) rethrows -> R
}

public enum SyntheticVolume {
    /// Fantoccio: cubo corticale da 20 mm a 1200 GV, sfere da 400 / 2800 / 60 GV, aria a −1000.
    public static func makePhantom(...) throws -> Volume
    public static let cortical = 1200.0, cancellous = 400.0, enamel = 2800.0
    public static let softTissue = 60.0, air = -1000.0
}
```

Add a `SegmentKit` target to `Package.swift` depending on `DICOMCore`, plus a `SegmentKitTests`
test target and a `.library` product.

> **How to touch the manifest.** Append to the existing `moduleTargets` and `testTargets`
> constants and add one `.library` to `libraryProducts`. Do **not** move targets inline into the
> `Package(...)` call, do **not** add `swiftSettings` to any target, and do not change the
> tools-version. Both restrictions come from real failures on this package: repeating
> `.swiftLanguageMode(.v6)` per target blew the type-check budget of the whole `Package(...)`
> expression. The comments at the top of `Package.swift` record why.

### Deliverable 1 — `Sources/SegmentKit/VolumeMask.swift`

```swift
/// Etichetta per voxel. 0 è lo sfondo; 1…255 sono regioni distinte.
public typealias SegmentLabel = UInt8

public struct VolumeMask: Sendable {
    public static let background: SegmentLabel = 0
    /// Limite oltre il quale la costruzione rifiuta invece di allocare.
    public static let maximumVoxelCount = 400_000_000

    public let geometry: VolumeGeometry
    public private(set) var labels: [SegmentLabel]   // ordine k-major, come Volume.samples

    public init?(geometry: VolumeGeometry)                  // tutto sfondo
    public init?(geometry: VolumeGeometry, labels: [SegmentLabel])
    public func label(i: Int, j: Int, k: Int) -> SegmentLabel
    public mutating func setLabel(_ label: SegmentLabel, i: Int, j: Int, k: Int)
    public func contains(i: Int, j: Int, k: Int) -> Bool    // etichetta ≠ sfondo
    /// Voxel non di sfondo, per etichetta.
    public func voxelCounts() -> [SegmentLabel: Int]
    /// Volume occupato in mm³. Il voxel non è un cubo: è il prodotto delle tre spaziature.
    public func volumeMM3(label: SegmentLabel?) -> Double
    /// Riquadro contenitore in indici voxel; `nil` se l'etichetta non compare.
    public func voxelBounds(label: SegmentLabel?) -> (min: (Int, Int, Int), max: (Int, Int, Int))?
    public func union(with other: VolumeMask) throws -> VolumeMask
    public func subtracting(_ other: VolumeMask) throws -> VolumeMask
    public func inverted() -> VolumeMask
}
```

Un `UInt8` per voxel costa 400 MB su 4·10⁸ voxel. È molto, e la scelta è deliberata: una maschera
booleana costerebbe un ottavo ma non distinguerebbe il dente 16 dal dente 17 né il metallo
dall'osso, e la segmentazione multi-etichetta è il motivo per cui questo modulo esiste. Dichiaralo
nel commento e imponi il limite.

### Deliverable 2 — `Sources/SegmentKit/VolumeCrop.swift`

```swift
public enum VolumeCrop {
    /// Ritaglia a un riquadro allineato agli assi **espresso in mm Patient**.
    public static func crop(_ volume: Volume, toBoxMM box: BoxMM) throws -> Volume
    /// Ritaglia al riquadro contenitore di una maschera, con un margine.
    public static func crop(
        _ volume: Volume, toMask mask: VolumeMask, marginMM: Double
    ) throws -> Volume
}

public struct BoxMM: Hashable, Sendable, Codable {
    public var minMM: Vec3
    public var maxMM: Vec3
    public init(minMM: Vec3, maxMM: Vec3)
    public var centerMM: Vec3
    public var sizeMM: Vec3
    public func contains(_ p: Vec3) -> Bool
    public func expanded(byMM: Double) -> BoxMM
    public func clamped(to other: BoxMM) -> BoxMM
}
```

> **La trappola che sposta ogni misura, e non si vede.** Il volume ritagliato ha una nuova
> `VolumeGeometry`, e la sua `originMM` **non** è quella del volume di partenza: è il punto Patient
> del voxel `(i₀, j₀, k₀)` da cui comincia il ritaglio. Dimenticare quello spostamento produce un
> volume che a schermo sembra perfetto — è la stessa anatomia, ben ritagliata — ma in cui ogni
> coordinata Patient è traslata di una costante. Le annotazioni salvate prima del ritaglio finiscono
> altrove, le misure nuove sono giuste fra loro e sbagliate rispetto al paziente, e niente segnala
> l'errore. Usa `geometry.patientPoint(i:j:k:)` sul primo voxel incluso, non aritmetica sulle
> spaziature: l'orientamento può non essere assiale standard e i tre assi Patient non coincidono
> con i tre assi voxel.
>
> Il test che lo verifica è il primo dell'elenco al Deliverable 7 e non è negoziabile.

Il ritaglio va convertito da mm a indici in modo conservativo: il riquadro di voxel risultante deve
**contenere** il riquadro richiesto, non essere contenuto in esso. Un `floor` sul minimo e un `ceil`
sul massimo, poi limitazione agli estremi del volume. Se l'intersezione è vuota, errore nominato.

Il `densityUnit`, la pendenza e l'intercetta del rescale passano invariati: il ritaglio non è una
trasformazione dei valori.

### Deliverable 3 — `Sources/SegmentKit/ThresholdSegmentation.swift`

```swift
public enum ThresholdSegmentation {
    /// Etichetta i voxel la cui **densità** cade nell'intervallo.
    public static func segment(
        _ volume: Volume,
        densityRange: ClosedRange<Double>,
        label: SegmentLabel,
        within region: VolumeMask?
    ) throws -> VolumeMask

    /// Maschera del metallo: soglia alta, dilatazione, e sole componenti sopra un volume minimo.
    ///
    /// La dilatazione non è un dettaglio: attorno al metallo c'è una penombra di voxel già
    /// corrotti dall'indurimento del fascio, e una maschera che si fermi al bordo geometrico
    /// lascia fuori proprio i voxel da correggere.
    public static func metalMask(
        _ volume: Volume,
        thresholdGV: Double,
        dilationMM: Double,
        minimumVolumeMM3: Double
    ) throws -> VolumeMask
}
```

> **Converti la soglia, non i voxel.** L'intervallo arriva in densità (GV); i campioni in memoria
> sono `Int16` grezzi, e la densità è `grezzo · pendenza + intercetta`. La via ovvia — convertire
> ogni voxel e confrontare — costa una moltiplicazione e un'addizione per voxel, cioè fino a 10⁹
> moltiplicazioni per una soglia. La via giusta **invertisce l'intervallo una volta sola** e
> confronta interi:
>
> ```
> grezzoMin = (densitàMin − intercetta) / pendenza
> grezzoMax = (densitàMax − intercetta) / pendenza
> ```
>
> Due avvertenze, entrambe fonti di difetti reali. **Se la pendenza è negativa i due estremi si
> scambiano**: dividere per un numero negativo rovescia la disuguaglianza, e senza lo scambio la
> maschera esce vuota. È raro ma esiste. E l'arrotondamento va scelto in modo che l'intervallo
> risultante **contenga** quello richiesto — `floor` sul minimo, `ceil` sul massimo — altrimenti si
> perde un voxel di bordo su ogni lato, che su una corticale da tre voxel è un terzo della
> struttura.
>
> Confronta i valori grezzi come `Int32`, non come `Int16`: gli estremi convertiti possono uscire
> dall'intervallo di `Int16` e il troncamento li farebbe rientrare dalla parte sbagliata.

`within region` limita l'operazione a una maschera esistente. Serve a segmentare dentro una regione
già isolata senza ritagliare il volume, e va rispettato anche per il costo: fuori dalla regione non
si legge nulla.

### Deliverable 4 — `Sources/SegmentKit/RegionGrowing.swift`

```swift
public enum Connectivity: Hashable, Sendable, Codable {
    /// Sei vicini di faccia. **Predefinita.**
    case faces
    /// Ventisei vicini, facce spigoli e vertici.
    case full
}

public enum RegionGrowing {
    public static func grow(
        in volume: Volume,
        fromSeedMM seed: Vec3,
        densityRange: ClosedRange<Double>,
        connectivity: Connectivity = .faces,
        label: SegmentLabel = 1,
        maximumVoxels: Int? = nil
    ) throws -> VolumeMask

    /// Cresce da più semi nella stessa maschera, ognuno con la propria etichetta.
    public static func grow(
        in volume: Volume,
        seeds: [(seedMM: Vec3, label: SegmentLabel)],
        densityRange: ClosedRange<Double>,
        connectivity: Connectivity = .faces
    ) throws -> VolumeMask
}
```

> **Niente ricorsione.** Il riempimento ricorsivo è l'implementazione da manuale e qui si rompe: su
> un volume da 10⁸ voxel una regione connessa può avere una profondità di ricorsione di milioni di
> livelli, e il processo termina per esaurimento dello stack — non con un errore, con un crash.
> Usa una pila esplicita in un `[Int32]` di indici lineari, con `reserveCapacity`.
>
> **Marca il voxel quando lo metti in pila, non quando lo estrai.** È la differenza fra una pila che
> resta proporzionale alla superficie della regione e una che cresce come il numero di volte in cui
> ogni voxel viene raggiunto dai vicini — fino a sei. Su una regione grande è la differenza fra
> funzionare e non funzionare.
>
> **La connettività predefinita è a sei facce, e non è una preferenza estetica.** Con
> ventisei vicini due denti che si toccano in un solo punto diagonale diventano una regione sola, e
> la crescita dilaga silenziosamente in tutta l'arcata. Su un contatto diagonale i sei vicini di
> faccia non passano. Chi vuole `.full` lo chiede.

`maximumVoxels` interrompe la crescita e lo dice nel risultato: una soglia scelta male fa dilagare
la regione in tutto il volume, e un limite con un errore nominato è più utile di un'attesa di
trenta secondi che finisce in una maschera inservibile.

### Deliverable 5 — `Sources/SegmentKit/Morphology.swift`

```swift
public enum Morphology {
    public static func dilated(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask
    public static func eroded(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask
    /// Erosione poi dilatazione: rimuove i granelli.
    public static func opened(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask
    /// Dilatazione poi erosione: chiude i buchi.
    public static func closed(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask
}
```

> **Il raggio è in millimetri, e il voxel non è un cubo.** Su una CBCT anisotropa — 0,25 mm nel
> piano e 0,4 mm fra le fette è comune — un raggio di «due voxel» vale 0,5 mm in due direzioni e
> 0,8 mm nella terza. L'operazione risulta anisotropa, la maschera si deforma nella direzione delle
> fette, e sul metallo la dilatazione copre la penombra su due assi e non sul terzo. Ricava i tre
> raggi in voxel dalle tre spaziature, separatamente, e usa un elemento strutturante
> **ellissoidale** in indici che corrisponde a una sfera in millimetri.

Se il raggio in voxel è separabile lungo i tre assi puoi decomporre l'operazione in tre passate
monodimensionali, che su un raggio di *r* voxel abbatte il costo da *r³* a *3r*. Una sfera non è
esattamente separabile: se scegli la decomposizione, dichiara nel commento che l'elemento
strutturante effettivo è un ottaedro o un parallelepipedo e non una sfera, e che l'approssimazione è
accettabile qui perché le maschere servono a coprire una penombra, non a definire una superficie
da stampare. Non lasciare che il lettore lo scopra dai risultati.

### Deliverable 6 — `Sources/SegmentKit/ConnectedComponents.swift`

```swift
public struct ComponentSummary: Hashable, Sendable {
    public let label: SegmentLabel
    public let voxelCount: Int
    public let volumeMM3: Double
    public let centroidMM: Vec3
    public let boundsMM: BoxMM
}

public enum ConnectedComponents {
    /// Rietichetta ogni isola con un'etichetta distinta, in ordine di volume decrescente.
    ///
    /// Le etichette sono un `UInt8`: oltre 255 componenti quelle più piccole vanno accorpate nello
    /// sfondo, e il risultato deve **dirlo** invece di troncare in silenzio.
    public static func label(
        _ mask: VolumeMask, connectivity: Connectivity = .faces
    ) throws -> (mask: VolumeMask, components: [ComponentSummary], discarded: Int)

    public static func keepingLargest(
        _ mask: VolumeMask, count: Int, connectivity: Connectivity = .faces
    ) throws -> VolumeMask

    public static func removingSmaller(
        than volumeMM3: Double, from mask: VolumeMask, connectivity: Connectivity = .faces
    ) throws -> VolumeMask
}
```

Il baricentro va calcolato in mm Patient tramite `geometry.patientPoint(i:j:k:)`, non mediando gli
indici e convertendo alla fine: le due cose coincidono solo se le tre spaziature sono uguali, e su
una CBCT anisotropa no.

### Deliverable 7 — `Sources/SegmentKit/MaskStatistics.swift`

```swift
public struct MaskStatistics: Hashable, Sendable {
    public let voxelCount: Int
    public let volumeMM3: Double
    public let meanDensity: Double
    public let standardDeviation: Double
    public let minimumDensity: Double
    public let maximumDensity: Double
    public let densityUnitSymbol: String
}

public enum MaskAnalysis {
    public static func statistics(
        of volume: Volume, within mask: VolumeMask, label: SegmentLabel?
    ) throws -> MaskStatistics?
}
```

La deviazione standard va calcolata con una passata sulle somme degli scarti da una media già nota,
o con l'algoritmo di Welford. **Non** come `E[x²] − E[x]²`: su valori di CBCT intorno a 3000 con
varianza piccola quella formula sottrae due numeri grandi e vicini, e in doppia precisione il
risultato perde le cifre che contano — talvolta esce negativo. Nel modulo `MeasureKit` la stessa
scelta è già stata fatta per questa ragione; sii coerente.

`densityUnitSymbol` viene da `volume.densityUnit.symbol`. Su una CBCT è `GV`, non `HU`: vedi il
Contratto 4 in `docs/architecture.md`.

### Deliverable 8 — Tests in `Tests/SegmentKitTests/`

Costruisci ogni volume analiticamente in memoria, o con `SyntheticVolume.makePhantom`. Nessun file
di riferimento. Copri almeno:

1. **Il ritaglio conserva le coordinate Patient.** Prendi un punto Patient dentro la regione
   ritagliata, convertilo in indici nel volume originale e nel ritagliato, e verifica che
   `patientPoint` dei due indici dia lo **stesso** punto entro 1e-9 mm. Poi verifica che la densità
   letta nei due volumi coincida. È il test più importante del lotto.
2. Il ritaglio contiene il riquadro richiesto, non è contenuto in esso: un riquadro che cade fra due
   voxel produce un volume che lo include.
3. Un ritaglio che non interseca il volume produce un errore nominato.
4. **Soglia sul fantoccio**: l'intervallo 1100…1300 GV seleziona il cubo corticale, e
   `volumeMM3` vale 8000 mm³ (20³) entro la tolleranza di un guscio di voxel. Calcola la tolleranza
   dalla superficie del cubo per la spaziatura, non con un numero magico.
5. **Soglia con pendenza negativa**: costruisci un volume con `rescaleSlope: -1` e verifica che la
   maschera non sia vuota e selezioni gli stessi voxel del caso positivo equivalente. È il caso in
   cui l'inversione dell'intervallo senza scambio degli estremi fallisce.
6. **Crescita di regione dal centro del cubo**: la maschera coincide con il cubo e non contiene
   nessun voxel delle sfere.
7. **Connettività**: due blocchi che si toccano in un solo vertice diagonale restano due regioni
   con `.faces` e diventano una con `.full`. Due asserzioni sullo stesso fantoccio.
8. **Nessuna ricorsione**: crescita su un volume 200×200×200 interamente entro la soglia, cioè
   8 milioni di voxel in una sola regione. Deve completare senza esaurire lo stack.
9. `maximumVoxels` interrompe e lo segnala.
10. **Dilatazione su spaziatura anisotropa**: parti da un singolo voxel su una geometria
    0,25/0,25/0,50 mm, dilata di 1 mm, e verifica che l'estensione della maschera in millimetri sia
    la stessa sui tre assi entro un voxel. Con i raggi in voxel invece che in millimetri questo
    test fallisce, ed è il suo scopo.
11. Erosione e dilatazione dello stesso raggio su una sfera grande riportano approssimativamente
    alla sfera di partenza; l'apertura rimuove un granello isolato e la chiusura riempie un buco
    isolato.
12. **Componenti connesse**: due sfere disgiunte danno due componenti, ordinate per volume
    decrescente; `keepingLargest(count: 1)` tiene la maggiore; i baricentri cadono nei centri delle
    sfere entro un voxel.
13. Oltre 255 componenti: il conteggio degli scartati è maggiore di zero e non c'è troncamento
    silenzioso.
14. **Statistiche**: media nel cubo del fantoccio uguale a 1200 GV entro 1e-6, deviazione standard
    nulla entro 1e-6, e `densityUnitSymbol == "GV"`.
15. **Maschera del metallo**: inserisci un blocco a 8000 GV in un volume di tessuto molle, e
    verifica che la maschera lo contenga, che la dilatazione la estenda del raggio richiesto, e che
    un granello isolato sotto `minimumVolumeMM3` venga scartato.

### When done

Report: files created, any deviation from this spec and why, and anything you are unsure compiles.
If there are no deviations and no doubts, say so explicitly.

## ▲ Fine del prompt ▲

---

## Nota per me, al ritorno

I punti dove un difetto non si vede:

- **lo spostamento di `originMM` nel ritaglio.** È il difetto peggiore che questo modulo può
  contenere, perché produce misure plausibili e sbagliate. Test 1.
- **l'inversione dell'intervallo con pendenza negativa**, che dà una maschera vuota senza errori;
- **la marcatura del voxel all'inserimento in pila** e non all'estrazione, che è la differenza fra
  una crescita che finisce e una che consuma memoria fino al limite;
- **i raggi morfologici in millimetri e non in voxel**, che su una CBCT anisotropa deforma la
  maschera nella direzione delle fette — e sul metallo lascia la penombra scoperta su un asse;
- la deviazione standard calcolata come differenza di due grandi numeri vicini.

Il test 1 e il test 10 sono quelli che verifico prima di tutti gli altri: sono i due che
distinguono un modulo corretto da uno che sembra corretto.

Da fare a me, dopo l'integrazione: la maschera su GPU come texture `.r8Unorm` e il suo uso negli
shader MPR e di raycasting, perché Codex non può compilare Metal.
