import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

@Suite("Piano di riformattazione")
struct ReformatPlanTests {
    @Test("Il piano completo stima esattamente il volume prodotto")
    func estimateMatchesResampledVolume() throws {
        let source = try makeLinearDensityVolume()
        let plan = ReformatPlan.full(for: source.geometry, spacingMM: 1)
        let result = try VolumeResampler.resampled(
            source,
            request: ResampleRequest(spacingMM: plan.spacingMM, regionMM: plan.regionMM)
        )

        #expect(plan.estimatedVoxelCount() == result.geometry.voxelCount)
        #expect(plan.estimatedBytes() == result.geometry.voxelCount * 2)
        #expect(plan.name == "Volume riformattato")
    }

    @Test("Le facce restano nel volume e non possono oltrepassarsi")
    func movingFacesClampsAndKeepsMinimumWidth() throws {
        let geometry = try makeArtifactFreeGeometry()
        let bounds = patientBounds(of: geometry)
        var plan = ReformatPlan.full(for: geometry, spacingMM: 2)

        plan.moveFace(.minX, toMM: bounds.maxMM.x + 100, within: geometry)
        #expect(plan.regionMM.maxMM.x - plan.regionMM.minMM.x >= 2)
        #expect(plan.regionMM.minMM.x >= bounds.minMM.x)
        plan.moveFace(.maxY, toMM: bounds.maxMM.y + 100, within: geometry)
        #expect(plan.regionMM.maxMM.y == bounds.maxMM.y)
        plan.moveFace(.minZ, toMM: bounds.minMM.z - 100, within: geometry)
        #expect(plan.regionMM.minMM.z == bounds.minMM.z)
    }

    @Test("La validazione segnala spacing e riquadri non utilizzabili")
    func validationReportsInvalidPlan() throws {
        let geometry = try makeArtifactFreeGeometry()
        var plan = ReformatPlan(
            regionMM: BoxMM(minMM: Vec3(10, 10, 10), maxMM: Vec3(-10, -10, -10)),
            spacingMM: 0,
            name: "Test",
            notes: ""
        )
        #expect(plan.validate(against: geometry).count >= 2)
        plan.spacingMM = 1
        plan.regionMM = BoxMM(
            minMM: Vec3(1000, 1000, 1000),
            maxMM: Vec3(1001, 1001, 1001)
        )
        #expect(!plan.validate(against: geometry).isEmpty)
    }
}

private func makeArtifactFreeGeometry() throws -> VolumeGeometry {
    let orientation = try #require(SliceOrientation(
        columnDirection: Vec3(1, 0, 0),
        rowDirection: Vec3(0, 1, 0)
    ))
    return try VolumeGeometry(
        columnCount: 10,
        rowCount: 8,
        sliceCount: 6,
        columnSpacingMM: 1,
        rowSpacingMM: 1,
        sliceSpacingMM: 1,
        orientation: orientation,
        originMM: .zero
    )
}
