import DICOMCore
import Foundation

/// Lisciatura che alterna contrazione e rigonfiamento per eliminare le scalette senza ritirare
/// il modello: omettere la seconda passata cambierebbe le dimensioni cliniche del pezzo stampato.
public enum MeshSmoothing: Sendable {
    public static func taubin(
        _ mesh: Mesh,
        lambda: Double = 0.53,
        mu: Double = -0.53,
        iterations: Int = 10
    ) -> Mesh {
        guard iterations > 0, lambda.isFinite, mu.isFinite else { return mesh }
        let topology = MeshTopology(mesh)
        let neighbours = topology.vertexNeighbours(vertexCount: mesh.vertexCount)
        let boundary = topology.boundaryVertices(vertexCount: mesh.vertexCount)
        var vertices = mesh.verticesMM

        var iteration = 0
        while iteration < iterations {
            vertices = smoothingPass(
                vertices: vertices,
                neighbours: neighbours,
                boundary: boundary,
                factor: lambda
            )
            vertices = smoothingPass(
                vertices: vertices,
                neighbours: neighbours,
                boundary: boundary,
                factor: mu
            )
            iteration += 1
        }
        return Mesh(verticesMM: vertices, triangles: mesh.triangles, name: mesh.name)
    }

    private static func smoothingPass(
        vertices: [Vec3],
        neighbours: [[Int]],
        boundary: [Bool],
        factor: Double
    ) -> [Vec3] {
        guard factor != 0 else { return vertices }
        var result = vertices
        for index in vertices.indices {
            guard !boundary[index], !neighbours[index].isEmpty, vertices[index].isFinite else {
                continue
            }
            var sum = Vec3.zero
            var count = 0
            for neighbour in neighbours[index] where vertices[neighbour].isFinite {
                sum += vertices[neighbour]
                count += 1
            }
            guard count > 0 else { continue }
            let average = sum / Double(count)
            let moved = vertices[index] + (average - vertices[index]) * factor
            if moved.isFinite {
                result[index] = moved
            }
        }
        return result
    }
}
