import DICOMCore
import Foundation

// Statistiche di densità su regioni di interesse.
//
// Implementa la conseguenza operativa del Contratto 3 di docs/architecture.md: **si campionano
// i valori grezzi `Int16` su CPU**, mai la texture GPU.
//
// La texture è filtrata trilinearmente. Una media calcolata su valori interpolati è verosimile
// e falsa; peggio, il minimo e il massimo risultano valori che nel dato reale non esistono,
// perché nati da una media fra vicini. Per una lettura di densità è inaccettabile.
//
// Il campionamento avviene per voxel effettivi: si scorre la scatola di contenimento della ROI
// in coordinate voxel e si verifica l'appartenenza del centro di ogni voxel. Non c'è
// ricampionamento, quindi `voxelCount` è un conteggio reale e non una stima.

// MARK: - Esito

public struct ROIStatistics: Hashable, Sendable {
    /// Numero di voxel effettivamente campionati.
    public let voxelCount: Int
    public let mean: Double
    /// Deviazione standard campionaria (denominatore `n − 1`).
    public let standardDeviation: Double
    public let minimum: Double
    public let maximum: Double
    public let median: Double
    /// Unità in cui vanno letti i valori: su CBCT è `.greyValue`.
    public let unit: DensityUnit
    /// Volume effettivamente campionato: `voxelCount` × volume del voxel.
    public let sampledVolumeMM3: Double
    /// Area analitica della figura, per le ROI planari. `nil` per quelle solide.
    public let analyticAreaMM2: Double?

    public init(
        voxelCount: Int,
        mean: Double,
        standardDeviation: Double,
        minimum: Double,
        maximum: Double,
        median: Double,
        unit: DensityUnit,
        sampledVolumeMM3: Double,
        analyticAreaMM2: Double?
    ) {
        self.voxelCount = voxelCount
        self.mean = mean
        self.standardDeviation = standardDeviation
        self.minimum = minimum
        self.maximum = maximum
        self.median = median
        self.unit = unit
        self.sampledVolumeMM3 = sampledVolumeMM3
        self.analyticAreaMM2 = analyticAreaMM2
    }

    /// Riga sintetica per l'elenco misure, per esempio `412 ± 88 GV`.
    public var summary: String {
        MeasurementFormatter.densityWithDeviation(
            mean: mean, standardDeviation: standardDeviation, unit: unit)
    }

    /// Righe etichetta/valore per l'ispettore.
    public var detailRows: [(label: String, value: String)] {
        var rows: [(String, String)] = [
            ("Media", MeasurementFormatter.density(mean, unit: unit)),
            ("Dev. standard", String(format: "%.1f %@", standardDeviation, unit.symbol)),
            ("Mediana", MeasurementFormatter.density(median, unit: unit)),
            ("Minimo", MeasurementFormatter.density(minimum, unit: unit)),
            ("Massimo", MeasurementFormatter.density(maximum, unit: unit)),
            ("Voxel", "\(voxelCount)"),
            ("Volume", MeasurementFormatter.volume(sampledVolumeMM3)),
        ]
        if let area = analyticAreaMM2 {
            rows.insert(("Area", MeasurementFormatter.area(area)), at: 5)
        }
        return rows
    }
}

public enum ROISamplingError: Error, Hashable, Sendable {
    /// La regione non contiene alcun voxel: fuori dal volume, o più piccola di un voxel.
    case emptyRegion
    /// Regione troppo estesa per essere campionata in memoria.
    case regionTooLarge(voxelCount: Int, limit: Int)
    case degenerateGeometry

    public var localizedDescription: String {
        switch self {
        case .emptyRegion:
            return "La regione non contiene voxel: è fuori dal volume oppure più piccola di "
                + "un voxel."
        case .regionTooLarge(let count, let limit):
            return "Regione troppo estesa: \(count) voxel contro un limite di \(limit). "
                + "Riduci le dimensioni della ROI."
        case .degenerateGeometry:
            return "Geometria della regione degenere."
        }
    }
}

// MARK: - Campionatore

public enum ROISampler {

    /// Limite di voxel campionabili in una sola ROI.
    ///
    /// Venti milioni di `Int16` sono 40 MB: abbondanti per qualunque ROI clinica, che sta
    /// nell'ordine delle migliaia di voxel. Il limite esiste per impedire che un trascinamento
    /// distratto su un volume da 0,15 mm provi ad allocare svariati gigabyte.
    public static let maxVoxelCount = 20_000_000

    // MARK: ROI ellittica

    public static func statistics(
        for roi: EllipseROI, in volume: Volume
    ) throws -> ROIStatistics {
        let halfThickness = max(roi.thicknessMM * 0.5, 1e-6)
        guard let normal = roi.normalMM.normalized else {
            throw ROISamplingError.degenerateGeometry
        }
        let extent = roi.semiAxisAMM.length + roi.semiAxisBMM.length + halfThickness
        let samples = try collect(
            in: volume,
            centerMM: roi.centerMM,
            radiusMM: extent,
            contains: { p in
                let d = p - roi.centerMM
                guard abs(d.dot(normal)) <= halfThickness else { return false }
                let lenA = roi.semiAxisAMM.length
                let lenB = roi.semiAxisBMM.length
                guard lenA > 0, lenB > 0 else { return false }
                let u = d.dot(roi.semiAxisAMM) / (lenA * lenA)
                let v = d.dot(roi.semiAxisBMM) / (lenB * lenB)
                return u * u + v * v <= 1.0
            })
        return try summarize(samples, volume: volume, analyticAreaMM2: roi.areaMM2)
    }

    // MARK: ROI poligonale

    public static func statistics(
        for roi: PolygonROI, in volume: Volume
    ) throws -> ROIStatistics {
        guard roi.verticesMM.count >= 3 else { throw ROISamplingError.degenerateGeometry }
        let centroid = roi.centroidMM
        let halfThickness = max(roi.thicknessMM * 0.5, 1e-6)
        var maxRadius = 0.0
        for v in roi.verticesMM {
            maxRadius = max(maxRadius, v.distance(to: centroid))
        }
        let samples = try collect(
            in: volume,
            centerMM: centroid,
            radiusMM: maxRadius + halfThickness,
            contains: { roi.contains($0) })
        return try summarize(samples, volume: volume, analyticAreaMM2: roi.areaMM2)
    }

    // MARK: ROI sferica

    public static func statistics(
        for roi: SphereROI, in volume: Volume
    ) throws -> ROIStatistics {
        guard roi.radiusMM > 0 else { throw ROISamplingError.degenerateGeometry }
        let radiusSquared = roi.radiusMM * roi.radiusMM
        let samples = try collect(
            in: volume,
            centerMM: roi.centerMM,
            radiusMM: roi.radiusMM,
            contains: { ($0 - roi.centerMM).lengthSquared <= radiusSquared })
        return try summarize(samples, volume: volume, analyticAreaMM2: nil)
    }

    // MARK: Nucleo del campionamento

    /// Raccoglie i valori grezzi dei voxel il cui **centro** cade dentro la regione.
    ///
    /// Si ricava la scatola di contenimento in coordinate voxel trasformando gli otto vertici
    /// della scatola sferica in mm: su piani obliqui questo copre più del necessario, ma il
    /// test di appartenenza scarta gli esuberi e il conteggio resta esatto.
    private static func collect(
        in volume: Volume,
        centerMM: Vec3,
        radiusMM: Double,
        contains: (Vec3) -> Bool
    ) throws -> [Int16] {

        let geometry = volume.geometry
        guard radiusMM.isFinite, radiusMM > 0 else { throw ROISamplingError.degenerateGeometry }

        // Otto vertici della scatola in mm → coordinate voxel → estremi interi.
        var minVoxel = Vec3(.infinity, .infinity, .infinity)
        var maxVoxel = Vec3(-.infinity, -.infinity, -.infinity)
        for dx in [-radiusMM, radiusMM] {
            for dy in [-radiusMM, radiusMM] {
                for dz in [-radiusMM, radiusMM] {
                    let corner = geometry.voxelPoint(
                        fromPatient: centerMM + Vec3(dx, dy, dz))
                    minVoxel = Vec3(
                        Swift.min(minVoxel.x, corner.x),
                        Swift.min(minVoxel.y, corner.y),
                        Swift.min(minVoxel.z, corner.z))
                    maxVoxel = Vec3(
                        Swift.max(maxVoxel.x, corner.x),
                        Swift.max(maxVoxel.y, corner.y),
                        Swift.max(maxVoxel.z, corner.z))
                }
            }
        }
        guard minVoxel.isFinite, maxVoxel.isFinite else {
            throw ROISamplingError.degenerateGeometry
        }

        let i0 = Swift.max(0, Int(minVoxel.x.rounded(.down)))
        let j0 = Swift.max(0, Int(minVoxel.y.rounded(.down)))
        let k0 = Swift.max(0, Int(minVoxel.z.rounded(.down)))
        let i1 = Swift.min(geometry.columnCount - 1, Int(maxVoxel.x.rounded(.up)))
        let j1 = Swift.min(geometry.rowCount - 1, Int(maxVoxel.y.rounded(.up)))
        let k1 = Swift.min(geometry.sliceCount - 1, Int(maxVoxel.z.rounded(.up)))

        guard i0 <= i1, j0 <= j1, k0 <= k1 else { throw ROISamplingError.emptyRegion }

        let boxCount = (i1 - i0 + 1) * (j1 - j0 + 1) * (k1 - k0 + 1)
        guard boxCount <= maxVoxelCount else {
            throw ROISamplingError.regionTooLarge(voxelCount: boxCount, limit: maxVoxelCount)
        }

        var samples: [Int16] = []
        samples.reserveCapacity(Swift.min(boxCount, 1 << 16))

        volume.withUnsafeSamples { buffer in
            for k in k0...k1 {
                for j in j0...j1 {
                    // L'indice di riga si calcola una volta sola: nel ciclo interno resta
                    // un semplice incremento, che su ROI grandi conta.
                    let rowBase = (k * geometry.rowCount + j) * geometry.columnCount
                    for i in i0...i1 {
                        let p = geometry.patientPoint(i: i, j: j, k: k)
                        if contains(p) {
                            samples.append(buffer[rowBase + i])
                        }
                    }
                }
            }
        }

        guard !samples.isEmpty else { throw ROISamplingError.emptyRegion }
        return samples
    }

    /// Calcola le statistiche dai campioni grezzi, applicando il rescale del volume.
    private static func summarize(
        _ raw: [Int16], volume: Volume, analyticAreaMM2: Double?
    ) throws -> ROIStatistics {

        guard !raw.isEmpty else { throw ROISamplingError.emptyRegion }

        let n = raw.count
        var sum = 0.0
        var minRaw = raw[0]
        var maxRaw = raw[0]

        for value in raw {
            sum += Double(value)
            if value < minRaw { minRaw = value }
            if value > maxRaw { maxRaw = value }
        }

        let meanRaw = sum / Double(n)

        // Varianza campionaria per somma degli scarti, in un secondo passaggio.
        // La forma equivalente `E[x²] − E[x]²` è numericamente instabile quando i valori sono
        // grandi e la varianza piccola — cioè esattamente il caso di una ROI dentro l'osso,
        // dove i valori stanno attorno a qualche migliaio e la dispersione è di poche decine.
        // Il secondo passaggio costa poco e non perde cifre significative.
        var sumSquaredDeviations = 0.0
        for value in raw {
            let d = Double(value) - meanRaw
            sumSquaredDeviations += d * d
        }
        let varianceRaw = n > 1 ? sumSquaredDeviations / Double(n - 1) : 0

        let sorted = raw.sorted()
        let medianRaw: Double =
            n % 2 == 1
            ? Double(sorted[n / 2])
            : (Double(sorted[n / 2 - 1]) + Double(sorted[n / 2])) * 0.5

        let slope = volume.rescaleSlope
        let spacing = volume.geometry.spacingMM
        let voxelVolume = spacing.x * spacing.y * spacing.z

        // Il rescale è affine, quindi si applica direttamente agli indici statistici invece
        // che voxel per voxel: media e mediana si trasformano per intero, la deviazione
        // standard solo con il modulo dello slope, perché l'intercetta trasla e non disperde.
        return ROIStatistics(
            voxelCount: n,
            mean: meanRaw * slope + volume.rescaleIntercept,
            standardDeviation: varianceRaw.squareRoot() * abs(slope),
            minimum: volume.applyRescale(minRaw),
            maximum: volume.applyRescale(maxRaw),
            median: medianRaw * slope + volume.rescaleIntercept,
            unit: volume.densityUnit,
            sampledVolumeMM3: Double(n) * voxelVolume,
            analyticAreaMM2: analyticAreaMM2
        )
    }
}

// MARK: - Profilo di densità

public struct ProfileSample: Hashable, Sendable {
    /// Distanza dall'inizio del segmento, in mm.
    public let distanceMM: Double
    public let value: Double
    public let positionMM: Vec3

    public init(distanceMM: Double, value: Double, positionMM: Vec3) {
        self.distanceMM = distanceMM
        self.value = value
        self.positionMM = positionMM
    }
}

extension ROISampler {

    /// Campiona la densità lungo un segmento.
    ///
    /// Qui l'interpolazione trilineare è corretta e voluta: un profilo serve a leggere
    /// l'andamento — dove comincia la corticale, quanto è spessa — e la continuità della curva
    /// conta più della fedeltà al singolo voxel. È l'unico caso in cui il Contratto 3 ammette
    /// il campionamento interpolato, perché non se ne ricava una statistica.
    public static func profile(for line: ProfileLine, in volume: Volume) -> [ProfileSample] {
        let count = max(2, line.sampleCount)
        let total = line.lengthMM
        var out: [ProfileSample] = []
        out.reserveCapacity(count)

        for n in 0..<count {
            let t = Double(n) / Double(count - 1)
            let p = line.startMM.lerp(to: line.endMM, t: t)
            guard let value = volume.interpolatedDensityValue(atPatient: p) else { continue }
            out.append(
                ProfileSample(distanceMM: t * total, value: value, positionMM: p))
        }
        return out
    }
}
