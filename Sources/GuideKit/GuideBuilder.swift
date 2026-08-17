import Foundation
import DICOMCore
import MeshKit

/// Parametri geometrici per la costruzione di una dima.
public struct GuideConfiguration: Hashable, Sendable, Codable {
    public var fitToleranceMM: Double
    public var wallThicknessMM: Double
    public var gridSpacingMM: Double
    public var footprintRadiusMM: Double
    public var minimumRimMarginMM: Double
    /// Finestre e fori applicati per sottrazione dopo l'unione delle boccole.
    public var features: [GuideFeature]

    public init() {
        fitToleranceMM = 0.1
        wallThicknessMM = 2.5
        gridSpacingMM = 0.5
        footprintRadiusMM = 4.0
        minimumRimMarginMM = 2.0
        features = []
    }
}

/// Esito delle verifiche che precedono l'esportazione alla stampante.
public struct GuideValidation: Sendable {
    public let isWatertight: Bool
    public let hasConsistentOrientation: Bool
    public let minimumWallThicknessMM: Double?
    public let volumeMM3: Double
    public let warnings: [String]

    public init(
        isWatertight: Bool,
        hasConsistentOrientation: Bool,
        minimumWallThicknessMM: Double?,
        volumeMM3: Double,
        warnings: [String]
    ) {
        self.isWatertight = isWatertight
        self.hasConsistentOrientation = hasConsistentOrientation
        self.minimumWallThicknessMM = minimumWallThicknessMM
        self.volumeMM3 = volumeMM3
        self.warnings = warnings
    }

    public var isPrintable: Bool {
        guard let thickness = minimumWallThicknessMM else { return false }
        return isWatertight && hasConsistentOrientation
            && volumeMM3.isFinite && volumeMM3 > 0
            && thickness.isFinite && thickness > 0
    }

    /// Ispeziona connettività, winding e volume di una mesh.
    public static func inspect(
        mesh: Mesh,
        minimumWallThicknessMM: Double?,
        additionalWarnings: [String] = []
    ) -> GuideValidation {
        var edges: [ValidationEdge: ValidationEdgeUse] = [:]
        var hasInvalidTriangles = false
        for triangle in mesh.triangles {
            guard triangle.a >= 0, triangle.a < mesh.verticesMM.count,
                  triangle.b >= 0, triangle.b < mesh.verticesMM.count,
                  triangle.c >= 0, triangle.c < mesh.verticesMM.count
            else {
                hasInvalidTriangles = true
                continue
            }
            addEdge(from: triangle.a, to: triangle.b, uses: &edges)
            addEdge(from: triangle.b, to: triangle.c, uses: &edges)
            addEdge(from: triangle.c, to: triangle.a, uses: &edges)
        }

        var watertight = !mesh.triangles.isEmpty && !hasInvalidTriangles
        var orientation = !mesh.triangles.isEmpty && !hasInvalidTriangles
        for use in edges.values {
            if use.count != 2 { watertight = false }
            if use.count == 2, use.directionBalance != 0 { orientation = false }
            if use.count > 2 { orientation = false }
        }

        let volume = abs(mesh.signedVolumeMM3())
        var warnings = additionalWarnings
        if !watertight { warnings.append("La mesh presenta bordi aperti o non-manifold.") }
        if !orientation { warnings.append("L'orientamento dei triangoli non è coerente.") }
        if hasInvalidTriangles {
            warnings.append("La mesh contiene indici di triangolo non validi.")
        }
        if volume <= 0 || !volume.isFinite { warnings.append("Il volume della dima non è valido.") }
        if let thickness = minimumWallThicknessMM {
            if !thickness.isFinite || thickness <= 0 {
                warnings.append("Lo spessore minimo della parete non è valido.")
            }
        } else {
            warnings.append("Lo spessore minimo della parete non è disponibile.")
        }
        return GuideValidation(
            isWatertight: watertight,
            hasConsistentOrientation: orientation,
            minimumWallThicknessMM: minimumWallThicknessMM,
            volumeMM3: volume.isFinite ? volume : 0,
            warnings: warnings)
    }

    private static func addEdge(
        from: Int,
        to: Int,
        uses: inout [ValidationEdge: ValidationEdgeUse]
    ) {
        let edge = ValidationEdge(from, to)
        var use = uses[edge] ?? ValidationEdgeUse(count: 0, directionBalance: 0)
        use.count += 1
        use.directionBalance += from < to ? 1 : -1
        uses[edge] = use
    }
}

/// Mesh finale, verifica e boccole che l'hanno generata.
public struct GuideResult: Sendable {
    public let mesh: Mesh
    public let validation: GuideValidation
    public let sleeves: [GuideSleeve]

    public init(mesh: Mesh, validation: GuideValidation, sleeves: [GuideSleeve]) {
        self.mesh = mesh
        self.validation = validation
        self.sleeves = sleeves
    }
}

/// Errori nominati che impediscono la costruzione di una dima affidabile.
public enum GuideBuildError: Error, Hashable, Sendable, LocalizedError {
    case emptyFootprint
    case gridTooCoarse(spacingMM: Double, thinnestFeatureMM: Double)
    case gridTooLarge(cellCount: Int, limit: Int)
    case footprintTooCloseToRim(marginMM: Double, requiredMM: Double)
    case sleeveOutsideGuide(index: Int)
    case invalidSleeve(index: Int, detail: String)
    case emptyResult
    case invalidConfiguration(detail: String)

    public var errorDescription: String? {
        switch self {
        case .emptyFootprint:
            return "L'impronta della dima è vuota."
        case .gridTooCoarse(let spacing, let feature):
            return "Passo griglia \(spacing) mm troppo grande per la caratteristica minima "
                + "di \(feature) mm: deve essere al massimo un terzo."
        case .gridTooLarge(let count, let limit):
            return "La griglia richiede \(count) campioni, oltre il limite di \(limit)."
        case .footprintTooCloseToRim(let margin, let required):
            return "L'impronta dista solo \(margin) mm dal bordo della scansione; "
                + "sono richiesti almeno \(required) mm."
        case .sleeveOutsideGuide(let index):
            return "La boccola all'indice \(index) non interseca il corpo della dima."
        case .invalidSleeve(let index, let detail):
            return "La boccola all'indice \(index) non è valida: \(detail)."
        case .emptyResult:
            return "Le operazioni sul campo hanno prodotto una dima vuota."
        case .invalidConfiguration(let detail):
            return "Configurazione della dima non valida: \(detail)."
        }
    }
}

/// Ispezioni e accessi sottratti al corpo della dima.
public enum GuideFeature: Hashable, Sendable, Codable {
    case inspectionWindow(
        centreMM: Vec3, axis: Vec3, widthMM: Double, heightMM: Double)
    case irrigationHole(centreMM: Vec3, axis: Vec3, diameterMM: Double)
}

/// Composizione robusta della dima mediante operazioni `min`/`max` su campi scalari.
public enum GuideBuilder: Sendable {
    public static func build(
        scan: Mesh,
        footprint: RegionMask,
        sleeves: [GuideSleeve],
        configuration: GuideConfiguration
    ) throws -> GuideResult {
        try validateConfiguration(configuration, sleeves: sleeves)
        let footprintPoints = footprint.includedPoints(from: scan.verticesMM)
        guard !footprintPoints.isEmpty else { throw GuideBuildError.emptyFootprint }

        let boundarySegments = meshBoundarySegments(scan)
        let rimMargin = minimumDistance(points: footprintPoints, segments: boundarySegments)
        if rimMargin < configuration.minimumRimMarginMM {
            throw GuideBuildError.footprintTooCloseToRim(
                marginMM: rimMargin, requiredMM: configuration.minimumRimMarginMM)
        }

        let bounds = pointBounds(footprintPoints)
        guard let bounds else { throw GuideBuildError.emptyFootprint }
        let expansion = configuration.footprintRadiusMM
            + configuration.wallThicknessMM + configuration.fitToleranceMM
        let minimum = bounds.minimum - Vec3(expansion, expansion, expansion)
        let maximum = bounds.maximum + Vec3(expansion, expansion, expansion)

        let estimated = estimatedCellCount(
            minimum: minimum, maximum: maximum,
            spacing: configuration.gridSpacingMM, padding: 2)
        if estimated > FieldGrid.maximumCellCount {
            throw GuideBuildError.gridTooLarge(
                cellCount: estimated, limit: FieldGrid.maximumCellCount)
        }
        guard let grid = FieldGrid(
            boundsMinMM: minimum, boundsMaxMM: maximum,
            spacingMM: configuration.gridSpacingMM, paddingCells: 2)
        else {
            throw GuideBuildError.invalidConfiguration(detail: "bounds o passo della griglia")
        }

        for index in sleeves.indices {
            guard sleeveFitsGrid(sleeves[index], grid: grid) else {
                throw GuideBuildError.sleeveOutsideGuide(index: index)
            }
        }

        let maxDistance = configuration.fitToleranceMM + configuration.wallThicknessMM
            + configuration.gridSpacingMM * 3
        let scanField = try MeshDistanceField.build(
            from: scan, grid: grid, maxDistanceMM: maxDistance)
        var body = scanField
        body.map { (distance: Double) -> Double in
            max(
                configuration.fitToleranceMM - distance,
                distance - (configuration.fitToleranceMM + configuration.wallThicknessMM))
        }

        let footprintField = distanceToFootprintField(
            points: footprintPoints, grid: grid,
            radiusMM: configuration.footprintRadiusMM)
        try body.combine(footprintField) { (left: Double, right: Double) -> Double in
            max(left, right)
        }

        for index in sleeves.indices {
            let housing = sleeves[index].housingField(grid: grid)
            guard fieldsOverlap(body, housing) else {
                throw GuideBuildError.sleeveOutsideGuide(index: index)
            }
            try body.combine(housing) { (left: Double, right: Double) -> Double in
                min(left, right)
            }
            let bore = sleeves[index].boreField(grid: grid)
            try body.combine(bore) { (left: Double, right: Double) -> Double in
                max(left, -right)
            }
        }

        for feature in configuration.features {
            let featureField = subtractiveField(feature, grid: grid)
            try body.combine(featureField) { (left: Double, right: Double) -> Double in
                max(left, -right)
            }
        }

        let mesh = MarchingCubes.surface(from: body, isoLevel: 0, name: "Dima")
        guard !mesh.verticesMM.isEmpty, !mesh.triangles.isEmpty else {
            throw GuideBuildError.emptyResult
        }
        let measuredThickness = measureMinimumWallThickness(
            scan: scan,
            footprint: footprint,
            sleeves: sleeves,
            finalField: body,
            configuration: configuration)
        let validation = GuideValidation.inspect(
            mesh: mesh,
            minimumWallThicknessMM: measuredThickness)
        return GuideResult(mesh: mesh, validation: validation, sleeves: sleeves)
    }

    private static func validateConfiguration(
        _ configuration: GuideConfiguration,
        sleeves: [GuideSleeve]
    ) throws {
        let values = [
            configuration.fitToleranceMM, configuration.wallThicknessMM,
            configuration.gridSpacingMM, configuration.footprintRadiusMM,
            configuration.minimumRimMarginMM,
        ]
        guard values.allSatisfy({ (value: Double) -> Bool in value.isFinite }),
              configuration.fitToleranceMM >= 0,
              configuration.wallThicknessMM > 0,
              configuration.gridSpacingMM > 0,
              configuration.footprintRadiusMM > 0,
              configuration.minimumRimMarginMM >= 0
        else {
            throw GuideBuildError.invalidConfiguration(detail: "misure non finite o non positive")
        }

        var thinnest = configuration.wallThicknessMM
        for index in sleeves.indices {
            let sleeve = sleeves[index]
            guard sleeve.axis.isFinite, sleeve.axis.normalized != nil,
                  sleeve.bottomMM.isFinite,
                  sleeve.innerDiameterMM.isFinite, sleeve.innerDiameterMM > 0,
                  sleeve.outerDiameterMM.isFinite,
                  sleeve.outerDiameterMM > sleeve.innerDiameterMM,
                  sleeve.heightMM.isFinite, sleeve.heightMM > 0,
                  sleeve.offsetToPlatformMM.isFinite, sleeve.offsetToPlatformMM >= 0
            else {
                throw GuideBuildError.invalidSleeve(
                    index: index,
                    detail: "asse, diametri, altezza o offset non validi")
            }
            let sleeveWall = (sleeve.outerDiameterMM - sleeve.innerDiameterMM) / 2
            thinnest = min(
                thinnest,
                min(sleeve.innerDiameterMM, min(sleeveWall, sleeve.heightMM)))
        }
        for feature in configuration.features {
            switch feature {
            case .irrigationHole(let centre, let axis, let diameter):
                guard centre.isFinite, axis.isFinite, axis.normalized != nil,
                      diameter.isFinite, diameter > 0
                else {
                    throw GuideBuildError.invalidConfiguration(
                        detail: "foro d'irrigazione non valido")
                }
                thinnest = min(thinnest, diameter)
            case .inspectionWindow(let centre, let axis, let width, let height):
                guard centre.isFinite, axis.isFinite, axis.normalized != nil,
                      width.isFinite, width > 0,
                      height.isFinite, height > 0
                else {
                    throw GuideBuildError.invalidConfiguration(
                        detail: "finestra d'ispezione non valida")
                }
                thinnest = min(thinnest, min(width, height))
            }
        }
        if configuration.gridSpacingMM > thinnest / 3 {
            throw GuideBuildError.gridTooCoarse(
                spacingMM: configuration.gridSpacingMM,
                thinnestFeatureMM: thinnest)
        }
    }

    private static func pointBounds(
        _ points: [Vec3]
    ) -> (minimum: Vec3, maximum: Vec3)? {
        guard let first = points.first, first.isFinite else { return nil }
        var minimum = first
        var maximum = first
        for point in points {
            guard point.isFinite else { continue }
            minimum = Vec3(
                min(minimum.x, point.x), min(minimum.y, point.y), min(minimum.z, point.z))
            maximum = Vec3(
                max(maximum.x, point.x), max(maximum.y, point.y), max(maximum.z, point.z))
        }
        return (minimum, maximum)
    }

    private static func estimatedCellCount(
        minimum: Vec3, maximum: Vec3, spacing: Double, padding: Int
    ) -> Int {
        guard spacing.isFinite, spacing > 0 else { return Int.max }
        func count(_ low: Double, _ high: Double) -> Int? {
            let value = Foundation.ceil((high - low) / spacing) + 1 + Double(padding * 2)
            return Int(exactly: value)
        }
        guard let x = count(minimum.x, maximum.x),
              let y = count(minimum.y, maximum.y),
              let z = count(minimum.z, maximum.z)
        else { return Int.max }
        let xy = x.multipliedReportingOverflow(by: y)
        let xyz = xy.partialValue.multipliedReportingOverflow(by: z)
        guard !xy.overflow, !xyz.overflow else { return Int.max }
        return xyz.partialValue
    }

    private static func distanceToFootprintField(
        points: [Vec3], grid: FieldGrid, radiusMM: Double
    ) -> ScalarField {
        var field = ScalarField(grid: grid, initialValue: radiusMM + grid.spacingMM)
        for z in 0..<grid.countZ {
            for y in 0..<grid.countY {
                for x in 0..<grid.countX {
                    let position = grid.position(x: x, y: y, z: z)
                    var nearest = Double.infinity
                    for point in points {
                        let distance = position.distance(to: point)
                        if distance < nearest { nearest = distance }
                    }
                    field.setValue(nearest - radiusMM, x: x, y: y, z: z)
                }
            }
        }
        return field
    }

    private static func fieldsOverlap(_ first: ScalarField, _ second: ScalarField) -> Bool {
        guard first.grid == second.grid, first.values.count == second.values.count else {
            return false
        }
        var index = 0
        while index < first.values.count {
            if first.values[index] <= 0, second.values[index] <= 0 { return true }
            index += 1
        }
        return false
    }

    /// Misura la distanza fra le due isosuperfici finali lungo le normali dell'impronta.
    ///
    /// Si usa il campo già composto, non il valore nominale: così assottigliamenti introdotti
    /// da boccole o sottrazioni entrano davvero nella validazione e non vengono nascosti dalla
    /// configurazione richiesta.
    private static func measureMinimumWallThickness(
        scan: Mesh,
        footprint: RegionMask,
        sleeves: [GuideSleeve],
        finalField: ScalarField,
        configuration: GuideConfiguration
    ) -> Double? {
        let normals = scan.vertexNormals()
        let step = configuration.gridSpacingMM / 4
        guard step.isFinite, step > 0 else { return nil }
        let startDistance = -configuration.gridSpacingMM
        let endDistance = configuration.fitToleranceMM + configuration.wallThicknessMM
            + configuration.gridSpacingMM
        var minimumThickness = Double.infinity

        let count = min(scan.verticesMM.count, normals.count)
        for index in 0..<count where footprint.isIncluded(index) {
            let point = scan.verticesMM[index]
            guard point.isFinite, let normal = normals[index].normalized else { continue }
            if let thickness = firstSolidSegmentThickness(
                field: finalField,
                origin: point,
                direction: normal,
                startDistance: startDistance,
                endDistance: endDistance,
                step: step)
            {
                minimumThickness = min(minimumThickness, thickness)
            }
        }

        // Le normali della scansione misurano la parete del corpo ma non quella anulare delle
        // boccole. La si campiona separatamente in più sezioni e direzioni radiali; usare il
        // campo finale fa entrare nella misura anche finestre o fori che la intercettano.
        for sleeve in sleeves {
            guard let axis = sleeve.axis.normalized else { continue }
            let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            guard let u = helper.cross(axis).normalized,
                  let v = axis.cross(u).normalized
            else { continue }
            let centre = sleeve.bottomMM - axis * (sleeve.heightMM / 2)
            let axialOffsets = [
                -sleeve.heightMM * 0.4, 0, sleeve.heightMM * 0.4,
            ]
            for axialOffset in axialOffsets {
                let sectionCentre = centre + axis * axialOffset
                for angleIndex in 0..<16 {
                    let angle = 2 * Double.pi * Double(angleIndex) / 16
                    let radial = u * Foundation.cos(angle) + v * Foundation.sin(angle)
                    if let thickness = firstSolidSegmentThickness(
                        field: finalField,
                        origin: sectionCentre,
                        direction: radial,
                        startDistance: 0,
                        endDistance: sleeve.outerDiameterMM / 2
                            + configuration.gridSpacingMM,
                        step: step)
                    {
                        minimumThickness = min(minimumThickness, thickness)
                    }
                }
            }
        }
        return minimumThickness.isFinite ? minimumThickness : nil
    }

    /// Restituisce lo spessore del primo intervallo interno incontrato lungo una semiretta.
    private static func firstSolidSegmentThickness(
        field: ScalarField,
        origin: Vec3,
        direction: Vec3,
        startDistance: Double,
        endDistance: Double,
        step: Double
    ) -> Double? {
        var crossings: [Double] = []
        var previousDistance = startDistance
        guard var previousValue = field.interpolated(
            atMM: origin + direction * previousDistance)
        else { return nil }

        var distance = startDistance + step
        while distance <= endDistance + step * 0.5, crossings.count < 3 {
            guard let value = field.interpolated(atMM: origin + direction * distance) else {
                break
            }
            let crosses = (previousValue > 0 && value <= 0)
                || (previousValue <= 0 && value > 0)
            if crosses {
                let denominator = value - previousValue
                let fraction: Double
                if denominator.isFinite, abs(denominator) > 1e-15 {
                    fraction = min(max(-previousValue / denominator, 0), 1)
                } else {
                    fraction = 0.5
                }
                crossings.append(previousDistance + (distance - previousDistance) * fraction)
            }
            previousDistance = distance
            previousValue = value
            distance += step
        }
        guard crossings.count >= 2 else { return nil }
        let thickness = crossings[1] - crossings[0]
        guard thickness.isFinite, thickness > 0 else { return nil }
        return thickness
    }

    private static func sleeveFitsGrid(_ sleeve: GuideSleeve, grid: FieldGrid) -> Bool {
        let direction = sleeve.axis.normalized ?? Vec3(0, 0, -1)
        let top = sleeve.bottomMM - direction * sleeve.heightMM
        let radius = sleeve.outerDiameterMM / 2 + grid.spacingMM
        let minimum = grid.originMM
        let maximum = grid.position(
            x: grid.countX - 1, y: grid.countY - 1, z: grid.countZ - 1)
        for point in [sleeve.bottomMM, top] {
            if point.x - radius < minimum.x || point.x + radius > maximum.x
                || point.y - radius < minimum.y || point.y + radius > maximum.y
                || point.z - radius < minimum.z || point.z + radius > maximum.z
            {
                return false
            }
        }
        return true
    }

    private static func meshBoundarySegments(_ mesh: Mesh) -> [BoundarySegment] {
        var counts: [ValidationEdge: Int] = [:]
        for triangle in mesh.triangles {
            for edge in [
                ValidationEdge(triangle.a, triangle.b),
                ValidationEdge(triangle.b, triangle.c),
                ValidationEdge(triangle.c, triangle.a),
            ] {
                counts[edge, default: 0] += 1
            }
        }
        var segments: [BoundarySegment] = []
        for (edge, count) in counts where count == 1 {
            guard edge.lower >= 0, edge.lower < mesh.verticesMM.count,
                  edge.upper >= 0, edge.upper < mesh.verticesMM.count
            else { continue }
            segments.append(
                BoundarySegment(
                    a: mesh.verticesMM[edge.lower], b: mesh.verticesMM[edge.upper]))
        }
        return segments
    }

    private static func minimumDistance(
        points: [Vec3], segments: [BoundarySegment]
    ) -> Double {
        guard !segments.isEmpty else { return .infinity }
        var minimum = Double.infinity
        for point in points {
            for segment in segments {
                minimum = min(minimum, pointToSegmentDistance(point, segment))
            }
        }
        return minimum
    }

    private static func pointToSegmentDistance(
        _ point: Vec3, _ segment: BoundarySegment
    ) -> Double {
        let direction = segment.b - segment.a
        let denominator = direction.lengthSquared
        guard denominator.isFinite, denominator > 0 else {
            return point.distance(to: segment.a)
        }
        let t = min(max((point - segment.a).dot(direction) / denominator, 0), 1)
        return point.distance(to: segment.a + direction * t)
    }

    private static func subtractiveField(
        _ feature: GuideFeature, grid: FieldGrid
    ) -> ScalarField {
        switch feature {
        case .irrigationHole(let centre, let rawAxis, let diameter):
            let axis = rawAxis.normalized ?? Vec3(0, 0, 1)
            var field = ScalarField(grid: grid, initialValue: .infinity)
            for z in 0..<grid.countZ {
                for y in 0..<grid.countY {
                    for x in 0..<grid.countX {
                        let relative = grid.position(x: x, y: y, z: z) - centre
                        let radial = (relative - axis * relative.dot(axis)).length
                        field.setValue(radial - diameter / 2, x: x, y: y, z: z)
                    }
                }
            }
            return field

        case .inspectionWindow(let centre, let rawAxis, let width, let height):
            let axis = rawAxis.normalized ?? Vec3(0, 0, 1)
            let helper = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
            let u = helper.cross(axis).normalized ?? Vec3(1, 0, 0)
            let v = axis.cross(u).normalized ?? Vec3(0, 1, 0)
            let depth = Double(max(grid.countX, max(grid.countY, grid.countZ))) * grid.spacingMM
            var field = ScalarField(grid: grid, initialValue: .infinity)
            for z in 0..<grid.countZ {
                for y in 0..<grid.countY {
                    for x in 0..<grid.countX {
                        let relative = grid.position(x: x, y: y, z: z) - centre
                        let qx = abs(relative.dot(u)) - width / 2
                        let qy = abs(relative.dot(v)) - height / 2
                        let qz = abs(relative.dot(axis)) - depth / 2
                        let outside = Vec3(max(qx, 0), max(qy, 0), max(qz, 0)).length
                        let inside = min(max(qx, max(qy, qz)), 0)
                        field.setValue(outside + inside, x: x, y: y, z: z)
                    }
                }
            }
            return field
        }
    }
}

private struct ValidationEdge: Hashable {
    let lower: Int
    let upper: Int

    init(_ first: Int, _ second: Int) {
        lower = min(first, second)
        upper = max(first, second)
    }
}

private struct ValidationEdgeUse {
    var count: Int
    var directionBalance: Int
}

private struct BoundarySegment {
    let a: Vec3
    let b: Vec3
}
