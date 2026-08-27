import Foundation
import DICOMCore

/// Etichetta per voxel. Zero è lo sfondo, mentre 1…255 identificano regioni distinte.
public typealias SegmentLabel = UInt8

/// Errori prodotti dalle operazioni di segmentazione che non possono completarsi in sicurezza.
public enum SegmentKitError: Error, Hashable, Sendable, LocalizedError {
    /// Le due maschere o la maschera e il volume non descrivono gli stessi voxel.
    case incompatibleGeometry
    /// Due etichette non di sfondo diverse occupano lo stesso voxel durante unione.
    case labelConflict(index: Int, first: SegmentLabel, second: SegmentLabel)
    /// Il riquadro richiesto non interseca alcun voxel del volume.
    case cropOutsideVolume
    /// Una maschera senza voxel selezionati non definisce un riquadro di ritaglio.
    case emptyMask
    /// Il margine in millimetri non è un valore finito e non negativo.
    case invalidMarginMM(Double)
    /// Il riquadro Patient non contiene coordinate finite o ha estremi invertiti.
    case invalidPatientBox
    /// La geometria calcolata per il ritaglio non è costruibile.
    case invalidCropGeometry
    /// I campioni estratti non consentono di costruire il volume ritagliato.
    case invalidCroppedVolume
    /// L'intervallo di densità non contiene estremi finiti utilizzabili.
    case invalidDensityRange
    /// La soglia della maschera metallica deve essere una densità finita in GV.
    case invalidMetalThresholdGV(Double)
    /// Lo sfondo non può identificare una nuova regione di segmentazione.
    case backgroundLabelNotAllowed
    /// La maschera non è allocabile per la geometria del volume richiesto.
    case maskAllocationFailed
    /// Il punto Patient usato come seme non contiene coordinate finite o convertibili.
    case invalidSeedPatientPoint
    /// Il seme convertito non cade in alcun voxel del volume.
    case seedOutsideVolume
    /// Il seme è nel volume ma non soddisfa la soglia di densità.
    case seedOutsideDensityRange
    /// Il limite di voxel richiesto non è positivo.
    case invalidMaximumVoxelCount(Int)
    /// La crescita supererebbe il limite massimo di voxel richiesto.
    case maximumVoxelCountExceeded(maximum: Int)
    /// Due semi sullo stesso voxel chiedono etichette diverse.
    case seedLabelConflict(index: Int, first: SegmentLabel, second: SegmentLabel)
    /// Il seme cade fuori dal riquadro entro cui la crescita è stata confinata.
    case seedOutsideRestriction
    /// La slope del rescale non consente di invertire l'intervallo di densità.
    case invalidRescaleSlope(Double)
    /// Il raggio morfologico non è finito oppure è negativo.
    case invalidMorphologyRadiusMM(Double)
    /// Il numero di componenti da conservare non può essere negativo.
    case invalidComponentCount(Int)
    /// Il volume minimo di una componente deve essere finito e non negativo.
    case invalidMinimumComponentVolumeMM3(Double)
    /// Il taglio minimo separa due parti: senza marcatori sull'oggetto non c'è cosa separare.
    case missingObjectSeed
    /// Senza marcatori sullo sfondo il taglio prenderebbe tutto il volume.
    case missingBackgroundSeed
    /// Il peso della continuità deve essere finito e non negativo.
    case invalidSmoothness(Double)
    /// La preferenza per i percorsi scuri deve stare fra zero e uno.
    case invalidLigamentAffinity(Double)
    /// L'ampiezza del contrasto deve essere una densità finita e positiva.
    case invalidContrastSigma(Double)
    /// Il tetto di nodi del grafo deve essere positivo.
    case invalidMaximumNodeCount(Int)
    /// Il grafo richiesto non è allocabile: serve restringere il riquadro.
    case graphTooLarge(nodes: Int, maximum: Int)

    /// Descrizione localizzata pronta per l'interfaccia utente.
    public var errorDescription: String? {
        switch self {
        case .incompatibleGeometry:
            return "Le geometrie delle maschere o del volume non coincidono esattamente."
        case .labelConflict(let index, let first, let second):
            return "Conflitto di etichette al voxel lineare \(index): \(first) e \(second)."
        case .cropOutsideVolume:
            return "Il riquadro richiesto non interseca il volume."
        case .emptyMask:
            return "La maschera non contiene voxel da ritagliare."
        case .invalidMarginMM(let margin):
            return "Il margine di ritaglio non è valido: \(margin) mm."
        case .invalidPatientBox:
            return "Il riquadro in coordinate Patient non è valido."
        case .invalidCropGeometry:
            return "Non è possibile costruire la geometria del volume ritagliato."
        case .invalidCroppedVolume:
            return "Non è possibile costruire il volume ritagliato dai campioni estratti."
        case .invalidDensityRange:
            return "L'intervallo di densità deve avere estremi finiti."
        case .invalidMetalThresholdGV(let threshold):
            return "La soglia della maschera metallica non è valida: \(threshold) GV."
        case .backgroundLabelNotAllowed:
            return "L'etichetta zero è riservata allo sfondo e non può definire una regione."
        case .maskAllocationFailed:
            return "Non è possibile allocare una maschera per la geometria richiesta."
        case .invalidSeedPatientPoint:
            return "Il seme in coordinate Patient non è finito o non è convertibile in voxel."
        case .seedOutsideVolume:
            return "Il seme non cade dentro il volume."
        case .seedOutsideDensityRange:
            return "Il seme non soddisfa l'intervallo di densità richiesto."
        case .invalidMaximumVoxelCount(let maximum):
            return "Il limite massimo di voxel deve essere positivo: \(maximum)."
        case .maximumVoxelCountExceeded(let maximum):
            return "La crescita supererebbe il limite di \(maximum) voxel."
        case .seedLabelConflict(let index, let first, let second):
            return "I semi al voxel lineare \(index) richiedono le etichette \(first) e \(second)."
        case .seedOutsideRestriction:
            return "Il seme cade fuori dal riquadro entro cui la crescita è confinata."
        case .invalidRescaleSlope(let slope):
            return "La slope di rescale non è valida per la segmentazione: \(slope)."
        case .invalidMorphologyRadiusMM(let radius):
            return "Il raggio morfologico non è valido: \(radius) mm."
        case .invalidComponentCount(let count):
            return "Il numero di componenti da conservare non può essere negativo: \(count)."
        case .invalidMinimumComponentVolumeMM3(let volume):
            return "Il volume minimo delle componenti non è valido: \(volume) mm³."
        case .missingObjectSeed:
            return "Serve almeno un marcatore dentro l'oggetto da estrarre."
        case .missingBackgroundSeed:
            return "Serve almeno un marcatore fuori dall'oggetto, in ciò da cui separarlo."
        case .invalidSmoothness(let smoothness):
            return "Il peso della continuità non è valido: \(smoothness)."
        case .invalidLigamentAffinity(let affinity):
            return "La preferenza per i percorsi scuri deve stare fra 0 e 1: \(affinity)."
        case .invalidContrastSigma(let sigma):
            return "L'ampiezza del contrasto non è valida: \(sigma) GV."
        case .invalidMaximumNodeCount(let maximum):
            return "Il tetto di nodi del grafo deve essere positivo: \(maximum)."
        case .graphTooLarge(let nodes, let maximum):
            return """
                Il riquadro richiede un grafo da \(nodes) nodi, oltre il limite di \(maximum). \
                Restringere il riquadro attorno alla struttura da estrarre.
                """
        }
    }
}

/// Maschera multietichetta allineata a un volume.
///
/// Ogni voxel usa un `UInt8`: a 400 milioni di voxel costa circa 400 MB, ma conserva regioni
/// diverse, cosa che una maschera booleana non può fare per denti, osso e metallo distinti.
public struct VolumeMask: Sendable {
    /// Etichetta riservata ai voxel non selezionati.
    public static let background: SegmentLabel = 0
    /// Limite oltre il quale la costruzione rifiuta invece di allocare.
    ///
    /// # Perché non è più un numero scritto a mano
    ///
    /// Era 400 milioni, cioè 400 MB di maschera. Una CBCT dentale a campo grande — 748 × 748 ×
    /// 733, quindici centimetri a 0,2 mm, un esame del tutto ordinario — ne conta 410, e la
    /// riduzione delle strie si rifiutava di partire proprio sul genere di esame per cui esiste.
    /// Un numero deciso a tavolino non sa quanta memoria ha la macchina su cui gira, e sbaglia
    /// in tutt'e due i versi: troppo basso su un Mac da 64 GB, troppo alto su uno da 8.
    ///
    /// La regola adesso è: la maschera può occupare al più **un sedicesimo** della memoria
    /// fisica. Un sedicesimo e non un ottavo perché la maschera non viaggia mai da sola — la
    /// catena della riduzione tiene insieme il volume originale in `Int16`, la maschera, la sua
    /// copia per la morfologia e il volume corretto, e a un byte per voxel la maschera è la più
    /// leggera delle quattro.
    ///
    /// Restano un pavimento e un soffitto. Il pavimento è il vecchio limite, perché nessuna
    /// macchina deve poter fare **meno** di prima; il soffitto tiene lontano il punto in cui
    /// un'aritmetica a 32 bit altrove diventerebbe un rischio.
    public static let maximumVoxelCount: Int = {
        let physical = ProcessInfo.processInfo.physicalMemory
        let share = Int(min(physical / 16, UInt64(Int.max)))
        return min(max(share, 400_000_000), 4_000_000_000)
    }()

    /// Geometria condivisa con il volume cui la maschera si applica.
    public let geometry: VolumeGeometry
    /// Etichette in ordine k-major, identico a `Volume.samples`.
    public private(set) var labels: [SegmentLabel]

    /// Costruisce una maschera completamente sullo sfondo, senza superare il limite di memoria.
    public init?(geometry: VolumeGeometry) {
        guard let voxelCount = Self.checkedVoxelCount(for: geometry) else { return nil }
        self.geometry = geometry
        self.labels = [SegmentLabel](repeating: Self.background, count: voxelCount)
    }

    /// Costruisce una maschera dalle etichette già disponibili se il loro conteggio è coerente.
    public init?(geometry: VolumeGeometry, labels: [SegmentLabel]) {
        guard let voxelCount = Self.checkedVoxelCount(for: geometry), labels.count == voxelCount else {
            return nil
        }
        self.geometry = geometry
        self.labels = labels
    }

    /// Restituisce l'etichetta del voxel, oppure lo sfondo fuori dal volume.
    public func label(i: Int, j: Int, k: Int) -> SegmentLabel {
        guard isValidVoxel(i: i, j: j, k: k) else { return Self.background }
        return labels[linearIndex(i: i, j: j, k: k)]
    }

    /// Imposta l'etichetta del voxel; fuori dal volume non effettua alcuna modifica.
    /// Scrittura per indice lineare, senza ricalcolare le tre coordinate.
    ///
    /// Interna al modulo e non pubblica: fuori di qui l'indice lineare non è una cosa che si
    /// debba conoscere, e chi lo sbagliasse scriverebbe in un voxel a caso senza accorgersene.
    /// Dentro, in un ciclo che tocca milioni di voxel, ricostruire `i`, `j` e `k` per poi
    /// rimoltiplicarli è metà del lavoro fatto due volte.
    mutating func setLabel(_ label: SegmentLabel, atIndex index: Int) {
        guard index >= 0, index < labels.count else { return }
        labels[index] = label
    }

    public mutating func setLabel(_ label: SegmentLabel, i: Int, j: Int, k: Int) {
        guard isValidVoxel(i: i, j: j, k: k) else { return }
        labels[linearIndex(i: i, j: j, k: k)] = label
    }

    /// Indica se il voxel ha un'etichetta diversa dallo sfondo.
    public func contains(i: Int, j: Int, k: Int) -> Bool {
        label(i: i, j: j, k: k) != Self.background
    }

    /// Conta i voxel non di sfondo raggruppati per etichetta.
    public func voxelCounts() -> [SegmentLabel: Int] {
        var counts: [SegmentLabel: Int] = [:]
        for value in labels where value != Self.background {
            counts[value, default: 0] += 1
        }
        return counts
    }

    /// Calcola il volume occupato in mm³ dall'etichetta indicata o da tutte le non di sfondo.
    public func volumeMM3(label: SegmentLabel?) -> Double {
        let voxelVolume = geometry.columnSpacingMM * geometry.rowSpacingMM * geometry.sliceSpacingMM
        var count = 0
        for value in labels where value != Self.background && matches(value, requestedLabel: label) {
            count += 1
        }
        return Double(count) * voxelVolume
    }

    /// Restituisce il riquadro contenitore in indici voxel dell'etichetta, oppure `nil` se assente.
    public func voxelBounds(
        label: SegmentLabel?
    ) -> (min: (Int, Int, Int), max: (Int, Int, Int))? {
        var minimum: (Int, Int, Int)?
        var maximum: (Int, Int, Int)?
        let planeSize = geometry.columnCount * geometry.rowCount

        for index in labels.indices {
            let value = labels[index]
            guard value != Self.background, matches(value, requestedLabel: label) else { continue }
            let k = index / planeSize
            let withinSlice = index % planeSize
            let j = withinSlice / geometry.columnCount
            let i = withinSlice % geometry.columnCount

            if let current = minimum {
                minimum = (min(current.0, i), min(current.1, j), min(current.2, k))
            } else {
                minimum = (i, j, k)
            }
            if let current = maximum {
                maximum = (max(current.0, i), max(current.1, j), max(current.2, k))
            } else {
                maximum = (i, j, k)
            }
        }

        guard let minimum, let maximum else { return nil }
        return (minimum, maximum)
    }

    /// Unisce due maschere preservando l'etichetta non di sfondo e segnalando i conflitti reali.
    public func union(with other: VolumeMask) throws -> VolumeMask {
        try requireSameGeometry(as: other)
        var combined = labels
        for index in combined.indices {
            let first = combined[index]
            let second = other.labels[index]
            if first == Self.background {
                combined[index] = second
            } else if second != Self.background && first != second {
                throw SegmentKitError.labelConflict(index: index, first: first, second: second)
            }
        }
        guard let result = VolumeMask(geometry: geometry, labels: combined) else {
            throw SegmentKitError.invalidCroppedVolume
        }
        return result
    }

    /// Rimuove i voxel in cui l'altra maschera non è sullo sfondo.
    public func subtracting(_ other: VolumeMask) throws -> VolumeMask {
        try requireSameGeometry(as: other)
        var result = labels
        for index in result.indices where other.labels[index] != Self.background {
            result[index] = Self.background
        }
        guard let mask = VolumeMask(geometry: geometry, labels: result) else {
            throw SegmentKitError.invalidCroppedVolume
        }
        return mask
    }

    /// Scambia sfondo e selezione: ogni voxel non di sfondo diventa zero, ogni zero diventa uno.
    public func inverted() -> VolumeMask {
        let invertedLabels = labels.map { $0 == Self.background ? 1 : Self.background }
        return VolumeMask(geometry: geometry, labels: invertedLabels) ?? self
    }

    private static func checkedVoxelCount(for geometry: VolumeGeometry) -> Int? {
        let columns = geometry.columnCount
        let rows = geometry.rowCount
        let slices = geometry.sliceCount
        let (planeSize, planeOverflow) = columns.multipliedReportingOverflow(by: rows)
        guard !planeOverflow else { return nil }
        let (voxelCount, voxelOverflow) = planeSize.multipliedReportingOverflow(by: slices)
        guard !voxelOverflow, voxelCount <= maximumVoxelCount else { return nil }
        return voxelCount
    }

    private func isValidVoxel(i: Int, j: Int, k: Int) -> Bool {
        i >= 0 && i < geometry.columnCount
            && j >= 0 && j < geometry.rowCount
            && k >= 0 && k < geometry.sliceCount
    }

    private func linearIndex(i: Int, j: Int, k: Int) -> Int {
        (k * geometry.rowCount + j) * geometry.columnCount + i
    }

    private func requireSameGeometry(as other: VolumeMask) throws {
        guard geometry == other.geometry else { throw SegmentKitError.incompatibleGeometry }
    }

    private func matches(_ value: SegmentLabel, requestedLabel: SegmentLabel?) -> Bool {
        guard let requestedLabel else { return true }
        return value == requestedLabel
    }
}
