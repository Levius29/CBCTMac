import DICOMCore
import Foundation

// Intersezione di una superficie con un piano.
//
// # A che cosa serve
//
// È il primitivo che manca per far **vedere** una superficie sulle viste 2D. Una scansione
// intraorale, una dima, una struttura segmentata: tutte sono mesh, e finché non si sa
// intersecarle con un piano restano invisibili dove si lavora davvero, cioè sulle fette.
//
// Serve anche a giudicare una registrazione. Il modo con cui chiunque verifica che una scansione
// sia allineata non è leggere un numero di scarto: è guardare il contorno sovrapposto alla fetta
// e vedere se segue lo smalto. Senza contorno, quello scarto resta una parola.
//
// # I casi degeneri, che sono il punto
//
// L'algoritmo in sé è tre righe: per ogni triangolo si guarda da che parte del piano stanno i
// vertici e si interpolano gli spigoli che lo attraversano. Tutto il lavoro sta in ciò che
// succede quando un vertice cade **esattamente** sul piano — e su una mesh con centomila
// triangoli succede sempre, perché i denti scansionati hanno vertici ovunque.
//
// Trattato male produce segmenti di lunghezza nulla, punti doppi e anelli che non si chiudono.
// Qui i vertici si classificano in sopra, sotto e **sul** piano, e i cinque casi si trattano per
// quello che sono invece di sperare che l'interpolazione se la cavi.

/// Un contorno: i segmenti dell'intersezione, e gli anelli che ne risultano.
public struct MeshContour: Sendable {

    /// Segmenti sciolti, nell'ordine in cui i triangoli li hanno prodotti.
    public let segments: [(a: Vec3, b: Vec3)]
    /// Anelli ricostruiti concatenando i segmenti. Un anello chiuso ripete il primo punto in coda.
    public let loops: [[Vec3]]

    public var isEmpty: Bool { segments.isEmpty }

    /// Lunghezza totale del contorno, in millimetri.
    public var lengthMM: Double {
        segments.reduce(0) { $0 + $1.a.distance(to: $1.b) }
    }
}

public enum MeshSlicer {

    /// Interseca una mesh con un piano.
    ///
    /// - Parameter toleranceMM: entro quanto un vertice si considera **sul** piano. Va
    ///   commisurato alla risoluzione della mesh: troppo stretto e i vertici quasi sul piano
    ///   generano segmenti minuscoli, troppo largo e triangoli interi vengono dichiarati
    ///   complanari e spariscono.
    public static func contour(
        of mesh: Mesh,
        planeOriginMM: Vec3,
        planeNormalMM: Vec3,
        toleranceMM: Double = 1e-6
    ) -> MeshContour {
        guard let normal = planeNormalMM.normalized, !mesh.triangles.isEmpty else {
            return MeshContour(segments: [], loops: [])
        }

        let vertices = mesh.verticesMM
        var segments: [(a: Vec3, b: Vec3)] = []

        for triangle in mesh.triangles {
            let indices = [triangle.a, triangle.b, triangle.c]
            guard indices.allSatisfy({ $0 >= 0 && $0 < vertices.count }) else { continue }

            let points = indices.map { vertices[$0] }
            let distances = points.map { ($0 - planeOriginMM).dot(normal) }

            // Classificazione in tre stati, non due: è la differenza fra trattare i casi
            // degeneri e sperare che non capitino.
            let onPlane = distances.enumerated().filter { abs($0.element) <= toleranceMM }
            let above = distances.filter { $0 > toleranceMM }.count
            let below = distances.filter { $0 < -toleranceMM }.count

            switch onPlane.count {
            case 3:
                // Triangolo complanare. Non produce contorno: i suoi spigoli di bordo arrivano
                // dai triangoli vicini, che il piano attraversa davvero. Emetterli qui darebbe
                // una macchia di segmenti sovrapposti al posto di una linea.
                continue

            case 2:
                // Uno spigolo giace sul piano. È il contorno, ed è esatto.
                let a = points[onPlane[0].offset]
                let b = points[onPlane[1].offset]
                if a.distance(to: b) > toleranceMM { segments.append((a, b)) }

            case 1:
                // Un vertice tocca il piano. Conta solo se gli altri due stanno da parti opposte:
                // altrimenti il triangolo sfiora il piano in un punto, e un punto non è un
                // contorno.
                guard above == 1, below == 1 else { continue }
                let touching = points[onPlane[0].offset]
                let others = (0..<3).filter { $0 != onPlane[0].offset }
                if let crossing = intersection(
                    points[others[0]], distances[others[0]],
                    points[others[1]], distances[others[1]])
                {
                    if touching.distance(to: crossing) > toleranceMM {
                        segments.append((touching, crossing))
                    }
                }

            default:
                // Nessun vertice sul piano: o lo attraversa su due spigoli, o non lo tocca.
                guard above > 0, below > 0 else { continue }
                var crossings: [Vec3] = []
                for edge in [(0, 1), (1, 2), (2, 0)] {
                    let (i, j) = edge
                    guard (distances[i] > 0) != (distances[j] > 0) else { continue }
                    if let point = intersection(points[i], distances[i], points[j], distances[j]) {
                        crossings.append(point)
                    }
                }
                if crossings.count >= 2, crossings[0].distance(to: crossings[1]) > toleranceMM {
                    segments.append((crossings[0], crossings[1]))
                }
            }
        }

        let unique = deduplicated(segments, toleranceMM: toleranceMM)
        return MeshContour(segments: unique, loops: chain(unique, toleranceMM: toleranceMM))
    }

    /// Toglie i segmenti ripetuti.
    ///
    /// Uno spigolo che **giace** sul piano appartiene a due triangoli, e ciascuno lo emette: nel
    /// disegno non si nota — due linee sovrapposte sono una linea — ma la lunghezza del contorno
    /// raddoppia, e la concatenazione ne fa un anello che va avanti e indietro fra gli stessi due
    /// punti. La lunghezza è un numero che qualcuno legge, quindi il doppione va tolto qui e non
    /// lasciato a chi disegna.
    ///
    /// Il confronto è **senza verso**: i due triangoli percorrono lo spigolo in senso opposto,
    /// che è esattamente ciò che rende il doppione difficile da vedere leggendo il codice.
    static func deduplicated(
        _ segments: [(a: Vec3, b: Vec3)], toleranceMM: Double
    ) -> [(a: Vec3, b: Vec3)] {
        let cell = Swift.max(toleranceMM * 4, 1e-4)
        func key(_ point: Vec3) -> [Int] {
            [Int((point.x / cell).rounded()), Int((point.y / cell).rounded()),
             Int((point.z / cell).rounded())]
        }

        var seen: Set<[Int]> = []
        var unique: [(a: Vec3, b: Vec3)] = []
        unique.reserveCapacity(segments.count)

        for segment in segments {
            let first = key(segment.a)
            let second = key(segment.b)
            // Ordinato, così andata e ritorno danno la stessa chiave.
            let combined = first.lexicographicallyPrecedes(second)
                ? first + second : second + first
            if seen.insert(combined).inserted { unique.append(segment) }
        }
        return unique
    }

    /// Punto in cui un segmento attraversa il piano, dalle distanze con segno dei suoi estremi.
    private static func intersection(
        _ a: Vec3, _ da: Double, _ b: Vec3, _ db: Double
    ) -> Vec3? {
        let span = da - db
        guard abs(span) > 1e-15 else { return nil }
        return a.lerp(to: b, t: da / span)
    }

    /// Concatena i segmenti in anelli, unendo gli estremi che coincidono.
    ///
    /// # Perché non basta l'elenco dei segmenti
    ///
    /// Per tracciare una linea sì, per riempirla no — e soprattutto per **contare**: sapere che
    /// una sezione della scansione dà due anelli separati invece di uno dice che la fetta taglia
    /// due denti, ed è un'informazione che l'elenco sciolto non contiene.
    ///
    /// La ricerca degli estremi vicini passa da una griglia: su una mesh fitta i segmenti sono
    /// decine di migliaia, e confrontarli tutti con tutti costerebbe il quadrato.
    static func chain(_ segments: [(a: Vec3, b: Vec3)], toleranceMM: Double) -> [[Vec3]] {
        guard !segments.isEmpty else { return [] }
        let cell = Swift.max(toleranceMM * 4, 1e-4)

        func key(_ point: Vec3) -> [Int] {
            [Int((point.x / cell).rounded()), Int((point.y / cell).rounded()),
             Int((point.z / cell).rounded())]
        }

        // Estremi disponibili, indicizzati per cella.
        var buckets: [[Int]: [Int]] = [:]
        for (index, segment) in segments.enumerated() {
            buckets[key(segment.a), default: []].append(index)
            buckets[key(segment.b), default: []].append(index)
        }

        func neighbours(of point: Vec3) -> [Int] {
            let base = key(point)
            var result: [Int] = []
            for dx in -1...1 {
                for dy in -1...1 {
                    for dz in -1...1 {
                        let cellKey = [base[0] + dx, base[1] + dy, base[2] + dz]
                        if let indices = buckets[cellKey] { result.append(contentsOf: indices) }
                    }
                }
            }
            return result
        }

        var used = [Bool](repeating: false, count: segments.count)
        var loops: [[Vec3]] = []
        let joinTolerance = Swift.max(toleranceMM * 2, 1e-6)

        for start in segments.indices where !used[start] {
            used[start] = true
            var loop = [segments[start].a, segments[start].b]

            // Si allunga dalla coda finché si trova un segmento che vi si attacca.
            var extended = true
            while extended {
                extended = false
                guard let tail = loop.last else { break }
                for candidate in neighbours(of: tail) where !used[candidate] {
                    let segment = segments[candidate]
                    if segment.a.distance(to: tail) <= joinTolerance {
                        loop.append(segment.b)
                    } else if segment.b.distance(to: tail) <= joinTolerance {
                        loop.append(segment.a)
                    } else {
                        continue
                    }
                    used[candidate] = true
                    extended = true
                    break
                }
            }
            loops.append(loop)
        }
        return loops
    }
}
