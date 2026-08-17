import Foundation
import MeshKit

/// Errori che impediscono di consegnare una dima alla stampante.
public enum GuideExportError: Error, Hashable, Sendable, LocalizedError {
    case guideNotPrintable(reasons: [String])

    public var errorDescription: String? {
        switch self {
        case .guideNotPrintable(let reasons):
            let detail = reasons.isEmpty ? "validazione non superata" : reasons.joined(separator: "; ")
            return "Esportazione della dima rifiutata: \(detail)."
        }
    }
}

/// Esportazione della geometria e del riepilogo produttivo della dima.
public enum GuideExport: Sendable {
    /// Esporta STL binario soltanto dopo una validazione positiva.
    public static func stl(_ result: GuideResult) throws -> Data {
        guard result.validation.isPrintable else {
            var reasons = result.validation.warnings
            if !result.validation.isWatertight {
                reasons.append("la mesh non è chiusa")
            }
            if !result.validation.hasConsistentOrientation {
                reasons.append("l'orientamento dei triangoli non è coerente")
            }
            if !result.validation.volumeMM3.isFinite || result.validation.volumeMM3 <= 0 {
                reasons.append("il volume non è finito e positivo")
            }
            if let thickness = result.validation.minimumWallThicknessMM {
                if !thickness.isFinite || thickness <= 0 {
                    reasons.append("lo spessore minimo non è valido")
                }
            } else {
                reasons.append("lo spessore minimo non è valido")
            }
            throw GuideExportError.guideNotPrintable(reasons: reasons)
        }
        return MeshIO.exportSTLBinary(result.mesh)
    }

    /// Riepilogo in italiano da conservare insieme al file destinato alla produzione.
    public static func manifest(
        _ result: GuideResult,
        configuration: GuideConfiguration
    ) -> String {
        var lines: [String] = []
        lines.append("MANIFEST DELLA DIMA")
        lines.append("")
        lines.append(String(format: "Volume: %.3f mm³", result.validation.volumeMM3))
        lines.append(
            String(format: "Tolleranza di adattamento: %.3f mm", configuration.fitToleranceMM))
        lines.append(
            String(format: "Spessore nominale della parete: %.3f mm", configuration.wallThicknessMM))
        lines.append(String(format: "Passo della griglia: %.3f mm", configuration.gridSpacingMM))
        if let thickness = result.validation.minimumWallThicknessMM {
            lines.append(String(format: "Spessore minimo verificato: %.3f mm", thickness))
        } else {
            lines.append("Spessore minimo verificato: non disponibile")
        }
        lines.append("Mesh chiusa: \(result.validation.isWatertight ? "sì" : "no")")
        lines.append(
            "Orientamento coerente: "
                + (result.validation.hasConsistentOrientation ? "sì" : "no"))
        lines.append("Stampabile: \(result.validation.isPrintable ? "sì" : "no")")
        lines.append("")
        lines.append("Boccole: \(result.sleeves.count)")
        for index in result.sleeves.indices {
            let sleeve = result.sleeves[index]
            lines.append(
                String(
                    format: "- %d: interno %.3f mm, esterno %.3f mm, altezza %.3f mm, "
                        + "offset piattaforma %.3f mm",
                    index + 1,
                    sleeve.innerDiameterMM,
                    sleeve.outerDiameterMM,
                    sleeve.heightMM,
                    sleeve.offsetToPlatformMM))
        }
        if !result.validation.warnings.isEmpty {
            lines.append("")
            lines.append("Avvertenze:")
            for warning in result.validation.warnings { lines.append("- \(warning)") }
        }

        lines.append("")
        lines.append(
            "La dima stampata è un dispositivo su misura ai sensi del MDR, Allegato XIII. "
                + "Gli obblighi regolatori e documentali ricadono su chi la produce.")
        lines.append(
            "La produzione richiede una resina biocompatibile certificata ISO 10993-1 / "
                + "USP Class VI e dichiarata compatibile con il processo di sterilizzazione "
                + "effettivamente utilizzato.")
        return lines.joined(separator: "\n")
    }
}
