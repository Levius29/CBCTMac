import Foundation
import DICOMCore

/// Statistiche di densità e dimensione per una selezione di voxel.
public struct MaskStatistics: Hashable, Sendable {
    /// Numero di voxel selezionati.
    public let voxelCount: Int
    /// Volume fisico della selezione in millimetri cubi.
    public let volumeMM3: Double
    /// Media della densità dopo rescale.
    public let meanDensity: Double
    /// Deviazione standard campionaria della densità dopo rescale.
    public let standardDeviation: Double
    /// Minima densità dopo rescale.
    public let minimumDensity: Double
    /// Massima densità dopo rescale.
    public let maximumDensity: Double
    /// Simbolo dell'unità di densità del volume.
    public let densityUnitSymbol: String

    /// Crea le statistiche già calcolate per una selezione.
    public init(
        voxelCount: Int,
        volumeMM3: Double,
        meanDensity: Double,
        standardDeviation: Double,
        minimumDensity: Double,
        maximumDensity: Double,
        densityUnitSymbol: String
    ) {
        self.voxelCount = voxelCount
        self.volumeMM3 = volumeMM3
        self.meanDensity = meanDensity
        self.standardDeviation = standardDeviation
        self.minimumDensity = minimumDensity
        self.maximumDensity = maximumDensity
        self.densityUnitSymbol = densityUnitSymbol
    }
}

/// Analisi numeriche di maschere applicate a un volume con la stessa geometria.
public enum MaskAnalysis: Sendable {
    /// Calcola le statistiche sui campioni realmente selezionati, oppure `nil` se non ce ne sono.
    ///
    /// La varianza è calcolata in una seconda passata sugli scarti dalla media grezza per evitare
    /// la cancellazione numerica della formula `E[x²] - E[x]²` sui valori CBCT elevati.
    public static func statistics(
        of volume: Volume, within mask: VolumeMask, label: SegmentLabel?
    ) throws -> MaskStatistics? {
        guard volume.geometry == mask.geometry else { throw SegmentKitError.incompatibleGeometry }
        var count = 0
        var rawSum = 0.0
        var rawMinimum = Double.infinity
        var rawMaximum = -Double.infinity
        for index in volume.samples.indices where selects(mask.labels[index], label: label) {
            let raw = Double(volume.samples[index])
            count += 1
            rawSum += raw
            rawMinimum = Swift.min(rawMinimum, raw)
            rawMaximum = Swift.max(rawMaximum, raw)
        }
        guard count > 0 else { return nil }
        let rawMean = rawSum / Double(count)
        var squaredDeviationSum = 0.0
        if count > 1 {
            for index in volume.samples.indices where selects(mask.labels[index], label: label) {
                let deviation = Double(volume.samples[index]) - rawMean
                squaredDeviationSum += deviation * deviation
            }
        }
        let rawStandardDeviation = count > 1
            ? (squaredDeviationSum / Double(count - 1)).squareRoot()
            : 0.0
        let firstDensityBound = rawMinimum * volume.rescaleSlope + volume.rescaleIntercept
        let secondDensityBound = rawMaximum * volume.rescaleSlope + volume.rescaleIntercept
        let voxelVolume = volume.geometry.columnSpacingMM
            * volume.geometry.rowSpacingMM * volume.geometry.sliceSpacingMM
        return MaskStatistics(
            voxelCount: count,
            volumeMM3: Double(count) * voxelVolume,
            meanDensity: rawMean * volume.rescaleSlope + volume.rescaleIntercept,
            standardDeviation: rawStandardDeviation * abs(volume.rescaleSlope),
            minimumDensity: Swift.min(firstDensityBound, secondDensityBound),
            maximumDensity: Swift.max(firstDensityBound, secondDensityBound),
            densityUnitSymbol: volume.densityUnit.symbol
        )
    }

    private static func selects(_ maskLabel: SegmentLabel, label: SegmentLabel?) -> Bool {
        guard let label else { return maskLabel != VolumeMask.background }
        return maskLabel == label
    }
}
