import Foundation
import DICOMCore
import MeshKit

/// Errori nella costruzione del campo di distanza da una mesh.
public enum MeshDistanceFieldError: Error, Hashable, Sendable, LocalizedError {
    case emptyMesh
    case invalidMaximumDistance(Double)
    case noUsableTriangles
    case spatialIndexTooLarge(triangleIndex: Int, cellCount: Int)
    case spatialQueryOutOfRange(point: Vec3)

    public var errorDescription: String? {
        switch self {
        case .emptyMesh:
            return "La mesh da convertire in campo di distanza è vuota."
        case .invalidMaximumDistance(let distance):
            return "La distanza massima del campo non è valida: \(distance) mm."
        case .noUsableTriangles:
            return "La mesh non contiene triangoli finiti e non degeneri utilizzabili."
        case .spatialIndexTooLarge(let index, let count):
            return "Il triangolo \(index) richiede \(count) celle nell'indice spaziale; "
                + "la mesh o la distanza massima non sono adatte a una griglia sicura."
        case .spatialQueryOutOfRange(let point):
            return "Il punto (\(point.x), \(point.y), \(point.z)) mm non è rappresentabile "
                + "nell'indice spaziale della mesh."
        }
    }
}

/// Costruzione di un campo di distanza dalla superficie di una mesh.
public enum MeshDistanceField: Sendable {
    /// Campo di distanza con segno ricavato dalle normali, adatto a superfici aperte.
    ///
    /// Una scansione intraorale è una superficie aperta: non possiede un “dentro” globale, per
    /// cui ray parity e winding number non hanno significato. Il segno indica invece il lato
    /// della normale del triangolo più vicino, che è proprio la convenzione necessaria per
    /// costruire una dima dal lato di approccio noto. Vicino al bordo della scansione questo
    /// segno cambia in modo discontinuo; l'impronta deve restarne distante e `GuideBuilder`
    /// verifica esplicitamente tale margine.
    public static func build(
        from mesh: Mesh,
        grid: FieldGrid,
        maxDistanceMM: Double
    ) throws -> ScalarField {
        guard !mesh.verticesMM.isEmpty, !mesh.triangles.isEmpty else {
            throw MeshDistanceFieldError.emptyMesh
        }
        guard maxDistanceMM.isFinite, maxDistanceMM > 0 else {
            throw MeshDistanceFieldError.invalidMaximumDistance(maxDistanceMM)
        }

        var records: [DistanceTriangle] = []
        records.reserveCapacity(mesh.triangles.count)
        for triangle in mesh.triangles {
            guard triangle.a >= 0, triangle.a < mesh.verticesMM.count,
                  triangle.b >= 0, triangle.b < mesh.verticesMM.count,
                  triangle.c >= 0, triangle.c < mesh.verticesMM.count
            else { continue }
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            guard a.isFinite, b.isFinite, c.isFinite else { continue }
            let cross = (b - a).cross(c - a)
            guard let normal = cross.normalized else { continue }
            records.append(DistanceTriangle(a: a, b: b, c: c, normal: normal))
        }
        guard !records.isEmpty else { throw MeshDistanceFieldError.noUsableTriangles }

        var buckets: [DistanceCell: [Int]] = [:]
        for index in records.indices {
            try insert(
                triangleIndex: index,
                triangle: records[index],
                cellSize: maxDistanceMM,
                buckets: &buckets)
        }
        let bucketBounds = DistanceCellBounds(cells: buckets.keys)

        var field = ScalarField(grid: grid, initialValue: maxDistanceMM)
        var visited = [Int](repeating: -1, count: records.count)
        var serial = 0

        for z in 0..<grid.countZ {
            for y in 0..<grid.countY {
                for x in 0..<grid.countX {
                    let point = grid.position(x: x, y: y, z: z)
                    guard let cell = DistanceCell(point: point, size: maxDistanceMM) else {
                        throw MeshDistanceFieldError.spatialQueryOutOfRange(point: point)
                    }
                    serial += 1
                    var nearestDistanceSquared = Double.infinity
                    var nearestSignedSide = 1.0

                    if let bucketBounds {
                        try searchBuckets(
                            point: point,
                            cell: cell,
                            bounds: bucketBounds,
                            cellSize: maxDistanceMM,
                            buckets: buckets,
                            serial: serial,
                            records: records,
                            visited: &visited,
                            nearestDistanceSquared: &nearestDistanceSquared,
                            nearestSignedSide: &nearestSignedSide)
                    }

                    if nearestDistanceSquared.isFinite {
                        let distance = min(nearestDistanceSquared.squareRoot(), maxDistanceMM)
                        field.setValue(nearestSignedSide * distance, x: x, y: y, z: z)
                    }
                }
            }
        }
        return field
    }

    /// Cerca per gusci cubici finché la distanza trovata è minore del limite geometrico
    /// di qualunque cella non ancora visitata.
    ///
    /// I soli 27 vicini bastano per il valore assoluto troncato, ma non per il segno: un punto
    /// lontano sul lato negativo resterebbe al valore iniziale positivo. L'espansione conserva
    /// l'accelerazione dell'hash e determina anche il triangolo realmente più vicino.
    private static func searchBuckets(
        point: Vec3,
        cell: DistanceCell,
        bounds: DistanceCellBounds,
        cellSize: Double,
        buckets: [DistanceCell: [Int]],
        serial: Int,
        records: [DistanceTriangle],
        visited: inout [Int],
        nearestDistanceSquared: inout Double,
        nearestSignedSide: inout Double
    ) throws {
        guard let minimumRing = bounds.minimumRing(from: cell),
              let maximumRing = bounds.maximumRing(from: cell)
        else {
            // Un confronto globale per ogni campione renderebbe impraticabile la griglia. Un
            // input oltre gli offset rappresentabili viene rifiutato con un errore esplicito.
            throw MeshDistanceFieldError.spatialQueryOutOfRange(point: point)
        }
        guard minimumRing <= maximumRing else { return }

        var radius = minimumRing
        while radius <= maximumRing {
            testBucketShell(
                point: point,
                cell: cell,
                radius: radius,
                buckets: buckets,
                serial: serial,
                records: records,
                visited: &visited,
                nearestDistanceSquared: &nearestDistanceSquared,
                nearestSignedSide: &nearestSignedSide)

            let lowerBound = Double(radius) * cellSize
            if nearestDistanceSquared.isFinite,
               lowerBound.isFinite,
               nearestDistanceSquared <= lowerBound * lowerBound
            {
                return
            }
            if radius == maximumRing { return }
            let next = radius.addingReportingOverflow(1)
            guard !next.overflow else { return }
            radius = next.partialValue
        }
    }

    /// Visita una sola volta le sei facce del guscio di raggio Chebyshev indicato.
    private static func testBucketShell(
        point: Vec3,
        cell: DistanceCell,
        radius: Int,
        buckets: [DistanceCell: [Int]],
        serial: Int,
        records: [DistanceTriangle],
        visited: inout [Int],
        nearestDistanceSquared: inout Double,
        nearestSignedSide: inout Double
    ) {
        if radius == 0 {
            testBucket(
                point: point, cell: cell, buckets: buckets, serial: serial,
                records: records, visited: &visited,
                nearestDistanceSquared: &nearestDistanceSquared,
                nearestSignedSide: &nearestSignedSide)
            return
        }

        let negative = -radius
        for dy in negative...radius {
            for dx in negative...radius {
                testOffsetBucket(
                    point: point, base: cell, dx: dx, dy: dy, dz: negative,
                    buckets: buckets, serial: serial, records: records, visited: &visited,
                    nearestDistanceSquared: &nearestDistanceSquared,
                    nearestSignedSide: &nearestSignedSide)
                testOffsetBucket(
                    point: point, base: cell, dx: dx, dy: dy, dz: radius,
                    buckets: buckets, serial: serial, records: records, visited: &visited,
                    nearestDistanceSquared: &nearestDistanceSquared,
                    nearestSignedSide: &nearestSignedSide)
            }
        }

        if radius > 1 {
            let innerLow = negative + 1
            let innerHigh = radius - 1
            for dz in innerLow...innerHigh {
                for dx in negative...radius {
                    testOffsetBucket(
                        point: point, base: cell, dx: dx, dy: negative, dz: dz,
                        buckets: buckets, serial: serial, records: records, visited: &visited,
                        nearestDistanceSquared: &nearestDistanceSquared,
                        nearestSignedSide: &nearestSignedSide)
                    testOffsetBucket(
                        point: point, base: cell, dx: dx, dy: radius, dz: dz,
                        buckets: buckets, serial: serial, records: records, visited: &visited,
                        nearestDistanceSquared: &nearestDistanceSquared,
                        nearestSignedSide: &nearestSignedSide)
                }
                for dy in innerLow...innerHigh {
                    testOffsetBucket(
                        point: point, base: cell, dx: negative, dy: dy, dz: dz,
                        buckets: buckets, serial: serial, records: records, visited: &visited,
                        nearestDistanceSquared: &nearestDistanceSquared,
                        nearestSignedSide: &nearestSignedSide)
                    testOffsetBucket(
                        point: point, base: cell, dx: radius, dy: dy, dz: dz,
                        buckets: buckets, serial: serial, records: records, visited: &visited,
                        nearestDistanceSquared: &nearestDistanceSquared,
                        nearestSignedSide: &nearestSignedSide)
                }
            }
        } else {
            // Per raggio 1 il piano interno contiene la sola coordinata zero.
            for dx in negative...radius {
                testOffsetBucket(
                    point: point, base: cell, dx: dx, dy: negative, dz: 0,
                    buckets: buckets, serial: serial, records: records, visited: &visited,
                    nearestDistanceSquared: &nearestDistanceSquared,
                    nearestSignedSide: &nearestSignedSide)
                testOffsetBucket(
                    point: point, base: cell, dx: dx, dy: radius, dz: 0,
                    buckets: buckets, serial: serial, records: records, visited: &visited,
                    nearestDistanceSquared: &nearestDistanceSquared,
                    nearestSignedSide: &nearestSignedSide)
            }
            testOffsetBucket(
                point: point, base: cell, dx: negative, dy: 0, dz: 0,
                buckets: buckets, serial: serial, records: records, visited: &visited,
                nearestDistanceSquared: &nearestDistanceSquared,
                nearestSignedSide: &nearestSignedSide)
            testOffsetBucket(
                point: point, base: cell, dx: radius, dy: 0, dz: 0,
                buckets: buckets, serial: serial, records: records, visited: &visited,
                nearestDistanceSquared: &nearestDistanceSquared,
                nearestSignedSide: &nearestSignedSide)
        }
    }

    private static func testOffsetBucket(
        point: Vec3,
        base: DistanceCell,
        dx: Int,
        dy: Int,
        dz: Int,
        buckets: [DistanceCell: [Int]],
        serial: Int,
        records: [DistanceTriangle],
        visited: inout [Int],
        nearestDistanceSquared: inout Double,
        nearestSignedSide: inout Double
    ) {
        guard let cell = base.offset(dx: dx, dy: dy, dz: dz) else { return }
        testBucket(
            point: point, cell: cell, buckets: buckets, serial: serial,
            records: records, visited: &visited,
            nearestDistanceSquared: &nearestDistanceSquared,
            nearestSignedSide: &nearestSignedSide)
    }

    private static func testBucket(
        point: Vec3,
        cell: DistanceCell,
        buckets: [DistanceCell: [Int]],
        serial: Int,
        records: [DistanceTriangle],
        visited: inout [Int],
        nearestDistanceSquared: inout Double,
        nearestSignedSide: inout Double
    ) {
        guard let candidates = buckets[cell] else { return }
        for triangleIndex in candidates {
            test(
                point: point, triangleIndex: triangleIndex, serial: serial,
                records: records, visited: &visited,
                nearestDistanceSquared: &nearestDistanceSquared,
                nearestSignedSide: &nearestSignedSide)
        }
    }

    private static func test(
        point: Vec3,
        triangleIndex: Int,
        serial: Int,
        records: [DistanceTriangle],
        visited: inout [Int],
        nearestDistanceSquared: inout Double,
        nearestSignedSide: inout Double
    ) {
        guard triangleIndex >= 0, triangleIndex < records.count,
              visited[triangleIndex] != serial
        else { return }
        visited[triangleIndex] = serial
        let triangle = records[triangleIndex]
        let closest = closestPoint(point, triangle: triangle)
        let delta = point - closest
        let distanceSquared = delta.lengthSquared
        guard distanceSquared.isFinite, distanceSquared < nearestDistanceSquared else { return }
        nearestDistanceSquared = distanceSquared
        nearestSignedSide = delta.dot(triangle.normal) >= 0 ? 1 : -1
    }

    /// Calcolo esatto del punto più vicino: distingue interno, tre spigoli e tre vertici.
    private static func closestPoint(_ point: Vec3, triangle: DistanceTriangle) -> Vec3 {
        let ab = triangle.b - triangle.a
        let ac = triangle.c - triangle.a
        let ap = point - triangle.a
        let d1 = ab.dot(ap)
        let d2 = ac.dot(ap)
        if d1 <= 0, d2 <= 0 { return triangle.a }

        let bp = point - triangle.b
        let d3 = ab.dot(bp)
        let d4 = ac.dot(bp)
        if d3 >= 0, d4 <= d3 { return triangle.b }

        let vc = d1 * d4 - d3 * d2
        if vc <= 0, d1 >= 0, d3 <= 0 {
            let v = d1 / (d1 - d3)
            return triangle.a + ab * v
        }

        let cp = point - triangle.c
        let d5 = ab.dot(cp)
        let d6 = ac.dot(cp)
        if d6 >= 0, d5 <= d6 { return triangle.c }

        let vb = d5 * d2 - d1 * d6
        if vb <= 0, d2 >= 0, d6 <= 0 {
            let w = d2 / (d2 - d6)
            return triangle.a + ac * w
        }

        let va = d3 * d6 - d5 * d4
        if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0 {
            let edge = triangle.c - triangle.b
            let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
            return triangle.b + edge * w
        }

        let denominator = va + vb + vc
        guard denominator.isFinite, abs(denominator) > 1e-30 else { return triangle.a }
        let inverse = 1 / denominator
        let v = vb * inverse
        let w = vc * inverse
        return triangle.a + ab * v + ac * w
    }

    private static func insert(
        triangleIndex: Int,
        triangle: DistanceTriangle,
        cellSize: Double,
        buckets: inout [DistanceCell: [Int]]
    ) throws {
        guard let minimum = DistanceCell(
            point: Vec3(
                min(triangle.a.x, min(triangle.b.x, triangle.c.x)),
                min(triangle.a.y, min(triangle.b.y, triangle.c.y)),
                min(triangle.a.z, min(triangle.b.z, triangle.c.z))),
            size: cellSize),
              let maximum = DistanceCell(
                point: Vec3(
                    max(triangle.a.x, max(triangle.b.x, triangle.c.x)),
                    max(triangle.a.y, max(triangle.b.y, triangle.c.y)),
                    max(triangle.a.z, max(triangle.b.z, triangle.c.z))),
                size: cellSize)
        else {
            throw MeshDistanceFieldError.spatialIndexTooLarge(
                triangleIndex: triangleIndex, cellCount: Int.max)
        }

        let deltaX = maximum.x.subtractingReportingOverflow(minimum.x)
        let deltaY = maximum.y.subtractingReportingOverflow(minimum.y)
        let deltaZ = maximum.z.subtractingReportingOverflow(minimum.z)
        guard !deltaX.overflow, !deltaY.overflow, !deltaZ.overflow else {
            throw MeshDistanceFieldError.spatialIndexTooLarge(
                triangleIndex: triangleIndex, cellCount: Int.max)
        }
        let spanXResult = deltaX.partialValue.addingReportingOverflow(1)
        let spanYResult = deltaY.partialValue.addingReportingOverflow(1)
        let spanZResult = deltaZ.partialValue.addingReportingOverflow(1)
        guard !spanXResult.overflow, !spanYResult.overflow, !spanZResult.overflow else {
            throw MeshDistanceFieldError.spatialIndexTooLarge(
                triangleIndex: triangleIndex, cellCount: Int.max)
        }
        let spanX = spanXResult.partialValue
        let spanY = spanYResult.partialValue
        let spanZ = spanZResult.partialValue
        let xy = spanX.multipliedReportingOverflow(by: spanY)
        let xyz = xy.partialValue.multipliedReportingOverflow(by: spanZ)
        guard spanX > 0, spanY > 0, spanZ > 0,
              !xy.overflow, !xyz.overflow
        else {
            throw MeshDistanceFieldError.spatialIndexTooLarge(
                triangleIndex: triangleIndex, cellCount: Int.max)
        }
        guard xyz.partialValue <= 100_000 else {
            // Ripiegare su tutti i triangoli per ogni campione annullerebbe lo scopo dell'hash.
            // Un indice patologico viene quindi rifiutato prima di allocare milioni di voci.
            throw MeshDistanceFieldError.spatialIndexTooLarge(
                triangleIndex: triangleIndex, cellCount: xyz.partialValue)
        }

        for z in minimum.z...maximum.z {
            for y in minimum.y...maximum.y {
                for x in minimum.x...maximum.x {
                    let cell = DistanceCell(x: x, y: y, z: z)
                    var entries = buckets[cell] ?? []
                    entries.append(triangleIndex)
                    buckets[cell] = entries
                }
            }
        }
    }
}

private struct DistanceTriangle {
    let a: Vec3
    let b: Vec3
    let c: Vec3
    let normal: Vec3
}

private struct DistanceCell: Hashable {
    let x: Int
    let y: Int
    let z: Int

    init(x: Int, y: Int, z: Int) {
        self.x = x
        self.y = y
        self.z = z
    }

    init?(point: Vec3, size: Double) {
        guard point.isFinite, size.isFinite, size > 0,
              let x = Int(exactly: Foundation.floor(point.x / size)),
              let y = Int(exactly: Foundation.floor(point.y / size)),
              let z = Int(exactly: Foundation.floor(point.z / size))
        else { return nil }
        self.init(x: x, y: y, z: z)
    }

    func offset(dx: Int, dy: Int, dz: Int) -> DistanceCell? {
        let nx = x.addingReportingOverflow(dx)
        let ny = y.addingReportingOverflow(dy)
        let nz = z.addingReportingOverflow(dz)
        guard !nx.overflow, !ny.overflow, !nz.overflow else { return nil }
        return DistanceCell(x: nx.partialValue, y: ny.partialValue, z: nz.partialValue)
    }
}

private struct DistanceCellBounds {
    let minimum: DistanceCell
    let maximum: DistanceCell

    init?<Cells: Sequence>(cells: Cells) where Cells.Element == DistanceCell {
        var iterator = cells.makeIterator()
        guard let first = iterator.next() else { return nil }
        var minimum = first
        var maximum = first
        while let cell = iterator.next() {
            minimum = DistanceCell(
                x: min(minimum.x, cell.x),
                y: min(minimum.y, cell.y),
                z: min(minimum.z, cell.z))
            maximum = DistanceCell(
                x: max(maximum.x, cell.x),
                y: max(maximum.y, cell.y),
                z: max(maximum.z, cell.z))
        }
        self.minimum = minimum
        self.maximum = maximum
    }

    func minimumRing(from cell: DistanceCell) -> Int? {
        let dx = axisGap(cell.x, minimum.x, maximum.x)
        let dy = axisGap(cell.y, minimum.y, maximum.y)
        let dz = axisGap(cell.z, minimum.z, maximum.z)
        guard let dx, let dy, let dz else { return nil }
        return max(dx, max(dy, dz))
    }

    func maximumRing(from cell: DistanceCell) -> Int? {
        let values = [
            absoluteDifference(cell.x, minimum.x), absoluteDifference(cell.x, maximum.x),
            absoluteDifference(cell.y, minimum.y), absoluteDifference(cell.y, maximum.y),
            absoluteDifference(cell.z, minimum.z), absoluteDifference(cell.z, maximum.z),
        ]
        var maximumValue = 0
        for value in values {
            guard let value else { return nil }
            maximumValue = max(maximumValue, value)
        }
        return maximumValue
    }

    private func axisGap(_ value: Int, _ lower: Int, _ upper: Int) -> Int? {
        if value < lower { return absoluteDifference(value, lower) }
        if value > upper { return absoluteDifference(value, upper) }
        return 0
    }

    private func absoluteDifference(_ first: Int, _ second: Int) -> Int? {
        if first >= second {
            let result = first.subtractingReportingOverflow(second)
            guard !result.overflow, result.partialValue >= 0 else { return nil }
            return result.partialValue
        }
        let result = second.subtractingReportingOverflow(first)
        guard !result.overflow, result.partialValue >= 0 else { return nil }
        return result.partialValue
    }
}
