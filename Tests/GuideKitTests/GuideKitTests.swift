import Foundation
import Testing

@testable import GuideKit
import DICOMCore
import ImplantKit
import MeshKit

@Suite("FieldGrid e ScalarField")
struct ScalarFieldTests {
    @Test("Il padding minimo è obbligatorio")
    func rejectsMissingPadding() {
        #expect(FieldGrid(
            boundsMinMM: .zero, boundsMaxMM: Vec3(1, 1, 1), spacingMM: 0.5,
            paddingCells: 0) == nil)
    }

    @Test("La griglia rifiuta più di 64 milioni di campioni senza allocare")
    func rejectsOversizedGrid() {
        #expect(FieldGrid(
            boundsMinMM: .zero, boundsMaxMM: Vec3(400, 400, 400), spacingMM: 0.1,
            paddingCells: 2) == nil)
    }

    @Test("La griglia rifiuta anche un estremo alto non finito dopo il padding")
    func rejectsNonFinitePaddedEndpoint() {
        let maximum = Double.greatestFiniteMagnitude
        #expect(FieldGrid(
            boundsMinMM: Vec3(maximum, maximum, maximum),
            boundsMaxMM: Vec3(maximum, maximum, maximum),
            spacingMM: maximum,
            paddingCells: 1) == nil)
    }

    @Test("L'interpolazione trilineare riproduce un campo lineare")
    func trilinearInterpolation() throws {
        let grid = try #require(FieldGrid(
            boundsMinMM: .zero, boundsMaxMM: Vec3(2, 2, 2), spacingMM: 1,
            paddingCells: 1))
        var field = ScalarField(grid: grid, initialValue: 0)
        fill(&field) { point in point.x + 2 * point.y + 3 * point.z }
        let value = try #require(field.interpolated(atMM: Vec3(0.25, 0.5, 0.75)))
        #expect(abs(value - 3.5) < 1e-12)
        #expect(field.interpolated(atMM: Vec3(-2, 0, 0)) == nil)
    }
}

@Suite("MeshDistanceField")
struct MeshDistanceFieldTests {
    private let triangle = Mesh(
        verticesMM: [Vec3(0, 0, 0), Vec3(4, 0, 0), Vec3(0, 4, 0)],
        triangles: [Triangle(a: 0, b: 1, c: 2)],
        name: "triangolo")

    @Test("Distanza esatta per proiezione interna")
    func interiorDistance() throws {
        let value = try distance(at: Vec3(1, 1, 2))
        #expect(abs(value - 2) < 1e-9)
    }

    @Test("Distanza esatta da uno spigolo")
    func edgeDistance() throws {
        let value = try distance(at: Vec3(2, -3, 0))
        #expect(abs(value - 3) < 1e-9)
    }

    @Test("Distanza esatta da un vertice")
    func vertexDistance() throws {
        let value = try distance(at: Vec3(-3, -4, 0))
        #expect(abs(value - 5) < 1e-9)
    }

    @Test("Il segno segue il lato indicato dalla normale")
    func signFollowsNormal() throws {
        #expect(try distance(at: Vec3(1, 1, 1)) > 0)
        #expect(try distance(at: Vec3(1, 1, -1)) < 0)
    }

    @Test("Anche una distanza troncata lontana conserva il segno")
    func farClampedDistanceKeepsSign() throws {
        #expect(abs(try distance(at: Vec3(1, 1, -50), maximumDistance: 2) + 2) < 1e-9)
    }

    private func distance(at point: Vec3, maximumDistance: Double = 10) throws -> Double {
        let grid = try #require(FieldGrid(
            boundsMinMM: point, boundsMaxMM: point, spacingMM: 1, paddingCells: 1))
        let field = try MeshDistanceField.build(
            from: triangle, grid: grid, maxDistanceMM: maximumDistance)
        return field.value(x: 1, y: 1, z: 1)
    }
}

@Suite("MarchingCubes")
struct MarchingCubesTests {
    @Test("Una sfera analitica è chiusa e conserva il volume")
    func sphereVolume() throws {
        let field = try sphereField(radius: 3, spacing: 0.3, touchesBoundary: false)
        let mesh = MarchingCubes.surface(from: field, isoLevel: 0, name: "sfera")
        let validation = GuideValidation.inspect(mesh: mesh, minimumWallThicknessMM: nil)
        let expected = 4.0 * Double.pi * 27.0 / 3.0
        #expect(validation.isWatertight)
        #expect(validation.hasConsistentOrientation)
        #expect(abs(abs(mesh.signedVolumeMM3()) - expected) / expected < 0.04)

        var outwardCount = 0
        for triangle in mesh.triangles {
            guard let normal = mesh.triangleNormal(triangle) else { continue }
            let centre = (mesh.verticesMM[triangle.a]
                + mesh.verticesMM[triangle.b]
                + mesh.verticesMM[triangle.c]) / 3
            if normal.dot(centre) > 0 { outwardCount += 1 }
        }
        #expect(outwardCount == mesh.triangles.count)
    }

    @Test("Il padding chiude la sfera, il contatto col bordo la apre")
    func paddingClosesSurface() throws {
        let closed = MarchingCubes.surface(
            from: try sphereField(radius: 2, spacing: 0.4, touchesBoundary: false),
            isoLevel: 0, name: "chiusa")
        let open = MarchingCubes.surface(
            from: try sphereField(radius: 2, spacing: 0.4, touchesBoundary: true),
            isoLevel: 0, name: "aperta")
        #expect(GuideValidation.inspect(mesh: closed, minimumWallThicknessMM: nil).isWatertight)
        #expect(!GuideValidation.inspect(mesh: open, minimumWallThicknessMM: nil).isWatertight)
    }

    private func sphereField(
        radius: Double, spacing: Double, touchesBoundary: Bool
    ) throws -> ScalarField {
        let minimum = Vec3(-radius, -radius, -radius)
        let maximum = Vec3(radius, radius, radius)
        let grid = try #require(FieldGrid(
            boundsMinMM: minimum, boundsMaxMM: maximum, spacingMM: spacing,
            paddingCells: touchesBoundary ? 1 : 2))
        var field = ScalarField(grid: grid, initialValue: 0)
        let boundaryX = grid.originMM.x
        fill(&field) { point in
            if touchesBoundary {
                // Il centro giace sul primo piano di campioni: la sfera attraversa davvero il
                // bordo della griglia e marching cubes non può chiudere quella calotta.
                let shifted = point - Vec3(boundaryX, 0, 0)
                return shifted.length - radius
            }
            return point.length - radius
        }
        return field
    }
}

@Suite("GuideSleeve, GuideBuilder e GuideExport")
struct GuideBuilderTests {
    @Test("La boccola endodontica segue il percorso accesso-apice")
    func canalSleeveAxis() {
        let sleeve = GuideSleeve.forCanal(
            accessMM: Vec3(1, 2, 3), apexMM: Vec3(4, 6, -9),
            burDiameterMM: 1.2, outerDiameterMM: 4, heightMM: 5)
        let expected = (Vec3(4, 6, -9) - Vec3(1, 2, 3)).normalized
        #expect(expected != nil)
        if let expected {
            #expect(sleeve.axis.isApproximatelyEqual(to: expected, tolerance: 1e-12))
        }
    }

    @Test("Una griglia più grossa di un terzo della parete viene rifiutata")
    func rejectsCoarseGrid() {
        let plate = plateMesh()
        var configuration = GuideConfiguration()
        configuration.wallThicknessMM = 1.5
        configuration.gridSpacingMM = 0.6
        var caughtExpectedError = false
        do {
            _ = try GuideBuilder.build(
                scan: plate.mesh, footprint: plate.footprint, sleeves: [],
                configuration: configuration)
        } catch let error as GuideBuildError {
            if case .gridTooCoarse = error { caughtExpectedError = true }
        } catch {
            caughtExpectedError = false
        }
        #expect(caughtExpectedError)
    }

    @Test("Un'impronta sul bordo della scansione viene rifiutata")
    func rejectsRimFootprint() {
        let plate = plateMesh(includeBoundary: true)
        var configuration = GuideConfiguration()
        configuration.minimumRimMarginMM = 0.5
        var caughtExpectedError = false
        do {
            _ = try GuideBuilder.build(
                scan: plate.mesh, footprint: plate.footprint, sleeves: [],
                configuration: configuration)
        } catch let error as GuideBuildError {
            if case .footprintTooCloseToRim = error { caughtExpectedError = true }
        } catch {
            caughtExpectedError = false
        }
        #expect(caughtExpectedError)
    }

    @Test("La dima su una piastra è chiusa e rispetta lo spessore")
    func flatGuideIsWatertight() throws {
        let plate = plateMesh()
        var configuration = GuideConfiguration()
        configuration.fitToleranceMM = 0.1
        configuration.wallThicknessMM = 1.5
        configuration.gridSpacingMM = 0.4
        configuration.footprintRadiusMM = 2.2
        configuration.minimumRimMarginMM = 0.4
        let result = try GuideBuilder.build(
            scan: plate.mesh, footprint: plate.footprint, sleeves: [],
            configuration: configuration)
        #expect(result.validation.isWatertight)
        let thickness = try #require(result.validation.minimumWallThicknessMM)
        #expect(abs(thickness - configuration.wallThicknessMM) <= configuration.gridSpacingMM)
    }

    @Test("Il foro della boccola attraversa entrambe le estremità")
    func boreIsThroughHole() throws {
        let grid = try #require(FieldGrid(
            boundsMinMM: Vec3(-5, -5, -30), boundsMaxMM: Vec3(5, 5, 30),
            spacingMM: 0.5, paddingCells: 2))
        let sleeve = GuideSleeve.forCanal(
            accessMM: .zero, apexMM: Vec3(0, 0, -10),
            burDiameterMM: 1.2, outerDiameterMM: 2, heightMM: 1)
        let bore = sleeve.boreField(grid: grid)
        #expect((bore.interpolated(atMM: Vec3(0, 0, -29)) ?? 1) < 0)
        #expect((bore.interpolated(atMM: Vec3(0, 0, 29)) ?? 1) < 0)
    }

    @Test("L'asse della fresa attraversa la dima senza incontrare una membrana")
    func builtGuideHasNoBoreMembrane() throws {
        let plate = plateMesh()
        let sleeve = GuideSleeve.forCanal(
            accessMM: Vec3(4, 4, 0), apexMM: Vec3(4, 4, -10),
            burDiameterMM: 1, outerDiameterMM: 4, heightMM: 2)
        var configuration = GuideConfiguration()
        configuration.wallThicknessMM = 1.5
        configuration.gridSpacingMM = 0.3
        configuration.footprintRadiusMM = 2.2
        configuration.minimumRimMarginMM = 0.4
        let result = try GuideBuilder.build(
            scan: plate.mesh, footprint: plate.footprint, sleeves: [sleeve],
            configuration: configuration)
        let start = sleeve.bottomMM + sleeve.axis * 5
        let end = sleeve.bottomMM - sleeve.axis * 5
        #expect(segmentIntersectionCount(start: start, end: end, mesh: result.mesh) == 0)
    }

    @Test("La misura rileva una parete di boccola più sottile del corpo")
    func sleeveWallReducesMeasuredMinimum() throws {
        let plate = plateMesh()
        let sleeve = GuideSleeve.forCanal(
            accessMM: Vec3(4, 4, 0), apexMM: Vec3(4, 4, -10),
            burDiameterMM: 1, outerDiameterMM: 2, heightMM: 2)
        var configuration = GuideConfiguration()
        configuration.wallThicknessMM = 1.5
        configuration.gridSpacingMM = 0.15
        configuration.footprintRadiusMM = 2.2
        configuration.minimumRimMarginMM = 0.4
        let result = try GuideBuilder.build(
            scan: plate.mesh, footprint: plate.footprint, sleeves: [sleeve],
            configuration: configuration)
        let thickness = try #require(result.validation.minimumWallThicknessMM)
        #expect(thickness > 0.3)
        #expect(thickness < 0.7)
    }

    @Test("Una boccola con foro nullo viene rifiutata con un errore nominato")
    func rejectsInvalidSleeve() {
        let plate = plateMesh()
        let sleeve = GuideSleeve(
            axis: Vec3(0, 0, -1), bottomMM: Vec3(4, 4, 0),
            innerDiameterMM: 0, outerDiameterMM: 3, heightMM: 2,
            offsetToPlatformMM: 0)
        var caughtExpectedError = false
        do {
            _ = try GuideBuilder.build(
                scan: plate.mesh, footprint: plate.footprint, sleeves: [sleeve],
                configuration: GuideConfiguration())
        } catch let error as GuideBuildError {
            if case .invalidSleeve = error { caughtExpectedError = true }
        } catch {
            caughtExpectedError = false
        }
        #expect(caughtExpectedError)
    }

    @Test("Un triangolo con indice invalido rende la mesh non stampabile")
    func invalidTriangleIndexFailsValidation() {
        let mesh = Mesh(
            verticesMM: [
                Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1),
            ],
            triangles: [
                Triangle(a: 0, b: 2, c: 1), Triangle(a: 0, b: 1, c: 3),
                Triangle(a: 1, b: 2, c: 3), Triangle(a: 2, b: 0, c: 3),
                Triangle(a: 0, b: 1, c: 99),
            ],
            name: "tetraedro con indice invalido")
        let validation = GuideValidation.inspect(mesh: mesh, minimumWallThicknessMM: 1)
        #expect(!validation.isWatertight)
        #expect(!validation.hasConsistentOrientation)
        #expect(!validation.isPrintable)
    }

    @Test("L'export rifiuta una mesh non stampabile")
    func exportRejectsInvalidMesh() {
        let mesh = Mesh(
            verticesMM: [.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
            triangles: [Triangle(a: 0, b: 1, c: 2)], name: "aperta")
        let validation = GuideValidation.inspect(mesh: mesh, minimumWallThicknessMM: 1)
        let result = GuideResult(mesh: mesh, validation: validation, sleeves: [])
        #expect(throws: GuideExportError.self) { _ = try GuideExport.stl(result) }
    }

    private func plateMesh(includeBoundary: Bool = false) -> (mesh: Mesh, footprint: RegionMask) {
        let side = 9
        var vertices: [Vec3] = []
        for y in 0..<side {
            for x in 0..<side { vertices.append(Vec3(Double(x), Double(y), 0)) }
        }
        var triangles: [Triangle] = []
        for y in 0..<(side - 1) {
            for x in 0..<(side - 1) {
                let a = y * side + x
                triangles.append(Triangle(a: a, b: a + 1, c: a + side + 1))
                triangles.append(Triangle(a: a, b: a + side + 1, c: a + side))
            }
        }
        var mask = RegionMask(vertexCount: vertices.count)
        mask.excludeAll()
        let centre = includeBoundary ? Vec3(0, 4, 0) : Vec3(4, 4, 0)
        mask.include(sphereCentreMM: centre, radiusMM: 0.6, vertices: vertices)
        return (Mesh(verticesMM: vertices, triangles: triangles, name: "piastra"), mask)
    }
}

private func segmentIntersectionCount(start: Vec3, end: Vec3, mesh: Mesh) -> Int {
    let direction = end - start
    var count = 0
    for triangle in mesh.triangles {
        guard triangle.a >= 0, triangle.a < mesh.verticesMM.count,
              triangle.b >= 0, triangle.b < mesh.verticesMM.count,
              triangle.c >= 0, triangle.c < mesh.verticesMM.count
        else { continue }
        let a = mesh.verticesMM[triangle.a]
        let b = mesh.verticesMM[triangle.b]
        let c = mesh.verticesMM[triangle.c]
        let edge1 = b - a
        let edge2 = c - a
        let p = direction.cross(edge2)
        let determinant = edge1.dot(p)
        if abs(determinant) < 1e-12 { continue }
        let inverse = 1 / determinant
        let tVector = start - a
        let u = tVector.dot(p) * inverse
        if u < 0 || u > 1 { continue }
        let q = tVector.cross(edge1)
        let v = direction.dot(q) * inverse
        if v < 0 || u + v > 1 { continue }
        let t = edge2.dot(q) * inverse
        if t >= 0, t <= 1 { count += 1 }
    }
    return count
}

private func fill(_ field: inout ScalarField, _ value: (Vec3) -> Double) {
    let grid = field.grid
    for z in 0..<grid.countZ {
        for y in 0..<grid.countY {
            for x in 0..<grid.countX {
                field.setValue(value(grid.position(x: x, y: y, z: z)), x: x, y: y, z: z)
            }
        }
    }
}
