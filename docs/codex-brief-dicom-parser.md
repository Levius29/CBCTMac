# Brief per Codex — Parser DICOM

Da incollare in Codex (o ChatGPT) su una macchina dove funziona. È autosufficiente: contiene
tutte le firme dei tipi esistenti, quindi Codex non ha bisogno di vedere la repo, anche se
averla aiuta.

**Al ritorno**: incolla i file prodotti nella chat, oppure committali su un branch e dimmelo.
Li rivedo prima che entrino in `claude/mac-cbct-dental-app-n84glw` — con nessuno che può
compilare Swift in questo ambiente, la revisione a mano è l'unica rete che abbiamo.

Se Codex ha accesso alla repo, aggiungi in testa al prompt:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi docs/architecture.md e Sources/DICOMCore/ prima di iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS viewer for dental CBCT scans.
Your task: implement a **pure-Swift DICOM parser**. Do not write any other part of the app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **No `simd`, no Metal, no AppKit/UIKit.** Only `Foundation`. This module must compile on
  Linux so `swift test` runs without Xcode.
- **Nobody can compile your output before review.** Write conservative, plain, obviously-correct
  Swift. No clever generics, no macros, no property wrappers, no existential gymnastics. Prefer
  explicit loops over chained higher-order functions where types could be ambiguous. Verify
  every closure's inferred types by hand.
- No `try!`, no `fatalError`, no force-unwraps on parsed input. A malformed DICOM file is
  routine, not a bug. Every failure must name the file and, where relevant, the tag and offset.
- Doc comments in **Italian**, identifiers in **English**. Comments should explain *why*,
  especially where a rule exists because of a real-world trap.
- Guard every read against running past the end of the data. Truncated input must throw, never
  crash or read out of bounds.

### Non-negotiable project contracts

**Slice ordering.** Never sort by `InstanceNumber (0020,0013)` — it is inconsistent across
manufacturers and absent on many CBCT exports. Ordering is done elsewhere by an existing
`SliceSorter` that projects `ImagePositionPatient` onto the slice normal. **Your scanner must
not sort.** Just carry position and orientation through.

**Density terminology.** CBCT values are not Hounsfield units. Never name anything `hu` or
`hounsfield`. The project uses "grey value" / `greyValue`.

**Geometry precision.** All geometry is `Double`. Never `Float`.

### Existing types you must integrate with — do not redefine these

```swift
// Sources/DICOMCore/Geometry.swift
public struct Vec3: Hashable, Sendable, Codable {
    public var x: Double; public var y: Double; public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double)
    public init?(_ values: [Double], offset: Int = 0)   // needs >= offset+3 elements
}

// Sources/DICOMCore/VolumeGeometry.swift
public struct SliceOrientation: Hashable, Sendable, Codable {
    public let columnDirection: Vec3    // first 3 of ImageOrientationPatient
    public let rowDirection: Vec3       // last 3 of ImageOrientationPatient
    public init?(columnDirection: Vec3, rowDirection: Vec3)
    public init?(dicomValues values: [Double])          // takes the 6 tag values
    public var normal: Vec3
}

public struct SliceDescriptor: Hashable, Sendable {
    public let positionMM: Vec3
    public let orientation: SliceOrientation
    public let sourceIndex: Int
    public init(positionMM: Vec3, orientation: SliceOrientation, sourceIndex: Int)
}

// Sources/DICOMCore/TransferSyntax.swift  — COMPLETE, just use it
public enum TransferSyntax: Hashable, Sendable {
    public init(uid: String)
    public var uid: String
    public var isExplicitVR: Bool      // false only for implicitVRLittleEndian
    public var isBigEndian: Bool
    public var isDeflated: Bool
    public var isEncapsulated: Bool    // true for compressed AND for unknown syntaxes
    public var isNativelySupported: Bool
    public var displayName: String
    // cases include: .implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian,
    // .deflatedExplicitVRLittleEndian, .rleLossless, .jpegBaseline8Bit, .jpeg2000Lossless,
    // .unknown(uid: String), and others
}

// Sources/DICOMCore/PixelDecoder.swift  — COMPLETE, just use it
public struct PixelDescriptor: Hashable, Sendable {
    public init(columns: Int, rows: Int, bitsAllocated: Int, bitsStored: Int, highBit: Int,
                isSigned: Bool, samplesPerPixel: Int = 1, frameCount: Int = 1)
    public var pixelsPerFrame: Int
    public var bytesPerFrame: Int
}
public struct DecodedFrame: Sendable {
    public let samples: [Int16]
    public let interceptAdjustment: Double   // add to RescaleIntercept; nonzero for 16-bit unsigned
    public init(samples: [Int16], interceptAdjustment: Double = 0)
}
public protocol PixelDecoder: Sendable {
    func canDecode(_ transferSyntax: TransferSyntax) -> Bool
    func decode(_ data: Data, frameIndex: Int, descriptor: PixelDescriptor,
                transferSyntax: TransferSyntax) throws -> DecodedFrame
}
public struct NativePixelDecoder: PixelDecoder { public init() }
```

### Deliverable 1 — `Sources/DICOMCore/DICOMTag.swift`

- `public struct DICOMTag: Hashable, Sendable, Comparable, CustomStringConvertible` with
  `group: UInt16`, `element: UInt16`. `description` formats as `(0028,0030)`. Sorts by group
  then element.
- `public enum VR: String, Sendable` — all standard VRs: AE AS AT CS DA DS DT FL FD IS LO LT
  OB OD OF OL OV OW PN SH SL SQ SS ST SV TM UC UI UL UN UR US UT UV.
  - `var usesLongLength: Bool` — true for **OB OD OF OL OV OW SQ UC UN UR UT SV UV**. These have
    a 12-byte explicit-VR header (2 reserved + 4-byte length) instead of 8 bytes (2-byte length).
  - `var isStringLike: Bool` for text VRs.
- `public enum DICOMTags` — static constants for the tags used by this project:
  transferSyntaxUID (0002,0010), mediaStorageSOPClassUID (0002,0002), fileMetaGroupLength
  (0002,0000), sopClassUID (0008,0016), sopInstanceUID (0008,0018), modality (0008,0060),
  manufacturer (0008,0070), manufacturerModelName (0008,1090), studyDate (0008,0020),
  studyDescription (0008,1030), seriesDescription (0008,103E), patientName (0010,0010),
  patientID (0010,0020), patientBirthDate (0010,0030), studyInstanceUID (0020,000D),
  seriesInstanceUID (0020,000E), seriesNumber (0020,0011), instanceNumber (0020,0013),
  imagePositionPatient (0020,0032), imageOrientationPatient (0020,0037), frameOfReferenceUID
  (0020,0052), samplesPerPixel (0028,0002), photometricInterpretation (0028,0004),
  numberOfFrames (0028,0008), rows (0028,0010), columns (0028,0011), pixelSpacing (0028,0030),
  bitsAllocated (0028,0100), bitsStored (0028,0101), highBit (0028,0102), pixelRepresentation
  (0028,0103), windowCenter (0028,1050), windowWidth (0028,1051), rescaleIntercept (0028,1052),
  rescaleSlope (0028,1053), rescaleType (0028,1054), sliceThickness (0018,0050),
  spacingBetweenSlices (0018,0088), kvp (0018,0060), pixelData (7FE0,0010),
  item (FFFE,E000), itemDelimitation (FFFE,E00D), sequenceDelimitation (FFFE,E0DD).

### Deliverable 2 — `Sources/DICOMCore/DICOMDataset.swift`

- `public struct DICOMElement: Sendable` — `tag`, `vr`, raw value bytes as `Data`.
- `public struct DICOMDataset: Sendable` — elements in file order plus lookup by tag.
  Accessors, all Optional-returning, never trapping:
  - `string(_:) -> String?` — trims trailing NUL and spaces
  - `strings(_:) -> [String]?` — splits on backslash
  - `double(_:) -> Double?`, `doubles(_:) -> [Double]?`
  - `int(_:) -> Int?`, `ints(_:) -> [Int]?`
  - `vec3(_:) -> Vec3?`
  - `subscript(tag: DICOMTag) -> DICOMElement?`
  - `var allElements: [DICOMElement]` in file order, for a future tag inspector

  **Critical:** numeric values arrive either as text (DS/IS — the normal case for `PixelSpacing`
  and `ImagePositionPatient`) or as binary (US/SS/UL/SL/FL/FD — the normal case for `Rows`,
  `Columns`, `BitsAllocated`). Handle both, keyed off the element's VR, respecting byte order
  for the binary ones. Getting this wrong yields plausible-looking wrong geometry.

### Deliverable 3 — `Sources/DICOMCore/DICOMParser.swift`

```swift
public enum ParseDepth: Sendable { case metadataOnly, includingPixelData }

public struct ParsedFile: Sendable {
    public let dataset: DICOMDataset
    public let transferSyntax: TransferSyntax
    public let pixelDataRange: Range<Int>?     // byte range in the source Data; nil if absent
    public let isEncapsulatedPixelData: Bool
}

public struct DICOMParser {
    public static func parse(data: Data, depth: ParseDepth, sourceName: String) throws -> ParsedFile
    public static func parse(url: URL, depth: ParseDepth) throws -> ParsedFile
}
```

Rules, in order:

1. **Preamble**: 128 bytes, then ASCII `DICM`. If `DICM` is absent at offset 128, retry from
   offset 0 as a headerless dataset in Implicit VR Little Endian — some older CBCT exports and
   extracted datasets lack the preamble. If that also fails to yield a plausible first tag, throw.
2. **File meta group (0002)**: always Explicit VR Little Endian regardless of what follows. Use
   `(0002,0000)` group length if present to find where it ends; otherwise stop at the first tag
   with group != 0x0002.
3. Read `(0002,0010)` → `TransferSyntax(uid:)`. Default `.implicitVRLittleEndian` if absent.
4. If `transferSyntax.isDeflated`, throw `.deflatedNotSupported` — do not attempt to inflate,
   zlib availability is not guaranteed cross-platform, and producing garbage is worse than
   failing clearly.
5. **Main dataset** with the VR mode and endianness from the transfer syntax.
   - Explicit: tag(4) + VR(2) + [long form: reserved(2) + length(4)] or [short: length(2)]
   - Implicit: tag(4) + length(4); infer VR from your `DICOMTags` table, `.UN` for unknown tags.
     Note: in implicit VR, `(7FE0,0010) PixelData` is **OW**.
6. **Sequences (SQ)** — you must handle these or the parser desynchronises and everything after
   a sequence is garbage. Handle both defined length (skip `length` bytes) and undefined length
   `0xFFFFFFFF` (scan items `(FFFE,E000)` until `(FFFE,E0DD)`, tracking nesting depth). Record
   the element with empty value data and move past it; add a `// TODO` noting a future tag
   inspector may want the contents.
7. **Undefined-length PixelData** (encapsulated): length `0xFFFFFFFF`, content is a Basic Offset
   Table item followed by fragment items, terminated by `(FFFE,E0DD)`. Record the full byte
   range from the first item to just before the delimiter, set `isEncapsulatedPixelData = true`,
   do not decode.
8. In `.metadataOnly`, stop the moment you reach `(7FE0,0010)`: record its range and return.
   This is what makes scanning a folder of 800 files fast.

`public enum DICOMParsingError: Error, Hashable, Sendable` with at least:
`notDICOM(sourceName:)`, `truncated(sourceName:atOffset:)`,
`unexpectedTag(sourceName:tag:atOffset:)`, `deflatedNotSupported(sourceName:)`,
`missingRequiredTag(sourceName:tag:)` — each with `localizedDescription` in Italian naming the
file and, where relevant, tag and offset.

### Deliverable 4 — `Sources/DICOMCore/DICOMScanner.swift`

```swift
public struct ScannedInstance: Sendable {
    public let url: URL
    public let sopInstanceUID: String
    public let seriesInstanceUID: String
    public let studyInstanceUID: String
    public let instanceNumber: Int?
    public let positionMM: Vec3?
    public let orientation: SliceOrientation?
}

public struct PixelSpacing: Hashable, Sendable {   // named struct, not a tuple
    public let rowMM: Double        // PixelSpacing[0] — vertical, between rows
    public let columnMM: Double     // PixelSpacing[1] — horizontal, between columns
}

public struct ScannedSeries: Sendable {
    public let seriesInstanceUID: String
    public let seriesNumber: Int?
    public let description: String?
    public let modality: String?
    public let instances: [ScannedInstance]      // NOT sorted
    public let rows: Int?
    public let columns: Int?
    public let pixelSpacingMM: PixelSpacing?
    public let sliceThicknessMM: Double?
}

public struct ScannedStudy: Sendable { /* studyInstanceUID, date, description, series */ }
public struct ScannedPatient: Sendable { /* patientID, name, studies */ }

public struct ScanResult: Sendable {
    public let patients: [ScannedPatient]
    public let failures: [(url: URL, reason: String)]   // use a named struct if needed
}

public struct DICOMScanner {
    public static func scan(directory: URL,
                            progress: (@Sendable (Int, Int) -> Void)?) throws -> ScanResult
}
```

- Walk the directory recursively.
- Skip non-DICOM files instead of failing the whole scan; collect per-file failures.
- Use `.metadataOnly` — never touch pixel bytes.
- Group patient → study → series.
- **Do not sort slices.** That is `SliceSorter`'s job.
- Keep non-image series (Modality `SR`, `PR`, `KO`) listed but flag them as non-image.

### Deliverable 5 — Tests in `Tests/DICOMCoreTests/`

Build DICOM byte streams **in memory** — no fixture files on disk. Write a
`DICOMByteStreamBuilder` helper so tests read clearly. Cover at least:

- explicit VR little endian round trip
- implicit VR little endian, including PixelData inferred as OW
- a defined-length sequence, verifying elements *after* it still parse
- an undefined-length **nested** sequence, same check
- truncated file throws rather than crashing
- missing `DICM` magic: headerless fallback works, or throws cleanly
- `doubles()` on a `DS` multi-value `"0.2\\0.2"` and on a binary `US`
- `metadataOnly` stops at PixelData and reports the correct range

### When done

Report: files created, anything where you deviated from this spec and why, and anything you
are unsure compiles.

## ▲ Fine del prompt ▲

---

## Secondo lotto, se il primo va liscio

`VolumeBuilder.swift` — assembla un `Volume` da una `ScannedSeries`. Ha una trappola che vale la
pena segnalare esplicitamente a Codex: `DecodedFrame.interceptAdjustment` va **sommato** a
`RescaleIntercept` moltiplicato per lo slope, cioè `intercept += adjustment × slope`. È la
compensazione della traslazione applicata ai dati senza segno a 16 bit, che altrimenti sfalsa
tutte le densità di una costante — un errore che non altera per nulla l'aspetto dell'immagine.
