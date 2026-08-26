import Foundation
import DICOMCore

/// Regola con cui vengono considerati adiacenti due voxel.
public enum Connectivity: Hashable, Sendable, Codable {
    /// Sei vicini di faccia; evita che un contatto diagonale unisca due denti distinti.
    case faces
    /// Ventisei vicini, inclusi spigoli e vertici.
    case full
}

/// Crescita di regioni iterativa, sicura anche quando una regione occupa milioni di voxel.
public enum RegionGrowing: Sendable {
    /// Cresce una regione dal seme Patient indicato fino ai limiti di soglia e di dimensione.
    public static func grow(
        in volume: Volume,
        fromSeedMM seed: Vec3,
        densityRange: ClosedRange<Double>,
        within regionMM: BoxMM? = nil,
        connectivity: Connectivity = .faces,
        label: SegmentLabel = 1,
        maximumVoxels: Int? = nil
    ) throws -> VolumeMask {
        guard label != VolumeMask.background else { throw SegmentKitError.backgroundLabelNotAllowed }
        if let maximumVoxels, maximumVoxels <= 0 {
            throw SegmentKitError.invalidMaximumVoxelCount(maximumVoxels)
        }
        return try grow(
            in: volume,
            seeds: [(seedMM: seed, label: label)],
            densityRange: densityRange,
            within: regionMM,
            connectivity: connectivity,
            maximumVoxels: maximumVoxels
        )
    }

    /// Cresce più regioni dalla stessa soglia, conservando l'etichetta assegnata a ogni seme.
    public static func grow(
        in volume: Volume,
        seeds: [(seedMM: Vec3, label: SegmentLabel)],
        densityRange: ClosedRange<Double>,
        within regionMM: BoxMM? = nil,
        connectivity: Connectivity = .faces
    ) throws -> VolumeMask {
        try grow(
            in: volume,
            seeds: seeds,
            densityRange: densityRange,
            within: regionMM,
            connectivity: connectivity,
            maximumVoxels: nil
        )
    }

    private static func grow(
        in volume: Volume,
        seeds: [(seedMM: Vec3, label: SegmentLabel)],
        densityRange: ClosedRange<Double>,
        within regionMM: BoxMM?,
        connectivity: Connectivity,
        maximumVoxels: Int?
    ) throws -> VolumeMask {
        let rawInterval = try RawDensityInterval(volume: volume, densityRange: densityRange)
        var restriction: GrowthRestriction?
        if let regionMM {
            guard let built = GrowthRestriction(box: regionMM, geometry: volume.geometry) else {
                throw SegmentKitError.cropOutsideVolume
            }
            restriction = built
        }
        guard var mask = VolumeMask(geometry: volume.geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }
        let geometry = volume.geometry
        let planeSize = geometry.columnCount * geometry.rowCount
        let reserveLimit = maximumVoxels ?? geometry.voxelCount
        var stack = [Int32]()
        stack.reserveCapacity(Swift.min(Swift.min(reserveLimit, geometry.voxelCount), 65_536))
        var selectedCount = 0

        // Tutti i semi sono segnati prima della DFS per intercettare conflitti senza dipendere dall'ordine.
        for seed in seeds {
            guard seed.label != VolumeMask.background else {
                throw SegmentKitError.backgroundLabelNotAllowed
            }
            let index = try seedIndex(seed.seedMM, geometry: geometry)
            if let restriction {
                let voxel = voxelCoordinates(index: index, geometry: geometry)
                guard restriction.allows(i: voxel.i, j: voxel.j, k: voxel.k) else {
                    throw SegmentKitError.seedOutsideRestriction
                }
            }
            guard rawInterval.contains(volume.samples[index]) else {
                throw SegmentKitError.seedOutsideDensityRange
            }
            let existing = mask.labels[index]
            if existing != VolumeMask.background {
                guard existing == seed.label else {
                    throw SegmentKitError.seedLabelConflict(index: index, first: existing, second: seed.label)
                }
                continue
            }
            if let maximumVoxels, selectedCount >= maximumVoxels {
                throw SegmentKitError.maximumVoxelCountExceeded(maximum: maximumVoxels)
            }
            guard let index32 = Int32(exactly: index) else {
                throw SegmentKitError.maskAllocationFailed
            }
            let voxel = voxelCoordinates(index: index, geometry: geometry)
            mask.setLabel(seed.label, i: voxel.i, j: voxel.j, k: voxel.k)
            selectedCount += 1
            stack.append(index32)
        }

        let offsets = connectivity == .faces ? regionFaceOffsets : regionFullOffsets
        while let current32 = stack.popLast() {
            let current = Int(current32)
            let voxel = voxelCoordinates(index: current, geometry: geometry)
            let label = mask.labels[current]
            for offset in offsets {
                let i = voxel.i + offset.i
                let j = voxel.j + offset.j
                let k = voxel.k + offset.k
                guard i >= 0, i < geometry.columnCount,
                      j >= 0, j < geometry.rowCount,
                      k >= 0, k < geometry.sliceCount
                else { continue }
                if let restriction, !restriction.allows(i: i, j: j, k: k) { continue }
                let neighbor = k * planeSize + j * geometry.columnCount + i
                guard mask.labels[neighbor] == VolumeMask.background,
                      rawInterval.contains(volume.samples[neighbor])
                else { continue }
                if let maximumVoxels, selectedCount >= maximumVoxels {
                    throw SegmentKitError.maximumVoxelCountExceeded(maximum: maximumVoxels)
                }
                guard let neighbor32 = Int32(exactly: neighbor) else {
                    throw SegmentKitError.maskAllocationFailed
                }
                // La marcatura avviene ora, non all'estrazione: ogni voxel entra una sola volta.
                mask.setLabel(label, i: i, j: j, k: k)
                selectedCount += 1
                stack.append(neighbor32)
            }
        }
        return mask
    }

    private static func seedIndex(_ seed: Vec3, geometry: VolumeGeometry) throws -> Int {
        guard seed.isFinite else { throw SegmentKitError.invalidSeedPatientPoint }
        let voxel = geometry.voxelPoint(fromPatient: seed)
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
        return (k * geometry.rowCount + j) * geometry.columnCount + i
    }
}

let regionFullOffsets: [RegionOffset] = [
    RegionOffset(i: -1, j: -1, k: -1), RegionOffset(i: 0, j: -1, k: -1), RegionOffset(i: 1, j: -1, k: -1),
    RegionOffset(i: -1, j: 0, k: -1), RegionOffset(i: 0, j: 0, k: -1), RegionOffset(i: 1, j: 0, k: -1),
    RegionOffset(i: -1, j: 1, k: -1), RegionOffset(i: 0, j: 1, k: -1), RegionOffset(i: 1, j: 1, k: -1),
    RegionOffset(i: -1, j: -1, k: 0), RegionOffset(i: 0, j: -1, k: 0), RegionOffset(i: 1, j: -1, k: 0),
    RegionOffset(i: -1, j: 0, k: 0), RegionOffset(i: 1, j: 0, k: 0),
    RegionOffset(i: -1, j: 1, k: 0), RegionOffset(i: 0, j: 1, k: 0), RegionOffset(i: 1, j: 1, k: 0),
    RegionOffset(i: -1, j: -1, k: 1), RegionOffset(i: 0, j: -1, k: 1), RegionOffset(i: 1, j: -1, k: 1),
    RegionOffset(i: -1, j: 0, k: 1), RegionOffset(i: 0, j: 0, k: 1), RegionOffset(i: 1, j: 0, k: 1),
    RegionOffset(i: -1, j: 1, k: 1), RegionOffset(i: 0, j: 1, k: 1), RegionOffset(i: 1, j: 1, k: 1)
]
