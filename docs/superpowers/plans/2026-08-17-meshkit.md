# MeshKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementare import/export di mesh triangolari, registrazione rigida Horn, affinamento ICP trimmed e maschere regionali in un modulo Swift 6 portabile.

**Architecture:** MeshKit è un target Foundation-only che dipende esclusivamente da DICOMCore. I cinque file pubblici richiesti contengono helper privati espliciti: cursori bounds-checked per i formati, matrici 4×4 a storage lineare per Jacobi e griglie hash distinte per welding e ICP.

**Tech Stack:** Swift 6 language mode, Foundation, DICOMCore, XCTest, Swift Package Manager.

## Global Constraints

- Swift 6 strict concurrency; tutti i tipi pubblici sono `Sendable`.
- Solo Foundation e DICOMCore; niente `simd`, Metal, AppKit, UIKit o dipendenze esterne.
- Geometria in `Double`; `Float32` soltanto al confine dei formati e allargamento immediato.
- Nessun macro, property wrapper, `try!`, `fatalError` o force unwrap su input.
- Ogni errore mesh nomina il file; ogni accesso a `Data` è preceduto da un controllo di range.
- Coordinate importate non finite generano `malformed`; coordinate non finite create in memoria non raggiungono mai `Int` nelle griglie.
- Doc comment e commenti in italiano; identificatori in inglese.
- Tutti i test costruiscono byte e geometrie in memoria; nessuna fixture versionata.
- Il toolchain Swift non è installato nell'ambiente corrente: i comandi RED/GREEN vengono comunque tentati e il limite viene registrato senza dichiarare test passati.

---

### Task 1: Target MeshKit e primitive geometriche

**Files:**
- Modify: `Package.swift`
- Create: `Tests/MeshKitTests/MeshTests.swift`
- Create: `Sources/MeshKit/Mesh.swift`

**Interfaces:**
- Consumes: `DICOMCore.Vec3`, `DICOMCore.Transform3D`.
- Produces: `Triangle` e `Mesh` con tutte le API del Deliverable 1.

- [ ] **Step 1: Scrivere i test RED delle proprietà geometriche**

Creare test XCTest che usano un tetraedro orientato e valori letterali:

```swift
import XCTest
import DICOMCore
@testable import MeshKit

final class MeshTests: XCTestCase {
    func testTriangleGeometryUsesAreaWeightedNormals() {
        let mesh = Mesh(
            verticesMM: [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 3, 0)],
            triangles: [Triangle(a: 0, b: 1, c: 2)],
            name: "triangle")

        XCTAssertEqual(mesh.vertexCount, 3)
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertEqual(mesh.surfaceAreaMM2(), 3.0, accuracy: 1e-12)
        XCTAssertEqual(mesh.triangleNormal(mesh.triangles[0]), Vec3(0, 0, 1))
        XCTAssertEqual(mesh.vertexNormals(), [Vec3(0, 0, 1), Vec3(0, 0, 1), Vec3(0, 0, 1)])
    }

    func testSignedVolumeIsDefinedForClosedOrientedMesh() {
        let mesh = makeUnitTetrahedron()
        XCTAssertEqual(abs(mesh.signedVolumeMM3()), 1.0 / 6.0, accuracy: 1e-12)
    }
}
```

Nel medesimo file aggiungere test separati per bounds, centroide vuoto/non vuoto,
trasformazione, normali isolate `.zero`, indici fuori range e rimozione di triangoli con
indici ripetuti o area nulla.

- [ ] **Step 2: Scrivere i test RED del welding, inclusa la guardia NaN**

Il bug catturato è sia la mancata ricerca nella cella adiacente sia il trap da conversione
`NaN → Int`:

```swift
func testWeldingFindsDuplicatesAcrossCellBoundaries() {
    let mesh = Mesh(
        verticesMM: [
            Vec3(0.000099, 0, 0), Vec3(0.000101, 0, 0),
            Vec3(1, 0, 0), Vec3(0, 1, 0),
        ],
        triangles: [Triangle(a: 0, b: 2, c: 3), Triangle(a: 1, b: 2, c: 3)],
        name: "unwelded")

    let welded = mesh.welded(toleranceMM: 1e-4)
    XCTAssertEqual(welded.vertexCount, 3)
    XCTAssertEqual(welded.surfaceAreaMM2(), mesh.surfaceAreaMM2(), accuracy: 1e-4)
}

func testWeldingSkipsNonFiniteVertexWithoutTrapping() {
    let mesh = Mesh(
        verticesMM: [Vec3(Double.nan, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0)],
        triangles: [],
        name: "application-mesh")
    let welded = mesh.welded()
    XCTAssertEqual(welded.vertexCount, 3)
    XCTAssertTrue(welded.verticesMM[0].x.isNaN)
}
```

- [ ] **Step 3: Tentare il RED**

Run: `swift test --filter MeshTests`

Expected in un ambiente Swift: FAIL perché `MeshKit` e le API non esistono. Nell'ambiente
corrente registrare `swift: command not found`.

- [ ] **Step 4: Aggiungere prodotto, target e test target al manifest**

Modificare `Package.swift` con dipendenze unidirezionali:

```swift
.library(name: "MeshKit", targets: ["MeshKit"]),

.target(
    name: "MeshKit",
    dependencies: ["DICOMCore"],
    swiftSettings: [.swiftLanguageMode(.v6)]
),

.testTarget(
    name: "MeshKitTests",
    dependencies: ["MeshKit", "DICOMCore"],
    swiftSettings: [.swiftLanguageMode(.v6)]
),
```

- [ ] **Step 5: Implementare `Mesh.swift`**

Usare loop espliciti e una chiave privata con conversione fallibile:

```swift
private struct WeldCell: Hashable {
    let x: Int
    let y: Int
    let z: Int
}

private func weldCell(for point: Vec3, size: Double) -> WeldCell? {
    guard point.isFinite, size.isFinite, size > 0 else { return nil }
    guard let x = Int(exactly: Foundation.floor(point.x / size)),
          let y = Int(exactly: Foundation.floor(point.y / size)),
          let z = Int(exactly: Foundation.floor(point.z / size))
    else { return nil }
    return WeldCell(x: x, y: y, z: z)
}
```

Per ciascun vertice finito cercare rappresentanti nelle 27 celle, verificare la distanza
euclidea e mantenere il primo. Per un vertice non finito aggiungere sempre un nuovo
rappresentante senza inserirlo nella griglia. Validare ogni indice prima del subscript.

- [ ] **Step 6: Tentare il GREEN e committare**

Run: `swift test --filter MeshTests`

Commit:

```bash
git add Package.swift Sources/MeshKit/Mesh.swift Tests/MeshKitTests/MeshTests.swift
git commit -m "feat: add MeshKit geometry"
```

---

### Task 2: STL binario e ASCII

**Files:**
- Create: `Tests/MeshKitTests/MeshIOByteBuilder.swift`
- Create: `Tests/MeshKitTests/STLTests.swift`
- Create: `Sources/MeshKit/MeshIO.swift`

**Interfaces:**
- Consumes: `Mesh`, `Triangle`, `Vec3`.
- Produces: `MeshFormat`, `MeshIOError`, rilevamento STL, load da `Data`/`URL` ed export STL.

- [ ] **Step 1: Creare il builder test-only e i test RED STL**

Il builder espone append espliciti per endianess:

```swift
struct MeshIOByteBuilder {
    private(set) var bytes: [UInt8] = []
    mutating func appendUInt16(_ value: UInt16, bigEndian: Bool = false) {
        let ordered = bigEndian ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: ordered) { rawBytes in
            bytes.append(contentsOf: rawBytes)
        }
    }
    mutating func appendUInt32(_ value: UInt32, bigEndian: Bool = false) {
        let ordered = bigEndian ? value.bigEndian : value.littleEndian
        withUnsafeBytes(of: ordered) { rawBytes in
            bytes.append(contentsOf: rawBytes)
        }
    }
    mutating func appendFloat32(_ value: Float, bigEndian: Bool = false) {
        appendUInt32(value.bitPattern, bigEndian: bigEndian)
    }
    mutating func appendFloat64(_ value: Double, bigEndian: Bool = false) {
        let bits = value.bitPattern
        let ordered = bigEndian ? bits.bigEndian : bits.littleEndian
        withUnsafeBytes(of: ordered) { rawBytes in
            bytes.append(contentsOf: rawBytes)
        }
    }
    mutating func appendASCII(_ value: String) { bytes.append(contentsOf: value.utf8) }
    var data: Data { Data(bytes) }
}
```

`STLTests` deve includere:

```swift
func testBinaryRoundTrip() throws {
    let original = makeTwoTriangleSquare()
    let data = MeshIO.exportSTLBinary(original)
    let loaded = try MeshIO.load(data: data, name: "square.stl")
    XCTAssertEqual(loaded.triangleCount, 2)
    XCTAssertEqual(loaded.vertexCount, 4)
    XCTAssertEqual(loaded.surfaceAreaMM2(), 1.0, accuracy: 1e-6)
}

func testBinaryHeaderBeginningWithSolidStaysBinary() throws {
    var data = MeshIO.exportSTLBinary(makeTwoTriangleSquare())
    data.replaceSubrange(0..<5, with: Data("solid".utf8))
    let loaded = try MeshIO.load(data: data, name: "trap.stl")
    XCTAssertEqual(loaded.triangleCount, 2)
}
```

Aggiungere STL ASCII con whitespace irregolare e senza `endsolid`, file troncato, header
binario con `UInt32.max` e input vuoto.

- [ ] **Step 2: Tentare il RED STL**

Run: `swift test --filter STLTests`

Expected: API `MeshIO` assente; nell'ambiente corrente il comando Swift non è disponibile.

- [ ] **Step 3: Implementare cursore, errori e STL**

`MeshIO.swift` contiene un cursore privato con `readUInt8/16/32/64`, `readFloat32`,
`readFloat64`, `readData` e `skip`. Ogni metodo usa una funzione equivalente a:

```swift
mutating func validatedRange(count: Int) throws -> Range<Int> {
    guard count >= 0, offset >= 0, offset <= data.count,
          count <= data.count - offset
    else { throw MeshIOError.truncated(name: name, atOffset: offset) }
    return offset..<(offset + count)
}
```

Prima di decodificare testo, leggere il conteggio STL e confrontare con
`84 + 50 × count` usando sottrazione/divisione protette. Per file binari non testuali con
conteggio superiore ai record disponibili, lanciare `tooManyTriangles` prima di riservare
memoria. Validare `Vec3.isFinite` per ciascuno dei tre vertici e nominare l'indice progressivo.

L'ASCII viene tokenizzato per whitespace e analizzato con indice esplicito. Entrambi i parser
restituiscono `mesh.welded()` e verificano che esistano vertici e triangoli.

- [ ] **Step 4: Implementare gli exporter STL**

Filtrare prima i triangoli con indici validi, scrivere il conteggio effettivo e poi ogni
record. Il binario usa `Float(value).bitPattern` soltanto durante la serializzazione; l'ASCII
usa una riga per normale e vertice. Una normale degenere è `(0,0,0)`.

- [ ] **Step 5: Tentare il GREEN STL e committare**

Run: `swift test --filter STLTests`

Commit:

```bash
git add Sources/MeshKit/MeshIO.swift Tests/MeshKitTests/MeshIOByteBuilder.swift Tests/MeshKitTests/STLTests.swift
git commit -m "feat: import and export STL meshes"
```

---

### Task 3: PLY header-driven ASCII e binario

**Files:**
- Modify: `Sources/MeshKit/MeshIO.swift`
- Create: `Tests/MeshKitTests/PLYTests.swift`

**Interfaces:**
- Consumes: cursore e tipi pubblici di `MeshIO.swift`.
- Produces: parser PLY ASCII, binary little-endian e binary big-endian con proprietà scalari/lista.

- [ ] **Step 1: Scrivere i test RED PLY**

Creare stream letterali per un quad con quattro vertici e una faccia, aspettandosi due
triangoli. Per il caso binario extra-property usare header:

```text
ply
format binary_little_endian 1.0
element vertex 3
property float x
property uchar red
property float y
property uchar green
property float z
property uchar blue
element face 1
property list uchar int vertex_indices
end_header
```

Scrivere i record nell'ordine dichiarato e verificare coordinate esatte, dimostrando che i
byte colore vengono consumati. Ripetere uno stream big-endian con `double x/y/z` e indici
`ushort`.

Il test anti-crash richiesto usa un bit pattern NaN:

```swift
func testPLYRejectsNaNCoordinate() {
    var builder = makeBinaryPLYHeader(vertexCount: 3, faceCount: 1)
    builder.appendUInt32(0x7FC0_0000)
    // completare y/z, gli altri vertici e la faccia con valori finiti
    XCTAssertThrowsError(try MeshIO.load(data: builder.data, name: "nan.ply")) {
        (error: any Error) in
        guard case MeshIOError.malformed(let name, let detail) = error else {
            XCTFail("Atteso malformed")
            return
        }
        XCTAssertEqual(name, "nan.ply")
        XCTAssertTrue(detail.contains("vertice 0"))
    }
}
```

- [ ] **Step 2: Tentare il RED PLY**

Run: `swift test --filter PLYTests`

- [ ] **Step 3: Implementare descrittori dell'header PLY**

Usare enum privati non generici:

```swift
private enum PLYEncoding { case ascii, binaryLittleEndian, binaryBigEndian }
private enum PLYScalarType { case int8, uint8, int16, uint16, int32, uint32, float32, float64 }
private enum PLYProperty {
    case scalar(name: String, type: PLYScalarType)
    case list(name: String, countType: PLYScalarType, valueType: PLYScalarType)
}
private struct PLYElement {
    let name: String
    let count: Int
    var properties: [PLYProperty]
}
```

Individuare `end_header` a livello byte, preservando l'offset del corpo. Rifiutare conteggi
negativi/non rappresentabili e proprietà senza elemento corrente.

- [ ] **Step 4: Implementare i reader record-driven**

Per ogni elemento e record consumare tutte le proprietà. Catturare x/y/z per `vertex`, la
lista indici per `face`, ignorare dopo la lettura ogni altra proprietà. Per le liste leggere
prima il conteggio come intero non negativo, verificarlo contro i byte residui e triangolare
con `(v0, vi, vi+1)`. Allargare ogni `Float` a `Double` nello stesso statement di lettura e
validare il `Vec3` prima di appendere.

- [ ] **Step 5: Tentare il GREEN PLY e committare**

Run: `swift test --filter PLYTests`

Commit:

```bash
git add Sources/MeshKit/MeshIO.swift Tests/MeshKitTests/PLYTests.swift
git commit -m "feat: import ASCII and binary PLY meshes"
```

---

### Task 4: OBJ e rilevamento finale del formato

**Files:**
- Modify: `Sources/MeshKit/MeshIO.swift`
- Create: `Tests/MeshKitTests/OBJTests.swift`

**Interfaces:**
- Consumes: errori e validazione mesh già implementati.
- Produces: parser OBJ completo e detection content-first fra STL, PLY e OBJ.

- [ ] **Step 1: Scrivere i test RED OBJ**

Usare un singolo OBJ che esercita righe separate con `i`, `i/j`, `i//k`, `i/j/k`, una faccia
negativa e un quad. Verificare il numero di triangoli e gli indici letterali attesi. Aggiungere
test per indice zero, indice fuori range, vertice `nan` e file troncato/non riconoscibile.

```swift
func testOBJTriangulatesAllIndexForms() throws {
    let text = """
    v 0 0 0
    v 1 0 0
    v 1 1 0
    v 0 1 0
    vt 0 0
    vn 0 0 1
    f 1 2 3
    f 1/1 3/1 4/1
    f 1//1 2//1 4//1
    f 2/1/1 3/1/1 4/1/1
    f -4 -3 -2 -1
    """
    let mesh = try MeshIO.load(data: Data(text.utf8), name: "forms.obj")
    XCTAssertEqual(mesh.vertexCount, 4)
    XCTAssertEqual(mesh.triangleCount, 6)
    XCTAssertEqual(mesh.triangles[4], Triangle(a: 0, b: 1, c: 2))
    XCTAssertEqual(mesh.triangles[5], Triangle(a: 0, b: 2, c: 3))
}
```

- [ ] **Step 2: Tentare il RED OBJ**

Run: `swift test --filter OBJTests`

- [ ] **Step 3: Implementare parsing line-based e detection**

Per ciascuna linea rimuovere la parte da `#`, separare per whitespace con loop esplicito e
gestire `v`/`f`. Risolvere l'indice con:

```swift
if rawIndex > 0 { resolved = rawIndex - 1 }
else if rawIndex < 0 { resolved = vertices.count + rawIndex }
else { throw malformed }
```

Il rilevamento usa nell'ordine: dimensione STL binaria esatta, magic `ply`, grammatica STL
ASCII e presenza di record OBJ `v`/`f`. Nessun binario viene decodificato come testo prima del
controllo STL.

- [ ] **Step 4: Tentare il GREEN OBJ, testare tutta MeshIO e committare**

Run: `swift test --filter MeshIO`

Run: `swift test --filter STLTests`

Run: `swift test --filter PLYTests`

Run: `swift test --filter OBJTests`

Commit:

```bash
git add Sources/MeshKit/MeshIO.swift Tests/MeshKitTests/OBJTests.swift
git commit -m "feat: import OBJ meshes"
```

---

### Task 5: Registrazione rigida Horn

**Files:**
- Create: `Tests/MeshKitTests/PointRegistrationTests.swift`
- Create: `Sources/MeshKit/PointRegistration.swift`

**Interfaces:**
- Consumes: `Vec3`, `Transform3D`.
- Produces: `RegistrationResult`, `RegistrationError`, `PointRegistration.align`.

- [ ] **Step 1: Scrivere i test RED della soluzione nota**

Costruire almeno sei punti non coplanari e un target con rotazione/traslazione note:

```swift
func testRecoversKnownRigidTransform() throws {
    let rotation = try XCTUnwrap(Transform3D.rotation(axis: Vec3(1, 2, 3), angle: 0.37))
    let expected = Transform3D(
        columnX: rotation.columnX,
        columnY: rotation.columnY,
        columnZ: rotation.columnZ,
        origin: Vec3(12.5, -7.25, 3.75))
    let source = registrationPoints()
    var target: [Vec3] = []
    for point: Vec3 in source { target.append(expected.apply(toPoint: point)) }

    let result = try PointRegistration.align(source: source, target: target)
    XCTAssertTrue(result.transform.isApproximatelyEqual(to: expected, tolerance: 1e-9))
    XCTAssertLessThan(result.rmsErrorMM, 1e-9)
    XCTAssertEqual(result.iterations, 0)
    XCTAssertTrue(result.converged)
}
```

Aggiungere mismatch, meno di tre punti, coincidenti, collineari, coordinate non finite e caso
target specchiato che deve produrre `determinant > 0` e residuo non nullo.

- [ ] **Step 2: Tentare il RED Horn**

Run: `swift test --filter PointRegistrationTests`

- [ ] **Step 3: Implementare validazione e degenerazione scale-aware**

Calcolare centroidi con loop. Scegliere il vettore centrato più lungo e verificare che esista
un secondo vettore con `cross.length > 1e-12 × base.length × candidate.length`. Ripetere il
controllo per source e target. Qualsiasi coordinata non finita genera
`degenerateConfiguration`.

- [ ] **Step 4: Implementare matrice Horn e Jacobi 4×4**

Usare `[Double](repeating: 0, count: 16)` per matrice ed autovettori. A ogni rotazione scegliere
il maggiore elemento fuori diagonale, calcolare `tau`, `t`, `c`, `s`, aggiornare righe/colonne
simmetriche e la matrice degli autovettori. Arrestare quando il massimo è sotto `1e-15` o dopo
un limite fisso prudente; un autovettore non normalizzabile genera
`degenerateConfiguration`.

Convertire `(w,x,y,z)` nelle colonne di `Transform3D`, calcolare l'origine e infine RMS/max su
tutte le coppie. La doc comment include le due motivazioni Horn contro SVD/Kabsch.

- [ ] **Step 5: Tentare il GREEN Horn e committare**

Run: `swift test --filter PointRegistrationTests`

Commit:

```bash
git add Sources/MeshKit/PointRegistration.swift Tests/MeshKitTests/PointRegistrationTests.swift
git commit -m "feat: register corresponding points with Horn method"
```

---

### Task 6: ICP trimmed e griglia target

**Files:**
- Create: `Tests/MeshKitTests/ICPTests.swift`
- Create: `Sources/MeshKit/ICP.swift`

**Interfaces:**
- Consumes: `PointRegistration.align`, `RegistrationResult`, `RegistrationError`.
- Produces: `ICPOptions` e `ICP.refine`.

- [ ] **Step 1: Scrivere i test RED ICP nominale e trimmed**

Generare una nuvola deterministica non simmetrica con loop su tre indici, target ottenuto da
una trasformazione nota e initial perturbato di pochi decimi di grado e millimetro. Verificare
RMS `< 0.01`, determinante positivo e trasformazione vicina.

Per trimmed ICP aggiungere al source il 30% di punti spostati senza controparte, impostare una
distanza massima che li lasci inizialmente candidati e verificare che il fit dei punti inlier
recuperi la trasformazione entro `0.01 mm`.

- [ ] **Step 2: Scrivere i test RED delle terminazioni e delle guardie**

Test separati:

- `maxIterations = 1` e `toleranceMM = 0` restituisce `converged == false` senza throw;
- cutoff che lascia meno di tre corrispondenze lancia `didNotConverge`;
- source/target collineari con corrispondenze esatte propaga `degenerateConfiguration` da
  `PointRegistration.align`;
- punti target e source non finiti vengono saltati senza trap;
- opzioni fuori dominio generano `degenerateConfiguration`.

- [ ] **Step 3: Tentare il RED ICP**

Run: `swift test --filter ICPTests`

- [ ] **Step 4: Implementare opzioni, sampling e griglia**

La chiave privata usa la stessa guardia finita/esatta del welding. Costruire
`[GridCell: [Int]]` una volta sul target, saltando punti non finiti. Il campione sorgente usa
indici equidistanti calcolati con aritmetica intera, senza casualità.

La query visita tre offset per asse con loop annidati, valida l'addizione degli indici di cella
contro overflow e mantiene il target con distanza quadrata minima entro il cutoff.

- [ ] **Step 5: Implementare iterazioni, trimming e terminazione**

Conservare corrispondenze private `(source: Vec3, target: Vec3, distanceSquared: Double)`,
ordinarle con closure completamente tipizzata e calcolare per difetto il numero trattenuto.
Prima di `align`, se il numero è inferiore a tre, lanciare `didNotConverge` con RMS precedente,
RMS dei superstiti o `.infinity`.

Non intercettare `RegistrationError.degenerateConfiguration`: lasciare propagare l'errore.
Comporre `delta.concatenating(current)`. Un RMS crescente incrementa il contatore di
divergenza, ogni non-crescita lo azzera, il quinto aumento lancia `didNotConverge`. Al limite
restituire l'ultimo risultato con `converged == false`.

- [ ] **Step 6: Tentare il GREEN ICP e committare**

Run: `swift test --filter ICPTests`

Commit:

```bash
git add Sources/MeshKit/ICP.swift Tests/MeshKitTests/ICPTests.swift
git commit -m "feat: refine mesh registration with trimmed ICP"
```

---

### Task 7: RegionMask

**Files:**
- Create: `Tests/MeshKitTests/RegionMaskTests.swift`
- Create: `Sources/MeshKit/RegionMask.swift`

**Interfaces:**
- Consumes: `[Vec3]`.
- Produces: `RegionMask` con selezione sferica e raccolta dei punti inclusi.

- [ ] **Step 1: Scrivere i test RED della maschera**

```swift
func testSphereExclusionAndInclusion() {
    let vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(3, 0, 0)]
    var mask = RegionMask(vertexCount: vertices.count)
    mask.exclude(sphereCentreMM: .zero, radiusMM: 1.1, vertices: vertices)
    XCTAssertEqual(mask.includedCount, 1)
    XCTAssertEqual(mask.includedPoints(from: vertices), [Vec3(3, 0, 0)])
    mask.include(sphereCentreMM: .zero, radiusMM: 0.1, vertices: vertices)
    XCTAssertTrue(mask.isIncluded(0))
}
```

Aggiungere includeAll/excludeAll, conteggio negativo iniziale, indice fuori range, array
vertici più corto e raggio negativo/non finito.

- [ ] **Step 2: Tentare il RED RegionMask**

Run: `swift test --filter RegionMaskTests`

- [ ] **Step 3: Implementare la maschera con loop bounds-safe**

Inizializzare `[Bool](repeating: true, count: max(0, vertexCount))`. Nelle operazioni sferiche
usare `min(included.count, vertices.count)`, raggio al quadrato e coordinate finite. Un indice
non valido restituisce `false`.

- [ ] **Step 4: Tentare il GREEN e committare**

Run: `swift test --filter RegionMaskTests`

Commit:

```bash
git add Sources/MeshKit/RegionMask.swift Tests/MeshKitTests/RegionMaskTests.swift
git commit -m "feat: mask mesh registration regions"
```

---

### Task 8: Audit integrato e consegna

**Files:**
- Verify: `Package.swift`
- Verify: `Sources/MeshKit/*.swift`
- Verify: `Tests/MeshKitTests/*.swift`
- Verify: `docs/superpowers/specs/2026-08-17-meshkit-design.md`

**Interfaces:**
- Consumes: l'intero modulo MeshKit.
- Produces: ramo revisionabile con report completo di verifiche e limiti.

- [ ] **Step 1: Tentare l'intera suite**

Run: `swift test`

Non dichiarare successo se il toolchain resta assente. Conservare l'output esatto nel report.

- [ ] **Step 2: Eseguire gli audit statici**

```bash
git diff --check 79517a286d54c770b90ffb3cb197757ff3eff21a...HEAD
rg -n 'try!|fatalError|preconditionFailure|assertionFailure' Sources/MeshKit Tests/MeshKitTests
rg -n '[A-Za-z0-9_\)\]]!([\.,\)\]\?]|$)' Sources/MeshKit Tests/MeshKitTests
rg -n 'simd|Metal|AppKit|UIKit' Sources/MeshKit Tests/MeshKitTests
rg -n '@(Suite|Test)|#(expect|require)|import Testing' Tests/MeshKitTests
rg -n '^public (struct|enum|protocol|class|actor)' Sources/MeshKit
```

Verificare manualmente che ogni pubblico dichiari `Sendable`, che ogni conversione a indice
di griglia passi da `isFinite` e `Int(exactly:)`, e che ogni accesso `Data[...]` abbia una
guardia locale dimostrabile.

- [ ] **Step 3: Confrontare copertura con il brief**

Spuntare esplicitamente: quattro formati/varianti PLY, trap `solid`, proprietà extra, indici
OBJ, truncation/count bomb, welding/NaN, Horn/reflection/collinearità, ICP/trim/non-convergence,
propagazione degenerazione e RegionMask.

- [ ] **Step 4: Committare eventuali sole correzioni di audit**

```bash
git add Package.swift Sources/MeshKit Tests/MeshKitTests docs/superpowers
git commit -m "chore: complete MeshKit audit"
```

Eseguire il commit soltanto se l'audit ha prodotto modifiche; non creare commit vuoti.
