import DICOMCore
import Foundation

public enum MeshDecimation: Sendable {
    /// Riduce la mesh verso il bilancio di triangoli richiesto.
    public static func simplified(_ mesh: Mesh, targetTriangleCount: Int) -> Mesh {
        guard targetTriangleCount > 0, mesh.triangleCount > targetTriangleCount else { return mesh }

        let cleaned = mesh.removingDegenerateTriangles()
        guard cleaned.triangleCount > targetTriangleCount else { return cleaned }
        var state = DecimationState(mesh: cleaned)
        state.simplify(to: targetTriangleCount)
        return state.result(name: mesh.name)
    }
}

private struct DecimationState {
    var vertices: [Vec3]
    var triangles: [Triangle]
    var triangleAlive: [Bool]
    var vertexAlive: [Bool]
    var vertexTriangles: [Set<Int>]
    var vertexNeighbours: [Set<Int>]
    var quadrics: [SymmetricQuadric]
    var versions: [Int]
    var heap = CollapseHeap()
    var liveTriangleCount: Int
    var serial = 0

    init(mesh: Mesh) {
        vertices = mesh.verticesMM
        triangles = mesh.triangles
        triangleAlive = [Bool](repeating: true, count: mesh.triangleCount)
        vertexAlive = [Bool](repeating: true, count: mesh.vertexCount)
        vertexTriangles = [Set<Int>](repeating: [], count: mesh.vertexCount)
        vertexNeighbours = [Set<Int>](repeating: [], count: mesh.vertexCount)
        quadrics = [SymmetricQuadric](repeating: .zero, count: mesh.vertexCount)
        versions = [Int](repeating: 0, count: mesh.vertexCount)
        liveTriangleCount = mesh.triangleCount

        for index in triangles.indices {
            let triangle = triangles[index]
            vertexTriangles[triangle.a].insert(index)
            vertexTriangles[triangle.b].insert(index)
            vertexTriangles[triangle.c].insert(index)
            connect(triangle.a, triangle.b)
            connect(triangle.b, triangle.c)
            connect(triangle.c, triangle.a)

            let a = vertices[triangle.a]
            let b = vertices[triangle.b]
            let c = vertices[triangle.c]
            guard let plane = PlaneQuadric(a: a, b: b, c: c) else { continue }
            quadrics[triangle.a] += plane.quadric
            quadrics[triangle.b] += plane.quadric
            quadrics[triangle.c] += plane.quadric
        }

        for first in vertexNeighbours.indices {
            for second in vertexNeighbours[first] where first < second {
                enqueue(first, second)
            }
        }
    }

    mutating func simplify(to target: Int) {
        while liveTriangleCount > target, let candidate = heap.popMinimum() {
            let first = candidate.edge.low
            let second = candidate.edge.high
            guard vertexAlive[first], vertexAlive[second],
                  versions[first] == candidate.firstVersion,
                  versions[second] == candidate.secondVersion,
                  vertexNeighbours[first].contains(second),
                  contractionPreservesTopology(first, second),
                  contractionPreservesOrientation(first, second, position: candidate.position)
            else { continue }
            contract(first, second, position: candidate.position)
        }
    }

    func result(name: String) -> Mesh {
        var retained = [Triangle]()
        retained.reserveCapacity(liveTriangleCount)
        for index in triangles.indices where triangleAlive[index] {
            retained.append(triangles[index])
        }
        let raw = Mesh(verticesMM: vertices, triangles: retained, name: name)
        return compactMesh(raw, keepingTriangleIndices: Array(raw.triangles.indices))
    }

    private mutating func connect(_ first: Int, _ second: Int) {
        guard first != second else { return }
        vertexNeighbours[first].insert(second)
        vertexNeighbours[second].insert(first)
    }

    private mutating func enqueue(_ first: Int, _ second: Int) {
        let edge = MeshEdge(first, second)
        guard edge.low != edge.high, vertexAlive[edge.low], vertexAlive[edge.high] else { return }
        let quadric = quadrics[edge.low] + quadrics[edge.high]
        let candidates = [
            vertices[edge.low],
            vertices[edge.high],
            (vertices[edge.low] + vertices[edge.high]) / 2,
            quadric.stationaryPoint,
        ]
        var bestPosition: Vec3?
        var bestCost = Double.infinity
        for position in candidates.compactMap({ $0 }) where position.isFinite {
            let cost = quadric.evaluate(at: position)
            if cost.isFinite, cost < bestCost {
                bestCost = cost
                bestPosition = position
            }
        }
        guard let position = bestPosition else { return }
        serial &+= 1
        heap.insert(
            CollapseCandidate(
                edge: edge,
                position: position,
                cost: Swift.max(0, bestCost),
                firstVersion: versions[edge.low],
                secondVersion: versions[edge.high],
                serial: serial
            )
        )
    }

    private func edgeTriangleCount(_ first: Int, _ second: Int) -> Int {
        let smaller = vertexTriangles[first].count <= vertexTriangles[second].count
            ? vertexTriangles[first] : vertexTriangles[second]
        let other = vertexTriangles[first].count <= vertexTriangles[second].count
            ? vertexTriangles[second] : vertexTriangles[first]
        var count = 0
        for triangle in smaller where triangleAlive[triangle] && other.contains(triangle) {
            count += 1
        }
        return count
    }

    private func contractionPreservesTopology(_ first: Int, _ second: Int) -> Bool {
        let incidentCount = edgeTriangleCount(first, second)
        guard incidentCount == 1 || incidentCount == 2 else { return false }

        let smaller = vertexNeighbours[first].count <= vertexNeighbours[second].count
            ? vertexNeighbours[first] : vertexNeighbours[second]
        let other = vertexNeighbours[first].count <= vertexNeighbours[second].count
            ? vertexNeighbours[second] : vertexNeighbours[first]
        var commonCount = 0
        for vertex in smaller where other.contains(vertex) {
            commonCount += 1
            // Più di due vicini comuni salderebbero fra loro zone diverse e farebbero
            // attraversare lo stesso spigolo da almeno tre triangoli.
            if commonCount > 2 { return false }
        }
        return commonCount == incidentCount
    }

    private func contractionPreservesOrientation(
        _ first: Int,
        _ second: Int,
        position: Vec3
    ) -> Bool {
        let incident = vertexTriangles[first].union(vertexTriangles[second])
        for index in incident where triangleAlive[index] {
            let triangle = triangles[index]
            let containsFirst = triangle.a == first || triangle.b == first || triangle.c == first
            let containsSecond = triangle.a == second || triangle.b == second || triangle.c == second
            if containsFirst && containsSecond { continue }

            let oldA = vertices[triangle.a]
            let oldB = vertices[triangle.b]
            let oldC = vertices[triangle.c]
            let newA = triangle.a == first || triangle.a == second ? position : oldA
            let newB = triangle.b == first || triangle.b == second ? position : oldB
            let newC = triangle.c == first || triangle.c == second ? position : oldC
            let oldNormal = (oldB - oldA).cross(oldC - oldA)
            let newNormal = (newB - newA).cross(newC - newA)
            guard oldNormal.isFinite, newNormal.isFinite,
                  oldNormal.lengthSquared > 0, newNormal.lengthSquared > 0
            else { return false }
            let scale = (oldNormal.lengthSquared * newNormal.lengthSquared).squareRoot()
            // La quadrica misura la distanza dai piani ma non il loro verso: questo test
            // geometrico è ciò che impedisce a una contrazione economica di capovolgere la pelle.
            guard oldNormal.dot(newNormal) > scale * 1e-12 else { return false }
        }
        return true
    }

    private mutating func contract(_ keep: Int, _ remove: Int, position: Vec3) {
        let oldNeighbours = vertexNeighbours[keep].union(vertexNeighbours[remove])
        let incident = vertexTriangles[keep].union(vertexTriangles[remove])
        var affectedVertices = oldNeighbours
        affectedVertices.insert(keep)
        affectedVertices.insert(remove)

        vertices[keep] = position
        quadrics[keep] += quadrics[remove]
        vertexAlive[remove] = false

        for index in incident where triangleAlive[index] {
            let old = triangles[index]
            affectedVertices.insert(old.a)
            affectedVertices.insert(old.b)
            affectedVertices.insert(old.c)
            let containsKeep = old.a == keep || old.b == keep || old.c == keep
            let containsRemove = old.a == remove || old.b == remove || old.c == remove
            if containsKeep && containsRemove {
                triangleAlive[index] = false
                liveTriangleCount -= 1
                vertexTriangles[old.a].remove(index)
                vertexTriangles[old.b].remove(index)
                vertexTriangles[old.c].remove(index)
                continue
            }

            let updated = Triangle(
                a: old.a == remove ? keep : old.a,
                b: old.b == remove ? keep : old.b,
                c: old.c == remove ? keep : old.c
            )
            triangles[index] = updated
            if containsRemove {
                vertexTriangles[remove].remove(index)
                vertexTriangles[keep].insert(index)
            }
            affectedVertices.insert(updated.a)
            affectedVertices.insert(updated.b)
            affectedVertices.insert(updated.c)
        }

        vertexTriangles[remove].removeAll(keepingCapacity: false)
        for vertex in affectedVertices {
            rebuildNeighbours(of: vertex)
        }
        for vertex in affectedVertices where vertexAlive[vertex] {
            versions[vertex] &+= 1
        }

        // I costi attorno alla contrazione sono cambiati. Le vecchie voci restano nell'heap
        // e vengono riconosciute dalle versioni, evitando una ricostruzione O(n²) della coda.
        for vertex in affectedVertices where vertexAlive[vertex] {
            for neighbour in vertexNeighbours[vertex] where vertex < neighbour {
                enqueue(vertex, neighbour)
            }
        }
    }

    private mutating func rebuildNeighbours(of vertex: Int) {
        guard vertexAlive[vertex] else {
            vertexNeighbours[vertex].removeAll(keepingCapacity: false)
            return
        }
        var rebuilt = Set<Int>()
        for index in vertexTriangles[vertex] where triangleAlive[index] {
            let triangle = triangles[index]
            if triangle.a != vertex, vertexAlive[triangle.a] { rebuilt.insert(triangle.a) }
            if triangle.b != vertex, vertexAlive[triangle.b] { rebuilt.insert(triangle.b) }
            if triangle.c != vertex, vertexAlive[triangle.c] { rebuilt.insert(triangle.c) }
        }
        vertexNeighbours[vertex] = rebuilt
    }
}

private struct PlaneQuadric {
    let quadric: SymmetricQuadric

    init?(a: Vec3, b: Vec3, c: Vec3) {
        guard let normal = (b - a).cross(c - a).normalized else { return nil }
        let distance = -normal.dot(a)
        quadric = SymmetricQuadric(plane: (normal.x, normal.y, normal.z, distance))
    }
}

private struct SymmetricQuadric: Sendable {
    var m00: Double
    var m01: Double
    var m02: Double
    var m03: Double
    var m11: Double
    var m12: Double
    var m13: Double
    var m22: Double
    var m23: Double
    var m33: Double

    static let zero = SymmetricQuadric(
        m00: 0, m01: 0, m02: 0, m03: 0, m11: 0,
        m12: 0, m13: 0, m22: 0, m23: 0, m33: 0
    )

    init(plane: (Double, Double, Double, Double)) {
        let (a, b, c, d) = plane
        m00 = a * a
        m01 = a * b
        m02 = a * c
        m03 = a * d
        m11 = b * b
        m12 = b * c
        m13 = b * d
        m22 = c * c
        m23 = c * d
        m33 = d * d
    }

    init(
        m00: Double, m01: Double, m02: Double, m03: Double, m11: Double,
        m12: Double, m13: Double, m22: Double, m23: Double, m33: Double
    ) {
        self.m00 = m00
        self.m01 = m01
        self.m02 = m02
        self.m03 = m03
        self.m11 = m11
        self.m12 = m12
        self.m13 = m13
        self.m22 = m22
        self.m23 = m23
        self.m33 = m33
    }

    static func + (left: SymmetricQuadric, right: SymmetricQuadric) -> SymmetricQuadric {
        SymmetricQuadric(
            m00: left.m00 + right.m00,
            m01: left.m01 + right.m01,
            m02: left.m02 + right.m02,
            m03: left.m03 + right.m03,
            m11: left.m11 + right.m11,
            m12: left.m12 + right.m12,
            m13: left.m13 + right.m13,
            m22: left.m22 + right.m22,
            m23: left.m23 + right.m23,
            m33: left.m33 + right.m33
        )
    }

    static func += (left: inout SymmetricQuadric, right: SymmetricQuadric) {
        left = left + right
    }

    func evaluate(at point: Vec3) -> Double {
        let x = point.x
        let y = point.y
        let z = point.z
        return m00 * x * x + 2 * m01 * x * y + 2 * m02 * x * z + 2 * m03 * x
            + m11 * y * y + 2 * m12 * y * z + 2 * m13 * y
            + m22 * z * z + 2 * m23 * z + m33
    }

    var stationaryPoint: Vec3? {
        let determinant = m00 * (m11 * m22 - m12 * m12)
            - m01 * (m01 * m22 - m12 * m02)
            + m02 * (m01 * m12 - m11 * m02)
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        let x = (-m03 * (m11 * m22 - m12 * m12)
            - m13 * (m02 * m12 - m01 * m22)
            - m23 * (m01 * m12 - m02 * m11)) / determinant
        let y = (-m03 * (m02 * m12 - m01 * m22)
            - m13 * (m00 * m22 - m02 * m02)
            - m23 * (m01 * m02 - m00 * m12)) / determinant
        let z = (-m03 * (m01 * m12 - m02 * m11)
            - m13 * (m01 * m02 - m00 * m12)
            - m23 * (m00 * m11 - m01 * m01)) / determinant
        let point = Vec3(x, y, z)
        return point.isFinite ? point : nil
    }
}

private struct CollapseCandidate: Sendable {
    let edge: MeshEdge
    let position: Vec3
    let cost: Double
    let firstVersion: Int
    let secondVersion: Int
    let serial: Int

    func isOrderedBefore(_ other: CollapseCandidate) -> Bool {
        if cost != other.cost { return cost < other.cost }
        if edge.low != other.edge.low { return edge.low < other.edge.low }
        if edge.high != other.edge.high { return edge.high < other.edge.high }
        return serial < other.serial
    }
}

private struct CollapseHeap: Sendable {
    private var storage = [CollapseCandidate]()

    mutating func insert(_ candidate: CollapseCandidate) {
        storage.append(candidate)
        var child = storage.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard storage[child].isOrderedBefore(storage[parent]) else { break }
            storage.swapAt(child, parent)
            child = parent
        }
    }

    mutating func popMinimum() -> CollapseCandidate? {
        guard !storage.isEmpty else { return nil }
        if storage.count == 1 { return storage.removeLast() }
        let result = storage[0]
        storage[0] = storage.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            guard left < storage.count else { break }
            let right = left + 1
            var child = left
            if right < storage.count, storage[right].isOrderedBefore(storage[left]) {
                child = right
            }
            guard storage[child].isOrderedBefore(storage[parent]) else { break }
            storage.swapAt(parent, child)
            parent = child
        }
        return result
    }
}
