# Brief per Codex — ArtifactKit: riduzione degli artefatti da metallo

Sesto lotto, ed è quello che l'utente ha indicato come più importante. Era bloccato dalla
segmentazione, che ora esiste: la maschera del metallo la produce `ThresholdSegmentation.metalMask`.

**Cosa si può fare davvero, e perché non di più.** I metodi migliori della letteratura lavorano
sulle **proiezioni**: si segmenta il metallo sull'immagine ricostruita, si sostituisce la sua
traccia nel sinogramma per interpolazione, si ricostruisce, e si raffina con una rete. Le
proiezioni grezze noi non le abbiamo — dalla CBCT esce un volume già ricostruito — e questo limite
non si aggira con l'ingegneria. Vedi `docs/competitive-analysis.md` § 6.

Resta il metodo più efficace fra quelli applicabili a un volume: la **soppressione delle strie in
dominio polare**. In coordinate polari centrate sul metallo, le strie — che in cartesiane sono
raggi — diventano linee quasi orizzontali, e un filtraggio direzionale lungo l'angolo le rimuove
lasciando intatto ciò che non ha quella forma. Non richiede alcuna ricostruzione e costa poco.

**La regola che precede l'algoritmo, e che vale più dell'algoritmo.** Un volume corretto non è più
il dato acquisito. Va marcato come corretto, la maschera va conservata, e ogni statistica calcolata
dentro o vicino alla regione corretta deve dirlo. Misurare una densità ossea su voxel interpolati e
riportarla come un dato è il modo più diretto di trasformare un miglioramento in un danno. Il
Deliverable 1 esiste solo per questo.

Se Codex ha accesso alla repo, premetti:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi Sources/SegmentKit/, Sources/DICOMCore/Volume.swift e docs/architecture.md prima di iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT planning application.
Your task: implement **ArtifactKit** — metal artefact reduction on a reconstructed volume, plus the
provenance record that makes a corrected volume honest about being corrected. Do not write any
other part of the app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **Only `Foundation`**, plus the existing `DICOMCore` and `SegmentKit` targets. No `simd`, no
  Metal, no AppKit, no third-party dependencies, no C interop. Compiles and tests on Linux.
- No `try!`, no `fatalError`, no force-unwraps. Every failure names what went wrong.
- **Never mutate the input volume.** Corrections produce a new `Volume`.
- Doc comments in **Italian**, identifiers in **English**. Explain *why* at the traps below.

### Existing types you must use — do not redefine

```swift
// DICOMCore
public struct Vec3: Hashable, Sendable, Codable { /* x, y, z; +,-,*,/, dot, cross, length,
    lengthSquared, normalized -> Vec3?, distance(to:), isFinite */ }

public struct VolumeGeometry: Hashable, Sendable, Codable {
    public let columnCount: Int, rowCount: Int, sliceCount: Int
    public let columnSpacingMM: Double, rowSpacingMM: Double, sliceSpacingMM: Double
    public let originMM: Vec3
    public func patientPoint(i: Int, j: Int, k: Int) -> Vec3
    public func voxelPoint(fromPatient p: Vec3) -> Vec3
    public var spacingMM: Vec3
    public var centerMM: Vec3
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
    public func linearIndex(i: Int, j: Int, k: Int) -> Int
    public func rawValue(i: Int, j: Int, k: Int) -> Int16?
    public func densityValue(i: Int, j: Int, k: Int) -> Double?
    public func applyRescale(_ raw: Int16) -> Double
}

// SegmentKit
public typealias SegmentLabel = UInt8
public struct VolumeMask: Sendable {
    public init?(geometry: VolumeGeometry)
    public let geometry: VolumeGeometry
    public private(set) var labels: [SegmentLabel]     // k-major, come Volume.samples
    public func label(i: Int, j: Int, k: Int) -> SegmentLabel
    public mutating func setLabel(_ label: SegmentLabel, i: Int, j: Int, k: Int)
    public func contains(i: Int, j: Int, k: Int) -> Bool
    public func voxelCounts() -> [SegmentLabel: Int]
    public func volumeMM3(label: SegmentLabel?) -> Double
    public func voxelBounds(label: SegmentLabel?) -> ...
}
public enum ThresholdSegmentation: Sendable {
    public static func metalMask(_ volume: Volume, thresholdGV: Double,
                                 dilationMM: Double, minimumVolumeMM3: Double) throws -> VolumeMask
}
public enum Morphology: Sendable {
    public static func dilated(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask
    public static func eroded(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask
}
public enum ConnectedComponents: Sendable {
    public static func label(_ mask: VolumeMask, connectivity: Connectivity)
        throws -> (mask: VolumeMask, components: [ComponentSummary], discarded: Int)
}
public struct ComponentSummary: Hashable, Sendable {
    public let label: SegmentLabel
    public let voxelCount: Int
    public let volumeMM3: Double
    public let centroidMM: Vec3
}
```

Add an `ArtifactKit` target to `Package.swift` depending on `DICOMCore` and `SegmentKit`, plus an
`ArtifactKitTests` test target and a `.library` product.

> **How to touch the manifest.** Append to the existing `moduleTargets` and `testTargets`
> constants and add one `.library` to `libraryProducts`. Do **not** move targets inline into the
> `Package(...)` call, do **not** add `swiftSettings` to any target, and do not change the
> tools-version. The comments at the top of `Package.swift` record why: repeating
> `.swiftLanguageMode(.v6)` per target blew the type-check budget of the whole expression.

### Deliverable 1 — `Sources/ArtifactKit/VolumeProvenance.swift`

Write this **first**, before any algorithm. It is the part that must not be forgotten later.

```swift
/// Che cosa è stato fatto a un volume dopo l'acquisizione.
public struct ProcessingStep: Hashable, Sendable, Codable {
    public var name: String            // es. "Soppressione strie da metallo"
    public var parametersDescription: String
    public var affectedVoxelCount: Int
    public var date: Date
}

public struct VolumeProvenance: Hashable, Sendable, Codable {
    public var steps: [ProcessingStep]
    public var isModified: Bool { !steps.isEmpty }
    /// Testo pronto per la barra di stato e per l'esportazione.
    public var summary: String
}

/// Un volume con la sua storia, e la maschera di ciò che è stato toccato.
public struct ProcessedVolume: Sendable {
    public let volume: Volume
    public let provenance: VolumeProvenance
    /// Voxel il cui valore è stato **alterato**. Non è la maschera del metallo: è più ampia,
    /// perché la correzione tocca anche l'intorno.
    public let modifiedMask: VolumeMask
    /// Vero se il punto indicato cade su un voxel alterato.
    public func isModified(atPatient point: Vec3) -> Bool
    /// Frazione di voxel alterati dentro un riquadro, per avvisare su una ROI.
    public func modifiedFraction(inBoxMM box: BoxMM) -> Double
}
```

> **Perché questo viene prima dell'algoritmo.** La correzione cambia i valori di grigio. Una ROI
> tracciata su una zona corretta restituisce una media che *sembra* una densità ossea e non lo è
> più: è una media di valori interpolati. Se l'informazione non è attaccata al volume, nessuna
> parte a valle può avvisare, e un miglioramento visivo diventa un errore di misura. Non è una
> funzione accessoria: è il motivo per cui è lecito offrire questa correzione.

### Deliverable 2 — `Sources/ArtifactKit/MetalDetection.swift`

```swift
public struct MetalRegion: Hashable, Sendable {
    public let label: SegmentLabel
    public let centroidMM: Vec3
    public let volumeMM3: Double
    /// Intervallo di fette su cui la regione compare.
    public let sliceRange: ClosedRange<Int>
}

public enum MetalDetection {
    /// Soglia automatica ricavata dall'istogramma, quando l'utente non ne impone una.
    ///
    /// Su una CBCT i valori non sono calibrati, quindi una soglia fissa in GV non è
    /// trasferibile da un apparecchio all'altro.
    public static func suggestedThresholdGV(for volume: Volume) -> Double

    public static func detect(
        in volume: Volume,
        thresholdGV: Double?,
        minimumVolumeMM3: Double
    ) throws -> (mask: VolumeMask, regions: [MetalRegion])
}
```

> **La soglia fissa è la trappola qui.** «Il metallo sta sopra 3000 GV» è vero su un apparecchio e
> falso sul successivo: la scala dipende dalla macchina, dal FOV e dalla posizione nell'immagine —
> è la stessa ragione per cui questo software scrive GV e non HU. Ricava la soglia dai dati:
> l'istogramma di una CBCT dentale ha una coda superiore separata dallo smalto, e un criterio
> robusto è un percentile alto (99,5 %) confrontato con la moda dell'osso. Documenta il criterio
> che scegli e ammetti che è euristico; lascia sempre la possibilità di imporre la soglia a mano.

### Deliverable 3 — `Sources/ArtifactKit/PolarStreakSuppression.swift`

Il cuore del lotto. Si lavora **fetta per fetta sul piano assiale**, perché le strie da metallo
giacciono in quel piano: nascono dalla geometria di acquisizione, che ruota attorno all'asse
verticale del paziente.

```swift
public struct StreakSuppressionParameters: Hashable, Sendable, Codable {
    /// Raggio massimo di azione attorno al centro del metallo, in millimetri.
    public var radiusMM: Double            // tipicamente 30–60
    /// Ampiezza della finestra angolare del filtro, in gradi.
    public var angularWindowDegrees: Double // tipicamente 5–15
    /// Quanto della correzione applicare, da 0 a 1. Sotto 1 si attenua invece di sostituire.
    public var strength: Double
    /// Il metallo stesso non si tocca: si reinserisce tale e quale.
    public var preservesMetal: Bool
    public init()
}

public enum PolarStreakSuppression {
    public static func apply(
        to volume: Volume,
        metalMask: VolumeMask,
        parameters: StreakSuppressionParameters
    ) throws -> ProcessedVolume
}
```

L'algoritmo, fetta per fetta:

1. Se la fetta non contiene metallo, si copia invariata. Non «quasi invariata»: **identica**, byte
   per byte, e questo è un test.
2. Centro polare: il baricentro del metallo **su quella fetta**, non del volume metallico intero.
   Le strie irradiano dal metallo presente lì.
3. Trasformazione in polare su una griglia (raggio × angolo), campionando con interpolazione
   bilineare. Il passo radiale sia circa la spaziatura del voxel; quello angolare tale che alla
   distanza massima un passo valga circa un voxel — altrimenti si sotto-campiona la periferia e si
   perdono dettagli lontani dal metallo.
4. Per ogni raggio costante, cioè per ogni **riga** dell'immagine polare, si stima la componente
   di stria: una mediana mobile lungo l'angolo, su una finestra pari a `angularWindowDegrees`. La
   mediana e non la media: una media viene trascinata dalla stria stessa, che è proprio ciò che si
   vuole isolare.
5. La correzione è la differenza fra il valore e la mediana locale, applicata con `strength`.
6. Ritorno in cartesiane con interpolazione bilineare, e ricomposizione: fuori da `radiusMM` il
   valore originale, dentro il valore corretto, con una **sfumatura** sul bordo.
7. Se `preservesMetal`, i voxel della maschera tornano al valore originale.

> **Il bordo di transizione, che è dove si vede il trucco.** Passando di colpo dal valore corretto
> a quello originale si crea un anello netto a `radiusMM`, che l'occhio legge come una struttura
> anatomica e che una soglia legge come un contorno. Sfuma la correzione negli ultimi millimetri,
> con un peso che va da 1 a 0. Il test che lo verifica misura il salto massimo fra voxel adiacenti
> attraverso il bordo.
>
> **La mediana mobile, se scritta male, domina il costo.** Ricalcolarla da capo per ogni angolo
> costa O(finestra · log finestra) per campione. Con una fetta da 500 raggi × 720 angoli e 300
> fette sono miliardi di operazioni. Usa una finestra scorrevole con un istogramma o due heap, così
> il costo per campione è costante o logaritmico nell'aggiornamento, non nel ricalcolo.
>
> **L'angolo è circolare.** La finestra a cavallo di 0 e 2π deve avvolgersi. Senza avvolgimento
> resta una cucitura radiale visibile — una stria artificiale creata proprio dal filtro che doveva
> toglierle. È un test.

### Deliverable 4 — `Sources/ArtifactKit/ArtifactReduction.swift`

```swift
public struct ArtifactReductionSettings: Hashable, Sendable, Codable {
    public var thresholdGV: Double?
    public var minimumMetalVolumeMM3: Double
    public var dilationMM: Double
    public var streak: StreakSuppressionParameters
    public init()
}

public enum ArtifactReduction {
    /// Individua il metallo e ne sopprime le strie. Se non trova metallo, restituisce il volume
    /// invariato con una provenienza vuota — e lo **dice**, invece di far credere di aver
    /// corretto qualcosa.
    public static func reduceMetalArtifacts(
        in volume: Volume,
        settings: ArtifactReductionSettings
    ) throws -> ProcessedVolume
}

public enum ArtifactReductionError: Error, Hashable, Sendable, LocalizedError {
    case noMetalFound(thresholdGV: Double)
    case metalTooExtensive(fraction: Double)
    case invalidParameters(detail: String)
}
```

`metalTooExtensive` serve a un caso reale: con una soglia troppo bassa la «maschera del metallo»
copre mezzo volume, e la correzione distruggerebbe l'anatomia. Sopra una frazione dichiarata —
proponi il 5 % — rifiuta con un errore che nomina la frazione trovata, invece di produrre un
risultato irriconoscibile.

### Deliverable 5 — Tests in `Tests/ArtifactKitTests/`

Costruisci ogni volume analiticamente in memoria. Nessun file di riferimento. Il fantoccio
`SyntheticVolume.makePhantom` esiste ma **non contiene strie**: per queste prove servono fantocci
tuoi, con strie sintetiche di forma nota. È il punto in cui il lotto si verifica davvero, quindi
scrivili con cura.

Fantoccio consigliato: un cilindro di tessuto molle uniforme, un inserto denso fuori centro, e
strie generate analiticamente come `A · cos(k(θ − θ₀))` sommate al valore di fondo, cioè costanti
lungo il raggio e periodiche nell'angolo. Con strie di ampiezza nota si può misurare **quanto**
ne resta.

Copri almeno:

- **Una fetta senza metallo esce identica**, campione per campione. Non «entro una tolleranza»:
  identica.
- **Le strie sintetiche si riducono**: la deviazione standard lungo l'angolo, a raggio fisso e
  lontano dal metallo, cala di almeno il 60 % rispetto al volume di partenza. Confronta con il
  valore di fondo noto, non con un'altra esecuzione dello stesso codice.
- **L'anatomia non si distrugge**: uno scalino di densità radiale, cioè una struttura che *non* ha
  la forma di una stria, sopravvive con un contrasto ridotto di meno del 10 %. È la prova che il
  filtro distingue le strie dall'anatomia, ed è più importante di quella precedente: un filtro che
  cancella tutto supera il test sulle strie e rovina l'immagine.
- **La cucitura angolare non esiste**: con strie centrate su θ = 0, il salto fra i voxel adiacenti
  a cavallo dell'angolo zero non è maggiore del salto tipico altrove.
- **Il bordo di transizione è sfumato**: il salto massimo fra voxel adiacenti attraverso
  `radiusMM` resta entro una soglia dichiarata.
- **Il metallo si conserva** quando `preservesMetal` è vero: i voxel della maschera hanno valore
  identico all'originale.
- **La provenienza è registrata**: dopo una correzione `provenance.isModified` è vero, c'è un passo
  con il conteggio dei voxel toccati, e `modifiedMask` non è vuota.
- **Senza metallo** il risultato ha provenienza vuota e volume identico, e `noMetalFound` viene
  lanciato o segnalato secondo la firma che scegli — dichiara quale.
- **`metalTooExtensive`** viene lanciato quando la maschera supera la frazione dichiarata.
- **La geometria non cambia**: origine, spaziature e conteggi del volume corretto sono identici a
  quelli di partenza. Una correzione che sposta la geometria falsifica ogni misura, ed è un difetto
  che nessuna ispezione visiva rivela.
- **Slope e intercetta si conservano**, e così `densityUnit`.

### When done

Report: files created, any deviation from this spec and why, and anything you are unsure compiles.
If there are no deviations and no doubts, say so explicitly.

## ▲ Fine del prompt ▲

---

## Nota per me, al ritorno

Da verificare per primi, perché sono i punti dove il risultato *sembra* migliore ed è peggiore:

- **il test sull'anatomia che sopravvive.** Quello sulle strie che calano lo supera anche un filtro
  che spiana tutto; è la coppia dei due a dire qualcosa. Se Codex ha scritto solo il primo, o se il
  secondo ha una tolleranza compiacente, il modulo non è verificato.
- **la provenienza attaccata al volume**, e il fatto che `modifiedMask` sia più ampia della
  maschera del metallo. Se coincidono, la correzione non ha toccato l'intorno — cioè non ha fatto
  nulla di utile — oppure la maschera è sbagliata.
- **l'avvolgimento dell'angolo**, che se manca produce una stria artificiale creata dal filtro.
- **la geometria invariata**, che è il difetto peggiore possibile qui: falsifica ogni misura e non
  si vede guardando l'immagine.

Poi resta a me: la scelta se mostrare il volume corretto o l'originale a interruttore, l'avviso
sulle ROI che cadono in zona corretta, e la maschera su GPU.
