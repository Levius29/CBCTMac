import DICOMCore
import Foundation

public struct MeshIntegrity: Hashable, Sendable {
    public var triangleCount: Int
    public var vertexCount: Int
    /// Spigoli percorsi da un solo triangolo: un solido chiuso non ne ha nessuno.
    public var openEdgeCount: Int
    /// Spigoli percorsi da più di due triangoli.
    public var nonManifoldEdgeCount: Int
    /// Gusci separati, cioè componenti connesse per spigolo.
    public var shellCount: Int
    /// Volume con segno: negativo quando le normali guardano dentro.
    public var volumeMM3: Double
    public var areaMM2: Double
    public var isWatertight: Bool { openEdgeCount == 0 && nonManifoldEdgeCount == 0 }
}

public enum MeshRepair: Sendable {
    public static func integrity(of mesh: Mesh) -> MeshIntegrity {
        let topology = MeshTopology(mesh)
        var openEdges = 0
        var nonManifoldEdges = 0
        for incident in topology.edgeUses.values {
            if incident.count == 1 {
                openEdges += 1
            } else if incident.count > 2 {
                nonManifoldEdges += 1
            }
        }

        var validIndices = [Int]()
        validIndices.reserveCapacity(mesh.triangles.count)
        for index in mesh.triangles.indices where topology.validTriangles[index] {
            validIndices.append(index)
        }
        let validMesh = compactMesh(mesh, keepingTriangleIndices: validIndices)
        return MeshIntegrity(
            triangleCount: mesh.triangleCount,
            vertexCount: mesh.vertexCount,
            openEdgeCount: openEdges,
            nonManifoldEdgeCount: nonManifoldEdges,
            shellCount: topology.components(in: mesh).count,
            volumeMM3: validMesh.signedVolumeMM3(),
            areaMM2: validMesh.surfaceAreaMM2()
        )
    }

    /// Tiene il guscio con più triangoli e scarta gli altri.
    public static func largestShell(of mesh: Mesh) -> Mesh {
        let components = MeshTopology(mesh).components(in: mesh)
        guard var largest = components.first else {
            return Mesh(verticesMM: [], triangles: [], name: mesh.name)
        }
        for component in components.dropFirst() where component.count > largest.count {
            largest = component
        }
        return compactMesh(mesh, keepingTriangleIndices: largest)
    }

    /// Rende coerente l'avvolgimento dei triangoli e porta le normali all'esterno.
    public static func orientedOutward(_ mesh: Mesh) -> Mesh {
        let topology = MeshTopology(mesh)
        var flipped = [Bool](repeating: false, count: mesh.triangles.count)
        var visited = [Bool](repeating: false, count: mesh.triangles.count)
        var result = mesh

        for seed in mesh.triangles.indices where topology.validTriangles[seed] && !visited[seed] {
            var shell = [Int]()
            var queue = [seed]
            visited[seed] = true
            var head = 0
            while head < queue.count {
                let current = queue[head]
                head += 1
                shell.append(current)
                let triangle = mesh.triangles[current]
                for edge in topology.edges(of: triangle) {
                    guard let incident = topology.edgeUses[edge],
                          let currentUse = incident.first(where: { $0.triangleIndex == current })
                    else { continue }
                    let currentAscending = currentUse.followsAscendingIndex != flipped[current]
                    for neighbourUse in incident where neighbourUse.triangleIndex != current {
                        let neighbour = neighbourUse.triangleIndex
                        guard !visited[neighbour] else { continue }
                        // Due facce coerenti percorrono lo spigolo comune in versi opposti.
                        // Memorizzare il verso originale permette di propagare il ribaltamento
                        // senza modificare la mappa mentre la coda è in uso.
                        flipped[neighbour] = neighbourUse.followsAscendingIndex == currentAscending
                        visited[neighbour] = true
                        queue.append(neighbour)
                    }
                }
            }

            for index in shell where flipped[index] {
                result.triangles[index] = reversed(result.triangles[index])
            }
            let shellMesh = compactMesh(result, keepingTriangleIndices: shell)
            if shellMesh.signedVolumeMM3() < 0 {
                // Gusci distinti possono avere versi iniziali diversi: il segno viene quindi
                // corretto per componente, non con un unico ribaltamento globale.
                for index in shell {
                    result.triangles[index] = reversed(result.triangles[index])
                }
            }
        }
        return result
    }

    private static func reversed(_ triangle: Triangle) -> Triangle {
        Triangle(a: triangle.a, b: triangle.c, c: triangle.b)
    }
}
