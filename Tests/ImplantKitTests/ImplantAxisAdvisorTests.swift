import DICOMCore
import Foundation
import Testing

@testable import ImplantKit

// La proposta dell'asse.
//
// Le prove che contano non sono che l'ottimizzatore trovi un massimo — quello lo fa qualunque
// ricerca — ma che trovi quello **clinicamente sensato**: che si allontani dal canale quando
// serve, che non lo faccia quando non serve, e che dichiari di non farcela invece di proporre la
// meno peggio.

@Suite("Proposta dell'asse implantare")
struct ImplantAxisAdvisorTests {

    private func model(diameter: Double = 4, length: Double = 10) -> ImplantModel {
        ImplantModel(
            manufacturer: "Prova", line: "Retta",
            diameterMM: diameter, lengthMM: length, platformDiameterMM: diameter)
    }

    /// Un canale rettilineo parallelo all'asse x, alla quota e alla profondità indicate.
    private func canal(atY y: Double, z: Double, radius: Double = 1.4) -> NerveCanal {
        NerveCanal(
            side: .right,
            nodes: (-3...3).map {
                NerveNode(positionMM: Vec3(Double($0) * 5, y, z), radiusMM: radius)
            })
    }

    // MARK: Allontanarsi quando serve

    @Test("Con un canale da un lato, l'asse proposto si inclina dall'altro")
    func axisTiltsAwayFromTheCanal() throws {
        // L'impianto scende verticale da (0, 0, 12) e l'apice arriva a z = 2. Il canale corre a
        // y = +4: inclinando verso −y ci si allontana. È il caso per cui la funzione esiste.
        let implant = ImplantPlacement(
            model: model(), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1), label: "1")
        let nerves = [canal(atY: 4, z: 2)]

        let suggestion = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))

        #expect(suggestion.nerveGainMM > 0.2, "guadagno \(suggestion.nerveGainMM) mm")
        #expect(!suggestion.allCandidatesUnsafe)
        // L'asse si è spostato verso il lato opposto al canale.
        #expect(suggestion.axis.y < -0.01, "asse \(suggestion.axis)")
    }

    @Test("Il margine si satura: lontano dal canale l'asse non si stravolge")
    func farFromTheCanalTheAxisStaysPut() throws {
        // Il canale è a otto millimetri, ben oltre la soglia di attenzione. Un ottimizzatore che
        // non saturasse il margine inclinerebbe comunque, per guadagnare millimetri che non
        // servono a nulla, e restituirebbe un asse tecnicamente ottimo e clinicamente ridicolo.
        let implant = ImplantPlacement(
            model: model(), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1), label: "1")
        let nerves = [canal(atY: 12, z: 2)]

        let suggestion = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))

        #expect(suggestion.angulationDegrees < 1, "inclinato di \(suggestion.angulationDegrees)°")
        #expect(abs(suggestion.nerveGainMM) < 0.5)
    }

    @Test("Se nessuna inclinazione basta, lo dice invece di proporre la meno peggio")
    func hopelessCasesAreDeclared() throws {
        // Il canale passa **dentro** il tragitto dell'impianto, e nessuna inclinazione entro venti
        // gradi lo evita. Il problema non è l'asse: è il punto d'inserzione o l'impianto scelto,
        // e continuare a inclinare non lo risolve.
        let implant = ImplantPlacement(
            model: model(length: 14), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1),
            label: "1")
        let nerves = [canal(atY: 0, z: 2, radius: 2.0)]

        let suggestion = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))
        #expect(suggestion.allCandidatesUnsafe)
    }

    @Test("Un guadagno piccolo non giustifica un'inclinazione grande")
    func smallGainDoesNotJustifyABigTilt() throws {
        // È la prova della **trattenuta**, e va costruita apposta: quasi sempre inclinare guadagna
        // molto margine, e allora la trattenuta non pesa. Qui il canale sta sotto l'apice a poco
        // meno della soglia di attenzione, quindi inclinando si guadagna solo il pezzetto che
        // manca alla saturazione — pochi centesimi di punteggio — mentre l'inclinazione costa.
        //
        // Senza la trattenuta la ricerca inclinerebbe di venti gradi per quei centesimi, e
        // proporrebbe un asse stravolto in cambio di un vantaggio che non esiste.
        let implant = ImplantPlacement(
            model: model(diameter: 3.5, length: 6), platformMM: Vec3(0, 0, 12),
            axis: Vec3(0, 0, -1), label: "1")
        let nerves = [canal(atY: 0, z: 2.7)]

        let baseline = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))
        // Il margine di partenza deve stare **sotto** la saturazione, altrimenti la prova
        // ricadrebbe nel caso già coperto e non proverebbe la trattenuta.
        let distance = try #require(baseline.minimumNerveDistanceMM)
        #expect(distance < SafetyThresholds.nerve.cautionMM, "margine di partenza \(distance) mm")
        #expect(distance >= SafetyThresholds.nerve.dangerMM, "e sopra la soglia critica")

        #expect(
            baseline.angulationDegrees < 6,
            "inclinato di \(baseline.angulationDegrees)° per un guadagno di \(baseline.nerveGainMM) mm")
    }

    // MARK: Che cosa non si propone

    @Test("Senza canali e senza volume non c'è nulla su cui decidere")
    func nothingToDecideGivesNoSuggestion() {
        let implant = ImplantPlacement(
            model: model(), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1), label: "1")
        #expect(ImplantAxisAdvisor.suggest(for: implant, nerves: [], volume: nil) == nil)
    }

    @Test("Un canale con un nodo solo non è un canale e non conta")
    func unusableCanalsAreIgnored() {
        let implant = ImplantPlacement(
            model: model(), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1), label: "1")
        let broken = NerveCanal(side: .right, nodes: [NerveNode(positionMM: Vec3(0, 4, 2))])
        #expect(ImplantAxisAdvisor.suggest(for: implant, nerves: [broken], volume: nil) == nil)
    }

    // MARK: Stabilità

    @Test("La stessa situazione dà sempre la stessa proposta")
    func suggestionIsDeterministic() throws {
        // Campionando a caso la proposta cambierebbe a ogni chiamata, e una proposta che cambia
        // senza che sia cambiato nulla non si può usare per decidere.
        let implant = ImplantPlacement(
            model: model(), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1), label: "1")
        let nerves = [canal(atY: 4, z: 2)]

        let first = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))
        let second = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))
        #expect(first.axis.distance(to: second.axis) < 1e-12)
    }

    @Test("L'inclinazione proposta resta entro il limite protesico")
    func tiltStaysWithinTheProstheticLimit() throws {
        // Venti gradi non è un limite tecnico: oltre, la corona ha bisogno di un moncone
        // angolato. Un asse migliore ma inutilizzabile non è una proposta.
        let implant = ImplantPlacement(
            model: model(), platformMM: Vec3(0, 0, 12), axis: Vec3(0, 0, -1), label: "1")
        let nerves = [canal(atY: 3, z: 2)]

        let suggestion = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: nerves, volume: nil))
        let tilt = suggestion.axis.angle(to: Vec3(0, 0, -1))! * 180 / .pi
        #expect(tilt <= ImplantAxisAdvisor.maximumTiltDegrees + 1e-9, "inclinato di \(tilt)°")
    }

    // MARK: L'osso

    @Test("A parità di nervo, si preferisce l'osso migliore")
    func denserBoneWinsWhenTheNerveIsEquivalent() throws {
        // Nessun canale: decide il solo osso. Nel fantoccio il cubo corticale sta al centro e
        // attorno c'è aria, quindi l'asse migliore è quello che resta dentro il cubo.
        let volume = try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5))
        let implant = ImplantPlacement(
            model: model(diameter: 3, length: 8), platformMM: Vec3(0, 0, 9),
            axis: Vec3(0, 0, -1), label: "1")

        let suggestion = try #require(
            ImplantAxisAdvisor.suggest(for: implant, nerves: [], volume: volume))
        let mean = try #require(suggestion.meanBoneGV)
        #expect(mean > 0, "densità media \(mean) GV")
        // Restando verticale l'impianto attraversa il cubo; inclinandolo ne esce.
        #expect(suggestion.angulationDegrees < 12, "inclinato di \(suggestion.angulationDegrees)°")
    }
}
