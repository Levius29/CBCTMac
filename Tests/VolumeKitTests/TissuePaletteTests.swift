import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Le tinte del preset «Tessuti distinti» devono essere distinguibili davvero.
//
// I preset realistici imitano il tessuto vero, e la ragione resta buona; il prezzo è che osso
// spugnoso, corticale, dentina e smalto sono quattro beige, e a schermo diventano un impasto —
// la differenza c'è nei dati e non nell'immagine.
//
// Distinguibile non è un'opinione: due tinte che differiscono solo in **chiarezza** tornano
// uguali appena l'ombreggiatura le colpisce da angoli diversi, e l'ombreggiatura in un rendering
// volumetrico cambia da un voxel all'altro. La differenza deve stare nella **tonalità**, che
// l'illuminazione non tocca. È questo che le prove qui sotto verificano.

@Suite("Tinte dei tessuti")
struct TissuePaletteTests {

    /// Tonalità in gradi, come la si intende in HSV.
    private func hue(_ colour: TransferColor) -> Double {
        let r = colour.red, g = colour.green, b = colour.blue
        let highest = max(r, max(g, b))
        let lowest = min(r, min(g, b))
        let span = highest - lowest
        guard span > 1e-9 else { return 0 }
        let value: Double
        if highest == r {
            value = 60 * (((g - b) / span).truncatingRemainder(dividingBy: 6))
        } else if highest == g {
            value = 60 * ((b - r) / span + 2)
        } else {
            value = 60 * ((r - g) / span + 4)
        }
        return value < 0 ? value + 360 : value
    }

    private func saturation(_ colour: TransferColor) -> Double {
        let highest = max(colour.red, max(colour.green, colour.blue))
        let lowest = min(colour.red, min(colour.green, colour.blue))
        guard highest > 1e-9 else { return 0 }
        return (highest - lowest) / highest
    }

    /// Distanza angolare fra due tonalità, sul cerchio.
    private func hueDistance(_ first: TransferColor, _ second: TransferColor) -> Double {
        let difference = abs(hue(first) - hue(second)).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    private var tissues: [(name: String, colour: TransferColor)] {
        [
            ("grasso e pelle", .fat),
            ("muscolo", .muscle),
            ("osso spugnoso", .cancellous),
            ("corona dentale", .toothCrown),
            ("restauri", .restoration),
        ]
    }

    @Test("Le cinque tinte sature distano almeno quaranta gradi l'una dall'altra")
    func theFiveTissueHuesAreFarApart() {
        for (indexA, a) in tissues.enumerated() {
            for b in tissues[(indexA + 1)...] {
                let distance = hueDistance(a.colour, b.colour)
                #expect(
                    distance >= 40,
                    "\(a.name) e \(b.name) distano \(Int(distance))° di tonalità")
            }
        }
    }

    @Test("Non si distinguono per sola chiarezza, che l'ombreggiatura cancella")
    func theyDoNotRelyOnLightnessAlone() {
        // La corticale è volutamente quasi bianca — è il guscio, e va letta come tale — quindi
        // resta fuori da questa prova. Tutte le altre devono avere colore, non solo grigio.
        for tissue in tissues {
            #expect(
                saturation(tissue.colour) > 0.2,
                "\(tissue.name) è troppo vicina al grigio: \(saturation(tissue.colour))")
        }
    }

    @Test("Il preset copre tutte le fasce, dalla pelle ai restauri")
    func thePresetSpansSkinToRestorations() {
        let function = TransferFunction.distinctTissues

        // Un campione dentro ogni fascia deve prendere la tinta di quella fascia.
        let expectations: [(density: Double, colour: TransferColor, name: String)] = [
            (-70, .fat, "grasso"),
            (80, .muscle, "muscolo"),
            (450, .cancellous, "osso spugnoso"),
            (1050, .cortical, "corticale"),
            (2000, .toothCrown, "corona"),
            (3200, .restoration, "restauro"),
        ]
        for expectation in expectations {
            let (colour, _) = function.sample(at: expectation.density)
            #expect(
                hueDistance(colour, expectation.colour) < 20,
                "a \(Int(expectation.density)) GV la tinta non è quella di \(expectation.name)")
        }
    }

    @Test("L'opacità cresce con la densità: quel che sta dietro non copre quel che sta davanti")
    func opacityGrowsWithDensity() {
        let function = TransferFunction.distinctTissues
        var previous = -1.0
        for density in stride(from: -300.0, through: 3400, by: 100) {
            let (_, opacity) = function.sample(at: density)
            #expect(opacity >= previous - 1e-9, "l'opacità cala a \(Int(density)) GV")
            previous = opacity
        }
        // E la pelle resta trasparente abbastanza da lasciar vedere l'osso sotto.
        #expect(function.sample(at: -70).opacity < 0.15)
        #expect(function.sample(at: 1050).opacity > 0.5)
    }

    @Test("L'aria non si disegna")
    func airDrawsNothing() {
        let function = TransferFunction.distinctTissues
        for density in [-1000.0, -800, -500, -350] {
            #expect(function.sample(at: density).opacity == 0)
        }
    }

    @Test("Il preset è nell'elenco, altrimenti non lo raggiunge nessuno")
    func thePresetIsListed() {
        #expect(TransferFunction.presets.contains { $0.name == "Tessuti distinti" })
    }
}
