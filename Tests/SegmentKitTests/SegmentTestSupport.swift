import DICOMCore
import Testing

@testable import SegmentKit

func makeGeometry(
    columns: Int = 6,
    rows: Int = 5,
    slices: Int = 4,
    rotated: Bool = false
) throws -> VolumeGeometry {
    let orientation = try #require(
        SliceOrientation(
            columnDirection: rotated ? Vec3(0, 1, 0) : Vec3(1, 0, 0),
            rowDirection: rotated ? Vec3(-1, 0, 0) : Vec3(0, 1, 0)
        )
    )
    return try VolumeGeometry(
        columnCount: columns,
        rowCount: rows,
        sliceCount: slices,
        columnSpacingMM: 0.7,
        rowSpacingMM: 1.1,
        sliceSpacingMM: 2.0,
        orientation: orientation,
        originMM: Vec3(10, 20, 30)
    )
}

func makeIndexedVolume(rotated: Bool = false) throws -> Volume {
    let geometry = try makeGeometry(rotated: rotated)
    var samples = [Int16]()
    samples.reserveCapacity(geometry.voxelCount)
    for k in 0..<geometry.sliceCount {
        for j in 0..<geometry.rowCount {
            for i in 0..<geometry.columnCount {
                samples.append(Int16((k * geometry.rowCount + j) * geometry.columnCount + i))
            }
        }
    }
    return try Volume(
        geometry: geometry,
        samples: samples,
        rescaleSlope: 2.5,
        rescaleIntercept: -100,
        densityUnit: .declaredHounsfield
    )
}

func patientAlignedBox(
    containingVoxelCorners corners: [Vec3],
    geometry: VolumeGeometry
) -> BoxMM {
    let points = corners.map(geometry.patientPoint(fromVoxel:))
    let minX = points.map(\.x).min() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let minZ = points.map(\.z).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    let maxZ = points.map(\.z).max() ?? 0
    return BoxMM(minMM: Vec3(minX, minY, minZ), maxMM: Vec3(maxX, maxY, maxZ))
}

func makeAnalyticPatientBoxMask(
    geometry: VolumeGeometry,
    box: BoxMM,
    label: SegmentLabel = 1
) throws -> VolumeMask {
    guard var mask = VolumeMask(geometry: geometry) else {
        throw SegmentKitError.maskAllocationFailed
    }
    for k in 0..<geometry.sliceCount {
        for j in 0..<geometry.rowCount {
            for i in 0..<geometry.columnCount
                where box.contains(geometry.patientPoint(i: i, j: j, k: k)) {
                mask.setLabel(label, i: i, j: j, k: k)
            }
        }
    }
    return mask
}
