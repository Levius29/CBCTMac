# Brief per Codex — Lotto A: ricampionamento del volume

Vedi `docs/work-plan.md` § 3, lotto A, e `docs/cs3d-teardown.md` § 4.

`SegmentKit.VolumeCrop` ritaglia già a un riquadro. Manca il **ricampionamento** a un passo di
voxel diverso, che è la seconda metà dello «strumento di riformattazione» dei visori commerciali:
si sceglie una regione e la si porta a 150 µm, lavorando a piena risoluzione su ciò che interessa
senza tenere in memoria l'intero FOV.

**Il rischio di questo lotto è tutto in una riga di codice**, ed è la ragione per cui il brief
insiste tanto sull'origine della geometria. Vedi il Deliverable 1.

Se Codex ha accesso alla repo, premetti:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi Sources/SegmentKit/VolumeCrop.swift, Sources/DICOMCore/Volume.swift e VolumeGeometry.swift
prima di iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT planning application.
Your task: add **volume resampling** to the existing `SegmentKit` target — producing a new `Volume`
at a different voxel spacing, optionally restricted to a box. Do not write any other part of the
app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **Only `Foundation`**, plus the existing `DICOMCore` target. No `simd`, no Metal, no AppKit, no
  third-party dependencies, no C interop. Compiles and tests on Linux.
- No `try!`, no `fatalError`, no force-unwraps. Every failure names what went wrong.
- Add files to the **existing** `SegmentKit` target. Do not create a new target and do not modify
  `Package.swift`.
- Doc comments in **Italian**, identifiers in **English**. Explain *why* at the traps below.

### Existing types you must use — do not redefine

```swift
// DICOMCore
public struct Vec3: Hashable, Sendable, Codable { /* x, y, z; +,-,*,/, dot, length, normalized,
    distance(to:), lerp(to:t:), isFinite */ }

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
    public var boundingBoxCornersMM: [Vec3]
}

public struct Volume: Sendable {
    public init(geometry: VolumeGeometry, samples: [Int16], rescaleSlope: Double = 1.0,
                rescaleIntercept: Double = 0.0, densityUnit: DensityUnit = .greyValue) throws
    public let geometry: VolumeGeometry
    public let samples: [Int16]              // k-major: k*(colonne*righe) + j*colonne + i
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
    public let densityUnit: DensityUnit
    public func linearIndex(i: Int, j: Int, k: Int) -> Int
    public func rawValue(i: Int, j: Int, k: Int) -> Int16?
    public func densityValue(i: Int, j: Int, k: Int) -> Double?
    /// Campionamento trilineare **già esistente**, in mm Patient, che restituisce una
    /// **densità** — cioè grezzo · slope + intercetta — e non un valore grezzo.
    public func interpolatedDensityValue(atPatient p: Vec3) -> Double?
    /// Campionamento al voxel più vicino, sempre in densità.
    public func densityValue(atPatient p: Vec3) -> Double?
}

// SegmentKit — già presenti
public struct BoxMM: Hashable, Sendable, Codable {
    public init(minMM: Vec3, maxMM: Vec3)
    public var minMM: Vec3, maxMM: Vec3
    public var centerMM: Vec3, sizeMM: Vec3
    public func contains(_ p: Vec3) -> Bool
    public func expanded(byMM: Double) -> BoxMM
}
public enum VolumeCrop: Sendable {
    public static func crop(_ volume: Volume, toBoxMM box: BoxMM) throws -> Volume
}
public enum SegmentKitError: Error, Hashable, Sendable, LocalizedError { /* … */ }
```

### Deliverable 1 — `Sources/SegmentKit/VolumeResampler.swift`

```swift
public struct ResampleRequest: Hashable, Sendable {
    /// Passo isotropo richiesto, in millimetri.
    public var spacingMM: Double
    /// Regione da ricampionare. `nil` significa l'intero volume.
    public var regionMM: BoxMM?
    /// Limite di voxel oltre il quale la richiesta viene rifiutata invece di allocare.
    public var maximumVoxelCount: Int
    public init(spacingMM: Double, regionMM: BoxMM? = nil,
                maximumVoxelCount: Int = 400_000_000)
}

public enum VolumeResampler {
    public static func resampled(_ volume: Volume, request: ResampleRequest) throws -> Volume

    /// Passi proposti per l'interfaccia, dal più fine al più grossolano.
    public static let spacingPresetsMM: [Double]
}

public enum ResampleError: Error, Hashable, Sendable, LocalizedError {
    case invalidSpacing(Double)
    case emptyRegion
    case tooManyVoxels(requested: Int, limit: Int)
}
```

> **La riga in cui si concentra tutto il rischio.** La geometria del volume ricampionato ha
> un'origine nuova, e va ricavata **proiettando un punto Patient**, non facendo aritmetica sulle
> spaziature. L'orientamento può non essere assiale standard: i tre assi voxel non coincidono con
> i tre assi Patient, e `origine + (i,j,k)·spaziatura` è vero solo nel caso standard. Nei casi
> ruotati produce un volume che a schermo sembra perfetto — è la stessa anatomia, alla risoluzione
> giusta — e in cui **ogni coordinata Patient è traslata e ruotata**. Le annotazioni salvate prima
> finiscono altrove, le misure nuove sono coerenti fra loro e sbagliate rispetto al paziente, e
> nulla segnala l'errore.
>
> Costruisci la geometria nuova con le stesse direzioni di riga e colonna dell'originale, con
> l'origine presa da `patientPoint` dell'angolo scelto, e poi verifica la corrispondenza con il
> test 1 del Deliverable 3. `VolumeCrop` risolve lo stesso problema qualche riga più in là:
> leggilo.

> **Non riscrivere il campionamento trilineare.** `Volume.interpolatedDensityValue(atPatient:)`
> esiste, è testato, e ai bordi ricade sul vicino più prossimo invece di estrapolare.
>
> Attenzione però al verso della conversione, perché è una trappola vera. Quel metodo restituisce
> una **densità**, mentre `Volume.samples` contiene valori **grezzi** in `Int16`. Ricampionare
> significa produrre campioni grezzi nuovi, quindi il valore interpolato va riportato indietro:
> `grezzo = (densità − intercetta) / slope`, arrotondato, e limitato all'intervallo di `Int16`.
> Saltare la conversione lascia un volume in cui slope e intercetta vengono applicate due volte, e
> l'immagine sembra plausibile con una scala di densità sbagliata di un fattore.
>
> Se preferisci evitare l'andata e ritorno puoi interpolare direttamente sui campioni grezzi
> scrivendo un tuo trilineare — ma allora **dichiaralo** nel commento e spiega perché non riusi
> quello esistente, e assicurati di trattare i bordi allo stesso modo.

> **Ricampionare non è filtrare.** Passando da 0,15 a 0,6 mm, l'interpolazione trilineare legge un
> campione ogni quattro e ignora gli altri tre: è *sotto-campionamento*, e produce aliasing —
> strutture sottili che compaiono e scompaiono spostandosi di una fetta. Quando il passo richiesto
> è più grossolano di quello di partenza, media i campioni della cella invece di prenderne uno
> solo. Dichiara nel commento il raggio della media e perché.

`spacingPresetsMM` deve coprire almeno `[0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0]`.

### Deliverable 2 — `Sources/SegmentKit/ReformatPlan.swift`

Il descrittore che l'interfaccia della riformattazione riempirà. Serve perché il riquadro di
ritaglio si manovra su tre viste collegate, e le tre devono descrivere **un solo**
parallelepipedo.

```swift
public struct ReformatPlan: Hashable, Sendable, Codable {
    public var regionMM: BoxMM
    public var spacingMM: Double
    public var name: String
    public var notes: String

    public init(regionMM: BoxMM, spacingMM: Double, name: String, notes: String)

    /// Riquadro iniziale: l'intero volume.
    public static func full(for geometry: VolumeGeometry, spacingMM: Double) -> ReformatPlan

    /// Numero di voxel che produrrebbe, senza allocare nulla.
    public func estimatedVoxelCount() -> Int
    /// Memoria stimata in byte, per avvisare prima di provarci.
    public func estimatedBytes() -> Int

    /// Sposta una faccia del riquadro, tenendolo dentro il volume e non degenere.
    public mutating func moveFace(_ face: BoxFace, toMM value: Double, within geometry: VolumeGeometry)

    public func validate(against geometry: VolumeGeometry) -> [String]
}

public enum BoxFace: Hashable, Sendable, Codable, CaseIterable {
    case minX, maxX, minY, maxY, minZ, maxZ
}
```

> **Il riquadro non può rovesciarsi.** Trascinando la faccia `minX` oltre `maxX` il riquadro si
> rovescia e produce dimensioni negative. Le conseguenze si vedono lontano — un conteggio di voxel
> negativo, un'allocazione assurda — e non nel punto in cui il difetto sta. `moveFace` deve
> imporre un margine minimo di un voxel fra le due facce opposte, e limitare al volume.

### Deliverable 3 — Tests in `Tests/SegmentKitTests/`

Costruisci tutto in memoria. Copri almeno:

1. **La geometria non si sposta.** Ricampiona il fantoccio a 0,15, 0,3 e 0,5 mm e verifica che un
   punto Patient dentro la regione dia la **stessa densità** nel volume originale e nel
   ricampionato, entro una tolleranza che dichiari. È il test più importante del lotto.
2. **Su geometria ruotata.** Ripeti il test 1 con una `SliceOrientation` non standard — per esempio
   colonne lungo `(0.8, 0.6, 0)` e righe lungo `(-0.6, 0.8, 0)`. Con l'origine calcolata per
   aritmetica invece che per proiezione, **questo test fallisce e il precedente no**: è la ragione
   per cui esistono entrambi.
3. **Il cubo resta 20,00 mm.** Sul fantoccio, misura lo spigolo del cubo corticale dopo il
   ricampionamento ai tre passi, per soglia sulla densità. Tolleranza: un voxel del passo nuovo.
4. **La densità resta 1200 GV** dentro il cubo, e slope, intercetta e `densityUnit` passano
   invariati.
5. **Il passo richiesto è quello ottenuto**: le tre spaziature del volume nuovo valgono
   `spacingMM`, e i conteggi coprono la regione richiesta.
6. **Sotto-campionamento senza aliasing**: su un volume con una struttura sottile periodica,
   ricampionare a un passo doppio con la media non produce l'inversione di contrasto che produce
   il campionamento puntuale. Confronta i due comportamenti nello stesso test.
7. `invalidSpacing` per passo nullo, negativo o non finito; `emptyRegion` per un riquadro che non
   interseca il volume; `tooManyVoxels` **senza allocare**, verificando che il limite scatti prima.
8. `ReformatPlan.moveFace` non rovescia il riquadro nemmeno spingendo una faccia oltre l'opposta, e
   limita al volume.
9. `estimatedVoxelCount` coincide con il conteggio reale del volume prodotto.

### When done

Report: files created, any deviation from this spec and why, and anything you are unsure compiles.
If there are no deviations and no doubts, say so explicitly.

## ▲ Fine del prompt ▲

---

## Nota per me, al ritorno

Il test 2 è quello che decide se il lotto è fatto bene: su geometria assiale standard un'origine
calcolata male dà comunque il risultato giusto, e il difetto resta invisibile fino al primo studio
ruotato. Se Codex ha scritto solo il test 1, o se il test 2 usa un orientamento che è ancora
allineato agli assi, il lotto non è verificato.

Poi il test 6, che è l'unico a distinguere un ricampionamento da un sotto-campionamento.
