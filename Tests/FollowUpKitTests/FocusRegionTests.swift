import DICOMCore
import Foundation
import Testing

@testable import FollowUpKit

// Le regole della regione seguita non sono comodità: ognuna corregge un modo di credere di
// guardare lo stesso punto mentre se ne guarda un altro. Queste prove le tengono ferme.

@Suite("Regione seguita nel tempo")
struct FocusRegionTests {

    private func makeRegion() -> FocusRegion {
        FocusRegion(name: "Sito 4.6", centerMM: Vec3(10, 20, 30), radiusMM: 6)
    }

    @Test("Spostare il centro azzera le verifiche")
    func movingCentreClearsChecks() {
        var region = makeRegion()
        let study = UUID()
        region.markChecked(studyID: study)
        #expect(region.isChecked(studyID: study))

        region.move(toMM: Vec3(11, 20, 30))
        #expect(!region.isChecked(studyID: study))
    }

    @Test("Cambiare il raggio azzera le verifiche")
    func changingRadiusClearsChecks() {
        var region = makeRegion()
        let study = UUID()
        region.markChecked(studyID: study)

        region.setRadiusMM(9)
        #expect(!region.isChecked(studyID: study))
        #expect(region.radiusMM == 9)
    }

    @Test("Riposare il centro dov'era non azzera niente")
    func movingNowhereKeepsChecks() {
        var region = makeRegion()
        let study = UUID()
        region.markChecked(studyID: study)

        region.move(toMM: region.centerMM)
        #expect(region.isChecked(studyID: study))
    }

    @Test("Rinominare conserva le verifiche")
    func renamingKeepsChecks() {
        var region = makeRegion()
        let study = UUID()
        region.markChecked(studyID: study)

        region.name = "Sito 4.6 — controllo"
        #expect(region.isChecked(studyID: study))
    }

    @Test("Il raggio non scende sotto il minimo")
    func radiusHasAFloor() {
        var region = makeRegion()
        region.setRadiusMM(0.01)
        #expect(region.radiusMM == FocusRegion.minimumRadiusMM)

        let born = FocusRegion(name: "x", centerMM: .zero, radiusMM: -3)
        #expect(born.radiusMM == FocusRegion.minimumRadiusMM)
    }

    @Test("Ogni data ha la sua correzione, e non tocca le altre")
    func correctionsAreIndependentPerStudy() {
        var region = makeRegion()
        let first = UUID()
        let second = UUID()
        region.markChecked(studyID: second)

        region.correct(studyID: first, offsetMM: Vec3(0.4, 0, -0.2))
        #expect(region.correctionMM(forStudy: first) == Vec3(0.4, 0, -0.2))
        #expect(region.correctionMM(forStudy: second) == nil)
        // La correzione di una data non può dichiarare verificata sé stessa, ma non tocca le altre.
        #expect(!region.isChecked(studyID: first))
        #expect(region.isChecked(studyID: second))

        region.correct(studyID: first, offsetMM: Vec3(0.5, 0, 0))
        #expect(region.correctionMM(forStudy: first) == Vec3(0.5, 0, 0))
        #expect(region.corrections.count == 1)

        region.clearCorrection(studyID: first)
        #expect(region.correctionMM(forStudy: first) == nil)
    }

    @Test("La correzione si somma alla posa, non la sostituisce")
    func correctionRidesOnTopOfThePose() throws {
        var region = makeRegion()
        let study = UUID()
        let pose = RigidPose(translationMM: Vec3(1, 0, 0))
        let geometry = try VolumeGeometry(
            columnCount: 60, rowCount: 60, sliceCount: 60,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero
        )

        let before = region.placement(in: geometry, pose: pose, studyID: study)
        #expect(before.centerMM.isApproximatelyEqual(to: Vec3(11, 20, 30), tolerance: 1e-9))

        region.correct(studyID: study, offsetMM: Vec3(0, 0.5, 0))
        let after = region.placement(in: geometry, pose: pose, studyID: study)
        #expect(after.centerMM.isApproximatelyEqual(to: Vec3(11, 20.5, 30), tolerance: 1e-9))
        // Il centro di partenza non si è mosso: la correzione vale per quella data soltanto.
        #expect(region.centerMM == Vec3(10, 20, 30))
    }

    @Test("Il fuori campo si decide sulla geometria originale")
    func outOfFieldIsDecidedOnTheOriginalGeometry() throws {
        let geometry = try VolumeGeometry(
            columnCount: 40, rowCount: 40, sliceCount: 40,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero
        )
        let study = UUID()

        let inside = FocusRegion(name: "dentro", centerMM: Vec3(20, 20, 20), radiusMM: 5)
        #expect(inside.placement(in: geometry, pose: .identity, studyID: study).status == .inside)

        let onTheEdge = FocusRegion(name: "al bordo", centerMM: Vec3(1, 20, 20), radiusMM: 5)
        #expect(
            onTheEdge.placement(in: geometry, pose: .identity, studyID: study).status == .clipped)

        let outside = FocusRegion(name: "fuori", centerMM: Vec3(120, 20, 20), radiusMM: 5)
        let placement = outside.placement(in: geometry, pose: .identity, studyID: study)
        #expect(placement.status == .outside)
        #expect(!placement.status.isDisplayable)
    }

    @Test("La regione fa andata e ritorno in JSON, correzioni comprese")
    func regionSurvivesJSON() throws {
        var region = makeRegion()
        let study = UUID()
        region.correct(studyID: study, offsetMM: Vec3(0.2, -0.1, 0))
        region.markChecked(studyID: study)

        let data = try JSONEncoder().encode(region)
        let restored = try JSONDecoder().decode(FocusRegion.self, from: data)
        #expect(restored == region)
        #expect(restored.correctionMM(forStudy: study) == Vec3(0.2, -0.1, 0))
        #expect(restored.isChecked(studyID: study))
    }
}
