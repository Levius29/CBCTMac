import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

func makeLinearDensityVolume(rotated: Bool = false) throws -> Volume {
    let orientation = try #require(SliceOrientation(
        columnDirection: rotated ? Vec3(0.8, 0.6, 0) : Vec3(1, 0, 0),
        rowDirection: rotated ? Vec3(-0.6, 0.8, 0) : Vec3(0, 1, 0)
    ))
    let geometry = try VolumeGeometry(
        columnCount: 21,
        rowCount: 19,
        sliceCount: 17,
        columnSpacingMM: 0.4,
        rowSpacingMM: 0.5,
        sliceSpacingMM: 0.6,
        orientation: orientation,
        originMM: Vec3(12, -7, 4)
    )
    let slope = 0.5
    let intercept = -1000.0
    var samples = [Int16]()
    samples.reserveCapacity(geometry.voxelCount)
    for k in 0..<geometry.sliceCount {
        for j in 0..<geometry.rowCount {
            for i in 0..<geometry.columnCount {
                let point = geometry.patientPoint(i: i, j: j, k: k)
                let density = 20 * point.x - 12 * point.y + 8 * point.z + 300
                let raw = ((density - intercept) / slope).rounded()
                samples.append(Int16(clamping: Int(raw)))
            }
        }
    }
    return try Volume(
        geometry: geometry,
        samples: samples,
        rescaleSlope: slope,
        rescaleIntercept: intercept,
        densityUnit: .greyValue
    )
}

func patientBounds(of geometry: VolumeGeometry) -> BoxMM {
    let corners = geometry.boundingBoxCornersMM
    var minimum = Vec3(Double.infinity, Double.infinity, Double.infinity)
    var maximum = Vec3(-Double.infinity, -Double.infinity, -Double.infinity)
    for point in corners {
        minimum = Vec3(
            min(minimum.x, point.x),
            min(minimum.y, point.y),
            min(minimum.z, point.z)
        )
        maximum = Vec3(
            max(maximum.x, point.x),
            max(maximum.y, point.y),
            max(maximum.z, point.z)
        )
    }
    return BoxMM(minMM: minimum, maxMM: maximum)
}

func foregroundExtentX(
    _ volume: Volume,
    densityRange: ClosedRange<Double>,
    atPatientY patientY: Double = 0,
    patientZ: Double = 0
) -> Double? {
    var minimum = Double.infinity
    var maximum = -Double.infinity
    var found = false
    let geometry = volume.geometry
    let centreVoxel = geometry.voxelPoint(fromPatient: Vec3(0, patientY, patientZ))
    guard centreVoxel.isFinite,
          let j = Int(exactly: centreVoxel.y.rounded()),
          let k = Int(exactly: centreVoxel.z.rounded()),
          j >= 0, j < geometry.rowCount,
          k >= 0, k < geometry.sliceCount
    else { return nil }
    for i in 0..<geometry.columnCount {
        guard let density = volume.densityValue(i: i, j: j, k: k),
              densityRange.contains(density)
        else { continue }
        let x = geometry.patientPoint(i: i, j: j, k: k).x
        minimum = min(minimum, x)
        maximum = max(maximum, x)
        found = true
    }
    guard found else { return nil }
    return maximum - minimum + geometry.columnSpacingMM
}
