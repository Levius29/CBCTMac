import DICOMCore
import Foundation
import MeshKit
import Testing

@testable import ImplantKit

// Il canale alveolare come tubo, per il riquadro 3D.
//
// Nel 3D il nervo non si disegnava affatto: impianti, barre, denti e arcata sì, il canale no.
// Chi lo tracciava e passava al 3D non vedeva niente — e il 3D è la vista che risponde meglio
// alla sola domanda per cui il canale si traccia: l'impianto passa sopra o dentro?
//
// Le prove qui verificano che il tubo sia un tubo: chiuso attorno all'asse, del raggio giusto,
// che segue il restringimento dei nodi, e con i triangoli rivolti in fuori.

@Suite("Superficie del canale alveolare")
struct NerveMeshTests {

    /// Canale rettilineo lungo l'asse x, raggio costante.
    private func makeStraightCanal(radiusMM: Double = 1.4) -> NerveCanal {
        NerveCanal(
            side: .left,
            nodes: [
                NerveNode(positionMM: Vec3(-20, 5, -8), radiusMM: radiusMM),
                NerveNode(positionMM: Vec3(0, 5, -8), radiusMM: radiusMM),
                NerveNode(positionMM: Vec3(20, 5, -8), radiusMM: radiusMM),
            ])
    }

    @Test("Un canale con meno di due nodi non è un percorso e non dà superficie")
    func tooFewNodesGiveNoSurface() {
        let empty = NerveCanal(side: .right, nodes: [])
        #expect(NerveMesh.surface(of: empty).triangles.isEmpty)

        let single = NerveCanal(
            side: .right, nodes: [NerveNode(positionMM: .zero, radiusMM: 1.4)])
        #expect(NerveMesh.surface(of: single).triangles.isEmpty)
    }

    @Test("Il tubo ha il raggio dei nodi, non uno inventato")
    func theTubeHasTheRadiusOfItsNodes() {
        for radius in [0.8, 1.4, 2.2] {
            let mesh = NerveMesh.surface(of: makeStraightCanal(radiusMM: radius), segments: 24)
            #expect(!mesh.verticesMM.isEmpty)

            // Su un canale rettilineo lungo x, la distanza di ogni vertice dall'asse è il raggio.
            var smallest = Double.infinity
            var largest = 0.0
            for vertex in mesh.verticesMM {
                let radial = Vec3(0, vertex.y - 5, vertex.z + 8).length
                smallest = min(smallest, radial)
                largest = max(largest, radial)
            }
            // Un poligono a ventiquattro lati sta fra il raggio e il raggio inscritto: lo scarto
            // è meno di due centesimi, non un fattore.
            #expect(abs(largest - radius) < 1e-9)
            #expect(smallest > radius * 0.99)
        }
    }

    @Test("Il tubo segue il restringimento del canale")
    func theTubeFollowsTheNarrowing() {
        // Un canale che si assottiglia verso il foro mentoniero: disegnarlo di spessore costante
        // direbbe che c'è meno osso di quanto ce n'è, proprio dove l'impianto ci arriva vicino.
        let tapering = NerveCanal(
            side: .left,
            nodes: [
                NerveNode(positionMM: Vec3(-20, 0, 0), radiusMM: 2.0),
                NerveNode(positionMM: Vec3(20, 0, 0), radiusMM: 0.8),
            ])
        let mesh = NerveMesh.surface(of: tapering, segments: 16)

        func radialSpread(near x: Double) -> Double {
            var largest = 0.0
            for vertex in mesh.verticesMM where abs(vertex.x - x) < 1 {
                largest = max(largest, Vec3(0, vertex.y, vertex.z).length)
            }
            return largest
        }
        let atStart = radialSpread(near: -19)
        let atEnd = radialSpread(near: 19)
        #expect(atStart > 1.8)
        #expect(atEnd < 1.0)
        #expect(atStart > atEnd * 1.8)
    }

    @Test("Il tubo è chiuso attorno all'asse: ogni spigolo è condiviso da due triangoli")
    func theTubeIsClosedAroundItsAxis() {
        let mesh = NerveMesh.surface(of: makeStraightCanal(), segments: 12)

        // Un tubo aperto ai due capi: gli spigoli del bordo stanno su un triangolo solo, tutti
        // gli altri su due. Se la fascia non si richiudesse in giro, ci sarebbero due spigoli
        // longitudinali di bordo in più per ogni anello.
        var counts: [String: Int] = [:]
        for triangle in mesh.triangles {
            for (a, b) in [(triangle.a, triangle.b), (triangle.b, triangle.c),
                (triangle.c, triangle.a)]
            {
                let key = a < b ? "\(a)-\(b)" : "\(b)-\(a)"
                counts[key, default: 0] += 1
            }
        }
        let boundary = counts.values.filter { $0 == 1 }.count
        // Solo i due anelli terminali: dodici spigoli ciascuno.
        #expect(boundary == 24)
        #expect(counts.values.allSatisfy { $0 <= 2 })
    }

    @Test("Le normali guardano in fuori")
    func normalsPointOutward() {
        let mesh = NerveMesh.surface(of: makeStraightCanal(), segments: 16)
        // Su un tubo rettilineo l'asse è noto: la normale di ogni triangolo deve avere
        // componente radiale positiva. Con l'ordine dei vertici invertito guarderebbe dentro, e
        // l'illuminazione del riquadro 3D renderebbe il canale una sagoma nera.
        var outward = 0
        var inward = 0
        for triangle in mesh.triangles {
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            guard let normal = (b - a).cross(c - a).normalized else { continue }
            let centroid = Vec3(
                (a.x + b.x + c.x) / 3, (a.y + b.y + c.y) / 3, (a.z + b.z + c.z) / 3)
            let radial = Vec3(0, centroid.y - 5, centroid.z + 8)
            if normal.dot(radial) > 0 { outward += 1 } else { inward += 1 }
        }
        #expect(outward > 0)
        #expect(inward == 0)
    }
}
