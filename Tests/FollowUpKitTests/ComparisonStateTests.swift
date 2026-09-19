import DICOMCore
import Foundation
import Testing

@testable import FollowUpKit

// Lo stato del confronto è piccolo, e ognuna di queste prove esiste perché il valore sbagliato
// non darebbe un errore: darebbe una tendina fuori dal riquadro, un lampeggio che sfarfalla, o
// due mirini su due punti diversi.

@Suite("Stato del confronto")
struct ComparisonStateTests {

    @Test("La tendina resta fra zero e uno, qualunque cosa le si dia")
    func wipeFractionIsClamped() {
        var state = ComparisonState()
        state.setWipeFraction(1.7)
        #expect(state.wipeFraction == 1)
        state.setWipeFraction(-3)
        #expect(state.wipeFraction == 0)
        state.setWipeFraction(Double.nan)
        #expect(state.wipeFraction == 0.5)
        state.setWipeFraction(0.25)
        #expect(state.wipeFraction == 0.25)
    }

    @Test("Il periodo del lampeggio sta fra i suoi limiti")
    func blinkPeriodIsClamped() {
        var state = ComparisonState()
        state.setBlinkPeriodSeconds(0.01)
        #expect(state.blinkPeriodSeconds == ComparisonState.minimumBlinkPeriodSeconds)
        state.setBlinkPeriodSeconds(90)
        #expect(state.blinkPeriodSeconds == ComparisonState.maximumBlinkPeriodSeconds)
        #expect(ComparisonState(blinkPeriodSeconds: 0).blinkPeriodSeconds
            == ComparisonState.minimumBlinkPeriodSeconds)
    }

    @Test("Fuori dal lampeggio il riferimento è sempre a schermo")
    func onlyBlinkAlternates() {
        let sideBySide = ComparisonState(mode: .sideBySide)
        let wipe = ComparisonState(mode: .wipe)
        for time in [0.0, 0.3, 0.5, 0.9, 12.7] {
            #expect(!sideBySide.showsFollowUp(atSeconds: time))
            #expect(!wipe.showsFollowUp(atSeconds: time))
        }
    }

    @Test("Il lampeggio alterna a metà periodo, e si ripete")
    func blinkAlternatesAtHalfPeriod() {
        let state = ComparisonState(mode: .blink, blinkPeriodSeconds: 0.8)
        #expect(!state.showsFollowUp(atSeconds: 0))
        #expect(!state.showsFollowUp(atSeconds: 0.39))
        #expect(state.showsFollowUp(atSeconds: 0.4))
        #expect(state.showsFollowUp(atSeconds: 0.79))
        #expect(!state.showsFollowUp(atSeconds: 0.8))
        #expect(state.showsFollowUp(atSeconds: 8.5))
        // Un tempo negativo capita al primo fotogramma dopo un riavvio dell'orologio della
        // vista: il ciclo prosegue all'indietro senza saltare, quindi −0,1 è come 0,7.
        #expect(state.showsFollowUp(atSeconds: -0.1))
        #expect(!state.showsFollowUp(atSeconds: Double.infinity))
    }

    @Test("Il bordo della tendina cade dove dice la frazione")
    func wipeSplitFollowsTheFraction() {
        var state = ComparisonState(mode: .wipe)
        state.setWipeFraction(0.25)
        #expect(state.wipeSplit(inWidth: 800) == 200)
        #expect(state.wipeSplit(inWidth: 0) == 0)
        #expect(state.wipeSplit(inWidth: Double.nan) == 0)
    }

    @Test("Il mirino è uno solo, e si porta nell'altro esame con la posa")
    func cursorTravelsWithThePose() {
        var state = ComparisonState()
        state.moveCursor(toMM: Vec3(10, 20, 30))
        #expect(state.cursorMM == Vec3(10, 20, 30))

        let pose = RigidPose(translationMM: Vec3(1.5, 0, -0.5))
        #expect(
            state.cursorMM(in: pose)
                .isApproximatelyEqual(to: Vec3(11.5, 20, 29.5), tolerance: 1e-9))

        // Un punto non finito arriva da una vista che non ha ancora una geometria: si ignora,
        // invece di portare un NaN dentro ogni conversione a valle.
        state.moveCursor(toMM: Vec3(Double.nan, 0, 0))
        #expect(state.cursorMM == Vec3(10, 20, 30))
    }

    @Test("Ogni modo ha il suo nome, e il lampeggio porta la sua avvertenza")
    func modesAreNamedAndTheRiskyOneIsFlagged() {
        #expect(ComparisonMode.allCases.count == 3)
        for mode in ComparisonMode.allCases {
            #expect(!mode.localizedName.isEmpty)
        }
        #expect(ComparisonMode.blink.caution != nil)
        #expect(ComparisonMode.sideBySide.caution == nil)
        #expect(ComparisonMode.wipe.caution == nil)
    }

    @Test("Le metriche dicono che cosa presuppongono")
    func metricsExplainThemselves() {
        #expect(RegistrationMetricKind.allCases.count == 2)
        for metric in RegistrationMetricKind.allCases {
            #expect(!metric.localizedName.isEmpty)
            #expect(!metric.explanation.isEmpty)
        }
    }
}
