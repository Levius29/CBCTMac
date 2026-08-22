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
        // Il bloccaggio vive sul riquadro, dove appartiene: lo stesso serve al riquadro di sola
        // lettura, che non ricampiona niente. Vedi `BoxMM.moving(_:of:toMM:within:marginMM:)`.
        let margin = spacingMM.isFinite && spacingMM > 0
            ? spacingMM
            : min(
                geometry.columnSpacingMM,
                min(geometry.rowSpacingMM, geometry.sliceSpacingMM)
            )
        regionMM = BoxMM.moving(
            face, of: regionMM, toMM: value, within: geometry, marginMM: margin)
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

    /// Il riquadro che contiene tutto il volume. Una riga sola: la regola sta sul riquadro.
    private static func patientBounds(of geometry: VolumeGeometry) -> BoxMM {
        BoxMM.patientBounds(of: geometry)
    }

    private func intersects(_ first: BoxMM, _ second: BoxMM) -> Bool {
        first.maxMM.x > second.minMM.x && first.minMM.x < second.maxMM.x
            && first.maxMM.y > second.minMM.y && first.minMM.y < second.maxMM.y
            && first.maxMM.z > second.minMM.z && first.minMM.z < second.maxMM.z
    }
}
