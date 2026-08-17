import ArtifactKit
import DICOMCore
import Foundation
import SegmentKit
import Testing

@Suite("Soppressione polare delle strie")
struct PolarStreakSuppressionTests {
    @Test("Una fetta senza metallo resta identica campione per campione")
    func sliceWithoutMetalIsByteIdentical() throws {
        let fixture = try makeStreakPhantom(slices: 2)
        let result = try PolarStreakSuppression.apply(
            to: fixture.volume,
            metalMask: fixture.metalMask,
            parameters: fixture.parameters
        )
        let planeSize = fixture.volume.geometry.columnCount * fixture.volume.geometry.rowCount

        #expect(Array(result.volume.samples[planeSize..<(2 * planeSize)])
            == Array(fixture.volume.samples[planeSize..<(2 * planeSize)]))
    }

    @Test("Le strie calano almeno del sessanta per cento senza spianare l'anatomia")
    func reducesStreaksAndPreservesRadialAnatomy() throws {
        let fixture = try makeStreakPhantom(slices: 1)
        let result = try PolarStreakSuppression.apply(
            to: fixture.volume,
            metalMask: fixture.metalMask,
            parameters: fixture.parameters
        )
        let originalOuter = ringValues(
            volume: fixture.volume, centre: fixture.centre, radius: 25, sampleCount: 144
        )
        let correctedOuter = ringValues(
            volume: result.volume, centre: fixture.centre, radius: 25, sampleCount: 144
        )
        let correctedInner = ringValues(
            volume: result.volume, centre: fixture.centre, radius: 10, sampleCount: 144
        )
        let originalDeviation = standardDeviation(fromKnownMean: originalOuter, mean: 1300)
        let correctedDeviation = standardDeviation(fromKnownMean: correctedOuter, mean: 1300)
        let correctedContrast = mean(correctedOuter) - mean(correctedInner)

        #expect(correctedDeviation <= originalDeviation * 0.40)
        #expect(correctedContrast >= 270)
        #expect(correctedContrast <= 330)
    }

    @Test("La finestra circolare non crea una cucitura all'angolo zero")
    func angularWindowWrapsWithoutSeam() throws {
        let fixture = try makeStreakPhantom(slices: 1)
        let result = try PolarStreakSuppression.apply(
            to: fixture.volume,
            metalMask: fixture.metalMask,
            parameters: fixture.parameters
        )
        let values = ringValues(
            volume: result.volume, centre: fixture.centre, radius: 25, sampleCount: 144
        )
        let seam = abs(Double(values[0]) - Double(values[143]))
        var typicalMaximum = 0.0
        for index in 1..<143 {
            typicalMaximum = max(
                typicalMaximum,
                abs(Double(values[index]) - Double(values[index - 1]))
            )
        }

        #expect(seam <= typicalMaximum + 2)
    }

    @Test("Il bordo radiale sfuma la correzione senza creare un anello netto")
    func radialBoundaryIsFeathered() throws {
        let fixture = try makeStreakPhantom(slices: 1)
        let result = try PolarStreakSuppression.apply(
            to: fixture.volume,
            metalMask: fixture.metalMask,
            parameters: fixture.parameters
        )
        let row = fixture.centre.j
        var maximumJump = 0
        for column in (fixture.centre.i + 37)...(fixture.centre.i + 41) {
            let first = result.volume.rawValue(i: column - 1, j: row, k: 0) ?? 0
            let second = result.volume.rawValue(i: column, j: row, k: 0) ?? 0
            maximumJump = max(maximumJump, abs(Int(second) - Int(first)))
        }

        // L'anello netto non corretto salterebbe di circa 200 GV; la rampa in tre millimetri
        // limita il gradino sotto 90 GV anche dopo il ricampionamento bilineare.
        #expect(maximumJump <= 90)
    }

    @Test("Il metallo è reinserito identico e la provenienza descrive l'intorno corretto")
    func preservesMetalAndRecordsActualChanges() throws {
        let fixture = try makeStreakPhantom(slices: 1)
        let result = try PolarStreakSuppression.apply(
            to: fixture.volume,
            metalMask: fixture.metalMask,
            parameters: fixture.parameters
        )
        let metalIndex = fixture.volume.linearIndex(
            i: fixture.centre.i,
            j: fixture.centre.j,
            k: 0
        )
        let modifiedCount = result.modifiedMask.voxelCounts()[1] ?? 0

        #expect(result.volume.samples[metalIndex] == fixture.volume.samples[metalIndex])
        #expect(result.modifiedMask.labels[metalIndex] == 0)
        #expect(modifiedCount > (fixture.metalMask.voxelCounts()[1] ?? 0))
        #expect(result.provenance.isModified)
        #expect(result.provenance.steps.count == 1)
        #expect(result.provenance.steps[0].affectedVoxelCount == modifiedCount)
        #expect(result.volume.geometry == fixture.volume.geometry)
        #expect(result.volume.rescaleSlope == fixture.volume.rescaleSlope)
        #expect(result.volume.rescaleIntercept == fixture.volume.rescaleIntercept)
        #expect(result.volume.densityUnit == fixture.volume.densityUnit)
    }
}

private struct StreakFixture {
    let volume: Volume
    let metalMask: VolumeMask
    let parameters: StreakSuppressionParameters
    let centre: (i: Int, j: Int)
}

private func makeStreakPhantom(slices: Int) throws -> StreakFixture {
    let columns = 101
    let rows = 101
    let centre = (i: 50, j: 50)
    var samples = [Int16]()
    samples.reserveCapacity(columns * rows * slices)
    for k in 0..<slices {
        for j in 0..<rows {
            for i in 0..<columns {
                let x = Double(i - centre.i)
                let y = Double(j - centre.j)
                let radius = hypot(x, y)
                let angle = atan2(y, x)
                let anatomy = radius >= 18 ? 300.0 : 0.0
                let streak = k == 0 ? 200.0 * cos(24.0 * angle) : 0.0
                let value = radius <= 45 ? 1000.0 + anatomy + streak : 100.0
                samples.append(Int16(clamping: Int(value.rounded())))
            }
        }
    }
    let volume = try makeArtifactVolume(
        columns: columns,
        rows: rows,
        slices: slices,
        samples: samples,
        slope: 1.25,
        intercept: -30,
        densityUnit: .declaredHounsfield
    )
    var mask = try #require(VolumeMask(geometry: volume.geometry))
    mask.setLabel(1, i: centre.i, j: centre.j, k: 0)
    var metalSamples = volume.samples
    metalSamples[volume.linearIndex(i: centre.i, j: centre.j, k: 0)] = 5000
    let metalVolume = try Volume(
        geometry: volume.geometry,
        samples: metalSamples,
        rescaleSlope: volume.rescaleSlope,
        rescaleIntercept: volume.rescaleIntercept,
        densityUnit: volume.densityUnit
    )
    var parameters = StreakSuppressionParameters()
    parameters.radiusMM = 40
    parameters.angularWindowDegrees = 15
    parameters.strength = 1
    parameters.preservesMetal = true
    return StreakFixture(
        volume: metalVolume,
        metalMask: mask,
        parameters: parameters,
        centre: centre
    )
}

private func ringValues(
    volume: Volume,
    centre: (i: Int, j: Int),
    radius: Double,
    sampleCount: Int
) -> [Int16] {
    var values = [Int16]()
    values.reserveCapacity(sampleCount)
    for sample in 0..<sampleCount {
        let angle = 2 * Double.pi * Double(sample) / Double(sampleCount)
        let i = centre.i + Int((radius * cos(angle)).rounded())
        let j = centre.j + Int((radius * sin(angle)).rounded())
        values.append(volume.rawValue(i: i, j: j, k: 0) ?? 0)
    }
    return values
}

private func mean(_ values: [Int16]) -> Double {
    var sum = 0.0
    for value in values { sum += Double(value) }
    return values.isEmpty ? 0 : sum / Double(values.count)
}

private func standardDeviation(fromKnownMean values: [Int16], mean: Double) -> Double {
    guard !values.isEmpty else { return 0 }
    var squared = 0.0
    for value in values {
        let difference = Double(value) - mean
        squared += difference * difference
    }
    return sqrt(squared / Double(values.count))
}
