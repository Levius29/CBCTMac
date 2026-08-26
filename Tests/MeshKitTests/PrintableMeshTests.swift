import DICOMCore
import Foundation
import Testing
@testable import MeshKit

@Suite("Mesh stampabili")
struct PrintableMeshTests {
    @Test("OBJ va e torna senza perdere vertici o triangoli")
    func objVaETorna() throws {
        let original = makeCube(name: "cubo\nsecondo oggetto")
        let data = Data(MeshIO.exportOBJ(original).utf8)

        let loaded = try MeshIO.load(data: data, name: "cubo.obj")

        #expect(loaded.verticesMM == original.verticesMM)
        #expect(loaded.triangles == original.triangles)
        #expect(MeshIO.exportOBJ(original).split(separator: "\n").first == "o cubo secondo oggetto")
    }

    @Test("Gli indici OBJ partono da uno")
    func indiciOBJPartonoDaUno() {
        let text = MeshIO.exportOBJ(makeTetrahedron())

        #expect(!text.contains("f 0 "))
        #expect(text.contains("f 1 "))
    }

    @Test("PLY binario va e torna senza perdere vertici o triangoli")
    func plyVaETorna() throws {
        let original = makeCube(name: "cubo")

        let loaded = try MeshIO.load(
            data: MeshIO.exportPLYBinary(original),
            name: "cubo.ply"
        )

        #expect(loaded.verticesMM == original.verticesMM)
        #expect(loaded.triangles == original.triangles)
    }

    @Test("L'esportatore unico concorda con quelli diretti")
    func esportatoreUnicoConcorda() {
        let mesh = makeTetrahedron()

        #expect(MeshIO.export(mesh, as: .stlBinary) == MeshIO.exportSTLBinary(mesh))
        #expect(MeshIO.export(mesh, as: .stlASCII) == Data(MeshIO.exportSTLASCII(mesh).utf8))
        #expect(MeshIO.export(mesh, as: .ply) == MeshIO.exportPLYBinary(mesh))
        #expect(MeshIO.export(mesh, as: .obj) == Data(MeshIO.exportOBJ(mesh).utf8))
    }

    @Test("Il referto distingue un cubo chiuso da uno con un buco")
    func refertoVedeUnBuco() {
        let closed = makeCube(name: "chiuso")
        var open = closed
        open.triangles.removeLast()

        let closedReport = MeshRepair.integrity(of: closed)
        let openReport = MeshRepair.integrity(of: open)

        #expect(closedReport.openEdgeCount == 0)
        #expect(closedReport.nonManifoldEdgeCount == 0)
        #expect(closedReport.isWatertight)
        #expect(openReport.openEdgeCount == 3)
        #expect(!openReport.isWatertight)
    }

    @Test("Due gusci separati si contano e si può tenere il maggiore")
    func dueGusciSiContano() {
        let first = makeCube(name: "primo")
        let second = makeCube(name: "secondo", offset: Vec3(10, 0, 0))
        let combined = MeshMerge.combined([first, second], name: "due cubi")

        #expect(MeshRepair.integrity(of: combined).shellCount == 2)

        let largest = MeshRepair.largestShell(of: combined)
        #expect(largest.triangleCount == first.triangleCount)
        #expect(largest.vertexCount == first.vertexCount)
        #expect(MeshRepair.integrity(of: largest).shellCount == 1)
    }

    @Test("L'orientamento incoerente torna coerente e rivolto all'esterno")
    func orientamentoSiRaddrizza() {
        let sphere = makeSphere(radius: 8, latitudeSegments: 20, longitudeSegments: 32)
        var scrambled = sphere
        for index in scrambled.triangles.indices where index.isMultiple(of: 2) {
            let triangle = scrambled.triangles[index]
            scrambled.triangles[index] = Triangle(a: triangle.a, b: triangle.c, c: triangle.b)
        }

        let repaired = MeshRepair.orientedOutward(scrambled)
        let expected = sphere.signedVolumeMM3()

        #expect(repaired.signedVolumeMM3() > 0)
        #expect(abs(repaired.signedVolumeMM3() - expected) / expected < 0.01)
    }

    @Test("Taubin conserva il volume mentre la sola Laplaciana ritira")
    func taubinNonRitira() {
        let sphere = makeSphere(radius: 10, latitudeSegments: 16, longitudeSegments: 32)
        let initialVolume = sphere.signedVolumeMM3()

        let taubin = MeshSmoothing.taubin(sphere, iterations: 20)
        let laplacian = MeshSmoothing.taubin(sphere, mu: 0, iterations: 20)
        let taubinLoss = abs(taubin.signedVolumeMM3() - initialVolume) / initialVolume
        let laplacianLoss = (initialVolume - laplacian.signedVolumeMM3()) / initialVolume

        #expect(taubinLoss < 0.03, "variazione Taubin: \(taubinLoss)")
        #expect(laplacianLoss > 0.10, "ritiro Laplaciano: \(laplacianLoss)")
    }

    @Test("Taubin riduce le scalette senza muovere il bordo aperto")
    func taubinToglieIGradini() {
        let stepped = makeSteppedSurface()
        let boundaryIndices = boundaryVertexIndices(gridSize: 11)
        let initialBoundary = boundaryIndices.map { stepped.verticesMM[$0] }
        let initialDeviation = normalDeviation(of: stepped)

        let smoothed = MeshSmoothing.taubin(stepped, iterations: 12)

        #expect(normalDeviation(of: smoothed) < initialDeviation)
        #expect(boundaryIndices.map { smoothed.verticesMM[$0] } == initialBoundary)
    }

    @Test("La decimazione rispetta il bilancio senza aprire o rovesciare la sfera")
    func decimazioneRispettaBilancio() {
        let sphere = makeSphere(radius: 10, latitudeSegments: 51, longitudeSegments: 50)
        #expect(sphere.triangleCount == 5_000)
        let initialVolume = sphere.signedVolumeMM3()

        let simplified = MeshDecimation.simplified(sphere, targetTriangleCount: 1_000)
        let report = MeshRepair.integrity(of: simplified)
        let volumeLoss = abs(simplified.signedVolumeMM3() - initialVolume) / initialVolume

        #expect(simplified.triangleCount <= 1_000)
        #expect(volumeLoss < 0.05, "variazione di volume: \(volumeLoss)")
        #expect(report.openEdgeCount == 0)
        #expect(report.nonManifoldEdgeCount == 0)
        #expect(simplified.signedVolumeMM3() > 0)
    }

    @Test("La decimazione non tocca una mesh già abbastanza piccola")
    func decimazioneNonToccaMeshPiccola() {
        let mesh = makeCube(name: "piccolo")

        #expect(MeshDecimation.simplified(mesh, targetTriangleCount: 12).verticesMM == mesh.verticesMM)
        #expect(MeshDecimation.simplified(mesh, targetTriangleCount: 12).triangles == mesh.triangles)
        #expect(MeshDecimation.simplified(mesh, targetTriangleCount: 0).triangles == mesh.triangles)
    }
}

private func makeCube(name: String, offset: Vec3 = .zero) -> Mesh {
    let vertices = [
        Vec3(-1, -1, -1), Vec3(1, -1, -1), Vec3(1, 1, -1), Vec3(-1, 1, -1),
        Vec3(-1, -1, 1), Vec3(1, -1, 1), Vec3(1, 1, 1), Vec3(-1, 1, 1),
    ].map { $0 + offset }
    let triangles = [
        Triangle(a: 0, b: 2, c: 1), Triangle(a: 0, b: 3, c: 2),
        Triangle(a: 4, b: 5, c: 6), Triangle(a: 4, b: 6, c: 7),
        Triangle(a: 0, b: 1, c: 5), Triangle(a: 0, b: 5, c: 4),
        Triangle(a: 3, b: 7, c: 6), Triangle(a: 3, b: 6, c: 2),
        Triangle(a: 0, b: 4, c: 7), Triangle(a: 0, b: 7, c: 3),
        Triangle(a: 1, b: 2, c: 6), Triangle(a: 1, b: 6, c: 5),
    ]
    return Mesh(verticesMM: vertices, triangles: triangles, name: name)
}

private func makeTetrahedron() -> Mesh {
    Mesh(
        verticesMM: [Vec3.zero, Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)],
        triangles: [
            Triangle(a: 0, b: 2, c: 1), Triangle(a: 0, b: 1, c: 3),
            Triangle(a: 0, b: 3, c: 2), Triangle(a: 1, b: 2, c: 3),
        ],
        name: "tetraedro"
    )
}

private func makeSphere(radius: Double, latitudeSegments: Int, longitudeSegments: Int) -> Mesh {
    var vertices = [Vec3(0, 0, radius)]
    for latitude in 1..<latitudeSegments {
        let theta = Double.pi * Double(latitude) / Double(latitudeSegments)
        let ringRadius = radius * Foundation.sin(theta)
        let z = radius * Foundation.cos(theta)
        for longitude in 0..<longitudeSegments {
            let phi = 2 * Double.pi * Double(longitude) / Double(longitudeSegments)
            vertices.append(Vec3(ringRadius * Foundation.cos(phi), ringRadius * Foundation.sin(phi), z))
        }
    }
    let bottom = vertices.count
    vertices.append(Vec3(0, 0, -radius))

    var triangles = [Triangle]()
    triangles.reserveCapacity(2 * longitudeSegments * (latitudeSegments - 1))
    for longitude in 0..<longitudeSegments {
        let next = (longitude + 1) % longitudeSegments
        triangles.append(Triangle(a: 0, b: 1 + longitude, c: 1 + next))
    }
    if latitudeSegments > 2 {
        for ring in 0..<(latitudeSegments - 2) {
            let upper = 1 + ring * longitudeSegments
            let lower = upper + longitudeSegments
            for longitude in 0..<longitudeSegments {
                let next = (longitude + 1) % longitudeSegments
                triangles.append(Triangle(a: upper + longitude, b: lower + longitude, c: lower + next))
                triangles.append(Triangle(a: upper + longitude, b: lower + next, c: upper + next))
            }
        }
    }
    let lastRing = bottom - longitudeSegments
    for longitude in 0..<longitudeSegments {
        let next = (longitude + 1) % longitudeSegments
        triangles.append(Triangle(a: bottom, b: lastRing + next, c: lastRing + longitude))
    }
    return Mesh(verticesMM: vertices, triangles: triangles, name: "sfera")
}

private func makeSteppedSurface() -> Mesh {
    let size = 11
    var vertices = [Vec3]()
    for y in 0..<size {
        for x in 0..<size {
            let z = Double((x + y) / 2) * 0.35
            vertices.append(Vec3(Double(x), Double(y), z))
        }
    }
    var triangles = [Triangle]()
    for y in 0..<(size - 1) {
        for x in 0..<(size - 1) {
            let a = y * size + x
            let b = a + 1
            let d = a + size
            let c = d + 1
            triangles.append(Triangle(a: a, b: b, c: c))
            triangles.append(Triangle(a: a, b: c, c: d))
        }
    }
    return Mesh(verticesMM: vertices, triangles: triangles, name: "gradini")
}

private func boundaryVertexIndices(gridSize: Int) -> [Int] {
    var result = [Int]()
    for y in 0..<gridSize {
        for x in 0..<gridSize where x == 0 || y == 0 || x == gridSize - 1 || y == gridSize - 1 {
            result.append(y * gridSize + x)
        }
    }
    return result
}

private func normalDeviation(of mesh: Mesh) -> Double {
    let normals = mesh.triangles.compactMap { mesh.triangleNormal($0) }
    guard !normals.isEmpty else { return 0 }
    var sum = Vec3.zero
    for normal in normals { sum += normal }
    guard let mean = sum.normalized else { return .infinity }
    var squared = 0.0
    for normal in normals {
        let clamped = max(-1.0, min(1.0, normal.dot(mean)))
        let angle = Foundation.acos(clamped)
        squared += angle * angle
    }
    return (squared / Double(normals.count)).squareRoot()
}
