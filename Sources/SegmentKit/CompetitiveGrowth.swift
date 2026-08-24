import DICOMCore
import Foundation

// Separare oggetti che si toccano: denti fra loro, e denti dall'osso.
//
// # Perché la crescita normale non basta, e non è un dettaglio
//
// `RegionGrowing` è un riempimento: parte da un seme e prende tutto ciò che gli è connesso e sta
// sopra soglia. Su un dente non funziona, e non per un difetto — per l'anatomia. La radice di un
// dente sta **dentro** l'osso, e in densità dentina e corticale si sovrappongono: qualunque
// soglia comprenda la dentina comprende anche l'osso, e il riempimento dal dente cola nella
// mandibola e se la prende tutta. Alzando la soglia si tiene solo lo smalto, cioè la corona
// senza radice, che come modello non serve a niente.
//
// # Quel che c'è davvero nei dati, e come lo si usa
//
// Fra radice e osso c'è lo **spazio del legamento parodontale**: una riga radiotrasparente
// spessa qualche decimo di millimetro, che gira attorno a tutta la radice. In densità è un
// avvallamento, non un muro — su una CBCT dentale spesso non scende sotto la soglia della
// dentina, quindi una soglia non la vede — ma è il punto **più scuro** del percorso che va dal
// dente all'osso. Lo stesso vale fra due denti vicini, dove il punto più scuro è il colletto
// interdentale.
//
// Da qui l'algoritmo: invece di riempire, si fa **competere**. Ogni regione avanza dai voxel più
// densi verso i meno densi, e ogni voxel se lo prende la regione che ci arriva per prima. Due
// fronti che si vengono incontro si fermano dove il percorso fra loro è più scuro — che è
// esattamente il legamento, e il colletto. Il confine non lo decide una soglia scelta a mano:
// lo decide dove il dato è più debole.
//
// È il classico spartiacque a partire da marcatori, scritto per essere veloce su volumi grandi:
// la coda di priorità è a secchielli, quindi il costo è lineare nel numero di voxel invece che
// `n log n`.
//
// # Che cosa questo **non** fa
//
// Non indovina dove sono i denti: i semi li mette chi guarda. È una scelta, non una mancanza —
// il riconoscimento automatico su una CBCT con otturazioni metalliche sbaglia in modi che non si
// vedono guardando il risultato, e un modello di dente sbagliato in silenzio è peggio di nessun
// modello. E non recupera ciò che gli artefatti hanno cancellato: dove una corona metallica ha
// bruciato la dentina attorno, lì non c'è dato da segmentare, e nessun algoritmo lo inventa.
public enum CompetitiveGrowth: Sendable {

    /// Quanti livelli di densità distingue la coda a secchielli.
    ///
    /// Mille e ventiquattro: su un intervallo di tremila valori grigi sono tre GV per secchiello,
    /// molto sotto il rumore di una CBCT. Distinguere più fine costerebbe memoria per separare
    /// valori che il dato non separa.
    public static let defaultBucketCount = 1024

    /// Assegna ogni voxel sopra soglia alla regione che lo raggiunge scendendo di densità.
    ///
    /// - Parameters:
    ///   - seeds: un punto Patient e l'etichetta della regione. Etichette diverse competono;
    ///     più semi con la stessa etichetta formano una regione sola, che è il modo di marcare
    ///     l'osso in più punti.
    ///   - densityRange: la fascia entro cui si compete. Fuori da essa non si assegna niente:
    ///     è ciò che tiene fuori l'aria e i tessuti molli, e va scelta perché comprenda dentina
    ///     e corticale insieme — separarle è compito della competizione, non della soglia.
    /// - Returns: la maschera, con un'etichetta per regione e sfondo altrove.
    public static func grow(
        in volume: Volume,
        seeds: [(seedMM: Vec3, label: SegmentLabel)],
        densityRange: ClosedRange<Double>,
        connectivity: Connectivity = .faces,
        bucketCount: Int = defaultBucketCount
    ) throws -> VolumeMask {
        guard !seeds.isEmpty else { throw SegmentKitError.emptyMask }
        let buckets = Swift.max(bucketCount, 2)
        let interval = try RawDensityInterval(volume: volume, densityRange: densityRange)
        guard var mask = VolumeMask(geometry: volume.geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }

        let geometry = volume.geometry
        let columns = geometry.columnCount
        let rows = geometry.rowCount
        let planeSize = columns * rows
        let voxelCount = geometry.voxelCount

        // Il secchiello di un voxel: zero il più denso, l'ultimo il meno denso. Si scende, e la
        // regione che parte dal punto più denso arriva prima ovunque il percorso resti alto.
        let lowest = Double(interval.minimum)
        let highest = Double(interval.maximum)
        let span = Swift.max(highest - lowest, 1)
        func bucket(of raw: Int16) -> Int {
            let position = (Double(raw) - lowest) / span
            let index = Int(((1 - position) * Double(buckets - 1)).rounded())
            return Swift.min(Swift.max(index, 0), buckets - 1)
        }

        var queues = [[Int32]](repeating: [], count: buckets)

        // I semi entrano tutti prima di cominciare, così un conflitto si vede subito e non
        // dipende dall'ordine in cui li si è scritti.
        for seed in seeds {
            guard seed.label != VolumeMask.background else {
                throw SegmentKitError.backgroundLabelNotAllowed
            }
            let index = try seedIndex(seed.seedMM, geometry: geometry)
            guard interval.contains(volume.samples[index]) else {
                throw SegmentKitError.seedOutsideDensityRange
            }
            let existing = mask.labels[index]
            if existing != VolumeMask.background, existing != seed.label {
                throw SegmentKitError.seedLabelConflict(
                    index: index, first: existing, second: seed.label)
            }
            guard existing == VolumeMask.background else { continue }
            mask.setLabel(seed.label, atIndex: index)
            queues[bucket(of: volume.samples[index])].append(Int32(index))
        }

        let offsets: [Int] = {
            var result = [1, -1, columns, -columns, planeSize, -planeSize]
            guard connectivity == .full else { return result }
            for dz in -1...1 {
                for dy in -1...1 {
                    for dx in -1...1 where !(dx == 0 && dy == 0 && dz == 0) {
                        let offset = dx + dy * columns + dz * planeSize
                        if !result.contains(offset) { result.append(offset) }
                    }
                }
            }
            return result
        }()

        // Si svuota un secchiello alla volta, dal più denso al meno denso. Un voxel raggiunto da
        // un fronte più denso è già assegnato quando il fronte meno denso ci arriva, e non
        // cambia più padrone: è questo che fa cadere il confine nel punto più scuro.
        for level in 0..<buckets {
            var cursor = 0
            while cursor < queues[level].count {
                let index = Int(queues[level][cursor])
                cursor += 1
                let label = mask.labels[index]

                let i = index % columns
                let j = (index / columns) % rows
                let k = index / planeSize

                for offset in offsets {
                    let neighbour = index + offset
                    guard neighbour >= 0, neighbour < voxelCount else { continue }
                    // Il passo lungo x non deve scavalcare il bordo della riga, e quello lungo y
                    // il bordo del piano: in un indice lineare due voxel ai capi opposti di una
                    // riga sono adiacenti, e senza questo controllo la regione uscirebbe da una
                    // parte e rientrerebbe dall'altra.
                    let ni = neighbour % columns
                    let nj = (neighbour / columns) % rows
                    let nk = neighbour / planeSize
                    guard abs(ni - i) <= 1, abs(nj - j) <= 1, abs(nk - k) <= 1 else { continue }

                    guard mask.labels[neighbour] == VolumeMask.background else { continue }
                    let sample = volume.samples[neighbour]
                    guard interval.contains(sample) else { continue }

                    mask.setLabel(label, atIndex: neighbour)
                    // Mai in un secchiello già svuotato: un voxel più denso del fronte corrente
                    // si mette in quello corrente, altrimenti resterebbe fermo per sempre.
                    let target = Swift.max(bucket(of: sample), level)
                    queues[target].append(Int32(neighbour))
                }
            }
            // Il secchiello svuotato non serve più: liberarlo tiene la memoria al minimo su un
            // volume grande, dove tenerli tutti costerebbe quanto la maschera.
            queues[level] = []
        }

        return mask
    }

    private static func seedIndex(_ seedMM: Vec3, geometry: VolumeGeometry) throws -> Int {
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
        return i + j * geometry.columnCount + k * geometry.columnCount * geometry.rowCount
    }
}
