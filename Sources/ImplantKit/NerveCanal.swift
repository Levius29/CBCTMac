import DICOMCore
import Foundation

// Tracciamento del canale alveolare inferiore.
//
// È la struttura da cui dipende l'allarme più importante di tutta la pianificazione: ledere il
// nervo alveolare inferiore produce un deficit sensitivo che può restare permanente. Il
// software non decide nulla al posto del clinico, ma la distanza fra impianto e canale è il
// numero che deve essere giusto, e ben visibile.
//
// Swift puro: la geometria si verifica senza GPU.

// MARK: - Lato

public enum MandibularSide: String, CaseIterable, Hashable, Sendable, Codable {
    case right
    case left

    public var localizedName: String {
        switch self {
        case .right: return "Destro"
        case .left: return "Sinistro"
        }
    }
}

// MARK: - Nodo

/// Un punto tracciato del canale, con il proprio raggio.
///
/// Il raggio è per nodo e non unico per tutto il canale perché il calibro cambia lungo il
/// percorso: più ampio in prossimità della spina di Spix, più stretto verso il forame
/// mentoniero. Usare un raggio costante sovrastimerebbe la distanza in un tratto e la
/// sottostimerebbe nell'altro.
public struct NerveNode: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var positionMM: Vec3
    public var radiusMM: Double

    /// Raggio predefinito. Il canale mandibolare misura tipicamente fra 2 e 3 mm di diametro.
    public static let defaultRadiusMM: Double = 1.4

    public init(id: UUID = UUID(), positionMM: Vec3, radiusMM: Double = defaultRadiusMM) {
        self.id = id
        self.positionMM = positionMM
        self.radiusMM = max(radiusMM, 0.1)
    }
}

/// Campione del canale dopo il ricampionamento.
public struct NerveSample: Hashable, Sendable {
    public let positionMM: Vec3
    public let radiusMM: Double
    public let tangent: Vec3
    public let arcLengthMM: Double
}

// MARK: - Canale

public struct NerveCanal: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    public var side: MandibularSide
    public var nodes: [NerveNode]
    /// Colore di visualizzazione, in `#RRGGBB`.
    public var colorHex: String
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        side: MandibularSide,
        nodes: [NerveNode] = [],
        colorHex: String = "#FF6B4A",
        isVisible: Bool = true
    ) {
        self.id = id
        self.side = side
        self.nodes = nodes
        self.colorHex = colorHex
        self.isVisible = isVisible
    }

    public var isUsable: Bool { nodes.count >= 2 }

    public var localizedName: String {
        "Canale mandibolare \(side.localizedName.lowercased())"
    }

    // MARK: Interpolazione

    /// Punto e raggio al parametro `t` in `[0, 1]`, con Catmull-Rom sui nodi.
    ///
    /// Il raggio si interpola linearmente e non con la spline: una spline su valori positivi
    /// può scendere sotto zero fra due nodi molto diversi, e un raggio negativo produrrebbe
    /// distanze senza senso proprio dove serve la massima affidabilità.
    public func sample(atParameter t: Double) -> (position: Vec3, radius: Double)? {
        guard nodes.count >= 2 else {
            return nodes.first.map { ($0.positionMM, $0.radiusMM) }
        }
        let segments = nodes.count - 1
        let clamped = min(max(t, 0), 1)
        let scaled = clamped * Double(segments)
        let index = min(Int(scaled), segments - 1)
        let local = scaled - Double(index)

        let p0 = nodes[max(index - 1, 0)].positionMM
        let p1 = nodes[index].positionMM
        let p2 = nodes[min(index + 1, nodes.count - 1)].positionMM
        let p3 = nodes[min(index + 2, nodes.count - 1)].positionMM

        let t2 = local * local
        let t3 = t2 * local
        let position =
            (p1 * 2.0
                + (p2 - p0) * local
                + (p0 * 2.0 - p1 * 5.0 + p2 * 4.0 - p3) * t2
                + (p1 * 3.0 - p0 - p2 * 3.0 + p3) * t3) * 0.5

        let r1 = nodes[index].radiusMM
        let r2 = nodes[min(index + 1, nodes.count - 1)].radiusMM
        let radius = r1 + (r2 - r1) * local

        return (position, radius)
    }

    /// Numero di suddivisioni per segmento usate nel ricampionamento.
    private static let subdivisionsPerSegment = 40

    /// Campiona il canale a passo d'arco approssimativamente costante.
    public func resampled(spacingMM: Double = 0.5) -> [NerveSample] {
        guard isUsable, spacingMM > 0 else { return [] }

        let segments = nodes.count - 1
        let total = segments * Self.subdivisionsPerSegment

        var positions: [Vec3] = []
        var radii: [Double] = []
        var cumulative: [Double] = []
        var length = 0.0
        var previous: Vec3?

        for step in 0...total {
            let t = Double(step) / Double(total)
            guard let point = sample(atParameter: t) else { continue }
            if let previous { length += point.position.distance(to: previous) }
            positions.append(point.position)
            radii.append(point.radius)
            cumulative.append(length)
            previous = point.position
        }

        guard let totalLength = cumulative.last, totalLength > 0 else { return [] }
        let count = max(2, Int((totalLength / spacingMM).rounded()) + 1)

        var samples: [NerveSample] = []
        samples.reserveCapacity(count)
        var searchIndex = 0

        for step in 0..<count {
            let target = totalLength * Double(step) / Double(count - 1)
            while searchIndex + 1 < cumulative.count, cumulative[searchIndex + 1] < target {
                searchIndex += 1
            }
            let next = min(searchIndex + 1, positions.count - 1)
            let span = cumulative[next] - cumulative[searchIndex]
            let local = span > 1e-12 ? (target - cumulative[searchIndex]) / span : 0

            let position = positions[searchIndex].lerp(to: positions[next], t: local)
            let radius = radii[searchIndex] + (radii[next] - radii[searchIndex]) * local
            let before = positions[max(searchIndex - 1, 0)]
            let after = positions[min(next + 1, positions.count - 1)]
            let tangent = (after - before).normalized ?? Vec3(1, 0, 0)

            samples.append(
                NerveSample(
                    positionMM: position, radiusMM: radius, tangent: tangent,
                    arcLengthMM: target))
        }
        return samples
    }

    public var lengthMM: Double {
        resampled(spacingMM: 1.0).last?.arcLengthMM ?? 0
    }

    // MARK: Distanza

    /// Distanza con segno da un punto alla **superficie** del canale.
    ///
    /// Negativa se il punto è dentro il canale. È la quantità che conta per la sicurezza: la
    /// distanza dall'asse sarebbe ottimistica di un raggio intero, cioè di quasi un millimetro
    /// e mezzo, su una soglia clinica che vale due millimetri.
    ///
    /// - Parameter resolutionMM: passo del campionamento del canale. Più fitto è più preciso e
    ///   più lento; mezzo millimetro è un compromesso adeguato a una soglia di due.
    public func signedDistance(from point: Vec3, resolutionMM: Double = 0.5) -> Double? {
        let samples = resampled(spacingMM: resolutionMM)
        guard !samples.isEmpty else { return nil }

        var best = Double.infinity
        for index in 0..<samples.count {
            let current = samples[index]

            if index + 1 < samples.count {
                // Distanza al segmento, non ai soli nodi: campionando ogni mezzo millimetro la
                // differenza è piccola, ma è gratis ed elimina l'errore a denti di sega.
                let next = samples[index + 1]
                let (distance, t) = distanceToSegment(
                    point: point, a: current.positionMM, b: next.positionMM)
                let radius = current.radiusMM + (next.radiusMM - current.radiusMM) * t
                best = min(best, distance - radius)
            } else {
                best = min(best, point.distance(to: current.positionMM) - current.radiusMM)
            }
        }
        return best
    }

    /// Punto del canale più vicino, utile per disegnare la linea di quota dell'allarme.
    public func closestPoint(to point: Vec3, resolutionMM: Double = 0.5) -> Vec3? {
        let samples = resampled(spacingMM: resolutionMM)
        guard !samples.isEmpty else { return nil }

        var best: Vec3?
        var bestDistance = Double.infinity
        for sample in samples {
            let distance = point.distance(to: sample.positionMM)
            if distance < bestDistance {
                bestDistance = distance
                best = sample.positionMM
            }
        }
        return best
    }

    // MARK: Modifica

    public mutating func addNode(_ node: NerveNode) {
        nodes.append(node)
    }

    public mutating func removeNode(id: UUID) {
        nodes.removeAll { $0.id == id }
    }

    public func nearestNode(to point: Vec3, toleranceMM: Double) -> NerveNode? {
        var best: NerveNode?
        var bestDistance = Double.infinity
        for node in nodes {
            let distance = node.positionMM.distance(to: point)
            if distance < bestDistance {
                bestDistance = distance
                best = node
            }
        }
        return bestDistance <= toleranceMM ? best : nil
    }

    /// Applica lo stesso raggio a tutti i nodi.
    public mutating func setUniformRadius(_ radiusMM: Double) {
        for index in nodes.indices {
            nodes[index].radiusMM = max(radiusMM, 0.1)
        }
    }
}

// MARK: - Utilità geometrica

/// Distanza da un punto a un segmento, e posizione normalizzata della proiezione.
func distanceToSegment(point: Vec3, a: Vec3, b: Vec3) -> (distance: Double, t: Double) {
    let ab = b - a
    let lengthSquared = ab.lengthSquared
    guard lengthSquared > 1e-12 else {
        return (point.distance(to: a), 0)
    }
    // Il parametro va limitato a [0,1]: senza il clamp la proiezione può cadere oltre gli
    // estremi e restituire una distanza minore di quella reale — cioè far sembrare sicuro un
    // impianto che non lo è.
    let t = min(max((point - a).dot(ab) / lengthSquared, 0), 1)
    let projection = a + ab * t
    return (point.distance(to: projection), t)
}
