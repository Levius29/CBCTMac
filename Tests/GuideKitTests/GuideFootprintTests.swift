import DICOMCore
import ImplantKit
import MeshKit
import Testing

@testable import GuideKit

// L'appoggio della dima.
//
// L'affermazione da provare non è che la maschera includa qualcosa — quasi qualunque
// implementazione lo fa — ma che includa **attorno alla piattaforma** e non altrove, che escluda
// il resto dell'arcata, e che dica quanti vertici ha preso: quel numero è ciò che si guarda per
// sapere se un appoggio esiste prima di provare a costruire.

@Suite("Appoggio della dima")
struct GuideFootprintTests {

    /// Una griglia piatta di vertici sul piano occlusale, come una scansione semplificata.
    private func flatScan(halfWidth: Double = 30, step: Double = 2) -> Mesh {
        var vertices: [Vec3] = []
        var x = -halfWidth
        while x <= halfWidth {
            var y = -halfWidth
            while y <= halfWidth {
                vertices.append(Vec3(x, y, 10))
                y += step
            }
            x += step
        }
        return Mesh(verticesMM: vertices, triangles: [], name: "scansione")
    }

    private func implant(at point: Vec3) -> ImplantPlacement {
        ImplantPlacement(
            model: ImplantModel(
                manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: point, axis: Vec3(0, 0, -1), label: "1")
    }

    @Test("L'appoggio comprende i vertici entro il raggio, e nessun altro")
    func footprintCoversTheRadiusAndNothingElse() {
        let scan = flatScan()
        let result = GuideFootprint.aroundImplants(
            scan: scan, implants: [implant(at: Vec3(0, 0, 10))], radiusMM: 8)

        #expect(result.includedCount > 0)
        for (index, vertex) in scan.verticesMM.enumerated() {
            let inside = vertex.distance(to: Vec3(0, 0, 10)) <= 8
            #expect(
                result.mask.isIncluded(index) == inside,
                "vertice a \(vertex.distance(to: Vec3(0, 0, 10))) mm")
        }
    }

    @Test("Si parte da tutto escluso, non da tutto incluso")
    func startsFromNothingIncluded() {
        // `RegionMask` nasce con tutto incluso, perché serve a **togliere** gli artefatti. Qui
        // serve il contrario: l'appoggio è ciò che si aggiunge. Dimenticare di azzerare darebbe
        // una dima che copre l'arcata intera, e nessuno se ne accorgerebbe leggendo il codice.
        let scan = flatScan()
        let result = GuideFootprint.aroundImplants(
            scan: scan, implants: [implant(at: Vec3(0, 0, 10))], radiusMM: 5)
        #expect(result.includedCount < scan.verticesMM.count / 2)
    }

    @Test("Due impianti danno un appoggio che comprende entrambi i siti")
    func twoImplantsGiveTwoSites() {
        let scan = flatScan()
        let single = GuideFootprint.aroundImplants(
            scan: scan, implants: [implant(at: Vec3(-12, 0, 10))], radiusMM: 6)
        let both = GuideFootprint.aroundImplants(
            scan: scan,
            implants: [implant(at: Vec3(-12, 0, 10)), implant(at: Vec3(12, 0, 10))],
            radiusMM: 6)
        #expect(both.includedCount > single.includedCount * 3 / 2)
    }

    @Test("L'appoggio sta attorno alla piattaforma, non attorno all'apice")
    func footprintFollowsThePlatform() {
        // La dima appoggia sulla superficie occlusale; l'apice sta dentro l'osso a dieci
        // millimetri da lì. Prendere l'apice darebbe un appoggio spostato, e su un impianto
        // inclinato anche fuori asse.
        var tilted = implant(at: Vec3(0, 0, 10))
        tilted.axis = Vec3(0.5, 0, -0.87).normalized!

        let scan = flatScan()
        let result = GuideFootprint.aroundImplants(scan: scan, implants: [tilted], radiusMM: 6)

        // Il baricentro dei vertici presi sta sopra la piattaforma, non spostato verso l'apice.
        var centre = Vec3.zero
        var count = 0
        for (index, vertex) in scan.verticesMM.enumerated() where result.mask.isIncluded(index) {
            centre = centre + vertex
            count += 1
        }
        #expect(count > 0)
        centre = centre * (1.0 / Double(count))
        #expect(abs(centre.x) < 0.5, "baricentro spostato a x = \(centre.x)")
    }

    @Test("Senza impianti, o con raggio nullo, non c'è appoggio")
    func nothingToRestOn() {
        let scan = flatScan()
        #expect(GuideFootprint.aroundImplants(scan: scan, implants: [], radiusMM: 8).includedCount == 0)
        #expect(
            GuideFootprint.aroundImplants(
                scan: scan, implants: [implant(at: .zero)], radiusMM: 0).includedCount == 0)
    }
}
