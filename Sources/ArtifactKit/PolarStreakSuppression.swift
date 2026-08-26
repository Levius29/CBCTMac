import Foundation
import DICOMCore
import SegmentKit

/// Parametri fisici della soppressione delle strie in dominio polare.
public struct StreakSuppressionParameters: Hashable, Sendable, Codable {
    /// Raggio massimo di azione attorno al centro del metallo, in millimetri.
    public var radiusMM: Double
    /// Ampiezza della finestra angolare del filtro, in gradi.
    public var angularWindowDegrees: Double
    /// Frazione della correzione applicata, da zero a uno.
    public var strength: Double
    /// Se vero, i campioni metallici vengono reinseriti identici all'acquisizione.
    public var preservesMetal: Bool

    /// Valori iniziali prudenti per una CBCT dentale.
    public init() {
        radiusMM = 40
        angularWindowDegrees = 10
        strength = 1
        preservesMetal = true
    }
}

/// Riduzione delle strie assiali mediante filtraggio angolare in coordinate polari.
public enum PolarStreakSuppression: Sendable {
    private static let maximumPolarSampleCount = 10_000_000

    /// Corregge le sole slice che contengono metallo e registra ogni voxel realmente alterato.
    ///
    /// Il centro viene ricalcolato su ogni slice perché una corona inclinata cambia posizione
    /// lungo `k`. Il filtro non va usato sul volume intero con un unico centro: le strie seguono
    /// il metallo presente nel piano di acquisizione corrente.
    public static func apply(
        to volume: Volume,
        metalMask: VolumeMask,
        parameters: StreakSuppressionParameters
    ) throws -> ProcessedVolume {
        try validate(volume: volume, mask: metalMask, parameters: parameters)
        guard var modifiedMask = VolumeMask(geometry: volume.geometry) else {
            throw ArtifactReductionError.invalidParameters(
                detail: "La maschera dei voxel modificati non è allocabile."
            )
        }

        var outputSamples = volume.samples
        let geometry = volume.geometry
        let planeSize = geometry.columnCount * geometry.rowCount
        var affectedVoxelCount = 0

        for k in 0..<geometry.sliceCount {
            let sliceStart = k * planeSize
            // Saltare qui, prima di qualunque ricampionamento, garantisce che una slice senza
            // metallo resti identica anche dopo arrotondamenti apparentemente innocui.
            guard let centre = metalCentroid(
                mask: metalMask,
                sliceStart: sliceStart,
                planeSize: planeSize,
                columnCount: geometry.columnCount
            ) else { continue }

            let effectiveRadiusMM = min(
                parameters.radiusMM,
                farthestCornerDistanceMM(centre: centre, geometry: geometry)
            )
            guard effectiveRadiusMM > 0 else { continue }
            let grid = try makePolarGrid(
                samples: outputSamples,
                sliceStart: sliceStart,
                geometry: geometry,
                centre: centre,
                radiusMM: effectiveRadiusMM,
                angularWindowDegrees: parameters.angularWindowDegrees
            )
            let featherWidthMM = min(3.0, max(grid.radialStepMM, effectiveRadiusMM * 0.10))

            for j in 0..<geometry.rowCount {
                for i in 0..<geometry.columnCount {
                    let dxMM = (Double(i) - centre.i) * geometry.columnSpacingMM
                    let dyMM = (Double(j) - centre.j) * geometry.rowSpacingMM
                    let radiusMM = hypot(dxMM, dyMM)
                    guard radiusMM <= effectiveRadiusMM else { continue }
                    let index = sliceStart + j * geometry.columnCount + i
                    if parameters.preservesMetal,
                       metalMask.labels[index] != VolumeMask.background {
                        outputSamples[index] = volume.samples[index]
                        continue
                    }

                    var angle = atan2(dyMM, dxMM)
                    if angle < 0 { angle += 2 * Double.pi }
                    let streak = grid.interpolatedStreak(radiusMM: radiusMM, angle: angle)
                    let featherStart = effectiveRadiusMM - featherWidthMM
                    let feather: Double
                    // Un passaggio netto alla sorgente creerebbe un anello che sembra anatomia;
                    // la rampa porta la correzione a zero prima del limite fisico richiesto.
                    if radiusMM <= featherStart {
                        feather = 1
                    } else {
                        feather = max(0, (effectiveRadiusMM - radiusMM) / featherWidthMM)
                    }
                    let original = Double(volume.samples[index])
                    let corrected = original - parameters.strength * feather * streak
                    let converted = int16Clamped(corrected)
                    outputSamples[index] = converted
                    if converted != volume.samples[index] {
                        modifiedMask.setLabel(1, i: i, j: j, k: k)
                        affectedVoxelCount += 1
                    }
                }
            }
        }

        let correctedVolume = try Volume(
            geometry: volume.geometry,
            samples: outputSamples,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept,
            densityUnit: volume.densityUnit
        )
        let steps: [ProcessingStep]
        if affectedVoxelCount == 0 {
            steps = []
        } else {
            let numericDescription = String(
                format: "raggio %.1f mm; finestra %.1f°; intensità %.2f; ",
                parameters.radiusMM,
                parameters.angularWindowDegrees,
                parameters.strength
            )
            let description = numericDescription
                + (parameters.preservesMetal ? "metallo preservato" : "metallo corretto")
            steps = [ProcessingStep(
                name: "Soppressione strie da metallo",
                parametersDescription: description,
                affectedVoxelCount: affectedVoxelCount,
                date: Date()
            )]
        }
        return ProcessedVolume(
            volume: correctedVolume,
            provenance: ProcessingHistory(steps: steps),
            modifiedMask: modifiedMask
        )
    }

    private static func validate(
        volume: Volume,
        mask: VolumeMask,
        parameters: StreakSuppressionParameters
    ) throws {
        guard volume.geometry == mask.geometry else {
            throw ArtifactReductionError.invalidParameters(
                detail: "La maschera del metallo non ha la geometria del volume."
            )
        }
        guard parameters.radiusMM.isFinite, parameters.radiusMM > 0 else {
            throw ArtifactReductionError.invalidParameters(
                detail: "Il raggio deve essere finito e maggiore di zero."
            )
        }
        guard parameters.angularWindowDegrees.isFinite,
              parameters.angularWindowDegrees > 0,
              parameters.angularWindowDegrees <= 360
        else {
            throw ArtifactReductionError.invalidParameters(
                detail: "La finestra angolare deve essere compresa fra 0 e 360 gradi."
            )
        }
        guard parameters.strength.isFinite,
              parameters.strength >= 0,
              parameters.strength <= 1
        else {
            throw ArtifactReductionError.invalidParameters(
                detail: "L'intensità deve essere compresa fra zero e uno."
            )
        }
    }

    private static func metalCentroid(
        mask: VolumeMask,
        sliceStart: Int,
        planeSize: Int,
        columnCount: Int
    ) -> (i: Double, j: Double)? {
        var sumI = 0.0
        var sumJ = 0.0
        var count = 0
        for withinSlice in 0..<planeSize {
            guard mask.labels[sliceStart + withinSlice] != VolumeMask.background else { continue }
            sumI += Double(withinSlice % columnCount)
            sumJ += Double(withinSlice / columnCount)
            count += 1
        }
        guard count > 0 else { return nil }
        return (sumI / Double(count), sumJ / Double(count))
    }

    private static func farthestCornerDistanceMM(
        centre: (i: Double, j: Double),
        geometry: VolumeGeometry
    ) -> Double {
        let maximumI = Double(geometry.columnCount - 1)
        let maximumJ = Double(geometry.rowCount - 1)
        var farthest = 0.0
        for corner in [(0.0, 0.0), (maximumI, 0.0), (0.0, maximumJ), (maximumI, maximumJ)] {
            let dx = (corner.0 - centre.i) * geometry.columnSpacingMM
            let dy = (corner.1 - centre.j) * geometry.rowSpacingMM
            farthest = max(farthest, hypot(dx, dy))
        }
        return farthest
    }

    private static func makePolarGrid(
        samples: [Int16],
        sliceStart: Int,
        geometry: VolumeGeometry,
        centre: (i: Double, j: Double),
        radiusMM: Double,
        angularWindowDegrees: Double
    ) throws -> PolarGrid {
        let radialStepMM = min(geometry.columnSpacingMM, geometry.rowSpacingMM)
        let radialCountDouble = ceil(radiusMM / radialStepMM) + 1
        let angularCountDouble = max(32, ceil(2 * Double.pi * radiusMM / radialStepMM))
        guard let radialCount = Int(exactly: radialCountDouble),
              let angularCount = Int(exactly: angularCountDouble)
        else {
            throw ArtifactReductionError.invalidParameters(
                detail: "La griglia polare richiesta non è rappresentabile."
            )
        }
        let (sampleCount, overflow) = radialCount.multipliedReportingOverflow(by: angularCount)
        guard !overflow, sampleCount <= maximumPolarSampleCount else {
            throw ArtifactReductionError.invalidParameters(
                detail: "La griglia polare supera il limite di sicurezza."
            )
        }
        let angularStep = 2 * Double.pi / Double(angularCount)
        var values = [Double](repeating: 0, count: sampleCount)
        for radialIndex in 0..<radialCount {
            let radius = min(radiusMM, Double(radialIndex) * radialStepMM)
            for angularIndex in 0..<angularCount {
                let angle = Double(angularIndex) * angularStep
                let i = centre.i + radius * cos(angle) / geometry.columnSpacingMM
                let j = centre.j + radius * sin(angle) / geometry.rowSpacingMM
                values[radialIndex * angularCount + angularIndex] = bilinearSample(
                    samples: samples,
                    sliceStart: sliceStart,
                    columns: geometry.columnCount,
                    rows: geometry.rowCount,
                    i: i,
                    j: j
                )
            }
        }

        var windowCount = Int((angularWindowDegrees / 360 * Double(angularCount)).rounded())
        windowCount = max(1, min(windowCount, angularCount))
        if windowCount.isMultiple(of: 2) {
            windowCount += 1
            if windowCount > angularCount { windowCount -= 2 }
        }
        windowCount = max(1, windowCount)
        var streaks = [Double](repeating: 0, count: sampleCount)
        for radialIndex in 0..<radialCount {
            let start = radialIndex * angularCount
            let row = Array(values[start..<(start + angularCount)])
            // La mediana resiste al valore estremo della stria; una media ne verrebbe trascinata
            // e sottostimerebbe proprio la componente direzionale che si vuole rimuovere.
            let medians = circularMovingMedians(row, windowCount: windowCount)
            for angularIndex in 0..<angularCount {
                streaks[start + angularIndex] = row[angularIndex] - medians[angularIndex]
            }
        }
        return PolarGrid(
            streaks: streaks,
            radialCount: radialCount,
            angularCount: angularCount,
            radialStepMM: radialStepMM,
            angularStep: angularStep
        )
    }

    private static func bilinearSample(
        samples: [Int16],
        sliceStart: Int,
        columns: Int,
        rows: Int,
        i: Double,
        j: Double
    ) -> Double {
        let clampedI = min(Double(columns - 1), max(0, i))
        let clampedJ = min(Double(rows - 1), max(0, j))
        let i0 = Int(clampedI.rounded(.down))
        let j0 = Int(clampedJ.rounded(.down))
        let i1 = min(columns - 1, i0 + 1)
        let j1 = min(rows - 1, j0 + 1)
        let ti = clampedI - Double(i0)
        let tj = clampedJ - Double(j0)
        let a = Double(samples[sliceStart + j0 * columns + i0])
        let b = Double(samples[sliceStart + j0 * columns + i1])
        let c = Double(samples[sliceStart + j1 * columns + i0])
        let d = Double(samples[sliceStart + j1 * columns + i1])
        let top = a * (1 - ti) + b * ti
        let bottom = c * (1 - ti) + d * ti
        return top * (1 - tj) + bottom * tj
    }

    /// Istogramma ordinato a coordinate compresse: conserva esattamente i `Double` interpolati
    /// ma aggiorna la finestra in O(log n), evitando di riordinare ogni vicinato angolare.
    /// Gli indici sono avvolti: senza circolarità gli angoli zero e 2π produrrebbero una cucitura
    /// radiale artificiale proprio nella correzione destinata a rimuovere le strie.
    private static func circularMovingMedians(
        _ values: [Double],
        windowCount: Int
    ) -> [Double] {
        guard !values.isEmpty else { return [] }
        let sorted = values.sorted()
        var unique = [Double]()
        unique.reserveCapacity(sorted.count)
        for value in sorted {
            if unique.last != value {
                unique.append(value)
            }
        }
        var positions: [Double: Int] = [:]
        positions.reserveCapacity(unique.count)
        for index in unique.indices { positions[unique[index]] = index }

        let half = windowCount / 2
        var histogram = FenwickHistogram(size: unique.count)
        for offset in -half...half {
            let angleIndex = wrapped(offset, count: values.count)
            if let position = positions[values[angleIndex]] {
                histogram.add(at: position, delta: 1)
            }
        }

        var medians = [Double](repeating: 0, count: values.count)
        let rank = (windowCount + 1) / 2
        for angleIndex in values.indices {
            medians[angleIndex] = unique[histogram.index(ofElementAtRank: rank)]
            let outgoing = wrapped(angleIndex - half, count: values.count)
            let incoming = wrapped(angleIndex + half + 1, count: values.count)
            if let position = positions[values[outgoing]] {
                histogram.add(at: position, delta: -1)
            }
            if let position = positions[values[incoming]] {
                histogram.add(at: position, delta: 1)
            }
        }
        return medians
    }

    static func wrapped(_ index: Int, count: Int) -> Int {
        let remainder = index % count
        return remainder >= 0 ? remainder : remainder + count
    }

    private static func int16Clamped(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let rounded = value.rounded()
        if rounded <= Double(Int16.min) { return Int16.min }
        if rounded >= Double(Int16.max) { return Int16.max }
        guard let integer = Int(exactly: rounded) else { return 0 }
        return Int16(clamping: integer)
    }
}

struct PolarGrid: Sendable {
    let streaks: [Double]
    let radialCount: Int
    let angularCount: Int
    let radialStepMM: Double
    let angularStep: Double

    func interpolatedStreak(radiusMM: Double, angle: Double) -> Double {
        let radialPosition = min(Double(radialCount - 1), max(0, radiusMM / radialStepMM))
        let angularPosition = angle / angularStep
        let radial0 = Int(radialPosition.rounded(.down))
        let radial1 = min(radialCount - 1, radial0 + 1)
        // `%` conserva il segno in Swift: per un angolo negativo produceva un indice negativo
        // e la lettura sotto andava in trap, anche se oggi il chiamante principale normalizza.
        let angular0 = PolarStreakSuppression.wrapped(
            Int(angularPosition.rounded(.down)), count: angularCount)
        let angular1 = PolarStreakSuppression.wrapped(angular0 + 1, count: angularCount)
        let radialFraction = radialPosition - Double(radial0)
        let angularFraction = angularPosition - floor(angularPosition)
        let a = streaks[radial0 * angularCount + angular0]
        let b = streaks[radial0 * angularCount + angular1]
        let c = streaks[radial1 * angularCount + angular0]
        let d = streaks[radial1 * angularCount + angular1]
        let near = a * (1 - angularFraction) + b * angularFraction
        let far = c * (1 - angularFraction) + d * angularFraction
        return near * (1 - radialFraction) + far * radialFraction
    }
}

private struct FenwickHistogram: Sendable {
    private var tree: [Int]

    init(size: Int) {
        tree = [Int](repeating: 0, count: size + 1)
    }

    mutating func add(at index: Int, delta: Int) {
        var position = index + 1
        while position < tree.count {
            tree[position] += delta
            position += position & -position
        }
    }

    func index(ofElementAtRank rank: Int) -> Int {
        var index = 0
        var accumulated = 0
        var step = 1
        while step < tree.count { step <<= 1 }
        step >>= 1
        var currentStep = step
        while currentStep > 0 {
            let candidate = index + currentStep
            if candidate < tree.count, accumulated + tree[candidate] < rank {
                index = candidate
                accumulated += tree[candidate]
            }
            currentStep >>= 1
        }
        return min(tree.count - 2, index)
    }
}
