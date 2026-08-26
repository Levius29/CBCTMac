import Foundation
import DICOMCore

/// Segmentazione per intervalli di densità, convertiti una volta nei valori grezzi del volume.
/// Finestre di densità di partenza per la segmentazione.
///
/// # Sono punti di partenza, non valori
///
/// Su una CBCT i valori grigi **non** sono unità Hounsfield: dipendono dall'apparecchio, dal
/// campo di vista e dalla posizione nel volume. Le soglie qui sotto sono quelle che funzionano
/// sulla maggior parte delle macchine dentali, e vanno spostate guardando l'istogramma di
/// *questo* volume — che è il motivo per cui sono preset e non costanti nascoste nel codice.
///
/// Vale il Contratto 4: nessuno di questi numeri è confrontabile con la letteratura in HU.
public struct ThresholdPreset: Hashable, Sendable, Identifiable {

    public let id: String
    public let name: String
    public let lowerGV: Double
    public let upperGV: Double
    /// Che cosa ci si aspetta di prendere, e che cosa si prende per sbaglio.
    public let caveat: String

    public init(id: String, name: String, lowerGV: Double, upperGV: Double, caveat: String) {
        self.id = id
        self.name = name
        self.lowerGV = lowerGV
        self.upperGV = upperGV
        self.caveat = caveat
    }

    public static let all: [ThresholdPreset] = [
        ThresholdPreset(
            id: "osso",
            name: "Osso",
            lowerGV: 1000,
            upperGV: 3500,
            caveat: "Prende anche denti, colonna e otturazioni: tutto ciò che è abbastanza denso."),
        ThresholdPreset(
            id: "corticale",
            name: "Osso corticale",
            lowerGV: 1300,
            upperGV: 2200,
            caveat: "Solo il guscio esterno. Su osso di scarsa qualità la corticale è sottile e "
                + "la maschera si spezza: è un'informazione, non un difetto."),
        ThresholdPreset(
            id: "denti",
            name: "Denti e smalto",
            lowerGV: 2000,
            upperGV: 4000,
            caveat: "Lo smalto è la struttura più densa. Le corone metalliche stanno sopra a "
                + "questa finestra e restano fuori; le otturazioni in amalgama no."),
        ThresholdPreset(
            id: "molli",
            name: "Tessuti molli e gengiva",
            lowerGV: -300,
            upperGV: 400,
            caveat: "Gengiva, labbro e lingua hanno densità simili e non si distinguono per "
                + "soglia: quel che esce è il profilo dei tessuti molli, non la gengiva da sola. "
                + "Serve a vedere dove appoggia una protesi, non a modellarla."),
        ThresholdPreset(
            id: "aeree",
            name: "Vie aeree",
            lowerGV: -1024,
            upperGV: -400,
            caveat: "L'aria dentro e fuori il paziente è la stessa: tieni il componente più "
                + "grande, o prenderai anche lo spazio attorno alla testa."),
        ThresholdPreset(
            id: "metallo",
            name: "Metallo",
            lowerGV: 3000,
            upperGV: 32767,
            caveat: "Corone, perni e otturazioni. Utile per vedere da dove nascono le strie "
                + "prima di ridurle."),
    ]
}

public enum ThresholdSegmentation: Sendable {
    /// Etichetta i voxel la cui densità cade nell'intervallo, eventualmente solo dentro una maschera.
    ///
    /// - Parameters:
    ///   - region: una maschera già calcolata dentro cui restare, oppure `nil`.
    ///   - box: un riquadro Patient dentro cui restare, oppure `nil`. È un secondo parametro e
    ///     non un secondo significato del primo perché i due si usano insieme: si limita al
    ///     riquadro *e* a ciò che una maschera precedente aveva selezionato.
    ///
    ///     Serve per la stessa ragione per cui serve alla crescita, e il caso è quello
    ///     dell'arcata: una soglia da osso, su una CBCT, prende la colonna vertebrale, il mento
    ///     e ogni otturazione: «tieni il pezzo più grande» allora restituisce mezzo cranio.
    ///     Stretto il riquadro attorno alla mandibola, lo stesso comando restituisce la
    ///     mandibola. Vedi `GrowthRestriction` per come il riquadro si applica.
    public static func segment(
        _ volume: Volume,
        densityRange: ClosedRange<Double>,
        label: SegmentLabel,
        within region: VolumeMask?,
        insideBoxMM box: BoxMM? = nil
    ) throws -> VolumeMask {
        guard label != VolumeMask.background else { throw SegmentKitError.backgroundLabelNotAllowed }
        if let region, region.geometry != volume.geometry {
            throw SegmentKitError.incompatibleGeometry
        }
        var restriction: GrowthRestriction?
        if let box {
            guard let built = GrowthRestriction(box: box, geometry: volume.geometry) else {
                throw SegmentKitError.cropOutsideVolume
            }
            restriction = built
        }

        let rawInterval = try RawDensityInterval(volume: volume, densityRange: densityRange)
        guard var mask = VolumeMask(geometry: volume.geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }

        // Col riquadro si percorrono solo i suoi indici invece di tutti i voxel del volume: su
        // un FOV grande sono due ordini di grandezza di differenza, e il ciclo è O(voxel) per
        // definizione.
        if let restriction {
            let geometry = volume.geometry
            for k in restriction.minimumK...restriction.maximumK {
                for j in restriction.minimumJ...restriction.maximumJ {
                    for i in restriction.minimumI...restriction.maximumI {
                        guard restriction.allows(i: i, j: j, k: k) else { continue }
                        let index = (k * geometry.rowCount + j) * geometry.columnCount + i
                        if let region, region.labels[index] == VolumeMask.background { continue }
                        if rawInterval.contains(volume.samples[index]) {
                            mask.setLabel(label, i: i, j: j, k: k)
                        }
                    }
                }
            }
            return mask
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
