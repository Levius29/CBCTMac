import DICOMCore
import Foundation

struct MeshEdge: Hashable, Sendable {
    let low: Int
    let high: Int

    init(_ first: Int, _ second: Int) {
        low = Swift.min(first, second)
        high = Swift.max(first, second)
    }
}

struct MeshEdgeUse: Sendable {
    let triangleIndex: Int
    let followsAscendingIndex: Bool
}

struct MeshTopology: Sendable {
    let edgeUses: [MeshEdge: [MeshEdgeUse]]
    let validTriangles: [Bool]

    init(_ mesh: Mesh) {
        var uses: [MeshEdge: [MeshEdgeUse]] = [:]
        let capacity = mesh.triangles.count.multipliedReportingOverflow(by: 3)
        if !capacity.overflow {
            uses.reserveCapacity(capacity.partialValue)
        }
        var valid = [Bool](repeating: false, count: mesh.triangles.count)

        for index in mesh.triangles.indices {
            let triangle = mesh.triangles[index]
            guard isValidTriangle(triangle, in: mesh) else { continue }
            valid[index] = true
            Self.appendUse(from: triangle.a, to: triangle.b, triangleIndex: index, to: &uses)
            Self.appendUse(from: triangle.b, to: triangle.c, triangleIndex: index, to: &uses)
            Self.appendUse(from: triangle.c, to: triangle.a, triangleIndex: index, to: &uses)
        }
        edgeUses = uses
        validTriangles = valid
    }

    func components(in mesh: Mesh) -> [[Int]] {
        var visited = [Bool](repeating: false, count: mesh.triangles.count)
        var result = [[Int]]()

        for seed in mesh.triangles.indices where validTriangles[seed] && !visited[seed] {
            var component = [Int]()
            var queue = [seed]
            visited[seed] = true
            var head = 0
            while head < queue.count {
                let triangleIndex = queue[head]
                head += 1
                component.append(triangleIndex)
                for edge in edges(of: mesh.triangles[triangleIndex]) {
                    guard let incident = edgeUses[edge] else { continue }
                    for use in incident where !visited[use.triangleIndex] {
                        visited[use.triangleIndex] = true
                        queue.append(use.triangleIndex)
                    }
                }
            }
            result.append(component)
        }
        return result
    }

    func vertexNeighbours(vertexCount: Int) -> [[Int]] {
        var neighbours = [[Int]](repeating: [], count: vertexCount)
        for edge in edgeUses.keys {
            guard edge.low >= 0, edge.high < vertexCount else { continue }
            neighbours[edge.low].append(edge.high)
            neighbours[edge.high].append(edge.low)
        }
        return neighbours
    }

    func boundaryVertices(vertexCount: Int) -> [Bool] {
        var boundary = [Bool](repeating: false, count: vertexCount)
        for (edge, incident) in edgeUses where incident.count == 1 {
            guard edge.low >= 0, edge.high < vertexCount else { continue }
            boundary[edge.low] = true
            boundary[edge.high] = true
        }
        return boundary
    }

    func edges(of triangle: Triangle) -> [MeshEdge] {
        [MeshEdge(triangle.a, triangle.b), MeshEdge(triangle.b, triangle.c), MeshEdge(triangle.c, triangle.a)]
    }

    private static func appendUse(
        from: Int,
        to: Int,
        triangleIndex: Int,
        to uses: inout [MeshEdge: [MeshEdgeUse]]
    ) {
        let edge = MeshEdge(from, to)
        uses[edge, default: []].append(
            MeshEdgeUse(triangleIndex: triangleIndex, followsAscendingIndex: from < to)
        )
    }
}

func isValidTriangle(_ triangle: Triangle, in mesh: Mesh) -> Bool {
    guard triangle.a >= 0, triangle.a < mesh.verticesMM.count,
          triangle.b >= 0, triangle.b < mesh.verticesMM.count,
          triangle.c >= 0, triangle.c < mesh.verticesMM.count,
          triangle.a != triangle.b,
          triangle.a != triangle.c,
          triangle.b != triangle.c
    else { return false }
    let a = mesh.verticesMM[triangle.a]
    let b = mesh.verticesMM[triangle.b]
    let c = mesh.verticesMM[triangle.c]
    guard a.isFinite, b.isFinite, c.isFinite else { return false }
    let cross = (b - a).cross(c - a)
    return cross.isFinite && cross.lengthSquared > 0
}

func compactMesh(_ mesh: Mesh, keepingTriangleIndices indices: [Int]) -> Mesh {
    var used = [Bool](repeating: false, count: mesh.verticesMM.count)
    var retained = [Triangle]()
    retained.reserveCapacity(indices.count)
    for index in indices {
        guard index >= 0, index < mesh.triangles.count else { continue }
        let triangle = mesh.triangles[index]
        guard isValidTriangle(triangle, in: mesh) else { continue }
        used[triangle.a] = true
        used[triangle.b] = true
        used[triangle.c] = true
        retained.append(triangle)
    }

    var mapping = [Int](repeating: -1, count: mesh.verticesMM.count)
    var vertices = [Vec3]()
    vertices.reserveCapacity(mesh.verticesMM.count)
    for index in mesh.verticesMM.indices where used[index] {
        mapping[index] = vertices.count
        vertices.append(mesh.verticesMM[index])
    }

    var triangles = [Triangle]()
    triangles.reserveCapacity(retained.count)
    for triangle in retained {
        triangles.append(
            Triangle(a: mapping[triangle.a], b: mapping[triangle.b], c: mapping[triangle.c])
        )
    }
    return Mesh(verticesMM: vertices, triangles: triangles, name: mesh.name)
}
