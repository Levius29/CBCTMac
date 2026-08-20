import DICOMCore
import Foundation

// Mettere più mesh in un file solo.
//
// # Che cosa fa, e soprattutto che cosa non fa
//
// Concatena: rinumera i vertici della seconda mesh dopo quelli della prima e riporta i
// triangoli. Il risultato è **una mesh con più componenti**, non un solido unico.
//
// Non è una unione booleana. Due impianti che si toccassero resterebbero due superfici
// compenetrate, e nel punto in cui si intersecano non c'è nessuno spigolo nuovo. Per un file da
// guardare o da aprire in un modellatore va benissimo — è ciò che uno STL è, un mucchio di
// triangoli senza topologia — e per una sottrazione booleana non basterebbe. Dirlo qui evita
// che qualcuno lo scopra provando a stampare.

public enum MeshMerge: Sendable {

    /// Unisce più mesh in una sola, conservandone i triangoli.
    ///
    /// - Returns: una mesh vuota col nome dato quando l'elenco è vuoto.
    public static func combined(_ meshes: [Mesh], name: String) -> Mesh {
        var vertices: [Vec3] = []
        var triangles: [Triangle] = []
        vertices.reserveCapacity(meshes.reduce(0) { $0 + $1.verticesMM.count })
        triangles.reserveCapacity(meshes.reduce(0) { $0 + $1.triangles.count })

        for mesh in meshes {
            let offset = vertices.count
            vertices.append(contentsOf: mesh.verticesMM)
            for triangle in mesh.triangles {
                // Un indice fuori intervallo nella mesh di partenza diventerebbe, sommandoci lo
                // scostamento, un indice **valido** che punta al vertice di un altro oggetto: un
                // triangolo che attraversa la scena, e nessun errore. Si scarta invece.
                guard triangle.a >= 0, triangle.a < mesh.verticesMM.count,
                    triangle.b >= 0, triangle.b < mesh.verticesMM.count,
                    triangle.c >= 0, triangle.c < mesh.verticesMM.count
                else { continue }
                triangles.append(
                    Triangle(
                        a: triangle.a + offset,
                        b: triangle.b + offset,
                        c: triangle.c + offset))
            }
        }

        return Mesh(verticesMM: vertices, triangles: triangles, name: name)
    }
}
