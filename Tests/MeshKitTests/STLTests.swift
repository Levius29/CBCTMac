import Foundation
import XCTest
import DICOMCore
@testable import MeshKit

final class STLTests: XCTestCase {
    func testBinaryRoundTrip() throws {
        let original = makeSquareMeshForIO()
        let data = MeshIO.exportSTLBinary(original)
        let loaded = try MeshIO.load(data: data, name: "square.stl")

        XCTAssertEqual(loaded.triangleCount, 2)
        XCTAssertEqual(loaded.vertexCount, 4)
        XCTAssertEqual(loaded.surfaceAreaMM2(), 1.0, accuracy: 1e-6)
    }

    func testBinaryHeaderBeginningWithSolidStaysBinary() throws {
        var data = MeshIO.exportSTLBinary(makeSquareMeshForIO())
        data.replaceSubrange(0..<5, with: Data("solid".utf8))

        let loaded = try MeshIO.load(data: data, name: "solid-header-trap.stl")
        XCTAssertEqual(loaded.triangleCount, 2)
        XCTAssertEqual(loaded.vertexCount, 4)
    }

    func testASCIIWithIrregularWhitespaceAndNoEndSolid() throws {
        let text = """
          solid   irregular
        facet normal 0 0 1
             outer   loop
          vertex 0 0 0
             vertex  1 0 0
          vertex 0 1 0
         endloop
        endfacet
        """

        let loaded = try MeshIO.load(data: Data(text.utf8), name: "irregular.stl")
        XCTAssertEqual(loaded.vertexCount, 3)
        XCTAssertEqual(loaded.triangleCount, 1)
        XCTAssertEqual(loaded.surfaceAreaMM2(), 0.5, accuracy: 1e-12)
    }

    func testTruncatedBinaryThrowsInsteadOfReadingPastEnd() {
        var data = MeshIO.exportSTLBinary(makeSquareMeshForIO())
        data.removeLast()

        XCTAssertThrowsError(try MeshIO.load(data: data, name: "truncated.stl")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .truncated(let name, _) = meshError
            else {
                XCTFail("Atteso truncated, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "truncated.stl")
        }
    }

    func testHugeDeclaredTriangleCountThrowsBeforeAllocation() {
        var builder = MeshIOByteBuilder()
        builder.appendZeroes(count: 80)
        builder.appendUInt32(UInt32.max)

        XCTAssertThrowsError(try MeshIO.load(data: builder.data, name: "count-bomb.stl")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .tooManyTriangles(let name, let declared) = meshError
            else {
                XCTFail("Atteso tooManyTriangles, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "count-bomb.stl")
            XCTAssertEqual(declared, UInt32.max)
        }
    }

    func testEmptyInputThrowsNamedError() {
        XCTAssertThrowsError(try MeshIO.load(data: Data(), name: "empty.mesh")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .emptyMesh(let name) = meshError
            else {
                XCTFail("Atteso emptyMesh, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "empty.mesh")
        }
    }

    func testMalformedASCIIReportsFileName() {
        let text = "solid broken facet normal 0 0 1 outer loop vertex 0 0 0 endloop endfacet"
        XCTAssertThrowsError(try MeshIO.load(data: Data(text.utf8), name: "broken.stl")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .malformed(let name, _) = meshError
            else {
                XCTFail("Atteso malformed, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "broken.stl")
        }
    }
}

func makeSquareMeshForIO() -> Mesh {
    Mesh(
        verticesMM: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0)],
        triangles: [Triangle(a: 0, b: 1, c: 2), Triangle(a: 0, b: 2, c: 3)],
        name: "square"
    )
}
