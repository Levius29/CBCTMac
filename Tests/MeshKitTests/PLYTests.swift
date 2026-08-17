import Foundation
import XCTest
import DICOMCore
@testable import MeshKit

final class PLYTests: XCTestCase {
    func testASCIIQuadIsTriangulated() throws {
        let text = """
        ply
        format ascii 1.0
        comment costruito interamente in memoria
        element vertex 4
        property float x
        property float y
        property float z
        element face 1
        property list uchar int polygon_vertices
        end_header
        0 0 0
        1 0 0
        1 1 0
        0 1 0
        4 0 1 2 3
        """

        let mesh = try MeshIO.load(data: Data(text.utf8), name: "quad-ascii.ply")
        XCTAssertEqual(mesh.verticesMM, [
            Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 1, 0), Vec3(0, 1, 0),
        ])
        XCTAssertEqual(mesh.triangles, [Triangle(a: 0, b: 1, c: 2), Triangle(a: 0, b: 2, c: 3)])
    }

    func testBinaryLittleEndianPLY() throws {
        var builder = MeshIOByteBuilder()
        builder.appendASCII(binaryHeader(
            format: "binary_little_endian",
            vertexCount: 3,
            faceCount: 1,
            coordinateType: "float",
            faceCountType: "uchar",
            faceIndexType: "int"
        ))
        appendFloatVertices(
            [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 1, 0)],
            to: &builder,
            bigEndian: false
        )
        builder.appendUInt8(3)
        builder.appendUInt32(0)
        builder.appendUInt32(1)
        builder.appendUInt32(2)

        let mesh = try MeshIO.load(data: builder.data, name: "little.ply")
        XCTAssertEqual(mesh.verticesMM, [Vec3(0, 0, 0), Vec3(2, 0, 0), Vec3(0, 1, 0)])
        XCTAssertEqual(mesh.triangles, [Triangle(a: 0, b: 1, c: 2)])
    }

    func testBinaryBigEndianPLYWithDoubleCoordinates() throws {
        var builder = MeshIOByteBuilder()
        builder.appendASCII(binaryHeader(
            format: "binary_big_endian",
            vertexCount: 4,
            faceCount: 1,
            coordinateType: "double",
            faceCountType: "uchar",
            faceIndexType: "ushort"
        ))
        let vertices = [Vec3(0, 0, 2), Vec3(1, 0, 2), Vec3(1, 1, 2), Vec3(0, 1, 2)]
        for point: Vec3 in vertices {
            builder.appendFloat64(point.x, bigEndian: true)
            builder.appendFloat64(point.y, bigEndian: true)
            builder.appendFloat64(point.z, bigEndian: true)
        }
        builder.appendUInt8(4)
        builder.appendUInt16(0, bigEndian: true)
        builder.appendUInt16(1, bigEndian: true)
        builder.appendUInt16(2, bigEndian: true)
        builder.appendUInt16(3, bigEndian: true)

        let mesh = try MeshIO.load(data: builder.data, name: "big.ply")
        XCTAssertEqual(mesh.verticesMM, vertices)
        XCTAssertEqual(mesh.triangles, [Triangle(a: 0, b: 1, c: 2), Triangle(a: 0, b: 2, c: 3)])
    }

    func testBinaryPLYSkipsInterleavedColourProperties() throws {
        var builder = MeshIOByteBuilder()
        let headerLines = [
            "ply",
            "format binary_little_endian 1.0",
            "element vertex 3",
            "property float x",
            "property uchar red",
            "property float y",
            "property uchar green",
            "property float z",
            "property uchar blue",
            "element face 1",
            "property list uchar int vertex_indices",
            "end_header",
        ]
        builder.appendASCII(headerLines.joined(separator: "\n") + "\n")
        let vertices = [Vec3(1.25, 2.5, 3.75), Vec3(-4, 5, 6), Vec3(7, -8, 9)]
        var colour: UInt8 = 10
        for point: Vec3 in vertices {
            builder.appendFloat32(Float(point.x))
            builder.appendUInt8(colour)
            builder.appendFloat32(Float(point.y))
            builder.appendUInt8(colour &+ 1)
            builder.appendFloat32(Float(point.z))
            builder.appendUInt8(colour &+ 2)
            colour &+= 3
        }
        builder.appendUInt8(3)
        builder.appendUInt32(0)
        builder.appendUInt32(1)
        builder.appendUInt32(2)

        let mesh = try MeshIO.load(data: builder.data, name: "colours.ply")
        XCTAssertEqual(mesh.verticesMM, vertices)
        XCTAssertEqual(mesh.triangles, [Triangle(a: 0, b: 1, c: 2)])
    }

    func testPLYRejectsNaNCoordinateInsteadOfTrapping() {
        var builder = MeshIOByteBuilder()
        builder.appendASCII(binaryHeader(
            format: "binary_little_endian",
            vertexCount: 3,
            faceCount: 1,
            coordinateType: "float",
            faceCountType: "uchar",
            faceIndexType: "int"
        ))
        builder.appendUInt32(0x7FC0_0000)
        builder.appendFloat32(0)
        builder.appendFloat32(0)
        appendFloatVertices([Vec3(1, 0, 0), Vec3(0, 1, 0)], to: &builder, bigEndian: false)
        builder.appendUInt8(3)
        builder.appendUInt32(0)
        builder.appendUInt32(1)
        builder.appendUInt32(2)

        XCTAssertThrowsError(try MeshIO.load(data: builder.data, name: "nan.ply")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .malformed(let name, let detail) = meshError
            else {
                XCTFail("Atteso malformed, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "nan.ply")
            XCTAssertTrue(detail.contains("vertice 0"))
        }
    }

    func testTruncatedBinaryPLYThrows() {
        var builder = MeshIOByteBuilder()
        builder.appendASCII(binaryHeader(
            format: "binary_little_endian",
            vertexCount: 1,
            faceCount: 1,
            coordinateType: "float",
            faceCountType: "uchar",
            faceIndexType: "int"
        ))
        builder.appendFloat32(0)
        builder.appendFloat32(0)

        XCTAssertThrowsError(try MeshIO.load(data: builder.data, name: "short.ply")) {
            (error: any Error) in
            XCTAssertTrue(error is MeshIOError)
        }
    }

    func testAmbiguousFaceListsAreRejected() {
        let text = """
        ply
        format ascii 1.0
        element vertex 3
        property float x
        property float y
        property float z
        element face 1
        property list uchar int first_indices
        property list uchar int second_indices
        end_header
        0 0 0
        1 0 0
        0 1 0
        3 0 1 2 3 0 1 2
        """

        XCTAssertThrowsError(try MeshIO.load(data: Data(text.utf8), name: "ambiguous.ply")) {
            (error: any Error) in
            guard let meshError = error as? MeshIOError,
                  case .malformed(let name, let detail) = meshError
            else {
                XCTFail("Atteso malformed, ricevuto \(error)")
                return
            }
            XCTAssertEqual(name, "ambiguous.ply")
            XCTAssertTrue(detail.contains("ambigue"))
        }
    }

    private func binaryHeader(
        format: String,
        vertexCount: Int,
        faceCount: Int,
        coordinateType: String,
        faceCountType: String,
        faceIndexType: String
    ) -> String {
        let lines = [
            "ply",
            "format \(format) 1.0",
            "element vertex \(vertexCount)",
            "property \(coordinateType) x",
            "property \(coordinateType) y",
            "property \(coordinateType) z",
            "element face \(faceCount)",
            "property list \(faceCountType) \(faceIndexType) vertex_indices",
            "end_header",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private func appendFloatVertices(
        _ vertices: [Vec3],
        to builder: inout MeshIOByteBuilder,
        bigEndian: Bool
    ) {
        for point: Vec3 in vertices {
            builder.appendFloat32(Float(point.x), bigEndian: bigEndian)
            builder.appendFloat32(Float(point.y), bigEndian: bigEndian)
            builder.appendFloat32(Float(point.z), bigEndian: bigEndian)
        }
    }
}
