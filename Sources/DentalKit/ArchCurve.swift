import DICOMCore
import Foundation

// La curva dell'arcata.
//
// È il punto di partenza di tutta la Fase 2: il panorex è uno slab lungo questa curva, e le
// sezioni trasversali sono piani perpendicolari a essa. Una curva sbagliata non produce
// un'immagine sbagliata in modo evidente — produce un panorex che *sembra* corretto e in cui i
// denti risultano inclinati o sfocati, e sezioni che tagliano la cresta di sbieco. Per questo
// vale la pena curarne la matematica più di quanto la sua semplicità suggerisca.
//
// Swift puro, senza Metal: il ricampionamento a passo d'arco costante si testa senza GPU.

// MARK: - Campione

/// Un punto della curva ricampionata, con il riferimento locale.
public struct ArchSample: Hashable, Sendable {
    /// Posizione in millimetri Patient.
    public let positionMM: Vec3
    /// Versore tangente, nel verso di percorrenza della curva.
    public let tangent: Vec3
    /// Versore perpendicolare alla tangente nel piano orizzontale: è la direzione
    /// **vestibolo-linguale**, quella lungo cui si taglia una sezione trasversale.
    public let normal: Vec3
    /// Distanza percorsa lungo la curva dall'inizio, in millimetri.
    public let arcLengthMM: Double

    public init(positionMM: Vec3, tangent: Vec3, normal: Vec3, arcLengthMM: Double) {
        self.positionMM = positionMM
        self.tangent = tangent
        self.normal = normal
        self.arcLengthMM = arcLengthMM
    }
}

// MARK: - Curva

/// Spline Catmull-Rom passante per i punti di controllo.
///
/// Catmull-Rom e non Bézier perché **passa esattamente per i punti**: l'utente clicca sulla
/// cresta e la curva ci passa sopra, senza il gioco dei punti di controllo che una Bézier
/// impone. Su una curva che si aggiusta a mano guardando l'anatomia è la differenza fra uno
/// strumento diretto e uno da domare.
public struct ArchCurve: Hashable, Sendable, Codable {

    /// Punti di controllo in millimetri Patient, nell'ordine di percorrenza.
    public var controlPointsMM: [Vec3]

    /// Asse verticale del paziente, usato per ricavare la normale vestibolo-linguale.
    /// Coincide con `+S` salvo riorientamenti.
    public var upAxis: Vec3

    public init(controlPointsMM: [Vec3], upAxis: Vec3 = Vec3(0, 0, 1)) {
        self.controlPointsMM = controlPointsMM
        self.upAxis = upAxis.normalized ?? Vec3(0, 0, 1)
    }

    public var isUsable: Bool { controlPointsMM.count >= 2 }

    // MARK: Valutazione

    /// Punto della curva al parametro `t` in `[0, 1]`, distribuito **per segmenti** e non per
    /// lunghezza d'arco. Serve al ricampionamento, non all'uso diretto: per avere punti
    /// equidistanti usare `resampled(spacingMM:)`.
    public func point(atParameter t: Double) -> Vec3? {
        guard controlPointsMM.count >= 2 else { return controlPointsMM.first }
        let segmentCount = controlPointsMM.count - 1
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Double(segmentCount)
        let index = min(Int(scaled), segmentCount - 1)
        let local = scaled - Double(index)
        return interpolate(segment: index, t: local)
    }

    /// Catmull-Rom su un segmento, con i punti agli estremi duplicati per definire le
    /// tangenti iniziale e finale.
    private func interpolate(segment: Int, t: Double) -> Vec3 {
        let count = controlPointsMM.count
        let p0 = controlPointsMM[max(segment - 1, 0)]
        let p1 = controlPointsMM[segment]
        let p2 = controlPointsMM[min(segment + 1, count - 1)]
        let p3 = controlPointsMM[min(segment + 2, count - 1)]

        let t2 = t * t
        let t3 = t2 * t

        // Forma standard con tensione 0,5.
        let a = p1 * 2.0
        let b = (p2 - p0) * t
        let c = (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
        let d = (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3
        return (a + b + c + d) * 0.5
    }

    // MARK: Ricampionamento

    /// Densità del campionamento intermedio usato per misurare la lunghezza d'arco.
    ///
    /// La lunghezza di una Catmull-Rom non ha forma chiusa: si approssima con una poligonale
    /// fitta. Duecento suddivisioni per segmento portano l'errore ben sotto il decimo di
    /// millimetro su una curva d'arcata, che è meno di mezzo voxel.
    private static let subdivisionsPerSegment = 200

    /// Poligonale densa con le lunghezze cumulate.
    private func densePolyline() -> (points: [Vec3], cumulative: [Double]) {
        guard controlPointsMM.count >= 2 else {
            return (controlPointsMM, [0])
        }
        let segments = controlPointsMM.count - 1
        let total = segments * Self.subdivisionsPerSegment

        var points: [Vec3] = []
        var cumulative: [Double] = []
        points.reserveCapacity(total + 1)
        cumulative.reserveCapacity(total + 1)

        var length = 0.0
        var previous: Vec3?

        for step in 0...total {
            let t = Double(step) / Double(total)
            guard let p = point(atParameter: t) else { continue }
            if let previous {
                length += p.distance(to: previous)
            }
            points.append(p)
            cumulative.append(length)
            previous = p
        }
        return (points, cumulative)
    }

    /// Lunghezza totale della curva in millimetri.
    public var lengthMM: Double {
        densePolyline().cumulative.last ?? 0
    }

    /// Campiona la curva a **passo d'arco costante**.
    ///
    /// È il requisito che rende utilizzabile un panorex: se i campioni fossero equidistanti nel
    /// parametro invece che nell'arco, l'immagine risulterebbe compressa nelle curve e dilatata
    /// nei tratti diritti. Una misura presa in orizzontale sul panorex non significherebbe
    /// nulla — e sui panorex ricostruiti la si prende eccome.
    public func resampled(spacingMM: Double) -> [ArchSample] {
        guard isUsable, spacingMM > 0 else { return [] }
        let (points, cumulative) = densePolyline()
        guard let total = cumulative.last, total > 0 else { return [] }

        let count = max(2, Int((total / spacingMM).rounded()) + 1)
        return resampled(count: count, polyline: points, cumulative: cumulative, total: total)
    }

    /// Campiona la curva in esattamente `count` punti equidistanti.
    ///
    /// Usato dal panorex, che ha bisogno di un campione per colonna di pixel: così lo shader
    /// indicizza direttamente senza interpolare.
    public func resampled(count: Int) -> [ArchSample] {
        guard isUsable, count >= 2 else { return [] }
        let (points, cumulative) = densePolyline()
        guard let total = cumulative.last, total > 0 else { return [] }
        return resampled(count: count, polyline: points, cumulative: cumulative, total: total)
    }

    private func resampled(
        count: Int, polyline: [Vec3], cumulative: [Double], total: Double
    ) -> [ArchSample] {

        var samples: [ArchSample] = []
        samples.reserveCapacity(count)

        var searchIndex = 0

        for step in 0..<count {
            let targetLength = total * Double(step) / Double(count - 1)

            // Avanzamento monotòno lungo la poligonale: la ricerca non riparte da capo a ogni
            // campione, quindi il costo complessivo resta lineare invece che quadratico.
            while searchIndex + 1 < cumulative.count, cumulative[searchIndex + 1] < targetLength {
                searchIndex += 1
            }
            let next = min(searchIndex + 1, polyline.count - 1)

            let span = cumulative[next] - cumulative[searchIndex]
            let local = span > 1e-12 ? (targetLength - cumulative[searchIndex]) / span : 0
            let position = polyline[searchIndex].lerp(to: polyline[next], t: local)

            // Tangente per differenze centrali sulla poligonale: più stabile della derivata
            // analitica della spline vicino ai punti di controllo, dove la curvatura salta.
            let before = polyline[max(searchIndex - 1, 0)]
            let after = polyline[min(next + 1, polyline.count - 1)]
            let tangent = (after - before).normalized ?? Vec3(1, 0, 0)

            // Normale vestibolo-linguale: perpendicolare alla tangente e all'asse verticale.
            // Se la tangente fosse parallela alla verticale il prodotto degenererebbe, ma su
            // una curva d'arcata, che giace in un piano pressoché orizzontale, non accade.
            let normal = tangent.cross(upAxis).normalized ?? Vec3(0, 1, 0)

            samples.append(
                ArchSample(
                    positionMM: position,
                    tangent: tangent,
                    normal: normal,
                    arcLengthMM: targetLength))
        }

        return samples
    }

    // MARK: Modifica

    public mutating func insertControlPoint(_ point: Vec3, at index: Int) {
        let clamped = min(max(index, 0), controlPointsMM.count)
        controlPointsMM.insert(point, at: clamped)
    }

    public mutating func removeControlPoint(at index: Int) {
        guard controlPointsMM.indices.contains(index) else { return }
        // Sotto i due punti la curva non esiste più: si rifiuta invece di lasciare uno stato
        // in cui il panorex sparisce senza spiegazione.
        guard controlPointsMM.count > 2 else { return }
        controlPointsMM.remove(at: index)
    }

    /// Indice del punto di controllo più vicino, entro `toleranceMM`.
    public func nearestControlPoint(to point: Vec3, toleranceMM: Double) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, control) in controlPointsMM.enumerated() {
            let distance = control.distance(to: point)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= toleranceMM ? best : nil
    }

    /// Posizione lungo la curva del punto più vicino, in millimetri d'arco.
    /// Serve a capire quale sezione trasversale corrisponde a un clic sul panorex.
    public func arcLength(nearestTo point: Vec3) -> Double? {
        guard isUsable else { return nil }
        let (polyline, cumulative) = densePolyline()
        var bestIndex = 0
        var bestDistance = Double.infinity
        for (index, candidate) in polyline.enumerated() {
            let distance = candidate.distance(to: point)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return cumulative[bestIndex]
    }

    // MARK: Curva predefinita

    /// Arcata approssimata, come punto di partenza da correggere a mano.
    ///
    /// Una parabola centrata nel volume, dimensionata su un'arcata adulta media. Non pretende
    /// di essere corretta per il paziente: serve a evitare che l'utente debba costruire la
    /// curva da zero a ogni apertura, quando spostare cinque punti è molto più rapido.
    /// Il rilevamento automatico arriverà con la segmentazione della Fase 6.
    public static func defaultArch(for geometry: VolumeGeometry) -> ArchCurve {
        let centre = geometry.centerMM
        let size = geometry.physicalSizeMM

        // Semilarghezza dell'arcata: circa metà del campo, limitata a valori plausibili per
        // una mandibola adulta.
        let halfWidth = min(max(size.x * 0.32, 18.0), 32.0)
        let depth = min(max(size.y * 0.30, 16.0), 30.0)

        // Nove punti su una parabola aperta verso il posteriore: l'apice sta sugli incisivi,
        // in avanti, e i rami vanno indietro verso i molari.
        var points: [Vec3] = []
        let count = 9
        for index in 0..<count {
            let t = Double(index) / Double(count - 1) * 2.0 - 1.0  // da −1 a +1
            let x = centre.x + t * halfWidth
            let y = centre.y - depth * (1.0 - t * t) + depth * 0.5
            points.append(Vec3(x, y, centre.z))
        }

        return ArchCurve(controlPointsMM: points)
    }
}
