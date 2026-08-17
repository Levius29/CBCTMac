import Testing
import Foundation
import DICOMCore
import MeshKit
@testable import GuideKit

// Verifica dell'indice spaziale di `MeshDistanceField` contro una verità analitica.
//
// Le altre prove sulla distanza usano un **singolo** triangolo, e con un solo triangolo l'indice
// spaziale non può sbagliare: qualunque ricerca lo trova. Restano quindi non esercitati proprio i
// pezzi più delicati — l'inserimento di un triangolo in tutte le celle che il suo bounding box
// tocca, la ricerca a gusci di raggio crescente, e il criterio che la interrompe. Un difetto in
// uno dei tre non produce un errore: produce una distanza sbagliata, cioè una dima che sembra
// giusta.
//
// Qui la superficie è una sfera geodetica con più di mille triangoli, e il riferimento non è
// un'altra esecuzione dello stesso codice: è `|p| − r`, che per una sfera è la distanza esatta.
// L'errore di tassellatura è quantificato sotto e sottratto dalla tolleranza.

@Suite("Indice spaziale su una superficie curva")
struct SpatialIndexTests {

    /// Sfera geodetica: icosaedro suddiviso `subdivisions` volte, vertici riportati sul raggio.
    ///
    /// I triangoli hanno orientamento uscente, quindi il segno del campo pseudo-firmato coincide
    /// con quello di `|p| − r`: negativo dentro, positivo fuori.
    private static func geodesicSphere(radius: Double, subdivisions: Int) -> Mesh {
        let t = (1 + Foundation.sqrt(5.0)) / 2
        var vertices: [Vec3] = [
            Vec3(-1, t, 0), Vec3(1, t, 0), Vec3(-1, -t, 0), Vec3(1, -t, 0),
            Vec3(0, -1, t), Vec3(0, 1, t), Vec3(0, -1, -t), Vec3(0, 1, -t),
            Vec3(t, 0, -1), Vec3(t, 0, 1), Vec3(-t, 0, -1), Vec3(-t, 0, 1),
        ]
        var faces: [(Int, Int, Int)] = [
            (0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11),
            (1, 5, 9), (5, 11, 4), (11, 10, 2), (10, 7, 6), (7, 1, 8),
            (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9),
            (4, 9, 5), (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1),
        ]

        for _ in 0..<subdivisions {
            var midpoints: [Int: Int] = [:]
            var next: [(Int, Int, Int)] = []
            next.reserveCapacity(faces.count * 4)

            func midpoint(_ i: Int, _ j: Int) -> Int {
                let key = i < j ? i * 100_000 + j : j * 100_000 + i
                if let existing = midpoints[key] { return existing }
                let index = vertices.count
                vertices.append((vertices[i] + vertices[j]) / 2)
                midpoints[key] = index
                return index
            }

            for face in faces {
                let ab = midpoint(face.0, face.1)
                let bc = midpoint(face.1, face.2)
                let ca = midpoint(face.2, face.0)
                next.append((face.0, ab, ca))
                next.append((face.1, bc, ab))
                next.append((face.2, ca, bc))
                next.append((ab, bc, ca))
            }
            faces = next
        }

        // La proiezione sul raggio avviene alla fine: proiettare a ogni giro darebbe la stessa
        // superficie ma con triangoli più irregolari.
        let projected = vertices.map { vertex -> Vec3 in
            guard let unit = vertex.normalized else { return Vec3(0, 0, radius) }
            return unit * radius
        }
        return Mesh(
            verticesMM: projected,
            triangles: faces.map { Triangle(a: $0.0, b: $0.1, c: $0.2) },
            name: "sfera geodetica")
    }

    @Test("La distanza da una sfera di 1280 triangoli coincide con |p| − r")
    func distanceMatchesAnalyticSphere() throws {
        let radius = 10.0
        let mesh = Self.geodesicSphere(radius: radius, subdivisions: 3)
        #expect(mesh.triangleCount == 1280)

        // Errore di tassellatura: il piano di una faccia taglia la corda, quindi la mesh sta
        // sempre **dentro** la sfera ideale, al più di questo scostamento. Lo si stima dal
        // vertice più distante dal centro di una faccia.
        var inscribedError = 0.0
        for triangle in mesh.triangles {
            let centre = (mesh.verticesMM[triangle.a]
                + mesh.verticesMM[triangle.b]
                + mesh.verticesMM[triangle.c]) / 3
            inscribedError = max(inscribedError, radius - centre.length)
        }
        #expect(inscribedError < radius * 0.01)

        let maxDistance = 4.0
        guard let grid = FieldGrid(
            boundsMinMM: Vec3(-radius - 2, -radius - 2, -radius - 2),
            boundsMaxMM: Vec3(radius + 2, radius + 2, radius + 2),
            spacingMM: 0.8,
            paddingCells: 2
        ) else {
            Issue.record("griglia non costruita")
            return
        }

        let field = try MeshDistanceField.build(
            from: mesh, grid: grid, maxDistanceMM: maxDistance)

        // Si confrontano solo i campioni nella fascia dove il campo non è troncato, e non a
        // ridosso del troncamento: lì il valore è per contratto saturato e non rappresenta più
        // una distanza.
        let band = maxDistance - 2 * grid.spacingMM
        var compared = 0
        var worst = 0.0
        var worstAt = Vec3(0, 0, 0)
        var signErrors = 0

        for z in 0..<grid.countZ {
            for y in 0..<grid.countY {
                for x in 0..<grid.countX {
                    let point = grid.position(x: x, y: y, z: z)
                    let analytic = point.length - radius
                    guard abs(analytic) < band else { continue }

                    let measured = field.value(x: x, y: y, z: z)
                    compared += 1

                    // Il segno deve seguire dentro/fuori. Vicinissimo alla superficie il
                    // confronto non è significativo: la mesh e la sfera ideale non coincidono.
                    if abs(analytic) > inscribedError * 2, measured.sign != analytic.sign {
                        signErrors += 1
                    }

                    let error = abs(measured - analytic)
                    if error > worst {
                        worst = error
                        worstAt = point
                    }
                }
            }
        }

        #expect(compared > 5000, "la fascia di confronto è troppo piccola per dire qualcosa")
        #expect(signErrors == 0, "segno errato su \(signErrors) campioni")

        // La distanza misurata è quella dalla mesh, che sta dentro la sfera ideale: lo
        // scostamento atteso è dell'ordine dell'errore di tassellatura, non del passo di griglia.
        // Il margine è tre volte quello, non di più: allargarlo renderebbe il test incapace di
        // vedere un indice spaziale che restituisce un triangolo non minimo.
        let tolerance = inscribedError * 3
        #expect(
            worst < tolerance,
            "scostamento massimo \(worst) mm in \(worstAt), tolleranza \(tolerance) mm")
    }

    @Test("Due superfici lontane fra loro non si confondono")
    func nearestSurfaceWins() throws {
        // Due piastre parallele con normali opposte, separate lungo Z. Ogni campione deve
        // riferirsi alla piastra più vicina: se la ricerca a gusci si fermasse troppo presto,
        // i campioni nella metà superiore prenderebbero la piastra sbagliata e il segno con essa.
        let halfGap = 6.0
        func plate(atZ z: Double, upward: Bool) -> ([Vec3], [Triangle]) {
            let corners = [
                Vec3(-8, -8, z), Vec3(8, -8, z), Vec3(8, 8, z), Vec3(-8, 8, z),
            ]
            let winding = upward
                ? [Triangle(a: 0, b: 1, c: 2), Triangle(a: 0, b: 2, c: 3)]
                : [Triangle(a: 0, b: 2, c: 1), Triangle(a: 0, b: 3, c: 2)]
            return (corners, winding)
        }

        let (lowerVertices, lowerTriangles) = plate(atZ: -halfGap, upward: false)
        let (upperVertices, upperTriangles) = plate(atZ: halfGap, upward: true)
        let mesh = Mesh(
            verticesMM: lowerVertices + upperVertices,
            triangles: lowerTriangles + upperTriangles.map {
                Triangle(a: $0.a + 4, b: $0.b + 4, c: $0.c + 4)
            },
            name: "due piastre")

        guard let grid = FieldGrid(
            boundsMinMM: Vec3(-4, -4, -halfGap),
            boundsMaxMM: Vec3(4, 4, halfGap),
            spacingMM: 0.5,
            paddingCells: 2
        ) else {
            Issue.record("griglia non costruita")
            return
        }

        let field = try MeshDistanceField.build(from: mesh, grid: grid, maxDistanceMM: 8)

        for z in 0..<grid.countZ {
            for y in 0..<grid.countY {
                for x in 0..<grid.countX {
                    let point = grid.position(x: x, y: y, z: z)
                    guard abs(point.x) < 5, abs(point.y) < 5 else { continue }

                    let toLower = abs(point.z + halfGap)
                    let toUpper = abs(point.z - halfGap)
                    let expected = min(toLower, toUpper)
                    guard expected < 5, abs(toLower - toUpper) > 1 else { continue }

                    let measured = abs(field.value(x: x, y: y, z: z))
                    #expect(
                        abs(measured - expected) < 1e-6,
                        "in \(point) attesa \(expected) mm, misurata \(measured) mm")
                }
            }
        }
    }
}
