import Foundation
import DICOMCore

/// Triangolo definito da tre indici nell'array dei vertici di una mesh.
public struct Triangle: Hashable, Sendable {
    public let a: Int
    public let b: Int
    public let c: Int

    public init(a: Int, b: Int, c: Int) {
        self.a = a
        self.b = b
        self.c = c
    }
}

/// Mesh triangolare espressa in millimetri.
public struct Mesh: Sendable {
    public var verticesMM: [Vec3]
    public var triangles: [Triangle]
    public var name: String

    public init(verticesMM: [Vec3], triangles: [Triangle], name: String) {
        self.verticesMM = verticesMM
        self.triangles = triangles
        self.name = name
    }

    /// Limiti assiali della mesh, oppure `nil` quando non esistono vertici.
    public var boundsMM: (min: Vec3, max: Vec3)? {
        guard let first = verticesMM.first else { return nil }

        var minimum = first
        var maximum = first
        var index = 1
        while index < verticesMM.count {
            let point = verticesMM[index]
            minimum.x = Swift.min(minimum.x, point.x)
            minimum.y = Swift.min(minimum.y, point.y)
            minimum.z = Swift.min(minimum.z, point.z)
            maximum.x = Swift.max(maximum.x, point.x)
            maximum.y = Swift.max(maximum.y, point.y)
            maximum.z = Swift.max(maximum.z, point.z)
            index += 1
        }
        return (minimum, maximum)
    }

    /// Centroide aritmetico dei vertici; per una mesh vuota restituisce zero.
    public var centroidMM: Vec3 {
        guard !verticesMM.isEmpty else { return .zero }

        var sum = Vec3.zero
        for point: Vec3 in verticesMM {
            sum += point
        }
        return sum / Double(verticesMM.count)
    }

    public var triangleCount: Int { triangles.count }
    public var vertexCount: Int { verticesMM.count }

    /// Normale unitaria del triangolo, oppure `nil` per indici non validi o area nulla.
    public func triangleNormal(_ triangle: Triangle) -> Vec3? {
        guard let points = trianglePoints(triangle) else { return nil }
        let cross = (points.b - points.a).cross(points.c - points.a)
        guard cross.isFinite else { return nil }
        return cross.normalized
    }

    /// Normali per vertice ottenute dalla media pesata per area dei triangoli adiacenti.
    public func vertexNormals() -> [Vec3] {
        var sums = [Vec3](repeating: .zero, count: verticesMM.count)

        for triangle: Triangle in triangles {
            guard let points = trianglePoints(triangle) else { continue }
            let cross = (points.b - points.a).cross(points.c - points.a)
            guard cross.isFinite, cross.lengthSquared > 0 else { continue }
            sums[triangle.a] += cross
            sums[triangle.b] += cross
            sums[triangle.c] += cross
        }

        var normals = [Vec3]()
        normals.reserveCapacity(sums.count)
        for sum: Vec3 in sums {
            if let normal = sum.normalized {
                normals.append(normal)
            } else {
                normals.append(.zero)
            }
        }
        return normals
    }

    /// Area complessiva dei triangoli validi, in millimetri quadrati.
    public func surfaceAreaMM2() -> Double {
        var area = 0.0
        for triangle: Triangle in triangles {
            guard let points = trianglePoints(triangle) else { continue }
            let cross = (points.b - points.a).cross(points.c - points.a)
            guard cross.isFinite else { continue }
            area += 0.5 * cross.length
        }
        return area
    }

    /// Volume con segno calcolato mediante il teorema della divergenza.
    ///
    /// Il risultato ha significato geometrico soltanto per una mesh chiusa e orientata in
    /// modo coerente. Su superfici aperte non rappresenta un volume fisico attendibile.
    public func signedVolumeMM3() -> Double {
        var volumeTimesSix = 0.0
        for triangle: Triangle in triangles {
            guard let points = trianglePoints(triangle) else { continue }
            guard points.a.isFinite, points.b.isFinite, points.c.isFinite else { continue }
            volumeTimesSix += points.a.dot(points.b.cross(points.c))
        }
        return volumeTimesSix / 6.0
    }

    /// Restituisce una copia trasformata senza modificare la connettività.
    public func transformed(by transform: Transform3D) -> Mesh {
        var transformedVertices = [Vec3]()
        transformedVertices.reserveCapacity(verticesMM.count)
        for point: Vec3 in verticesMM {
            transformedVertices.append(transform.apply(toPoint: point))
        }
        return Mesh(verticesMM: transformedVertices, triangles: triangles, name: name)
    }

    /// Unisce vertici distanti al massimo `toleranceMM` e reindicizza i triangoli.
    ///
    /// Gli scanner intraorali esportano spesso vertici non condivisi. La saldatura evita di
    /// moltiplicare inutilmente il lavoro e rende più stabili gli algoritmi successivi. I
    /// vertici non finiti creati dal codice applicativo vengono conservati come elementi
    /// distinti ma non entrano nella griglia: convertire NaN o infinito a `Int` causerebbe un
    /// trap di runtime.
    public func welded(toleranceMM: Double = 1e-4) -> Mesh {
        guard toleranceMM.isFinite, toleranceMM > 0 else { return self }
        let toleranceSquared = toleranceMM * toleranceMM
        guard toleranceSquared.isFinite else { return self }

        var weldedVertices = [Vec3]()
        weldedVertices.reserveCapacity(verticesMM.count)
        var oldToNew = [Int](repeating: -1, count: verticesMM.count)
        var grid: [WeldCell: [Int]] = [:]

        var oldIndex = 0
        while oldIndex < verticesMM.count {
            let point = verticesMM[oldIndex]
            guard let cell = weldCell(for: point, size: toleranceMM) else {
                oldToNew[oldIndex] = weldedVertices.count
                weldedVertices.append(point)
                oldIndex += 1
                continue
            }

            var representative: Int?
            var dx = -1
            while dx <= 1 {
                var dy = -1
                while dy <= 1 {
                    var dz = -1
                    while dz <= 1 {
                        if let neighbour = cell.offsetBy(dx: dx, dy: dy, dz: dz),
                           let candidates = grid[neighbour]
                        {
                            for candidate: Int in candidates {
                                let delta = weldedVertices[candidate] - point
                                let distanceSquared = delta.lengthSquared
                                if distanceSquared.isFinite, distanceSquared <= toleranceSquared {
                                    if let existing = representative {
                                        if candidate < existing {
                                            representative = candidate
                                        }
                                    } else {
                                        representative = candidate
                                    }
                                }
                            }
                        }
                        dz += 1
                    }
                    dy += 1
                }
                dx += 1
            }

            if let representative {
                oldToNew[oldIndex] = representative
            } else {
                let newIndex = weldedVertices.count
                weldedVertices.append(point)
                oldToNew[oldIndex] = newIndex
                var entries = grid[cell] ?? []
                entries.append(newIndex)
                grid[cell] = entries
            }
            oldIndex += 1
        }

        var weldedTriangles = [Triangle]()
        weldedTriangles.reserveCapacity(triangles.count)
        for triangle: Triangle in triangles {
            weldedTriangles.append(
                Triangle(
                    a: reindexed(triangle.a, using: oldToNew),
                    b: reindexed(triangle.b, using: oldToNew),
                    c: reindexed(triangle.c, using: oldToNew)
                )
            )
        }
        return Mesh(verticesMM: weldedVertices, triangles: weldedTriangles, name: name)
    }

    /// Elimina triangoli con indici ripetuti, non validi o area nulla.
    public func removingDegenerateTriangles() -> Mesh {
        var retained = [Triangle]()
        retained.reserveCapacity(triangles.count)
        for triangle: Triangle in triangles {
            guard triangle.a != triangle.b,
                  triangle.a != triangle.c,
                  triangle.b != triangle.c,
                  let points = trianglePoints(triangle)
            else { continue }

            let cross = (points.b - points.a).cross(points.c - points.a)
            guard cross.isFinite, cross.lengthSquared > 0 else { continue }
            retained.append(triangle)
        }
        return Mesh(verticesMM: verticesMM, triangles: retained, name: name)
    }

    private func trianglePoints(_ triangle: Triangle) -> (a: Vec3, b: Vec3, c: Vec3)? {
        guard triangle.a >= 0, triangle.a < verticesMM.count,
              triangle.b >= 0, triangle.b < verticesMM.count,
              triangle.c >= 0, triangle.c < verticesMM.count
        else { return nil }
        return (verticesMM[triangle.a], verticesMM[triangle.b], verticesMM[triangle.c])
    }

    private func reindexed(_ index: Int, using mapping: [Int]) -> Int {
        guard index >= 0, index < mapping.count, mapping[index] >= 0 else { return index }
        return mapping[index]
    }
}

private struct WeldCell: Hashable {
    let x: Int
    let y: Int
    let z: Int

    func offsetBy(dx: Int, dy: Int, dz: Int) -> WeldCell? {
        let nextX = x.addingReportingOverflow(dx)
        let nextY = y.addingReportingOverflow(dy)
        let nextZ = z.addingReportingOverflow(dz)
        guard !nextX.overflow, !nextY.overflow, !nextZ.overflow else { return nil }
        return WeldCell(x: nextX.partialValue, y: nextY.partialValue, z: nextZ.partialValue)
    }
}

private func weldCell(for point: Vec3, size: Double) -> WeldCell? {
    guard point.isFinite, size.isFinite, size > 0 else { return nil }
    let scaledX = point.x / size
    let scaledY = point.y / size
    let scaledZ = point.z / size
    guard scaledX.isFinite, scaledY.isFinite, scaledZ.isFinite else { return nil }
    guard let x = Int(exactly: Foundation.floor(scaledX)),
          let y = Int(exactly: Foundation.floor(scaledY)),
          let z = Int(exactly: Foundation.floor(scaledZ))
    else { return nil }
    return WeldCell(x: x, y: y, z: z)
}
