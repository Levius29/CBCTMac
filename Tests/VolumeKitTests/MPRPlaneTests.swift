import DICOMCore
import Testing

@testable import VolumeKit

// Test della proiezione dei piani.
//
// `patientPoint(atPixelX:y:...)` è la funzione che trasforma un clic del mouse in un punto
// anatomico, e quindi in una misura. `pixelPosition(ofPatient:...)` è quella che rimette
// un'annotazione al posto giusto sullo schermo. Devono essere l'una l'inversa dell'altra in
// modo esatto: se divergono, le misure risultano corrette nei numeri e sbagliate nei punti —
// l'utente clicca su uno spigolo e misura da qualche altra parte.
//
// Questo file sta fuori dalla guardia Metal proprio per essere verificabile senza GPU.

@Suite("MPRPlane")
struct MPRPlaneTests {

    private func makeGeometry() throws -> VolumeGeometry {
        try VolumeGeometry(
            columnCount: 100, rowCount: 80, sliceCount: 60,
            columnSpacingMM: 0.3, rowSpacingMM: 0.4, sliceSpacingMM: 0.5,
            orientation: .standardAxial,
            originMM: Vec3(-15, -16, -15))
    }

    private func makePlane() -> MPRPlane {
        MPRPlane(
            plane: .axial,
            through: Vec3(2, -3, 5),
            widthMM: 60,
            heightMM: 40)
    }

    // MARK: Andata e ritorno

    @Test("Pixel → millimetri → pixel è l'identità")
    func pixelRoundTrip() {
        let plane = makePlane()
        let width = 800
        let height = 600

        for (x, y) in [(0.0, 0.0), (399.5, 299.5), (123.25, 456.75), (799.0, 599.0)] {
            let patient = plane.patientPoint(
                atPixelX: x, y: y, pixelWidth: width, pixelHeight: height)
            let back = plane.pixelPosition(
                ofPatient: patient, pixelWidth: width, pixelHeight: height)

            #expect(abs(back.x - x) < 1e-9, "x: atteso \(x), ottenuto \(back.x)")
            #expect(abs(back.y - y) < 1e-9, "y: atteso \(y), ottenuto \(back.y)")
            // Un punto ricavato dal piano giace sul piano: distanza nulla.
            #expect(abs(back.distanceMM) < 1e-9)
        }
    }

    @Test("Il centro del riquadro corrisponde al centro del piano")
    func centrePixelIsPlaneCentre() {
        let plane = makePlane()
        let width = 400
        let height = 300

        // Con un numero pari di pixel il centro cade fra due campioni: il punto medio è
        // (n−1)/2, non n/2. È lo stesso scarto di mezzo pixel dell'origine.
        let centre = plane.patientPoint(
            atPixelX: Double(width - 1) / 2, y: Double(height - 1) / 2,
            pixelWidth: width, pixelHeight: height)
        #expect(centre.isApproximatelyEqual(to: plane.centerMM, tolerance: 1e-9))
    }

    @Test("Un pixel corrisponde al passo atteso in millimetri")
    func pixelStep() {
        let plane = MPRPlane(
            plane: .axial, through: .zero, widthMM: 100, heightMM: 50)
        let step = plane.rightStepMM(pixelWidth: 200)
        #expect(abs(step.length - 0.5) < 1e-12)

        let downStep = plane.downStepMM(pixelHeight: 100)
        #expect(abs(downStep.length - 0.5) < 1e-12)
    }

    @Test("La distanza con segno cresce allontanandosi dal piano")
    func signedDistance() {
        let plane = makePlane()
        let normal = plane.normalMM
        let offPlane = plane.centerMM + normal * 3.5

        let projected = plane.pixelPosition(
            ofPatient: offPlane, pixelWidth: 400, pixelHeight: 300)
        #expect(abs(projected.distanceMM - 3.5) < 1e-9)
    }

    // MARK: Assi e convenzione

    @Test("Gli assi del piano assiale seguono la convenzione radiologica")
    func axialAxes() {
        let plane = MPRPlane(plane: .axial, through: .zero, widthMM: 10, heightMM: 10)
        #expect(plane.rightMM.isApproximatelyEqual(to: Vec3(1, 0, 0)))
        #expect(plane.downMM.isApproximatelyEqual(to: Vec3(0, 1, 0)))
        // Normale verso l'alto del paziente: scorrere in avanti sale.
        #expect(plane.normalMM.isApproximatelyEqual(to: Vec3(0, 0, 1)))
    }

    @Test("I tre piani canonici hanno normali fra loro ortogonali")
    func planesAreOrthogonal() {
        let axial = MPRPlane(plane: .axial, through: .zero, widthMM: 10, heightMM: 10)
        let coronal = MPRPlane(plane: .coronal, through: .zero, widthMM: 10, heightMM: 10)
        let sagittal = MPRPlane(plane: .sagittal, through: .zero, widthMM: 10, heightMM: 10)

        #expect(abs(axial.normalMM.dot(coronal.normalMM)) < 1e-12)
        #expect(abs(axial.normalMM.dot(sagittal.normalMM)) < 1e-12)
        #expect(abs(coronal.normalMM.dot(sagittal.normalMM)) < 1e-12)
    }

    // MARK: Navigazione

    @Test("L'avanzamento sposta il piano lungo la propria normale")
    func advancing() {
        let plane = makePlane()
        let moved = plane.advanced(byMM: 2.5)
        let delta = moved.centerMM - plane.centerMM
        #expect(abs(delta.length - 2.5) < 1e-12)
        #expect(delta.normalized!.isApproximatelyEqual(to: plane.normalMM, tolerance: 1e-9))
    }

    @Test("Lo zoom stringe la finestra senza spostare il centro")
    func zooming() {
        let plane = makePlane()
        let zoomed = plane.zoomed(by: 2.0)
        #expect(abs(zoomed.widthMM - plane.widthMM / 2) < 1e-12)
        #expect(abs(zoomed.heightMM - plane.heightMM / 2) < 1e-12)
        #expect(zoomed.centerMM.isApproximatelyEqual(to: plane.centerMM))
    }

    @Test("L'adattamento delle proporzioni allarga, non stringe")
    func aspectOnlyGrows() {
        // Ridimensionando la finestra l'anatomia inquadrata non deve uscire dal campo:
        // stringere la farebbe sparire ai bordi.
        let plane = MPRPlane(plane: .axial, through: .zero, widthMM: 40, heightMM: 40)

        let wide = plane.matchingAspect(pixelWidth: 800, pixelHeight: 400)
        #expect(wide.widthMM >= plane.widthMM - 1e-12)
        #expect(abs(wide.heightMM - plane.heightMM) < 1e-12)

        let tall = plane.matchingAspect(pixelWidth: 400, pixelHeight: 800)
        #expect(tall.heightMM >= plane.heightMM - 1e-12)
        #expect(abs(tall.widthMM - plane.widthMM) < 1e-12)
    }

    @Test("L'inquadratura iniziale contiene tutto il volume")
    func fittedContainsVolume() throws {
        let geometry = try makeGeometry()
        let plane = MPRPlane.fitted(plane: .axial, geometry: geometry)

        // Ogni vertice del volume deve cadere dentro la finestra visibile.
        for corner in geometry.boundingBoxCornersMM {
            let d = corner - plane.centerMM
            #expect(abs(d.dot(plane.rightMM)) <= plane.widthMM / 2 + 1e-9)
            #expect(abs(d.dot(plane.downMM)) <= plane.heightMM / 2 + 1e-9)
        }
    }

    // MARK: Slab

    @Test("Slice singola quando lo spessore è nullo")
    func singleSliceWhenNoSlab() throws {
        let geometry = try makeGeometry()
        var plane = makePlane()
        plane.slabThicknessMM = 0
        #expect(plane.slabSampleCount(geometry: geometry) == 1)
        #expect(plane.slabStepMM(geometry: geometry).length < 1e-12)
    }

    @Test("Lo slab campiona al passo del voxel più fine")
    func slabSampling() throws {
        let geometry = try makeGeometry()  // passo minimo 0,3 mm
        var plane = makePlane()
        plane.slabThicknessMM = 3.0

        let count = plane.slabSampleCount(geometry: geometry)
        #expect(count == 11)  // 3,0 / 0,3 + 1

        // I campioni coprono esattamente lo spessore richiesto.
        let step = plane.slabStepMM(geometry: geometry)
        #expect(abs(step.length * Double(count - 1) - 3.0) < 1e-9)
    }
}

// MARK: - Finestra e livello

@Suite("DensityWindow")
struct DensityWindowTests {

    @Test("Gli estremi derivano da ampiezza e livello")
    func bounds() {
        let wl = DensityWindow(width: 2400, level: 600)
        #expect(abs(wl.lowerBound - (-600)) < 1e-12)
        #expect(abs(wl.upperBound - 1800) < 1e-12)
    }

    @Test("Un'ampiezza nulla o negativa viene portata al minimo")
    func rejectsNonPositiveWidth() {
        // Una finestra di ampiezza zero produrrebbe una divisione per zero nello shader.
        #expect(DensityWindow(width: 0, level: 100).width >= 1)
        #expect(DensityWindow(width: -500, level: 100).width >= 1)
    }

    @Test("I preset dentali coprono i tessuti che servono")
    func presets() {
        #expect(DensityWindow.presets.count >= 5)
        // L'osso è il punto di partenza abituale su una CBCT dentale.
        #expect(DensityWindow.bone.width > 1000)
        // Le vie aeree guardano l'aria, quindi il livello sta molto in basso.
        #expect(DensityWindow.airway.level < 0)
    }

    @Test("La finestra automatica scarta le code")
    func automaticIgnoresTails() throws {
        // Sul fantoccio gli estremi sono aria a −1000 e smalto a 2800. Scartando lo 0,5% per
        // lato la finestra deve restare dentro quell'intervallo, non coincidervi: altrimenti
        // il tessuto utile finirebbe compresso in pochi livelli di grigio.
        let volume = try SyntheticVolume.makePhantom(
            columns: 60, rows: 60, slices: 60, spacingMM: Vec3(1, 1, 1))
        let wl = DensityWindow.automatic(from: volume)

        #expect(wl.width > 0)
        #expect(wl.lowerBound >= SyntheticVolume.air - 1)
        #expect(wl.upperBound <= SyntheticVolume.enamel + 1)
    }
}
