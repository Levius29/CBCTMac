import DICOMCore
import Foundation
import SegmentKit

// Che cosa vuol dire «le due immagini coincidono», e perché non basta sottrarle.
//
// # Il difetto che l'informazione mutua evita
//
// La somma dei quadrati delle differenze presuppone che lo stesso tessuto abbia lo stesso numero
// nei due esami. Sulle CBCT è falso: il valore grigio dipende da apparecchio, FOV, filtrazione e
// posizione nell'immagine (Contratto 4), quindi la stessa corticale può stare a 1400 in un esame
// e a 1750 in quello dell'anno dopo, fatto su un'altra macchina. Minimizzando le differenze si
// ottiene una registrazione che sposta l'osso per far quadrare i numeri, e lo fa in silenzio.
//
// L'informazione mutua non chiede che i valori coincidano: chiede che **conoscere il valore in un
// esame riduca l'incertezza sul valore nell'altro**. Una relazione qualunque, purché stabile.
// Ed è esattamente ciò che lega due ricostruzioni dello stesso osso fatte da due macchine
// diverse. È la ragione per cui è la metrica standard della registrazione medica dal 1997, e la
// ragione per cui è quella che si usa qui per difetto.
//
// La correlazione resta disponibile per il caso opposto — stessa macchina, stesso protocollo,
// controllo a distanza di mesi — dove è più ripida e converge in meno passi.
//
// # Perché i campioni e non tutti i voxel
//
// Una CBCT `640³` ha 262 milioni di voxel e la discesa valuta la metrica una dozzina di volte per
// passo. Guardarli tutti significherebbe ore. Dodicimila campioni presi a caso su una distribuzione
// nota danno la stessa posizione a meno di una frazione di voxel, e li si estrae con un generatore
// deterministico: **la stessa coppia di esami dà sempre la stessa registrazione**, che è ciò che
// permette di riprovare un risultato dubbio e ritrovarlo identico invece di ottenerne un terzo.

/// Come si misura la somiglianza fra i due esami durante la registrazione.
public enum RegistrationMetricKind: String, CaseIterable, Hashable, Sendable, Codable,
    Identifiable
{
    /// Informazione mutua: regge il cambio di apparecchio, di FOV e di protocollo.
    case mutualInformation
    /// Correlazione dei valori: più ripida, ma pretende che i due esami siano scalati allo stesso modo.
    case crossCorrelation

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .mutualInformation: return "Informazione mutua"
        case .crossCorrelation: return "Correlazione"
        }
    }

    /// Che cosa presuppone, detto a chi deve sceglierla.
    public var explanation: String {
        switch self {
        case .mutualInformation:
            return """
                Non pretende che lo stesso tessuto abbia lo stesso valore grigio nei due esami: \
                basta che la relazione fra i due sia stabile. È la scelta giusta quando gli esami \
                vengono da apparecchi, FOV o protocolli diversi.
                """
        case .crossCorrelation:
            return """
                Presuppone che i due esami siano scalati allo stesso modo. Converge in meno passi \
                sullo stesso apparecchio e con lo stesso protocollo; altrove può allineare i \
                numeri invece dell'osso.
                """
        }
    }
}

/// I campioni del riferimento e la metrica valutata su di essi, per una data posa.
///
/// Non è pubblico: è il motore della discesa, e ciò che il chiamante deve poter dire sta tutto
/// in `RegistrationSettings`.
struct RegistrationCostFunction {

    /// Intervalli dell'istogramma congiunto. Quarantotto è il compromesso classico: abbastanza
    /// per distinguere aria, tessuto molle, spongiosa e corticale; abbastanza pochi perché
    /// dodicimila campioni non lascino l'istogramma quasi vuoto, che è la condizione in cui
    /// l'informazione mutua diventa rumore.
    static let binCount = 48

    /// Quanto pesa, nel costo, la parte di riferimento rimasta fuori dal campo del confronto.
    ///
    /// Serve contro una scorciatoia che la discesa troverebbe da sola: allontanare i due volumi
    /// finché si sovrappongono solo per un angolo di aria omogenea, dove qualunque metrica è
    /// contenta. Il peso è piccolo di proposito — la sovrapposizione va incoraggiata, non
    /// imposta — perché su due CBCT con FOV diversi una parte fuori campo è normale.
    static let overlapWeight = 0.25

    /// Sotto questa frazione di campioni utili la metrica non significa più niente.
    static let minimumValidFraction = 0.05

    /// Costo restituito quando i due volumi in pratica non si toccano. Finito di proposito:
    /// un infinito mandherebbe in NaN il gradiente alle differenze finite e fermerebbe la discesa
    /// proprio dove deve ripartire.
    static let unusableCost = 10.0

    let kind: RegistrationMetricKind
    /// Punti del riferimento, in millimetri Patient.
    let pointsMM: [Vec3]
    /// Valore grezzo del riferimento in quei punti.
    let referenceValues: [Double]
    /// Posizione continua di quei valori nell'istogramma, fra `0` e `binCount − 1`.
    let referenceBins: [Double]
    let followUp: Volume
    let followUpMinimum: Double
    let followUpBinScale: Double

    init(
        kind: RegistrationMetricKind,
        reference: Volume,
        followUp: Volume,
        sampleCount: Int,
        regionMM: BoxMM?,
        seed: UInt64
    ) throws {
        let geometry = reference.geometry
        let referenceRange = reference.rawValueRange
        let referenceSpan = Double(referenceRange.upperBound) - Double(referenceRange.lowerBound)
        let followUpRange = followUp.rawValueRange
        let followUpSpan = Double(followUpRange.upperBound) - Double(followUpRange.lowerBound)
        guard referenceSpan > 0, followUpSpan > 0 else {
            throw VolumeRegistrationError.constantVolume
        }

        let referenceScale = Double(Self.binCount - 1) / referenceSpan
        var random = SplitMix64(seed: seed)
        var points: [Vec3] = []
        var values: [Double] = []
        var bins: [Double] = []
        points.reserveCapacity(sampleCount)
        values.reserveCapacity(sampleCount)
        bins.reserveCapacity(sampleCount)

        // Estrazione con rifiuto: fuori dalla regione scelta il campione si butta. Il tetto ai
        // tentativi esiste perché una regione che non interseca il volume darebbe un ciclo
        // infinito invece di un errore, ed è l'errore che si vuole.
        let attemptLimit = max(sampleCount * 50, 10_000)
        var attempts = 0
        while points.count < sampleCount && attempts < attemptLimit {
            attempts += 1
            let i = min(Int(random.unit() * Double(geometry.columnCount)), geometry.columnCount - 1)
            let j = min(Int(random.unit() * Double(geometry.rowCount)), geometry.rowCount - 1)
            let k = min(Int(random.unit() * Double(geometry.sliceCount)), geometry.sliceCount - 1)
            guard let raw = reference.rawValue(i: i, j: j, k: k) else { continue }
            let point = geometry.patientPoint(i: i, j: j, k: k)
            if let regionMM, !regionMM.contains(point) { continue }
            let value = Double(raw)
            points.append(point)
            values.append(value)
            bins.append((value - Double(referenceRange.lowerBound)) * referenceScale)
        }

        guard points.count >= max(sampleCount / 4, 64) else {
            throw VolumeRegistrationError.regionTooSmall(samples: points.count)
        }

        self.kind = kind
        self.pointsMM = points
        self.referenceValues = values
        self.referenceBins = bins
        self.followUp = followUp
        self.followUpMinimum = Double(followUpRange.lowerBound)
        self.followUpBinScale = Double(Self.binCount - 1) / followUpSpan
    }

    /// Il costo da minimizzare per la posa indicata. Più piccolo, più i due esami coincidono.
    func cost(of pose: RigidPose) -> Double {
        let geometry = followUp.geometry
        let toVoxel = geometry.patientToVoxel.concatenating(pose.transform)
        let columns = geometry.columnCount
        let rows = geometry.rowCount
        let slices = geometry.sliceCount
        let maxI = Double(columns - 1)
        let maxJ = Double(rows - 1)
        let maxK = Double(slices - 1)
        let points = pointsMM
        let bins = Self.binCount

        return followUp.samples.withUnsafeBufferPointer { buffer -> Double in

            /// Valore grezzo del confronto sotto il campione indicato, interpolato. `nil` fuori campo.
            func sample(_ index: Int) -> Double? {
                let v = toVoxel.apply(toPoint: points[index])
                guard v.isFinite,
                    v.x >= 0, v.y >= 0, v.z >= 0,
                    v.x <= maxI, v.y <= maxJ, v.z <= maxK
                else { return nil }
                let fi = v.x.rounded(.down)
                let fj = v.y.rounded(.down)
                let fk = v.z.rounded(.down)
                let i0 = Int(fi)
                let j0 = Int(fj)
                let k0 = Int(fk)
                let i1 = min(i0 + 1, columns - 1)
                let j1 = min(j0 + 1, rows - 1)
                let k1 = min(k0 + 1, slices - 1)
                let tx = v.x - fi
                let ty = v.y - fj
                let tz = v.z - fk

                func at(_ i: Int, _ j: Int, _ k: Int) -> Double {
                    Double(buffer[(k * rows + j) * columns + i])
                }

                let c00 = at(i0, j0, k0) * (1 - tx) + at(i1, j0, k0) * tx
                let c10 = at(i0, j1, k0) * (1 - tx) + at(i1, j1, k0) * tx
                let c01 = at(i0, j0, k1) * (1 - tx) + at(i1, j0, k1) * tx
                let c11 = at(i0, j1, k1) * (1 - tx) + at(i1, j1, k1) * tx
                let c0 = c00 * (1 - ty) + c10 * ty
                let c1 = c01 * (1 - ty) + c11 * ty
                return c0 * (1 - tz) + c1 * tz
            }

            switch kind {
            case .mutualInformation:
                var joint = [Double](repeating: 0, count: bins * bins)
                var valid = 0
                for index in points.indices {
                    guard let moving = sample(index) else { continue }
                    valid += 1
                    let a = referenceBins[index]
                    let raw = (moving - followUpMinimum) * followUpBinScale
                    let b = Swift.min(Swift.max(raw, 0), Double(bins - 1))
                    let a0 = Int(a)
                    let b0 = Int(b)
                    let a1 = Swift.min(a0 + 1, bins - 1)
                    let b1 = Swift.min(b0 + 1, bins - 1)
                    let da = a - Double(a0)
                    let db = b - Double(b0)
                    // Ripartizione lineare sui due intervalli adiacenti in entrambe le direzioni:
                    // senza, l'istogramma salta di colpo quando un campione cambia intervallo e
                    // il gradiente alle differenze finite legge una scalinata invece di una china.
                    joint[a0 * bins + b0] += (1 - da) * (1 - db)
                    joint[a0 * bins + b1] += (1 - da) * db
                    joint[a1 * bins + b0] += da * (1 - db)
                    joint[a1 * bins + b1] += da * db
                }
                let fraction = Double(valid) / Double(points.count)
                guard fraction >= Self.minimumValidFraction else { return Self.unusableCost }

                let total = Double(valid)
                var referenceMarginal = [Double](repeating: 0, count: bins)
                var followUpMarginal = [Double](repeating: 0, count: bins)
                for a in 0..<bins {
                    for b in 0..<bins {
                        let weight = joint[a * bins + b]
                        guard weight > 0 else { continue }
                        referenceMarginal[a] += weight
                        followUpMarginal[b] += weight
                    }
                }
                var information = 0.0
                for a in 0..<bins where referenceMarginal[a] > 0 {
                    let pa = referenceMarginal[a] / total
                    for b in 0..<bins where followUpMarginal[b] > 0 {
                        let weight = joint[a * bins + b]
                        guard weight > 0 else { continue }
                        let pab = weight / total
                        let pb = followUpMarginal[b] / total
                        information += pab * Foundation.log(pab / (pa * pb))
                    }
                }
                return -information + Self.overlapWeight * (1 - fraction)

            case .crossCorrelation:
                var sumReference = 0.0
                var sumFollowUp = 0.0
                var sumReferenceSquared = 0.0
                var sumFollowUpSquared = 0.0
                var sumProduct = 0.0
                var valid = 0
                for index in points.indices {
                    guard let moving = sample(index) else { continue }
                    valid += 1
                    let fixed = referenceValues[index]
                    sumReference += fixed
                    sumFollowUp += moving
                    sumReferenceSquared += fixed * fixed
                    sumFollowUpSquared += moving * moving
                    sumProduct += fixed * moving
                }
                let fraction = Double(valid) / Double(points.count)
                guard fraction >= Self.minimumValidFraction else { return Self.unusableCost }

                let n = Double(valid)
                let covariance = n * sumProduct - sumReference * sumFollowUp
                let referenceSpread = n * sumReferenceSquared - sumReference * sumReference
                let followUpSpread = n * sumFollowUpSquared - sumFollowUp * sumFollowUp
                guard referenceSpread > 0, followUpSpread > 0 else { return Self.unusableCost }
                let correlation = covariance / (referenceSpread * followUpSpread).squareRoot()
                return 1 - correlation + Self.overlapWeight * (1 - fraction)
            }
        }
    }
}

/// Generatore pseudocasuale deterministico, portabile e senza stato globale.
///
/// `SystemRandomNumberGenerator` darebbe una registrazione diversa a ogni esecuzione sugli stessi
/// due esami. Non è un dettaglio da poco: chi rivede una registrazione dubbia e la rilancia deve
/// ritrovare *quella*, non una terza da confrontare con le prime due.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Un numero in `[0, 1)`.
    mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}
