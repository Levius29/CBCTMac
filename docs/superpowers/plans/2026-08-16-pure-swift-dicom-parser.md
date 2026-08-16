# Pure Swift DICOM Parser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implementare i cinque deliverable del brief DICOM: tag/VR, dataset, parser, scanner ricorsivo e test con stream costruiti in memoria.

**Architecture:** Un cursore privato legge `Data` byte per byte con controllo preventivo dei limiti. `DICOMElement` conserva internamente l'endianness del proprio valore, il parser separa file meta e dataset principale, e lo scanner usa soltanto `metadataOnly` senza ordinare le istanze.

**Tech Stack:** Swift 6, Swift Package Manager, Foundation, XCTest, Linux.

## Global Constraints

- Swift 6 language mode e strict concurrency; tutti i tipi pubblici sono `Sendable`.
- Solo Foundation: niente `simd`, Metal, AppKit o UIKit.
- Nessun `try!`, `fatalError` o force unwrap su dati analizzati.
- Ogni lettura controlla i limiti e ogni errore nomina il file; tag e offset compaiono quando pertinenti.
- Doc comment in italiano e identificatori in inglese.
- Geometria esclusivamente in `Double`; nessun identificatore relativo alle densità usa termini vietati dal contratto.
- Lo scanner non ordina mai le slice e non usa `InstanceNumber` come chiave d'ordine.
- Non si ridefiniscono `Vec3`, `SliceOrientation`, `SliceDescriptor`, `TransferSyntax`, `PixelDescriptor`, `DecodedFrame`, `PixelDecoder` o `NativePixelDecoder`.
- Non si modifica alcun file dell'applicazione, di MeasureKit o di VolumeKit.

---

### Task 1: Tag, VR e dataset tipizzato

**Files:**
- Create: `Sources/DICOMCore/DICOMTag.swift`
- Create: `Sources/DICOMCore/DICOMDataset.swift`
- Create: `Tests/DICOMCoreTests/DICOMTagDatasetTests.swift`

**Interfaces:**
- Consumes: `Vec3.init?(_:offset:)` da `Geometry.swift`.
- Produces: `DICOMTag`, `VR`, `DICOMTags`, `DICOMElement`, `DICOMDataset` e tutti gli accessor richiesti dal brief.

- [ ] **Step 1: Scrivere i test fallenti per tag, VR e valori numerici**

Creare una suite XCTest che dimostri formattazione/ordinamento, DS multivalore e US/SS/UL/SL/FL/FD binari. Le attese devono essere letterali:

```swift
func testDecimalStringValues() throws {
    let element = DICOMElement(
        tag: DICOMTags.pixelSpacing,
        vr: .DS,
        value: Data("0.2\\0.2 ".utf8))
    let dataset = DICOMDataset(elements: [element])
    let values = try XCTUnwrap(dataset.doubles(DICOMTags.pixelSpacing))
    XCTAssertEqual(values, [0.2, 0.2])
}

func testUnsignedShortValues() {
    let element = DICOMElement(
        tag: DICOMTags.rows,
        vr: .US,
        value: Data([0x00, 0x02]))
    let dataset = DICOMDataset(elements: [element])
    XCTAssertEqual(dataset.ints(DICOMTags.rows), [512])
    XCTAssertEqual(dataset.doubles(DICOMTags.rows), [512.0])
}
```

- [ ] **Step 2: Verificare il RED**

Run: `swift test --filter DICOMTagDatasetTests`
Expected: compilazione fallita perché `DICOMTag`, `DICOMElement` e `DICOMDataset` non esistono.

- [ ] **Step 3: Implementare `DICOMTag.swift`**

Usare confronto esplicito e switch esaustivi:

```swift
public static func < (lhs: DICOMTag, rhs: DICOMTag) -> Bool {
    if lhs.group != rhs.group { return lhs.group < rhs.group }
    return lhs.element < rhs.element
}

public var description: String {
    String(format: "(%04X,%04X)", group, element)
}
```

Definire tutti i VR elencati nel brief, i due switch `usesLongLength` e `isStringLike`, tutte le costanti pubbliche e una funzione interna `DICOMTags.inferredVR(for:)` con PixelData `.OW` e `.UN` per tag sconosciuti.

- [ ] **Step 4: Implementare `DICOMDataset.swift`**

`DICOMElement` espone `tag`, `vr`, `value` e usa un campo interno `isBigEndian`. Il dataset costruisce il lookup con un ciclo esplicito. Le letture binarie assemblano i byte senza load non allineati:

```swift
private func uint16(_ bytes: Data, at offset: Int, bigEndian: Bool) -> UInt16? {
    guard offset >= 0, offset <= bytes.count, bytes.count - offset >= 2 else { return nil }
    let first = UInt16(bytes[bytes.startIndex + offset])
    let second = UInt16(bytes[bytes.startIndex + offset + 1])
    return bigEndian ? (first << 8) | second : (second << 8) | first
}
```

Applicare lo stesso schema a 32 e 64 bit. Convertire FL direttamente dal formato IEEE-754 binary32 a `Double`, senza introdurre valori `Float`; convertire FD con `Double(bitPattern:)`. Ogni array binario richiede una lunghezza multipla della larghezza del VR. `int(_:)` accetta soltanto conversioni esatte.

- [ ] **Step 5: Verificare il GREEN e l'assenza di regressioni**

Run: `swift test --filter DICOMTagDatasetTests`
Expected: tutti i test della suite passano.
Run: `swift test`
Expected: tutte le suite esistenti e nuove passano senza warning.

- [ ] **Step 6: Commit del task**

```bash
git add Sources/DICOMCore/DICOMTag.swift Sources/DICOMCore/DICOMDataset.swift Tests/DICOMCoreTests/DICOMTagDatasetTests.swift
git commit -m "feat: add DICOM tags and typed dataset"
```

### Task 2: Builder di test e parsing dei dataset nativi

**Files:**
- Create: `Sources/DICOMCore/DICOMParser.swift`
- Create: `Tests/DICOMCoreTests/DICOMByteStreamBuilder.swift`
- Create: `Tests/DICOMCoreTests/DICOMParserTests.swift`

**Interfaces:**
- Consumes: `DICOMTags.inferredVR(for:)`, `DICOMDataset`, `TransferSyntax`.
- Produces: `ParseDepth`, `ParsedFile`, `DICOMParsingError`, `DICOMParser.parse(data:depth:sourceName:)` e `parse(url:depth:)`.

- [ ] **Step 1: Scrivere il builder di stream test-only**

Il builder mantiene `[UInt8]`, offre append espliciti LE/BE, preambolo, elementi Explicit/Implicit e restituisce il range del valore appena scritto:

```swift
mutating func appendExplicit(
    tag: DICOMTag, vr: VR, value: [UInt8], bigEndian: Bool = false
) -> Range<Int> {
    appendTag(tag, bigEndian: bigEndian)
    bytes.append(contentsOf: Array(vr.rawValue.utf8))
    if vr.usesLongLength {
        bytes.append(0)
        bytes.append(0)
        appendUInt32(UInt32(value.count), bigEndian: bigEndian)
    } else {
        appendUInt16(UInt16(value.count), bigEndian: bigEndian)
    }
    let start = bytes.count
    bytes.append(contentsOf: value)
    return start..<bytes.count
}
```

Il builder effettua il padding pari per UI con NUL e per VR testuali con spazio.

- [ ] **Step 2: Scrivere i test fallenti per preambolo, file meta, Explicit e Implicit VR**

Creare test distinti che rilevino le seguenti mutazioni: ignorare TransferSyntax, interpretare Implicit come Explicit, non applicare il fallback headerless e leggere oltre un valore troncato.

```swift
func testExplicitLittleEndianRoundTrip() throws {
    var builder = DICOMByteStreamBuilder()
    builder.appendPreamble()
    builder.appendUID(tag: DICOMTags.transferSyntaxUID, "1.2.840.10008.1.2.1")
    builder.appendExplicit(tag: DICOMTags.sopInstanceUID, vr: .UI, value: builder.paddedUI("1.2.3.4"))
    builder.appendExplicit(tag: DICOMTags.rows, vr: .US, value: [0x00, 0x02])
    let parsed = try DICOMParser.parse(
        data: builder.data, depth: .includingPixelData, sourceName: "explicit.dcm")
    XCTAssertEqual(parsed.transferSyntax, .explicitVRLittleEndian)
    XCTAssertEqual(parsed.dataset.string(DICOMTags.sopInstanceUID), "1.2.3.4")
    XCTAssertEqual(parsed.dataset.int(DICOMTags.rows), 512)
}
```

Includere test per headerless Implicit valido, byte casuali → `notDICOM`, deflated → `deflatedNotSupported`, group length del file meta e troncamento con offset verificato dal case dell'enum.

- [ ] **Step 3: Verificare il RED**

Run: `swift test --filter DICOMParserTests`
Expected: compilazione fallita perché `DICOMParser` non esiste.

- [ ] **Step 4: Implementare cursore, errori e file meta**

Il cursore contiene `data`, `offset`, `sourceName`, `bigEndian` e metodi throwing per `readUInt8/16/32`, `readTag`, `readData(count:)` e `skip(count:)`. Ogni metodo usa la forma:

```swift
guard count >= 0, offset >= 0, offset <= data.count, data.count - offset >= count else {
    throw DICOMParsingError.truncated(sourceName: sourceName, atOffset: offset)
}
```

Il parser riconosce `DICM`, convalida il primo header headerless, legge il gruppo 0002 in Explicit VR Little Endian e usa il group length dal byte successivo al valore UL. L'assenza del transfer syntax usa `.implicitVRLittleEndian`.

- [ ] **Step 5: Implementare header e valori del dataset principale**

Creare un `ElementHeader` privato con tag, VR, length, headerOffset e valueOffset. Explicit VR seleziona 2 o 4 byte dalla proprietà del VR; Implicit usa `inferredVR`. Le lunghezze definite vengono convalidate prima del `Data`.

PixelData definito produce `pixelDataRange`. Con `.metadataOnly`, aggiungere un elemento PixelData vuoto e restituire senza copiare il range; con `.includingPixelData`, memorizzare i byte.

- [ ] **Step 6: Verificare il GREEN e commit**

Run: `swift test --filter DICOMParserTests`
Expected: test nativi, fallback e troncamento passano.
Run: `swift test`
Expected: zero fallimenti.

```bash
git add Sources/DICOMCore/DICOMParser.swift Tests/DICOMCoreTests/DICOMByteStreamBuilder.swift Tests/DICOMCoreTests/DICOMParserTests.swift
git commit -m "feat: parse native DICOM datasets"
```

### Task 3: Sequenze e PixelData incapsulato

**Files:**
- Modify: `Sources/DICOMCore/DICOMParser.swift`
- Modify: `Tests/DICOMCoreTests/DICOMByteStreamBuilder.swift`
- Modify: `Tests/DICOMCoreTests/DICOMParserTests.swift`

**Interfaces:**
- Consumes: header parser e cursore del Task 2.
- Produces: sincronizzazione oltre SQ definite/indefinite e range dei fragment incapsulati.

- [ ] **Step 1: Scrivere i test fallenti per SQ definita e SQ indefinita annidata**

Usare un tag di sequenza esplicito `(0008,1115)`. Il test annidato costruisce: outer SQ indefinita → item indefinito → inner SQ indefinita → item definito vuoto → sequence delimiter → item delimiter → sequence delimiter → `Modality`. Entrambi i test verificano `dataset.string(DICOMTags.modality) == "CT"`.

- [ ] **Step 2: Scrivere il test fallente per PixelData indefinito**

Costruire Basic Offset Table vuota, due fragment item e sequence delimiter. Verificare che il range inizi sul primo item, termini prima del delimiter, `isEncapsulatedPixelData` sia vero e non avvenga decodifica.

- [ ] **Step 3: Verificare il RED**

Run: `swift test --filter DICOMParserTests`
Expected: i test nuovi falliscono perché il parser non salta correttamente le lunghezze indefinite.

- [ ] **Step 4: Implementare lo stack dei contenitori**

Usare un array privato di enum concrete, senza ricorsione:

```swift
private enum UndefinedContainer {
    case sequence
    case item
}
```

Ogni item legge tag e lunghezza nel formato speciale 4+4. Un item definito viene saltato dopo il controllo; un item indefinito aggiunge `.item`; una SQ indefinita aggiunge `.sequence`; i delimiter devono corrispondere alla cima dello stack. Il parser registra SQ con `Data()` e include esattamente il commento richiesto:

```swift
// TODO: un futuro tag inspector potrebbe conservare il contenuto della sequenza.
```

- [ ] **Step 5: Implementare lo scanner dei fragment**

Accettare soltanto `Item` con lunghezza definita e `SequenceDelimitation` con lunghezza zero. Il range è `firstItemOffset..<delimiterOffset`; input troncati o tag diversi producono l'errore con offset.

- [ ] **Step 6: Verificare GREEN, regressioni e commit**

Run: `swift test --filter DICOMParserTests`
Expected: tutti i test parser passano.
Run: `swift test`
Expected: zero fallimenti.

```bash
git add Sources/DICOMCore/DICOMParser.swift Tests/DICOMCoreTests/DICOMByteStreamBuilder.swift Tests/DICOMCoreTests/DICOMParserTests.swift
git commit -m "feat: handle DICOM sequences and fragments"
```

### Task 4: Scanner ricorsivo e gerarchia clinica

**Files:**
- Create: `Sources/DICOMCore/DICOMScanner.swift`
- Create: `Tests/DICOMCoreTests/DICOMScannerTests.swift`

**Interfaces:**
- Consumes: `DICOMParser.parse(url:depth:)`, accessor del dataset, `Vec3`, `SliceOrientation`.
- Produces: tutti i tipi `Scanned*`, `PixelSpacing`, `ScanFailure`, `ScanResult`, `DICOMScanner.scan(directory:progress:)`.

- [ ] **Step 1: Scrivere test fallenti di raggruppamento e serie non-image**

Generare in memoria due istanze CT con `InstanceNumber` 20 e 10 nell'ordine di creazione, più una serie SR. Scrivere i byte in una directory temporanea creata dal test. Verificare gerarchia, geometria `Double`, `isImageSeries == false` per SR e che la sequenza delle istanze CT conservi l'ordine incontrato anziché diventare `[10, 20]`.

- [ ] **Step 2: Scrivere test fallenti per file estranei e DICOM malformato**

Un file di testo casuale non compare in `failures`; un DICOM con magic ma valore troncato produce un solo `ScanFailure` contenente nome file e offset. Verificare anche le chiamate progress `(0,total)` e l'ultima `(total,total)` con un recorder test-only `@unchecked Sendable` che protegge il proprio array tramite `NSLock`; la closure `@Sendable` cattura soltanto il recorder.

- [ ] **Step 3: Verificare il RED**

Run: `swift test --filter DICOMScannerTests`
Expected: compilazione fallita perché `DICOMScanner` e i tipi scanner non esistono.

- [ ] **Step 4: Implementare i tipi pubblici e l'enumerazione**

Definire initializer pubblici espliciti. Usare `FileManager.contentsOfDirectory(at:includingPropertiesForKeys:options:)` con una pila di URL e cicli espliciti. Non invocare `sorted`, `sort` o `InstanceNumber` per decidere l'ordine. Convertire errori di directory in `DICOMScanningError.cannotEnumerate(path:reason:)`.

- [ ] **Step 5: Implementare parsing e raggruppamento**

Per ogni file regolare chiamare `.metadataOnly`. Ignorare soltanto `DICOMParsingError.notDICOM`; aggiungere gli altri errori a `[ScanFailure]`. Richiedere SOP/Series/Study UID con `missingRequiredTag`. Usare accumulatori array più mappe UID→indice, conservando l'ordine di primo incontro. Creare `PixelSpacing` solo con due valori finiti e positivi; creare `SliceOrientation` dai sei valori DICOM. `isImageSeries` è falso esattamente per `SR`, `PR`, `KO`.

- [ ] **Step 6: Verificare GREEN, regressioni e commit**

Run: `swift test --filter DICOMScannerTests`
Expected: scanner e progress passano.
Run: `swift test`
Expected: zero fallimenti.

```bash
git add Sources/DICOMCore/DICOMScanner.swift Tests/DICOMCoreTests/DICOMScannerTests.swift
git commit -m "feat: scan and group DICOM files"
```

### Task 5: Audit completo del brief e verifica finale

**Files:**
- Modify only if an audit finds a concrete defect: the four new source files and four new test files.

**Interfaces:**
- Consumes: tutti i deliverable dei Task 1–4.
- Produces: evidenza verificabile di conformità o un elenco preciso dei limiti ambientali.

- [ ] **Step 1: Eseguire la suite completa in Swift 6**

Run: `swift test`
Expected: build riuscita, zero test falliti, zero warning di strict concurrency. Se `swift` non è disponibile, registrare letteralmente l'errore del comando e non dichiarare che compila.

- [ ] **Step 2: Eseguire audit statici mirati**

```bash
rg -n 'try!|fatalError|[^?]![.)\],]' Sources/DICOMCore/DICOMTag.swift Sources/DICOMCore/DICOMDataset.swift Sources/DICOMCore/DICOMParser.swift Sources/DICOMCore/DICOMScanner.swift
rg -ni '\bhu\b|hounsfield|simd|metal|appkit|uikit' Sources/DICOMCore/DICOMTag.swift Sources/DICOMCore/DICOMDataset.swift Sources/DICOMCore/DICOMParser.swift Sources/DICOMCore/DICOMScanner.swift
rg -n 'sorted\(|\.sort\(|sort\s*\{' Sources/DICOMCore/DICOMScanner.swift
git diff --check
```

Expected: nessuna violazione; gli unici riferimenti consentiti a `InstanceNumber` sono il tag e il campo trasportato, mai una chiamata di ordinamento.

- [ ] **Step 3: Revisione riga per riga dei requisiti**

Confrontare i cinque deliverable del brief con API e test. Controllare in particolare: tutti i VR elencati, tutti i tag richiesti, long VR esatti, file meta little endian, fallback headerless, deflated rifiutato, SQ definite/indefinite, PixelData incapsulato, range metadata-only, errori localizzati, ricorsione scanner, flag non-image e assenza di sorting.

- [ ] **Step 4: Commit delle sole correzioni emerse dall'audit**

Se l'audit trova un difetto, prima aggiungere o modificare un test che fallisce, poi correggere il codice e rieseguire la verifica pertinente.

```bash
git add Sources/DICOMCore Tests/DICOMCoreTests
git commit -m "test: harden DICOM parser edge cases"
```

Se non emerge alcuna correzione, non creare un commit vuoto.

- [ ] **Step 5: Preparare il rapporto finale**

Elencare file creati, commit, risultato effettivo di ogni comando, deviazioni dalla specifica e dubbi di compilazione. Dichiarare esplicitamente la mancanza della toolchain se `swift test` non è stato eseguito.
