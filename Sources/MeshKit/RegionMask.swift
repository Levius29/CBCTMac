import Foundation
import DICOMCore

/// Contrassegna i vertici da escludere dalla registrazione.
///
/// Gli artefatti metallici di corone e otturazioni sono la causa più comune di una cattiva
/// registrazione fra CBCT e scansione intraorale. L'utente li rimuove con un pennello prima
/// dell'allineamento; questa maschera conserva il risultato di quel gesto.
public struct RegionMask: Sendable {
    private var included: [Bool]

    /// Crea una maschera che include inizialmente tutti i vertici.
    public init(vertexCount: Int) {
        included = [Bool](repeating: true, count: Swift.max(0, vertexCount))
    }

    /// Esclude i vertici compresi nella sfera indicata.
    public mutating func exclude(
        sphereCentreMM: Vec3,
        radiusMM: Double,
        vertices: [Vec3]
    ) {
        setIncluded(
            false,
            sphereCentreMM: sphereCentreMM,
            radiusMM: radiusMM,
            vertices: vertices
        )
    }

    /// Include i vertici compresi nella sfera indicata.
    public mutating func include(
        sphereCentreMM: Vec3,
        radiusMM: Double,
        vertices: [Vec3]
    ) {
        setIncluded(
            true,
            sphereCentreMM: sphereCentreMM,
            radiusMM: radiusMM,
            vertices: vertices
        )
    }

    /// Esclude ogni vertice della maschera.
    public mutating func excludeAll() {
        var index = 0
        while index < included.count {
            included[index] = false
            index += 1
        }
    }

    /// Include ogni vertice della maschera.
    public mutating func includeAll() {
        var index = 0
        while index < included.count {
            included[index] = true
            index += 1
        }
    }

    /// Restituisce `false` anche per un indice fuori intervallo.
    public func isIncluded(_ index: Int) -> Bool {
        guard index >= 0, index < included.count else { return false }
        return included[index]
    }

    /// Estrae i punti inclusi senza leggere oltre l'array più corto.
    public func includedPoints(from vertices: [Vec3]) -> [Vec3] {
        var result = [Vec3]()
        result.reserveCapacity(Swift.min(includedCount, vertices.count))
        let count = Swift.min(included.count, vertices.count)
        var index = 0
        while index < count {
            if included[index] {
                result.append(vertices[index])
            }
            index += 1
        }
        return result
    }

    /// Numero di vertici attualmente inclusi.
    public var includedCount: Int {
        var count = 0
        for value: Bool in included {
            if value {
                count += 1
            }
        }
        return count
    }

    private mutating func setIncluded(
        _ value: Bool,
        sphereCentreMM: Vec3,
        radiusMM: Double,
        vertices: [Vec3]
    ) {
        guard sphereCentreMM.isFinite, radiusMM.isFinite, radiusMM >= 0 else { return }
        let radiusSquared = radiusMM * radiusMM
        guard radiusSquared.isFinite else { return }

        let count = Swift.min(included.count, vertices.count)
        var index = 0
        while index < count {
            let point = vertices[index]
            if point.isFinite {
                let distanceSquared = (point - sphereCentreMM).lengthSquared
                if distanceSquared.isFinite, distanceSquared <= radiusSquared {
                    included[index] = value
                }
            }
            index += 1
        }
    }
}
