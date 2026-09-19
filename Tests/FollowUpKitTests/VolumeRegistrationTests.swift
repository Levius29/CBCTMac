import DICOMCore
import Foundation
import SegmentKit
import Testing

@testable import FollowUpKit

// La prova che conta, e che cosa prova davvero.
//
// Si prende il fantoccio, lo si sposta di una posa **nota**, e si chiede alla registrazione di
// ritrovarla. L'errore si misura dove interessa — sui punti dell'anatomia, in millimetri — e non
// sui sei parametri, che possono compensarsi a vicenda e dare numeri diversi per la stessa
// trasformazione.
//
// Resta una prova d'ingegneria, non uno studio di accuratezza: dice che l'aritmetica è quella
// giusta, non che su due CBCT vere di un paziente vero l'allineamento sia clinicamente adeguato.
// Quello lo dice solo chi guarda i reperi, ed è la ragione per cui il modulo non dichiara mai una
// registrazione «riuscita» ma «allineata, da verificare a occhio».

@Suite("Registrazione fra due esami")
struct VolumeRegistrationTests {

    /// Punti dove il fantoccio ha struttura: l'errore si misura lì, non nell'aria.
    private func landmarks(of volume: Volume) -> [Vec3] {
        let c = volume.geometry.centerMM
        return [
            c,
            c + Vec3(8, 0, 0), c - Vec3(8, 0, 0),
            c + Vec3(0, 8, 0), c - Vec3(0, 8, 0),
            c + Vec3(0, 0, 8), c - Vec3(0, 0, 8),
        ]
    }

    /// Lo scarto residuo: si compone la posa trovata con quella imposta e si guarda di quanto il
    /// punto non torna al suo posto.
    private func residualMM(found: RigidPose, truth: RigidPose, at points: [Vec3]) -> Double {
        points
            .map { truth.apply(toPoint: found.apply(toPoint: $0)).distance(to: $0) }
            .max() ?? 0
    }

    @Test("Ritrova una rototraslazione nota entro un millimetro sui reperi")
    func recoversKnownPose() throws {
        let reference = try makeRegistrationPhantom()
        let truth = RigidPose(
            rotationRadians: Vec3(0, 0, 3 * Double.pi / 180),
            translationMM: Vec3(2.0, -1.5, 1.0),
            centerMM: reference.geometry.centerMM
        )
        let followUp = try FollowUpResampler.aligned(
            reference, onto: reference.geometry, pose: truth
        ).volume

        let outcome = try VolumeRegistration.align(
            followUp: followUp,
            to: reference,
            settings: quickSettings(regionMM: centralBox(of: reference, halfSizeMM: 20))
        )

        #expect(residualMM(found: outcome.pose, truth: truth, at: landmarks(of: reference)) < 1.0)
        #expect(outcome.coverage > 0.9)
    }

    @Test("Una traslazione pura si ritrova anche con la correlazione")
    func recoversTranslationWithCorrelation() throws {
        let reference = try makeRegistrationPhantom()
        let truth = RigidPose(
            translationMM: Vec3(-2.5, 1.5, 0),
            centerMM: reference.geometry.centerMM
        )
        let followUp = try FollowUpResampler.aligned(
            reference, onto: reference.geometry, pose: truth
        ).volume

        let outcome = try VolumeRegistration.align(
            followUp: followUp,
            to: reference,
            settings: quickSettings(
                metric: .crossCorrelation,
                shrinkFactors: [4, 2],
                regionMM: centralBox(of: reference, halfSizeMM: 20)
            )
        )

        #expect(residualMM(found: outcome.pose, truth: truth, at: landmarks(of: reference)) < 1.0)
    }

    @Test("Un esame registrato su sé stesso non si muove")
    func selfRegistrationStaysPut() throws {
        let reference = try makeRegistrationPhantom()
        let outcome = try VolumeRegistration.align(
            followUp: reference,
            to: reference,
            settings: quickSettings(
                shrinkFactors: [4, 2],
                regionMM: centralBox(of: reference, halfSizeMM: 20)
            )
        )
        #expect(outcome.maximumDisplacementMM < 1.0)
        #expect(abs(outcome.coverage - 1.0) < 0.01)
        #expect(outcome.rotationDegrees < 1.0)
    }

    @Test("Due esecuzioni sugli stessi esami danno la stessa posa")
    func registrationIsReproducible() throws {
        let reference = try makeRegistrationPhantom()
        let truth = RigidPose(translationMM: Vec3(1.5, 0, 0), centerMM: reference.geometry.centerMM)
        let followUp = try FollowUpResampler.aligned(
            reference, onto: reference.geometry, pose: truth
        ).volume
        let settings = RegistrationSettings(
            shrinkFactors: [4],
            samplesPerLevel: 800,
            maximumIterationsPerLevel: 8,
            initialStepMM: 2.0,
            regionMM: centralBox(of: reference, halfSizeMM: 20)
        )

        let first = try VolumeRegistration.align(
            followUp: followUp, to: reference, settings: settings)
        let second = try VolumeRegistration.align(
            followUp: followUp, to: reference, settings: settings)
        #expect(first.pose == second.pose)
        #expect(first.metricValue == second.metricValue)
    }

    @Test("Un volume troppo piccolo è un errore dichiarato")
    func tinyVolumesThrow() throws {
        let small = try makeRampVolume(columns: 8, rows: 8, slices: 8)
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumeRegistration.align(followUp: small, to: small)
        }
    }

    @Test("Un volume tutto uguale non si registra, e lo dice")
    func constantVolumeThrows() throws {
        let geometry = try VolumeGeometry(
            columnCount: 16, rowCount: 16, sliceCount: 16,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: .zero
        )
        let flat = try Volume(
            geometry: geometry, samples: [Int16](repeating: 42, count: geometry.voxelCount))
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumeRegistration.align(followUp: flat, to: flat)
        }
    }

    @Test("Una regione che non tocca il volume è un errore, non un ciclo infinito")
    func regionOutsideTheVolumeThrows() throws {
        let reference = try makeRegistrationPhantom()
        let far = BoxMM(minMM: Vec3(900, 900, 900), maxMM: Vec3(1000, 1000, 1000))
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumeRegistration.align(
                followUp: reference,
                to: reference,
                settings: quickSettings(shrinkFactors: [4], regionMM: far)
            )
        }
    }

    @Test("Esami che non si sovrappongono non producono una posa qualunque")
    func disjointStudiesThrow() throws {
        let reference = try makeRegistrationPhantom()
        var geometry = reference.geometry
        geometry = try VolumeGeometry(
            columnCount: geometry.columnCount,
            rowCount: geometry.rowCount,
            sliceCount: geometry.sliceCount,
            columnSpacingMM: geometry.columnSpacingMM,
            rowSpacingMM: geometry.rowSpacingMM,
            sliceSpacingMM: geometry.sliceSpacingMM,
            orientation: geometry.orientation,
            originMM: geometry.originMM + Vec3(5_000, 0, 0)
        )
        let elsewhere = try Volume(
            geometry: geometry,
            samples: reference.samples,
            rescaleSlope: reference.rescaleSlope,
            rescaleIntercept: reference.rescaleIntercept,
            densityUnit: reference.densityUnit
        )
        #expect(throws: VolumeRegistrationError.self) {
            _ = try VolumeRegistration.align(
                followUp: elsewhere,
                to: reference,
                settings: quickSettings(shrinkFactors: [4])
            )
        }
    }

    @Test("La copertura descrive il campo acquisito, non l'accuratezza")
    func coverageDescribesTheAcquiredField() throws {
        let reference = try makeRampVolume(
            columns: 20, rows: 20, slices: 20, spacingMM: Vec3(1, 1, 1))
        let full = VolumeRegistration.coverage(
            of: reference, over: reference.geometry, pose: .identity)
        #expect(abs(full - 1.0) < 1e-9)

        let shifted = VolumeRegistration.coverage(
            of: reference,
            over: reference.geometry,
            pose: RigidPose(translationMM: Vec3(10, 0, 0))
        )
        #expect(shifted > 0.4 && shifted < 0.6)
    }
}
