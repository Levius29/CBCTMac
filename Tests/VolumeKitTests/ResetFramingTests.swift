import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// «Rimetti a posto le viste» deve riempire il riquadro, non rimpicciolire e spostare.
//
// # Il difetto, con i suoi numeri
//
// `fitted` misura le distanze degli spigoli **dal centro del piano** e tiene la maggiore. Il
// centro però veniva dal mirino, e il mirino sta dove l'utente stava guardando: di lato. Da un
// centro spostato di quaranta millimetri su un volume largo cento, le due distanze sono dieci e
// novanta — vince novanta, e il campo esce centottantasette millimetri per un oggetto che ne
// misura cento. L'anatomia occupa poco più di metà larghezza e non è al centro.
//
// Le prove qui sotto sono scritte per **cadere** su quella versione: la prima è letteralmente
// quel caso, con quei numeri.

@Suite("Inquadratura del «rimetti a posto»")
struct ResetFramingTests {

    /// Cubo di cento millimetri di lato, centrato nell'origine Patient.
    private func makeGeometry() throws -> VolumeGeometry {
        try VolumeGeometry(
            columnCount: 200, rowCount: 200, sliceCount: 200,
            columnSpacingMM: 0.5, rowSpacingMM: 0.5, sliceSpacingMM: 0.5,
            orientation: .standardAxial,
            originMM: Vec3(-49.75, -49.75, -49.75))
    }

    @Test("Il campo vale l'ingombro del volume, non il doppio")
    func theFieldMatchesTheVolumeExtent() throws {
        let geometry = try makeGeometry()
        // Mirino quaranta millimetri a destra del centro: è dove si stava guardando.
        let offCentre = MPRPlane(
            plane: .axial, through: Vec3(40, 0, 12), widthMM: 30, heightMM: 30)

        // La vecchia strada: `fitted` da un centro spostato.
        let old = offCentre.fitted(to: geometry)
        #expect(old.widthMM > 170)

        // Quella nuova: prima si centra.
        let fixed = offCentre.centred(onVolume: geometry).fitted(to: geometry)
        // Cento millimetri più il quattro per cento di margine.
        #expect(abs(fixed.widthMM - 104) < 0.5)
        #expect(abs(fixed.heightMM - 104) < 0.5)
        // E meno della metà del campo di prima: è il «rimpicciolisce», al rovescio.
        #expect(fixed.widthMM < old.widthMM * 0.6)
    }

    @Test("Il volume sta simmetrico attorno al centro dell'inquadratura")
    func theVolumeSitsSymmetricallyInTheFrame() throws {
        let geometry = try makeGeometry()
        let fixed = MPRPlane(plane: .axial, through: Vec3(40, -25, 12), widthMM: 30, heightMM: 30)
            .centred(onVolume: geometry)

        var lowest = Double.infinity
        var highest = -Double.infinity
        var leftmost = Double.infinity
        var rightmost = -Double.infinity
        for corner in geometry.boundingBoxCornersMM {
            let relative = corner - fixed.centerMM
            let across = relative.dot(fixed.rightMM)
            let down = relative.dot(fixed.downMM)
            leftmost = min(leftmost, across)
            rightmost = max(rightmost, across)
            lowest = min(lowest, down)
            highest = max(highest, down)
        }
        // Simmetrico vuol dire che i due bordi distano uguale: è la condizione che rende
        // `fitted` esatto invece che generoso.
        #expect(abs(leftmost + rightmost) < 1e-9)
        #expect(abs(lowest + highest) < 1e-9)
    }

    @Test("La fetta che si sta guardando non si muove")
    func theSliceStaysWhereItWas() throws {
        let geometry = try makeGeometry()
        for depth in [-30.0, 0, 12.5, 44] {
            let plane = MPRPlane(
                plane: .axial, through: Vec3(40, -25, depth), widthMM: 30, heightMM: 30)
            let centred = plane.centred(onVolume: geometry)
            // La componente lungo la normale è quel che identifica la fetta.
            let before = plane.centerMM.dot(plane.normalMM)
            let after = centred.centerMM.dot(centred.normalMM)
            #expect(abs(before - after) < 1e-9)
        }
    }

    @Test("Un piano già centrato non si muove")
    func anAlreadyCentredPlaneDoesNotMove() throws {
        let geometry = try makeGeometry()
        let plane = MPRPlane(plane: .coronal, through: Vec3(0, 7, 0), widthMM: 104, heightMM: 104)
        let centred = plane.centred(onVolume: geometry)
        #expect(centred.centerMM.distance(to: plane.centerMM) < 1e-9)
        // E rifarlo due volte dà lo stesso: premere il pulsante due volte non deve cambiare
        // niente la seconda.
        let twice = centred.centred(onVolume: geometry)
        #expect(twice.centerMM.distance(to: centred.centerMM) < 1e-9)
    }

    @Test("Su un volume non cubico ogni lato prende il proprio ingombro")
    func eachAxisTakesItsOwnExtent() throws {
        // Campo di vista dentale: più largo che alto. Il vecchio `resetAllViews` faceva un
        // campo **quadrato** grande quanto la dimensione maggiore, cioè un terzo di riquadro
        // vuoto sopra e sotto sull'assiale.
        let geometry = try VolumeGeometry(
            columnCount: 200, rowCount: 200, sliceCount: 100,
            columnSpacingMM: 0.5, rowSpacingMM: 0.5, sliceSpacingMM: 0.5,
            orientation: .standardAxial,
            originMM: Vec3(-49.75, -49.75, -24.75))

        let coronal = MPRPlane(plane: .coronal, through: Vec3(30, 10, 8), widthMM: 5, heightMM: 5)
            .centred(onVolume: geometry)
            .fitted(to: geometry)
        // Larghezza cento, altezza cinquanta: due numeri diversi, non il maggiore due volte.
        #expect(abs(coronal.widthMM - 104) < 0.5)
        #expect(abs(coronal.heightMM - 52) < 0.5)
    }

    @Test("Con il piano ruotato ci si centra lungo la sua normale, non lungo un asse")
    func aRotatedPlaneIsCentredAlongItsOwnNormal() throws {
        let geometry = try makeGeometry()
        let rotated = MPRPlane(plane: .sagittal, through: Vec3(18, -22, 9), widthMM: 30, heightMM: 30)
            .rotated(aboutAxis: Vec3(0, 0, 1), byRadians: .pi / 5, aboutMM: Vec3(18, -22, 9))
        let centred = rotated.centred(onVolume: geometry)

        // La fetta resta la sua, e il centro cade sul volume dentro il piano.
        #expect(abs(rotated.centerMM.dot(rotated.normalMM)
            - centred.centerMM.dot(centred.normalMM)) < 1e-9)
        let relative = geometry.centerMM - centred.centerMM
        #expect(abs(relative.dot(centred.rightMM)) < 1e-9)
        #expect(abs(relative.dot(centred.downMM)) < 1e-9)
    }
}
