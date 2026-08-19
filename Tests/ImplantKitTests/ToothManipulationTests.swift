import DICOMCore
import Foundation
import Testing

@testable import ImplantKit

// Spostare e ruotare un dente.
//
// La prova che conta è che ogni rotazione tenga fermo ciò che promette di tenere fermo.
// Trascinando la corona l'apice non si muove; trascinando l'apice la corona non si muove. Se
// scivolassero, ogni aggiustamento ne richiederebbe un secondo per disfare metà del primo — e
// il difetto non darebbe nessun errore, solo un gesto che non converge mai.

@Suite("Manipolazione del dente protesico")
struct ToothManipulationTests {

    private func molar() throws -> ProstheticTooth {
        try #require(ProstheticTooth.standard(forToothNumber: 46, at: Vec3(20, 5, 0)))
    }

    // MARK: Presa

    @Test("Le tre prese stanno dove ci si aspetta lungo il dente")
    func gripsAreWhereTheyBelong() throws {
        let tooth = try molar()
        let axis = tooth.axisMM
        let occlusal = tooth.occlusalCentreMM
        let height = tooth.heightMM

        #expect(
            ToothManipulation.grip(at: occlusal, of: tooth, toleranceMM: 0.5) == .crown)
        #expect(
            ToothManipulation.grip(
                at: occlusal + axis * (height * 0.5), of: tooth, toleranceMM: 0.5) == .body)
        #expect(
            ToothManipulation.grip(
                at: occlusal + axis * height, of: tooth, toleranceMM: 0.5) == .apex)
    }

    @Test("Fuori dall'ingombro non si afferra niente")
    func outsideTheBoxNothingIsGripped() throws {
        let tooth = try molar()
        // Ben oltre metà della dimensione maggiore, che su un molare inferiore è 11,2 mm.
        let far = tooth.positionMM + Vec3(30, 0, 0)
        #expect(ToothManipulation.grip(at: far, of: tooth, toleranceMM: 1) == nil)

        // E nemmeno sopra la corona o sotto l'apice.
        let above = tooth.occlusalCentreMM - tooth.axisMM * 5
        #expect(ToothManipulation.grip(at: above, of: tooth, toleranceMM: 1) == nil)
    }

    // MARK: Traslazione

    @Test("Il corpo trasla, e la traslazione è relativa al passo")
    func bodyTranslates() throws {
        let tooth = try molar()
        let moved = ToothManipulation.dragged(
            tooth, grip: .body, toMM: Vec3(23, 5, 0), fromMM: Vec3(20, 5, 0))

        #expect(moved.positionMM.distance(to: tooth.positionMM + Vec3(3, 0, 0)) < 1e-12)
        // L'asse non cambia traslando.
        #expect((moved.axisMM - tooth.axisMM).length < 1e-12)
    }

    // MARK: Rotazioni

    @Test("Trascinando la corona l'apice resta esattamente dov'è")
    func crownDragKeepsTheApex() throws {
        let tooth = try molar()
        let apexBefore = tooth.positionMM + tooth.axisMM * (tooth.heightMM * 0.5)

        let turned = ToothManipulation.dragged(
            tooth, grip: .crown, toMM: tooth.occlusalCentreMM + Vec3(4, 1, 0),
            fromMM: tooth.occlusalCentreMM)
        let apexAfter = turned.positionMM + turned.axisMM * (turned.heightMM * 0.5)

        #expect(apexAfter.distance(to: apexBefore) < 1e-9)
        // E l'asse è davvero cambiato: un test che provasse solo l'apice fermo passerebbe anche
        // se la rotazione non facesse nulla.
        #expect((turned.axisMM - tooth.axisMM).length > 0.05)
        #expect(abs(turned.axisMM.length - 1) < 1e-12)
    }

    @Test("Trascinando l'apice la corona resta esattamente dov'è")
    func apexDragKeepsTheCrown() throws {
        let tooth = try molar()
        let occlusalBefore = tooth.occlusalCentreMM

        let target = occlusalBefore + tooth.axisMM * tooth.heightMM + Vec3(3, 0, 0)
        let turned = ToothManipulation.dragged(
            tooth, grip: .apex, toMM: target, fromMM: occlusalBefore)

        #expect(turned.occlusalCentreMM.distance(to: occlusalBefore) < 1e-9)
        #expect((turned.axisMM - tooth.axisMM).length > 0.05)
        #expect(abs(turned.axisMM.length - 1) < 1e-12)
    }

    @Test("Un bersaglio degenere lascia il dente com'è invece di annullarlo")
    func degenerateTargetsAreIgnored() throws {
        let tooth = try molar()

        // Bersaglio coincidente col perno della rotazione: la direzione non esiste.
        let apex = tooth.positionMM + tooth.axisMM * (tooth.heightMM * 0.5)
        #expect(ToothManipulation.tilted(tooth, crownTowards: apex) == tooth)
        #expect(ToothManipulation.tilted(tooth, apexTowards: tooth.occlusalCentreMM) == tooth)

        // E un punto non finito non deve propagarsi nella posizione.
        let broken = Vec3(Double.nan, 0, 0)
        #expect(ToothManipulation.dragged(tooth, grip: .body, toMM: broken, fromMM: .zero) == tooth)
        #expect(ToothManipulation.moved(tooth, toMM: broken) == tooth)
    }

    @Test("Ruotare non cambia le misure del dente")
    func rotationPreservesSize() throws {
        let tooth = try molar()
        let turned = ToothManipulation.tilted(tooth, crownTowards: tooth.occlusalCentreMM + Vec3(5, 2, 1))
        #expect(turned.widthMM == tooth.widthMM)
        #expect(turned.heightMM == tooth.heightMM)
        #expect(turned.depthMM == tooth.depthMM)
        #expect(turned.toothNumber == tooth.toothNumber)
        #expect(turned.id == tooth.id)
    }
}
