import DICOMCore
import Testing

@testable import DentalKit

// Dal clic ai millimetri, sulla panorex.
//
// È la conversione che mancava, e la sua assenza si vedeva come «gli strumenti funzionano solo in
// certi riquadri». Qui non si verifica che il codice faccia quello che fa — sarebbe una prova
// che non può fallire — ma che le proprietà di una panorex corretta reggano: scala isotropa,
// passo uniforme lungo l'arco, i capi dell'arcata sui bordi dell'immagine, e lo scostamento
// vestibolo-linguale che sposta esattamente di quanto dice.

@Suite("Clic sulla panorex")
struct PanoramicPickingTests {

    private func makeCurve() -> ArchCurve {
        ArchCurve(controlPointsMM: [
            Vec3(-25, 10, 5), Vec3(-18, -6, 5), Vec3(0, -14, 5),
            Vec3(18, -6, 5), Vec3(25, 10, 5),
        ])
    }

    private func makeLayout(
        zoom: Double = 1, arcCentreMM: Double? = nil, normalOffsetMM: Double = 0
    ) -> PanoramicLayout {
        PanoramicLayout(
            curve: makeCurve(),
            heightMM: 70,
            verticalCentreMM: 5,
            slabThicknessMM: 20,
            projection: .maximum,
            millimetresPerPixel: 0.2,
            zoom: zoom,
            arcCentreMM: arcCentreMM,
            normalOffsetMM: normalOffsetMM)
    }

    private let width = 600
    private let height = 300

    // MARK: Coincidenza con ciò che è stato disegnato

    @Test("Il punto sotto un pixel è quello che il renderer ha campionato")
    func pickMatchesTheRenderedColumn() throws {
        // Il renderer prende `columnSamples` e ne calcola il bordo alto; il clic deve ricadere
        // sullo stesso punto, altrimenti si misura su un'immagine e si legge su un'altra.
        for layout in [makeLayout(), makeLayout(zoom: 3, arcCentreMM: 40)] {
            let samples = layout.columnSamples(pixelWidth: width)
            for column in [0, 1, width / 2, width - 2, width - 1] {
                let expected = layout.topOfColumn(
                    samples[column], pixelWidth: width, pixelHeight: height)
                let picked = try #require(
                    layout.patientPoint(
                        atPixelX: Double(column), y: 0,
                        pixelWidth: width, pixelHeight: height))
                #expect(picked.distance(to: expected) < 1e-9, "colonna \(column)")
            }
        }
    }

    // MARK: I capi dell'arcata

    @Test("A ingrandimento 1 le colonne di bordo stanno mezza colonna dentro i capi della curva")
    func unzoomedEdgesSitHalfAColumnInside() throws {
        // Mezza colonna e non zero: è il prezzo dichiarato della convenzione unica del centro
        // pixel. Su un'arcata di 130 mm in 600 colonne fa un decimo di millimetro per lato, oltre
        // l'ultimo molare. Questa prova fissa quel prezzo, così se un giorno diventasse una
        // colonna intera si vedrebbe subito.
        let layout = makeLayout()
        let curve = layout.curve
        let half = curve.lengthMM / Double(width) * 0.5
        let ends = curve.samples(atArcLengthsMM: [half, curve.lengthMM - half])

        // Il confronto è sulle sole componenti orizzontali: la quota la impone
        // `verticalCentreMM`, e non è quella dei punti di controllo.
        let up = curve.upAxis
        func horizontal(_ point: Vec3) -> Vec3 { point - up * point.dot(up) }

        let first = try #require(
            layout.patientPoint(atPixelX: 0, y: 0, pixelWidth: width, pixelHeight: height))
        let last = try #require(
            layout.patientPoint(
                atPixelX: Double(width - 1), y: 0, pixelWidth: width, pixelHeight: height))

        #expect(horizontal(first).distance(to: horizontal(ends[0].positionMM)) < 1e-9)
        #expect(horizontal(last).distance(to: horizontal(ends[1].positionMM)) < 1e-9)
    }

    // MARK: Scala

    @Test("Il passo orizzontale segue la lunghezza d'arco, non la corda")
    func horizontalStepFollowsArcLength() throws {
        // Se le colonne fossero equidistanti nel parametro invece che nell'arco, la somma delle
        // corde fra colonne vicine sarebbe sensibilmente più corta della lunghezza della curva
        // proprio nei tratti curvi. Con il campionamento ad arco costante la somma delle corde
        // approssima la lunghezza per difetto di pochissimo: è la freccia della curvatura su
        // 0,2 mm di passo, cioè parti per milione.
        let layout = makeLayout()
        var travelled = 0.0
        var previous = try #require(
            layout.patientPoint(atPixelX: 0, y: 0, pixelWidth: width, pixelHeight: height))
        for column in 1..<width {
            let point = try #require(
                layout.patientPoint(
                    atPixelX: Double(column), y: 0, pixelWidth: width, pixelHeight: height))
            travelled += previous.distance(to: point)
            previous = point
        }

        // Il bersaglio è `(width − 1)` passi e non l'arcata intera: le colonne campionano i
        // centri delle fette, quindi fra la prima e l'ultima ci sono `width − 1` passi e mezzo
        // passo resta fuori per lato.
        let expected = layout.millimetresPerPixel(pixelWidth: width) * Double(width - 1)
        #expect(travelled <= expected + 1e-9, "le corde non possono superare l'arco")
        #expect(
            travelled > expected * 0.9999,
            "somma corde \(travelled) mm su \(expected) mm d'arco")
    }

    @Test("Il passo verticale vale i millimetri per pixel e scende verso i piedi")
    func verticalStepIsIsotropicAndPointsDown() throws {
        let layout = makeLayout()
        let scale = layout.millimetresPerPixel(pixelWidth: width)

        let top = try #require(
            layout.patientPoint(atPixelX: 300, y: 0, pixelWidth: width, pixelHeight: height))
        let bottom = try #require(
            layout.patientPoint(
                atPixelX: 300, y: Double(height - 1), pixelWidth: width, pixelHeight: height))

        let span = top.distance(to: bottom)
        #expect(abs(span - scale * Double(height - 1)) < 1e-9)
        // Verso i piedi: componente negativa lungo l'asse verticale del paziente.
        #expect((bottom - top).dot(layout.curve.upAxis) < 0)
    }

    @Test("La scala è la stessa in orizzontale e in verticale")
    func scaleIsIsotropic() throws {
        // Serve perché un oggetto rotondo deve misurare uguale in ogni direzione: con scale
        // diverse una misura obliqua sbaglierebbe di una quantità che dipende dall'angolo, cioè
        // nel modo più difficile da accorgersene.
        //
        // Il passo orizzontale si legge in lunghezza d'arco e non come corda fra due colonne
        // lontane: la corda è per definizione più corta dell'arco, e sull'arcata anteriore lo è
        // del due per cento. Che l'arco corrisponda poi a una distanza vera in millimetri lo
        // stabiliscono le due prove precedenti.
        let layout = makeLayout()
        let scale = layout.millimetresPerPixel(pixelWidth: width)

        let arcSpan =
            layout.arcLengthMM(atPixelX: 350, pixelWidth: width)
            - layout.arcLengthMM(atPixelX: 250, pixelWidth: width)

        let a = try #require(
            layout.patientPoint(atPixelX: 250, y: 0, pixelWidth: width, pixelHeight: height))
        let c = try #require(
            layout.patientPoint(atPixelX: 250, y: 100, pixelWidth: width, pixelHeight: height))
        let vertical = a.distance(to: c)

        #expect(abs(vertical - scale * 100) < 1e-9)
        #expect(
            abs(arcSpan - vertical) < 1e-9,
            "orizzontale \(arcSpan) mm, verticale \(vertical) mm")
    }

    @Test("Cento colonne d'arcata anteriore misurano cento passi, a meno del taglio d'angolo")
    func chordSumOverCurvedRegionStaysWithinPolylineError() throws {
        // La stessa tratta percorsa corda per corda, che è ciò che fa chi misura sull'immagine.
        // Resta sotto l'arco, e deve: ogni corda che scavalca un vertice della poligonale densa
        // ne taglia l'angolo. Sull'anteriore vale due centesimi di millimetro su dodici, e questa
        // prova esiste per fissare quel numero — se un giorno crescesse, la poligonale si sarebbe
        // fatta più grossolana e le misure ne risentirebbero.
        let layout = makeLayout()
        let scale = layout.millimetresPerPixel(pixelWidth: width)

        var travelled = 0.0
        var previous = try #require(
            layout.patientPoint(atPixelX: 250, y: 0, pixelWidth: width, pixelHeight: height))
        for column in 251...350 {
            let point = try #require(
                layout.patientPoint(
                    atPixelX: Double(column), y: 0, pixelWidth: width, pixelHeight: height))
            travelled += previous.distance(to: point)
            previous = point
        }

        let expected = scale * 100
        #expect(travelled <= expected + 1e-9, "la corda non può superare l'arco")
        #expect(
            travelled > expected * 0.997,
            "percorso \(travelled) mm su \(expected) mm d'arco")
    }

    // MARK: Ingrandimento e scostamento

    @Test("Ingranditi, la colonna centrale cade sul centro della finestra")
    func zoomedCentreColumnIsTheWindowCentre() throws {
        let layout = makeLayout(zoom: 3, arcCentreMM: 40)
        let centreColumn = Double(width) / 2 - 0.5
        let arc = layout.arcLengthMM(atPixelX: centreColumn, pixelWidth: width)
        #expect(abs(arc - layout.clampedArcCentreMM) < 1e-9)
    }

    @Test("Lo scostamento vestibolo-linguale sposta il punto lungo la normale, di quanto dice")
    func normalOffsetShiftsAlongTheNormal() throws {
        let plain = makeLayout()
        let shifted = makeLayout(normalOffsetMM: 4)
        let column = 220.0

        let a = try #require(
            plain.patientPoint(atPixelX: column, y: 150, pixelWidth: width, pixelHeight: height))
        let b = try #require(
            shifted.patientPoint(atPixelX: column, y: 150, pixelWidth: width, pixelHeight: height))

        let arc = plain.arcLengthMM(atPixelX: column, pixelWidth: width)
        let sample = try #require(plain.curve.samples(atArcLengthsMM: [arc]).first)

        let delta = b - a
        #expect(abs(delta.length - 4) < 1e-9, "spostamento \(delta.length) mm")
        #expect(delta.distance(to: sample.normal * 4) < 1e-9)
    }

    // MARK: Andata e ritorno

    @Test("Un punto preso da un pixel torna su quel pixel")
    func projectionInvertsPicking() throws {
        // È la proprietà che rende utilizzabile la sovraimpressione: se andata e ritorno non
        // coincidessero, una misura apparirebbe spostata rispetto al punto in cui è stata posata,
        // e la si darebbe per sbagliata quando invece sbaglia il disegno.
        for layout in [makeLayout(), makeLayout(zoom: 2.5, arcCentreMM: 50), makeLayout(normalOffsetMM: 3)] {
            for column in [40.0, 180.0, 299.5, 420.0, 560.0] {
                for row in [0.0, 90.0, 210.0] {
                    let point = try #require(
                        layout.patientPoint(
                            atPixelX: column, y: row, pixelWidth: width, pixelHeight: height))
                    let back = try #require(
                        layout.projection(
                            ofPatient: point, pixelWidth: width, pixelHeight: height))

                    // La colonna passa dalla lunghezza d'arco della poligonale densa, e ritrovarla
                    // costa una ricerca del punto più vicino: mezzo millesimo di colonna è il
                    // residuo di quella ricerca, non uno scarto di convenzione.
                    #expect(abs(back.x - column) < 0.01, "colonna \(column), riga \(row): \(back.x)")
                    #expect(abs(back.y - row) < 0.01, "colonna \(column), riga \(row): \(back.y)")
                    #expect(
                        abs(back.depthMM) < 0.01,
                        "un punto preso sulla superficie ha profondità nulla: \(back.depthMM)")
                }
            }
        }
    }

    @Test("La profondità dice di quanto un punto è fuori dalla superficie ricostruita")
    func projectionReportsDepthOffTheSurface() throws {
        let layout = makeLayout()
        let onSurface = try #require(
            layout.patientPoint(atPixelX: 300, y: 150, pixelWidth: width, pixelHeight: height))
        let arc = layout.arcLengthMM(atPixelX: 300, pixelWidth: width)
        let sample = try #require(layout.curve.samples(atArcLengthsMM: [arc]).first)

        for offset in [-6.0, -1.5, 2.0, 7.5] {
            let moved = onSurface + sample.normal * offset
            let back = try #require(
                layout.projection(ofPatient: moved, pixelWidth: width, pixelHeight: height))
            // Spostandosi lungo la normale la colonna non cambia — la normale è perpendicolare
            // alla tangente — e la profondità vale esattamente lo spostamento.
            #expect(abs(back.depthMM - offset) < 0.05, "scostamento \(offset): \(back.depthMM)")
            #expect(abs(back.y - 150) < 0.05)
        }
    }

    @Test("Con lo scostamento in profondità, la superficie campionata ha ancora profondità nulla")
    func depthIsMeasuredFromTheSampledSurface() throws {
        // La profondità si conta dalla **superficie che si sta guardando**, non dalla curva: chi
        // sfoglia l'arcata a −3 mm vede quella superficie, e le misure che ci stanno sopra devono
        // risultare in piano, non tutte a tre millimetri di distanza.
        let layout = makeLayout(normalOffsetMM: -3)
        let point = try #require(
            layout.patientPoint(atPixelX: 260, y: 120, pixelWidth: width, pixelHeight: height))
        let back = try #require(
            layout.projection(ofPatient: point, pixelWidth: width, pixelHeight: height))
        #expect(abs(back.depthMM) < 0.01, "profondità \(back.depthMM) mm")
    }

    // MARK: Casi degeneri

    @Test("Senza curva utilizzabile non c'è punto da restituire")
    func unusableCurveHasNoPoint() {
        let layout = PanoramicLayout(curve: ArchCurve(controlPointsMM: [Vec3(0, 0, 0)]))
        #expect(layout.patientPoint(atPixelX: 10, y: 10, pixelWidth: 64, pixelHeight: 64) == nil)
        #expect(makeLayout().patientPoint(atPixelX: 0, y: 0, pixelWidth: 0, pixelHeight: 64) == nil)
        #expect(makeLayout().patientPoint(atPixelX: 0, y: 0, pixelWidth: 64, pixelHeight: 0) == nil)
    }
}
