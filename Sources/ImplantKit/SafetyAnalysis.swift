import DICOMCore
import Foundation

// Analisi di sicurezza e densità ossea attorno a un impianto pianificato.
//
// Le soglie sono quelle correnti in letteratura implantare — due millimetri di margine dal
// canale alveolare — ma restano **parametri**, non verità: le imposta il clinico. Il software
// misura e segnala, non decide. Il banner di uso non diagnostico vale qui più che altrove.

// MARK: - Livello

public enum SafetyLevel: String, Hashable, Sendable, Codable, Comparable {
    case safe
    case caution
    case danger

    private var order: Int {
        switch self {
        case .safe: return 0
        case .caution: return 1
        case .danger: return 2
        }
    }

    public static func < (a: SafetyLevel, b: SafetyLevel) -> Bool { a.order < b.order }

    public var localizedName: String {
        switch self {
        case .safe: return "Sicuro"
        case .caution: return "Attenzione"
        case .danger: return "Critico"
        }
    }

    /// Colore suggerito, in `#RRGGBB`.
    public var colorHex: String {
        switch self {
        case .safe: return "#30D158"
        case .caution: return "#FFD60A"
        case .danger: return "#FF453A"
        }
    }
}

/// Soglie di prossimità, in millimetri.
public struct SafetyThresholds: Hashable, Sendable, Codable {
    /// Sotto questa distanza la situazione è critica.
    public var dangerMM: Double
    /// Sotto questa distanza serve attenzione.
    public var cautionMM: Double

    public init(dangerMM: Double = 1.0, cautionMM: Double = 2.0) {
        self.dangerMM = dangerMM
        self.cautionMM = max(cautionMM, dangerMM)
    }

    /// Margine di due millimetri dal canale alveolare: è il valore più citato in letteratura.
    public static let nerve = SafetyThresholds(dangerMM: 1.0, cautionMM: 2.0)
    /// Fra impianti adiacenti si raccomandano tre millimetri di osso interposto.
    public static let adjacentImplant = SafetyThresholds(dangerMM: 1.5, cautionMM: 3.0)

    public func level(for distanceMM: Double) -> SafetyLevel {
        if distanceMM < dangerMM { return .danger }
        if distanceMM < cautionMM { return .caution }
        return .safe
    }
}

// MARK: - Esito di prossimità

public struct ProximityFinding: Hashable, Sendable, Identifiable {
    public var id: String { structureName }

    public let structureName: String
    /// Distanza fra le due **superfici**, in millimetri. Negativa se si compenetrano.
    public let distanceMM: Double
    public let level: SafetyLevel
    /// Punto sull'impianto più vicino alla struttura, per disegnare la linea di quota.
    public let implantPointMM: Vec3?
    public let structurePointMM: Vec3?

    public init(
        structureName: String,
        distanceMM: Double,
        level: SafetyLevel,
        implantPointMM: Vec3? = nil,
        structurePointMM: Vec3? = nil
    ) {
        self.structureName = structureName
        self.distanceMM = distanceMM
        self.level = level
        self.implantPointMM = implantPointMM
        self.structurePointMM = structurePointMM
    }

    public var formattedDistance: String {
        if distanceMM < 0 {
            return String(format: "compenetrazione %.1f mm", -distanceMM)
                .replacingOccurrences(of: ".", with: ",")
        }
        return String(format: "%.1f mm", distanceMM).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Densità ossea

/// Statistiche di densità di una fascia attorno all'impianto.
public struct DensityBand: Hashable, Sendable {
    public let name: String
    public let sampleCount: Int
    public let mean: Double
    public let standardDeviation: Double
    public let minimum: Double
    public let maximum: Double
    public let unit: DensityUnit

    public var summary: String {
        String(format: "%.0f ± %.0f %@", mean, standardDeviation, unit.symbol)
            .replacingOccurrences(of: "-", with: "−")
    }
}

/// Densità dell'osso attorno all'impianto, divisa per terzi.
///
/// La divisione in terzi non è decorativa: la stabilità primaria dipende soprattutto
/// dall'osso corticale del terzo coronale, mentre un terzo apicale povero conta meno. Un
/// valore medio unico nasconderebbe proprio la distinzione che serve.
public struct BoneDensityProfile: Hashable, Sendable {
    public let coronal: DensityBand
    public let middle: DensityBand
    public let apical: DensityBand
    public let overall: DensityBand

    public var bands: [DensityBand] { [coronal, middle, apical] }
}

// MARK: - Rapporto

public struct SafetyReport: Hashable, Sendable {
    public let implantID: UUID
    public let findings: [ProximityFinding]
    public let density: BoneDensityProfile?
    /// Angolo con l'impianto meno parallelo, in gradi. `nil` se è l'unico.
    public let maxParallelismDeviationDegrees: Double?
    /// Inclinazione rispetto alla verticale del paziente, in gradi.
    public let angulationDegrees: Double?

    /// Livello complessivo: il peggiore fra tutti i riscontri.
    public var worstLevel: SafetyLevel {
        findings.map(\.level).max() ?? .safe
    }
}

// MARK: - Analizzatore

public enum SafetyAnalyzer {

    /// Analizza un impianto rispetto a nervi, impianti adiacenti e osso circostante.
    ///
    /// - Parameters:
    ///   - implant: l'impianto da valutare.
    ///   - nerves: canali tracciati.
    ///   - otherImplants: gli altri impianti pianificati; quello in esame viene escluso.
    ///   - volume: se presente, si calcola anche la densità ossea.
    ///   - referenceUp: direzione verticale di riferimento per l'angolazione.
    public static func analyze(
        implant: ImplantPlacement,
        nerves: [NerveCanal],
        otherImplants: [ImplantPlacement],
        volume: Volume?,
        thresholds: SafetyThresholds = .nerve,
        adjacentThresholds: SafetyThresholds = .adjacentImplant,
        referenceUp: Vec3 = Vec3(0, 0, 1)
    ) -> SafetyReport {

        var findings: [ProximityFinding] = []

        // Punti sulla superficie dell'impianto: la distanza si misura da lì, non dall'asse.
        // Usare l'asse regalerebbe un raggio intero di margine — due millimetri su un impianto
        // da 4,1, cioè l'intera soglia di sicurezza.
        let surface = implant.surfacePoints(levels: 16, radialSteps: 20)

        // MARK: Nervi
        for nerve in nerves where nerve.isUsable {
            var best = Double.infinity
            var bestImplantPoint: Vec3?

            for point in surface {
                guard let distance = nerve.signedDistance(from: point) else { continue }
                if distance < best {
                    best = distance
                    bestImplantPoint = point
                }
            }
            guard best.isFinite, let implantPoint = bestImplantPoint else { continue }

            findings.append(
                ProximityFinding(
                    structureName: nerve.localizedName,
                    distanceMM: best,
                    level: thresholds.level(for: best),
                    implantPointMM: implantPoint,
                    structurePointMM: nerve.closestPoint(to: implantPoint)))
        }

        // MARK: Impianti adiacenti
        for other in otherImplants where other.id != implant.id {
            var best = Double.infinity
            var bestPoint: Vec3?
            for point in surface {
                let distance = other.signedDistance(from: point)
                if distance < best {
                    best = distance
                    bestPoint = point
                }
            }
            guard best.isFinite, let bestPoint else { continue }

            let name = other.label.isEmpty ? "Impianto adiacente" : other.label
            findings.append(
                ProximityFinding(
                    structureName: name,
                    distanceMM: best,
                    level: adjacentThresholds.level(for: best),
                    implantPointMM: bestPoint,
                    structurePointMM: nil))
        }

        // MARK: Parallelismo
        var maxDeviation: Double?
        for other in otherImplants where other.id != implant.id {
            let degrees = implant.angle(to: other) * 180 / Double.pi
            maxDeviation = max(maxDeviation ?? 0, degrees)
        }

        // MARK: Densità
        let density = volume.flatMap { boneDensity(around: implant, in: $0) }

        return SafetyReport(
            implantID: implant.id,
            findings: findings.sorted { $0.distanceMM < $1.distanceMM },
            density: density,
            maxParallelismDeviationDegrees: maxDeviation,
            angulationDegrees: implant.angleDegrees(to: referenceUp))
    }

    // MARK: Densità ossea

    /// Campiona la densità su un guscio cilindrico appena fuori dalla superficie implantare.
    ///
    /// Lo scarto di mezzo millimetro dalla superficie è deliberato: campionare esattamente sul
    /// contorno prenderebbe voxel a cavallo del bordo, mediando osso e — su un caso reale con
    /// un impianto già presente — artefatti metallici. Mezzo millimetro fuori si legge l'osso
    /// che accoglierà l'impianto, che è ciò che interessa sapere prima di inserirlo.
    public static func boneDensity(
        around implant: ImplantPlacement,
        in volume: Volume,
        offsetMM: Double = 0.5,
        levels: Int = 30,
        radialSteps: Int = 16
    ) -> BoneDensityProfile? {

        guard let basis = implant.perpendicularBasis() else { return nil }

        var coronal: [Double] = []
        var middle: [Double] = []
        var apical: [Double] = []

        let length = implant.model.lengthMM
        for level in 0..<levels {
            let z = length * Double(level) / Double(max(levels - 1, 1))
            let radius = implant.model.radius(atZ: z) + offsetMM
            let centre = implant.axisPoint(atZ: z)

            for step in 0..<radialSteps {
                let angle = 2 * Double.pi * Double(step) / Double(radialSteps)
                let direction = basis.u * Foundation.cos(angle) + basis.v * Foundation.sin(angle)
                let point = centre + direction * radius

                // Campionamento nearest sui dati di CPU, come prescrive il Contratto 3:
                // interpolare restituirebbe valori che nel volume non esistono.
                guard let value = volume.densityValue(atPatient: point) else { continue }

                let fraction = z / length
                if fraction < 1.0 / 3.0 {
                    coronal.append(value)
                } else if fraction < 2.0 / 3.0 {
                    middle.append(value)
                } else {
                    apical.append(value)
                }
            }
        }

        let all = coronal + middle + apical
        guard !all.isEmpty else { return nil }

        return BoneDensityProfile(
            coronal: band(named: "Terzo coronale", values: coronal, unit: volume.densityUnit),
            middle: band(named: "Terzo medio", values: middle, unit: volume.densityUnit),
            apical: band(named: "Terzo apicale", values: apical, unit: volume.densityUnit),
            overall: band(named: "Complessivo", values: all, unit: volume.densityUnit))
    }

    private static func band(named name: String, values: [Double], unit: DensityUnit)
        -> DensityBand
    {
        guard !values.isEmpty else {
            return DensityBand(
                name: name, sampleCount: 0, mean: 0, standardDeviation: 0,
                minimum: 0, maximum: 0, unit: unit)
        }

        let count = values.count
        let mean = values.reduce(0, +) / Double(count)

        // Somma degli scarti e non `E[x²] − E[x]²`: i valori sono grandi e la dispersione
        // piccola, il caso in cui la seconda forma perde cifre significative.
        var sumSquared = 0.0
        for value in values {
            let d = value - mean
            sumSquared += d * d
        }
        let variance = count > 1 ? sumSquared / Double(count - 1) : 0

        return DensityBand(
            name: name,
            sampleCount: count,
            mean: mean,
            standardDeviation: variance.squareRoot(),
            minimum: values.min() ?? 0,
            maximum: values.max() ?? 0,
            unit: unit)
    }
}
