import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// Le prove del taglio minimo, e cosa ciascuna dimostra davvero.
//
// La prima è la più importante e non parla di denti: il flusso calcolato qui deve valere quanto
// quello calcolato da un secondo algoritmo, scritto per l'occasione e completamente diverso.
// Boykov e Kolmogorov è veloce ma delicato — la parte che riadotta gli orfani si può sbagliare
// in modi che non fanno cadere niente e danno solo un taglio un po' peggiore, che a occhio non
// si distingue da uno giusto. Un secondo algoritmo che sbagliasse allo stesso modo è
// implausibile, e finché i due numeri coincidono su grafi presi a caso il primo è giusto.
//
// Le altre due sono cliniche: il confine cade dove il legamento parodontale lo mette, e — la
// prova che giustifica l'esistenza di questo modulo — non passa dal varco che manda fuori strada
// la crescita competitiva.

@Suite("Taglio minimo")
struct GraphCutTests {

    // MARK: - Il flusso è quello giusto

    /// Il valore del taglio prodotto coincide con quello di un secondo algoritmo, su grafi presi
    /// a caso.
    ///
    /// I grafi sono piccoli ma non banali: capacità distribuite in modo da avere spesso più
    /// tagli minimi diversi dello stesso costo, che è il caso in cui un errore nella riadozione
    /// si vede. Il seme del generatore è fisso, perché una prova che fallisce una volta su venti
    /// senza potersi ripetere identica non serve a niente.
    @Test("Il taglio vale quanto quello di un algoritmo indipendente")
    func matchesIndependentMaxFlow() throws {
        var generator = SplitMix64(seed: 0x5EED_1234_ABCD_0001)

        for trial in 0..<40 {
            let sizeI = 2 + Int(generator.next() % 4)
            let sizeJ = 2 + Int(generator.next() % 3)
            let sizeK = 1 + Int(generator.next() % 3)

            let geometry = try VolumeGeometry(
                columnCount: sizeI, rowCount: sizeJ, sliceCount: sizeK,
                columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
                orientation: .standardAxial, originMM: Vec3(0, 0, 0))
            let box = IndexBox(restriction: nil, geometry: geometry)
            let directions = Directions(connectivity: .faces, geometry: geometry)

            var solver = MaxFlowSolver(box: box, directions: directions)
            var reference = DinicMaxFlow(nodeCount: box.nodeCount)

            // Capacità sugli archi, le stesse nei due grafi. Si conservano qui perché il costo
            // del taglio va ricalcolato sulle capacità **originali**: quelle dentro il
            // risolutore, a flusso finito, sono le residue e non dicono più quanto è costato.
            var builtEdges: [(a: Int, b: Int, capacity: Int)] = []
            for node in 0..<box.nodeCount {
                for direction in directions.positiveDirections {
                    guard let neighbour = box.neighbour(of: node, along: direction) else {
                        continue
                    }
                    let capacity = Int32(generator.next() % 24)
                    solver.setSymmetricCapacity(
                        capacity, from: node, to: neighbour, along: direction,
                        opposite: directions.opposite(of: direction))
                    reference.addUndirectedEdge(node, neighbour, capacity: Int(capacity))
                    builtEdges.append((node, neighbour, Int(capacity)))
                }
            }

            // Capacità verso i terminali. Almeno un nodo per parte è vincolato, altrimenti il
            // taglio minimo è zero e la prova non prova niente.
            var terminals = [Int32](repeating: 0, count: box.nodeCount)
            for node in 0..<box.nodeCount {
                terminals[node] = Int32(generator.next() % 41) - 20
            }
            terminals[0] = MaxFlowSolver.infiniteCapacity
            terminals[box.nodeCount - 1] = -MaxFlowSolver.infiniteCapacity

            for node in 0..<box.nodeCount {
                solver.setTerminal(terminals[node], at: node)
                if terminals[node] > 0 {
                    reference.addSourceEdge(node, capacity: Int(terminals[node]))
                } else if terminals[node] < 0 {
                    reference.addSinkEdge(node, capacity: Int(-terminals[node]))
                }
            }

            solver.solve()
            let partition = (0..<box.nodeCount).map { solver.isOnSourceSide($0) }

            let produced = cutCost(
                partition: partition, edges: builtEdges, terminals: terminals)
            let minimum = reference.maxFlow()

            #expect(
                produced == minimum,
                "prova \(trial): il taglio prodotto costa \(produced), il minimo è \(minimum)")
        }
    }

    // MARK: - Il confine cade nel legamento

    /// Due blocchi densi uniti da un ponte che si abbassa nel mezzo: il taglio passa per il
    /// punto più scuro.
    ///
    /// È lo stesso fantoccio della crescita competitiva, e la ragione è che qui i due devono
    /// dare la stessa risposta: dove il dato è pulito, l'ottimo globale e l'ottimo locale
    /// coincidono. Se questa prova fallisse mentre quella passa, il taglio starebbe pagando per
    /// una raffinatezza che sul caso facile peggiora le cose.
    @Test("Il confine cade nel punto più scuro del ponte")
    func cutsAtTheDarkestPoint() throws {
        let volume = try makeBridgedVolume()

        let mask = try GraphCut.segment(
            in: volume,
            objectSeedsMM: [Vec3(5, 6, 6)],
            backgroundSeedsMM: [Vec3(26, 6, 6)],
            densityRange: 800...3000)

        // Il blocco marcato è tutto dentro, quello opposto tutto fuori.
        #expect(mask.label(i: 5, j: 6, k: 6) == 1)
        #expect(mask.label(i: 9, j: 6, k: 6) == 1)
        #expect(mask.label(i: 22, j: 6, k: 6) == VolumeMask.background)
        #expect(mask.label(i: 26, j: 6, k: 6) == VolumeMask.background)

        // Il confine sta dentro il ponte, e vicino al suo minimo. La V tocca il fondo a 16: si
        // accetta uno scarto di due voxel, perché attorno al minimo il costo è quasi piatto e
        // pretendere il voxel esatto sarebbe pretendere una precisione che il dato non ha.
        let boundary = try #require(
            firstBackgroundColumn(in: mask, j: 6, k: 6),
            "la maschera non ha un confine lungo x")
        #expect(boundary > 10 && boundary < 22, "il confine è fuori dal ponte: x = \(boundary)")
        #expect(abs(boundary - 17) <= 2, "il confine è lontano dal minimo: x = \(boundary)")
    }

    // MARK: - Il varco, che è il motivo per cui questo modulo esiste

    /// Un ponticello sottile fra le due parti non fa dilagare il taglio.
    ///
    /// Il fantoccio è il caso che manda fuori strada qualunque procedura che decida un voxel
    /// alla volta: fra i due blocchi c'è una lamina scura che li separa quasi ovunque, ma in un
    /// punto un filo denso spesso un voxel li unisce. È la radice saldata alla corticale, o il
    /// tratto di legamento che il rumore ha riempito.
    ///
    /// Una crescita si infila nel filo e da lì si prende tutto il blocco opposto, perché quando
    /// ci passa non ha modo di sapere che sta sbagliando. Il taglio minimo non ci passa, e non
    /// perché sia più furbo: perché usare quel filo lo obbligherebbe comunque a tagliare tutto
    /// attorno al blocco opposto, e tagliare il filo — un arco solo — costa incomparabilmente
    /// meno.
    @Test("Un ponticello di un voxel non fa dilagare il taglio")
    func doesNotLeakThroughAThinBridge() throws {
        let volume = try makeLeakingVolume()

        let mask = try GraphCut.segment(
            in: volume,
            objectSeedsMM: [Vec3(5, 6, 6)],
            backgroundSeedsMM: [Vec3(26, 6, 6)],
            densityRange: 800...3000)

        let counts = mask.voxelCounts()
        let claimed = counts[1] ?? 0

        // Il blocco marcato conta 8 × 8 × 8 = 512 voxel. Si concede il filo e qualche voxel di
        // lamina attorno, non il blocco opposto.
        #expect(claimed >= 512, "il taglio non ha preso nemmeno il suo blocco: \(claimed) voxel")
        #expect(claimed < 900, "il taglio è dilagato oltre la lamina: \(claimed) voxel")

        // La prova diretta: il blocco opposto è rimasto fuori, tutto quanto.
        for i in 22...29 {
            #expect(
                mask.label(i: i, j: 6, k: 6) == VolumeMask.background,
                "il taglio ha preso il blocco opposto a x = \(i)")
        }
    }

    // MARK: - I vincoli sono vincoli

    @Test("I marcatori sono rispettati anche contro l'energia")
    func seedsAreHardConstraints() throws {
        let volume = try makeBridgedVolume()

        // Il marcatore dell'oggetto sta nel blocco di destra e quello dello sfondo in quello di
        // sinistra: l'opposto della prova precedente. Se i marcatori fossero un suggerimento
        // invece che un vincolo, il taglio darebbe la stessa risposta di prima.
        let mask = try GraphCut.segment(
            in: volume,
            objectSeedsMM: [Vec3(26, 6, 6)],
            backgroundSeedsMM: [Vec3(5, 6, 6)],
            densityRange: 800...3000)

        #expect(mask.label(i: 26, j: 6, k: 6) == 1)
        #expect(mask.label(i: 5, j: 6, k: 6) == VolumeMask.background)
    }

    @Test("Fuori dalla fascia di densità non si assegna niente")
    func staysInsideTheDensityRange() throws {
        let volume = try makeBridgedVolume()

        let mask = try GraphCut.segment(
            in: volume,
            objectSeedsMM: [Vec3(5, 6, 6)],
            backgroundSeedsMM: [Vec3(26, 6, 6)],
            densityRange: 800...3000)

        // L'aria attorno ai blocchi sta a zero: fuori fascia, e quindi mai nell'oggetto.
        for k in 0..<12 {
            for j in 0..<12 {
                for i in 0..<32 where volume.samples[i + j * 32 + k * 32 * 12] < 800 {
                    #expect(
                        mask.label(i: i, j: j, k: k) == VolumeMask.background,
                        "voxel fuori fascia assegnato all'oggetto a (\(i), \(j), \(k))")
                }
            }
        }
    }

    // MARK: - Quel che rifiuta

    @Test("Senza marcatori la procedura rifiuta invece di indovinare")
    func refusesWithoutSeeds() throws {
        let volume = try makeBridgedVolume()

        #expect(throws: SegmentKitError.missingObjectSeed) {
            _ = try GraphCut.segment(
                in: volume, objectSeedsMM: [], backgroundSeedsMM: [Vec3(26, 6, 6)],
                densityRange: 800...3000)
        }
        #expect(throws: SegmentKitError.missingBackgroundSeed) {
            _ = try GraphCut.segment(
                in: volume, objectSeedsMM: [Vec3(5, 6, 6)], backgroundSeedsMM: [],
                densityRange: 800...3000)
        }
    }

    @Test("Un grafo oltre il tetto viene rifiutato prima di allocarlo")
    func refusesAnOversizedGraph() throws {
        let volume = try makeBridgedVolume()
        var settings = GraphCut.Settings.dental
        settings.maximumNodeCount = 100

        #expect(throws: SegmentKitError.self) {
            _ = try GraphCut.segment(
                in: volume, objectSeedsMM: [Vec3(5, 6, 6)],
                backgroundSeedsMM: [Vec3(26, 6, 6)],
                densityRange: 800...3000, settings: settings)
        }
    }

    @Test("I parametri fuori dominio sono un errore, non un valore corretto in silenzio")
    func refusesInvalidSettings() throws {
        let volume = try makeBridgedVolume()

        var negative = GraphCut.Settings.dental
        negative.smoothness = -1
        #expect(throws: SegmentKitError.invalidSmoothness(-1)) {
            _ = try GraphCut.segment(
                in: volume, objectSeedsMM: [Vec3(5, 6, 6)],
                backgroundSeedsMM: [Vec3(26, 6, 6)],
                densityRange: 800...3000, settings: negative)
        }

        var excessive = GraphCut.Settings.dental
        excessive.ligamentAffinity = 1.5
        #expect(throws: SegmentKitError.invalidLigamentAffinity(1.5)) {
            _ = try GraphCut.segment(
                in: volume, objectSeedsMM: [Vec3(5, 6, 6)],
                backgroundSeedsMM: [Vec3(26, 6, 6)],
                densityRange: 800...3000, settings: excessive)
        }
    }

    // MARK: - Fantocci

    /// Due blocchi a 2000 uniti da un ponte che scende a 900 nel mezzo, sfondo a 0.
    ///
    /// I blocchi stanno a x ∈ [2,9] e x ∈ [22,29]; il ponte a x ∈ [10,21], con una V che tocca
    /// il minimo a x = 16.
    private func makeBridgedVolume(
        bridgeFloor: Double = 900, blockValue: Double = 2000
    ) throws -> Volume {
        let geometry = try VolumeGeometry(
            columnCount: 32, rowCount: 12, sliceCount: 12,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: Vec3(0, 0, 0))

        var samples = [Int16](repeating: 0, count: geometry.voxelCount)
        for k in 2..<10 {
            for j in 2..<10 {
                for i in 0..<32 {
                    let value: Double
                    switch i {
                    case 2...9, 22...29:
                        value = blockValue
                    case 10...21:
                        let distance = Double(abs(i - 16))
                        value = bridgeFloor + (blockValue - bridgeFloor) * (distance / 6)
                    default:
                        value = 0
                    }
                    samples[i + j * 32 + k * 32 * 12] = Int16(value.rounded())
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    /// Due blocchi separati da una lamina scura, uniti da un filo denso spesso un voxel.
    ///
    /// I blocchi occupano x ∈ [2,9] e x ∈ [22,29] su otto voxel per lato; fra loro, a
    /// x ∈ [10,21], c'è materiale appena sopra la soglia — la lamina — tranne lungo la riga
    /// (j, k) = (6, 6), dove corre il filo alla stessa densità dei blocchi.
    private func makeLeakingVolume() throws -> Volume {
        let geometry = try VolumeGeometry(
            columnCount: 32, rowCount: 12, sliceCount: 12,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: Vec3(0, 0, 0))

        var samples = [Int16](repeating: 0, count: geometry.voxelCount)
        for k in 2..<10 {
            for j in 2..<10 {
                for i in 0..<32 {
                    let value: Int16
                    switch i {
                    case 2...9, 22...29:
                        value = 2000
                    case 10...21:
                        // La lamina sta appena dentro la fascia: nessuna soglia la toglie di
                        // mezzo, ed è esattamente la situazione in cui il legamento non basta.
                        value = (j == 6 && k == 6) ? 2000 : 850
                    default:
                        value = 0
                    }
                    samples[i + j * 32 + k * 32 * 12] = value
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    // MARK: - Attrezzi

    /// La prima colonna, scorrendo verso destra, in cui la maschera torna sfondo.
    private func firstBackgroundColumn(in mask: VolumeMask, j: Int, k: Int) -> Int? {
        var seenObject = false
        for i in 0..<mask.geometry.columnCount {
            let isObject = mask.label(i: i, j: j, k: k) != VolumeMask.background
            if isObject { seenObject = true }
            if seenObject && !isObject { return i }
        }
        return nil
    }

    /// Il costo del taglio descritto dalla partizione, sulle capacità originali.
    ///
    /// Gli archi fra i nodi sono simmetrici, quindi separarne due costa la capacità una volta
    /// sola, comunque sia orientato l'arco. Sui terminali no: un nodo lasciato allo sfondo paga
    /// l'arco che gli veniva dalla sorgente, uno preso nell'oggetto paga quello che andava al
    /// pozzo, e mai il contrario.
    private func cutCost(
        partition: [Bool],
        edges: [(a: Int, b: Int, capacity: Int)],
        terminals: [Int32]
    ) -> Int {
        var total = 0
        for edge in edges where partition[edge.a] != partition[edge.b] {
            total += edge.capacity
        }
        for node in partition.indices {
            if partition[node], terminals[node] < 0 { total += Int(-terminals[node]) }
            if !partition[node], terminals[node] > 0 { total += Int(terminals[node]) }
        }
        return total
    }
}

// MARK: - L'algoritmo di riscontro

/// Flusso massimo secondo Dinic, scritto per non somigliare in niente a quello che deve
/// controllare.
///
/// Liste di adiacenza esplicite invece di una griglia implicita, livelli ricostruiti da capo a
/// ogni fase invece di alberi mantenuti, nessuna riadozione: se i due concordano su grafi presi
/// a caso, concordano perché il risultato è quello giusto e non perché condividono un errore.
struct DinicMaxFlow {
    private struct Edge {
        var target: Int
        var capacity: Int
    }

    private var edges: [Edge] = []
    private var adjacency: [[Int]]
    private let source: Int
    private let sink: Int
    private let total: Int

    init(nodeCount: Int) {
        source = nodeCount
        sink = nodeCount + 1
        total = nodeCount + 2
        adjacency = [[Int]](repeating: [], count: total)
    }

    private mutating func addEdge(_ from: Int, _ to: Int, capacity: Int, reverse: Int) {
        adjacency[from].append(edges.count)
        edges.append(Edge(target: to, capacity: capacity))
        adjacency[to].append(edges.count)
        edges.append(Edge(target: from, capacity: reverse))
    }

    mutating func addUndirectedEdge(_ a: Int, _ b: Int, capacity: Int) {
        addEdge(a, b, capacity: capacity, reverse: capacity)
    }

    mutating func addSourceEdge(_ node: Int, capacity: Int) {
        addEdge(source, node, capacity: capacity, reverse: 0)
    }

    mutating func addSinkEdge(_ node: Int, capacity: Int) {
        addEdge(node, sink, capacity: capacity, reverse: 0)
    }

    mutating func maxFlow() -> Int {
        var flow = 0
        while true {
            var level = [Int](repeating: -1, count: total)
            level[source] = 0
            var queue = [source]
            var cursor = 0
            while cursor < queue.count {
                let node = queue[cursor]
                cursor += 1
                for edgeIndex in adjacency[node] where edges[edgeIndex].capacity > 0 {
                    let next = edges[edgeIndex].target
                    if level[next] < 0 {
                        level[next] = level[node] + 1
                        queue.append(next)
                    }
                }
            }
            guard level[sink] >= 0 else { return flow }

            var progress = [Int](repeating: 0, count: total)
            while true {
                let pushed = augment(
                    from: source, limit: Int.max, level: level, progress: &progress)
                guard pushed > 0 else { break }
                flow += pushed
            }
        }
    }

    private mutating func augment(
        from node: Int, limit: Int, level: [Int], progress: inout [Int]
    ) -> Int {
        guard node != sink else { return limit }
        while progress[node] < adjacency[node].count {
            let edgeIndex = adjacency[node][progress[node]]
            let next = edges[edgeIndex].target
            if edges[edgeIndex].capacity > 0, level[next] == level[node] + 1 {
                let pushed = augment(
                    from: next, limit: Swift.min(limit, edges[edgeIndex].capacity),
                    level: level, progress: &progress)
                if pushed > 0 {
                    edges[edgeIndex].capacity -= pushed
                    edges[edgeIndex ^ 1].capacity += pushed
                    return pushed
                }
            }
            progress[node] += 1
        }
        return 0
    }
}

/// Generatore deterministico, perché una prova che non si ripete identica non è una prova.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
