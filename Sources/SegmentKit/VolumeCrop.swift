import Foundation
import DICOMCore

/// Riquadro allineato agli assi Patient, espresso in millimetri.
public struct BoxMM: Hashable, Sendable, Codable {
    /// Estremo minimo per ciascun asse Patient.
    public var minMM: Vec3
    /// Estremo massimo per ciascun asse Patient.
    public var maxMM: Vec3

    /// Costruisce il riquadro senza modificare gli estremi; un riquadro vuoto resta rilevabile.
    public init(minMM: Vec3, maxMM: Vec3) {
        self.minMM = minMM
        self.maxMM = maxMM
    }

    /// Centro geometrico del riquadro in coordinate Patient.
    public var centerMM: Vec3 { (minMM + maxMM) * 0.5 }

    /// Dimensioni orientate del riquadro lungo gli assi Patient.
    public var sizeMM: Vec3 { maxMM - minMM }

    /// Indica se il punto Patient appartiene al riquadro, estremi compresi.
    public func contains(_ point: Vec3) -> Bool {
        point.x >= minMM.x && point.x <= maxMM.x
            && point.y >= minMM.y && point.y <= maxMM.y
            && point.z >= minMM.z && point.z <= maxMM.z
    }

    /// Allarga il riquadro della stessa quantità lungo ogni asse Patient.
    public func expanded(byMM amount: Double) -> BoxMM {
        let offset = Vec3(amount, amount, amount)
        return BoxMM(minMM: minMM - offset, maxMM: maxMM + offset)
    }

    /// Interseca questo riquadro con l'altro, mantenendo un eventuale risultato vuoto rilevabile.
    public func clamped(to other: BoxMM) -> BoxMM {
        BoxMM(
            minMM: Vec3(
                max(minMM.x, other.minMM.x),
                max(minMM.y, other.minMM.y),
                max(minMM.z, other.minMM.z)
            ),
            maxMM: Vec3(
                min(maxMM.x, other.maxMM.x),
                min(maxMM.y, other.maxMM.y),
                min(maxMM.z, other.maxMM.z)
            )
        )
    }
}

/// Operazioni di ritaglio che conservano campioni e coordinate Patient originali.
public enum VolumeCrop: Sendable {
    /// Ritaglia a un riquadro allineato agli assi espresso in millimetri Patient.
    public static func crop(_ volume: Volume, toBoxMM box: BoxMM) throws -> Volume {
        guard isValid(box) else { throw SegmentKitError.invalidPatientBox }
        let bounds = try voxelBounds(for: box, in: volume.geometry)
        return try crop(volume, toVoxelBounds: bounds)
    }

    /// Ritaglia al riquadro contenitore della maschera non di sfondo, aggiungendo un margine Patient.
    public static func crop(
        _ volume: Volume,
        toMask mask: VolumeMask,
        marginMM: Double
    ) throws -> Volume {
        guard volume.geometry == mask.geometry else { throw SegmentKitError.incompatibleGeometry }
        guard marginMM.isFinite, marginMM >= 0 else {
            throw SegmentKitError.invalidMarginMM(marginMM)
        }
        guard let maskBounds = mask.voxelBounds(label: nil) else { throw SegmentKitError.emptyMask }
        let box = patientBox(for: maskBounds, in: volume.geometry).expanded(byMM: marginMM)
        return try crop(volume, toBoxMM: box)
    }

    private static func crop(
        _ volume: Volume,
        toVoxelBounds bounds: VoxelBounds
    ) throws -> Volume {
        let columns = bounds.maximumI - bounds.minimumI + 1
        let rows = bounds.maximumJ - bounds.minimumJ + 1
        let slices = bounds.maximumK - bounds.minimumK + 1
        let sampleCount = try checkedSampleCount(columns: columns, rows: rows, slices: slices)
        let origin = volume.geometry.patientPoint(
            i: bounds.minimumI,
            j: bounds.minimumJ,
            k: bounds.minimumK
        )
        let geometry: VolumeGeometry
        do {
            geometry = try VolumeGeometry(
                columnCount: columns,
                rowCount: rows,
                sliceCount: slices,
                columnSpacingMM: volume.geometry.columnSpacingMM,
                rowSpacingMM: volume.geometry.rowSpacingMM,
                sliceSpacingMM: volume.geometry.sliceSpacingMM,
                orientation: volume.geometry.orientation,
                originMM: origin
            )
        } catch {
            throw SegmentKitError.invalidCropGeometry
        }

        var samples = [Int16]()
        samples.reserveCapacity(sampleCount)
        for k in bounds.minimumK...bounds.maximumK {
            for j in bounds.minimumJ...bounds.maximumJ {
                let start = volume.linearIndex(i: bounds.minimumI, j: j, k: k)
                let end = start + columns
                samples.append(contentsOf: volume.samples[start..<end])
            }
        }
        do {
            return try Volume(
                geometry: geometry,
                samples: samples,
                rescaleSlope: volume.rescaleSlope,
                rescaleIntercept: volume.rescaleIntercept,
                densityUnit: volume.densityUnit
            )
        } catch {
            throw SegmentKitError.invalidCroppedVolume
        }
    }

    private static func voxelBounds(for box: BoxMM, in geometry: VolumeGeometry) throws -> VoxelBounds {
        var minimum = Vec3(Double.infinity, Double.infinity, Double.infinity)
        var maximum = Vec3(-Double.infinity, -Double.infinity, -Double.infinity)

        for point in patientCorners(of: box) {
            let voxel = geometry.voxelPoint(fromPatient: point)
            guard voxel.isFinite else { throw SegmentKitError.invalidPatientBox }
            minimum = Vec3(min(minimum.x, voxel.x), min(minimum.y, voxel.y), min(minimum.z, voxel.z))
            maximum = Vec3(max(maximum.x, voxel.x), max(maximum.y, voxel.y), max(maximum.z, voxel.z))
        }

        let rawMinimumI = try roundedIndex(minimum.x, rule: .down)
        let rawMinimumJ = try roundedIndex(minimum.y, rule: .down)
        let rawMinimumK = try roundedIndex(minimum.z, rule: .down)
        let rawMaximumI = try roundedIndex(maximum.x, rule: .up)
        let rawMaximumJ = try roundedIndex(maximum.y, rule: .up)
        let rawMaximumK = try roundedIndex(maximum.z, rule: .up)
        guard intersects(rawMinimum: rawMinimumI, rawMaximum: rawMaximumI, count: geometry.columnCount),
              intersects(rawMinimum: rawMinimumJ, rawMaximum: rawMaximumJ, count: geometry.rowCount),
              intersects(rawMinimum: rawMinimumK, rawMaximum: rawMaximumK, count: geometry.sliceCount)
        else {
            throw SegmentKitError.cropOutsideVolume
        }
        return VoxelBounds(
            minimumI: clamped(rawMinimumI, count: geometry.columnCount),
            minimumJ: clamped(rawMinimumJ, count: geometry.rowCount),
            minimumK: clamped(rawMinimumK, count: geometry.sliceCount),
            maximumI: clamped(rawMaximumI, count: geometry.columnCount),
            maximumJ: clamped(rawMaximumJ, count: geometry.rowCount),
            maximumK: clamped(rawMaximumK, count: geometry.sliceCount)
        )
    }

    private static func patientBox(
        for bounds: (min: (Int, Int, Int), max: (Int, Int, Int)),
        in geometry: VolumeGeometry
    ) -> BoxMM {
        let vertices = voxelCorners(minimum: bounds.min, maximum: bounds.max).map {
            geometry.patientPoint(i: $0.0, j: $0.1, k: $0.2)
        }
        var minimum = Vec3(Double.infinity, Double.infinity, Double.infinity)
        var maximum = Vec3(-Double.infinity, -Double.infinity, -Double.infinity)
        for point in vertices {
            minimum = Vec3(min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
            maximum = Vec3(max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
        }
        return BoxMM(minMM: minimum, maxMM: maximum)
    }

    private static func patientCorners(of box: BoxMM) -> [Vec3] {
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

    private static func voxelCorners(
        minimum: (Int, Int, Int),
        maximum: (Int, Int, Int)
    ) -> [(Int, Int, Int)] {
        [
            (minimum.0, minimum.1, minimum.2), (maximum.0, minimum.1, minimum.2),
            (minimum.0, maximum.1, minimum.2), (maximum.0, maximum.1, minimum.2),
            (minimum.0, minimum.1, maximum.2), (maximum.0, minimum.1, maximum.2),
            (minimum.0, maximum.1, maximum.2), (maximum.0, maximum.1, maximum.2),
        ]
    }

    private static func roundedIndex(
        _ value: Double,
        rule: FloatingPointRoundingRule
    ) throws -> Int {
        let rounded = value.rounded(rule)
        guard rounded.isFinite, let index = Int(exactly: rounded) else {
            throw SegmentKitError.invalidPatientBox
        }
        return index
    }

    private static func intersects(rawMinimum: Int, rawMaximum: Int, count: Int) -> Bool {
        rawMinimum < count && rawMaximum >= 0
    }

    private static func clamped(_ index: Int, count: Int) -> Int {
        min(max(index, 0), count - 1)
    }

    private static func isValid(_ box: BoxMM) -> Bool {
        box.minMM.isFinite && box.maxMM.isFinite
            && box.minMM.x <= box.maxMM.x
            && box.minMM.y <= box.maxMM.y
            && box.minMM.z <= box.maxMM.z
    }

    private static func checkedSampleCount(columns: Int, rows: Int, slices: Int) throws -> Int {
        let (planeSize, planeOverflow) = columns.multipliedReportingOverflow(by: rows)
        let (sampleCount, volumeOverflow) = planeSize.multipliedReportingOverflow(by: slices)
        guard !planeOverflow, !volumeOverflow else { throw SegmentKitError.invalidCropGeometry }
        return sampleCount
    }
}

private struct VoxelBounds: Sendable {
    let minimumI: Int
    let minimumJ: Int
    let minimumK: Int
    let maximumI: Int
    let maximumJ: Int
    let maximumK: Int
}
