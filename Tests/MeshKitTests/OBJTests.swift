import Foundation
import XCTest
import DICOMCore
@testable import MeshKit

final class OBJTests: XCTestCase {
    func testAllIndexFormsNegativeIndicesAndQuadTriangulation() throws {
        let text = """
        # Tutte le forme di indice condividono gli stessi quattro vertici.
        v 0 0 0
        v 1 0 0
        v 1 1 0
        v 0 1 0
        vt 0 0
        vn 0 0 1
        mtllib ignored.mtl
        usemtl enamel
        o teeth
        g crowns
        s off
        f 1 2 3
        f 1/1 3/1 4/1
        f 1//1 2//1 4//1
        f 2/1/1 3/1/1 4/1/1
        f -4 -3 -2 -1
        """

        let mesh = try MeshIO.load(data: Data(text.utf8), name: "forms.obj")
        XCTAssertEqual(mesh.vertexCount, 4)
        XCTAssertEqual(mesh.triangleCount, 6)
        XCTAssertEqual(mesh.triangles[0], Triangle(a: 0, b: 1, c: 2))
        XCTAssertEqual(mesh.triangles[1], Triangle(a: 0, b: 2, c: 3))
        XCTAssertEqual(mesh.triangles[2], Triangle(a: 0, b: 1, c: 3))
        XCTAssertEqual(mesh.triangles[3], Triangle(a: 1, b: 2, c: 3))
        XCTAssertEqual(mesh.triangles[4], Triangle(a: 0, b: 1, c: 2))
        XCTAssertEqual(mesh.triangles[5], Triangle(a: 0, b: 2, c: 3))
    }

    func testZeroIndexIsRejected() {
        let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 0 2 3\n"
        assertMalformed(text: text, name: "zero.obj")
    }

    func testOutOfRangeIndexIsRejected() {
        let text = "v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 4\n"
        assertMalformed(text: text, name: "range.obj")
    }

    func testNonFiniteVertexIsRejectedWithItsIndex() {
        let text = "v nan 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n"
        XCTAssertThrowsError(try MeshIO.load(data: Data(text.utf8), name: "nan.obj")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .malformed(let name, let detail) = meshError
            else {
                XCTFail("Atteso malformed, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "nan.obj")
            XCTAssertTrue(detail.contains("vertice 0"))
        }
    }

    func testTruncatedVertexLineThrows() {
        assertMalformed(text: "v 0 1\n", name: "short.obj")
    }

    func testUnknownTextFormatThrowsNamedError() {
        let text = String(repeating: "questo non è un formato mesh ", count: 10)
        XCTAssertThrowsError(try MeshIO.load(data: Data(text.utf8), name: "notes.txt")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .unrecognisedFormat(let name) = meshError
            else {
                XCTFail("Atteso unrecognisedFormat, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "notes.txt")
        }
    }

    private func assertMalformed(text: String, name: String) {
        XCTAssertThrowsError(try MeshIO.load(data: Data(text.utf8), name: name)) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .malformed(let errorName, _) = meshError
            else {
                XCTFail("Atteso malformed, ricevuto \(error)")
                return
            }
            XCTAssertEqual(errorName, name)
        }
    }
}
