import DICOMCore
import Foundation
import Testing

@testable import FollowUpKit

// La posa è sei numeri, e sbagliarne la lettura non dà errori: dà un confronto fra due punti
// diversi. Queste prove fissano la convenzione — riferimento → confronto, rotazione attorno al
// centro — in modo che cambiarla rompa qualcosa di visibile invece di spostare in silenzio ogni
// misura del modulo.

@Suite("Posa rigida")
struct RigidPoseTests {

    @Test("La posa neutra non sposta niente")
    func identityMovesNothing() {
        let point = Vec3(12, -4, 7)
        #expect(RigidPose.identity.apply(toPoint: point).isApproximatelyEqual(to: point))
    }

    @Test("Il centro di rotazione resta fermo")
    func rotationCenterStaysPut() {
        let center = Vec3(30, -10, 5)
        let pose = RigidPose(
            rotationRadians: Vec3(0.2, -0.1, 0.35),
            translationMM: .zero,
            centerMM: center
        )
        #expect(pose.apply(toPoint: center).isApproximatelyEqual(to: center, tolerance: 1e-9))
    }

    @Test("La traslazione sposta il centro esattamente di quanto dichiara")
    func translationMovesCenter() {
        let center = Vec3(1, 2, 3)
        let pose = RigidPose(
            rotationRadians: Vec3(0.3, 0.1, -0.2),
            translationMM: Vec3(4, -5, 6),
            centerMM: center
        )
        #expect(
            pose.apply(toPoint: center).isApproximatelyEqual(to: Vec3(5, -3, 9), tolerance: 1e-9))
        #expect(abs(pose.displacementMM(atPoint: center) - Vec3(4, -5, 6).length) < 1e-9)
    }

    @Test("La rotazione conserva le distanze")
    func rotationKeepsDistances() {
        let pose = RigidPose(
            rotationRadians: Vec3(0.4, -0.25, 0.7),
            translationMM: Vec3(3, 3, -2),
            centerMM: Vec3(5, 5, 5)
        )
        let a = Vec3(0, 0, 0)
        let b = Vec3(10, -3, 4)
        let moved = pose.apply(toPoint: a).distance(to: pose.apply(toPoint: b))
        #expect(abs(moved - a.distance(to: b)) < 1e-9)
    }

    @Test("L'inversa riporta il punto esattamente dov'era")
    func inverseReturnsPoint() throws {
        let pose = RigidPose(
            rotationRadians: Vec3(-0.15, 0.4, 0.05),
            translationMM: Vec3(2, -7, 1),
            centerMM: Vec3(9, 9, 9)
        )
        let inverse = try #require(pose.inverseTransform)
        let point = Vec3(3, 14, -8)
        let back = inverse.apply(toPoint: pose.apply(toPoint: point))
        #expect(back.isApproximatelyEqual(to: point, tolerance: 1e-9))
    }

    @Test("Le tre rotazioni si compongono nell'ordine x, y, z")
    func rotationOrderIsFixed() {
        // Novanta gradi attorno a z soltanto: l'asse x finisce su y. Se l'ordine o il segno
        // cambiano, questo punto finisce altrove, ed è meglio che lo dica una prova.
        let pose = RigidPose(rotationRadians: Vec3(0, 0, Double.pi / 2))
        let moved = pose.apply(toPoint: Vec3(1, 0, 0))
        #expect(moved.isApproximatelyEqual(to: Vec3(0, 1, 0), tolerance: 1e-9))
    }

    @Test("La posa fa andata e ritorno in JSON")
    func poseSurvivesJSON() throws {
        let pose = RigidPose(
            rotationRadians: Vec3(0.01, -0.02, 0.03),
            translationMM: Vec3(1.5, -2.5, 0.25),
            centerMM: Vec3(40, 40, 40)
        )
        let data = try JSONEncoder().encode(pose)
        let restored = try JSONDecoder().decode(RigidPose.self, from: data)
        #expect(restored == pose)
    }
}
