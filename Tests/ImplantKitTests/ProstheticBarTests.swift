import DICOMCore
import Foundation
import MeshKit
import Testing

@testable import ImplantKit

// La barra protesica.
//
// Due cose la definiscono, e i test guardano quelle: passa **sopra** le piattaforme — non sotto,
// che metterebbe la struttura dentro l'osso — e percorre gli impianti nell'ordine dell'arcata,
// non in quello in cui sono stati posati. Nessuno posa gli impianti da destra a sinistra: si
// comincia dal sito più delicato, e una barra che seguisse quell'ordine sarebbe un gomitolo.

@Suite("Barra protesica")
struct ProstheticBarTests {

    private func implant(at x: Double, axis: Vec3 = Vec3(0, 0, -1)) -> ImplantPlacement {
        ImplantPlacement(
            model: ImplantModel(manufacturer: "G", line: "C", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(x, 0, 0), axis: axis, label: "\(Int(x))")
    }

    @Test("I nodi stanno sopra le piattaforme, nel verso della bocca")
    func nodesSitAboveThePlatforms() {
        let implants = [implant(at: -10), implant(at: 0), implant(at: 10)]
        let bar = ProstheticBar(implantIDs: implants.map(\.id), offsetMM: 2)
        let nodes = bar.nodesMM(in: implants)

        #expect(nodes.count == 3)
        // Gli impianti scendono lungo −z, quindi l'occlusale è +z: la barra deve stare più in
        // alto delle piattaforme. Il verso sbagliato la metterebbe dentro l'osso.
        for node in nodes {
            #expect(abs(node.z - 2) < 1e-9, "nodo in z = \(node.z)")
        }

        // Con scostamento nullo la barra passa esattamente per le piattaforme.
        let flush = ProstheticBar(implantIDs: implants.map(\.id), offsetMM: 0)
        #expect(flush.nodesMM(in: implants).allSatisfy { abs($0.z) < 1e-9 })
    }

    @Test("Il verso segue l'asse dell'impianto, non l'asse del mondo")
    func offsetFollowsEachAxis() {
        // Un impianto superiore ha l'apice **sopra**: il suo occlusale è verso −z.
        let upper = implant(at: 0, axis: Vec3(0, 0, 1))
        let bar = ProstheticBar(implantIDs: [upper.id], offsetMM: 3)
        let node = bar.nodesMM(in: [upper])[0]
        #expect(abs(node.z + 3) < 1e-9, "un impianto superiore porta la barra verso il basso")
    }

    @Test("La barra sopravvive alla cancellazione di un impianto")
    func missingImplantsAreSkipped() {
        let implants = [implant(at: -10), implant(at: 0), implant(at: 10)]
        let bar = ProstheticBar(implantIDs: implants.map(\.id))

        // Il secondo impianto viene cancellato: la barra passa dai due rimanenti invece di
        // sparire o di puntare al nulla.
        let survivors = [implants[0], implants[2]]
        #expect(bar.nodesMM(in: survivors).count == 2)
        #expect(bar.isUsable(in: survivors))

        // Con un solo appoggio non è più una barra.
        #expect(!bar.isUsable(in: [implants[0]]))
        #expect(bar.lengthMM(in: [implants[0]]) == 0)
    }

    @Test("La lunghezza è quella del percorso, non della corda")
    func lengthFollowsThePath() {
        // Tre impianti su una V: la corda fra il primo e l'ultimo è 20, il percorso è di più.
        let implants = [
            ImplantPlacement(platformMM: Vec3(-10, 0, 0), axis: Vec3(0, 0, -1)),
            ImplantPlacement(platformMM: Vec3(0, 6, 0), axis: Vec3(0, 0, -1)),
            ImplantPlacement(platformMM: Vec3(10, 0, 0), axis: Vec3(0, 0, -1)),
        ]
        let bar = ProstheticBar(implantIDs: implants.map(\.id), offsetMM: 0)
        let expected = 2 * Vec3(10, 6, 0).length
        #expect(abs(bar.lengthMM(in: implants) - expected) < 1e-9)
    }

    // MARK: Ordinamento

    @Test("Gli impianti si ordinano lungo l'arcata, non nell'ordine di posa")
    func implantsFollowTheArch() {
        // Posati in ordine sparso, come succede: prima il sito difficile.
        let scattered = [implant(at: 10), implant(at: -10), implant(at: 3), implant(at: -4)]
        let arch = [Vec3(-15, 0, 0), Vec3(0, 0, 0), Vec3(15, 0, 0)]

        let ordered = ProstheticBarBuilder.ordered(scattered, alongMM: arch)
        let positions = ordered.map(\.platformMM.x)
        #expect(positions == [-10, -4, 3, 10], "ordinati lungo la curva: \(positions)")
    }

    @Test("Senza una curva si tiene l'ordine dato, che è l'unico disponibile")
    func withoutAnArchTheOrderIsKept() {
        let scattered = [implant(at: 10), implant(at: -10)]
        let ordered = ProstheticBarBuilder.ordered(scattered, alongMM: [Vec3(0, 0, 0)])
        #expect(ordered.map(\.platformMM.x) == [10, -10])
    }

    // MARK: Superficie

    @Test("Il tubo è chiuso e le normali guardano fuori")
    func tubeIsClosedAndOutward() {
        let implants = [implant(at: -10), implant(at: 0), implant(at: 10)]
        let bar = ProstheticBar(implantIDs: implants.map(\.id), diameterMM: 4, offsetMM: 2)
        let mesh = ProstheticBarBuilder.surface(of: bar, implants: implants)

        var edges: [Set<Int>: Int] = [:]
        var directed: [Int: Int] = [:]
        var volume = 0.0
        for triangle in mesh.triangles {
            for pair in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                edges[[pair.0, pair.1], default: 0] += 1
                directed[pair.0 &* 1_000_003 &+ pair.1, default: 0] += 1
            }
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            volume += a.dot(b.cross(c)) / 6
        }

        #expect(edges.values.allSatisfy { $0 == 2 })
        #expect(directed.values.allSatisfy { $0 == 1 })
        // Positivo: un tubo con le normali all'interno si stamperebbe cavo.
        #expect(volume > 0, "volume con segno \(volume)")
        // Dell'ordine di un cilindro lungo venti e largo quattro.
        let cylinder = Double.pi * 2 * 2 * 20
        #expect(volume > cylinder * 0.8 && volume < cylinder * 1.2, "volume \(volume)")
    }

    @Test("Una barra senza appoggi non produce una superficie")
    func emptyBarYieldsNothing() {
        let bar = ProstheticBar(implantIDs: [])
        #expect(ProstheticBarBuilder.surface(of: bar, implants: []).triangles.isEmpty)
    }
}
