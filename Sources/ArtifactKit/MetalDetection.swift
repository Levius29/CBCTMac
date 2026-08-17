import Foundation
import DICOMCore
import SegmentKit

/// Regione metallica connessa individuata nel volume.
public struct MetalRegion: Hashable, Sendable {
    public let label: SegmentLabel
    public let centroidMM: Vec3
    public let volumeMM3: Double
    /// Intervallo di fette su cui la regione compare.
    public let sliceRange: ClosedRange<Int>

    /// Costruisce il riepilogo di una componente metallica già verificata.
    public init(
        label: SegmentLabel,
        centroidMM: Vec3,
        volumeMM3: Double,
        sliceRange: ClosedRange<Int>
    ) {
        self.label = label
        self.centroidMM = centroidMM
        self.volumeMM3 = volumeMM3
        self.sliceRange = sliceRange
    }
}

/// Individuazione euristica delle regioni metalliche su valori grigi CBCT.
public enum MetalDetection: Sendable {
    /// Soglia automatica ricavata dalla coda alta dell'istogramma.
    ///
    /// I GV non sono calibrati fra apparecchi. Si prende il primo campione oltre il 99,5%
    /// cumulativo e lo si confronta con la moda: il punto medio separa la popolazione dominante
    /// dalla coda densa. È un'euristica intenzionale e la soglia manuale resta sempre disponibile.
    public static func suggestedThresholdGV(for volume: Volume) -> Double {
        let offset = -Int(Int16.min)
        var histogram = [Int](repeating: 0, count: Int(UInt16.max) + 1)
        for sample in volume.samples {
            histogram[Int(sample) + offset] += 1
        }

        var modeIndex = 0
        var modeCount = -1
        for index in histogram.indices {
            if histogram[index] > modeCount {
                modeCount = histogram[index]
                modeIndex = index
            }
        }

        let targetCount = Int(floor(Double(volume.samples.count) * 0.995))
        var cumulative = 0
        var percentileIndex = histogram.count - 1
        if volume.rescaleSlope > 0 {
            for index in histogram.indices {
                cumulative += histogram[index]
                if cumulative > targetCount {
                    percentileIndex = index
                    break
                }
            }
        } else {
            percentileIndex = 0
            for index in histogram.indices.reversed() {
                cumulative += histogram[index]
                if cumulative > targetCount {
                    percentileIndex = index
                    break
                }
            }
        }

        let modeRaw = Double(modeIndex - offset)
        let percentileRaw = Double(percentileIndex - offset)
        if percentileIndex == modeIndex {
            let aboveMaximum = volume.densityRange.upperBound + abs(volume.rescaleSlope)
            return aboveMaximum.isFinite ? aboveMaximum : Double.greatestFiniteMagnitude
        }
        let thresholdRaw = modeRaw + (percentileRaw - modeRaw) * 0.5
        return thresholdRaw * volume.rescaleSlope + volume.rescaleIntercept
    }

    /// Segmenta, filtra e descrive le componenti metalliche senza dilatarle.
    ///
    /// La dilatazione appartiene alla correzione della penombra, non alla misura del metallo:
    /// applicarla qui falserebbe volume e baricentro riportati all'utente.
    public static func detect(
        in volume: Volume,
        thresholdGV: Double?,
        minimumVolumeMM3: Double
    ) throws -> (mask: VolumeMask, regions: [MetalRegion]) {
        let threshold = thresholdGV ?? suggestedThresholdGV(for: volume)
        let filtered = try ThresholdSegmentation.metalMask(
            volume,
            thresholdGV: threshold,
            dilationMM: 0,
            minimumVolumeMM3: minimumVolumeMM3
        )
        let labeled = try ConnectedComponents.label(filtered, connectivity: .faces)
        var ranges: [SegmentLabel: ClosedRange<Int>] = [:]
        let geometry = volume.geometry
        let planeSize = geometry.columnCount * geometry.rowCount
        for index in labeled.mask.labels.indices {
            let label = labeled.mask.labels[index]
            guard label != VolumeMask.background else { continue }
            let slice = index / planeSize
            if let current = ranges[label] {
                ranges[label] = Swift.min(current.lowerBound, slice)...Swift.max(current.upperBound, slice)
            } else {
                ranges[label] = slice...slice
            }
        }

        var regions = [MetalRegion]()
        regions.reserveCapacity(labeled.components.count)
        for component in labeled.components {
            guard let sliceRange = ranges[component.label] else { continue }
            regions.append(MetalRegion(
                label: component.label,
                centroidMM: component.centroidMM,
                volumeMM3: component.volumeMM3,
                sliceRange: sliceRange
            ))
        }
        return (labeled.mask, regions)
    }
}
