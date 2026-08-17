import DICOMCore
import SegmentKit
import Testing

func makeArtifactGeometry(
    columns: Int,
    rows: Int,
    slices: Int,
    columnSpacingMM: Double = 1,
    rowSpacingMM: Double = 1,
    sliceSpacingMM: Double = 1
) throws -> VolumeGeometry {
    let orientation = try #require(
        SliceOrientation(columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0))
    )
    return try VolumeGeometry(
        columnCount: columns,
        rowCount: rows,
        sliceCount: slices,
        columnSpacingMM: columnSpacingMM,
        rowSpacingMM: rowSpacingMM,
        sliceSpacingMM: sliceSpacingMM,
        orientation: orientation,
        originMM: Vec3(0, 0, 0)
    )
}

func makeArtifactVolume(
    columns: Int,
    rows: Int,
    slices: Int,
    samples: [Int16],
    columnSpacingMM: Double = 1,
    rowSpacingMM: Double = 1,
    sliceSpacingMM: Double = 1,
    slope: Double = 1,
    intercept: Double = 0,
    densityUnit: DensityUnit = .greyValue
) throws -> Volume {
    let geometry = try makeArtifactGeometry(
        columns: columns,
        rows: rows,
        slices: slices,
        columnSpacingMM: columnSpacingMM,
        rowSpacingMM: rowSpacingMM,
        sliceSpacingMM: sliceSpacingMM
    )
    return try Volume(
        geometry: geometry,
        samples: samples,
        rescaleSlope: slope,
        rescaleIntercept: intercept,
        densityUnit: densityUnit
    )
}
