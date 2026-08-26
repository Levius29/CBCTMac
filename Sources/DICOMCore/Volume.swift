import Foundation

// Il volume ricostruito, lato CPU.
//
// Implementa il lato CPU del Contratto 3: campioni `Int16` grezzi più slope/intercept.
// La controparte GPU (texture 3D `.r16Float`) vive in VolumeKit e si costruisce da qui.
//
// Regola che discende dal Contratto 3: **ogni statistica di densità si calcola su questi dati**,
// mai leggendo la texture. La texture è filtrata, e una media su valori interpolati è una media
// verosimile e falsa, con minimi e massimi che nel dato reale non compaiono mai.

// MARK: - Unità di densità

/// Come vanno etichettati i valori di densità nella UI.
///
/// Vedi il Contratto 4: le CBCT non producono unità Hounsfield. Il tipo esiste per rendere
/// impossibile stampare «HU» per distrazione.
public enum DensityUnit: Hashable, Sendable, Codable {
    /// Valore grigio CBCT. Non confrontabile con la letteratura in HU né fra apparecchi diversi.
    case greyValue
    /// Unità Hounsfield **dichiarate dal produttore**: TC vera, o CBCT che afferma di calibrare.
    /// Resta una dichiarazione, non una garanzia.
    case declaredHounsfield

    public var symbol: String {
        switch self {
        case .greyValue: return "GV"
        case .declaredHounsfield: return "HU"
        }
    }

    /// L'inverso di `symbol`, per rileggere un volume archiviato.
    ///
    /// Un simbolo sconosciuto dà `.greyValue`, e il verso di questo ripiego non è indifferente.
    /// Dichiarare HU su dati che non lo sono invita a confrontarli con le soglie di
    /// letteratura, che è precisamente l'errore che il Contratto 4 esiste per impedire.
    /// Dichiarare GV su una TC vera fa perdere un'informazione e non induce a sbagliare.
    public init(symbol: String) {
        switch symbol.uppercased() {
        case "HU": self = .declaredHounsfield
        default: self = .greyValue
        }
    }

    /// Testo del tooltip che accompagna sempre una lettura di densità.
    public var explanation: String {
        switch self {
        case .greyValue:
            return "Valore grigio CBCT. Non equivale alle unità Hounsfield della TC: dipende "
                + "dall'apparecchio, dal FOV e dalla posizione nell'immagine, e non è "
                + "confrontabile con i valori di riferimento in letteratura."
        case .declaredHounsfield:
            return "Unità Hounsfield dichiarate dal produttore dell'apparecchio. "
                + "La calibrazione non è verificata da questo software."
        }
    }
}

// MARK: - Volume

/// Volume tridimensionale immutabile, con la sua geometria.
///
/// Immutabile e `Sendable`: una volta costruito attraversa gli attori senza sincronizzazione.
/// L'array `Int16` è copy-on-write, quindi passarlo per valore non duplica i mezzo gigabyte.
public struct Volume: Sendable {

    public let geometry: VolumeGeometry

    /// Campioni grezzi in ordine `k`-maggiore: indice `= (k · rows + j) · columns + i`.
    /// Ordine scelto per far coincidere una slice con un intervallo contiguo, così il
    /// caricamento scrive sequenzialmente e l'upload alla texture procede per slice.
    public let samples: [Int16]

    /// `RescaleSlope (0028,1053)`.
    public let rescaleSlope: Double
    /// `RescaleIntercept (0028,1052)`.
    public let rescaleIntercept: Double

    /// Come etichettare le letture di densità di questo volume.
    public let densityUnit: DensityUnit

    /// Minimo e massimo dei campioni grezzi, calcolati una volta in costruzione.
    /// Servono a finestra/livello automatici e all'istogramma della transfer function.
    public let rawValueRange: ClosedRange<Int16>

    public init(
        geometry: VolumeGeometry,
        samples: [Int16],
        rescaleSlope: Double = 1.0,
        rescaleIntercept: Double = 0.0,
        densityUnit: DensityUnit = .greyValue
    ) throws {
        let expected = geometry.voxelCount
        guard samples.count == expected else {
            throw VolumeError.sampleCountMismatch(expected: expected, actual: samples.count)
        }
        self.geometry = geometry
        self.samples = samples
        self.rescaleSlope = rescaleSlope.isFinite && rescaleSlope != 0 ? rescaleSlope : 1.0
        self.rescaleIntercept = rescaleIntercept.isFinite ? rescaleIntercept : 0.0
        self.densityUnit = densityUnit

        if let lo = samples.min(), let hi = samples.max() {
            self.rawValueRange = lo...hi
        } else {
            self.rawValueRange = 0...0
        }
    }

    // MARK: Indicizzazione

    @inlinable
    public func linearIndex(i: Int, j: Int, k: Int) -> Int {
        (k * geometry.rowCount + j) * geometry.columnCount + i
    }

    @inlinable
    public func isValidVoxel(i: Int, j: Int, k: Int) -> Bool {
        i >= 0 && i < geometry.columnCount
            && j >= 0 && j < geometry.rowCount
            && k >= 0 && k < geometry.sliceCount
    }

    /// Campione grezzo, senza rescale. `nil` fuori dal volume.
    @inlinable
    public func rawValue(i: Int, j: Int, k: Int) -> Int16? {
        guard isValidVoxel(i: i, j: j, k: k) else { return nil }
        return samples[linearIndex(i: i, j: j, k: k)]
    }

    /// Valore di densità con rescale applicato, nell'unità indicata da `densityUnit`.
    @inlinable
    public func densityValue(i: Int, j: Int, k: Int) -> Double? {
        guard let raw = rawValue(i: i, j: j, k: k) else { return nil }
        return Double(raw) * rescaleSlope + rescaleIntercept
    }

    @inlinable
    public func applyRescale(_ raw: Int16) -> Double {
        Double(raw) * rescaleSlope + rescaleIntercept
    }

    /// Intervallo dei valori dopo rescale, per finestra/livello e istogrammi.
    public var densityRange: ClosedRange<Double> {
        let a = applyRescale(rawValueRange.lowerBound)
        let b = applyRescale(rawValueRange.upperBound)
        return Swift.min(a, b)...Swift.max(a, b)
    }

    // MARK: Campionamento

    /// Campionamento **nearest neighbour** da un punto in mm Patient.
    ///
    /// È la funzione da usare per le statistiche ROI: restituisce un valore realmente presente
    /// nel dato, non una media fra vicini.
    public func densityValue(atPatient p: Vec3) -> Double? {
        let v = geometry.voxelPoint(fromPatient: p)
        // Un piano JSON danneggiato può portare qui NaN, infinito o una coordinata troppo grande
        // per `Int`: la conversione diretta va in trap e abbatte l'app mentre apre il caso.
        guard v.isFinite,
            let i = Int(exactly: v.x.rounded()),
            let j = Int(exactly: v.y.rounded()),
            let k = Int(exactly: v.z.rounded())
        else { return nil }
        return densityValue(i: i, j: j, k: k)
    }

    /// Campionamento **trilineare** da un punto in mm Patient.
    ///
    /// Per profili lungo una linea e anteprime, dove la continuità conta più della fedeltà al
    /// singolo voxel. Da non usare per le statistiche: vedi il Contratto 3.
    public func interpolatedDensityValue(atPatient p: Vec3) -> Double? {
        let v = geometry.voxelPoint(fromPatient: p)
        guard v.isFinite else { return nil }

        let fi = v.x.rounded(.down)
        let fj = v.y.rounded(.down)
        let fk = v.z.rounded(.down)
        let i0 = Int(fi), j0 = Int(fj), k0 = Int(fk)
        let tx = v.x - fi, ty = v.y - fj, tz = v.z - fk

        // Serve l'intero cubo di 8 vicini; ai bordi si rinuncia invece di estrapolare.
        guard isValidVoxel(i: i0, j: j0, k: k0),
              isValidVoxel(i: i0 + 1, j: j0 + 1, k: k0 + 1)
        else {
            return densityValue(atPatient: p)
        }

        @inline(__always)
        func raw(_ di: Int, _ dj: Int, _ dk: Int) -> Double {
            Double(samples[linearIndex(i: i0 + di, j: j0 + dj, k: k0 + dk)])
        }

        let c00 = raw(0, 0, 0) * (1 - tx) + raw(1, 0, 0) * tx
        let c10 = raw(0, 1, 0) * (1 - tx) + raw(1, 1, 0) * tx
        let c01 = raw(0, 0, 1) * (1 - tx) + raw(1, 0, 1) * tx
        let c11 = raw(0, 1, 1) * (1 - tx) + raw(1, 1, 1) * tx

        let c0 = c00 * (1 - ty) + c10 * ty
        let c1 = c01 * (1 - ty) + c11 * ty

        return (c0 * (1 - tz) + c1 * tz) * rescaleSlope + rescaleIntercept
    }

    /// Accesso diretto ai campioni senza copia. Da preferire nei cicli stretti
    /// (statistiche ROI, costruzione dell'istogramma, upload GPU).
    public func withUnsafeSamples<R>(_ body: (UnsafeBufferPointer<Int16>) throws -> R) rethrows -> R {
        try samples.withUnsafeBufferPointer(body)
    }

    // MARK: Istogramma

    /// Istogramma dei valori grezzi su `binCount` intervalli uniformi.
    /// Alimenta l'editor di transfer function e la scelta automatica di finestra/livello.
    public func rawHistogram(binCount: Int = 512) -> [Int] {
        guard binCount > 0 else { return [] }
        let lo = Double(rawValueRange.lowerBound)
        let hi = Double(rawValueRange.upperBound)
        guard hi > lo else { return [samples.count] }

        var bins = [Int](repeating: 0, count: binCount)
        let scale = Double(binCount) / (hi - lo)
        withUnsafeSamples { buffer in
            for value in buffer {
                let position = (Double(value) - lo) * scale
                let index = Swift.min(binCount - 1, Swift.max(0, Int(position)))
                bins[index] += 1
            }
        }
        return bins
    }
}

// MARK: - Errori

public enum VolumeError: Error, Hashable, Sendable {
    case sampleCountMismatch(expected: Int, actual: Int)
    case unsupportedBitDepth(bitsAllocated: Int)
    case allocationFailed(bytes: Int)

    public var localizedDescription: String {
        switch self {
        case .sampleCountMismatch(let expected, let actual):
            return "Numero di campioni incoerente con la geometria: attesi \(expected), "
                + "ricevuti \(actual)."
        case .unsupportedBitDepth(let bits):
            return "Profondità di \(bits) bit non supportata."
        case .allocationFailed(let bytes):
            let mb = Double(bytes) / 1_048_576.0
            return String(format: "Memoria insufficiente per un volume da %.0f MB.", mb)
        }
    }
}
