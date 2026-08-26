# Brief per Codex — MeshKit: dalla superficie al solido stampabile

Il nucleo della segmentazione c'è e le sue superfici sono già chiuse: sul fantoccio dente-in-osso
marching cubes esce con **zero bordi aperti e zero spigoli non-manifold**, sia per l'osso sia per
il dente. Quel che manca sta a valle, ed è tutto ciò che separa una superficie corretta da un file
che una stampante accetta:

| Manca | Conseguenza per chi stampa |
|---|---|
| esportazione OBJ | `MeshFormat.obj` esiste **solo in lettura**; si esporta soltanto STL |
| lisciatura | la superficie è a gradini di voxel: il modello stampato ha le scalette |
| decimazione | 26.272 triangoli per un dente da fantoccio a 0,4 mm; un'arcata vera ne fa milioni |
| referto d'integrità | non c'è modo di sapere *prima* di stampare se il solido è chiuso |

## Da sapere prima di iniziare

`Mesh` ha già `welded(toleranceMM:)` e `removingDegenerateTriangles()`, e `MarchingCubes.surface`
li applica entrambi in uscita. **Non riscriverli.** La saldatura è già fatta: chi arriva qui trova
vertici condivisi e indici sani.

---

## ▼ Da qui in giù è il lotto ▼

You are writing Swift 6 code for **CBCTMac**, a native macOS dental CBCT planning application.
Repo: https://github.com/Levius29/CBCTMac, branch `claude/dicom-volume-segmentation-zoomdc`.
Your task: extend **MeshKit** so a marching-cubes surface can become a 3D-printable solid.
Do not touch any other module.

Read first: `Sources/MeshKit/Mesh.swift`, `Sources/MeshKit/MeshIO.swift`,
`Sources/MeshKit/MarchingCubes.swift`, `Sources/DICOMCore/Geometry.swift`.

### Hard constraints

- Swift 6 language mode, strict concurrency. All public types `Sendable`.
- **Only `Foundation`**, plus the existing `DICOMCore` target. No `simd`, no Metal, no AppKit,
  no SwiftUI, no third-party dependencies, no C interop. Must compile and test on Linux.
- No `try!`, no `fatalError`, no force-unwraps, no `as!`. Every failure names what went wrong.
- **Doc comments in Italian, identifiers in English.** Match the surrounding prose: comments
  explain *why* a decision was taken, especially at the traps listed below. Do not write comments
  that restate the code.
- No recursion over mesh elements: a full arch is millions of triangles and the stack will not
  hold. Iterative queues only.
- Swift toolchain is at `/opt/swift/usr/bin` — run `export PATH=/opt/swift/usr/bin:$PATH` first.
  Verify with `swift build` and `swift test --filter MeshKit`. The whole suite is 893 tests and
  green: **it must still be green when you are done.**

### Deliverable 1 — OBJ export, and one door for every format

```swift
extension MeshIO {
    /// Esporta come Wavefront OBJ.
    public static func exportOBJ(_ mesh: Mesh) -> String
    /// Esporta come PLY binario little-endian.
    public static func exportPLYBinary(_ mesh: Mesh) -> Data
    /// Esporta nel formato richiesto.
    public static func export(_ mesh: Mesh, as format: MeshFormat) -> Data
}
```

`MeshFormat` already exists with `.stlBinary`, `.stlASCII`, `.ply`, `.obj` and is used only when
loading. `export(_:as:)` must be total over it — a `switch` with no `default`, so that adding a
format later fails to compile instead of silently falling through to STL.

**Trap.** OBJ face indices are **1-based**, and negative indices are legal and mean "relative to
the end". Write absolute 1-based indices. Emit `o <name>` with newlines and control characters
stripped from the mesh name, as `exportSTLASCII` already does — a name with a newline in it
produces a file that loads as two objects.

**Trap.** Coordinates are millimetres in `Double`. Printing them with `\(value)` gives Swift's
shortest round-tripping form, which is what you want; do not round to a fixed number of decimals,
because 0,075 mm voxels put real detail in the fourth decimal.

Reuse `exportableTriangles(in:)` — it already drops degenerate and out-of-range triangles, and
the three exporters must agree on what they emit.

### Deliverable 2 — the integrity report

```swift
public struct MeshIntegrity: Hashable, Sendable {
    public var triangleCount: Int
    public var vertexCount: Int
    /// Spigoli percorsi da un solo triangolo: un solido chiuso non ne ha nessuno.
    public var openEdgeCount: Int
    /// Spigoli percorsi da più di due triangoli.
    public var nonManifoldEdgeCount: Int
    /// Gusci separati, cioè componenti connesse per spigolo.
    public var shellCount: Int
    /// Volume con segno: negativo quando le normali guardano dentro.
    public var volumeMM3: Double
    public var areaMM2: Double
    public var isWatertight: Bool { openEdgeCount == 0 && nonManifoldEdgeCount == 0 }
}

public enum MeshRepair: Sendable {
    public static func integrity(of mesh: Mesh) -> MeshIntegrity
    /// Tiene il guscio con più triangoli e scarta gli altri.
    public static func largestShell(of mesh: Mesh) -> Mesh
    /// Rende coerente l'avvolgimento dei triangoli e porta le normali all'esterno.
    public static func orientedOutward(_ mesh: Mesh) -> Mesh
}
```

**Trap, e il motivo per cui `orientedOutward` non è un dettaglio.** Uno slicer che riceve triangoli
avvolti a caso stampa un guscio vuoto o rifiuta il file. L'avvolgimento si propaga per adiacenza
con una coda iterativa (un triangolo impone il verso ai suoi vicini di spigolo: se due triangoli
adiacenti percorrono lo stesso spigolo **nello stesso verso**, uno dei due va rovesciato), e alla
fine si guarda il volume con segno del guscio: se è negativo si rovescia tutto. Il volume con
segno è già in `Mesh.signedVolumeMM3()`.

Fai la propagazione **per guscio**, non sull'intera mesh: gusci separati non hanno spigoli in
comune e orientarli insieme lascerebbe il secondo come capita.

**Trap.** L'adiacenza si costruisce su una mappa da spigolo (coppia ordinata di indici, minore
prima) a triangoli. Con milioni di triangoli, `Dictionary<Edge, [Int]>` con `reserveCapacity` è
accettabile; una scansione quadratica no.

### Deliverable 3 — Taubin smoothing

```swift
public enum MeshSmoothing: Sendable {
    public static func taubin(
        _ mesh: Mesh, lambda: Double = 0.53, mu: Double = -0.53,
        iterations: Int = 10
    ) -> Mesh
}
```

**Il punto di tutto il deliverable.** La lisciatura laplaciana pura (solo il passo `lambda`)
**ritira il modello**: dopo venti passate un dente ha perso mezzo millimetro di diametro, e un
dente stampato mezzo millimetro più magro non serve a nessuno. Taubin alterna un passo di
lisciatura con `lambda > 0` e un passo di *rigonfiamento* con `mu < -lambda`; la coppia lascia
passare le frequenze basse e toglie solo i gradini. Una iterazione è **le due passate insieme**.

Scrivi questa ragione nel commento del tipo. È l'unica cosa che qualcuno debba sapere leggendolo,
e senza di essa la prima persona che ottimizza il codice toglie il secondo passo.

- L'umbrella operator è la media dei vicini di spigolo, non dei vicini di triangolo.
- I vertici su un bordo aperto **non si muovono**: una mesh chiusa non ne ha, ma una che è stata
  ritagliata sì, e lisciarne il bordo lo arrotola su sé stesso.
- Con `iterations <= 0`, o con `lambda`/`mu` non finiti, restituisci la mesh invariata.

### Deliverable 4 — decimazione a quadriche

```swift
public enum MeshDecimation: Sendable {
    /// Riduce la mesh verso il bilancio di triangoli richiesto.
    public static func simplified(_ mesh: Mesh, targetTriangleCount: Int) -> Mesh
}
```

Errore quadratico di Garland-Heckbert, contrazione di spigolo, coda di priorità sul costo.

**Tre trappole, tutte e tre nate dallo stesso errore di chi la scrive per la prima volta:**

1. Una contrazione che **rovescia** un triangolo adiacente va rifiutata, non pagata cara: il costo
   quadratico non la vede, perché misura la distanza dai piani e non il verso. Prima di accettare,
   controlla che nessun triangolo incidente cambi il segno della propria normale.
2. Una contrazione che rende la topologia **non-manifold** va rifiutata: se i vicini dei due
   estremi hanno in comune più di due vertici, contrarre crea uno spigolo percorso tre volte.
3. Il costo in coda **invecchia**: contrarre uno spigolo cambia il costo dei suoi vicini. Non
   ricostruire la coda (è O(n²)); marca le voci obsolete con una versione per vertice e scartale
   quando escono.

Se il bilancio è già rispettato, o se è `<= 0`, restituisci la mesh invariata.

### Deliverable 5 — i test

In `Tests/MeshKitTests/`, con `swift-testing` (`import Testing`), come il resto della suite.
Nomi dei test in italiano, come gli altri.

Obbligatori, e ognuno deve poter **fallire** se il codice è sbagliato:

1. **OBJ va e torna.** Esporta un cubo, ricaricalo con `MeshIO.load(data:name:)`, e verifica che
   vertici e triangoli coincidano. `load` già riconosce l'OBJ, quindi il giro si chiude.
2. **Gli indici OBJ partono da uno.** Un tetraedro esportato non deve contenere `f 0`.
3. **PLY va e torna**, come sopra.
4. **`export(_:as:)` concorda** con i tre esportatori diretti, sugli stessi byte.
5. **Il referto vede un buco.** Prendi un cubo chiuso, togli un triangolo, e verifica che
   `openEdgeCount` passi da 0 a 3 e `isWatertight` da vero a falso.
6. **Due gusci si contano due.** Unisci due cubi lontani con `MeshMerge.combined` e verifica
   `shellCount == 2`; poi `largestShell` ne tiene uno solo.
7. **L'orientamento si raddrizza.** Rovescia l'avvolgimento di metà dei triangoli di una sfera,
   passa da `orientedOutward`, e verifica che il volume con segno torni positivo e pari a quello
   di partenza entro l'1%.
8. **Taubin non ritira.** Su una sfera tassellata, venti iterazioni devono lasciare il volume
   entro il **3%** di quello iniziale. La stessa prova con la sola laplaciana (chiamando `taubin`
   con `mu: 0`) deve invece perdere **più del 10%** — è la prova che dimostra perché il secondo
   passo esiste, e senza di essa il test non può fallire.
9. **Taubin toglie i gradini.** Costruisci una superficie a gradini, misura la deviazione standard
   delle normali dei triangoli prima e dopo, e verifica che cali.
10. **La decimazione rispetta il bilancio e non rovescia niente.** Da una sfera a 5.000 triangoli
    scendi a 1.000: il conteggio deve essere ≤ 1.000, il volume entro il 5% e
    `MeshRepair.integrity` non deve trovare né bordi aperti né spigoli non-manifold.
11. **La decimazione non tocca ciò che è già abbastanza piccolo.**

### Come consegnare

Lascia le modifiche nell'albero di lavoro. **Non eseguire nessun comando `git`** — niente `add`,
niente `commit`, niente `checkout`: sto lavorando in parallelo nella stessa copia e un commit
raccoglierebbe anche i miei file a metà. Al commit ci penso io.

**Non toccare** `Sources/SegmentKit/`, `Sources/CBCTMacApp/` né `Tests/SegmentKitTests/`, per la
stessa ragione. I tuoi file sono solo `Sources/MeshKit/` e `Tests/MeshKitTests/`.

Prima di dire che hai finito: `swift build` pulito e `swift test` con tutta la suite verde.

## ▲ Fine del lotto ▲
