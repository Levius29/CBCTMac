import XCTest
import DICOMCore
@testable import MeshKit

final class RegionMaskTests: XCTestCase {
    func testSphereExclusionAndInclusion() {
        let vertices = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(3, 0, 0)]
        var mask = RegionMask(vertexCount: vertices.count)

        mask.exclude(sphereCentreMM: .zero, radiusMM: 1.1, vertices: vertices)
        XCTAssertEqual(mask.includedCount, 1)
        XCTAssertEqual(mask.includedPoints(from: vertices), [Vec3(3, 0, 0)])

        mask.include(sphereCentreMM: .zero, radiusMM: 0.1, vertices: vertices)
        XCTAssertTrue(mask.isIncluded(0))
        XCTAssertFalse(mask.isIncluded(1))
        XCTAssertTrue(mask.isIncluded(2))
    }

    func testExcludeAllAndIncludeAll() {
        var mask = RegionMask(vertexCount: 4)
        XCTAssertEqual(mask.includedCount, 4)
        mask.excludeAll()
        XCTAssertEqual(mask.includedCount, 0)
        mask.includeAll()
        XCTAssertEqual(mask.includedCount, 4)
    }

    func testNegativeVertexCountCreatesEmptyMask() {
        let mask = RegionMask(vertexCount: -20)
        XCTAssertEqual(mask.includedCount, 0)
        XCTAssertFalse(mask.isIncluded(0))
    }

    func testInvalidIndicesAndShortVertexArraysAreSafe() {
        var mask = RegionMask(vertexCount: 5)
        let vertices = [Vec3.zero, Vec3(10, 0, 0)]
        mask.exclude(sphereCentreMM: .zero, radiusMM: 1, vertices: vertices)

        XCTAssertFalse(mask.isIncluded(-1))
        XCTAssertFalse(mask.isIncluded(5))
        XCTAssertFalse(mask.isIncluded(0))
        XCTAssertTrue(mask.isIncluded(1))
        XCTAssertEqual(mask.includedCount, 4)
        XCTAssertEqual(mask.includedPoints(from: vertices), [Vec3(10, 0, 0)])
    }

    func testInvalidSphereLeavesMaskUnchanged() {
        let vertices = [Vec3.zero, Vec3(1, 0, 0)]
        var mask = RegionMask(vertexCount: vertices.count)
        mask.exclude(sphereCentreMM: .zero, radiusMM: -1, vertices: vertices)
        mask.exclude(sphereCentreMM: .zero, radiusMM: .infinity, vertices: vertices)
        mask.exclude(
            sphereCentreMM: Vec3(Double.nan, 0, 0),
            radiusMM: 10,
            vertices: vertices
        )

        XCTAssertEqual(mask.includedCount, 2)
    }

    func testNonFiniteVertexIsNotModifiedByBrush() {
        let vertices = [Vec3(Double.nan, 0, 0), Vec3.zero]
        var mask = RegionMask(vertexCount: vertices.count)
        mask.exclude(sphereCentreMM: .zero, radiusMM: 1, vertices: vertices)

        XCTAssertTrue(mask.isIncluded(0))
        XCTAssertFalse(mask.isIncluded(1))
    }
}
