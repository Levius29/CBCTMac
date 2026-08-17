import DICOMCore
import Testing

@testable import VolumeKit

// Test della navigazione: zoom ancorato, rotazione nel piano, inquadratura di ritorno.
//
// Sono le tre operazioni con cui si manovra un'immagine, e sbagliarle non produce un errore
// visibile: produce un visore che «impazzisce». Lo zoom centrato sul riquadro allontana dal
// cursore ciò che si guarda; una rotazione che non ruota anche il centro fa scivolare via il
// perno; un'inquadratura di ritorno troppo stretta taglia l'anatomia. In tutti e tre i casi
// l'invariante è geometrica ed esatta, quindi si verifica con una tolleranza minuscola.

@Suite("Navigazione dell'inquadratura")
struct ViewNavigationTests {

    private func makeGeometry() throws -> VolumeGeometry {
        try VolumeGeometry(
            columnCount: 100, rowCount: 80, sliceCount: 60,
            columnSpacingMM: 0.3, rowSpacingMM: 0.4, sliceSpacingMM: 0.5,
            orientation: .standardAxial,
            originMM: Vec3(-15, -16, -15))
    }

    private func makePlane() -> MPRPlane {
        MPRPlane(plane: .axial, through: Vec3(2, -3, 5), widthMM: 60, heightMM: 40)
    }

    // MARK: Zoom ancorato

    @Test("Il punto sotto il puntatore non si muove")
    func anchoredZoomKeepsPointFixed() {
        let plane = makePlane()
        let width = 800
        let height = 600

        // Angoli, centro e punti sparsi: l'ancoraggio deve valere ovunque, non solo al centro,
        // dove qualunque implementazione dello zoom sarebbe corretta per caso.
        let probes: [(Double, Double)] = [
            (0, 0), (799, 599), (0, 599), (799, 0),
            (399.5, 299.5), (123.25, 456.75), (640, 120),
        ]

        for factor in [1.1, 2.0, 8.0, 0.5, 0.125] {
            for (x, y) in probes {
                let before = plane.patientPoint(
                    atPixelX: x, y: y, pixelWidth: width, pixelHeight: height)
                let zoomed = plane.zoomed(
                    by: factor, aboutPixelX: x, y: y, pixelWidth: width, pixelHeight: height)
                let after = zoomed.patientPoint(
                    atPixelX: x, y: y, pixelWidth: width, pixelHeight: height)

                #expect(
                    before.distance(to: after) < 1e-9,
                    "fattore \(factor) su (\(x),\(y)): scostamento \(before.distance(to: after)) mm")
            }
        }
    }

    @Test("La scala cambia esattamente del fattore richiesto")
    func anchoredZoomScalesExactly() {
        let plane = makePlane()
        let zoomed = plane.zoomed(
            by: 4, aboutPixelX: 100, y: 50, pixelWidth: 800, pixelHeight: 600)

        #expect(abs(zoomed.widthMM - plane.widthMM / 4) < 1e-12)
        #expect(abs(zoomed.heightMM - plane.heightMM / 4) < 1e-12)
        // Gli assi non devono ruotare: lo zoom è una scala, non una trasformazione affine
        // qualunque.
        #expect(zoomed.rightMM.isApproximatelyEqual(to: plane.rightMM))
        #expect(zoomed.downMM.isApproximatelyEqual(to: plane.downMM))
    }

    @Test("Zoom sul centro coincide con lo zoom non ancorato")
    func anchoredZoomAtCentreMatchesPlainZoom() {
        let plane = makePlane()
        // Il centro esatto di una finestra da 800×600 pixel sta fra i pixel 399 e 400.
        let anchored = plane.zoomed(
            by: 3, aboutPixelX: 399.5, y: 299.5, pixelWidth: 800, pixelHeight: 600)
        let plain = plane.zoomed(by: 3)

        #expect(anchored.centerMM.isApproximatelyEqual(to: plain.centerMM))
        #expect(abs(anchored.widthMM - plain.widthMM) < 1e-12)
    }

    @Test("Uno zoom e il suo inverso sullo stesso punto riportano al piano di partenza")
    func anchoredZoomIsInvertible() {
        let plane = makePlane()
        let zoomed = plane.zoomed(
            by: 2.5, aboutPixelX: 700, y: 40, pixelWidth: 800, pixelHeight: 600)
        let back = zoomed.zoomed(
            by: 1 / 2.5, aboutPixelX: 700, y: 40, pixelWidth: 800, pixelHeight: 600)

        #expect(back.centerMM.isApproximatelyEqual(to: plane.centerMM, tolerance: 1e-9))
        #expect(abs(back.widthMM - plane.widthMM) < 1e-9)
        #expect(abs(back.heightMM - plane.heightMM) < 1e-9)
    }

    @Test("Un fattore non positivo non altera il piano")
    func anchoredZoomRejectsNonPositiveFactor() {
        let plane = makePlane()
        for factor in [0.0, -1.0] {
            let result = plane.zoomed(
                by: factor, aboutPixelX: 10, y: 10, pixelWidth: 800, pixelHeight: 600)
            #expect(result == plane)
        }
    }

    // MARK: Rotazione nel piano

    @Test("La rotazione lascia fermo il perno")
    func rotationKeepsPivotFixed() {
        let plane = makePlane()
        let width = 800
        let height = 600
        let pivot = plane.patientPoint(
            atPixelX: 250, y: 180, pixelWidth: width, pixelHeight: height)

        for degrees in [5.0, 30.0, 90.0, -45.0, 180.0] {
            let rotated = plane.rotatedInPlane(
                byRadians: degrees * .pi / 180, aboutMM: pivot)
            let position = rotated.pixelPosition(
                ofPatient: pivot, pixelWidth: width, pixelHeight: height)

            // Il perno resta sullo stesso pixel: è ciò che rende la rotazione prevedibile.
            #expect(abs(position.x - 250) < 1e-8, "\(degrees)°: x = \(position.x)")
            #expect(abs(position.y - 180) < 1e-8, "\(degrees)°: y = \(position.y)")
            #expect(abs(position.distanceMM) < 1e-9)
        }
    }

    @Test("La rotazione nel piano non cambia la fetta inquadrata")
    func rotationPreservesNormal() {
        let plane = makePlane()
        let rotated = plane.rotatedInPlane(byRadians: 0.7, aboutMM: Vec3(10, 10, 5))

        // La normale è l'identità della fetta: se ruotasse, si starebbe guardando altro.
        #expect(rotated.normalMM.isApproximatelyEqual(to: plane.normalMM, tolerance: 1e-9))
        // Gli assi restano ortonormali, altrimenti l'immagine risulterebbe deformata.
        #expect(abs(rotated.rightMM.length - 1) < 1e-12)
        #expect(abs(rotated.downMM.length - 1) < 1e-12)
        #expect(abs(rotated.rightMM.dot(rotated.downMM)) < 1e-12)
    }

    @Test("Una rotazione di 90° scambia gli assi")
    func rotationByRightAngleSwapsAxes() {
        let plane = makePlane()
        let rotated = plane.rotatedInPlane(byRadians: .pi / 2, aboutMM: plane.centerMM)

        // Con la normale uscente, +90° porta `destra` su `giù`.
        #expect(rotated.rightMM.isApproximatelyEqual(to: plane.downMM, tolerance: 1e-9))
        #expect(rotated.downMM.isApproximatelyEqual(to: plane.rightMM * -1, tolerance: 1e-9))
    }

    @Test("Rotazioni successive si compongono")
    func rotationsCompose() {
        let plane = makePlane()
        let pivot = Vec3(3, -1, 5)
        let twice = plane
            .rotatedInPlane(byRadians: 0.3, aboutMM: pivot)
            .rotatedInPlane(byRadians: 0.4, aboutMM: pivot)
        let once = plane.rotatedInPlane(byRadians: 0.7, aboutMM: pivot)

        #expect(twice.rightMM.isApproximatelyEqual(to: once.rightMM, tolerance: 1e-9))
        #expect(twice.centerMM.isApproximatelyEqual(to: once.centerMM, tolerance: 1e-9))
    }

    // MARK: Inquadratura di ritorno

    @Test("L'inquadratura di ritorno contiene tutto il volume")
    func fittedContainsWholeVolume() throws {
        let geometry = try makeGeometry()
        // Si parte da un'inquadratura assurda: molto ingrandita e fuori centro, come dopo
        // essersi persi.
        var plane = MPRPlane(plane: .axial, through: geometry.centerMM, widthMM: 3, heightMM: 2)
        plane.centerMM = plane.centerMM + Vec3(40, -30, 0)

        let fitted = plane.fitted(to: geometry)

        for corner in geometry.boundingBoxCornersMM {
            let relative = corner - fitted.centerMM
            #expect(abs(relative.dot(fitted.rightMM)) <= fitted.widthMM / 2 + 1e-9)
            #expect(abs(relative.dot(fitted.downMM)) <= fitted.heightMM / 2 + 1e-9)
        }
    }

    @Test("L'inquadratura di ritorno non ruota né cambia fetta")
    func fittedPreservesOrientation() throws {
        let geometry = try makeGeometry()
        let plane = makePlane().rotatedInPlane(byRadians: 0.5, aboutMM: Vec3(0, 0, 5))
        let fitted = plane.fitted(to: geometry)

        #expect(fitted.rightMM.isApproximatelyEqual(to: plane.rightMM))
        #expect(fitted.downMM.isApproximatelyEqual(to: plane.downMM))
        // Il centro non si muove: cambia solo quanto si vede, non dove si guarda. Così tornare
        // all'inquadratura piena non fa perdere il punto in cui si stava lavorando.
        #expect(fitted.centerMM.isApproximatelyEqual(to: plane.centerMM))
    }

    @Test("Il margine dell'inquadratura di ritorno è rispettato")
    func fittedAppliesMargin() throws {
        let geometry = try makeGeometry()
        let plane = MPRPlane(plane: .axial, through: geometry.centerMM, widthMM: 5, heightMM: 5)

        let tight = plane.fitted(to: geometry, marginFraction: 0)
        let loose = plane.fitted(to: geometry, marginFraction: 0.2)

        #expect(abs(loose.widthMM - tight.widthMM * 1.2) < 1e-9)
        // Il volume è 100×0,3 = 30 mm in colonna e 80×0,4 = 32 mm in riga; il piano assiale
        // guarda quelle due, quindi l'inquadratura senza margine deve valere proprio quelle.
        #expect(abs(tight.widthMM - 30) < 1e-6, "larghezza \(tight.widthMM) mm")
        #expect(abs(tight.heightMM - 32) < 1e-6, "altezza \(tight.heightMM) mm")
    }
}
