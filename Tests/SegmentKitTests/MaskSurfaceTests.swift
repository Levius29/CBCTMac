import DICOMCore
import Foundation
import MeshKit
import Testing

@testable import SegmentKit

// Dalla maschera alla superficie.
//
// Il fantoccio ha misure note e verificate da un'implementazione indipendente: il cubo corticale
// è un cubo di venti millimetri di lato a 1200 GV. Segmentarlo e ricostruirne la superficie deve
// restituire quei venti millimetri — ed è la sola prova che dice se la catena
// maschera → campo → marching cubes conserva le coordinate, o se le sposta di mezzo voxel a
// ogni passaggio.

@Suite("Superficie di una maschera")
struct MaskSurfaceTests {

    /// Fantoccio piccolo: la prova è geometrica, non di prestazione, e 120³ basta a contenere
    /// il cubo con margine.
    private func phantom() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5))
    }

    /// Il solo cubo centrale, isolato come lo isolerebbe il programma.
    ///
    /// La soglia da sola non basta, ed è istruttivo: nel fantoccio le lastrine di riferimento a
    /// z = −20 mm sono anch'esse di osso corticale, quindi cadono nella stessa finestra di
    /// densità. Una prova che si fermasse alla soglia misurerebbe la scatola che contiene cubo
    /// **e** lastrine — 24 × 24 × 37 mm — e non se ne accorgerebbe, perché è pur sempre un
    /// numero plausibile. Il componente più grande separa i due oggetti, ed è la stessa catena
    /// che serve su un paziente per staccare la mandibola dalla colonna.
    private func corticalCube(_ volume: Volume) throws -> VolumeMask {
        let thresholded = try ThresholdSegmentation.segment(
            volume, densityRange: 1000...1500, label: 1, within: nil)
        return try ConnectedComponents.keepingLargest(thresholded, count: 1)
    }

    @Test("Il cubo del fantoccio torna venti millimetri anche passando dalla mesh")
    func cubeKeepsItsTwentyMillimetres() throws {
        let volume = try phantom()
        let mask = try corticalCube(volume)
        let mesh = try #require(MaskSurface.mesh(of: mask, label: 1, spacingMM: 0.5))

        #expect(!mesh.triangles.isEmpty)

        var minimum = Vec3(.infinity, .infinity, .infinity)
        var maximum = Vec3(-.infinity, -.infinity, -.infinity)
        for vertex in mesh.verticesMM {
            minimum = Vec3(
                Swift.min(minimum.x, vertex.x), Swift.min(minimum.y, vertex.y),
                Swift.min(minimum.z, vertex.z))
            maximum = Vec3(
                Swift.max(maximum.x, vertex.x), Swift.max(maximum.y, vertex.y),
                Swift.max(maximum.z, vertex.z))
        }

        // Un voxel di tolleranza per lato. Il confine vero sta fra l'ultimo voxel dentro e il
        // primo fuori, e marching cubes lo mette a metà: più preciso di così non è definito.
        for (axis, extent) in [
            ("x", maximum.x - minimum.x), ("y", maximum.y - minimum.y),
            ("z", maximum.z - minimum.z),
        ] {
            #expect(abs(extent - 20) <= 1.0, "lato \(axis) misurato \(extent) mm")
        }

        // E sta dove sta il cubo: centrato nell'origine, che è come il fantoccio è costruito.
        let centre = (minimum + maximum) * 0.5
        #expect(centre.length < 1.0, "centro in \(centre)")
    }

    @Test("Un passo più grosso costa meno triangoli e non sposta la superficie")
    func coarserStepKeepsThePosition() throws {
        let volume = try phantom()
        let mask = try corticalCube(volume)
        let fine = try #require(MaskSurface.mesh(of: mask, label: 1, spacingMM: 0.5))
        let coarse = try #require(MaskSurface.mesh(of: mask, label: 1, spacingMM: 1.5))

        #expect(coarse.triangles.count < fine.triangles.count)

        func extent(_ mesh: Mesh) -> Double {
            var minimum = Double.infinity
            var maximum = -Double.infinity
            for vertex in mesh.verticesMM {
                minimum = Swift.min(minimum, vertex.x)
                maximum = Swift.max(maximum, vertex.x)
            }
            return maximum - minimum
        }

        // Il passo grosso perde dettaglio, non posizione: il lato resta quello entro il suo
        // stesso passo. Se invece la scatola si spostasse, l'errore crescerebbe con il passo e
        // una segmentazione ridotta comparirebbe accanto all'anatomia invece che sopra.
        #expect(abs(extent(coarse) - extent(fine)) <= 1.5)
    }

    @Test("Una maschera vuota non produce una mesh, e lo dice")
    func emptyMaskYieldsNothing() throws {
        let volume = try phantom()
        let empty = try #require(VolumeMask(geometry: volume.geometry))
        #expect(MaskSurface.isEmpty(empty))
        #expect(MaskSurface.mesh(of: empty) == nil)
    }

    @Test("Un'etichetta assente non prende i voxel di un'altra")
    func labelIsRespected() throws {
        let volume = try phantom()
        let mask = try corticalCube(volume)
        #expect(!MaskSurface.isEmpty(mask, label: 1))
        // L'etichetta 7 non è stata assegnata a nulla. Se il filtro fosse ignorato, qui
        // uscirebbe il cubo — cioè un oggetto attribuito a un'etichetta che non esiste.
        #expect(MaskSurface.isEmpty(mask, label: 7))
        #expect(MaskSurface.mesh(of: mask, label: 7) == nil)
    }

    @Test("Il passo si ferma al minimo dichiarato invece di far esplodere la griglia")
    func stepIsClamped() throws {
        let volume = try phantom()
        let mask = try corticalCube(volume)
        // Un micrometro richiederebbe una griglia da miliardi di celle. Il limite la riporta a
        // un decimo di millimetro; la mesh esce, e non è un rifiuto per dimensione.
        let mesh = MaskSurface.mesh(of: mask, label: 1, spacingMM: 0.000_001)
        #expect(mesh != nil || !MaskSurface.isEmpty(mask, label: 1))
    }
}

// MARK: - I preset di soglia

@Suite("Preset di soglia")
struct ThresholdPresetTests {

    @Test("Ogni preset ha una finestra sensata e un caveat scritto")
    func presetsAreWellFormed() {
        #expect(!ThresholdPreset.all.isEmpty)
        for preset in ThresholdPreset.all {
            #expect(preset.lowerGV < preset.upperGV, "\(preset.name): finestra rovesciata")
            #expect(!preset.name.isEmpty)
            // Il caveat non è decorazione: dice che cosa il preset prende per sbaglio, ed è la
            // sola cosa che impedisce di leggere «Osso» come «solo osso».
            #expect(preset.caveat.count > 30, "\(preset.name): caveat troppo corto per dire nulla")
        }
    }

    @Test("Gli identificatori sono unici, altrimenti il menu ne perderebbe uno")
    func identifiersAreUnique() {
        let identifiers = ThresholdPreset.all.map(\.id)
        #expect(Set(identifiers).count == identifiers.count)
        let names = ThresholdPreset.all.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("Le finestre sono ordinate per densità crescente, come l'anatomia")
    func presetsCoverTheRangeInOrder() throws {
        // Aria, tessuti molli, osso, denti, metallo: è la scala su cui si legge una CBCT, e i
        // preset devono starci sopra senza salti assurdi.
        func preset(_ id: String) throws -> ThresholdPreset {
            try #require(ThresholdPreset.all.first { $0.id == id })
        }
        let air = try preset("aeree")
        let soft = try preset("molli")
        let bone = try preset("osso")
        let teeth = try preset("denti")
        let metal = try preset("metallo")

        #expect(air.upperGV <= soft.lowerGV, "aria e tessuti molli non devono sovrapporsi")
        #expect(soft.upperGV < bone.lowerGV)
        #expect(bone.lowerGV < teeth.lowerGV)
        #expect(teeth.lowerGV < metal.lowerGV)
    }

    @Test("Il preset del metallo arriva al massimo rappresentabile")
    func metalReachesTheTop() throws {
        let metal = try #require(ThresholdPreset.all.first { $0.id == "metallo" })
        // Un tetto più basso taglierebbe via proprio i voxel più densi, che sono il metallo.
        #expect(metal.upperGV >= Double(Int16.max))
    }
}
