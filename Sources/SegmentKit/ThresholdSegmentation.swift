import Foundation
import DICOMCore

/// Segmentazione per intervalli di densità, convertiti una volta nei valori grezzi del volume.
public enum ThresholdSegmentation: Sendable {
    /// Etichetta i voxel la cui densità cade nell'intervallo, eventualmente solo dentro una maschera.
    public static func segment(
        _ volume: Volume,
        densityRange: ClosedRange<Double>,
        label: SegmentLabel,
        within region: VolumeMask?
    ) throws -> VolumeMask {
        guard label != VolumeMask.background else { throw SegmentKitError.backgroundLabelNotAllowed }
        if let region, region.geometry != volume.geometry {
            throw SegmentKitError.incompatibleGeometry
        }

        let rawInterval = try RawDensityInterval(volume: volume, densityRange: densityRange)
        guard var mask = VolumeMask(geometry: volume.geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }

        for index in volume.samples.indices {
            // Fuori dalla regione non si legge il campione: la restrizione limita anche il costo.
            if let region, region.labels[index] == VolumeMask.background { continue }
            if rawInterval.contains(volume.samples[index]) {
                let coordinates = voxelCoordinates(index: index, geometry: volume.geometry)
                mask.setLabel(label, i: coordinates.i, j: coordinates.j, k: coordinates.k)
            }
        }
        return mask
    }

    /// Costruisce la maschera del metallo con soglia alta, dilatazione della penombra e filtro isole.
    ///
    /// La soglia è espressa in GV e viene affidata a `segment`, che conserva la conversione una
    /// sola volta nello spazio dei campioni grezzi; non altera quindi slope, intercetta o unità
    /// della densità del volume. Le altre due fasi delegano i loro controlli ai rispettivi errori
    /// nominati per mantenere un solo contratto di validazione per morfologia e componenti.
    public static func metalMask(
        _ volume: Volume,
        thresholdGV: Double,
        dilationMM: Double,
        minimumVolumeMM3: Double
    ) throws -> VolumeMask {
        guard thresholdGV.isFinite else {
            throw SegmentKitError.invalidMetalThresholdGV(thresholdGV)
        }
        let thresholded = try segment(
            volume,
            densityRange: thresholdGV...Double.greatestFiniteMagnitude,
            label: 1,
            within: nil
        )
        let dilated = try Morphology.dilated(thresholded, byMM: dilationMM)
        return try ConnectedComponents.removingSmaller(
            than: minimumVolumeMM3,
            from: dilated
        )
    }
}

/// Intervallo di campioni grezzi che contiene conservativamente un intervallo di densità.
///
/// È interno al modulo: evita moltiplicazioni per voxel e conserva il confronto in `Int32`.
/// Gli estremi vengono ordinati dopo la divisione per gestire slope negative e arrotondati verso
/// l'esterno, così i voxel sul bordo della soglia non vengono esclusi per difetto.
struct RawDensityInterval: Sendable {
    let minimum: Int32
    let maximum: Int32

    init(volume: Volume, densityRange: ClosedRange<Double>) throws {
        guard densityRange.lowerBound.isFinite, densityRange.upperBound.isFinite else {
            throw SegmentKitError.invalidDensityRange
        }
        guard densityRange.lowerBound <= densityRange.upperBound else {
            throw SegmentKitError.invalidDensityRange
        }
        // `Volume` normalizza slope non valide, ma il controllo difensivo preserva l'inversione
        // della soglia se in futuro viene introdotto un costruttore che non applica tale garanzia.
        guard volume.rescaleSlope.isFinite, volume.rescaleSlope != 0 else {
            throw SegmentKitError.invalidRescaleSlope(volume.rescaleSlope)
        }
        let first = (densityRange.lowerBound - volume.rescaleIntercept) / volume.rescaleSlope
        let second = (densityRange.upperBound - volume.rescaleIntercept) / volume.rescaleSlope
        guard !first.isNaN, !second.isNaN else { throw SegmentKitError.invalidDensityRange }
        let lower = Swift.min(first, second)
        let upper = Swift.max(first, second)
        minimum = Self.lowerBound(containing: lower)
        maximum = Self.upperBound(containing: upper)
    }

    func contains(_ raw: Int16) -> Bool {
        let value = Int32(raw)
        return value >= minimum && value <= maximum
    }

    private static func lowerBound(containing value: Double) -> Int32 {
        let rounded = floor(value)
        if rounded <= Double(Int32.min) { return Int32.min }
        if rounded >= Double(Int32.max) { return Int32.max }
        return Int32(exactly: rounded) ?? Int32.min
    }

    private static func upperBound(containing value: Double) -> Int32 {
        let rounded = ceil(value)
        if rounded <= Double(Int32.min) { return Int32.min }
        if rounded >= Double(Int32.max) { return Int32.max }
        return Int32(exactly: rounded) ?? Int32.max
    }
}

struct RegionOffset: Sendable {
    let i: Int
    let j: Int
    let k: Int
}

let regionFaceOffsets: [RegionOffset] = [
    RegionOffset(i: -1, j: 0, k: 0), RegionOffset(i: 1, j: 0, k: 0),
    RegionOffset(i: 0, j: -1, k: 0), RegionOffset(i: 0, j: 1, k: 0),
    RegionOffset(i: 0, j: 0, k: -1), RegionOffset(i: 0, j: 0, k: 1)
]

func voxelCoordinates(index: Int, geometry: VolumeGeometry) -> (i: Int, j: Int, k: Int) {
    let planeSize = geometry.columnCount * geometry.rowCount
    let k = index / planeSize
    let withinSlice = index % planeSize
    return (withinSlice % geometry.columnCount, withinSlice / geometry.columnCount, k)
}
