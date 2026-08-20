import Foundation
import Testing

@testable import VolumeKit

// Quando un oggetto del piano è «nella fetta», e quanto va sfumato.
//
// # Il caso che nessun test copriva
//
// Un impianto Ø4,1 × 10 posato cliccando sull'assiale: la piattaforma sul piano, l'apice dieci
// millimetri sotto. La regola vecchia mediava le due distanze — cinque millimetri — e la
// confrontava con la sfumatura di un diametro: opacità negativa, disegno scartato. L'impianto
// esisteva e non si vedeva da nessuna parte.
//
// Le prove qui sotto sono scritte per **cadere** su quella regola e passare su questa. La prima
// è letteralmente quel caso, con i suoi numeri.

@Suite("Vicinanza al piano di taglio")
struct PlaneProximityTests {

    @Test("Un impianto posato sull'assiale è nella fetta, non a cinque millimetri")
    func implantPlacedOnTheAxialIsInTheSlice() {
        // Piattaforma sul piano, apice dieci millimetri più in là.
        let distance = PlaneProximity.distanceMM(from: 0, to: -10)
        #expect(distance == 0)

        // E quindi disegnato pieno, non scartato. Con la media faceva 1 − 5/4,1 = −0,22.
        let opacity = PlaneProximity.fadeOpacity(distanceMM: distance, fadeOverMM: 4.1)
        #expect(opacity == 1)
    }

    @Test("Il piano che attraversa un corpo lo trova a distanza zero, da entrambi i versi")
    func crossingBodiesAreAtZeroDistance() {
        #expect(PlaneProximity.distanceMM(from: -3, to: 7) == 0)
        #expect(PlaneProximity.distanceMM(from: 7, to: -3) == 0)
        // Tangente: tocca, quindi è dentro.
        #expect(PlaneProximity.distanceMM(from: 0, to: 12) == 0)
        #expect(PlaneProximity.distanceMM(from: -12, to: 0) == 0)
    }

    @Test("Fuori dal corpo vale la distanza dell'estremo più vicino, non la media")
    func outsideBodiesReportTheNearestEnd() {
        // Tutto da una parte: il più vicino sta a due millimetri, la media direbbe sei.
        #expect(PlaneProximity.distanceMM(from: 2, to: 10) == 2)
        #expect(PlaneProximity.distanceMM(from: -10, to: -2) == 2)
    }

    @Test("Una scatola tagliata a metà altezza è dentro, anche senza vertici vicini")
    func aBoxCutThroughItsMiddleIsInside() {
        // Gli otto vertici di un molare alto sette millimetri e mezzo, tagliato a metà: nessun
        // vertice più vicino di 3,75 mm. Con il valore assoluto usciva 3,75 su una sfumatura di
        // quattro, cioè sagoma al sei per cento — invisibile proprio nel taglio che la attraversa.
        let corners = [3.75, 3.75, 3.75, 3.75, -3.75, -3.75, -3.75, -3.75]
        let distance = PlaneProximity.distanceMM(ofConvexBody: corners)
        #expect(distance == 0)
        #expect(PlaneProximity.fadeOpacity(distanceMM: distance, fadeOverMM: 4) == 1)
    }

    @Test("Una scatola tutta oltre il piano sfuma sulla distanza del vertice più vicino")
    func aBoxBeyondThePlaneFadesOnItsNearestCorner() {
        let corners = [2.0, 2.0, 5.0, 5.0, 2.0, 2.0, 5.0, 5.0]
        #expect(PlaneProximity.distanceMM(ofConvexBody: corners) == 2)
    }

    @Test("La frazione di attraversamento cade dove il segmento incontra il piano")
    func theCrossingFractionLandsOnThePlane() {
        // Metà esatta.
        #expect(PlaneProximity.crossingFraction(from: 5, to: -5) == 0.5)
        // Un quarto: cinque contro quindici.
        #expect(abs(PlaneProximity.crossingFraction(from: 5, to: -15) - 0.25) < 1e-12)
        // Piattaforma sul piano: la sezione si guarda alla piattaforma.
        #expect(PlaneProximity.crossingFraction(from: 0, to: -10) == 0)
        // Apice sul piano: si guarda all'apice.
        #expect(PlaneProximity.crossingFraction(from: -10, to: 0) == 1)
    }

    @Test("Senza attraversamento la frazione è l'estremo più vicino, mai fuori intervallo")
    func withoutCrossingTheFractionStaysAtAnEnd() {
        #expect(PlaneProximity.crossingFraction(from: 2, to: 12) == 0)
        #expect(PlaneProximity.crossingFraction(from: 12, to: 2) == 1)
        #expect(PlaneProximity.crossingFraction(from: -2, to: -12) == 0)
    }

    @Test("La sfumatura va da piena a nulla, senza uscire dall'intervallo")
    func theFadeStaysBetweenZeroAndOne() {
        #expect(PlaneProximity.fadeOpacity(distanceMM: 0, fadeOverMM: 4) == 1)
        #expect(PlaneProximity.fadeOpacity(distanceMM: 2, fadeOverMM: 4) == 0.5)
        #expect(PlaneProximity.fadeOpacity(distanceMM: 4, fadeOverMM: 4) == 0)
        // Oltre la sfumatura resta zero e non diventa negativa.
        #expect(PlaneProximity.fadeOpacity(distanceMM: 40, fadeOverMM: 4) == 0)
        // Una sfumatura nulla non divide per zero.
        #expect(PlaneProximity.fadeOpacity(distanceMM: 1, fadeOverMM: 0) == 0)
    }

    @Test("Un impianto perpendicolare al piano non ha sagoma: si disegna la sezione")
    func aPerpendicularImplantHasNoSilhouette() {
        // Asse lungo la normale: proiezione nulla, ben sotto il diametro.
        let perpendicular = PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: 1)
        #expect(perpendicular == 0)
        #expect(perpendicular < 4.1)

        // Disteso nel piano: si vede tutto, e la sagoma è quella giusta.
        #expect(PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: 0) == 10)
        #expect(PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: 0) > 4.1)

        // A quarantacinque gradi: dieci per radice di un mezzo, cioè sette e settanta.
        let tilted = PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: 0.5.squareRoot())
        #expect(abs(tilted - 10 * 0.5.squareRoot()) < 1e-12)
        // E resta una sagoma, non una sezione.
        #expect(tilted > 4.1)
    }

    @Test("Il segno dell'inclinazione non cambia nulla, e valori impossibili non esplodono")
    func tiltIsUsedAsAMagnitude() {
        #expect(PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: -1) == 0)
        #expect(PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: -0.6)
            == PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: 0.6))
        // Un coseno leggermente fuori da ±1 per errore numerico non deve dare NaN.
        #expect(PlaneProximity.inPlaneLengthMM(lengthMM: 10, tilt: 1.0000001) == 0)
    }

    @Test("Un corpo senza vertici non dichiara una posizione")
    func anEmptyBodyHasNoPosition() {
        #expect(PlaneProximity.distanceMM(ofConvexBody: []) == 0)
    }
}
