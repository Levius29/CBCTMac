import DICOMCore
import Foundation

// Decidere il confine su tutto il contorno insieme, invece che un voxel alla volta.
//
// # Che cosa aggiunge alla crescita competitiva
//
// `CompetitiveGrowth` fa incontrare due fronti e li ferma dove il percorso fra loro è più
// scuro. Funziona, ed è rapida, ma decide **localmente**: ogni voxel se lo prende chi ci arriva
// per primo, e quella decisione non si rivede più. Basta un varco — un tratto di legamento che
// il rumore ha riempito, una radice saldata alla corticale, un pixel bruciato da una corona
// metallica — perché un fronte passi dall'altra parte, e da lì dilaga: fuori di lì la
// competizione non ha modo di sapere che ha sbagliato.
//
// Il taglio minimo non ha questo difetto, perché non decide un voxel alla volta: cerca la
// superficie che separa i due gruppi di marcatori **pagando meno di ogni altra**. Un varco
// largo un voxel non gli serve a niente, perché per usarlo dovrebbe comunque tagliare tutt'
// attorno, e quel prezzo lo paga. Fra due superfici che passano entrambe per il legamento
// sceglie la più corta; fra due che pagano lo stesso sceglie quella dove il dato è più debole.
// È la differenza fra un confine trovato e un confine dimostrato: qui l'ottimo è globale, non
// un ottimo locale che si spera sia quello giusto.
//
// # L'energia, e il termine che non è di manuale
//
// Si minimizza la solita somma di Boykov e Jolly: quanto costa dare un voxel all'una o all'
// altra parte, più quanto costa separare due voxel vicini. Il primo termine, su un dente, vale
// poco e lo sappiamo: dentina e corticale hanno densità che si sovrappongono, quindi guardando
// un voxel isolato non si capisce di chi sia. Il lavoro lo fa il secondo termine.
//
// Nella formulazione classica separare due voxel vicini costa tanto quanto si somigliano:
//
//     w(p,q) = exp( −(I_p − I_q)² / 2σ² ) / distanza(p,q)
//
// Il che va benissimo per un oggetto che stacca sul fondo, e male per un dente dentro l'osso,
// dove il salto di densità sul legamento è di poche centinaia di GV — a volte di nessuna. Qui
// si aggiunge un fattore che la formula di manuale non ha, e che viene dall'anatomia e non
// dalla matematica: **separare due voxel entrambi densi costa caro, separarne due scuri costa
// poco.** Lo spazio del legamento parodontale è un avvallamento che gira attorno a tutta la
// radice, e il colletto fra due denti vicini è la stessa cosa in piccolo: sono i punti scuri, e
// il taglio deve preferirli anche là dove il gradiente da solo non li segnala.
//
//     w(p,q) = λ · exp( −(I_p − I_q)² / 2σ² ) · densità(min(I_p, I_q)) / distanza(p,q)
//
// `ligamentAffinity` dosa quel fattore: a zero resta la formula di manuale, a uno pesa quanto
// può. La divisione per la distanza in **millimetri** e non in voxel non è un dettaglio: una
// CBCT con slice più spesse del pixel darebbe altrimenti un taglio che preferisce le superfici
// perpendicolari all'asse più fitto, cioè una segmentazione che cambia forma col formato di
// acquisizione invece che con l'anatomia.
//
// # Il prezzo, che è la memoria
//
// Il grafo costa una quarantina di byte per voxel contro il byte della maschera: su un FOV da
// sedici centimetri sarebbero decine di gigabyte. Per questo qui la scatola non è un consiglio
// come in `GrowthRestriction`, è **il modo in cui la procedura è utilizzabile** — e infatti
// chiunque faccia questo mestiere obbliga a disegnarla. Un dente sta in 15 × 15 × 25 mm: a
// 0,15 mm sono un milione e mezzo di nodi, settanta megabyte, frazioni di secondo.
//
// # Che cosa questo **non** fa
//
// Non indovina dove sono i denti — i marcatori li mette chi guarda, per le stesse ragioni
// scritte in `CompetitiveGrowth`. E non inventa il dato che l'artefatto metallico ha cancellato:
// dove attorno a una corona la dentina è stata bruciata, il taglio passerà da qualche parte
// perché deve passare, ma quella superficie non è un confine anatomico ed è chi guarda a
// doverlo sapere.
// non-ancora-collegato: il pannello di segmentazione offre soglia e crescita competitiva; il
// taglio minimo entra nell'interfaccia quando ci sarà da posare i marcatori delle due parti,
// che è un gesto che oggi la UI non ha.
public enum GraphCut: Sendable {

    /// I pochi numeri che governano la forma del taglio.
    public struct Settings: Hashable, Sendable {

        /// Quanto pesa tenere unito rispetto a somigliare al proprio marcatore.
        ///
        /// Alzandolo il confine si liscia e ignora i voxel isolati; abbassandolo insegue le
        /// singole densità e si frastaglia. Su una CBCT dentale il termine di somiglianza vale
        /// poco per costruzione, quindi il valore utile è alto.
        public var smoothness: Double

        /// L'ampiezza in GV del salto di densità considerato un confine, oppure `nil` per
        /// misurarla sul dato.
        ///
        /// Misurarla è quasi sempre meglio che sceglierla: un valore scritto a mano sbaglia di
        /// molto fra una macchina rumorosa e una pulita, e sbagliarlo verso il basso rende ogni
        /// grumo di rumore un confine possibile.
        public var contrastSigmaGV: Double?

        /// Quanto il taglio preferisce passare per i voxel scuri, da 0 a 1.
        ///
        /// A zero è la formula di Boykov e Jolly senza aggiunte. A uno il fattore di densità
        /// pesa quanto può, che è ciò che serve per far cadere il confine nel legamento
        /// parodontale là dove il gradiente da solo non basterebbe a segnalarlo.
        public var ligamentAffinity: Double

        /// Sei vicini o ventisei.
        ///
        /// Con sei il taglio è una superficie a scalini e tende a preferire i piani coordinati —
        /// l'errore di metrica noto di ogni taglio su griglia. Con ventisei l'approssimazione
        /// della superficie è molto migliore e il grafo costa quattro volte tanto.
        public var connectivity: Connectivity

        /// Il tetto di nodi oltre il quale la procedura rifiuta invece di allocare, oppure
        /// `nil` per ricavarlo dalla memoria della macchina.
        public var maximumNodeCount: Int?

        public init(
            smoothness: Double = 12,
            contrastSigmaGV: Double? = nil,
            ligamentAffinity: Double = 1,
            connectivity: Connectivity = .faces,
            maximumNodeCount: Int? = nil
        ) {
            self.smoothness = smoothness
            self.contrastSigmaGV = contrastSigmaGV
            self.ligamentAffinity = ligamentAffinity
            self.connectivity = connectivity
            self.maximumNodeCount = maximumNodeCount
        }

        /// I valori tarati per separare un dente dall'osso che lo circonda.
        public static let dental = Settings()
    }

    /// Assegna all'oggetto i voxel che il taglio di costo minimo lascia dalla parte dei suoi
    /// marcatori.
    ///
    /// - Parameters:
    ///   - objectSeedsMM: punti Patient dentro la cosa da estrarre. Ne basta uno, ma ognuno è un
    ///     vincolo assoluto: quel voxel sarà nell'oggetto qualunque cosa dica l'energia.
    ///   - backgroundSeedsMM: punti Patient in ciò da cui separarla — l'osso attorno, il dente
    ///     accanto. Anche questi sono vincoli assoluti.
    ///   - densityRange: la fascia entro cui l'oggetto può stare. Fuori da essa il voxel è
    ///     sfondo e basta, senza che l'energia possa ripensarci: è ciò che tiene fuori l'aria e
    ///     i tessuti molli, e come in `CompetitiveGrowth` va scelta larga, perché separare
    ///     dentina e corticale è compito del taglio e non della soglia.
    ///   - regionMM: la scatola fuori dalla quale non si assegna niente. È opzionale nella firma
    ///     e necessaria nei fatti su qualunque volume vero: senza, il grafo copre l'intero FOV e
    ///     la procedura rifiuta di allocarlo.
    /// - Returns: la maschera con `label` sui voxel dell'oggetto e sfondo altrove.
    public static func segment(
        in volume: Volume,
        objectSeedsMM: [Vec3],
        backgroundSeedsMM: [Vec3],
        densityRange: ClosedRange<Double>,
        within regionMM: BoxMM? = nil,
        settings: Settings = .dental,
        label: SegmentLabel = 1
    ) throws -> VolumeMask {
        guard !objectSeedsMM.isEmpty else { throw SegmentKitError.missingObjectSeed }
        guard !backgroundSeedsMM.isEmpty else { throw SegmentKitError.missingBackgroundSeed }
        guard label != VolumeMask.background else {
            throw SegmentKitError.backgroundLabelNotAllowed
        }
        guard settings.smoothness.isFinite, settings.smoothness >= 0 else {
            throw SegmentKitError.invalidSmoothness(settings.smoothness)
        }
        guard settings.ligamentAffinity.isFinite,
            settings.ligamentAffinity >= 0, settings.ligamentAffinity <= 1
        else {
            throw SegmentKitError.invalidLigamentAffinity(settings.ligamentAffinity)
        }
        if let sigma = settings.contrastSigmaGV {
            guard sigma.isFinite, sigma > 0 else {
                throw SegmentKitError.invalidContrastSigma(sigma)
            }
        }

        let interval = try RawDensityInterval(volume: volume, densityRange: densityRange)
        let geometry = volume.geometry

        var restriction: GrowthRestriction?
        if let regionMM {
            guard let built = GrowthRestriction(box: regionMM, geometry: geometry) else {
                throw SegmentKitError.cropOutsideVolume
            }
            restriction = built
        }

        let box = IndexBox(restriction: restriction, geometry: geometry)
        let nodeCount = box.nodeCount
        let degree = settings.connectivity == .faces ? 6 : 26
        let maximumNodeCount =
            try resolvedMaximumNodeCount(settings.maximumNodeCount, degree: degree)
        guard nodeCount <= maximumNodeCount else {
            throw SegmentKitError.graphTooLarge(nodes: nodeCount, maximum: maximumNodeCount)
        }

        guard var mask = VolumeMask(geometry: geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }

        // I marcatori si convertono tutti prima di costruire il grafo: un punto storto o fuori
        // scatola è un errore dell'operatore, e deve fermare la procedura prima che questa abbia
        // allocato centinaia di megabyte per poi accorgersene.
        let objectNodes = try seedNodes(
            objectSeedsMM, box: box, geometry: geometry, restriction: restriction)
        let backgroundNodes = try seedNodes(
            backgroundSeedsMM, box: box, geometry: geometry, restriction: restriction)
        for node in objectNodes {
            let raw = volume.samples[box.volumeIndex(ofNode: node)]
            guard interval.contains(raw) else { throw SegmentKitError.seedOutsideDensityRange }
        }
        let objectSet = Set(objectNodes)
        for node in backgroundNodes where objectSet.contains(node) {
            throw SegmentKitError.seedLabelConflict(
                index: box.volumeIndex(ofNode: node), first: label, second: VolumeMask.background)
        }

        let directions = Directions(connectivity: settings.connectivity, geometry: geometry)
        var solver = MaxFlowSolver(box: box, directions: directions)

        let sigma = try settings.contrastSigmaGV
            ?? estimatedContrastSigmaGV(volume: volume, box: box, directions: directions)
        buildEdges(
            into: &solver, volume: volume, box: box, directions: directions,
            interval: interval, sigma: sigma, settings: settings)
        buildTerminals(
            into: &solver, volume: volume, box: box, interval: interval,
            restriction: restriction, objectNodes: objectNodes, backgroundNodes: backgroundNodes)

        solver.solve()

        for node in 0..<nodeCount where solver.isOnSourceSide(node) {
            mask.setLabel(label, atIndex: box.volumeIndex(ofNode: node))
        }
        return mask
    }

    /// Il tetto ricavato dalla memoria fisica quando non è stato imposto.
    ///
    /// Un ottavo della memoria della macchina, come in `VolumeMask.maximumVoxelCount` e per la
    /// stessa ragione: il grafo non viaggia mai da solo, perché il volume in `Int16` e la
    /// maschera in uscita gli stanno accanto per tutta la durata del calcolo.
    private static func resolvedMaximumNodeCount(_ requested: Int?, degree: Int) throws -> Int {
        if let requested {
            guard requested > 0 else {
                throw SegmentKitError.invalidMaximumNodeCount(requested)
            }
            return requested
        }
        let bytesPerNode = degree * MemoryLayout<Int32>.size + 21
        let budget = ProcessInfo.processInfo.physicalMemory / 8
        let share = Int(min(budget / UInt64(bytesPerNode), UInt64(Int.max)))
        return min(max(share, 1_000_000), 200_000_000)
    }

    private static func seedNodes(
        _ seedsMM: [Vec3],
        box: IndexBox,
        geometry: VolumeGeometry,
        restriction: GrowthRestriction?
    ) throws -> [Int] {
        try seedsMM.map { seedMM in
            guard seedMM.isFinite else { throw SegmentKitError.invalidSeedPatientPoint }
            let voxel = geometry.voxelPoint(fromPatient: seedMM)
            guard voxel.isFinite,
                let i = Int(exactly: voxel.x.rounded()),
                let j = Int(exactly: voxel.y.rounded()),
                let k = Int(exactly: voxel.z.rounded())
            else {
                throw SegmentKitError.invalidSeedPatientPoint
            }
            guard i >= 0, i < geometry.columnCount,
                j >= 0, j < geometry.rowCount,
                k >= 0, k < geometry.sliceCount
            else {
                throw SegmentKitError.seedOutsideVolume
            }
            guard let node = box.node(i: i, j: j, k: k) else {
                throw SegmentKitError.seedOutsideRestriction
            }
            if let restriction, !restriction.allows(i: i, j: j, k: k) {
                throw SegmentKitError.seedOutsideRestriction
            }
            return node
        }
    }

    /// Misura sul dato l'ampiezza del salto che vale come confine.
    ///
    /// Si prende la media dei quadrati delle differenze fra voxel vicini, che è la stima
    /// suggerita nell'articolo originale. Su un volume dove tutto è piatto la media è zero e
    /// dividere per essa sarebbe una divisione per zero: in quel caso qualunque σ va bene, e si
    /// restituisce uno.
    private static func estimatedContrastSigmaGV(
        volume: Volume, box: IndexBox, directions: Directions
    ) throws -> Double {
        var total = 0.0
        var count = 0
        // Sui volumi grandi non serve guardarli tutti: un voxel ogni tanto dà la stessa media
        // con un costo che non si sente. Il passo è primo rispetto alle dimensioni della
        // griglia, così il campione non finisce per battere sempre sullo stesso piano.
        let stride = Swift.max(box.nodeCount / 200_000, 1)
        for node in Swift.stride(from: 0, to: box.nodeCount, by: stride) {
            let here = volume.applyRescale(volume.samples[box.volumeIndex(ofNode: node)])
            for direction in directions.positiveDirections {
                guard let neighbour = box.neighbour(of: node, along: direction) else { continue }
                let there = volume.applyRescale(volume.samples[box.volumeIndex(ofNode: neighbour)])
                let delta = here - there
                total += delta * delta
                count += 1
            }
        }
        guard count > 0 else { return 1 }
        let mean = total / Double(count)
        guard mean.isFinite, mean > 0 else { return 1 }
        return sqrt(mean)
    }

    private static func buildEdges(
        into solver: inout MaxFlowSolver,
        volume: Volume,
        box: IndexBox,
        directions: Directions,
        interval: RawDensityInterval,
        sigma: Double,
        settings: Settings
    ) {
        let lowest = Double(interval.minimum)
        let span = Swift.max(Double(interval.maximum) - lowest, 1)
        let twoSigmaSquared = 2 * sigma * sigma
        let slope = volume.rescaleSlope

        for node in 0..<box.nodeCount {
            let hereRaw = Double(volume.samples[box.volumeIndex(ofNode: node)])
            for direction in directions.positiveDirections {
                guard let neighbour = box.neighbour(of: node, along: direction) else { continue }
                let thereRaw = Double(volume.samples[box.volumeIndex(ofNode: neighbour)])

                // La differenza si misura in GV e non in valori grezzi: σ è in GV, e su un
                // volume con slope diversa da uno confrontarli darebbe un contrasto sbagliato
                // di quel fattore.
                let deltaGV = (hereRaw - thereRaw) * slope
                let similarity = exp(-(deltaGV * deltaGV) / twoSigmaSquared)

                // Il fattore che non è di manuale: dove passa il legamento i due voxel sono
                // scuri, il fattore scende, e tagliare lì costa poco.
                let darkest = Swift.min(hereRaw, thereRaw)
                let position = Swift.min(Swift.max((darkest - lowest) / span, 0), 1)
                let density = settings.ligamentAffinity * position
                    + (1 - settings.ligamentAffinity)

                let weight = settings.smoothness * similarity * density
                    / directions.distanceMM(direction)
                solver.setSymmetricCapacity(
                    quantised(weight), from: node, to: neighbour, along: direction,
                    opposite: directions.opposite(of: direction))
            }
        }
    }

    private static func buildTerminals(
        into solver: inout MaxFlowSolver,
        volume: Volume,
        box: IndexBox,
        interval: RawDensityInterval,
        restriction: GrowthRestriction?,
        objectNodes: [Int],
        backgroundNodes: [Int]
    ) {
        // Le due medie dei marcatori sono tutto ciò che si sa sulle due parti. È poco, ed è
        // voluto: con un marcatore per parte qualunque stima più raffinata — un istogramma, una
        // gaussiana con la sua varianza — sarebbe costruita su un campione di uno, e darebbe
        // un'aria di precisione a un numero che non ne ha.
        let objectMean = mean(of: objectNodes, volume: volume, box: box)
        let backgroundMean = mean(of: backgroundNodes, volume: volume, box: box)
        let separation = Swift.max(abs(objectMean - backgroundMean), 1)

        for node in 0..<box.nodeCount {
            let volumeIndex = box.volumeIndex(ofNode: node)
            let raw = volume.samples[volumeIndex]

            // Fuori fascia, o fuori dal riquadro vero quando la matrice è ruotata: sfondo per
            // vincolo, non per convenienza. Il taglio non deve nemmeno poterci pensare.
            guard interval.contains(raw) else {
                solver.setTerminal(-MaxFlowSolver.infiniteCapacity, at: node)
                continue
            }
            if let restriction {
                let (i, j, k) = box.voxel(ofNode: node)
                guard restriction.allows(i: i, j: j, k: k) else {
                    solver.setTerminal(-MaxFlowSolver.infiniteCapacity, at: node)
                    continue
                }
            }

            let value = Double(raw)
            let toObject = abs(value - objectMean) / separation
            let toBackground = abs(value - backgroundMean) / separation
            // Convenzione di Boykov e Jolly: l'arco che parte dalla sorgente costa quanto
            // somigliare allo sfondo, perché tagliarlo significa avere dato il voxel allo
            // sfondo. La capacità netta è la differenza fra i due.
            solver.setTerminal(quantised(toBackground - toObject), at: node)
        }

        // I vincoli assoluti si scrivono per ultimi, così sovrascrivono qualunque cosa l'energia
        // avesse dedotto per quei voxel.
        for node in objectNodes {
            solver.setTerminal(MaxFlowSolver.infiniteCapacity, at: node)
        }
        for node in backgroundNodes {
            solver.setTerminal(-MaxFlowSolver.infiniteCapacity, at: node)
        }
    }

    private static func mean(of nodes: [Int], volume: Volume, box: IndexBox) -> Double {
        guard !nodes.isEmpty else { return 0 }
        var total = 0.0
        for node in nodes {
            total += Double(volume.samples[box.volumeIndex(ofNode: node)])
        }
        return total / Double(nodes.count)
    }

    /// Porta un costo continuo in interi.
    ///
    /// Il taglio minimo si calcola in aritmetica intera e non in virgola mobile: con i reali le
    /// somme di capacità residue accumulano un errore che non si annulla mai del tutto, e
    /// l'algoritmo può ritrovarsi a inseguire cammini di capacità 10⁻¹⁵ senza fermarsi. Con gli
    /// interi la terminazione è garantita, e la scala è abbastanza fine che l'arrotondamento
    /// resta molto sotto il rumore del dato.
    static let quantisationScale = 256.0

    static func quantised(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = (value * quantisationScale).rounded()
        let limit = Double(MaxFlowSolver.infiniteCapacity)
        return Int32(Swift.min(Swift.max(scaled, -limit), limit))
    }
}

/// La scatola di indici entro cui il grafo esiste, e la conversione fra i suoi nodi e i voxel.
///
/// I nodi sono **tutti** i voxel della scatola, anche quelli fuori fascia: legarli allo sfondo
/// con una capacità insuperabile costa un intero per voxel e fa risparmiare la mappa da indice
/// di volume a indice di nodo, che su un FOV grande peserebbe più del grafo.
struct IndexBox: Sendable {
    let minimumI: Int, minimumJ: Int, minimumK: Int
    let sizeI: Int, sizeJ: Int, sizeK: Int
    let volumeColumns: Int, volumeRows: Int

    init(restriction: GrowthRestriction?, geometry: VolumeGeometry) {
        volumeColumns = geometry.columnCount
        volumeRows = geometry.rowCount
        if let restriction {
            minimumI = restriction.minimumI
            minimumJ = restriction.minimumJ
            minimumK = restriction.minimumK
            sizeI = restriction.maximumI - restriction.minimumI + 1
            sizeJ = restriction.maximumJ - restriction.minimumJ + 1
            sizeK = restriction.maximumK - restriction.minimumK + 1
        } else {
            minimumI = 0
            minimumJ = 0
            minimumK = 0
            sizeI = geometry.columnCount
            sizeJ = geometry.rowCount
            sizeK = geometry.sliceCount
        }
    }

    var nodeCount: Int { sizeI * sizeJ * sizeK }

    func node(i: Int, j: Int, k: Int) -> Int? {
        let li = i - minimumI, lj = j - minimumJ, lk = k - minimumK
        guard li >= 0, li < sizeI, lj >= 0, lj < sizeJ, lk >= 0, lk < sizeK else { return nil }
        return (lk * sizeJ + lj) * sizeI + li
    }

    func voxel(ofNode node: Int) -> (i: Int, j: Int, k: Int) {
        let plane = sizeI * sizeJ
        let lk = node / plane
        let rest = node % plane
        return (rest % sizeI + minimumI, rest / sizeI + minimumJ, lk + minimumK)
    }

    func volumeIndex(ofNode node: Int) -> Int {
        let (i, j, k) = voxel(ofNode: node)
        return (k * volumeRows + j) * volumeColumns + i
    }

    /// Il vicino lungo la direzione, o `nil` se uscirebbe dalla scatola.
    ///
    /// Il controllo è sulle tre coordinate e non sul solo indice lineare, perché in un indice
    /// lineare i due voxel ai capi opposti di una riga sono adiacenti: senza, il taglio potrebbe
    /// uscire da una faccia e rientrare dall'altra.
    func neighbour(of node: Int, along direction: Direction) -> Int? {
        let (i, j, k) = voxel(ofNode: node)
        return self.node(i: i + direction.dx, j: j + direction.dy, k: k + direction.dz)
    }
}

/// Uno degli spostamenti che collegano un voxel ai suoi vicini.
struct Direction: Hashable, Sendable {
    let dx: Int
    let dy: Int
    let dz: Int
    /// La posizione della direzione nel grafo: gli opposti stanno in coppia, `d` e `d ^ 1`.
    let slot: Int
}

/// L'elenco delle direzioni, con le distanze in millimetri già calcolate.
struct Directions: Sendable {
    /// Solo le direzioni con spostamento positivo: ogni arco si costruisce una volta sola, e
    /// insieme al suo reciproco.
    let positiveDirections: [Direction]
    /// Tutte le direzioni ordinate per posizione, opposti in coppia: serve al risolutore, che
    /// ragiona per posizione e non conosce il concetto di verso positivo.
    let bySlot: [Direction]
    private let distances: [Double]

    init(connectivity: Connectivity, geometry: VolumeGeometry) {
        let dx = geometry.columnSpacingMM
        let dy = geometry.rowSpacingMM
        let dz = geometry.sliceSpacingMM

        var offsets: [(Int, Int, Int)] = [(1, 0, 0), (0, 1, 0), (0, 0, 1)]
        if connectivity == .full {
            offsets = []
            // Metà degli spostamenti, uno per coppia di opposti: il primo non nullo in ordine
            // lessicografico si tiene, il suo negativo si scarta.
            for kz in -1...1 {
                for jy in -1...1 {
                    for ix in -1...1 where !(ix == 0 && jy == 0 && kz == 0) {
                        let isPositive = kz > 0 || (kz == 0 && jy > 0) || (kz == 0 && jy == 0 && ix > 0)
                        if isPositive { offsets.append((ix, jy, kz)) }
                    }
                }
            }
        }

        var built: [Direction] = []
        var all: [Direction] = []
        var lengths: [Double] = []
        for (index, offset) in offsets.enumerated() {
            let forward = Direction(dx: offset.0, dy: offset.1, dz: offset.2, slot: index * 2)
            let backward = Direction(
                dx: -offset.0, dy: -offset.1, dz: -offset.2, slot: index * 2 + 1)
            built.append(forward)
            all.append(forward)
            all.append(backward)
            let length = sqrt(
                pow(Double(offset.0) * dx, 2) + pow(Double(offset.1) * dy, 2)
                    + pow(Double(offset.2) * dz, 2))
            lengths.append(Swift.max(length, .leastNormalMagnitude))
            lengths.append(Swift.max(length, .leastNormalMagnitude))
        }
        positiveDirections = built
        bySlot = all
        distances = lengths
    }

    func distanceMM(_ direction: Direction) -> Double { distances[direction.slot] }

    func opposite(of direction: Direction) -> Int { direction.slot ^ 1 }
}

/// Il flusso massimo di Boykov e Kolmogorov su griglia.
///
/// # Perché questo e non un algoritmo di manuale
///
/// Su un grafo qualunque Dinic o push-relabel hanno limiti teorici migliori. Su una griglia di
/// visione, dove i cammini fra sorgente e pozzo sono lunghi e quasi tutti gli archi hanno
/// capacità simile, in pratica perdono: ricostruiscono da capo i livelli a ogni fase, e le fasi
/// sono tante. Questo algoritmo tiene invece **due alberi di ricerca**, uno dalla sorgente e uno
/// dal pozzo, e dopo aver saturato un cammino non li butta: ne stacca il pezzo rotto e riattacca
/// gli orfani. È la ragione per cui è lo standard di fatto per il taglio minimo sulle immagini.
///
/// Gli archi non hanno una lista di adiacenza. Sono un array `nodeCount × degree` in cui la
/// posizione dice già la direzione, e il reciproco di `d` è `d ^ 1`: su un grafo dove ogni nodo
/// ha lo stesso numero di vicini è la rappresentazione più compatta possibile, e risparmia i
/// quattro byte per arco che l'indice del reciproco costerebbe.
struct MaxFlowSolver {

    /// La capacità che nessun taglio può permettersi, e che quindi vincola.
    ///
    /// Un quarto del massimo rappresentabile: quattro capacità così si sommano ancora senza
    /// traboccare, il che basta perché la somma delle capacità entranti in un nodo vincolato non
    /// possa mai andare in overflow.
    static let infiniteCapacity: Int32 = Int32.max / 4

    private static let free: UInt8 = 0
    private static let sourceTree: UInt8 = 1
    private static let sinkTree: UInt8 = 2

    private static let noParent: Int32 = -1
    private static let terminalParent: Int32 = -2
    private static let orphanParent: Int32 = -3

    let nodeCount: Int
    let degree: Int

    /// La griglia su cui il grafo è disteso, e gli spostamenti che ne collegano i nodi.
    ///
    /// Il risolutore la conosce invece di farsela dire da fuori: il vicino di un nodo si chiede
    /// milioni di volte per cammino, e passare da una chiamata indiretta costerebbe più di tutto
    /// il resto messo insieme.
    private let sizeI: Int, sizeJ: Int, sizeK: Int
    private let steps: [Direction]

    private var residual: [Int32]
    private var terminal: [Int32]
    private var parent: [Int32]
    private var tree: [UInt8]
    private var distance: [Int32]
    private var timestamp: [Int32]

    private var active: [Int32] = []
    private var activeCursor = 0
    private var isQueued: [Bool]
    private var orphans: [Int32] = []
    private var currentTime: Int32 = 0

    init(box: IndexBox, directions: Directions) {
        nodeCount = box.nodeCount
        degree = directions.bySlot.count
        sizeI = box.sizeI
        sizeJ = box.sizeJ
        sizeK = box.sizeK
        steps = directions.bySlot
        let nodeCount = box.nodeCount
        let degree = directions.bySlot.count
        residual = [Int32](repeating: 0, count: nodeCount * degree)
        terminal = [Int32](repeating: 0, count: nodeCount)
        parent = [Int32](repeating: MaxFlowSolver.noParent, count: nodeCount)
        tree = [UInt8](repeating: MaxFlowSolver.free, count: nodeCount)
        distance = [Int32](repeating: 0, count: nodeCount)
        timestamp = [Int32](repeating: 0, count: nodeCount)
        isQueued = [Bool](repeating: false, count: nodeCount)
    }

    mutating func setSymmetricCapacity(
        _ capacity: Int32, from node: Int, to neighbour: Int, along direction: Direction,
        opposite: Int
    ) {
        residual[node * degree + direction.slot] = capacity
        residual[neighbour * degree + opposite] = capacity
    }

    mutating func setTerminal(_ capacity: Int32, at node: Int) {
        terminal[node] = capacity
    }

    /// Indica se il nodo è rimasto dalla parte della sorgente, cioè nell'oggetto.
    ///
    /// I nodi che alla fine non appartengono a nessuno dei due alberi stanno dalla parte del
    /// pozzo: sono quelli che il flusso ha isolato, e per definizione il taglio minimo li lascia
    /// fuori dall'oggetto.
    mutating func isOnSourceSide(_ node: Int) -> Bool { tree[node] == MaxFlowSolver.sourceTree }

    /// Calcola il flusso massimo, e con esso il taglio.
    mutating func solve() {
        seedTrees()
        while true {
            guard let (contactNode, contactSlot) = grow() else { break }
            // La cache deve diventare vecchia prima di creare gli orfani: altrimenti un nodo
            // appena staccato conserva il timestamp corrente e sembra ancora radicato tramite
            // il cammino che l'aumento ha appena spezzato.
            currentTime += 1
            augment(from: contactNode, along: contactSlot)
            adopt()
        }
    }

    /// Ogni nodo con una capacità terminale non nulla è la radice di uno dei due alberi.
    private mutating func seedTrees() {
        active.reserveCapacity(nodeCount / 4 + 1)
        for node in 0..<nodeCount where terminal[node] != 0 {
            tree[node] = terminal[node] > 0
                ? MaxFlowSolver.sourceTree : MaxFlowSolver.sinkTree
            parent[node] = MaxFlowSolver.terminalParent
            distance[node] = 1
            timestamp[node] = 0
            enqueue(Int32(node))
        }
    }

    private mutating func enqueue(_ node: Int32) {
        guard !isQueued[Int(node)] else { return }
        isQueued[Int(node)] = true
        active.append(node)
    }

    private mutating func nextActive() -> Int32? {
        while activeCursor < active.count {
            let node = active[activeCursor]
            activeCursor += 1
            // La coda si compatta quando la parte già consumata supera la metà: liberarla a ogni
            // estrazione costerebbe uno spostamento per elemento, tenerla per sempre farebbe
            // crescere l'array senza limite su un grafo grande.
            if activeCursor > active.count / 2 && activeCursor > 1024 {
                active.removeFirst(activeCursor)
                activeCursor = 0
            }
            let index = Int(node)
            guard isQueued[index] else { continue }
            isQueued[index] = false
            guard parent[index] != MaxFlowSolver.noParent else { continue }
            return node
        }
        return nil
    }

    /// Fa crescere i due alberi finché non si toccano; restituisce l'arco di contatto.
    private mutating func grow() -> (node: Int, slot: Int)? {
        while let raw = nextActive() {
            let node = Int(raw)
            let ownTree = tree[node]
            guard ownTree != MaxFlowSolver.free else { continue }

            for slot in 0..<degree {
                // Un albero dalla sorgente avanza sulla capacità residua uscente; uno dal pozzo
                // su quella entrante, che è la residua dell'arco reciproco.
                let capacity = ownTree == MaxFlowSolver.sourceTree
                    ? residual[node * degree + slot]
                    : residualOfReverse(node: node, slot: slot)
                guard capacity > 0 else { continue }
                guard let neighbour = neighbourNode(of: node, slot: slot) else { continue }

                if tree[neighbour] == MaxFlowSolver.free {
                    tree[neighbour] = ownTree
                    parent[neighbour] = Int32(slot ^ 1)
                    timestamp[neighbour] = timestamp[node]
                    distance[neighbour] = distance[node] + 1
                    enqueue(Int32(neighbour))
                } else if tree[neighbour] != ownTree {
                    // I due alberi si toccano. L'arco si riporta sempre nel verso
                    // sorgente → pozzo, così chi aumenta il flusso non deve sapere da quale dei
                    // due lati la ricerca sia arrivata.
                    isQueued[node] = true
                    active.append(Int32(node))
                    return ownTree == MaxFlowSolver.sourceTree
                        ? (node, slot)
                        : (neighbour, slot ^ 1)
                } else if timestamp[neighbour] <= timestamp[node]
                    && distance[neighbour] > distance[node] + 1 {
                    // Stesso albero, ma il vicino ci arriva per una strada più lunga: lo si
                    // riattacca qui. È l'euristica che tiene gli alberi bassi, e con essi il
                    // costo di rimettere a posto gli orfani.
                    parent[neighbour] = Int32(slot ^ 1)
                    timestamp[neighbour] = timestamp[node]
                    distance[neighbour] = distance[node] + 1
                }
            }
        }
        return nil
    }

    /// Satura il cammino che passa per l'arco di contatto e ne stacca i nodi rimasti senza
    /// genitore.
    private mutating func augment(from node: Int, along slot: Int) {
        guard let neighbour = neighbourNode(of: node, slot: slot) else { return }

        var bottleneck = residual[node * degree + slot]
        // Verso la sorgente, risalendo l'albero S dal nodo di contatto.
        var current = node
        while parent[current] != MaxFlowSolver.terminalParent {
            let parentSlot = Int(parent[current])
            guard let up = neighbourNode(of: current, slot: parentSlot) else { break }
            bottleneck = Swift.min(bottleneck, residual[up * degree + (parentSlot ^ 1)])
            current = up
        }
        bottleneck = Swift.min(bottleneck, terminal[current])

        // Verso il pozzo, scendendo l'albero T dall'altro capo dell'arco di contatto.
        //
        // Qui il verso si ribalta rispetto al ramo di sopra, ed è il punto in cui è più facile
        // sbagliarsi: nell'albero della sorgente il flusso scende dal genitore al figlio, in
        // quello del pozzo risale dal figlio al genitore. La capacità da guardare è quindi
        // quella dell'arco che **esce** dal nodo verso il proprio genitore, non quella del suo
        // reciproco.
        current = neighbour
        while parent[current] != MaxFlowSolver.terminalParent {
            let parentSlot = Int(parent[current])
            guard let down = neighbourNode(of: current, slot: parentSlot) else { break }
            bottleneck = Swift.min(bottleneck, residual[current * degree + parentSlot])
            current = down
        }
        bottleneck = Swift.min(bottleneck, -terminal[current])

        guard bottleneck > 0 else { return }

        residual[node * degree + slot] -= bottleneck
        residual[neighbour * degree + (slot ^ 1)] += bottleneck

        current = node
        while parent[current] != MaxFlowSolver.terminalParent {
            let parentSlot = Int(parent[current])
            guard let up = neighbourNode(of: current, slot: parentSlot) else { break }
            residual[current * degree + parentSlot] += bottleneck
            residual[up * degree + (parentSlot ^ 1)] -= bottleneck
            if residual[up * degree + (parentSlot ^ 1)] == 0 {
                parent[current] = MaxFlowSolver.orphanParent
                orphans.append(Int32(current))
            }
            current = up
        }
        terminal[current] -= bottleneck
        if terminal[current] == 0 {
            parent[current] = MaxFlowSolver.orphanParent
            orphans.append(Int32(current))
        }

        current = neighbour
        while parent[current] != MaxFlowSolver.terminalParent {
            let parentSlot = Int(parent[current])
            guard let down = neighbourNode(of: current, slot: parentSlot) else { break }
            residual[current * degree + parentSlot] -= bottleneck
            residual[down * degree + (parentSlot ^ 1)] += bottleneck
            if residual[current * degree + parentSlot] == 0 {
                parent[current] = MaxFlowSolver.orphanParent
                orphans.append(Int32(current))
            }
            current = down
        }
        terminal[current] += bottleneck
        if terminal[current] == 0 {
            parent[current] = MaxFlowSolver.orphanParent
            orphans.append(Int32(current))
        }
    }

    /// Cerca ai nodi rimasti senza genitore un nuovo attacco allo stesso albero.
    ///
    /// Chi non lo trova torna libero, e i suoi figli diventano orfani a loro volta. È la parte
    /// che rende l'algoritmo quello che è: invece di ricostruire gli alberi da zero dopo ogni
    /// cammino saturato, se ne ripara il pezzo staccato.
    private mutating func adopt() {
        while let raw = orphans.popLast() {
            let orphan = Int(raw)
            let ownTree = tree[orphan]
            guard ownTree != MaxFlowSolver.free else { continue }

            var bestSlot: Int?
            var minimumDistance = Int.max
            for slot in 0..<degree {
                guard let candidate = neighbourNode(of: orphan, slot: slot) else { continue }
                guard tree[candidate] == ownTree else { continue }
                let capacity = ownTree == MaxFlowSolver.sourceTree
                    ? residual[candidate * degree + (slot ^ 1)]
                    : residual[orphan * degree + slot]
                guard capacity > 0 else { continue }
                let candidateDistance = originDistance(candidate)
                guard candidateDistance < minimumDistance else { continue }
                bestSlot = slot
                minimumDistance = candidateDistance
            }

            if let bestSlot {
                parent[orphan] = Int32(bestSlot)
                timestamp[orphan] = currentTime
                distance[orphan] = Int32(minimumDistance + 1)
                continue
            }

            // Nessun genitore possibile: il nodo esce dall'albero, e chi lo aveva come genitore
            // resta a sua volta orfano. I vicini dell'altro albero tornano attivi, perché la
            // frontiera si è appena spostata e potrebbero ora poter crescere di qui.
            for slot in 0..<degree {
                guard let neighbour = neighbourNode(of: orphan, slot: slot) else { continue }
                guard tree[neighbour] == ownTree else { continue }
                // La stessa capacità che l'adozione avrebbe guardato, vista dall'altro capo:
                // chi poteva adottare l'orfano torna attivo, perché la frontiera si è appena
                // spostata e da lì l'albero potrebbe ora crescere.
                let capacity = ownTree == MaxFlowSolver.sourceTree
                    ? residual[neighbour * degree + (slot ^ 1)]
                    : residual[orphan * degree + slot]
                if capacity > 0 { enqueue(Int32(neighbour)) }
                if parent[neighbour] >= 0, Int(parent[neighbour]) == (slot ^ 1) {
                    parent[neighbour] = MaxFlowSolver.orphanParent
                    orphans.append(Int32(neighbour))
                }
            }
            tree[orphan] = MaxFlowSolver.free
            parent[orphan] = MaxFlowSolver.noParent
            isQueued[orphan] = false
        }
    }

    /// Restituisce la distanza dal terminale, o infinito se il cammino finisce in un orfano.
    ///
    /// Ogni nodo visitato conserva la distanza esatta, non il solo fatto di essere radicato:
    /// `grow()` usa lo stesso valore per tenere aciclici gli alberi, e ridurlo a un booleano può
    /// riattaccare un nodo sotto un proprio discendente. Il tempo evita di rifare la risalita per
    /// ogni candidato quando gli orfani sono tanti.
    private mutating func originDistance(_ node: Int) -> Int {
        var current = node
        var rootedDistance = 0
        while true {
            if timestamp[current] == currentTime {
                rootedDistance += Int(distance[current])
                break
            }
            let link = parent[current]
            rootedDistance += 1
            if link == MaxFlowSolver.terminalParent {
                timestamp[current] = currentTime
                distance[current] = 1
                break
            }
            if link == MaxFlowSolver.orphanParent || link == MaxFlowSolver.noParent {
                rootedDistance = Int.max
                break
            }
            guard let up = neighbourNode(of: current, slot: Int(link)) else {
                rootedDistance = Int.max
                break
            }
            current = up
        }

        guard rootedDistance < Int.max else { return Int.max }

        current = node
        var cachedDistance = rootedDistance
        while timestamp[current] != currentTime {
            timestamp[current] = currentTime
            distance[current] = Int32(cachedDistance)
            cachedDistance -= 1
            let link = parent[current]
            guard link >= 0,
                let up = neighbourNode(of: current, slot: Int(link))
            else { break }
            current = up
        }
        return rootedDistance
    }

    private mutating func residualOfReverse(node: Int, slot: Int) -> Int32 {
        guard let neighbour = neighbourNode(of: node, slot: slot) else { return 0 }
        return residual[neighbour * degree + (slot ^ 1)]
    }

    /// Il nodo vicino lungo quella posizione, oppure `nil` sul bordo della griglia.
    ///
    /// Le tre coordinate si ricavano ogni volta invece di tenerle in memoria: sono due divisioni
    /// contro i sei byte per nodo che memorizzarle costerebbe, e su un grafo che occupa già
    /// decine di megabyte la memoria è la risorsa scarsa. Il controllo è su ciascuna coordinata
    /// e non sul solo indice lineare, perché in un indice lineare i due nodi ai capi opposti di
    /// una riga sono adiacenti.
    /// `mutating` evita che Swift materializzi una copia dell'intero risolutore quando questo
    /// helper viene chiamato da un metodo che ha già accesso esclusivo a `self`. In debug quella
    /// copia trattiene tutti gli array a ogni arco visitato e forza poi il copy-on-write.
    private mutating func neighbourNode(of node: Int, slot: Int) -> Int? {
        let step = steps[slot]
        let plane = sizeI * sizeJ
        let k = node / plane
        let rest = node % plane
        let j = rest / sizeI
        let i = rest % sizeI

        let ni = i + step.dx, nj = j + step.dy, nk = k + step.dz
        guard ni >= 0, ni < sizeI, nj >= 0, nj < sizeJ, nk >= 0, nk < sizeK else { return nil }
        return (nk * sizeJ + nj) * sizeI + ni
    }
}
