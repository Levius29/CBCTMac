# Brief per Codex — Decoder per pixel compressi, in Swift puro

Terzo lotto. Stessa modalità: copia il blocco fra i marcatori, incollalo in Codex, poi rivedo
prima del merge.

**Perché questo, e perché adesso.** L'applicazione oggi rifiuta i DICOM compressi con
`VolumeBuildError.unsupportedCompression`. Diversi apparecchi CBCT comprimono in uscita, quindi
è probabile che la prima CBCT reale sbatta esattamente lì. Con RLE e JPEG Lossless in Swift puro
si copre la gran parte degli export compressi **senza integrare DCMTK**, che significa nessuna
dipendenza C++, nessuna catena di build nativa, e i decoder verificabili con `swift test` su
qualunque piattaforma.

Se Codex ha accesso alla repo, premetti:
`Repo: https://github.com/Levius29/CBCTMac, branch claude/mac-cbct-dental-app-n84glw.
Leggi Sources/DICOMCore/PixelDecoder.swift e TransferSyntax.swift prima di iniziare.`

---

## ▼ Da qui in giù, copia tutto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT application. Your task:
implement **pure-Swift decoders for compressed DICOM pixel data** — RLE Lossless and JPEG
Lossless — plus the encapsulated-fragment handling that feeds them. Do not write any other part
of the app.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **Only `Foundation`.** No `simd`, no Metal, no AppKit, no third-party dependencies, no C
  interop. This module compiles and tests on Linux.
- No `try!`, no `fatalError`, no force-unwraps on parsed input. Compressed pixel data from a
  real scanner is frequently slightly off-spec; malformed input must throw, never crash, never
  read out of bounds.
- **All geometry and sample handling in exact integer arithmetic.** These are lossless codecs:
  a decoded frame must be bit-exact, and any rounding is a bug.
- Doc comments in **Italian**, identifiers in **English**. Explain *why*, especially at the traps
  named below.

### Existing types you must integrate with — do not redefine

```swift
// Sources/DICOMCore/PixelDecoder.swift
public struct PixelDescriptor: Hashable, Sendable {
    public let columns: Int
    public let rows: Int
    public let bitsAllocated: Int      // 8 or 16
    public let bitsStored: Int         // often 12–16 on CBCT
    public let highBit: Int
    public let isSigned: Bool          // PixelRepresentation == 1
    public let samplesPerPixel: Int    // 1 for greyscale
    public let frameCount: Int
    public init(columns: Int, rows: Int, bitsAllocated: Int, bitsStored: Int, highBit: Int,
                isSigned: Bool, samplesPerPixel: Int = 1, frameCount: Int = 1)
    public var pixelsPerFrame: Int
    public var bytesPerSample: Int
    public var bytesPerFrame: Int
}

public struct DecodedFrame: Sendable {
    public let samples: [Int16]
    /// Da sommare a RescaleIntercept, moltiplicato per lo slope. Vale 32768 quando dati
    /// senza segno a 16 bit sono stati traslati per entrare in Int16.
    public let interceptAdjustment: Double
    public init(samples: [Int16], interceptAdjustment: Double = 0)
}

public protocol PixelDecoder: Sendable {
    func canDecode(_ transferSyntax: TransferSyntax) -> Bool
    func decode(_ data: Data, frameIndex: Int, descriptor: PixelDescriptor,
                transferSyntax: TransferSyntax) throws -> DecodedFrame
}

public enum PixelDecodingError: Error, Hashable, Sendable {
    case unsupportedTransferSyntax(TransferSyntax)
    case unsupportedBitsAllocated(Int)
    case unsupportedSamplesPerPixel(Int)
    case truncatedPixelData(expected: Int, available: Int)
    case frameIndexOutOfRange(Int, frameCount: Int)
    case invalidDescriptor(String)
    // Aggiungi i casi che ti servono, con localizedDescription in italiano.
}

// TransferSyntax espone: .rleLossless, .jpegLosslessNonHierarchical (processo 14),
// .jpegLosslessNonHierarchicalSV1 (processo 14 SV1), .isEncapsulated, .displayName, .uid
```

Study `NativePixelDecoder` in the same file: it handles the uncompressed syntaxes and shows the
house style for masking `BitsStored`, sign-extending, and the −32768 shift for unsigned 16-bit
data. **Your decoders must apply the same normalisation to their output**, so a caller cannot
tell from `DecodedFrame` whether the source was compressed.

### Deliverable 1 — `Sources/DICOMCore/EncapsulatedPixelData.swift`

Encapsulated pixel data is not one blob: it is a sequence of items. Parsing it is a prerequisite
for both decoders.

```swift
public struct EncapsulatedPixelData: Sendable {
    /// Byte ranges of the fragments, in file order, excluding item headers.
    public let fragments: [Range<Int>]
    /// Basic Offset Table entries, if present and non-empty.
    public let basicOffsetTable: [UInt32]

    public static func parse(_ data: Data, sourceName: String) throws -> EncapsulatedPixelData

    /// Concatenated bytes of the fragments belonging to one frame.
    public func frameData(_ data: Data, frameIndex: Int, frameCount: Int) throws -> Data
}
```

Layout: the first item is the Basic Offset Table — often **empty, length zero**, which is legal.
Then one or more fragment items. Terminated by `(FFFE,E0DD)`.

> **The trap that decides whether multi-frame files work.** A frame is not always one fragment.
> Encoders may split a single frame across several fragments, and some emit one fragment per
> frame. Resolve it in this order:
> 1. If the Basic Offset Table is non-empty, use it: entry *n* is the byte offset of frame *n*'s
>    first fragment, measured from the first byte after the BOT item. This is authoritative.
> 2. Otherwise, if `fragments.count == frameCount`, assume one fragment per frame.
> 3. Otherwise, if `frameCount == 1`, concatenate every fragment.
> 4. Otherwise throw: guessing produces a frame assembled from the wrong bytes, which decodes
>    into plausible-looking noise rather than an error.

### Deliverable 2 — `Sources/DICOMCore/RLEPixelDecoder.swift`

DICOM RLE Lossless, PS3.5 Annex G. A `PixelDecoder` handling `.rleLossless`.

Each frame begins with a 64-byte header: `UInt32` segment count, then 15 `UInt32` segment
offsets, all little endian. Each segment is PackBits-encoded: a control byte *n* where
`0...127` means "the next n+1 bytes are literal", and `129...255` means "repeat the next byte
257−n times". The value `128` is a no-op.

> **The trap that makes 16-bit images look like static.** For 16-bit data the segments are not
> interleaved samples — they are **byte planes**. Segment 0 holds the *most significant* byte of
> every sample, segment 1 the *least significant*. You must decode both segments fully and then
> recombine them per sample: `value = (msb << 8) | lsb`. Treating the segments as consecutive
> sample runs produces an image that is recognisable in outline and completely wrong in value,
> which is the worst kind of wrong.
>
> For `samplesPerPixel > 1` the plane count multiplies accordingly, but this project only needs
> greyscale: throw `unsupportedSamplesPerPixel` for anything else rather than guessing an order.

Validate the segment count against `bytesPerSample`, and every offset against the available
bytes, before allocating.

### Deliverable 3 — `Sources/DICOMCore/JPEGLosslessDecoder.swift`

JPEG Lossless per ITU-T T.81, process 14, both the general form and SV1. A `PixelDecoder`
handling `.jpegLosslessNonHierarchical` and `.jpegLosslessNonHierarchicalSV1`. This is the
compressed syntax that appears most often in DICOM.

Marker parsing: `SOI (FFD8)`, `SOF3 (FFC3)` — lossless sequential Huffman — `DHT (FFC4)`,
`SOS (FFDA)`, `DRI (FFDD)`, `EOI (FFD9)`. Skip `APPn` and `COM` by their length. Reject `SOF0`,
`SOF1`, `SOF2` and the arithmetic-coded `SOF` markers with a clear error: they are different
codecs, and silently attempting them yields garbage.

From `SOF3` read precision (2–16 bits), height, width, and the component list. From `SOS` read
the component-to-table mapping, the **predictor selector `Ss`**, and `Al` (point transform).

Decoding, per component and per line:

1. Huffman-decode a category `S` from the DC table.
2. If `S == 0` the difference is 0; if `S == 16` the difference is 32768; otherwise read `S`
   raw bits and apply the T.81 extension: if the value is below `1 << (S-1)`, add
   `(-1 << S) + 1`.
3. Compute the prediction `Px` from the neighbours `Ra` (left), `Rb` (above), `Rc`
   (above-left) according to `Ss`:
   `1: Ra` · `2: Rb` · `3: Rc` · `4: Ra+Rb−Rc` · `5: Ra+((Rb−Rc)>>1)` ·
   `6: Rb+((Ra−Rc)>>1)` · `7: (Ra+Rb)>>1`. `Ss == 0` is not valid for lossless.
4. The sample is `(Px + difference)` masked to the precision.

> **Three traps, each of which produces a whole broken image rather than a local artefact.**
>
> - **Byte stuffing.** Inside the entropy-coded stream a literal `0xFF` byte is written as
>   `0xFF 0x00`. The bit reader must consume the `0x00` and yield only the `0xFF`. Any other
>   `0xFF xx` pair is a marker and ends the scan. Getting this wrong desynchronises the bit
>   stream at the first bright pixel run and everything after it is noise.
> - **Line and image start predictors.** The first sample of the **first** line has no
>   neighbours: `Px = 1 << (precision - 1)`. The first sample of every **subsequent** line uses
>   `Px = Rb`, the sample directly above — *not* the selected predictor, and not `Ra` from the
>   previous line's end. This single rule, if missed, tilts or streaks the image in a way that
>   looks like a scanner artefact rather than a bug.
> - **Restart markers.** If `DRI` set a non-zero interval, `RSTn (FFD0–FFD7)` markers appear
>   every *n* MCUs. At each one, reset the bit reader to a byte boundary **and** reset the
>   predictors as if starting a new line. Ignoring them desynchronises the stream partway down
>   the image.
>
> Build the Huffman tables from the `BITS`/`HUFFVAL` arrays exactly as T.81 Annex C specifies.
> A lookup structure is welcome, but correctness first.

### Deliverable 4 — `Sources/DICOMCore/CompositePixelDecoder.swift`

```swift
/// Instrada verso il decoder adatto alla sintassi.
public struct CompositePixelDecoder: PixelDecoder {
    public init(decoders: [any PixelDecoder] = [
        NativePixelDecoder(), RLEPixelDecoder(), JPEGLosslessDecoder(),
    ])
}
```

It must pick the first decoder whose `canDecode` returns true, and throw
`unsupportedTransferSyntax` when none does. For encapsulated syntaxes it is responsible for
extracting the correct frame via `EncapsulatedPixelData` before handing bytes to the decoder, so
the individual decoders receive one frame's bytes and nothing else.

Make `CompositePixelDecoder()` the default value of the `decoder` parameter in
`VolumeBuilder.build(series:decoder:progress:)` — that one-word change is what actually lets the
application open compressed studies.

### Deliverable 5 — Tests in `Tests/DICOMCoreTests/`

Build every byte stream **in memory**. No fixture files in the repository. Because these are
lossless codecs, the assertions must be **bit-exact equality**, never approximate.

Cover at least:

- **RLE round trip**: write a small PackBits encoder in the test helper, encode a known 8-bit
  image, decode, assert exact equality.
- **RLE 16-bit byte planes**: a known 16-bit image whose high and low bytes differ markedly, so
  that swapping the planes or interleaving them produces a visibly different result. Assert
  exact equality. This is the trap test.
- **RLE literal runs, repeat runs, and the 128 no-op** all in one segment.
- **RLE with a corrupt segment offset** throws instead of reading out of bounds.
- **JPEG Lossless**: hand-assemble a minimal SOF3 stream for a small image — a few pixels is
  enough — with a hand-computed Huffman table, and assert the decoded samples exactly.
- **JPEG byte stuffing**: an image whose entropy stream necessarily contains `FF 00`. Assert
  exact equality; a failure here is the stuffing rule.
- **JPEG predictors**: one test per selector 1 through 7, each on a gradient small enough to
  verify by hand.
- **JPEG first-sample-of-line predictor**: an image at least 3×3 where using the selected
  predictor instead of `Rb` at column 0 would give a different answer.
- **JPEG restart markers** with a small `DRI` interval.
- **JPEG rejects SOF0** with a clear error.
- **Encapsulated fragments**: one fragment per frame; multiple fragments for a single frame;
  a non-empty Basic Offset Table; and the ambiguous case that must throw.
- **BitsStored normalisation**: a 12-bit-stored image inside 16 bits allocated comes back masked
  and sign-extended identically to what `NativePixelDecoder` would produce for the same values.

### When done

Report: files created, any deviation from this spec and why, and anything you are unsure
compiles. If there are no deviations and no doubts, say so explicitly.

## ▲ Fine del prompt ▲

---

## In coda, dopo questo

**JPEG 2000.** È la sintassi compressa restante e non è affrontabile con lo stesso metodo: un
decoder JPEG 2000 conforme è un progetto in sé, non un file. Se dopo RLE e JPEG Lossless
resteranno file che non si aprono, allora e solo allora vale la pena valutare DCMTK con
OpenJPEG, sapendo che porta con sé una catena di build C++.

**Anonimizzazione DICOM (GDPR).** Profilo di base PS3.15 Annex E, con gli UID rimappati in modo
**coerente all'interno dello studio**: se si generano UID nuovi a caso, le relazioni fra serie si
spezzano e lo studio anonimizzato non si riapre più come un insieme unico.

**GuideKit, Fase 5.** Le dime chirurgiche ed endodontiche. Ora che MeshKit esiste, una via in
Swift puro è praticabile: campo di distanza con segno dalla mesh, offset e spessore sul campo
invece che sulle normali — l'offset lungo le normali produce auto-intersezioni sistematiche —
poi marching cubes per tornare a una superficie. Le operazioni booleane con la boccola diventano
combinazioni di campi, che è più robusto di un kernel CSG su triangoli. Merita un brief a sé.
