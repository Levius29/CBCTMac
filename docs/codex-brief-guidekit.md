# Brief per Codex — GuideKit: dime chirurgiche ed endodontiche

Quarto lotto. È il più impegnativo dei quattro, e il presupposto è appena arrivato: MeshKit
esiste, compila e i suoi test passano.

**La scelta di fondo, e perché.** Non si usa un kernel CSG su triangoli. Le operazioni si fanno
su un **campo scalare** campionato su griglia, e la superficie si estrae con marching cubes. Due
ragioni concrete:

- L'offset di una mesh lungo le normali dei triangoli produce auto-intersezioni sistematiche
  ovunque la superficie sia concava — e la superficie di un'arcata è concava quasi per intero.
  Un offset su campo di distanza non può auto-intersecarsi: è una isosuperficie.
- Le operazioni booleane con la boccola diventano `min` e `max` fra campi, il che è
  immune ai casi degeneri che fanno cadere un CSG su triangoli (facce complanari, spigoli
  coincidenti, triangoli di area nulla). Su una dima che va in bocca a un paziente, la
  robustezza vale più dell'eleganza.

Questo evita anche di introdurre Manifold o CGAL, cioè una dipendenza C++ con la sua catena di
build — la stessa ragione per cui i decoder compressi sono in Swift puro.

Se Codex ha accesso alla repo, premetti:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi Sources/MeshKit/ e docs/architecture.md prima di iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT planning application.
Your task: implement **GuideKit** — generation of 3D-printable surgical and endodontic drill
guides from an intraoral scan surface plus planned implant or canal axes. Do not write any other
part of the app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **Only `Foundation`**, plus the existing `DICOMCore`, `MeshKit` and `ImplantKit` targets. No
  `simd`, no Metal, no AppKit, no third-party dependencies, no C interop. Compiles and tests on
  Linux.
- No `try!`, no `fatalError`, no force-unwraps. Every failure names what went wrong.
- **All geometry in `Double`.** Guides are printed and inserted in a mouth: a millimetre matters.
- Doc comments in **Italian**, identifiers in **English**. Explain *why* at the traps below.

### Existing types you must use — do not redefine

```swift
// DICOMCore
public struct Vec3: Hashable, Sendable, Codable { /* x, y, z; +,-,*,/, dot, cross,
    length, lengthSquared, normalized -> Vec3?, distance(to:), lerp(to:t:), isFinite,
    isApproximatelyEqual(to:tolerance:) */ }
public struct Transform3D: Hashable, Sendable, Codable { /* apply(toPoint:),
    apply(toVector:), rotation(axis:angle:) -> Transform3D?, inverse, concatenating */ }

// MeshKit
public struct Triangle: Hashable, Sendable { public let a: Int, b: Int, c: Int }
public struct Mesh: Sendable {
    public var verticesMM: [Vec3]
    public var triangles: [Triangle]
    public var name: String
    public init(verticesMM: [Vec3], triangles: [Triangle], name: String)
    public var boundsMM: (min: Vec3, max: Vec3)?
    public var centroidMM: Vec3
    public var vertexCount: Int
    public var triangleCount: Int
    public func triangleNormal(_ t: Triangle) -> Vec3?
    public func vertexNormals() -> [Vec3]
    public func surfaceAreaMM2() -> Double
    public func signedVolumeMM3() -> Double
    public func transformed(by: Transform3D) -> Mesh
    public func welded(toleranceMM: Double) -> Mesh
    public func removingDegenerateTriangles() -> Mesh
}
public enum MeshIO { public static func exportSTLBinary(_ mesh: Mesh) -> Data
                     public static func exportSTLASCII(_ mesh: Mesh) -> String }
public struct RegionMask: Sendable {
    public init(vertexCount: Int)
    public func isIncluded(_ index: Int) -> Bool
    public func includedPoints(from vertices: [Vec3]) -> [Vec3]
    public var includedCount: Int
}

// ImplantKit
public struct ImplantPlacement: Hashable, Sendable, Codable, Identifiable {
    public var model: ImplantModel
    public var platformMM: Vec3     // centro della piattaforma protesica
    public var axis: Vec3           // versore, dalla piattaforma verso l'apice
    public var label: String
    public var apexMM: Vec3
    public func axisPoint(atZ: Double) -> Vec3
    public func perpendicularBasis() -> (u: Vec3, v: Vec3)?
}
public struct ImplantModel: Hashable, Sendable, Codable, Identifiable {
    public var diameterMM: Double
    public var lengthMM: Double
}
```

Add a `GuideKit` target to `Package.swift` depending on `DICOMCore`, `MeshKit`, `ImplantKit`,
plus a `GuideKitTests` test target. Change nothing else in the manifest.

> **How to touch the manifest.** Append the two entries to the existing `moduleTargets` and
> `testTargets` constants and add one `.library` to `libraryProducts`. Do **not** move targets
> inline into the `Package(...)` call, do **not** add `swiftSettings` to any target, and do not
> change the tools-version. Both restrictions come from real failures on this package: repeating
> `.swiftLanguageMode(.v6)` per target blew the type-check budget of the whole `Package(...)`
> expression, and the typed constants exist precisely to keep that inference cheap. The comments
> at the top of `Package.swift` record why.

### Deliverable 1 — `Sources/GuideKit/ScalarField.swift`

A scalar field sampled on an axis-aligned grid. Everything else is built on this.

```swift
public struct FieldGrid: Hashable, Sendable {
    public let originMM: Vec3        // centro della cella (0,0,0)
    public let spacingMM: Double     // isotropo
    public let countX: Int, countY: Int, countZ: Int
    public init?(boundsMinMM: Vec3, boundsMaxMM: Vec3, spacingMM: Double, paddingCells: Int)
    public func position(x: Int, y: Int, z: Int) -> Vec3
    public var cellCount: Int
}

public struct ScalarField: Sendable {
    public let grid: FieldGrid
    public private(set) var values: [Double]   // countX*countY*countZ, x più veloce
    public init(grid: FieldGrid, initialValue: Double)
    public func value(x: Int, y: Int, z: Int) -> Double
    /// Trilineare; `nil` fuori dalla griglia.
    public func interpolated(atMM point: Vec3) -> Double?
    public mutating func combine(_ other: ScalarField, using: (Double, Double) -> Double) throws
    public mutating func map(_ transform: (Double) -> Double)
}
```

> **The trap that makes a guide unprintable.** `FieldGrid.init` takes `paddingCells`, whose
> default value is `2` and whose accepted range starts at `1`: below that, return `nil`.
> Marching cubes only closes a surface where the field changes sign
> *inside* the grid: if the object touches the grid boundary, the extracted mesh is left open
> there, and an open mesh is not a printable solid. The padding is what guarantees the field is
> uniformly "outside" all around the object. Reject `paddingCells < 1`.
>
> **Memory.** A 60 mm cube at 0.15 mm spacing is 400³ cells, 64 million doubles, half a
> gigabyte. Bound the grid to the actual working region and document the cost in the doc comment.
> `FieldGrid.init?` must return `nil` — not trap, not allocate — when `cellCount` would exceed a
> stated limit; use 64 million cells as that limit and name it as a public constant.

### Deliverable 2 — `Sources/GuideKit/MeshDistanceField.swift`

```swift
public enum MeshDistanceField {
    /// Campo di distanza con segno ricavato dalle normali, per superfici **aperte**.
    public static func build(
        from mesh: Mesh,
        grid: FieldGrid,
        maxDistanceMM: Double
    ) throws -> ScalarField
}
```

The field is `f(p) = sign * d(p)` where `d` is the unsigned distance from `p` to the nearest
point on the mesh, and `sign` is `+1` when `p` lies on the side the nearest triangle's normal
points to, `-1` otherwise.

> **Why not a true signed distance field.** An intraoral scan is an **open surface** — a shell of
> the arch, not a closed solid — so "inside" is undefined and any inside/outside test (ray
> parity, winding number) is meaningless on it. The normal-side sign is well defined everywhere
> and is exactly what a guide needs, because the guide approaches from one known side. State this
> in the doc comment; a future reader will otherwise "fix" it into a real SDF and break it.
>
> Accept the consequence honestly: near the **rim** of an open surface the sign flips
> discontinuously. Note in the doc comment that the footprint region must therefore stay away
> from the scan boundary, and that `GuideBuilder` enforces this.

Clamp the field to `±maxDistanceMM`: values far from the surface carry no information and
computing them exactly wastes the whole budget. Use a **uniform spatial hash over triangles**
(cell size ≈ `maxDistanceMM`) so each grid point only tests nearby triangles, never all of them —
a 200k-triangle scan against 64 million grid points is otherwise not finishable.

Point-to-triangle distance must be the exact closest-point computation, handling the interior,
the three edges and the three vertices as separate cases. Approximating with vertex distance
alone produces a lumpy field and a guide with visible facets.

### Deliverable 3 — `Sources/GuideKit/MarchingCubes.swift`

```swift
public enum MarchingCubes {
    /// Estrae l'isosuperficie a `isoLevel`. La normale punta verso i valori crescenti.
    public static func surface(
        from field: ScalarField,
        isoLevel: Double,
        name: String
    ) -> Mesh
}
```

Standard marching cubes with the 256-entry edge table and 256-entry triangle table. Interpolate
each intersected edge linearly between its two corner values, so the surface is smooth rather
than stair-stepped. Weld the result (`Mesh.welded`) and drop degenerate triangles.

Ambiguous-face cases may be resolved by the plain lookup table; note in the doc comment that this
can produce small topological artefacts on saddle configurations, and that it is acceptable here
because the fields involved are smooth offsets rather than noisy data.

> **Grid spacing versus wall thickness.** Marching cubes cannot represent a feature thinner than
> roughly two cells. A 2 mm guide wall at 1 mm spacing comes out perforated. Document that the
> spacing must be at most **one third** of the thinnest intended feature, and have
> `GuideBuilder` refuse a configuration that violates it rather than silently printing a
> guide with holes in it.

### Deliverable 4 — `Sources/GuideKit/GuideSleeve.swift`

```swift
public struct GuideSleeve: Hashable, Sendable, Codable {
    /// Asse, dal lato occlusale verso l'apice.
    public var axis: Vec3
    /// Punto sull'asse in corrispondenza del bordo **inferiore** della boccola.
    public var bottomMM: Vec3
    public var innerDiameterMM: Double
    public var outerDiameterMM: Double
    public var heightMM: Double
    /// Distanza fra il bordo inferiore della boccola e la piattaforma implantare prevista.
    public var offsetToPlatformMM: Double

    /// Boccola per un impianto pianificato, allineata al suo asse.
    public static func forImplant(
        _ implant: ImplantPlacement,
        innerDiameterMM: Double,
        outerDiameterMM: Double,
        heightMM: Double,
        offsetToPlatformMM: Double
    ) -> GuideSleeve

    /// Boccola endodontica lungo un percorso d'accesso al canale.
    /// L'asse va dal punto d'accesso coronale verso l'apice.
    public static func forCanal(
        accessMM: Vec3,
        apexMM: Vec3,
        burDiameterMM: Double,
        outerDiameterMM: Double,
        heightMM: Double
    ) -> GuideSleeve

    /// Campo del cilindro esterno: negativo dentro.
    public func housingField(grid: FieldGrid) -> ScalarField
    /// Campo del foro interno: negativo dentro.
    public func boreField(grid: FieldGrid) -> ScalarField
}
```

The bore must be a **through hole**: extend it well past both ends of the housing, otherwise the
subtraction leaves a thin membrane closing the hole — a defect invisible on screen and fatal in
use, because the drill cannot pass. Document that.

### Deliverable 5 — `Sources/GuideKit/GuideBuilder.swift`

```swift
public struct GuideConfiguration: Hashable, Sendable, Codable {
    /// Gioco fra la superficie della scansione e la parete interna della dima.
    public var fitToleranceMM: Double        // tipicamente 0.05–0.15
    public var wallThicknessMM: Double       // tipicamente 2.0–3.0
    public var gridSpacingMM: Double         // ≤ un terzo dello spessore
    /// Raggio entro cui la dima si estende attorno all'impronta dipinta.
    public var footprintRadiusMM: Double
    /// Margine minimo dal bordo della scansione: sotto questo il segno del campo non è
    /// affidabile e la dima non va costruita lì.
    public var minimumRimMarginMM: Double
    public init()
}

public struct GuideValidation: Sendable {
    public let isWatertight: Bool
    public let hasConsistentOrientation: Bool
    public let minimumWallThicknessMM: Double?
    public let volumeMM3: Double
    public let warnings: [String]
    public var isPrintable: Bool
}

public struct GuideResult: Sendable {
    public let mesh: Mesh
    public let validation: GuideValidation
    public let sleeves: [GuideSleeve]
}

public enum GuideBuilder {
    public static func build(
        scan: Mesh,
        footprint: RegionMask,
        sleeves: [GuideSleeve],
        configuration: GuideConfiguration
    ) throws -> GuideResult
}

public enum GuideBuildError: Error, Hashable, Sendable, LocalizedError {
    case emptyFootprint
    case gridTooCoarse(spacingMM: Double, thinnestFeatureMM: Double)
    case gridTooLarge(cellCount: Int, limit: Int)
    case footprintTooCloseToRim(marginMM: Double, requiredMM: Double)
    case sleeveOutsideGuide(index: Int)
    case emptyResult
}

/// Ispezione: finestre e fori praticati nella dima dopo la sua generazione.
public enum GuideFeature: Hashable, Sendable, Codable {
    /// Finestra d'ispezione: consente di verificare l'appoggio sui denti a dima inserita.
    case inspectionWindow(centreMM: Vec3, axis: Vec3, widthMM: Double, heightMM: Double)
    /// Foro d'irrigazione.
    case irrigationHole(centreMM: Vec3, axis: Vec3, diameterMM: Double)
}
```

`build` composes fields, and every step is a field operation:

1. Grid bounded to the footprint points expanded by
   `footprintRadiusMM + wallThicknessMM + fitToleranceMM`, plus padding cells.
2. `f = MeshDistanceField.build(from: scan, ...)`.
3. Guide body = the shell `fitToleranceMM ≤ f ≤ fitToleranceMM + wallThicknessMM`, expressed as
   a field so it composes: `body = max(fitTolerance − f, f − (fitTolerance + wallThickness))`,
   negative inside the shell.
4. Restrict to the footprint: `max(body, distanceToFootprint − footprintRadiusMM)`.
5. For each sleeve: `body = min(body, housing)` then `body = max(body, −bore)`.
6. Apply any `GuideFeature` by subtracting its field.
7. `MarchingCubes.surface(from: body, isoLevel: 0, ...)`.
8. Validate.

Before doing any of that, refuse configurations that cannot produce a sound guide:
`gridSpacingMM > wallThicknessMM / 3` → `gridTooCoarse`; an empty mask → `emptyFootprint`; a
footprint whose points come closer than `minimumRimMarginMM` to the scan boundary →
`footprintTooCloseToRim`. Failing early with a named reason is worth far more than a guide that
looks plausible and does not fit.

Boundary detection: a mesh edge belonging to exactly one triangle is a boundary edge. Its
vertices are rim vertices.

Watertightness check: every edge must belong to exactly two triangles, and the two must traverse
it in opposite directions. Report both facts separately in `GuideValidation` — an orientation
problem and a hole are different defects with different causes.

### Deliverable 6 — `Sources/GuideKit/GuideExport.swift`

```swift
public enum GuideExport {
    public static func stl(_ result: GuideResult) throws -> Data
    /// Riepilogo testuale da accompagnare al file: misure, boccole, esito della validazione,
    /// e la nota che una dima stampata è un dispositivo su misura.
    public static func manifest(_ result: GuideResult, configuration: GuideConfiguration) -> String
}
```

`stl` must refuse to export when `validation.isPrintable` is false, and say why. A guide that
fails validation must not reach a printer silently.

The manifest text must state, in Italian, that the printed guide is a **custom-made device**
under MDR Annex XIII, that the obligations fall on whoever produces it, and that it requires a
biocompatible resin certified to ISO 10993-1 / USP Class VI and compatible with sterilisation.
This is not decoration: it is the one place where the information reaches the person holding the
file.

### Deliverable 7 — Tests in `Tests/GuideKitTests/`

Build every mesh analytically in memory. No fixture files. Cover at least:

- `FieldGrid` refuses `paddingCells < 1` and returns `nil` beyond the cell limit.
- Distance field against an analytic case: a single large triangle, where the exact
  point-to-plane distance is known by hand. Assert agreement within a small tolerance.
- Point-to-triangle distance for a point projecting **inside** the triangle, onto an **edge**,
  and onto a **vertex** — three separate assertions, hand-computed.
- The sign flips across the surface following the normal.
- Marching cubes on the field of an analytic sphere: the extracted mesh is watertight, and its
  volume is within a few percent of `4/3 π r³`. Compare against the analytic value, not against
  another run of the same code.
- Marching cubes closes the surface when padding is present, and the **watertight check fails**
  when a sphere is deliberately made to touch the grid boundary. This is the padding trap and it
  must be a test.
- A guide built on a flat plate footprint is watertight, and its measured wall thickness matches
  `wallThicknessMM` within one grid cell.
- The bore is a through hole: a ray along the sleeve axis exits the guide, i.e. no membrane
  closes it.
- `gridTooCoarse` is thrown when spacing exceeds a third of the wall thickness.
- `footprintTooCloseToRim` is thrown for a footprint touching the mesh boundary.
- `GuideExport.stl` refuses a mesh that fails validation.
- An endodontic sleeve built from an access-to-apex path has its axis along that path.

### When done

Report: files created, any deviation from this spec and why, and anything you are unsure
compiles. If there are no deviations and no doubts, say so explicitly.

## ▲ Fine del prompt ▲

---

## Nota per me, al ritorno

Da verificare con particolare attenzione, perché sono i punti dove un difetto produce una dima
che *sembra* giusta:

- il padding della griglia, che è ciò che rende la mesh chiusa e quindi stampabile;
- il foro passante, perché una membrana residua non si vede a schermo e blocca la fresa;
- il rapporto fra passo della griglia e spessore di parete, che se violato produce una parete
  perforata;
- il rifiuto dell'export quando la validazione fallisce, che è l'ultima barriera prima della
  stampante.

Il volume della sfera confrontato con `4/3 π r³` è il test che vale più di tutti: è l'unico che
verifica la catena campo → marching cubes contro una verità analitica invece che contro se stessa.
