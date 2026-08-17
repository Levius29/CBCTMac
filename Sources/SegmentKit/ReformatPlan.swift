import Foundation
import DICOMCore

/// Faccia modificabile di un riquadro Patient allineato agli assi.
public enum BoxFace: Hashable, Sendable, Codable, CaseIterable {
    case minX
    case maxX
    case minY
    case maxY
    case minZ
    case maxZ
}

/// Descrittore condiviso dalle tre viste dello strumento di riformattazione.
public struct ReformatPlan: Hashable, Sendable, Codable {
    /// Unico riquadro Patient condiviso dalle tre viste ortogonali.
    public var regionMM: BoxMM
    /// Passo isotropo richiesto per il volume risultante.
    public var spacingMM: Double
    /// Nome mostrato nell'elenco dei volumi.
    public var name: String
    /// Annotazione libera associata al volume riformattato.
    public var notes: String

    /// Costruisce un piano esplicito senza correggere silenziosamente i valori inseriti.
    public init(regionMM: BoxMM, spacingMM: Double, name: String, notes: String) {
        self.regionMM = regionMM
        self.spacingMM = spacingMM
        self.name = name
        self.notes = notes
    }

    /// Costruisce il piano iniziale sull'intero volume, compresi i bordi esterni dei voxel.
    public static func full(for geometry: VolumeGeometry, spacingMM: Double) -> ReformatPlan {
        ReformatPlan(
            regionMM: Self.patientBounds(of: geometry),
            spacingMM: spacingMM,
            name: "Volume riformattato",
            notes: ""
        )
    }

    /// Numero di voxel che il riquadro produrrebbe, senza effettuare allocazioni.
    public func estimatedVoxelCount() -> Int {
        guard spacingMM.isFinite, spacingMM > 0,
              regionMM.minMM.isFinite, regionMM.maxMM.isFinite
        else { return 0 }
        let size = regionMM.sizeMM
        guard size.x > 0, size.y > 0, size.z > 0 else { return 0 }
        guard let columns = estimatedCount(size.x),
              let rows = estimatedCount(size.y),
              let slices = estimatedCount(size.z)
        else { return Int.max }
        let (plane, planeOverflow) = columns.multipliedReportingOverflow(by: rows)
        guard !planeOverflow else { return Int.max }
        let (count, countOverflow) = plane.multipliedReportingOverflow(by: slices)
        return countOverflow ? Int.max : count
    }

    /// Memoria dei soli campioni `Int16`, in byte, saturata se non rappresentabile.
    public func estimatedBytes() -> Int {
        let count = estimatedVoxelCount()
        let (bytes, overflow) = count.multipliedReportingOverflow(by: MemoryLayout<Int16>.stride)
        return overflow ? Int.max : bytes
    }

    /// Sposta una faccia entro il volume senza consentire l'inversione del riquadro.
    ///
    /// Il margine minimo è un voxel del passo richiesto: bloccare l'inversione qui evita che un
    /// trascinamento produca molto più tardi conteggi negativi o allocazioni insensate.
    public mutating func moveFace(
        _ face: BoxFace,
        toMM value: Double,
        within geometry: VolumeGeometry
    ) {
        guard value.isFinite else { return }
        let bounds = Self.patientBounds(of: geometry)
        regionMM = regionMM.clamped(to: bounds)
        let requestedMargin = spacingMM.isFinite && spacingMM > 0
            ? spacingMM
            : min(
                geometry.columnSpacingMM,
                min(geometry.rowSpacingMM, geometry.sliceSpacingMM)
            )
        let marginX = min(requestedMargin, bounds.maxMM.x - bounds.minMM.x)
        let marginY = min(requestedMargin, bounds.maxMM.y - bounds.minMM.y)
        let marginZ = min(requestedMargin, bounds.maxMM.z - bounds.minMM.z)
        let x = normalizedInterval(
            minimum: regionMM.minMM.x,
            maximum: regionMM.maxMM.x,
            boundMinimum: bounds.minMM.x,
            boundMaximum: bounds.maxMM.x,
            margin: marginX
        )
        let y = normalizedInterval(
            minimum: regionMM.minMM.y,
            maximum: regionMM.maxMM.y,
            boundMinimum: bounds.minMM.y,
            boundMaximum: bounds.maxMM.y,
            margin: marginY
        )
        let z = normalizedInterval(
            minimum: regionMM.minMM.z,
            maximum: regionMM.maxMM.z,
            boundMinimum: bounds.minMM.z,
            boundMaximum: bounds.maxMM.z,
            margin: marginZ
        )
        regionMM = BoxMM(
            minMM: Vec3(x.minimum, y.minimum, z.minimum),
            maxMM: Vec3(x.maximum, y.maximum, z.maximum)
        )

        switch face {
        case .minX:
            regionMM.minMM.x = max(bounds.minMM.x, min(value, regionMM.maxMM.x - marginX))
        case .maxX:
            regionMM.maxMM.x = min(bounds.maxMM.x, max(value, regionMM.minMM.x + marginX))
        case .minY:
            regionMM.minMM.y = max(bounds.minMM.y, min(value, regionMM.maxMM.y - marginY))
        case .maxY:
            regionMM.maxMM.y = min(bounds.maxMM.y, max(value, regionMM.minMM.y + marginY))
        case .minZ:
            regionMM.minMM.z = max(bounds.minMM.z, min(value, regionMM.maxMM.z - marginZ))
        case .maxZ:
            regionMM.maxMM.z = min(bounds.maxMM.z, max(value, regionMM.minMM.z + marginZ))
        }
    }

    /// Elenca i problemi che impedirebbero un ricampionamento sicuro.
    public func validate(against geometry: VolumeGeometry) -> [String] {
        var issues = [String]()
        if !spacingMM.isFinite || spacingMM <= 0 {
            issues.append("Il passo isotropo deve essere finito e maggiore di zero.")
        }
        let finiteBox = regionMM.minMM.isFinite && regionMM.maxMM.isFinite
        let orderedBox = finiteBox
            && regionMM.minMM.x < regionMM.maxMM.x
            && regionMM.minMM.y < regionMM.maxMM.y
            && regionMM.minMM.z < regionMM.maxMM.z
        if !orderedBox {
            issues.append("Il riquadro deve avere estremi finiti e ordinati.")
        } else {
            let bounds = Self.patientBounds(of: geometry)
            if !intersects(regionMM, bounds) {
                issues.append("Il riquadro non interseca il volume.")
            } else if regionMM.minMM.x < bounds.minMM.x
                || regionMM.minMM.y < bounds.minMM.y
                || regionMM.minMM.z < bounds.minMM.z
                || regionMM.maxMM.x > bounds.maxMM.x
                || regionMM.maxMM.y > bounds.maxMM.y
                || regionMM.maxMM.z > bounds.maxMM.z
            {
                issues.append("Il riquadro supera i limiti Patient del volume.")
            }
        }
        if spacingMM.isFinite, spacingMM > 0, estimatedVoxelCount() == Int.max {
            issues.append("Il conteggio dei voxel non è rappresentabile.")
        }
        return issues
    }

    private func estimatedCount(_ extentMM: Double) -> Int? {
        let value = ceil(extentMM / spacingMM)
        guard value.isFinite, value >= 1, value <= Double(Int.max) else { return nil }
        return Int(exactly: value)
    }

    private func normalizedInterval(
        minimum: Double,
        maximum: Double,
        boundMinimum: Double,
        boundMaximum: Double,
        margin: Double
    ) -> (minimum: Double, maximum: Double) {
        var lower = min(max(minimum, boundMinimum), boundMaximum)
        var upper = min(max(maximum, boundMinimum), boundMaximum)
        if upper < lower { swap(&lower, &upper) }
        guard upper - lower < margin else { return (lower, upper) }
        let centre = (lower + upper) * 0.5
        lower = max(boundMinimum, min(centre - margin * 0.5, boundMaximum - margin))
        upper = lower + margin
        return (lower, upper)
    }

    private static func patientBounds(of geometry: VolumeGeometry) -> BoxMM {
        var minimum = Vec3(Double.infinity, Double.infinity, Double.infinity)
        var maximum = Vec3(-Double.infinity, -Double.infinity, -Double.infinity)
        for point in geometry.boundingBoxCornersMM {
            minimum = Vec3(
                min(minimum.x, point.x),
                min(minimum.y, point.y),
                min(minimum.z, point.z)
            )
            maximum = Vec3(
                max(maximum.x, point.x),
                max(maximum.y, point.y),
                max(maximum.z, point.z)
            )
        }
        return BoxMM(minMM: minimum, maxMM: maximum)
    }

    private func intersects(_ first: BoxMM, _ second: BoxMM) -> Bool {
        first.maxMM.x > second.minMM.x && first.minMM.x < second.maxMM.x
            && first.maxMM.y > second.minMM.y && first.minMM.y < second.maxMM.y
            && first.maxMM.z > second.minMM.z && first.minMM.z < second.maxMM.z
    }
}
