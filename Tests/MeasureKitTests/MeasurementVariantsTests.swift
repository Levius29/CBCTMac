import DICOMCore
import Foundation
import Testing

@testable import MeasureKit

// Test delle varianti di misura.
//
// Due controlli qui sotto verificano che una misura si **rifiuti** di rispondere: l'area di un
// poligono sghembo e l'area di una spezzata aperta. Sono i più importanti del gruppo, perché il
// modo in cui questi calcoli sbagliano non è restituire un errore — è restituire un numero
// plausibile che finisce in una relazione.

@Suite("Varianti di misura")
struct MeasurementVariantsTests {

    // MARK: Spezzata

    @Test("La lunghezza di una spezzata nota, aperta e chiusa")
    func polylineLength() {
        let points = [Vec3(0, 0, 0), Vec3(3, 0, 0), Vec3(3, 4, 0)]
        let open = PolylineMeasurement(pointsMM: points, isClosed: false)
        #expect(abs(open.lengthMM - 7) < 1e-12)

        // Chiudendo il triangolo 3-4-5 si aggiunge l'ipotenusa.
        let closed = PolylineMeasurement(pointsMM: points, isClosed: true)
        #expect(abs(closed.lengthMM - 12) < 1e-12)
    }

    @Test("Meno di due punti non è una lunghezza")
    func degeneratePolyline() {
        #expect(PolylineMeasurement(pointsMM: []).lengthMM == 0)
        #expect(PolylineMeasurement(pointsMM: [Vec3(1, 2, 3)]).lengthMM == 0)
    }

    @Test("Un quadrato di 10 mm misura 100 mm², comunque sia orientato nello spazio")
    func squareAreaIsOrientationIndependent() throws {
        let flat = PolylineMeasurement(
            pointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(10, 10, 0), Vec3(0, 10, 0)],
            isClosed: true)
        let flatArea = try #require(flat.areaMM2)
        #expect(abs(flatArea - 100) < 1e-9)

        // Lo stesso quadrato ruotato di 37° attorno a x e 24° attorno a z. L'area è una proprietà
        // della figura, non della sua posa: se il calcolo passasse da una proiezione su un piano
        // coordinato, qui uscirebbe un numero più piccolo.
        let rotateX = try #require(Transform3D.rotation(axis: Vec3(1, 0, 0), angle: 0.6458))
        let rotateZ = try #require(Transform3D.rotation(axis: Vec3(0, 0, 1), angle: 0.4189))
        let oblique = PolylineMeasurement(
            pointsMM: flat.pointsMM.map { rotateZ.apply(toPoint: rotateX.apply(toPoint: $0)) },
            isClosed: true)
        let obliqueArea = try #require(oblique.areaMM2)
        #expect(abs(obliqueArea - 100) < 1e-9)
    }

    @Test("Quattro punti sghembi non hanno un'area")
    func skewPolygonHasNoArea() {
        // Gli stessi quattro vertici del quadrato, ma uno sollevato di due millimetri: non c'è
        // più un piano che li contenga, e la formula del laccio darebbe comunque un numero.
        let skew = PolylineMeasurement(
            pointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(10, 10, 2), Vec3(0, 10, 0)],
            isClosed: true)
        #expect(skew.areaMM2 == nil)
        // La lunghezza invece resta definita: il perimetro di una spezzata sghemba esiste.
        #expect(skew.lengthMM > 0)
    }

    @Test("Una spezzata aperta non ha area nemmeno se complanare")
    func openPolylineHasNoArea() {
        let open = PolylineMeasurement(
            pointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(10, 10, 0)],
            isClosed: false)
        #expect(open.areaMM2 == nil)
    }

    @Test("Tre punti allineati non hanno area")
    func collinearPointsHaveNoArea() {
        let line = PolylineMeasurement(
            pointsMM: [Vec3(0, 0, 0), Vec3(5, 0, 0), Vec3(10, 0, 0)],
            isClosed: true)
        #expect(line.areaMM2 == nil)
    }

    // MARK: Angolo fra due rette

    @Test("Trenta gradi restano trenta con tutti e quattro i versi dei segmenti")
    func acuteAngleIsIndependentOfDirection() {
        let angle = 30.0 * .pi / 180
        let a0 = Vec3(0, 0, 0), a1 = Vec3(10, 0, 0)
        let b0 = Vec3(0, 5, 0)
        let b1 = b0 + Vec3(Foundation.cos(angle), Foundation.sin(angle), 0) * 10

        // I quattro modi di tracciare gli stessi due segmenti. Senza il valore assoluto del
        // coseno, due di questi darebbero 150°, e l'utente penserebbe a un difetto.
        let combinations = [
            (a0, a1, b0, b1), (a1, a0, b0, b1), (a0, a1, b1, b0), (a1, a0, b1, b0),
        ]
        for combination in combinations {
            let measurement = LineAngleMeasurement(
                firstStartMM: combination.0, firstEndMM: combination.1,
                secondStartMM: combination.2, secondEndMM: combination.3)
            #expect(abs(measurement.acuteDegrees - 30) < 1e-9)
        }
    }

    @Test("Due rette parallele: angolo nullo e distanza pari alla separazione")
    func parallelLines() {
        let measurement = LineAngleMeasurement(
            firstStartMM: Vec3(0, 0, 0), firstEndMM: Vec3(10, 0, 0),
            secondStartMM: Vec3(-4, 7, 0), secondEndMM: Vec3(20, 7, 0))
        #expect(abs(measurement.acuteDegrees) < 1e-9)
        // Qui la formula chiusa per rette sghembe dividerebbe per zero.
        #expect(abs(measurement.minimumDistanceMM - 7) < 1e-9)
    }

    @Test("Due rette incidenti hanno distanza nulla")
    func intersectingLines() {
        let measurement = LineAngleMeasurement(
            firstStartMM: Vec3(-10, 0, 0), firstEndMM: Vec3(10, 0, 0),
            secondStartMM: Vec3(0, -10, 0), secondEndMM: Vec3(0, 10, 0))
        #expect(measurement.minimumDistanceMM < 1e-9)
        #expect(measurement.isIntersecting)
        #expect(abs(measurement.acuteDegrees - 90) < 1e-9)
    }

    @Test("Due rette sghembe con distanza nota per costruzione")
    func skewLines() {
        // Una lungo x sul piano z=0, l'altra lungo y sul piano z=6: non si incontrano mai, e la
        // loro distanza minima è esattamente la separazione fra i due piani.
        let measurement = LineAngleMeasurement(
            firstStartMM: Vec3(-10, 0, 0), firstEndMM: Vec3(10, 0, 0),
            secondStartMM: Vec3(3, -10, 6), secondEndMM: Vec3(3, 10, 6))
        #expect(abs(measurement.minimumDistanceMM - 6) < 1e-9)
        #expect(!measurement.isIntersecting)
        #expect(abs(measurement.acuteDegrees - 90) < 1e-9)
    }

    @Test("Un segmento degenere non manda in crisi la misura")
    func degenerateSegment() {
        let measurement = LineAngleMeasurement(
            firstStartMM: Vec3(1, 1, 1), firstEndMM: Vec3(1, 1, 1),
            secondStartMM: Vec3(0, 0, 0), secondEndMM: Vec3(10, 0, 0))
        #expect(measurement.acuteDegrees == 0)
        #expect(measurement.minimumDistanceMM.isFinite)
    }
}

// MARK: - Metadati scrivibili

@Suite("Metadati dell'annotazione")
struct AnnotationMetadataTests {

    private func every() -> [Annotation] {
        let m = AnnotationMetadata(label: "prima", colorHex: "#111111")
        return [
            .distance(DistanceMeasurement(metadata: m, startMM: .zero, endMM: Vec3(1, 0, 0))),
            .angle(
                AngleMeasurement(
                    metadata: m, vertexMM: .zero, firstArmMM: Vec3(1, 0, 0), secondArmMM: Vec3(0, 1, 0))),
            .ellipseROI(
                EllipseROI(
                    metadata: m, centerMM: .zero, semiAxisAMM: Vec3(2, 0, 0),
                    semiAxisBMM: Vec3(0, 2, 0), thicknessMM: 1)),
            .sphereROI(SphereROI(metadata: m, centerMM: .zero, radiusMM: 3)),
            .text(TextNote(metadata: m, anchorMM: .zero, text: "x")),
            .arrow(ArrowNote(metadata: m, tipMM: .zero, tailMM: Vec3(1, 0, 0), text: "x")),
        ]
    }

    @Test("Scrivere i metadati funziona su ogni caso dell'enumerazione")
    func metadataIsWritableForEveryCase() {
        // Il `set` ha nove rami scritti a mano: basta dimenticarne uno perché nascondere una
        // misura funzioni per otto tipi su nove, e il difetto si vedrebbe solo su quel tipo.
        for var annotation in every() {
            let id = annotation.id
            annotation.metadata.isHidden = true
            annotation.metadata.colorHex = "#FF0000"
            annotation.metadata.label = "dopo"

            #expect(annotation.metadata.isHidden)
            #expect(annotation.metadata.colorHex == "#FF0000")
            #expect(annotation.metadata.label == "dopo")
            // E il resto dell'annotazione non è stato toccato.
            #expect(annotation.id == id)
            #expect(!annotation.handlesMM.isEmpty)
        }
    }
}

// MARK: - Trasformazione rigida

@Suite("Trasformazione delle annotazioni")
struct AnnotationTransformTests {

    /// Rotazione di 90° attorno a z, con perno lontano dall'origine: la traslazione implicita è
    /// grande, quindi un punto trattato da vettore — o viceversa — sbaglia di molto e si vede.
    private func makeTransforms() -> (point: (Vec3) -> Vec3, vector: (Vec3) -> Vec3) {
        let pivot = Vec3(100, 50, 0)
        let rotation = Transform3D.rotation(axis: Vec3(0, 0, 1), angle: .pi / 2)!
        let point: (Vec3) -> Vec3 = { pivot + rotation.apply(toVector: $0 - pivot) }
        let vector: (Vec3) -> Vec3 = { rotation.apply(toVector: $0) }
        return (point, vector)
    }

    @Test("Una distanza ruota conservando la propria lunghezza")
    func distanceKeepsItsLength() {
        let (point, vector) = makeTransforms()
        var annotation = Annotation.distance(
            DistanceMeasurement(startMM: Vec3(0, 0, 0), endMM: Vec3(3, 4, 0)))
        annotation.transform(point: point, vector: vector)

        guard case .distance(let moved) = annotation else {
            Issue.record("il caso è cambiato")
            return
        }
        // Una trasformazione rigida non cambia le misure: è la proprietà per cui si può
        // raddrizzare un volume senza invalidare ciò che ci si è misurato sopra.
        #expect(abs(moved.lengthMM - 5) < 1e-9)
        #expect(!moved.startMM.isApproximatelyEqual(to: Vec3(0, 0, 0), tolerance: 1e-6))
    }

    @Test("I semiassi dell'ellisse sono vettori, non punti")
    func ellipseSemiAxesAreVectors() throws {
        let (point, vector) = makeTransforms()
        var annotation = Annotation.ellipseROI(
            EllipseROI(
                centerMM: Vec3(10, 10, 0),
                semiAxisAMM: Vec3(3, 0, 0),
                semiAxisBMM: Vec3(0, 2, 0),
                thicknessMM: 1))
        annotation.transform(point: point, vector: vector)

        guard case .ellipseROI(let moved) = annotation else {
            Issue.record("il caso è cambiato")
            return
        }
        // **Il controllo che conta.** Passando i semiassi per la trasformazione dei punti,
        // ciascuno prenderebbe anche la traslazione implicita del perno: un semiasse di tre
        // millimetri diventerebbe lungo più di cento, e l'ellisse coprirebbe mezza immagine.
        #expect(abs(moved.semiAxisAMM.length - 3) < 1e-9, "semiasse lungo \(moved.semiAxisAMM.length)")
        #expect(abs(moved.semiAxisBMM.length - 2) < 1e-9)
        // E sono ruotati davvero, non lasciati fermi.
        #expect(abs(moved.semiAxisAMM.y - 3) < 1e-9)
    }

    @Test("Il piano di riferimento si muove con l'annotazione")
    func referencePlaneFollows() throws {
        let (point, vector) = makeTransforms()
        var annotation = Annotation.distance(
            DistanceMeasurement(
                metadata: AnnotationMetadata(
                    referencePlane: AnnotationPlaneReference(
                        originMM: Vec3(0, 0, 5), normalMM: Vec3(0, 0, 1))),
                startMM: Vec3(0, 0, 5), endMM: Vec3(3, 0, 5)))
        annotation.transform(point: point, vector: vector)

        let reference = try #require(annotation.metadata.referencePlane)
        // La normale resta unitaria: se fosse passata per la trasformazione dei punti sarebbe
        // lunga più di cento, e la misura sparirebbe dalla vista in cui era stata tracciata.
        #expect(abs(reference.normalMM.length - 1) < 1e-9)
        #expect(reference.originMM.isApproximatelyEqual(to: point(Vec3(0, 0, 5)), tolerance: 1e-9))
    }

    @Test("Ogni caso dell'enumerazione si sposta davvero")
    func everyCaseMoves() {
        let (point, vector) = makeTransforms()
        let originals: [Annotation] = [
            .distance(DistanceMeasurement(startMM: .zero, endMM: Vec3(1, 0, 0))),
            .angle(
                AngleMeasurement(
                    vertexMM: .zero, firstArmMM: Vec3(1, 0, 0), secondArmMM: Vec3(0, 1, 0))),
            .ellipseROI(
                EllipseROI(
                    centerMM: Vec3(1, 1, 0), semiAxisAMM: Vec3(2, 0, 0),
                    semiAxisBMM: Vec3(0, 2, 0), thicknessMM: 1)),
            .sphereROI(SphereROI(centerMM: Vec3(2, 2, 2), radiusMM: 3)),
            .text(TextNote(anchorMM: Vec3(4, 4, 4), text: "x")),
            .arrow(ArrowNote(tipMM: .zero, tailMM: Vec3(1, 1, 0), text: "x")),
            .polyline(PolylineMeasurement(pointsMM: [.zero, Vec3(1, 0, 0), Vec3(1, 1, 0)])),
            .lineAngle(
                LineAngleMeasurement(
                    firstStartMM: .zero, firstEndMM: Vec3(1, 0, 0),
                    secondStartMM: Vec3(0, 1, 0), secondEndMM: Vec3(1, 1, 0))),
        ]

        // Undici rami scritti a mano: dimenticarne uno lascerebbe un tipo di annotazione fermo
        // nel vecchio riferimento dopo un raddrizzamento, e nulla lo direbbe.
        for original in originals {
            var moved = original
            moved.transform(point: point, vector: vector)
            #expect(moved.handlesMM.count == original.handlesMM.count)
            for (before, after) in zip(original.handlesMM, moved.handlesMM) {
                #expect(
                    !before.isApproximatelyEqual(to: after, tolerance: 1e-6),
                    "\(original.kindName) non si è mosso")
            }
        }
    }
}
