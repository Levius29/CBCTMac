import DICOMCore
import SegmentKit
import Testing

@testable import FollowUpKit

/// Un volume con un valore che cresce linearmente lungo i tre assi: si sa in anticipo che cosa
/// deve restituire ogni interpolazione, quindi gli errori di geometria si vedono come numeri e
/// non come immagini storte.
func makeRampVolume(
    columns: Int = 8,
    rows: Int = 6,
    slices: Int = 4,
    spacingMM: Vec3 = Vec3(0.5, 0.75, 1.0),
    originMM: Vec3 = Vec3(10, 20, 30)
) throws -> Volume {
    let geometry = try VolumeGeometry(
        columnCount: columns,
        rowCount: rows,
        sliceCount: slices,
        columnSpacingMM: spacingMM.x,
        rowSpacingMM: spacingMM.y,
        sliceSpacingMM: spacingMM.z,
        orientation: .standardAxial,
        originMM: originMM
    )
    var samples = [Int16]()
    samples.reserveCapacity(geometry.voxelCount)
    for k in 0..<slices {
        for j in 0..<rows {
            for i in 0..<columns {
                samples.append(Int16(i + 10 * j + 100 * k))
            }
        }
    }
    return try Volume(geometry: geometry, samples: samples)
}

/// Il fantoccio, abbastanza grande da registrarsi e abbastanza piccolo da non far durare la prova
/// più del resto della suite.
func makeRegistrationPhantom() throws -> Volume {
    try SyntheticVolume.makePhantom(
        columns: 80, rows: 80, slices: 80, spacingMM: Vec3(0.75, 0.75, 0.75))
}

/// Impostazioni rapide: meno campioni e meno passi di quelli veri, quanto basta a mostrare che la
/// discesa arriva dove deve.
func quickSettings(
    metric: RegistrationMetricKind = .mutualInformation,
    shrinkFactors: [Int] = [4, 2, 1],
    regionMM: BoxMM? = nil
) -> RegistrationSettings {
    RegistrationSettings(
        metric: metric,
        shrinkFactors: shrinkFactors,
        samplesPerLevel: 3_000,
        maximumIterationsPerLevel: 35,
        initialStepMM: 3.0,
        minimumStepMM: 0.05,
        relaxationFactor: 0.5,
        seed: 42,
        regionMM: regionMM
    )
}

/// La scatola attorno al centro del volume, dove il fantoccio ha le sue strutture.
func centralBox(of volume: Volume, halfSizeMM: Double) -> BoxMM {
    let center = volume.geometry.centerMM
    let half = Vec3(halfSizeMM, halfSizeMM, halfSizeMM)
    return BoxMM(minMM: center - half, maxMM: center + half)
}
