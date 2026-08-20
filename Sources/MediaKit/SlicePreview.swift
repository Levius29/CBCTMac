import DICOMCore
import Foundation

// Le anteprime delle fette: da voxel a pixel.
//
// # Perché ridotte
//
// Perché sono un'**anteprima**, non il dato. Il dato sono i file DICOM che stanno accanto, e chi
// deve misurare apre quelli. Queste servono a chi ha ricevuto una chiavetta e vuole vedere subito
// che cosa contiene, senza installare niente: un PNG non compresso a piena risoluzione, per
// quattrocento fette, sarebbe un centinaio di megabyte per una cosa che si guarda una volta.

public struct SlicePreview: Hashable, Sendable {
    /// Il PNG, pronto da scrivere su disco.
    public var pngData: Data
    /// L'indice della fetta nel volume, da zero.
    public var sliceIndex: Int
    /// La quota della fetta lungo la normale, in millimetri Patient.
    public var positionMM: Double
    public var width: Int
    public var height: Int
}

public enum SlicePreviewBuilder: Sendable {

    /// Quante fette al massimo entrano in un'anteprima.
    public static let defaultMaximumSlices = 60
    /// Il lato più lungo di un'anteprima, in pixel.
    public static let defaultMaximumSide = 384

    /// Genera le anteprime assiali di un volume.
    ///
    /// # La finestra
    ///
    /// I valori si trasformano in grigi con la stessa finestra che si sta guardando nel
    /// programma. Sceglierne una da soli — il minimo e il massimo del volume, per esempio — darebbe
    /// un'immagine slavata su ogni CBCT, perché il massimo è quasi sempre un'otturazione
    /// metallica e schiaccia tutto il resto in due livelli di grigio.
    ///
    /// - Parameters:
    ///   - volume: il volume da cui leggere.
    ///   - windowCenterGV: il centro della finestra di densità.
    ///   - windowWidthGV: la sua ampiezza. Valori non positivi vengono portati a uno.
    ///   - maximumSlices: quante fette al massimo.
    ///   - maximumSide: il lato più lungo in pixel.
    public static func previews(
        of volume: Volume,
        windowCenterGV: Double,
        windowWidthGV: Double,
        maximumSlices: Int = defaultMaximumSlices,
        maximumSide: Int = defaultMaximumSide
    ) -> [SlicePreview] {
        let geometry = volume.geometry
        guard geometry.sliceCount > 0, geometry.columnCount > 0, geometry.rowCount > 0,
            maximumSlices > 0, maximumSide > 0
        else { return [] }

        // Riduzione a numeri interi: un fattore frazionario richiederebbe un ricampionamento, e
        // per un'anteprima la media su blocchi interi costa meno e non introduce ringing.
        let longest = Swift.max(geometry.columnCount, geometry.rowCount)
        let factor = Swift.max(1, Int(ceil(Double(longest) / Double(maximumSide))))
        let width = Swift.max(1, geometry.columnCount / factor)
        let height = Swift.max(1, geometry.rowCount / factor)

        let indices = sliceIndices(count: geometry.sliceCount, limit: maximumSlices)
        let width2 = Double(Swift.max(windowWidthGV, 1))
        let low = windowCenterGV - width2 / 2

        var result: [SlicePreview] = []
        result.reserveCapacity(indices.count)

        for slice in indices {
            var pixels = [UInt8](repeating: 0, count: width * height)
            let area = geometry.columnCount * geometry.rowCount
            let base = slice * area

            for row in 0..<height {
                for column in 0..<width {
                    // Media del blocco `factor × factor`: senza, una struttura sottile può
                    // sparire del tutto fra un campione e il successivo.
                    var sum = 0.0
                    var count = 0
                    for dy in 0..<factor {
                        let sourceRow = row * factor + dy
                        guard sourceRow < geometry.rowCount else { break }
                        let rowBase = base + sourceRow * geometry.columnCount
                        for dx in 0..<factor {
                            let sourceColumn = column * factor + dx
                            guard sourceColumn < geometry.columnCount else { break }
                            sum += Double(volume.samples[rowBase + sourceColumn])
                            count += 1
                        }
                    }
                    guard count > 0 else { continue }
                    let raw = sum / Double(count)
                    let value = raw * volume.rescaleSlope + volume.rescaleIntercept
                    let normalized = (value - low) / width2
                    let clamped = Swift.max(0, Swift.min(1, normalized))
                    pixels[row * width + column] = UInt8((clamped * 255).rounded())
                }
            }

            guard let png = PNGEncoder.grayscale(pixels: pixels, width: width, height: height)
            else { continue }

            let origin = geometry.patientPoint(i: 0, j: 0, k: slice)
            result.append(
                SlicePreview(
                    pngData: png, sliceIndex: slice,
                    positionMM: origin.dot(geometry.orientation.normal),
                    width: width, height: height))
        }
        return result
    }

    /// Quali fette prendere, distribuite in modo uniforme fra la prima e l'ultima.
    ///
    /// Prima e ultima incluse: sono le due che dicono dove comincia e dove finisce il campo, ed è
    /// la prima cosa che si vuole sapere guardando un esame ricevuto.
    static func sliceIndices(count: Int, limit: Int) -> [Int] {
        guard count > 0, limit > 0 else { return [] }
        guard count > limit else { return Array(0..<count) }
        guard limit > 1 else { return [0] }
        return (0..<limit).map { step in
            Int((Double(step) * Double(count - 1) / Double(limit - 1)).rounded())
        }
    }
}
