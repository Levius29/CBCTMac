import Foundation
import DICOMCore

/// Opzioni dell'affinamento Iterative Closest Point.
public struct ICPOptions: Sendable {
    public var maxIterations: Int
    public var toleranceMM: Double
    public var maxCorrespondenceDistanceMM: Double
    /// Frazione delle corrispondenze migliori mantenuta a ogni iterazione.
    public var trimFraction: Double
    public var sampleLimit: Int

    public init() {
        maxIterations = 50
        toleranceMM = 1e-4
        maxCorrespondenceDistanceMM = 2.0
        trimFraction = 0.8
        sampleLimit = 5_000
    }
}

/// Affinamento rigido ICP fra due nuvole di punti.
public enum ICP: Sendable {
    /// Affina `initial` in modo che `source` coincida con `target`.
    ///
    /// ICP converge verso il minimo locale più vicino e non registra due superfici da zero:
    /// la trasformazione iniziale deve essere già vicina al risultato, normalmente grazie
    /// alla registrazione di coppie di punti. Nel risultato `pointCount` è il numero di
    /// corrispondenze sopravvissute al cutoff e al trimming nell'ultima iterazione, non il
    /// numero totale di vertici. Raggiungere `maxIterations` restituisce un risultato utile
    /// con `converged == false`; RMS e trasformazione restano così disponibili al chiamante.
    public static func refine(
        source: [Vec3],
        target: [Vec3],
        initial: Transform3D,
        options: ICPOptions
    ) throws -> RegistrationResult {
        guard !source.isEmpty, !target.isEmpty else {
            throw RegistrationError.emptyMesh
        }
        try validate(options: options, initial: initial)

        let maximumDistanceSquared = options.maxCorrespondenceDistanceMM
            * options.maxCorrespondenceDistanceMM
        guard maximumDistanceSquared.isFinite else {
            throw RegistrationError.degenerateConfiguration(
                detail: "la distanza massima produce un quadrato non finito"
            )
        }

        var finiteSource = [Vec3]()
        finiteSource.reserveCapacity(Swift.min(source.count, options.sampleLimit))
        for point: Vec3 in source {
            if point.isFinite {
                finiteSource.append(point)
            }
        }
        let sampledSource = evenlySample(points: finiteSource, limit: options.sampleLimit)
        let grid = ICPSpatialGrid(
            points: target,
            cellSize: options.maxCorrespondenceDistanceMM
        )

        var current = initial
        var convergenceTracker = ICPConvergenceTracker()
        var lastRMS = Double.infinity
        var lastMaximumError = Double.infinity
        var lastPointCount = 0
        var completedIterations = 0

        var iteration = 0
        while iteration < options.maxIterations {
            var correspondences = [ICPCorrespondence]()
            correspondences.reserveCapacity(sampledSource.count)

            var sourceOrder = 0
            while sourceOrder < sampledSource.count {
                let transformed = current.apply(toPoint: sampledSource[sourceOrder])
                if transformed.isFinite,
                   let nearest = grid.nearest(
                       to: transformed,
                       maximumDistanceSquared: maximumDistanceSquared
                   )
                {
                    correspondences.append(
                        ICPCorrespondence(
                            source: transformed,
                            target: nearest.point,
                            distanceSquared: nearest.distanceSquared,
                            sourceOrder: sourceOrder
                        )
                    )
                }
                sourceOrder += 1
            }

            correspondences.sort {
                (lhs: ICPCorrespondence, rhs: ICPCorrespondence) -> Bool in
                if lhs.distanceSquared == rhs.distanceSquared {
                    return lhs.sourceOrder < rhs.sourceOrder
                }
                return lhs.distanceSquared < rhs.distanceSquared
            }

            let rawRetainedCount = Foundation.floor(
                Double(correspondences.count) * options.trimFraction
            )
            guard rawRetainedCount.isFinite,
                  let retainedCount = Int(exactly: rawRetainedCount),
                  retainedCount <= correspondences.count
            else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "conteggio delle corrispondenze trimmed non valido"
                )
            }

            if retainedCount < 3 {
                let currentRMS = correspondenceRMS(
                    correspondences,
                    retainedCount: retainedCount
                )
                throw RegistrationError.didNotConverge(
                    iterations: iteration + 1,
                    rmsErrorMM: convergenceTracker.previousRMS ?? currentRMS
                )
            }

            // Il trimming è essenziale sui dati dentali: la scansione intraorale contiene
            // soprattutto corone, mentre la superficie CBCT include anche osso, tessuti e
            // artefatti metallici senza controparte. Scartare le corrispondenze peggiori evita
            // che quelle regioni trascinino l'allineamento lontano dai denti.
            var registrationSource = [Vec3]()
            var registrationTarget = [Vec3]()
            registrationSource.reserveCapacity(retainedCount)
            registrationTarget.reserveCapacity(retainedCount)
            var retainedIndex = 0
            while retainedIndex < retainedCount {
                registrationSource.append(correspondences[retainedIndex].source)
                registrationTarget.append(correspondences[retainedIndex].target)
                retainedIndex += 1
            }

            // Un insieme trimmed può diventare collineare. In quel caso l'errore specifico
            // di Horn deve propagare invariato: non è la stessa cosa di una lenta convergenza.
            let alignment = try PointRegistration.align(
                source: registrationSource,
                target: registrationTarget
            )
            current = alignment.transform.concatenating(current)
            lastRMS = alignment.rmsErrorMM
            lastMaximumError = alignment.maxErrorMM
            lastPointCount = retainedCount
            completedIterations = iteration + 1

            if try convergenceTracker.record(
                rmsErrorMM: alignment.rmsErrorMM,
                toleranceMM: options.toleranceMM,
                iteration: completedIterations
            ) {
                return RegistrationResult(
                    transform: current,
                    rmsErrorMM: alignment.rmsErrorMM,
                    maxErrorMM: alignment.maxErrorMM,
                    pointCount: retainedCount,
                    iterations: completedIterations,
                    converged: true
                )
            }
            iteration += 1
        }

        return RegistrationResult(
            transform: current,
            rmsErrorMM: lastRMS,
            maxErrorMM: lastMaximumError,
            pointCount: lastPointCount,
            iterations: completedIterations,
            converged: false
        )
    }

    private static func validate(options: ICPOptions, initial: Transform3D) throws {
        guard options.maxIterations > 0 else {
            throw RegistrationError.degenerateConfiguration(
                detail: "maxIterations deve essere positivo"
            )
        }
        guard options.toleranceMM.isFinite, options.toleranceMM >= 0 else {
            throw RegistrationError.degenerateConfiguration(
                detail: "toleranceMM deve essere finita e non negativa"
            )
        }
        guard options.maxCorrespondenceDistanceMM.isFinite,
              options.maxCorrespondenceDistanceMM > 0
        else {
            throw RegistrationError.degenerateConfiguration(
                detail: "maxCorrespondenceDistanceMM deve essere finita e positiva"
            )
        }
        guard options.trimFraction.isFinite,
              options.trimFraction > 0,
              options.trimFraction <= 1
        else {
            throw RegistrationError.degenerateConfiguration(
                detail: "trimFraction deve appartenere a (0, 1]"
            )
        }
        guard options.sampleLimit >= 3 else {
            throw RegistrationError.degenerateConfiguration(
                detail: "sampleLimit deve essere almeno 3"
            )
        }
        guard initial.columnX.isFinite,
              initial.columnY.isFinite,
              initial.columnZ.isFinite,
              initial.origin.isFinite,
              initial.determinant.isFinite,
              initial.determinant > 0
        else {
            throw RegistrationError.degenerateConfiguration(
                detail: "la trasformazione iniziale non è finita o conserva una riflessione"
            )
        }
    }

    private static func evenlySample(points: [Vec3], limit: Int) -> [Vec3] {
        guard points.count > limit else { return points }

        var result = [Vec3]()
        result.reserveCapacity(limit)
        let baseStep = points.count / limit
        let remainder = points.count % limit
        var pointIndex = 0
        var remainderAccumulator = 0
        var sampleIndex = 0
        while sampleIndex < limit, pointIndex < points.count {
            result.append(points[pointIndex])

            // Forma incrementale di floor(k * count / limit): evita che il prodotto di due
            // `Int` grandi trabocchi prima della divisione.
            let room = limit - remainder
            if remainder > 0, remainderAccumulator >= room {
                remainderAccumulator -= room
                pointIndex += baseStep + 1
            } else {
                remainderAccumulator += remainder
                pointIndex += baseStep
            }
            sampleIndex += 1
        }
        return result
    }

    private static func correspondenceRMS(
        _ correspondences: [ICPCorrespondence],
        retainedCount: Int
    ) -> Double {
        guard retainedCount > 0, retainedCount <= correspondences.count else {
            return .infinity
        }
        var sum = 0.0
        var index = 0
        while index < retainedCount {
            sum += correspondences[index].distanceSquared
            if !sum.isFinite { return .infinity }
            index += 1
        }
        return Foundation.sqrt(sum / Double(retainedCount))
    }
}

struct ICPConvergenceTracker: Sendable {
    private(set) var previousRMS: Double?
    private var consecutiveIncreases: Int

    init() {
        previousRMS = nil
        consecutiveIncreases = 0
    }

    mutating func record(
        rmsErrorMM: Double,
        toleranceMM: Double,
        iteration: Int
    ) throws -> Bool {
        if rmsErrorMM <= toleranceMM {
            previousRMS = rmsErrorMM
            return true
        }

        if let previous = previousRMS {
            if rmsErrorMM > previous {
                consecutiveIncreases += 1
                if consecutiveIncreases >= 5 {
                    throw RegistrationError.didNotConverge(
                        iterations: iteration,
                        rmsErrorMM: rmsErrorMM
                    )
                }
            } else {
                consecutiveIncreases = 0
                let improvement = previous - rmsErrorMM
                if improvement < toleranceMM {
                    previousRMS = rmsErrorMM
                    return true
                }
            }
        }
        previousRMS = rmsErrorMM
        return false
    }
}

private struct ICPCorrespondence {
    let source: Vec3
    let target: Vec3
    let distanceSquared: Double
    let sourceOrder: Int
}

private struct ICPGridCell: Hashable {
    let x: Int
    let y: Int
    let z: Int

    func offsetBy(dx: Int, dy: Int, dz: Int) -> ICPGridCell? {
        let nextX = x.addingReportingOverflow(dx)
        let nextY = y.addingReportingOverflow(dy)
        let nextZ = z.addingReportingOverflow(dz)
        guard !nextX.overflow, !nextY.overflow, !nextZ.overflow else { return nil }
        return ICPGridCell(
            x: nextX.partialValue,
            y: nextY.partialValue,
            z: nextZ.partialValue
        )
    }
}

private struct ICPNearestPoint {
    let point: Vec3
    let distanceSquared: Double
}

private struct ICPSpatialGrid {
    let points: [Vec3]
    let cellSize: Double
    let cells: [ICPGridCell: [Int]]

    init(points: [Vec3], cellSize: Double) {
        self.points = points
        self.cellSize = cellSize
        var builtCells: [ICPGridCell: [Int]] = [:]
        var index = 0
        while index < points.count {
            if let cell = ICPSpatialGrid.cell(for: points[index], size: cellSize) {
                var entries = builtCells[cell] ?? []
                entries.append(index)
                builtCells[cell] = entries
            }
            index += 1
        }
        cells = builtCells
    }

    func nearest(to query: Vec3, maximumDistanceSquared: Double) -> ICPNearestPoint? {
        guard query.isFinite,
              maximumDistanceSquared.isFinite,
              maximumDistanceSquared >= 0,
              let centre = ICPSpatialGrid.cell(for: query, size: cellSize)
        else { return nil }

        var bestIndex: Int?
        var bestDistanceSquared = maximumDistanceSquared
        var dx = -1
        while dx <= 1 {
            var dy = -1
            while dy <= 1 {
                var dz = -1
                while dz <= 1 {
                    if let neighbour = centre.offsetBy(dx: dx, dy: dy, dz: dz),
                       let candidates = cells[neighbour]
                    {
                        for candidateIndex: Int in candidates {
                            guard candidateIndex >= 0, candidateIndex < points.count else { continue }
                            let delta = points[candidateIndex] - query
                            let distanceSquared = delta.lengthSquared
                            guard distanceSquared.isFinite,
                                  distanceSquared <= maximumDistanceSquared
                            else { continue }

                            if let existingIndex = bestIndex {
                                if distanceSquared < bestDistanceSquared
                                    || (distanceSquared == bestDistanceSquared
                                        && candidateIndex < existingIndex)
                                {
                                    bestIndex = candidateIndex
                                    bestDistanceSquared = distanceSquared
                                }
                            } else {
                                bestIndex = candidateIndex
                                bestDistanceSquared = distanceSquared
                            }
                        }
                    }
                    dz += 1
                }
                dy += 1
            }
            dx += 1
        }

        guard let resolvedIndex = bestIndex else { return nil }
        return ICPNearestPoint(
            point: points[resolvedIndex],
            distanceSquared: bestDistanceSquared
        )
    }

    private static func cell(for point: Vec3, size: Double) -> ICPGridCell? {
        // Questa guardia resta anche se gli importer rifiutano NaN e infinito: l'API accetta
        // nuvole costruite in memoria, e `Int(Double.nan)` causa un trap anziché restituire nil.
        guard point.isFinite, size.isFinite, size > 0 else { return nil }
        let scaledX = point.x / size
        let scaledY = point.y / size
        let scaledZ = point.z / size
        guard scaledX.isFinite, scaledY.isFinite, scaledZ.isFinite else { return nil }
        guard let x = Int(exactly: Foundation.floor(scaledX)),
              let y = Int(exactly: Foundation.floor(scaledY)),
              let z = Int(exactly: Foundation.floor(scaledZ))
        else { return nil }
        return ICPGridCell(x: x, y: y, z: z)
    }
}
