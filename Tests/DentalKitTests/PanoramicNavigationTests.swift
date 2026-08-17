import DICOMCore
import Testing

@testable import DentalKit

// Scorrimento e ingrandimento del panorex.
//
// A ingrandimento 1 la finestra visibile è l'arcata intera, e non c'è niente in cui scorrere: lo
// zoom è il presupposto dello scorrimento, non un extra. Da lì la finestra diventa un tratto
// d'arco e si percorre come si scorre una finestra su un'immagine più lunga.
//
// La proprietà che tutte queste prove verificano è una sola: la finestra resta **dentro** la
// curva. Uscirne significherebbe colonne che campionano oltre i capi dell'arcata, cioè bande
// nere ai lati e — peggio — una scala orizzontale che non corrisponde più alla lunghezza d'arco.

@Suite("Navigazione del panorex")
struct PanoramicNavigationTests {

    private func makeCurve() -> ArchCurve {
        ArchCurve(controlPointsMM: [
            Vec3(-25, 10, 5), Vec3(-18, -6, 5), Vec3(0, -14, 5),
            Vec3(18, -6, 5), Vec3(25, 10, 5),
        ])
    }

    private func makeLayout(zoom: Double = 1, arcCentreMM: Double? = nil) -> PanoramicLayout {
        PanoramicLayout(
            curve: makeCurve(),
            heightMM: 70,
            verticalCentreMM: 5,
            slabThicknessMM: 20,
            projection: .maximum,
            millimetresPerPixel: 0.2,
            zoom: zoom,
            arcCentreMM: arcCentreMM)
    }

    // MARK: Finestra visibile

    @Test("A ingrandimento 1 la finestra è l'arcata intera")
    func unzoomedWindowIsTheWholeArch() {
        let layout = makeLayout()
        let range = layout.visibleArcRangeMM

        #expect(abs(range.lowerBound) < 1e-9)
        #expect(abs(range.upperBound - layout.curve.lengthMM) < 1e-9)
        #expect(layout.effectiveZoom == 1)
    }

    @Test("L'ingrandimento restringe la finestra in proporzione")
    func zoomNarrowsTheWindow() {
        let total = makeLayout().curve.lengthMM
        for zoom in [1.5, 2.0, 4.0, 10.0] {
            let layout = makeLayout(zoom: zoom)
            let range = layout.visibleArcRangeMM
            let span = range.upperBound - range.lowerBound
            #expect(abs(span - total / zoom) < 1e-9, "zoom \(zoom): finestra \(span) mm")
        }
    }

    @Test("Un ingrandimento sotto 1 viene riportato a 1")
    func zoomBelowOneIsClamped() {
        // Sotto 1 l'arcata occuperebbe meno della larghezza, lasciando bande vuote ai lati: si
        // potrebbe fare e non serve a nulla.
        #expect(makeLayout(zoom: 0.5).effectiveZoom == 1)
        #expect(makeLayout(zoom: 0).effectiveZoom == 1)
        #expect(makeLayout(zoom: -3).effectiveZoom == 1)
        #expect(makeLayout(zoom: .nan).effectiveZoom == 1)
    }

    // MARK: Lo scorrimento si ferma contro i capi

    @Test("La finestra non esce mai dalla curva")
    func windowNeverLeavesTheCurve() {
        let total = makeLayout().curve.lengthMM

        // Centri richiesti assurdi compresi: è quello che produce un trascinamento continuato.
        for requested in [-500.0, -1.0, 0.0, total / 2, total, total + 500] {
            for zoom in [1.0, 2.0, 3.0, 8.0] {
                let layout = makeLayout(zoom: zoom, arcCentreMM: requested)
                let range = layout.visibleArcRangeMM
                #expect(
                    range.lowerBound >= -1e-9,
                    "zoom \(zoom), centro \(requested): inizio \(range.lowerBound)")
                #expect(
                    range.upperBound <= total + 1e-9,
                    "zoom \(zoom), centro \(requested): fine \(range.upperBound)")
            }
        }
    }

    @Test("A ingrandimento 1 il centro è forzato a metà curva")
    func centreIsPinnedWhenNotZoomed() {
        let total = makeLayout().curve.lengthMM
        // Con la finestra larga quanto la curva non c'è margine per scorrere, e il centro
        // richiesto va ignorato invece di spostare l'immagine fuori dai dati.
        for requested in [0.0, total, -20, total * 2] {
            let layout = makeLayout(zoom: 1, arcCentreMM: requested)
            #expect(abs(layout.clampedArcCentreMM - total / 2) < 1e-9)
        }
    }

    @Test("Scorrere accumula, e si arresta contro il capo")
    func scrollingAccumulatesAndStops() {
        var layout = makeLayout(zoom: 4)
        let total = layout.curve.lengthMM
        let start = layout.clampedArcCentreMM

        layout = layout.scrolled(byArcMM: 5)
        #expect(abs(layout.clampedArcCentreMM - (start + 5)) < 1e-9)

        layout = layout.scrolled(byArcMM: 5)
        #expect(abs(layout.clampedArcCentreMM - (start + 10)) < 1e-9)

        // Scorrimenti ripetuti oltre il capo non "accumulano debito": arrivati al fondo,
        // continuare a trascinare non deve poi richiedere altrettanto per tornare indietro.
        for _ in 0..<20 { layout = layout.scrolled(byArcMM: 20) }
        let atEnd = layout.clampedArcCentreMM
        #expect(abs(atEnd - (total - layout.visibleArcHalfLengthMM)) < 1e-9)

        layout = layout.scrolled(byArcMM: -3)
        #expect(abs(layout.clampedArcCentreMM - (atEnd - 3)) < 1e-9)
    }

    @Test("Uno scorrimento non finito non muove nulla")
    func nonFiniteScrollIsIgnored() {
        let layout = makeLayout(zoom: 3)
        let before = layout.clampedArcCentreMM
        #expect(abs(layout.scrolled(byArcMM: .nan).clampedArcCentreMM - before) < 1e-9)
        #expect(abs(layout.scrolled(byArcMM: .infinity).clampedArcCentreMM - before) < 1e-9)
    }

    // MARK: Colonne

    @Test("Le colonne coprono la finestra visibile, non l'intera curva")
    func columnsCoverTheVisibleWindow() {
        let layout = makeLayout(zoom: 3, arcCentreMM: 40)
        let width = 400
        let samples = layout.columnSamples(pixelWidth: width)
        let range = layout.visibleArcRangeMM

        #expect(samples.count == width)
        guard let first = samples.first, let last = samples.last else {
            Issue.record("campioni mancanti")
            return
        }

        // Mezzo pixel dentro il bordo, per la convenzione dei centri di pixel.
        let step = (range.upperBound - range.lowerBound) / Double(width)
        #expect(abs(first.arcLengthMM - (range.lowerBound + step * 0.5)) < 1e-6)
        #expect(abs(last.arcLengthMM - (range.upperBound - step * 0.5)) < 1e-6)

        // Passo costante in lunghezza d'arco anche ingranditi: è la proprietà che rende leggibile
        // una misura orizzontale, e ingrandire non deve poterla rompere.
        for index in 1..<samples.count {
            let delta = samples[index].arcLengthMM - samples[index - 1].arcLengthMM
            #expect(abs(delta - step) < 1e-6, "colonna \(index): passo \(delta)")
        }
    }

    @Test("La scala resta isotropa a qualunque ingrandimento")
    func scaleStaysIsotropicWhenZoomed() {
        let width = 800
        for zoom in [1.0, 2.5, 6.0] {
            let layout = makeLayout(zoom: zoom, arcCentreMM: 30)
            let horizontal =
                (layout.visibleArcRangeMM.upperBound - layout.visibleArcRangeMM.lowerBound)
                / Double(width)
            let vertical = layout.downStepMM(pixelWidth: width).length
            #expect(
                abs(vertical - horizontal) < 1e-12,
                "zoom \(zoom): orizzontale \(horizontal), verticale \(vertical)")
        }
    }

    // MARK: Zoom ancorato

    @Test("Lo zoom tiene fermo il punto dell'arcata sotto il pixel")
    func anchoredZoomKeepsArcLengthUnderCursor() {
        let width = 800
        let layout = makeLayout(zoom: 2, arcCentreMM: 35)

        for x in [0.0, 200.0, 399.5, 650.0, 799.0] {
            let before = layout.arcLengthMM(atPixelX: x, pixelWidth: width)
            let zoomed = layout.zoomed(by: 2, aboutPixelX: x, pixelWidth: width)
            let after = zoomed.arcLengthMM(atPixelX: x, pixelWidth: width)

            // Vicino ai capi la limitazione della finestra può impedire l'ancoraggio esatto: è
            // corretto così, perché restare dentro la curva viene prima. Si verifica quindi
            // l'ancoraggio dove c'è margine, e altrove solo che la finestra resti valida.
            let half = zoomed.visibleArcHalfLengthMM
            let hasRoom = before > half + 1 && before < layout.curve.lengthMM - half - 1
            if hasRoom {
                #expect(abs(after - before) < 1e-6, "pixel \(x): da \(before) a \(after)")
            } else {
                #expect(zoomed.visibleArcRangeMM.lowerBound >= -1e-9)
                #expect(zoomed.visibleArcRangeMM.upperBound <= layout.curve.lengthMM + 1e-9)
            }
        }
    }

    @Test("Lo zoom non scende sotto l'arcata intera")
    func zoomingOutStopsAtTheWholeArch() {
        let layout = makeLayout(zoom: 2)
        let out = layout.zoomed(by: 0.1, aboutPixelX: 400, pixelWidth: 800)
        #expect(out.effectiveZoom == 1)
        // E tornati a 1, la finestra è di nuovo l'arcata intera e centrata.
        #expect(abs(out.visibleArcRangeMM.lowerBound) < 1e-9)
        #expect(abs(out.visibleArcRangeMM.upperBound - layout.curve.lengthMM) < 1e-9)
    }

    // MARK: Campionamento a lunghezze arbitrarie

    @Test("Le lunghezze fuori intervallo si limitano ai capi")
    func arbitraryArcLengthsAreClamped() {
        let curve = makeCurve()
        let total = curve.lengthMM
        let samples = curve.samples(atArcLengthsMM: [-50, 0, total / 2, total, total + 50])

        #expect(samples.count == 5)
        #expect(abs(samples[0].arcLengthMM) < 1e-9)
        #expect(abs(samples[1].arcLengthMM) < 1e-9)
        #expect(abs(samples[3].arcLengthMM - total) < 1e-9)
        #expect(abs(samples[4].arcLengthMM - total) < 1e-9)
        // Il campione limitato coincide con quello del capo, non è un punto inventato.
        #expect(samples[0].positionMM.isApproximatelyEqual(to: samples[1].positionMM, tolerance: 1e-9))
    }

    @Test("Lunghezze fuori ordine danno comunque il risultato giusto")
    func unsortedArcLengthsStillWork() {
        let curve = makeCurve()
        let total = curve.lengthMM
        let ascending = curve.samples(atArcLengthsMM: [total * 0.2, total * 0.8])
        let descending = curve.samples(atArcLengthsMM: [total * 0.8, total * 0.2])

        // La ricerca monotòna riparte da capo quando la lunghezza torna indietro: il costo
        // peggiora, la correttezza no.
        #expect(
            ascending[0].positionMM.isApproximatelyEqual(
                to: descending[1].positionMM, tolerance: 1e-9))
        #expect(
            ascending[1].positionMM.isApproximatelyEqual(
                to: descending[0].positionMM, tolerance: 1e-9))
    }

    @Test("Una curva inutilizzabile non produce campioni")
    func unusableCurveYieldsNothing() {
        let curve = ArchCurve(controlPointsMM: [Vec3(0, 0, 0)])
        #expect(curve.samples(atArcLengthsMM: [0, 1, 2]).isEmpty)
        #expect(makeCurve().samples(atArcLengthsMM: []).isEmpty)
    }
}
