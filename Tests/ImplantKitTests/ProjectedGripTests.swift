import DICOMCore
import Foundation
import Testing

@testable import ImplantKit

// Afferrare un impianto guardandolo, non calcolandolo.
//
// # Il difetto che queste prove chiudono
//
// La presa stava nello spazio: chiedeva che il clic distasse dall'asse meno del raggio più la
// tolleranza. In un riquadro 2D il clic sta **per costruzione sul piano di taglio**, quindi un
// impianto tre millimetri davanti al piano aveva distanza tre millimetri — più della presa — pur
// essendo disegnato benissimo, perché la sovraimpressione lo sfuma su un diametro intero. Si
// vedeva e non si prendeva.
//
// Nel 3D lo stesso per un'altra strada: la sonda stava alla profondità della **mezzeria**, e su
// un impianto inclinato gli estremi ne distano qualche millimetro. Si afferrava in mezzo e non
// alle estremità, che sono le maniglie con cui lo si inclina.
//
// La domanda giusta è una sola: il puntatore cade dentro la sagoma che si vede? Qui si verifica
// quella, in unità di vista, senza sapere se a proiettare sia stato un piano o una camera.

@Suite("Presa sulla proiezione")
struct ProjectedGripTests {

    private typealias Point = ImplantManipulation.PlanarPoint

    /// Impianto verticale sullo schermo: piattaforma in alto, apice cento punti più giù.
    private let platform = Point(x: 100, y: 50)
    private let apex = Point(x: 100, y: 150)
    private let radius = 8.0
    private let tolerance = 3.0

    private func grip(_ x: Double, _ y: Double) -> ImplantGrip? {
        ImplantManipulation.projectedGrip(
            at: Point(x: x, y: y), platform: platform, apex: apex,
            radius: radius, tolerance: tolerance)
    }

    @Test("Si afferra il corpo dovunque dentro la sagoma, non solo sull'asse")
    func theBodyIsGrabbableAcrossItsWidth() {
        // Sull'asse, a metà lunghezza.
        #expect(grip(100, 100) == .body)
        // Al bordo del pezzo: è lì che si mira, perché è lì che il pezzo si vede.
        #expect(grip(108, 100) == .body)
        #expect(grip(92, 100) == .body)
        // E un po' oltre, quanto la tolleranza.
        #expect(grip(110, 100) == .body)
        // Oltre raggio più tolleranza, no.
        #expect(grip(115, 100) == nil)
    }

    @Test("Le estremità danno le maniglie che inclinano, il mezzo quella che trasla")
    func theEndsGiveTheTiltingHandles() {
        #expect(grip(100, 55) == .head)
        #expect(grip(100, 145) == .apex)
        #expect(grip(100, 100) == .body)

        // Il confine sta a un quarto della lunghezza da ciascun capo.
        #expect(grip(100, 74) == .head)
        #expect(grip(100, 76) == .body)
        #expect(grip(100, 124) == .body)
        #expect(grip(100, 126) == .apex)
    }

    @Test("Fuori dai due capi si può sbagliare quanto la tolleranza, non di più")
    func theOvershootIsBoundedByTheTolerance() {
        #expect(grip(100, 48) == .head, "due punti sopra la piattaforma")
        #expect(grip(100, 152) == .apex, "due punti sotto l'apice")
        #expect(grip(100, 45) == nil, "cinque punti sopra: troppo")
        #expect(grip(100, 155) == nil)
    }

    @Test("Un impianto visto di punta si afferra dal cerchio")
    func anImplantSeenEndOnIsGrabbableFromItsCircle() {
        // Piattaforma e apice sullo stesso pixel: la sagoma degenera in un cerchio, e non c'è
        // un lungo da percorrere. Deve restare afferrabile — è la vista assiale di un impianto
        // verticale, cioè il caso più comune che ci sia.
        let point = Point(x: 60, y: 60)
        let same = ImplantManipulation.projectedGrip(
            at: Point(x: 64, y: 62), platform: point, apex: point,
            radius: radius, tolerance: tolerance)
        #expect(same == .body)

        let far = ImplantManipulation.projectedGrip(
            at: Point(x: 80, y: 60), platform: point, apex: point,
            radius: radius, tolerance: tolerance)
        #expect(far == nil)
    }

    @Test("Su un impianto obliquo la presa segue la sagoma, non il rettangolo che la contiene")
    func anObliqueImplantIsGrabbedAlongItsShape() {
        let start = Point(x: 40, y: 40)
        let end = Point(x: 140, y: 140)
        func oblique(_ x: Double, _ y: Double) -> ImplantGrip? {
            ImplantManipulation.projectedGrip(
                at: Point(x: x, y: y), platform: start, apex: end,
                radius: radius, tolerance: tolerance)
        }
        // Sulla diagonale, a metà.
        #expect(oblique(90, 90) == .body)
        // L'angolo del rettangolo che contiene la sagoma è lontano dall'asse: fuori.
        #expect(oblique(140, 40) == nil)
        #expect(oblique(40, 140) == nil)
    }

    @Test("Il raggio conta: un impianto largo si afferra da più lontano di uno stretto")
    func widerImplantsHaveWiderGrip() {
        let narrow = ImplantManipulation.projectedGrip(
            at: Point(x: 108, y: 100), platform: platform, apex: apex,
            radius: 2, tolerance: 1)
        #expect(narrow == nil)

        let wide = ImplantManipulation.projectedGrip(
            at: Point(x: 108, y: 100), platform: platform, apex: apex,
            radius: 10, tolerance: 1)
        #expect(wide == .body)
    }

    @Test("Il punto lontano dalla sagoma non afferra niente")
    func farPointsGrabNothing() {
        #expect(grip(300, 300) == nil)
        #expect(grip(100, -50) == nil)
    }
}
