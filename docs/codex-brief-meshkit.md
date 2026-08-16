# Brief per Codex — MeshKit: import mesh e registrazione

Secondo lotto, dopo il parser DICOM. Stessa modalità: copia il blocco fra i marcatori e
incollalo in Codex. Al ritorno rivedo il codice prima del merge.

Perché questo: è il presupposto delle **dime chirurgiche** (Fase 5). Senza la scansione
intraorale registrata sul CBCT non esiste pianificazione protesicamente guidata, e senza quella
la dima non ha su cosa appoggiarsi.

Se Codex ha accesso alla repo, premetti:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi docs/architecture.md e Sources/DICOMCore/Geometry.swift prima di iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT planning application.
Your task: implement **MeshKit** — surface mesh import/export and rigid registration of an
intraoral scan onto a CBCT volume. Do not write any other part of the app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **No `simd`, no Metal, no AppKit/UIKit, no third-party dependencies.** Only `Foundation`.
  This module must compile and test on Linux.
- **Nobody can compile your output before review.** Write conservative, plain Swift. No clever
  generics, no macros, no property wrappers. Prefer explicit loops where types could be
  ambiguous. Verify every closure's inferred types by hand.
- No `try!`, no `fatalError`, no force-unwraps on parsed input. A malformed mesh file is
  routine, not a bug. Every failure names the file and what went wrong.
- **All geometry in `Double`**, never `Float`, except where a file format stores Float32 — read
  it as Float32 and widen immediately.
- Doc comments in **Italian**, identifiers in **English**. Explain *why*, especially where a
  rule exists because of a real-world trap.

### Existing types you must use — do not redefine

```swift
// Sources/DICOMCore/Geometry.swift  (module DICOMCore)
public struct Vec3: Hashable, Sendable, Codable {
    public var x: Double; public var y: Double; public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double)
    public static let zero: Vec3
    public var lengthSquared: Double
    public var length: Double
    public var normalized: Vec3?          // nil for the zero vector
    public var isFinite: Bool
    // + - * / with scalars, +=, -=, *=
    public func dot(_ o: Vec3) -> Double
    public func cross(_ o: Vec3) -> Vec3
    public func distance(to o: Vec3) -> Double
    public func lerp(to o: Vec3, t: Double) -> Vec3
    public func angle(to o: Vec3) -> Double?
    public func isApproximatelyEqual(to o: Vec3, tolerance: Double = 1e-9) -> Bool
}

public struct Transform3D: Hashable, Sendable, Codable {
    public var columnX: Vec3; public var columnY: Vec3; public var columnZ: Vec3
    public var origin: Vec3
    public init(columnX: Vec3, columnY: Vec3, columnZ: Vec3, origin: Vec3)
    public static let identity: Transform3D
    public static func translation(_ t: Vec3) -> Transform3D
    public static func rotation(axis: Vec3, angle: Double) -> Transform3D?
    public var determinant: Double
    public func apply(toPoint p: Vec3) -> Vec3     // includes translation
    public func apply(toVector v: Vec3) -> Vec3    // excludes translation
    public func concatenating(_ other: Transform3D) -> Transform3D  // self ∘ other
    public var inverse: Transform3D?
    public func isApproximatelyEqual(to o: Transform3D, tolerance: Double = 1e-9) -> Bool
}
```

`MeshKit` depends on `DICOMCore` only.

### Deliverable 1 — `Sources/MeshKit/Mesh.swift`

```swift
public struct Triangle: Hashable, Sendable { public let a: Int, b: Int, c: Int }  // vertex indices

public struct Mesh: Sendable {
    public var verticesMM: [Vec3]
    public var triangles: [Triangle]
    public var name: String
    public init(verticesMM: [Vec3], triangles: [Triangle], name: String)

    public var boundsMM: (min: Vec3, max: Vec3)?    // nil when empty
    public var centroidMM: Vec3
    public var triangleCount: Int
    public var vertexCount: Int

    public func triangleNormal(_ t: Triangle) -> Vec3?      // nil if degenerate
    public func vertexNormals() -> [Vec3]                   // area-weighted average
    public func surfaceAreaMM2() -> Double
    /// Signed volume via the divergence theorem. Only meaningful for a closed mesh;
    /// document that and do not pretend otherwise.
    public func signedVolumeMM3() -> Double
    public func transformed(by t: Transform3D) -> Mesh
    /// Removes duplicate vertices within `toleranceMM` and reindexes triangles.
    /// Intraoral scans routinely ship with unwelded vertices, and every downstream
    /// algorithm gets slower and less stable without this.
    public func welded(toleranceMM: Double = 1e-4) -> Mesh
    /// Drops triangles with zero area or repeated indices.
    public func removingDegenerateTriangles() -> Mesh
}
```

### Deliverable 2 — `Sources/MeshKit/MeshIO.swift`

```swift
public enum MeshFormat: Sendable { case stlBinary, stlASCII, ply, obj }

public enum MeshIO {
    public static func load(url: URL) throws -> Mesh          // detects format
    public static func load(data: Data, name: String) throws -> Mesh
    public static func exportSTLBinary(_ mesh: Mesh) -> Data
    public static func exportSTLASCII(_ mesh: Mesh) -> String
}

public enum MeshIOError: Error, Hashable, Sendable, LocalizedError {
    case unrecognisedFormat(name: String)
    case truncated(name: String, atOffset: Int)
    case malformed(name: String, detail: String)
    case emptyMesh(name: String)
    case tooManyTriangles(name: String, declared: UInt32)
}
```

Formats to support:

**STL binary** — 80-byte header, `UInt32` triangle count, then 50 bytes per triangle
(3 Float32 normal + 9 Float32 vertices + UInt16 attribute).
> **Trap you must handle:** you cannot detect binary vs ASCII by the leading word. Plenty of
> binary STL files begin with the ASCII text `solid` in their 80-byte header, and naive
> detection then parses megabytes of binary as text. **Detect by size**: a file is binary STL
> if `data.count == 84 + 50 * triangleCount` where triangleCount is read from bytes 80..84.
> Fall back to ASCII only when that check fails. Also sanity-check the declared count against
> the available bytes before allocating, so a corrupt header cannot request gigabytes.

**STL ASCII** — `solid` / `facet normal` / `outer loop` / `vertex` ×3 / `endloop` / `endfacet`.
Tolerate arbitrary whitespace and missing trailing `endsolid`.

**PLY** — ASCII and binary, both little and big endian. Parse the header for `element vertex N`,
`element face M`, and the property list. Support at minimum `float`/`float32`, `double`/`float64`,
and the integer types for indices. Faces come as a count-prefixed list; triangulate polygons
with a simple fan (`v0,v1,v2`, `v0,v2,v3`, …). Ignore colour and normal properties but you must
still **skip their bytes correctly** in binary mode, or every vertex after the first is garbage.

**OBJ** — `v` and `f` lines. Handle `f` indices in the forms `i`, `i/j`, `i//k`, `i/j/k`, and
**negative indices**, which are relative to the end of the vertex list. Triangulate polygons
with a fan. Ignore `vt`, `vn`, `mtllib`, `usemtl`, `o`, `g`, `s`.

STL stores no vertex sharing: after loading an STL, run `welded()` so downstream algorithms get
a proper connected mesh.

### Deliverable 3 — `Sources/MeshKit/PointRegistration.swift`

Closed-form rigid registration from corresponding point pairs.

```swift
public struct RegistrationResult: Sendable {
    public let transform: Transform3D    // maps source into target space
    public let rmsErrorMM: Double
    public let maxErrorMM: Double
    public let pointCount: Int
    public let iterations: Int           // 0 for the closed-form solution
    public let converged: Bool
}

public enum PointRegistration {
    /// Optimal rigid transform (rotation + translation, no scaling) aligning `source` onto
    /// `target`. Requires at least 3 non-collinear pairs.
    public static func align(source: [Vec3], target: [Vec3]) throws -> RegistrationResult
}

public enum RegistrationError: Error, Hashable, Sendable, LocalizedError {
    case mismatchedPointCounts(source: Int, target: Int)
    case tooFewPoints(count: Int, required: Int)
    case degenerateConfiguration(detail: String)
    case emptyMesh
    case didNotConverge(iterations: Int, rmsErrorMM: Double)
}
```

**Use Horn's quaternion method, not SVD-based Kabsch.** Two reasons, and state them in the doc
comment:

1. SVD in pure Swift means writing your own decomposition. Horn's method needs only the largest
   eigenvector of a symmetric 4×4 matrix, which the Jacobi eigenvalue algorithm delivers in a
   few dozen lines and converges reliably on symmetric input.
2. Kabsch via SVD can return a **reflection** instead of a rotation when the determinant is
   negative — a mirrored jaw looks superficially plausible and is catastrophic. Horn's method
   produces a unit quaternion and therefore cannot express a reflection at all: the failure
   mode is eliminated by construction rather than patched afterwards.

Algorithm: centre both point sets on their centroids, build the 3×3 cross-covariance matrix,
assemble Horn's symmetric 4×4 matrix `N`, find its eigenvector for the largest eigenvalue by
Jacobi rotations, convert that unit quaternion to a rotation matrix, then recover the
translation as `centroidTarget − R · centroidSource`.

Detect degenerate configurations (all points collinear or coincident) and throw rather than
returning a transform that happens to satisfy the algebra.

### Deliverable 4 — `Sources/MeshKit/ICP.swift`

Iterative closest point refinement.

```swift
public struct ICPOptions: Sendable {
    public var maxIterations: Int          // default 50
    public var toleranceMM: Double         // default 1e-4, stop when RMS improves by less
    public var maxCorrespondenceDistanceMM: Double  // default 2.0
    /// Fraction of best-matching correspondences kept each iteration (trimmed ICP).
    public var trimFraction: Double        // default 0.8
    public var sampleLimit: Int            // default 5000 source points per iteration
    public init()
}

public enum ICP {
    /// Refines `initial` so that `source` best matches `target`.
    public static func refine(
        source: [Vec3],
        target: [Vec3],
        initial: Transform3D,
        options: ICPOptions
    ) throws -> RegistrationResult
}
```

Each iteration: transform the source points, find each one's nearest target point, discard
correspondences beyond `maxCorrespondenceDistanceMM`, keep the best `trimFraction`, solve with
`PointRegistration.align`, compose, and check convergence.

**Two things that decide whether this works in practice, and both need comments saying so:**

- **Trimmed ICP is not optional here.** An intraoral scan covers the crowns; the CBCT surface
  also contains bone, soft tissue, and metal artefacts with no counterpart in the scan. Plain
  ICP drags the alignment toward those unmatched regions. Discarding the worst fifth of
  correspondences each iteration is what keeps the fit on the teeth.
- **ICP only refines.** It converges to the nearest local minimum, so it needs a starting
  transform already close to correct — which is what the point-pair step provides. Say so in
  the doc comment; do not present ICP as something that can align from scratch.

Nearest-neighbour search must not be the naive O(n·m) double loop: with 200k-vertex scans that
is minutes per iteration. Implement a **uniform spatial hash grid** (cell size ≈
`maxCorrespondenceDistanceMM`), built once over the target points, queried over the 27
neighbouring cells. A KD-tree is also acceptable; the grid is simpler and adequate for point
clouds of roughly uniform density, which dental surfaces are.

#### Reaching `maxIterations` is not a failure

**Return the result with `converged == false`. Do not throw.**

Hitting the iteration limit is ordinary: ICP routinely oscillates in the last fraction of a
micron without ever meeting the tolerance, while the alignment itself is excellent. Throwing
would discard both the transform and the RMS — exactly the two things the caller needs in order
to judge the fit. Whether a registration is good enough is a clinical decision made by looking
at the residual, not one an iteration counter can make. The presence of `converged` and
`iterations` in `RegistrationResult` already assumes this: if the function always threw on
non-convergence, `converged` could never be `false` and the field would be dead.

The risk of silently accepting a bad alignment is real, but it belongs to the UI, which must
show the RMS prominently and warn above a threshold — not to an exception that hides the number.

**Do throw `didNotConverge` when the fit is genuinely unusable**, which is a different
situation from merely slow:

- fewer than 3 correspondences survive trimming and the distance cutoff, so no transform can be
  solved at all;
- the RMS increases for 5 consecutive iterations, which means divergence rather than slow
  progress.

In both cases include the iteration count and the last RMS in the error, so the caller can tell
the two apart.

If `PointRegistration.align` itself throws inside an iteration — the surviving correspondences
happen to be collinear, say — let that error propagate as `degenerateConfiguration` rather than
recasting it as `didNotConverge`. The two describe different failures and the caller may want to
react differently: one means the geometry is unusable, the other that the search went nowhere.

### Deliverable 5 — `Sources/MeshKit/RegionMask.swift`

```swift
/// Marks vertices to exclude from registration.
public struct RegionMask: Sendable {
    public init(vertexCount: Int)
    public mutating func exclude(sphereCentreMM: Vec3, radiusMM: Double, vertices: [Vec3])
    public mutating func include(sphereCentreMM: Vec3, radiusMM: Double, vertices: [Vec3])
    public mutating func excludeAll()
    public mutating func includeAll()
    public func isIncluded(_ index: Int) -> Bool
    public func includedPoints(from vertices: [Vec3]) -> [Vec3]
    public var includedCount: Int
}
```

Its purpose, which belongs in the doc comment: metal artefacts from crowns and fillings are the
single most common cause of a bad CBCT-to-scan registration. The user brushes those regions out
before registering, and this is what records the brushing.

### Non-finite coordinates: a crash, not just bad data

A malformed PLY or OBJ can contain `nan` or `inf` coordinates, and STL can too — a Float32 bit
pattern of `0x7FC00000` is a perfectly well-formed 4 bytes that reads as NaN. Range-checking the
bytes does not catch this, because it is a *value* problem rather than a *length* problem.

It matters more than it looks, because **`Int(Double.nan)` traps in Swift** — it is a runtime
crash, not a nil. Any spatial grid that computes a cell index as `Int(coordinate / cellSize)`
therefore crashes the moment a NaN vertex reaches it, which happens in `welded()` and again in
ICP. That contradicts the rule that malformed input must never crash.

Two guards, both required:

1. **At import**, reject vertices whose coordinates are not finite. Use `Vec3.isFinite`. Throw
   `malformed` naming the file and the offending vertex index; do not silently substitute zero,
   which would place a phantom vertex at the origin and quietly distort every subsequent
   measurement.
2. **In the spatial grid**, compute cell indices with `Int(exactly:)` — or check `isFinite`
   before converting — and skip any point that fails. A guard in one place only is not enough:
   meshes also arrive from `Mesh.init` called by application code, not just from the parsers.

Add tests for both: a PLY carrying a NaN coordinate must throw rather than crash, and a `Mesh`
constructed in memory with a NaN vertex must survive `welded()` without trapping.

### Deliverable 6 — Tests in `Tests/MeshKitTests/`

Build all meshes and byte streams **in memory**; no fixture files in the repository. Cover at
least:

- STL binary round trip through `exportSTLBinary` and `load`
- **A binary STL whose 80-byte header begins with the ASCII text `solid`** — this is the
  detection trap and it must be a test, not just a comment
- STL ASCII with irregular whitespace
- PLY ascii, PLY binary little endian, PLY binary big endian
- PLY binary carrying extra per-vertex properties (e.g. colour), verifying the bytes are
  skipped correctly and the coordinates still come out right
- OBJ with `i`, `i/j`, `i//k`, `i/j/k`, negative indices, and a quad that gets triangulated
- truncated files throw instead of crashing
- a corrupt STL declaring a huge triangle count throws instead of allocating
- `welded()` collapses coincident vertices and preserves the surface area
- registration: apply a known rotation and translation to a point set, recover it, expect RMS
  below 1e-9
- registration is a **rotation, never a reflection** — build a case that would tempt an
  SVD implementation into a mirror and assert `determinant > 0`
- registration throws on collinear points
- ICP: perturb a known transform slightly, verify it converges back with RMS below 0.01 mm
- trimmed ICP: add 30% outlier points with no counterpart and verify the fit still recovers the
  transform, which plain ICP would not

### When done

Report: files created, any deviation from this spec and why, and anything you are unsure
compiles. If there are no deviations and no doubts, say so explicitly.

## ▲ Fine del prompt ▲

---

## Terzo lotto, quando questo è chiuso

Anonimizzazione DICOM (GDPR): riscrittura dei tag identificativi secondo il profilo di base
PS3.15 Annex E, con UID rimappati in modo coerente all'interno dello studio — se si generano
UID nuovi a caso, le relazioni fra serie si spezzano e lo studio anonimizzato non si riapre più
come un insieme unico.
