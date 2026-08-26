import DICOMCore
import Foundation
import MeshKit
import Testing

@testable import ImplantKit

@Suite("Superficie filettata dell'impianto")
struct ThreadedImplantMeshTests {
    private let sides = 32

    private func placement(
        pitch: Double = 1,
        depth: Double = 0.3,
        axis: Vec3 = Vec3(0, 0, 1)
    ) -> ImplantPlacement {
        ImplantPlacement(
            model: ImplantModel(
                manufacturer: "Generico",
                line: "Parametrico",
                diameterMM: 4,
                lengthMM: 8,
                platformDiameterMM: 4,
                apexDiameterMM: 4,
                profile: [
                    ProfilePoint(zMM: 0, radiusMM: 2),
                    ProfilePoint(zMM: 8, radiusMM: 2),
                ],
                threadPitchMM: pitch,
                threadDepthMM: depth
            ),
            platformMM: .zero,
            axis: axis
        )
    }

    private func edgeCounts(_ mesh: Mesh) -> [Set<Int>: Int] {
        var counts: [Set<Int>: Int] = [:]
        for triangle in mesh.triangles {
            for edge in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                counts[[edge.0, edge.1], default: 0] += 1
            }
        }
        return counts
    }

    @Test("I parametri mancanti nei piani precedenti ricevono valori tipici illustrativi")
    func legacyCodingUsesThreadFallbacks() throws {
        let original = placement().model
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "threadPitchMM")
        object.removeValue(forKey: "threadDepthMM")

        let legacyData = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ImplantModel.self, from: legacyData)

        #expect(decoded.threadPitchMM == ImplantModel.defaultThreadPitchMM)
        #expect(decoded.threadDepthMM == ImplantModel.defaultThreadDepthMM)
    }

    @Test("La mesh filettata è chiusa")
    func threadedMeshIsWatertight() {
        let implant = placement(axis: Vec3(1, -2, 4))
        let mesh = ImplantMesh.threadedSurface(of: implant, segments: sides)
        #expect(!mesh.triangles.isEmpty)
        #expect(edgeCounts(mesh).values.allSatisfy { $0 == 2 })
    }

    @Test("Le normali laterali della filettatura guardano fuori")
    func threadedNormalsPointOutward() throws {
        // L'impianto va legato: la prova ne usa l'asse più sotto, e passandolo solo come
        // argomento il nome non esiste in questo ambito.
        let implant = placement()
        let mesh = ImplantMesh.threadedSurface(of: implant, segments: sides)
        for triangle in mesh.triangles {
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            let centre = (a + b + c) / 3
            let along = centre.dot(implant.axis)
            guard along > 1e-8, along < 8 - 1e-8 else { continue }
            let radial = centre - implant.axis * along
            let normal = try #require(mesh.triangleNormal(triangle))
            #expect(normal.dot(radial) > 0)
        }
        #expect(mesh.signedVolumeMM3() > 0)
    }

    @Test("Il passo si misura fra i minimi della geometria")
    func pitchIsMeasurableFromRadiusMinima() {
        let requestedPitch = 1.0
        let mesh = ImplantMesh.threadedSurface(
            of: placement(pitch: requestedPitch), segments: sides)
        let ringCount = (mesh.verticesMM.count - 2) / sides
        let samples = (0..<ringCount).map { ring -> (z: Double, radius: Double) in
            let point = mesh.verticesMM[ring * sides]
            return (point.z, Foundation.hypot(point.x, point.y))
        }
        var minima: [Double] = []
        for index in 1..<(samples.count - 1) {
            if samples[index].radius < samples[index - 1].radius,
               samples[index].radius <= samples[index + 1].radius
            {
                minima.append(samples[index].z)
            }
        }

        #expect(minima.count >= 6)
        for index in 1..<minima.count {
            #expect(abs((minima[index] - minima[index - 1]) - requestedPitch) < 0.09)
        }
    }

    @Test("La profondità si misura sulla circonferenza della geometria")
    func depthIsMeasurableAtOneLevel() throws {
        let requestedDepth = 0.3
        let mesh = ImplantMesh.threadedSurface(
            of: placement(depth: requestedDepth), segments: sides)
        let ringCount = (mesh.verticesMM.count - 2) / sides
        let ring = ringCount / 2
        let radii = (0..<sides).map { side in
            let point = mesh.verticesMM[ring * sides + side]
            return Foundation.hypot(point.x, point.y)
        }
        let minimum = try #require(radii.min())
        let maximum = try #require(radii.max())
        #expect(abs((maximum - minimum) - requestedDepth) < 1e-9)
    }

    @Test("Passo o profondità nulli conservano esattamente il solido liscio")
    func nullThreadParametersUseSmoothSurface() {
        for model in [placement(pitch: 0), placement(depth: 0)] {
            let smooth = ImplantMesh.surface(of: model, segments: sides)
            let threaded = ImplantMesh.threadedSurface(of: model, segments: sides)
            #expect(threaded.verticesMM == smooth.verticesMM)
            #expect(threaded.triangles == smooth.triangles)
            #expect(threaded.name == smooth.name)
        }
    }

    @Test("Il livello per lo schermo ha almeno dieci volte meno triangoli")
    func screenLevelIsAtLeastOneOrderLighter() {
        for segmentCount in [3, sides, 512] {
            let model = placement(pitch: 0.7)
            let detailed = ImplantMesh.threadedSurface(of: model, segments: segmentCount)
            let screen = ImplantMesh.threadedScreenSurface(of: model, segments: segmentCount)
            #expect(screen.triangles.count * 10 <= detailed.triangles.count)
        }
    }
}
