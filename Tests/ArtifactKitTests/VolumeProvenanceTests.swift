import ArtifactKit
import DICOMCore
import Foundation
import SegmentKit
import Testing

@Suite("Provenienza del volume corretto")
struct VolumeProvenanceTests {
    @Test("Il riepilogo distingue il volume originale dai passaggi applicati")
    func summaryDescribesProcessingSteps() {
        let original = VolumeProvenance(steps: [])
        let processed = VolumeProvenance(steps: [
            ProcessingStep(
                name: "Soppressione strie da metallo",
                parametersDescription: "raggio 40 mm",
                affectedVoxelCount: 12,
                date: Date(timeIntervalSince1970: 0)
            )
        ])

        #expect(!original.isModified)
        #expect(original.summary == "Volume originale non modificato.")
        #expect(processed.isModified)
        #expect(processed.summary.contains("Soppressione strie da metallo"))
        #expect(processed.summary.contains("12 voxel"))
    }

    @Test("Le query Patient interrogano soltanto i voxel realmente alterati")
    func patientQueriesUseModifiedMask() throws {
        let volume = try makeArtifactVolume(
            columns: 3,
            rows: 2,
            slices: 1,
            samples: [0, 0, 0, 0, 0, 0]
        )
        var mask = try #require(VolumeMask(geometry: volume.geometry))
        mask.setLabel(1, i: 1, j: 0, k: 0)
        mask.setLabel(1, i: 2, j: 1, k: 0)
        let result = ProcessedVolume(
            volume: volume,
            provenance: VolumeProvenance(steps: []),
            modifiedMask: mask
        )

        #expect(result.isModified(atPatient: Vec3(1, 0, 0)))
        #expect(!result.isModified(atPatient: Vec3(0, 0, 0)))
        #expect(!result.isModified(atPatient: Vec3(Double.nan, 0, 0)))
        let box = BoxMM(minMM: Vec3(0, 0, 0), maxMM: Vec3(1, 1, 0))
        #expect(result.modifiedFraction(inBoxMM: box) == 0.25)
        let outside = BoxMM(minMM: Vec3(20, 20, 20), maxMM: Vec3(21, 21, 21))
        #expect(result.modifiedFraction(inBoxMM: outside) == 0)
    }
}
