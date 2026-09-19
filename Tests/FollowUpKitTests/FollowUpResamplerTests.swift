import DICOMCore
import Foundation
import Testing

@testable import FollowUpKit

// Il ricampionamento è il punto in cui un errore di direzione della posa diventa invisibile: si
// ottiene comunque un volume, e sembra un esame. Queste prove chiedono le due cose che lo
// smaschererebbero — la griglia è quella del riferimento, e il contenuto si è spostato del verso
// giusto.

@Suite("Ricampionamento dell'esame di confronto")
struct FollowUpResamplerTests {

    @Test("Con la posa neutra il volume si ritrova identico sulla propria griglia")
    func identityPoseKeepsSamples() throws {
        let volume = try makeRampVolume()
        let aligned = try FollowUpResampler.aligned(
            volume, onto: volume.geometry, pose: .identity)
        #expect(aligned.volume.geometry == volume.geometry)
        #expect(aligned.volume.samples == volume.samples)
        #expect(abs(aligned.coverage - 1.0) < 1e-12)
    }

    @Test("La griglia resta quella del riferimento, non quella del confronto")
    func gridComesFromReference() throws {
        let reference = try makeRampVolume(columns: 10, rows: 10, slices: 10)
        let followUp = try makeRampVolume(
            columns: 6, rows: 6, slices: 6, spacingMM: Vec3(1, 1, 1), originMM: Vec3(11, 21, 31))
        let aligned = try FollowUpResampler.aligned(
            followUp, onto: reference.geometry, pose: .identity)
        #expect(aligned.volume.geometry == reference.geometry)
        #expect(aligned.volume.samples.count == reference.geometry.voxelCount)
    }

    @Test("Il rescale e l'unità restano quelli dell'esame di confronto")
    func rescaleComesFromFollowUp() throws {
        let reference = try makeRampVolume()
        let followUp = try SyntheticVolume.makePhantom(
            columns: 12, rows: 12, slices: 12, spacingMM: Vec3(1, 1, 1))
        let aligned = try FollowUpResampler.aligned(
            followUp, onto: reference.geometry, pose: .identity)
        #expect(aligned.volume.rescaleIntercept == followUp.rescaleIntercept)
        #expect(aligned.volume.rescaleSlope == followUp.rescaleSlope)
        #expect(aligned.volume.densityUnit == followUp.densityUnit)
    }

    @Test("Una traslazione nota sposta il contenuto di esattamente quei millimetri")
    func translationMovesContentByTheStatedAmount() throws {
        let volume = try makeRampVolume(
            columns: 12, rows: 12, slices: 12, spacingMM: Vec3(1, 1, 1))
        let pose = RigidPose(translationMM: Vec3(2, 0, 0))
        let aligned = try FollowUpResampler.aligned(
            volume, onto: volume.geometry, pose: pose)

        // La posa porta il punto del riferimento nello spazio del confronto: sul voxel (3,4,5)
        // della griglia si legge quindi ciò che l'originale aveva due millimetri più in là.
        let expected = try #require(volume.rawValue(i: 5, j: 4, k: 5))
        let actual = try #require(aligned.volume.rawValue(i: 3, j: 4, k: 5))
        #expect(actual == expected)
    }

    @Test("Fuori dal campo si scrive il minimo, e la copertura lo dichiara")
    func outsideTheFieldIsDeclared() throws {
        let volume = try makeRampVolume(
            columns: 12, rows: 12, slices: 12, spacingMM: Vec3(1, 1, 1))
        // Mezzo volume di traslazione: metà della griglia resta senza dato.
        let pose = RigidPose(translationMM: Vec3(6, 0, 0))
        let aligned = try FollowUpResampler.aligned(
            volume, onto: volume.geometry, pose: pose)

        #expect(aligned.coverage > 0.4 && aligned.coverage < 0.6)
        #expect(aligned.missingRawValue == volume.rawValueRange.lowerBound)
        let empty = try #require(aligned.volume.rawValue(i: 11, j: 0, k: 0))
        #expect(empty == aligned.missingRawValue)
    }

    @Test("Due esami che non si toccano danno copertura nulla")
    func disjointVolumesHaveNoCoverage() throws {
        let volume = try makeRampVolume(
            columns: 12, rows: 12, slices: 12, spacingMM: Vec3(1, 1, 1))
        let pose = RigidPose(translationMM: Vec3(500, 0, 0))
        let aligned = try FollowUpResampler.aligned(
            volume, onto: volume.geometry, pose: pose)
        #expect(aligned.coverage == 0)
    }
}
