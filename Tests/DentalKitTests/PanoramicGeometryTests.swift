import DICOMCore
import Testing

@testable import DentalKit

// Geometria del panorex: isotropia della scala e centratura verticale.
//
// Qui c'era un difetto che produceva tre sintomi in una volta — immagine schiacciata in altezza,
// sbilanciata verso l'alto e fuori centro — e la cui causa era una sola: la scala orizzontale era
// `lunghezzaCurva / larghezza`, quella verticale un valore fisso di 0,2 mm per pixel, e il bordo
// alto dell'immagine era ancorato al bordo di una finestra da 70 mm invece che centrato.
//
// L'aspetto era il sintomo meno grave. Con due scale diverse una misura verticale sul panorex non
// è confrontabile con una orizzontale, e un panorex ricostruito serve proprio a prendere misure.
// Per questo l'isotropia è un test e non un dettaglio di resa.

@Suite("Geometria del panorex")
struct PanoramicGeometryTests {

    private func makeCurve() -> ArchCurve {
        // Un arco a U con l'apice in avanti, punti a quota z = 5.
        ArchCurve(controlPointsMM: [
            Vec3(-25, 10, 5), Vec3(-18, -6, 5), Vec3(0, -14, 5),
            Vec3(18, -6, 5), Vec3(25, 10, 5),
        ])
    }

    private func makeLayout(verticalCentreMM: Double = 5) -> PanoramicLayout {
        PanoramicLayout(
            curve: makeCurve(),
            heightMM: 70,
            verticalCentreMM: verticalCentreMM,
            slabThicknessMM: 20,
            projection: .maximum,
            millimetresPerPixel: 0.2)
    }

    // MARK: Isotropia

    @Test("La scala verticale coincide con quella orizzontale")
    func scaleIsIsotropic() {
        let layout = makeLayout()

        for width in [320, 640, 1000, 1920] {
            // Scala orizzontale: il renderer ricampiona **tutta** la curva su `width` colonne,
            // quindi vale per costruzione lunghezza/larghezza. Non è una scelta, è una
            // conseguenza, ed è la verticale che deve adeguarsi.
            let horizontal = layout.curve.lengthMM / Double(width)
            let vertical = layout.downStepMM(pixelWidth: width).length

            #expect(
                abs(vertical - horizontal) < 1e-12,
                "larghezza \(width): orizzontale \(horizontal), verticale \(vertical)")
            #expect(abs(layout.millimetresPerPixel(pixelWidth: width) - horizontal) < 1e-12)
        }
    }

    @Test("Il passo verticale punta verso i piedi")
    func downStepPointsInferior() {
        let step = makeLayout().downStepMM(pixelWidth: 640)
        // L'asse verticale predefinito è +Z, che in LPS è superiore: il basso dello schermo deve
        // andare nella direzione opposta.
        #expect(step.z < 0)
        #expect(abs(step.x) < 1e-12)
        #expect(abs(step.y) < 1e-12)
    }

    @Test("La scala non degenera con una larghezza non valida")
    func scaleFallsBackOnInvalidWidth() {
        let layout = makeLayout()
        // Ricadere sul valore richiesto è preferibile a dividere per zero: succede al più per il
        // primo fotogramma, prima che il riquadro abbia una dimensione.
        #expect(layout.millimetresPerPixel(pixelWidth: 0) == 0.2)
    }

    // MARK: Centratura verticale

    @Test("La quota richiesta cade al centro dell'immagine")
    func verticalCentreIsHonoured() {
        let width = 800
        for centre in [-20.0, 0.0, 5.0, 33.5] {
            let layout = makeLayout(verticalCentreMM: centre)
            let scale = layout.millimetresPerPixel(pixelWidth: width)
            guard let sample = layout.columnSamples(pixelWidth: width).first else {
                Issue.record("nessun campione")
                return
            }

            for height in [1, 2, 240, 601] {
                let top = layout.topOfColumn(
                    sample, pixelWidth: width, pixelHeight: height)
                // Riga centrale: `(altezza − 1)/2` passi sotto il bordo alto. Con quella
                // convenzione la simmetria è esatta per qualunque altezza, pari o dispari.
                let middle = top + layout.downStepMM(pixelWidth: width)
                    * (Double(height - 1) * 0.5)

                #expect(
                    abs(middle.z - centre) < 1e-9,
                    "quota \(centre), altezza \(height): centro a \(middle.z)")
                // La componente nel piano non deve cambiare: la verticale è l'unica direzione in
                // cui `topOfColumn` sposta il campione.
                #expect(abs(middle.x - sample.positionMM.x) < 1e-9)
                #expect(abs(middle.y - sample.positionMM.y) < 1e-9)
                _ = scale
            }
        }
    }

    @Test("L'immagine si estende in modo simmetrico sopra e sotto")
    func verticalExtentIsSymmetric() {
        let width = 800
        let height = 300
        let layout = makeLayout(verticalCentreMM: 5)
        guard let sample = layout.columnSamples(pixelWidth: width).first else {
            Issue.record("nessun campione")
            return
        }

        let step = layout.downStepMM(pixelWidth: width)
        let top = layout.topOfColumn(sample, pixelWidth: width, pixelHeight: height)
        let bottom = top + step * Double(height - 1)

        let above = top.z - 5
        let below = 5 - bottom.z
        #expect(above > 0)
        #expect(abs(above - below) < 1e-9, "sopra \(above) mm, sotto \(below) mm")
    }

    @Test("L'altezza inquadrata cresce con l'altezza del riquadro")
    func visibleHeightFollowsPixelHeight() {
        let layout = makeLayout()
        let width = 800
        let scale = layout.millimetresPerPixel(pixelWidth: width)

        // Un riquadro più alto mostra **più anatomia**, non la stessa anatomia più stirata: è la
        // conseguenza diretta dell'avere una scala sola, e va verificata perché è il
        // comportamento che sostituisce la vecchia altezza fissa a 70 mm.
        for height in [100, 300, 900] {
            let visible = layout.visibleHeightMM(pixelWidth: width, pixelHeight: height)
            #expect(abs(visible - scale * Double(height)) < 1e-12)
        }

        let small = layout.visibleHeightMM(pixelWidth: width, pixelHeight: 100)
        let large = layout.visibleHeightMM(pixelWidth: width, pixelHeight: 900)
        #expect(large > small * 8.9)
    }

    // MARK: Copertura orizzontale

    @Test("Le colonne coprono la curva a passo costante, col passo che la scala dichiara")
    func columnsSpanTheWholeCurve() {
        let layout = makeLayout()
        let width = 500
        let samples = layout.columnSamples(pixelWidth: width)

        #expect(samples.count == width)
        guard let first = samples.first, let last = samples.last else {
            Issue.record("campioni mancanti")
            return
        }

        // Ogni colonna campiona il **centro** della fetta d'arcata che rappresenta, quindi la
        // prima e l'ultima stanno mezzo passo dentro i capi della curva.
        //
        // Prima questa prova pretendeva `0` e `lengthMM` esatti, cioè `width − 1` intervalli su
        // `width` colonne. Sembra più preciso e non lo è: `millimetresPerPixel` divide la stessa
        // lunghezza per `width`, e la differenza fra i due denominatori è una dilatazione
        // orizzontale dello 0,2 % che si presentava solo a ingrandimento 1. Una prova che fissa
        // un difetto lo protegge, e questa lo proteggeva.
        let expectedStep = layout.curve.lengthMM / Double(width)
        #expect(abs(first.arcLengthMM - expectedStep * 0.5) < 1e-9)
        #expect(abs(last.arcLengthMM - (layout.curve.lengthMM - expectedStep * 0.5)) < 1e-6)

        // Passo costante in lunghezza d'arco: è ciò che rende leggibile una misura orizzontale.
        for index in 1..<samples.count {
            let step = samples[index].arcLengthMM - samples[index - 1].arcLengthMM
            #expect(abs(step - expectedStep) < 1e-6, "colonna \(index): passo \(step)")
        }

        // E il passo è **quello che la barra di scala dichiara**: è l'uguaglianza che rende
        // isotropa l'immagine, e quella che prima non valeva.
        #expect(abs(expectedStep - layout.millimetresPerPixel(pixelWidth: width)) < 1e-12)
    }
}
