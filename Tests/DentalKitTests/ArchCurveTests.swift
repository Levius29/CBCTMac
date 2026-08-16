import DICOMCore
import Testing
import VolumeKit

@testable import DentalKit

// Test della curva dell'arcata e delle sezioni trasversali.
//
// Il test che conta davvero è l'equidistanza dei campioni. Se i punti fossero equidistanti nel
// parametro della spline invece che nella lunghezza d'arco, il panorex risulterebbe compresso
// nelle curve e dilatato nei tratti diritti — e l'immagine sarebbe perfettamente plausibile,
// solo con una scala orizzontale variabile. Una misura presa in orizzontale su quel panorex
// non significherebbe nulla, e nessuno se ne accorgerebbe guardando.

@Suite("ArchCurve")
struct ArchCurveTests {

    /// Semicerchio di raggio noto: nove punti di controllo, come una curva d'arcata reale.
    private func semicircle(radius: Double = 30) -> ArchCurve {
        var points: [Vec3] = []
        let count = 9
        for index in 0..<count {
            let angle = Double.pi * Double(index) / Double(count - 1)
            points.append(
                Vec3(-radius * Foundation.cos(angle), -radius * Foundation.sin(angle), 0))
        }
        return ArchCurve(controlPointsMM: points)
    }

    private func straightLine(length: Double = 40) -> ArchCurve {
        ArchCurve(controlPointsMM: [
            Vec3(0, 0, 0), Vec3(length / 3, 0, 0), Vec3(length * 2 / 3, 0, 0),
            Vec3(length, 0, 0),
        ])
    }

    // MARK: Lunghezza

    @Test("La lunghezza di una retta è la distanza fra gli estremi")
    func straightLength() {
        let curve = straightLine(length: 40)
        #expect(abs(curve.lengthMM - 40) < 0.01)
    }

    @Test("La lunghezza di un semicerchio si avvicina a πr")
    func semicircleLength() {
        // La Catmull-Rom attraverso punti su un cerchio non è un cerchio esatto, quindi non si
        // pretende πr al millesimo: uno scarto sotto l'uno percento conferma che il calcolo
        // della lunghezza d'arco è corretto e non, per esempio, la somma delle corde fra i soli
        // punti di controllo, che darebbe parecchio meno.
        let curve = semicircle(radius: 30)
        let expected = Double.pi * 30
        let error = abs(curve.lengthMM - expected) / expected
        #expect(error < 0.01, "lunghezza \(curve.lengthMM), attesa circa \(expected)")
    }

    // MARK: Equidistanza

    @Test("I campioni sono equidistanti anche dove la curvatura cambia")
    func samplesAreEquidistant() {
        let curve = semicircle(radius: 30)
        let samples = curve.resampled(count: 200)
        #expect(samples.count == 200)

        var minStep = Double.infinity
        var maxStep = 0.0
        for index in 1..<samples.count {
            let step = samples[index].positionMM.distance(to: samples[index - 1].positionMM)
            minStep = min(minStep, step)
            maxStep = max(maxStep, step)
        }

        // Le distanze fra punti consecutivi devono coincidere: qualche parte per mille di
        // scarto viene dall'approssimazione poligonale, non dal metodo.
        let spread = (maxStep - minStep) / maxStep
        #expect(spread < 0.02, "passo fra \(minStep) e \(maxStep) mm")
    }

    @Test("La distanza d'arco cresce in modo uniforme")
    func arcLengthIsUniform() {
        let curve = semicircle(radius: 30)
        let samples = curve.resampled(count: 50)
        let total = curve.lengthMM

        for (index, sample) in samples.enumerated() {
            let expected = total * Double(index) / Double(samples.count - 1)
            #expect(abs(sample.arcLengthMM - expected) < 1e-6)
        }
    }

    @Test("Il ricampionamento a passo fissato rispetta il passo richiesto")
    func resamplingBySpacing() {
        let curve = straightLine(length: 40)
        let samples = curve.resampled(spacingMM: 2.0)

        // Quaranta millimetri a passo di due: ventuno campioni, estremi inclusi.
        #expect(samples.count == 21)
        for index in 1..<samples.count {
            let step = samples[index].positionMM.distance(to: samples[index - 1].positionMM)
            #expect(abs(step - 2.0) < 0.02)
        }
    }

    // MARK: Passaggio per i punti di controllo

    @Test("La curva passa per i punti di controllo")
    func passesThroughControlPoints() {
        // È la proprietà per cui si usa Catmull-Rom invece di Bézier: l'utente clicca sulla
        // cresta e la curva ci passa sopra, senza il gioco dei punti di controllo.
        let curve = semicircle(radius: 30)
        let segments = curve.controlPointsMM.count - 1

        for (index, control) in curve.controlPointsMM.enumerated() {
            let t = Double(index) / Double(segments)
            guard let point = curve.point(atParameter: t) else {
                Issue.record("nessun punto al parametro \(t)")
                continue
            }
            #expect(point.isApproximatelyEqual(to: control, tolerance: 1e-9))
        }
    }

    // MARK: Riferimento locale

    @Test("Tangente e normale sono versori ortogonali")
    func localFrameIsOrthonormal() {
        let curve = semicircle(radius: 30)
        for sample in curve.resampled(count: 40) {
            #expect(abs(sample.tangent.length - 1) < 1e-9)
            #expect(abs(sample.normal.length - 1) < 1e-9)
            #expect(abs(sample.tangent.dot(sample.normal)) < 1e-9)
        }
    }

    @Test("La normale è orizzontale, cioè vestibolo-linguale")
    func normalIsHorizontal() {
        // La normale serve a tagliare le sezioni trasversali: se avesse una componente
        // verticale, le sezioni risulterebbero inclinate e l'altezza dell'osso misurata su di
        // esse sarebbe sistematicamente sbagliata.
        let curve = semicircle(radius: 30)
        for sample in curve.resampled(count: 40) {
            #expect(abs(sample.normal.dot(curve.upAxis)) < 1e-9)
        }
    }

    // MARK: Casi limite

    @Test("Una curva con meno di due punti non è utilizzabile")
    func rejectsTooFewPoints() {
        #expect(!ArchCurve(controlPointsMM: []).isUsable)
        #expect(!ArchCurve(controlPointsMM: [Vec3(0, 0, 0)]).isUsable)
        #expect(ArchCurve(controlPointsMM: [Vec3(0, 0, 0), Vec3(1, 0, 0)]).isUsable)
    }

    @Test("Non si può scendere sotto i due punti di controllo")
    func cannotRemoveBelowTwo() {
        var curve = ArchCurve(controlPointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0)])
        curve.removeControlPoint(at: 0)
        #expect(curve.controlPointsMM.count == 2, "la curva non deve poter sparire")
    }

    @Test("Il punto di controllo più vicino si trova entro la tolleranza")
    func findsNearestControlPoint() {
        let curve = straightLine(length: 40)
        #expect(curve.nearestControlPoint(to: Vec3(13.5, 1, 0), toleranceMM: 3) == 1)
        #expect(curve.nearestControlPoint(to: Vec3(20, 50, 0), toleranceMM: 3) == nil)
    }

    @Test("L'arcata predefinita è utilizzabile e sta dentro il volume")
    func defaultArchIsUsable() throws {
        let geometry = try VolumeGeometry(
            columnCount: 240, rowCount: 240, sliceCount: 240,
            columnSpacingMM: 0.25, rowSpacingMM: 0.25, sliceSpacingMM: 0.25,
            orientation: .standardAxial, originMM: Vec3(-30, -30, -30))

        let curve = ArchCurve.defaultArch(for: geometry)
        #expect(curve.isUsable)
        #expect(curve.lengthMM > 40)

        for point in curve.controlPointsMM {
            #expect(
                geometry.containsPatientPoint(point),
                "punto \(point) fuori dal volume")
        }
    }
}

// MARK: - Sezioni trasversali

@Suite("Sezioni trasversali")
struct CrossSectionTests {

    private func curve() -> ArchCurve {
        var points: [Vec3] = []
        for index in 0..<7 {
            let angle = Double.pi * Double(index) / 6.0
            points.append(Vec3(-25 * Foundation.cos(angle), -25 * Foundation.sin(angle), 0))
        }
        return ArchCurve(controlPointsMM: points)
    }

    @Test("Il piano di ogni sezione è perpendicolare alla curva")
    func planesArePerpendicular() {
        // È la definizione stessa di sezione trasversale: la normale del piano deve coincidere
        // con la tangente alla curva. Se non lo fosse, la sezione taglierebbe la cresta di
        // sbieco e lo spessore osseo misurato risulterebbe maggiore del reale.
        let layout = CrossSectionLayout(curve: curve(), intervalMM: 2.0)
        let sections = layout.sections()
        let samples = curve().resampled(spacingMM: 2.0)

        #expect(sections.count == samples.count)

        for (section, sample) in zip(sections, samples) {
            let planeNormal = section.plane.normalMM
            let alignment = abs(planeNormal.dot(sample.tangent))
            #expect(alignment > 0.999, "disallineamento: \(alignment)")
        }
    }

    @Test("L'asse orizzontale della sezione è vestibolo-linguale")
    func horizontalAxisIsBuccoLingual() {
        let layout = CrossSectionLayout(curve: curve(), intervalMM: 2.0)
        for section in layout.sections() {
            // Orizzontale: nessuna componente lungo l'asse verticale del paziente.
            #expect(abs(section.plane.rightMM.z) < 1e-9)
            // Verticale verso i piedi, come nelle viste coronale e sagittale.
            #expect(section.plane.downMM.isApproximatelyEqual(to: Vec3(0, 0, -1), tolerance: 1e-9))
        }
    }

    @Test("Le sezioni sono spaziate dell'intervallo richiesto")
    func sectionSpacing() {
        let layout = CrossSectionLayout(curve: curve(), intervalMM: 1.0)
        let sections = layout.sections()
        #expect(sections.count > 10)

        for index in 1..<sections.count {
            let delta = sections[index].arcLengthMM - sections[index - 1].arcLengthMM
            #expect(abs(delta - 1.0) < 0.05)
        }
    }

    @Test("Le sezioni sono numerate ed etichettate progressivamente")
    func sectionLabels() {
        let sections = CrossSectionLayout(curve: curve(), intervalMM: 5.0).sections()
        #expect(sections[0].index == 0)
        #expect(sections[0].label.hasPrefix("1 ·"))
        for (position, section) in sections.enumerated() {
            #expect(section.index == position)
        }
    }

    @Test("Si individua la sezione più vicina a una posizione d'arco")
    func findsNearestSection() {
        let layout = CrossSectionLayout(curve: curve(), intervalMM: 2.0)
        let sections = layout.sections()
        let target = sections[5].arcLengthMM + 0.3

        let found = layout.section(nearestToArcLength: target, in: sections)
        #expect(found?.index == 5)
    }
}

// MARK: - Panorex

@Suite("PanoramicLayout")
struct PanoramicLayoutTests {

    private func curve() -> ArchCurve {
        ArchCurve(controlPointsMM: [
            Vec3(-25, 5, 0), Vec3(-15, -12, 0), Vec3(0, -18, 0),
            Vec3(15, -12, 0), Vec3(25, 5, 0),
        ])
    }

    @Test("La larghezza naturale corrisponde alla lunghezza della curva")
    func naturalWidth() {
        let layout = PanoramicLayout(curve: curve(), millimetresPerPixel: 0.2)
        let expected = Int((curve().lengthMM / 0.2).rounded())
        #expect(layout.naturalPixelWidth == expected)
    }

    @Test("C'è esattamente un campione per colonna di pixel")
    func oneSamplePerColumn() {
        // Il kernel indicizza il buffer con la coordinata x del pixel: se i campioni fossero
        // meno delle colonne, le ultime leggerebbero fuori dal buffer.
        let layout = PanoramicLayout(curve: curve())
        #expect(layout.columnSamples(pixelWidth: 800).count == 800)
        #expect(layout.columnSamples(pixelWidth: 1).count == 2)
    }

    @Test("Il passo verticale punta verso i piedi")
    func downStepPointsInferior() {
        let layout = PanoramicLayout(curve: curve(), millimetresPerPixel: 0.25)
        let step = layout.downStepMM()
        #expect(step.z < 0)
        #expect(abs(step.length - 0.25) < 1e-12)
    }

    @Test("Il numero di campioni dello slab ha un tetto")
    func slabSampleCountIsCapped() throws {
        // Uno slab spesso su voxel finissimi chiederebbe centinaia di letture per pixel: con
        // due milioni di pixel diventa mezzo miliardo di campionamenti per fotogramma, e oltre
        // una certa densità non si guadagna nulla di visibile.
        let geometry = try VolumeGeometry(
            columnCount: 100, rowCount: 100, sliceCount: 100,
            columnSpacingMM: 0.05, rowSpacingMM: 0.05, sliceSpacingMM: 0.05,
            orientation: .standardAxial, originMM: .zero)

        let layout = PanoramicLayout(curve: curve(), slabThicknessMM: 30)
        #expect(layout.slabSampleCount(geometry: geometry) <= 96)
    }

    @Test("Senza spessore si campiona una sola fetta")
    func noSlabMeansSingleSample() throws {
        let geometry = try VolumeGeometry(
            columnCount: 50, rowCount: 50, sliceCount: 50,
            columnSpacingMM: 0.5, rowSpacingMM: 0.5, sliceSpacingMM: 0.5,
            orientation: .standardAxial, originMM: .zero)

        let layout = PanoramicLayout(curve: curve(), slabThicknessMM: 0)
        #expect(layout.slabSampleCount(geometry: geometry) == 1)
        let sample = layout.columnSamples(pixelWidth: 10)[0]
        #expect(layout.slabStep(for: sample, sampleCount: 1).length < 1e-12)
    }
}
