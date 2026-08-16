import Foundation

// Tipi geometrici in Double, senza `simd`.
//
// Due ragioni per non usare `simd` qui (vedi docs/architecture.md § 3):
//
//  1. Precisione. `simd` è pensato per Float. Il contratto del progetto vuole Double per
//     geometria e misure: un arrotondamento su una distanza implanto-nervo non è accettabile.
//  2. Portabilità. `simd` è solo Apple. Restando in Swift puro, DICOMCore e MeasureKit
//     compilano e si testano anche su Linux, quindi `swift test` gira senza Xcode.
//
// La conversione a `simd_float4x4` avviene esclusivamente al confine con Metal, in VolumeKit.

// MARK: - Vec3

/// Vettore o punto tridimensionale in Double.
///
/// Nel progetto rappresenta quasi sempre millimetri nello spazio Patient (LPS).
public struct Vec3: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public static let zero = Vec3(0, 0, 0)

    /// Costruisce da un array di almeno 3 elementi; `nil` se troppo corto.
    /// Utile per i tag DICOM che arrivano come liste di stringhe decimali.
    public init?(_ values: [Double], offset: Int = 0) {
        guard values.count >= offset + 3 else { return nil }
        self.init(values[offset], values[offset + 1], values[offset + 2])
    }

    public var lengthSquared: Double { x * x + y * y + z * z }
    public var length: Double { lengthSquared.squareRoot() }

    /// Versore. Restituisce `nil` per il vettore nullo invece di produrre NaN silenziosi.
    public var normalized: Vec3? {
        let l = length
        guard l > 0, l.isFinite else { return nil }
        return Vec3(x / l, y / l, z / l)
    }

    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }

    public static func + (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x + b.x, a.y + b.y, a.z + b.z) }
    public static func - (a: Vec3, b: Vec3) -> Vec3 { Vec3(a.x - b.x, a.y - b.y, a.z - b.z) }
    public static prefix func - (a: Vec3) -> Vec3 { Vec3(-a.x, -a.y, -a.z) }
    public static func * (a: Vec3, s: Double) -> Vec3 { Vec3(a.x * s, a.y * s, a.z * s) }
    public static func * (s: Double, a: Vec3) -> Vec3 { a * s }
    public static func / (a: Vec3, s: Double) -> Vec3 { Vec3(a.x / s, a.y / s, a.z / s) }

    public static func += (a: inout Vec3, b: Vec3) { a = a + b }
    public static func -= (a: inout Vec3, b: Vec3) { a = a - b }
    public static func *= (a: inout Vec3, s: Double) { a = a * s }

    public func dot(_ o: Vec3) -> Double { x * o.x + y * o.y + z * o.z }

    public func cross(_ o: Vec3) -> Vec3 {
        Vec3(
            y * o.z - z * o.y,
            z * o.x - x * o.z,
            x * o.y - y * o.x
        )
    }

    public func distance(to o: Vec3) -> Double { (self - o).length }

    /// Interpolazione lineare; `t` non viene limitato all'intervallo [0,1].
    public func lerp(to o: Vec3, t: Double) -> Vec3 { self + (o - self) * t }

    /// Angolo con `o` in radianti, nell'intervallo [0, π]. `nil` se un vettore è nullo.
    public func angle(to o: Vec3) -> Double? {
        guard let a = normalized, let b = o.normalized else { return nil }
        // Il clamp evita che un errore di arrotondamento su vettori quasi paralleli
        // faccia uscire l'argomento da [-1,1] e restituisca NaN.
        return Foundation.acos(max(-1.0, min(1.0, a.dot(b))))
    }

    /// Vero se le componenti coincidono entro `tolerance`.
    public func isApproximatelyEqual(to o: Vec3, tolerance: Double = 1e-9) -> Bool {
        abs(x - o.x) <= tolerance && abs(y - o.y) <= tolerance && abs(z - o.z) <= tolerance
    }
}

extension Vec3: CustomStringConvertible {
    public var description: String {
        String(format: "(%.4f, %.4f, %.4f)", x, y, z)
    }
}

// MARK: - Transform3D

/// Trasformazione affine 3D: parte lineare 3×3 più traslazione.
///
/// Tutte le trasformazioni del progetto sono affini (l'ultima riga della 4×4 equivalente è
/// sempre `0 0 0 1`), quindi il tipo lo impone anziché lasciarlo alla disciplina di chi scrive.
/// Semplifica anche l'inversione, che diventa esatta e a costo fisso.
///
/// Le tre colonne sono le immagini dei versori degli assi:
/// `columnX` è dove finisce `(1,0,0)`, `columnY` dove finisce `(0,1,0)`, e così via.
///
/// ```
///     | cX.x  cY.x  cZ.x  o.x |
/// M = | cX.y  cY.y  cZ.y  o.y |
///     | cX.z  cY.z  cZ.z  o.z |
///     | 0     0     0     1   |
/// ```
public struct Transform3D: Hashable, Sendable, Codable {
    public var columnX: Vec3
    public var columnY: Vec3
    public var columnZ: Vec3
    public var origin: Vec3

    public init(columnX: Vec3, columnY: Vec3, columnZ: Vec3, origin: Vec3) {
        self.columnX = columnX
        self.columnY = columnY
        self.columnZ = columnZ
        self.origin = origin
    }

    public static let identity = Transform3D(
        columnX: Vec3(1, 0, 0),
        columnY: Vec3(0, 1, 0),
        columnZ: Vec3(0, 0, 1),
        origin: .zero
    )

    public static func translation(_ t: Vec3) -> Transform3D {
        Transform3D(columnX: Vec3(1, 0, 0), columnY: Vec3(0, 1, 0), columnZ: Vec3(0, 0, 1), origin: t)
    }

    /// Rotazione di `angle` radianti attorno ad `axis` (Rodrigues). `nil` se l'asse è nullo.
    public static func rotation(axis: Vec3, angle: Double) -> Transform3D? {
        guard let a = axis.normalized else { return nil }
        let c = Foundation.cos(angle)
        let s = Foundation.sin(angle)
        let t = 1 - c
        return Transform3D(
            columnX: Vec3(t * a.x * a.x + c, t * a.x * a.y + s * a.z, t * a.x * a.z - s * a.y),
            columnY: Vec3(t * a.x * a.y - s * a.z, t * a.y * a.y + c, t * a.y * a.z + s * a.x),
            columnZ: Vec3(t * a.x * a.z + s * a.y, t * a.y * a.z - s * a.x, t * a.z * a.z + c),
            origin: .zero
        )
    }

    /// Determinante della parte lineare. Se è ~0 la trasformazione non è invertibile
    /// (volume degenere: spaziatura nulla o assi collineari).
    public var determinant: Double {
        columnX.dot(columnY.cross(columnZ))
    }

    /// Applica la trasformazione a un **punto** (traslazione inclusa).
    public func apply(toPoint p: Vec3) -> Vec3 {
        columnX * p.x + columnY * p.y + columnZ * p.z + origin
    }

    /// Applica la trasformazione a un **vettore/direzione** (traslazione esclusa).
    ///
    /// Usare questa, e non `apply(toPoint:)`, per differenze fra punti, normali di piano e
    /// direzioni: sommare l'origine a una direzione è l'errore classico che sposta le misure
    /// di una quantità costante.
    public func apply(toVector v: Vec3) -> Vec3 {
        columnX * v.x + columnY * v.y + columnZ * v.z
    }

    /// Composizione: il risultato applica prima `other`, poi `self`.
    public func concatenating(_ other: Transform3D) -> Transform3D {
        Transform3D(
            columnX: apply(toVector: other.columnX),
            columnY: apply(toVector: other.columnY),
            columnZ: apply(toVector: other.columnZ),
            origin: apply(toPoint: other.origin)
        )
    }

    /// Inversa. `nil` se la parte lineare è singolare.
    ///
    /// Per una affine `[A t; 0 1]` l'inversa è `[A⁻¹  −A⁻¹t; 0 1]`: si inverte la 3×3 con i
    /// cofattori e si trasforma la traslazione. Niente eliminazione di Gauss su una 4×4.
    public var inverse: Transform3D? {
        let det = determinant
        guard det.isFinite, abs(det) > 1e-15 else { return nil }
        let invDet = 1.0 / det

        // Righe dell'inversa della 3×3 = cofattori trasposti / determinante.
        let r0 = columnY.cross(columnZ) * invDet
        let r1 = columnZ.cross(columnX) * invDet
        let r2 = columnX.cross(columnY) * invDet

        // r0, r1, r2 sono le *righe* di A⁻¹; servono le colonne.
        let invColumnX = Vec3(r0.x, r1.x, r2.x)
        let invColumnY = Vec3(r0.y, r1.y, r2.y)
        let invColumnZ = Vec3(r0.z, r1.z, r2.z)

        let invOrigin = Vec3(
            -r0.dot(origin),
            -r1.dot(origin),
            -r2.dot(origin)
        )

        return Transform3D(
            columnX: invColumnX,
            columnY: invColumnY,
            columnZ: invColumnZ,
            origin: invOrigin
        )
    }

    /// 16 `Float` in ordine **column-major**, pronti per un buffer Metal o `simd_float4x4`.
    ///
    /// È l'unico punto in cui si scende a precisione singola, e avviene per necessità: gli
    /// shader lavorano in Float. La geometria a monte resta in Double.
    public func columnMajorFloat4x4() -> [Float] {
        [
            Float(columnX.x), Float(columnX.y), Float(columnX.z), 0,
            Float(columnY.x), Float(columnY.y), Float(columnY.z), 0,
            Float(columnZ.x), Float(columnZ.y), Float(columnZ.z), 0,
            Float(origin.x), Float(origin.y), Float(origin.z), 1,
        ]
    }

    public func isApproximatelyEqual(to o: Transform3D, tolerance: Double = 1e-9) -> Bool {
        columnX.isApproximatelyEqual(to: o.columnX, tolerance: tolerance)
            && columnY.isApproximatelyEqual(to: o.columnY, tolerance: tolerance)
            && columnZ.isApproximatelyEqual(to: o.columnZ, tolerance: tolerance)
            && origin.isApproximatelyEqual(to: o.origin, tolerance: tolerance)
    }
}

extension Transform3D: CustomStringConvertible {
    public var description: String {
        "Transform3D(X: \(columnX), Y: \(columnY), Z: \(columnZ), O: \(origin))"
    }
}
