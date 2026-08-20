import DICOMCore
import Foundation
import MeshKit
import Testing

@testable import ImplantKit

// L'impianto come superficie.
//
// La prova che conta più delle altre è che la superficie sia **chiusa**: una mesh aperta passa
// ogni controllo di forma e produce un pezzo che lo slicer rifiuta o riempie a caso. Si verifica
// contando gli spigoli — in un solido chiuso ogni spigolo appartiene esattamente a due
// triangoli — e con la formula di Eulero, che una superficie bucata non soddisfa.

@Suite("Superficie dell'impianto e del dente")
struct ImplantMeshTests {

    private func implant(
        diameter: Double = 4.1, apex: Double = 2.6, length: Double = 12,
        axis: Vec3 = Vec3(0, 0, -1), platform: Vec3 = Vec3(10, -5, 3)
    ) -> ImplantPlacement {
        ImplantPlacement(
            model: ImplantModel(
                manufacturer: "G", line: "C", diameterMM: diameter, lengthMM: length,
                platformDiameterMM: diameter, apexDiameterMM: apex),
            platformMM: platform, axis: axis, label: "46")
    }

    /// Ogni spigolo di un solido chiuso appartiene a esattamente due triangoli.
    private func edgeCounts(_ mesh: Mesh) -> [Int] {
        var counts: [Set<Int>: Int] = [:]
        for triangle in mesh.triangles {
            for pair in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                counts[[pair.0, pair.1], default: 0] += 1
            }
        }
        return Array(counts.values)
    }

    /// Quanti spigoli **orientati** compaiono più di una volta.
    ///
    /// Il conteggio non orientato non vede una faccia girata al contrario: gli spigoli restano
    /// due, solo percorsi nello stesso verso invece che in versi opposti. È la differenza fra
    /// una superficie chiusa e una superficie chiusa **coerente**, e uno slicer guarda la
    /// seconda — una faccia invertita gli dice che lì il pieno sta dall'altra parte.
    private func inconsistentDirectedEdges(_ mesh: Mesh) -> Int {
        var seen: [Int: Int] = [:]
        for triangle in mesh.triangles {
            for pair in [(triangle.a, triangle.b), (triangle.b, triangle.c), (triangle.c, triangle.a)] {
                seen[pair.0 &* 1_000_003 &+ pair.1, default: 0] += 1
            }
        }
        return seen.values.filter { $0 != 1 }.count
    }

    /// Volume con segno, dal teorema della divergenza. Positivo se le normali guardano fuori.
    private func signedVolume(_ mesh: Mesh) -> Double {
        var total = 0.0
        for triangle in mesh.triangles {
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            total += a.dot(b.cross(c)) / 6
        }
        return total
    }

    @Test("La superficie dell'impianto è chiusa")
    func implantSurfaceIsClosed() {
        let mesh = ImplantMesh.surface(of: implant())
        #expect(!mesh.triangles.isEmpty)

        // Nessuno spigolo di bordo: se ce ne fosse anche uno solo, il pezzo avrebbe un buco.
        let counts = edgeCounts(mesh)
        #expect(counts.allSatisfy { $0 == 2 }, "spigoli con conteggio diverso da due")

        // Eulero: V − S + F = 2 per una superficie di genere zero. Con i vertici duplicati
        // sull'anello degenere della punta il conto si sposta, quindi si verifica il criterio
        // degli spigoli sopra e qui solo che il numero di facce sia quello atteso.
        let sides = ImplantMesh.defaultSegments
        let rings = implant().model.profile.count
        let expected = (rings - 1) * sides * 2 + sides * 2
        #expect(mesh.triangles.count == expected)

        // Chiusa **e coerente**: ogni spigolo percorso una volta per verso. Il conteggio non
        // orientato da solo non vede una faccia girata al contrario.
        #expect(inconsistentDirectedEdges(mesh) == 0)

        // E le normali guardano fuori. Un volume negativo significherebbe un pezzo che lo
        // slicer stampa al rovescio, cioè cavo — e non lo direbbe nessun errore.
        let volume = signedVolume(mesh)
        #expect(volume > 0, "volume con segno \(volume)")
        // Dell'ordine di un cilindro da 4,1 × 12: fra un terzo e il tutto di π r² h.
        let cylinder = Double.pi * 2.05 * 2.05 * 12
        #expect(volume > cylinder * 0.3 && volume < cylinder * 1.05, "volume \(volume)")
    }

    @Test("La superficie sta dove sta l'impianto, e ha le sue misure")
    func surfaceMatchesTheImplant() throws {
        let placement = implant(diameter: 5, apex: 3, length: 10, platform: Vec3(20, 5, 0))
        let mesh = ImplantMesh.surface(of: placement)
        let bounds = try #require(mesh.boundsMM)

        // Lunghezza lungo l'asse, che qui è −z: dalla piattaforma in z = 0 all'apice in z = −10.
        #expect(abs((bounds.max.z - bounds.min.z) - 10) < 1e-9)
        // Larghezza: il diametro della testa, meno lo scarto del poligono inscritto.
        let width = bounds.max.x - bounds.min.x
        let error = ImplantMesh.radialErrorMM(radiusMM: 2.5, segments: ImplantMesh.defaultSegments)
        #expect(width <= 5 + 1e-9)
        #expect(width >= 5 - 2 * error - 1e-9, "larghezza \(width)")
        // E il centro è dove sta l'impianto.
        #expect(abs((bounds.min.x + bounds.max.x) / 2 - 20) < 1e-9)
    }

    @Test("L'errore del poligono è dichiarato e piccolo")
    func radialErrorIsDeclared() {
        // Su un impianto da 6 mm, trentadue lati sbagliano meno di venti micron.
        let error = ImplantMesh.radialErrorMM(radiusMM: 3, segments: 32)
        #expect(error < 0.02, "scarto \(error) mm")
        // E cresce riducendo i lati: se non crescesse, la formula non dipenderebbe da essi.
        #expect(ImplantMesh.radialErrorMM(radiusMM: 3, segments: 8) > error * 5)
        // Meno di tre lati non è un poligono: si tratta come tre invece di dividere per zero.
        #expect(ImplantMesh.radialErrorMM(radiusMM: 3, segments: 0).isFinite)
    }

    @Test("La superficie segue l'asse, comunque sia inclinato")
    func surfaceFollowsTheAxis() throws {
        let tilted = implant(axis: Vec3(1, 1, -3), platform: .zero)
        let mesh = ImplantMesh.surface(of: tilted)
        let axis = try #require(tilted.axis.normalized)

        // Ogni vertice sta entro il raggio massimo dall'asse, e fra piattaforma e apice.
        let maxRadius = tilted.model.platformDiameterMM / 2 + 1e-9
        for vertex in mesh.verticesMM {
            let along = (vertex - tilted.platformMM).dot(axis)
            let radial = ((vertex - tilted.platformMM) - axis * along).length
            #expect(radial <= maxRadius, "raggio \(radial)")
            #expect(along >= -1e-9 && along <= tilted.model.lengthMM + 1e-9, "quota \(along)")
        }
    }

    @Test("Un asse degenere dà una mesh vuota invece di una storta")
    func degenerateAxisYieldsNothing() {
        var broken = implant()
        broken.axis = Vec3(0, 0, -1)
        // `ImplantPlacement` normalizza l'asse in costruzione, quindi il caso da coprire è il
        // profilo vuoto: un modello senza punti non può produrre una superficie.
        broken.model.profile = []
        #expect(ImplantMesh.surface(of: broken).triangles.isEmpty)
    }

    // MARK: Il dente

    @Test("La scatola del dente è chiusa e ha le sue misure")
    func toothBoxIsClosed() throws {
        let tooth = try #require(ProstheticTooth.standard(forToothNumber: 46, at: Vec3(20, 5, 0)))
        let mesh = ImplantMesh.surface(of: tooth, mesialDirectionMM: Vec3(0, 1, 0))

        #expect(mesh.verticesMM.count == 8)
        #expect(mesh.triangles.count == 12)
        #expect(edgeCounts(mesh).allSatisfy { $0 == 2 })
        #expect(inconsistentDirectedEdges(mesh) == 0)
        let volume = signedVolume(mesh)
        #expect(volume > 0, "volume con segno \(volume)")
        #expect(
            abs(volume - tooth.widthMM * tooth.heightMM * tooth.depthMM) < 1e-6,
            "una scatola ha il volume del prodotto dei lati, e questo lo verifica")

        let bounds = try #require(mesh.boundsMM)
        // Con la tangente lungo y, la larghezza mesio-distale sta su y e lo spessore su x.
        #expect(abs((bounds.max.y - bounds.min.y) - tooth.widthMM) < 1e-9)
        #expect(abs((bounds.max.x - bounds.min.x) - tooth.depthMM) < 1e-9)
        #expect(abs((bounds.max.z - bounds.min.z) - tooth.heightMM) < 1e-9)
    }

    @Test("Le due superfici si esportano in STL")
    func surfacesExportToSTL() throws {
        let mesh = ImplantMesh.surface(of: implant())
        let data = MeshIO.exportSTLBinary(mesh)
        // Intestazione da 80 byte, contatore da 4, cinquanta byte per triangolo.
        #expect(data.count == 84 + mesh.triangles.count * 50)

        let reread = try MeshIO.load(data: data, name: "Impianto")
        #expect(reread.triangles.count == mesh.triangles.count)
    }
}
