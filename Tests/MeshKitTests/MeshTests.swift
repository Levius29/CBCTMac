import XCTest
import DICOMCore
@testable import MeshKit

final class MeshTests: XCTestCase {
    func testTriangleGeometryAndAreaWeightedNormals() {
        let mesh = Mesh(
            verticesMM: [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 3, 0)],
            triangles: [Triangle(a: 0, b: 1, c: 2)],
            name: "triangle"
        )

        XCTAssertEqual(mesh.vertexCount, 3)
        XCTAssertEqual(mesh.triangleCount, 1)
        XCTAssertEqual(mesh.surfaceAreaMM2(), 3.0, accuracy: 1e-12)
        XCTAssertEqual(mesh.triangleNormal(mesh.triangles[0]), Vec3(0, 0, 1))
        XCTAssertEqual(
            mesh.vertexNormals(),
            [Vec3(0, 0, 1), Vec3(0, 0, 1), Vec3(0, 0, 1)]
        )
    }

    func testBoundsCentroidAndEmptyMesh() {
        let mesh = Mesh(
            verticesMM: [Vec3(-2, 5, 7), Vec3(4, -1, 3), Vec3(1, 2, -6)],
            triangles: [],
            name: "points"
        )

        let bounds = mesh.boundsMM
        XCTAssertEqual(bounds?.min, Vec3(-2, -1, -6))
        XCTAssertEqual(bounds?.max, Vec3(4, 5, 7))
        XCTAssertEqual(mesh.centroidMM, Vec3(1, 2, 4.0 / 3.0))

        let empty = Mesh(verticesMM: [], triangles: [], name: "empty")
        XCTAssertNil(empty.boundsMM)
        XCTAssertEqual(empty.centroidMM, .zero)
        XCTAssertEqual(empty.surfaceAreaMM2(), 0)
        XCTAssertEqual(empty.signedVolumeMM3(), 0)
    }

    func testSignedVolumeForClosedOrientedMesh() {
        let mesh = makeUnitTetrahedron()
        XCTAssertEqual(mesh.signedVolumeMM3(), 1.0 / 6.0, accuracy: 1e-12)
    }

    func testTransformAppliesToVerticesAndPreservesNameAndIndices() {
        let mesh = Mesh(
            verticesMM: [Vec3(1, 2, 3)],
            triangles: [Triangle(a: 0, b: 0, c: 0)],
            name: "original"
        )
        let transformed = mesh.transformed(by: .translation(Vec3(10, -5, 2)))

        XCTAssertEqual(transformed.verticesMM, [Vec3(11, -3, 5)])
        XCTAssertEqual(transformed.triangles, mesh.triangles)
        XCTAssertEqual(transformed.name, "original")
    }

    func testInvalidAndDegenerateTrianglesAreSafe() {
        let mesh = Mesh(
            verticesMM: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(2, 0, 0)],
            triangles: [
                Triangle(a: 0, b: 1, c: 2),
                Triangle(a: 0, b: 0, c: 1),
                Triangle(a: -1, b: 1, c: 2),
                Triangle(a: 0, b: 1, c: 9),
            ],
            name: "bad-triangles"
        )

        for triangle: Triangle in mesh.triangles {
            XCTAssertNil(mesh.triangleNormal(triangle))
        }
        XCTAssertEqual(mesh.vertexNormals(), [.zero, .zero, .zero])
        XCTAssertEqual(mesh.surfaceAreaMM2(), 0)
        XCTAssertEqual(mesh.removingDegenerateTriangles().triangleCount, 0)
    }

    func testRemovingDegenerateTrianglesKeepsValidTriangles() {
        let valid = Triangle(a: 0, b: 1, c: 2)
        let mesh = Mesh(
            verticesMM: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
            triangles: [valid, Triangle(a: 0, b: 1, c: 1)],
            name: "mixed"
        )

        let cleaned = mesh.removingDegenerateTriangles()
        XCTAssertEqual(cleaned.triangles, [valid])
        XCTAssertEqual(cleaned.verticesMM, mesh.verticesMM)
    }

    func testWeldingCollapsesCoincidentVerticesAndPreservesArea() {
        let mesh = Mesh(
            verticesMM: [
                Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0),
                Vec3(0, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
            ],
            triangles: [Triangle(a: 0, b: 1, c: 2), Triangle(a: 3, b: 4, c: 5)],
            name: "unwelded-square"
        )

        let welded = mesh.welded()
        XCTAssertEqual(welded.vertexCount, 4)
        XCTAssertEqual(welded.triangleCount, 2)
        XCTAssertEqual(welded.surfaceAreaMM2(), mesh.surfaceAreaMM2(), accuracy: 1e-12)
    }

    func testWeldingSearchesAdjacentCells() {
        let mesh = Mesh(
            verticesMM: [Vec3(0.000099, 0, 0), Vec3(0.000101, 0, 0)],
            triangles: [],
            name: "cell-boundary"
        )

        XCTAssertEqual(mesh.welded(toleranceMM: 1e-4).vertexCount, 1)
    }

    func testWeldingSkipsNonFiniteVertexWithoutTrapping() {
        let mesh = Mesh(
            verticesMM: [Vec3(Double.nan, 0, 0), Vec3(0, 0, 0), Vec3(1, 0, 0)],
            triangles: [],
            name: "application-mesh"
        )

        let welded = mesh.welded()
        XCTAssertEqual(welded.vertexCount, 3)
        XCTAssertTrue(welded.verticesMM[0].x.isNaN)
    }

    func testNonPositiveOrNonFiniteToleranceLeavesMeshUnchanged() {
        let mesh = Mesh(
            verticesMM: [Vec3.zero, Vec3.zero],
            triangles: [],
            name: "tolerance"
        )

        XCTAssertEqual(mesh.welded(toleranceMM: 0).vertexCount, 2)
        XCTAssertEqual(mesh.welded(toleranceMM: -1).vertexCount, 2)
        XCTAssertEqual(mesh.welded(toleranceMM: .infinity).vertexCount, 2)
    }

    private func makeUnitTetrahedron() -> Mesh {
        Mesh(
            verticesMM: [Vec3.zero, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)],
            triangles: [
                Triangle(a: 0, b: 2, c: 1),
                Triangle(a: 0, b: 1, c: 3),
                Triangle(a: 0, b: 3, c: 2),
                Triangle(a: 1, b: 2, c: 3),
            ],
            name: "tetrahedron"
        )
    }
}
