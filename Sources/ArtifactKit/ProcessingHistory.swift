import Foundation
import DICOMCore
import SegmentKit

/// Che cosa è stato fatto a un volume dopo l'acquisizione.
public struct ProcessingStep: Hashable, Sendable, Codable {
    public var name: String
    public var parametersDescription: String
    public var affectedVoxelCount: Int
    public var date: Date

    /// Registra un passaggio con i parametri mostrabili e il numero di voxel alterati.
    public init(
        name: String,
        parametersDescription: String,
        affectedVoxelCount: Int,
        date: Date
    ) {
        self.name = name
        self.parametersDescription = parametersDescription
        self.affectedVoxelCount = affectedVoxelCount
        self.date = date
    }
}

/// Storia delle elaborazioni applicate a un volume dopo l'acquisizione.
///
/// Si chiamava `VolumeProvenance` e collideva con l'omonimo di `StudyKit`, che descrive invece da
/// **dove viene** un volume — letto, derivato, sintetico. Due significati legittimi della stessa
/// parola, e un file che importa entrambi i moduli non compila più. Il nome nuovo è anche il più
/// esatto dei due: questo tipo è letteralmente un elenco di `ProcessingStep`, cioè una storia di
/// elaborazioni, non una provenienza.
public struct ProcessingHistory: Hashable, Sendable, Codable {
    public var steps: [ProcessingStep]

    /// Costruisce una storia, vuota per un volume acquisito e non modificato.
    public init(steps: [ProcessingStep]) {
        self.steps = steps
    }

    /// Indica se almeno un'elaborazione ha modificato i valori acquisiti.
    public var isModified: Bool { !steps.isEmpty }

    /// Testo pronto per la barra di stato e per l'esportazione.
    public var summary: String {
        guard !steps.isEmpty else { return "Volume originale non modificato." }
        var descriptions = [String]()
        descriptions.reserveCapacity(steps.count)
        for step in steps {
            var description = "\(step.name): \(step.affectedVoxelCount) voxel"
            if !step.parametersDescription.isEmpty {
                description += " (\(step.parametersDescription))"
            }
            descriptions.append(description)
        }
        return descriptions.joined(separator: "; ")
    }
}

/// Un volume con la sua storia e la maschera dei valori realmente alterati.
public struct ProcessedVolume: Sendable {
    public let volume: Volume
    public let provenance: ProcessingHistory
    /// Voxel il cui valore è stato alterato; è più ampia della sola maschera del metallo.
    public let modifiedMask: VolumeMask

    /// Costruisce un risultato mantenendo insieme dati, storia e area modificata.
    public init(volume: Volume, provenance: ProcessingHistory, modifiedMask: VolumeMask) {
        self.volume = volume
        self.provenance = provenance
        self.modifiedMask = modifiedMask
    }

    /// Vero se il punto indicato cade sul centro del voxel alterato più vicino.
    public func isModified(atPatient point: Vec3) -> Bool {
        let voxel = volume.geometry.voxelPoint(fromPatient: point)
        guard voxel.isFinite else { return false }
        let roundedI = voxel.x.rounded()
        let roundedJ = voxel.y.rounded()
        let roundedK = voxel.z.rounded()
        guard let i = Int(exactly: roundedI),
              let j = Int(exactly: roundedJ),
              let k = Int(exactly: roundedK)
        else { return false }
        return modifiedMask.contains(i: i, j: j, k: k)
    }

    /// Frazione di centri voxel alterati dentro un riquadro Patient.
    ///
    /// Si contano centri reali, non un volume continuo interpolato: la maschera descrive voxel
    /// discreti e una stima geometrica diversa potrebbe nascondere una ROI corretta molto piccola.
    public func modifiedFraction(inBoxMM box: BoxMM) -> Double {
        guard box.minMM.isFinite, box.maxMM.isFinite,
              box.minMM.x <= box.maxMM.x,
              box.minMM.y <= box.maxMM.y,
              box.minMM.z <= box.maxMM.z
        else { return 0 }

        let geometry = volume.geometry
        var minimum = Vec3(Double.infinity, Double.infinity, Double.infinity)
        var maximum = Vec3(-Double.infinity, -Double.infinity, -Double.infinity)
        for point in patientCorners(of: box) {
            let voxel = geometry.voxelPoint(fromPatient: point)
            guard voxel.isFinite else { return 0 }
            minimum = Vec3(
                min(minimum.x, voxel.x),
                min(minimum.y, voxel.y),
                min(minimum.z, voxel.z)
            )
            maximum = Vec3(
                max(maximum.x, voxel.x),
                max(maximum.y, voxel.y),
                max(maximum.z, voxel.z)
            )
        }
        guard let iRange = clampedRange(
                  minimum: minimum.x, maximum: maximum.x, count: geometry.columnCount
              ),
              let jRange = clampedRange(
                  minimum: minimum.y, maximum: maximum.y, count: geometry.rowCount
              ),
              let kRange = clampedRange(
                  minimum: minimum.z, maximum: maximum.z, count: geometry.sliceCount
              )
        else { return 0 }

        var insideCount = 0
        var modifiedCount = 0
        for k in kRange {
            for j in jRange {
                for i in iRange {
                    let point = geometry.patientPoint(i: i, j: j, k: k)
                    guard box.contains(point) else { continue }
                    insideCount += 1
                    if modifiedMask.contains(i: i, j: j, k: k) {
                        modifiedCount += 1
                    }
                }
            }
        }
        guard insideCount > 0 else { return 0 }
        return Double(modifiedCount) / Double(insideCount)
    }

    private func patientCorners(of box: BoxMM) -> [Vec3] {
        [
            Vec3(box.minMM.x, box.minMM.y, box.minMM.z),
            Vec3(box.maxMM.x, box.minMM.y, box.minMM.z),
            Vec3(box.minMM.x, box.maxMM.y, box.minMM.z),
            Vec3(box.maxMM.x, box.maxMM.y, box.minMM.z),
            Vec3(box.minMM.x, box.minMM.y, box.maxMM.z),
            Vec3(box.maxMM.x, box.minMM.y, box.maxMM.z),
            Vec3(box.minMM.x, box.maxMM.y, box.maxMM.z),
            Vec3(box.maxMM.x, box.maxMM.y, box.maxMM.z),
        ]
    }

    private func clampedRange(
        minimum: Double,
        maximum: Double,
        count: Int
    ) -> ClosedRange<Int>? {
        guard maximum >= -0.5, minimum <= Double(count) - 0.5 else { return nil }
        let lowerDouble = max(0, floor(minimum))
        let upperDouble = min(Double(count - 1), ceil(maximum))
        guard lowerDouble <= upperDouble,
              let lower = Int(exactly: lowerDouble),
              let upper = Int(exactly: upperDouble)
        else { return nil }
        return lower...upper
    }
}
