import Foundation
import DICOMCore

/// Errori delle operazioni fra campi scalari.
public enum ScalarFieldError: Error, Hashable, Sendable, LocalizedError {
    case incompatibleGrids

    public var errorDescription: String? {
        switch self {
        case .incompatibleGrids:
            return "I campi scalari hanno griglie diverse e non possono essere combinati."
        }
    }
}

/// Griglia assiale isotropa usata per campionare un campo scalare.
///
/// Il costo cresce con il volume: una griglia da 400³ contiene 64 milioni di `Double`, circa
/// mezzo gigabyte. Per questo la costruzione si arresta prima di allocare oltre
/// `maximumCellCount`, e chi la usa deve limitare i bounds alla sola regione di lavoro.
public struct FieldGrid: Hashable, Sendable {
    /// Limite pubblico che impedisce a un input errato di richiedere allocazioni gigantesche.
    public static let maximumCellCount = 64_000_000

    /// Centro del campione con indici `(0,0,0)`.
    public let originMM: Vec3
    public let spacingMM: Double
    public let countX: Int
    public let countY: Int
    public let countZ: Int

    /// Crea una griglia che include i bounds e almeno una corona esterna di campioni.
    ///
    /// Il padding non può essere zero: marching cubes chiude una superficie soltanto quando
    /// il cambio di segno avviene dentro la griglia, lasciando campioni uniformemente esterni
    /// lungo tutto il bordo.
    public init?(
        boundsMinMM: Vec3,
        boundsMaxMM: Vec3,
        spacingMM: Double,
        paddingCells: Int = 2
    ) {
        guard boundsMinMM.isFinite, boundsMaxMM.isFinite,
              spacingMM.isFinite, spacingMM > 0,
              paddingCells >= 1,
              boundsMaxMM.x >= boundsMinMM.x,
              boundsMaxMM.y >= boundsMinMM.y,
              boundsMaxMM.z >= boundsMinMM.z
        else { return nil }

        guard let baseX = Self.axisCount(
            minimum: boundsMinMM.x, maximum: boundsMaxMM.x, spacing: spacingMM),
              let baseY = Self.axisCount(
                minimum: boundsMinMM.y, maximum: boundsMaxMM.y, spacing: spacingMM),
              let baseZ = Self.axisCount(
                minimum: boundsMinMM.z, maximum: boundsMaxMM.z, spacing: spacingMM)
        else { return nil }

        let paddingTwice = paddingCells.multipliedReportingOverflow(by: 2)
        guard !paddingTwice.overflow else { return nil }
        let x = baseX.addingReportingOverflow(paddingTwice.partialValue)
        let y = baseY.addingReportingOverflow(paddingTwice.partialValue)
        let z = baseZ.addingReportingOverflow(paddingTwice.partialValue)
        guard !x.overflow, !y.overflow, !z.overflow else { return nil }

        let xy = x.partialValue.multipliedReportingOverflow(by: y.partialValue)
        guard !xy.overflow else { return nil }
        let xyz = xy.partialValue.multipliedReportingOverflow(by: z.partialValue)
        guard !xyz.overflow, xyz.partialValue <= Self.maximumCellCount else { return nil }

        let paddingMM = Double(paddingCells) * spacingMM
        let origin = Vec3(
            boundsMinMM.x - paddingMM,
            boundsMinMM.y - paddingMM,
            boundsMinMM.z - paddingMM)
        guard origin.isFinite else { return nil }
        let last = Vec3(
            origin.x + Double(x.partialValue - 1) * spacingMM,
            origin.y + Double(y.partialValue - 1) * spacingMM,
            origin.z + Double(z.partialValue - 1) * spacingMM)
        guard last.isFinite else { return nil }

        self.originMM = origin
        self.spacingMM = spacingMM
        self.countX = x.partialValue
        self.countY = y.partialValue
        self.countZ = z.partialValue
    }

    /// Posizione del campione agli indici indicati.
    public func position(x: Int, y: Int, z: Int) -> Vec3 {
        Vec3(
            originMM.x + Double(x) * spacingMM,
            originMM.y + Double(y) * spacingMM,
            originMM.z + Double(z) * spacingMM)
    }

    public var cellCount: Int {
        countX * countY * countZ
    }

    private static func axisCount(
        minimum: Double, maximum: Double, spacing: Double
    ) -> Int? {
        let span = maximum - minimum
        guard span.isFinite else { return nil }
        let intervals = Foundation.ceil(span / spacing)
        guard intervals.isFinite, let count = Int(exactly: intervals), count < Int.max else {
            return nil
        }
        return count + 1
    }
}

/// Campo scalare campionato con `x` come indice più veloce.
public struct ScalarField: Sendable {
    public let grid: FieldGrid
    public private(set) var values: [Double]

    public init(grid: FieldGrid, initialValue: Double) {
        self.grid = grid
        self.values = [Double](repeating: initialValue, count: grid.cellCount)
    }

    /// Valore campionato; fuori griglia restituisce `+infinity` invece di leggere memoria
    /// invalida. Nelle composizioni di distanza questo equivale correttamente a “fuori”.
    public func value(x: Int, y: Int, z: Int) -> Double {
        guard let index = linearIndex(x: x, y: y, z: z) else { return .infinity }
        return values[index]
    }

    /// Interpolazione trilineare; restituisce `nil` fuori dalla griglia.
    public func interpolated(atMM point: Vec3) -> Double? {
        guard point.isFinite else { return nil }
        let fx = (point.x - grid.originMM.x) / grid.spacingMM
        let fy = (point.y - grid.originMM.y) / grid.spacingMM
        let fz = (point.z - grid.originMM.z) / grid.spacingMM
        guard fx.isFinite, fy.isFinite, fz.isFinite,
              fx >= 0, fy >= 0, fz >= 0,
              fx <= Double(grid.countX - 1),
              fy <= Double(grid.countY - 1),
              fz <= Double(grid.countZ - 1)
        else { return nil }

        let xPair = interpolationPair(fx, count: grid.countX)
        let yPair = interpolationPair(fy, count: grid.countY)
        let zPair = interpolationPair(fz, count: grid.countZ)
        guard let xPair, let yPair, let zPair else { return nil }

        let c000 = value(x: xPair.lower, y: yPair.lower, z: zPair.lower)
        let c100 = value(x: xPair.upper, y: yPair.lower, z: zPair.lower)
        let c010 = value(x: xPair.lower, y: yPair.upper, z: zPair.lower)
        let c110 = value(x: xPair.upper, y: yPair.upper, z: zPair.lower)
        let c001 = value(x: xPair.lower, y: yPair.lower, z: zPair.upper)
        let c101 = value(x: xPair.upper, y: yPair.lower, z: zPair.upper)
        let c011 = value(x: xPair.lower, y: yPair.upper, z: zPair.upper)
        let c111 = value(x: xPair.upper, y: yPair.upper, z: zPair.upper)

        let c00 = c000 + (c100 - c000) * xPair.fraction
        let c10 = c010 + (c110 - c010) * xPair.fraction
        let c01 = c001 + (c101 - c001) * xPair.fraction
        let c11 = c011 + (c111 - c011) * xPair.fraction
        let c0 = c00 + (c10 - c00) * yPair.fraction
        let c1 = c01 + (c11 - c01) * yPair.fraction
        return c0 + (c1 - c0) * zPair.fraction
    }

    /// Combina due campi cella per cella.
    public mutating func combine(
        _ other: ScalarField,
        using operation: (Double, Double) -> Double
    ) throws {
        guard grid == other.grid, values.count == other.values.count else {
            throw ScalarFieldError.incompatibleGrids
        }
        var index = 0
        while index < values.count {
            values[index] = operation(values[index], other.values[index])
            index += 1
        }
    }

    /// Trasforma ogni valore senza cambiare la griglia.
    public mutating func map(_ transform: (Double) -> Double) {
        var index = 0
        while index < values.count {
            values[index] = transform(values[index])
            index += 1
        }
    }

    /// Setter interno usato dai costruttori di campi e dai test analitici del modulo.
    mutating func setValue(_ value: Double, x: Int, y: Int, z: Int) {
        guard let index = linearIndex(x: x, y: y, z: z) else { return }
        values[index] = value
    }

    private func linearIndex(x: Int, y: Int, z: Int) -> Int? {
        guard x >= 0, x < grid.countX,
              y >= 0, y < grid.countY,
              z >= 0, z < grid.countZ
        else { return nil }
        return (z * grid.countY + y) * grid.countX + x
    }

    private func interpolationPair(
        _ coordinate: Double, count: Int
    ) -> (lower: Int, upper: Int, fraction: Double)? {
        guard count >= 2 else { return nil }
        if coordinate >= Double(count - 1) {
            return (count - 2, count - 1, 1)
        }
        let roundedDown = Foundation.floor(coordinate)
        guard let lower = Int(exactly: roundedDown), lower >= 0, lower + 1 < count else {
            return nil
        }
        return (lower, lower + 1, coordinate - roundedDown)
    }
}
