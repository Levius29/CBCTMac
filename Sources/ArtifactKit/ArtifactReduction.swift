import Foundation
import DICOMCore
import SegmentKit

/// Impostazioni complete della pipeline di riduzione degli artefatti metallici.
public struct ArtifactReductionSettings: Hashable, Sendable, Codable {
    public var thresholdGV: Double?
    public var minimumMetalVolumeMM3: Double
    public var dilationMM: Double
    public var streak: StreakSuppressionParameters

    /// Valori iniziali prudenti; la soglia resta automatica perché i GV non sono calibrati.
    public init() {
        thresholdGV = nil
        minimumMetalVolumeMM3 = 1
        dilationMM = 1
        streak = StreakSuppressionParameters()
    }
}

/// Errori che impediscono una correzione affidabile del volume.
public enum ArtifactReductionError: Error, Hashable, Sendable, LocalizedError {
    case noMetalFound(thresholdGV: Double)
    case metalTooExtensive(fraction: Double)
    case invalidParameters(detail: String)

    /// Descrizione localizzata pronta per l'interfaccia utente.
    public var errorDescription: String? {
        switch self {
        case .noMetalFound(let threshold):
            return String(format: "Nessun metallo trovato con soglia %.1f GV.", threshold)
        case .metalTooExtensive(let fraction):
            return String(
                format: "La maschera metallica occupa il %.1f%% del volume e supera il limite del 5%%.",
                fraction * 100
            )
        case .invalidParameters(let detail):
            return "Parametri di riduzione degli artefatti non validi: \(detail)"
        }
    }
}

/// Pipeline completa di rilevamento e soppressione delle strie metalliche.
public enum ArtifactReduction: Sendable {
    /// Frazione massima che può essere classificata come metallo senza rischiare l'anatomia.
    public static let maximumMetalFraction = 0.05

    /// Individua il metallo e ne sopprime le strie.
    ///
    /// Se non trova metallo restituisce il volume invariato con provenienza vuota. Non lancia
    /// `noMetalFound`: l'assenza di metallo è un esito ordinario e il risultato lo comunica senza
    /// nascondere volume e maschera al chiamante.
    public static func reduceMetalArtifacts(
        in volume: Volume,
        settings: ArtifactReductionSettings
    ) throws -> ProcessedVolume {
        try validate(settings)
        let detection = try MetalDetection.detect(
            in: volume,
            thresholdGV: settings.thresholdGV,
            minimumVolumeMM3: settings.minimumMetalVolumeMM3
        )
        let metalVoxelCount = foregroundCount(detection.mask)
        guard metalVoxelCount > 0 else {
            return ProcessedVolume(
                volume: volume,
                provenance: VolumeProvenance(steps: []),
                modifiedMask: detection.mask
            )
        }

        let fraction = Double(metalVoxelCount) / Double(volume.samples.count)
        guard fraction <= maximumMetalFraction else {
            throw ArtifactReductionError.metalTooExtensive(fraction: fraction)
        }

        // La dilatazione appartiene alla penombra da correggere. Il limite del 5% usa invece il
        // metallo rilevato, altrimenti il margine fisico farebbe apparire pericolosa una corona
        // piccola in un volume con voxel grandi.
        let correctionMask = try Morphology.dilated(detection.mask, byMM: settings.dilationMM)
        return try PolarStreakSuppression.apply(
            to: volume,
            metalMask: correctionMask,
            parameters: settings.streak
        )
    }

    private static func validate(_ settings: ArtifactReductionSettings) throws {
        if let threshold = settings.thresholdGV, !threshold.isFinite {
            throw ArtifactReductionError.invalidParameters(
                detail: "La soglia manuale deve essere finita."
            )
        }
        guard settings.minimumMetalVolumeMM3.isFinite,
              settings.minimumMetalVolumeMM3 >= 0
        else {
            throw ArtifactReductionError.invalidParameters(
                detail: "Il volume minimo del metallo deve essere finito e non negativo."
            )
        }
        guard settings.dilationMM.isFinite, settings.dilationMM >= 0 else {
            throw ArtifactReductionError.invalidParameters(
                detail: "La dilatazione deve essere finita e non negativa."
            )
        }
        guard settings.streak.radiusMM.isFinite, settings.streak.radiusMM > 0,
              settings.streak.angularWindowDegrees.isFinite,
              settings.streak.angularWindowDegrees > 0,
              settings.streak.angularWindowDegrees <= 360,
              settings.streak.strength.isFinite,
              settings.streak.strength >= 0,
              settings.streak.strength <= 1
        else {
            throw ArtifactReductionError.invalidParameters(
                detail: "I parametri della soppressione delle strie sono fuori intervallo."
            )
        }
    }

    private static func foregroundCount(_ mask: VolumeMask) -> Int {
        var count = 0
        for label in mask.labels where label != VolumeMask.background { count += 1 }
        return count
    }
}
