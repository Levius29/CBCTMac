import ArtifactKit
import DICOMCore
import Foundation
import Testing

@Suite("Pipeline di riduzione degli artefatti")
struct ArtifactReductionTests {
    @Test("Senza metallo restituisce volume identico e provenienza vuota")
    func noMetalReturnsUnmodifiedResult() throws {
        let samples = [Int16](repeating: 500, count: 9 * 9)
        let volume = try makeArtifactVolume(columns: 9, rows: 9, slices: 1, samples: samples)
        var settings = ArtifactReductionSettings()
        settings.minimumMetalVolumeMM3 = 0
        settings.dilationMM = 0

        let result = try ArtifactReduction.reduceMetalArtifacts(in: volume, settings: settings)

        #expect(result.volume.samples == volume.samples)
        #expect(result.volume.geometry == volume.geometry)
        #expect(!result.provenance.isModified)
        #expect(result.modifiedMask.voxelCounts().isEmpty)
    }

    @Test("Una soglia che classifica oltre il cinque per cento viene rifiutata")
    func excessiveMetalMaskThrows() throws {
        let samples = [Int16](repeating: 1000, count: 10 * 10)
        let volume = try makeArtifactVolume(columns: 10, rows: 10, slices: 1, samples: samples)
        var settings = ArtifactReductionSettings()
        settings.thresholdGV = 900
        settings.minimumMetalVolumeMM3 = 0
        settings.dilationMM = 0

        var caught: ArtifactReductionError?
        do {
            _ = try ArtifactReduction.reduceMetalArtifacts(in: volume, settings: settings)
        } catch let error as ArtifactReductionError {
            caught = error
        } catch {
        }

        #expect(caught == .metalTooExtensive(fraction: 1))
    }

    @Test("La pipeline rileva il metallo e conserva geometria e rescale")
    func pipelineProducesCorrectedVolume() throws {
        let columns = 61
        let rows = 61
        let centre = 30
        var samples = [Int16]()
        samples.reserveCapacity(columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let angle = atan2(Double(j - centre), Double(i - centre))
                let value = 1000.0 + 180.0 * cos(24.0 * angle)
                samples.append(Int16(clamping: Int(value.rounded())))
            }
        }
        samples[centre * columns + centre] = 5000
        let volume = try makeArtifactVolume(
            columns: columns,
            rows: rows,
            slices: 1,
            samples: samples,
            slope: 1.5,
            intercept: -100,
            densityUnit: .declaredHounsfield
        )
        var settings = ArtifactReductionSettings()
        settings.thresholdGV = 7000
        settings.minimumMetalVolumeMM3 = 0
        settings.dilationMM = 0
        settings.streak.radiusMM = 25
        settings.streak.angularWindowDegrees = 15

        let result = try ArtifactReduction.reduceMetalArtifacts(in: volume, settings: settings)

        #expect(result.provenance.isModified)
        #expect(!result.modifiedMask.voxelCounts().isEmpty)
        #expect(result.volume.geometry == volume.geometry)
        #expect(result.volume.rescaleSlope == 1.5)
        #expect(result.volume.rescaleIntercept == -100)
        #expect(result.volume.densityUnit == .declaredHounsfield)
        #expect(result.volume.samples[centre * columns + centre] == 5000)
    }

    @Test("I parametri non finiti producono un errore nominato")
    func invalidSettingsThrowNamedError() throws {
        let volume = try makeArtifactVolume(columns: 1, rows: 1, slices: 1, samples: [0])
        var settings = ArtifactReductionSettings()
        settings.dilationMM = .nan

        var caught: ArtifactReductionError?
        do {
            _ = try ArtifactReduction.reduceMetalArtifacts(in: volume, settings: settings)
        } catch let error as ArtifactReductionError {
            caught = error
        } catch {
        }

        guard let caught else {
            Issue.record("Era atteso invalidParameters.")
            return
        }
        guard case .invalidParameters = caught else {
            Issue.record("Era atteso invalidParameters.")
            return
        }
    }
}
