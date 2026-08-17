import Foundation
import DICOMCore

/// Risultato di una registrazione rigida fra due insiemi di punti.
public struct RegistrationResult: Sendable {
    public let transform: Transform3D
    public let rmsErrorMM: Double
    public let maxErrorMM: Double
    /// Coppie usate nel fit; per ICP sono quelle sopravvissute a cutoff e trimming.
    public let pointCount: Int
    /// Zero per la soluzione chiusa Horn, numero di passi completati per ICP.
    public let iterations: Int
    public let converged: Bool

    public init(
        transform: Transform3D,
        rmsErrorMM: Double,
        maxErrorMM: Double,
        pointCount: Int,
        iterations: Int,
        converged: Bool
    ) {
        self.transform = transform
        self.rmsErrorMM = rmsErrorMM
        self.maxErrorMM = maxErrorMM
        self.pointCount = pointCount
        self.iterations = iterations
        self.converged = converged
    }
}

/// Errori della registrazione rigida e del suo affinamento iterativo.
public enum RegistrationError: Error, Hashable, Sendable, LocalizedError {
    case mismatchedPointCounts(source: Int, target: Int)
    case tooFewPoints(count: Int, required: Int)
    case degenerateConfiguration(detail: String)
    case emptyMesh
    case didNotConverge(iterations: Int, rmsErrorMM: Double)

    public var errorDescription: String? {
        switch self {
        case .mismatchedPointCounts(let source, let target):
            return "La registrazione ha \(source) punti sorgente e \(target) punti destinazione."
        case .tooFewPoints(let count, let required):
            return "La registrazione richiede almeno \(required) punti, ma ne ha ricevuti \(count)."
        case .degenerateConfiguration(let detail):
            return "La configurazione dei punti è degenere: \(detail)."
        case .emptyMesh:
            return "La registrazione non può usare una nuvola di punti vuota."
        case .didNotConverge(let iterations, let rmsErrorMM):
            return "La registrazione è inutilizzabile dopo \(iterations) iterazioni (RMS \(rmsErrorMM) mm)."
        }
    }
}

/// Registrazione rigida chiusa da coppie di punti corrispondenti.
public enum PointRegistration: Sendable {
    /// Calcola rotazione e traslazione ottimali che portano `source` in `target`.
    ///
    /// Si usa il metodo dei quaternioni di Horn anziché Kabsch basato su SVD per due motivi.
    /// Una SVD pura richiederebbe una decomposizione numerica completa scritta nel modulo,
    /// mentre Horn richiede soltanto l'autovettore massimo di una matrice simmetrica 4×4,
    /// ottenibile in modo affidabile con Jacobi. Inoltre una SVD può produrre una riflessione
    /// quando il determinante è negativo: una mandibola specchiata appare plausibile ma è
    /// clinicamente catastrofica. Un quaternione unitario non può rappresentare riflessioni,
    /// quindi quel modo di guasto è eliminato per costruzione e non corretto a posteriori.
    /// Sono necessarie almeno tre coppie non collineari.
    public static func align(source: [Vec3], target: [Vec3]) throws -> RegistrationResult {
        guard source.count == target.count else {
            throw RegistrationError.mismatchedPointCounts(
                source: source.count,
                target: target.count
            )
        }
        guard source.count >= 3 else {
            throw RegistrationError.tooFewPoints(count: source.count, required: 3)
        }

        var index = 0
        while index < source.count {
            guard source[index].isFinite, target[index].isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "la coppia \(index) contiene coordinate non finite"
                )
            }
            index += 1
        }

        let sourceCentroid = try centroid(of: source, label: "sorgente")
        let targetCentroid = try centroid(of: target, label: "destinazione")
        var centeredSource = [Vec3]()
        var centeredTarget = [Vec3]()
        centeredSource.reserveCapacity(source.count)
        centeredTarget.reserveCapacity(target.count)

        index = 0
        while index < source.count {
            let sourcePoint = source[index] - sourceCentroid
            let targetPoint = target[index] - targetCentroid
            guard sourcePoint.isFinite, targetPoint.isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "centratura numericamente non finita alla coppia \(index)"
                )
            }
            centeredSource.append(sourcePoint)
            centeredTarget.append(targetPoint)
            index += 1
        }

        guard hasNonCollinearPoints(centeredSource) else {
            throw RegistrationError.degenerateConfiguration(
                detail: "i punti sorgente sono coincidenti o collineari"
            )
        }
        guard hasNonCollinearPoints(centeredTarget) else {
            throw RegistrationError.degenerateConfiguration(
                detail: "i punti destinazione sono coincidenti o collineari"
            )
        }

        var sxx = 0.0
        var sxy = 0.0
        var sxz = 0.0
        var syx = 0.0
        var syy = 0.0
        var syz = 0.0
        var szx = 0.0
        var szy = 0.0
        var szz = 0.0

        index = 0
        while index < centeredSource.count {
            let p = centeredSource[index]
            let q = centeredTarget[index]
            sxx += p.x * q.x
            sxy += p.x * q.y
            sxz += p.x * q.z
            syx += p.y * q.x
            syy += p.y * q.y
            syz += p.y * q.z
            szx += p.z * q.x
            szy += p.z * q.y
            szz += p.z * q.z
            index += 1
        }

        let covarianceValues = [sxx, sxy, sxz, syx, syy, syz, szx, szy, szz]
        for value: Double in covarianceValues {
            guard value.isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "covarianza non finita"
                )
            }
        }

        let trace = sxx + syy + szz
        let n01 = syz - szy
        let n02 = szx - sxz
        let n03 = sxy - syx
        let hornMatrix = [
            trace, n01, n02, n03,
            n01, sxx - syy - szz, sxy + syx, szx + sxz,
            n02, sxy + syx, -sxx + syy - szz, syz + szy,
            n03, szx + sxz, syz + szy, -sxx - syy + szz,
        ]
        for value: Double in hornMatrix {
            guard value.isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "matrice di Horn non finita"
                )
            }
        }

        let quaternion = try largestEigenvector(ofSymmetric4x4: hornMatrix)
        let w = quaternion[0]
        let x = quaternion[1]
        let y = quaternion[2]
        let z = quaternion[3]

        let r00 = 1.0 - 2.0 * (y * y + z * z)
        let r01 = 2.0 * (x * y - z * w)
        let r02 = 2.0 * (x * z + y * w)
        let r10 = 2.0 * (x * y + z * w)
        let r11 = 1.0 - 2.0 * (x * x + z * z)
        let r12 = 2.0 * (y * z - x * w)
        let r20 = 2.0 * (x * z - y * w)
        let r21 = 2.0 * (y * z + x * w)
        let r22 = 1.0 - 2.0 * (x * x + y * y)

        let rotation = Transform3D(
            columnX: Vec3(r00, r10, r20),
            columnY: Vec3(r01, r11, r21),
            columnZ: Vec3(r02, r12, r22),
            origin: .zero
        )
        let translation = targetCentroid - rotation.apply(toVector: sourceCentroid)
        let transform = Transform3D(
            columnX: rotation.columnX,
            columnY: rotation.columnY,
            columnZ: rotation.columnZ,
            origin: translation
        )

        guard transform.columnX.isFinite,
              transform.columnY.isFinite,
              transform.columnZ.isFinite,
              transform.origin.isFinite,
              transform.determinant.isFinite,
              transform.determinant > 0
        else {
            throw RegistrationError.degenerateConfiguration(
                detail: "trasformazione risultante non valida"
            )
        }

        var squaredErrorSum = 0.0
        var maxError = 0.0
        index = 0
        while index < source.count {
            let distance = transform.apply(toPoint: source[index]).distance(to: target[index])
            guard distance.isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "residuo non finito alla coppia \(index)"
                )
            }
            squaredErrorSum += distance * distance
            maxError = Swift.max(maxError, distance)
            index += 1
        }
        let rms = Foundation.sqrt(squaredErrorSum / Double(source.count))
        guard rms.isFinite else {
            throw RegistrationError.degenerateConfiguration(detail: "RMS non finito")
        }

        return RegistrationResult(
            transform: transform,
            rmsErrorMM: rms,
            maxErrorMM: maxError,
            pointCount: source.count,
            iterations: 0,
            converged: true
        )
    }

    private static func centroid(of points: [Vec3], label: String) throws -> Vec3 {
        var sum = Vec3.zero
        for point: Vec3 in points {
            sum += point
            guard sum.isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "centroide \(label) non finito"
                )
            }
        }
        let result = sum / Double(points.count)
        guard result.isFinite else {
            throw RegistrationError.degenerateConfiguration(
                detail: "centroide \(label) non finito"
            )
        }
        return result
    }

    private static func hasNonCollinearPoints(_ centeredPoints: [Vec3]) -> Bool {
        var base = Vec3.zero
        var longestSquared = 0.0
        for point: Vec3 in centeredPoints {
            let lengthSquared = point.lengthSquared
            if lengthSquared.isFinite, lengthSquared > longestSquared {
                longestSquared = lengthSquared
                base = point
            }
        }
        guard longestSquared > 0, let baseDirection = base.normalized else { return false }

        for candidate: Vec3 in centeredPoints {
            guard let candidateDirection = candidate.normalized else { continue }
            let sine = baseDirection.cross(candidateDirection).length
            if sine.isFinite, sine > 1e-12 {
                return true
            }
        }
        return false
    }

    private static func largestEigenvector(ofSymmetric4x4 input: [Double]) throws -> [Double] {
        guard input.count == 16 else {
            throw RegistrationError.degenerateConfiguration(
                detail: "dimensione interna della matrice di Horn non valida"
            )
        }
        var matrix = input
        var eigenvectors = [Double](repeating: 0, count: 16)
        var diagonalIndex = 0
        while diagonalIndex < 4 {
            eigenvectors[diagonalIndex * 4 + diagonalIndex] = 1
            diagonalIndex += 1
        }

        var converged = false
        var rotationCount = 0
        while rotationCount < 128 {
            var p = 0
            var q = 1
            var largestOffDiagonal = 0.0
            var row = 0
            while row < 4 {
                var column = row + 1
                while column < 4 {
                    let magnitude = abs(matrix[row * 4 + column])
                    if magnitude > largestOffDiagonal {
                        largestOffDiagonal = magnitude
                        p = row
                        q = column
                    }
                    column += 1
                }
                row += 1
            }

            var largestDiagonal = 0.0
            diagonalIndex = 0
            while diagonalIndex < 4 {
                largestDiagonal = Swift.max(
                    largestDiagonal,
                    abs(matrix[diagonalIndex * 4 + diagonalIndex])
                )
                diagonalIndex += 1
            }
            let threshold = 1e-15 * Swift.max(1.0, largestDiagonal)
            if largestOffDiagonal <= threshold {
                converged = true
                break
            }

            let pp = p * 4 + p
            let qq = q * 4 + q
            let pq = p * 4 + q
            let app = matrix[pp]
            let aqq = matrix[qq]
            let apq = matrix[pq]
            guard apq.isFinite, apq != 0 else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "rotazione di Jacobi non valida"
                )
            }

            let tau = (aqq - app) / (2.0 * apq)
            let sign = tau >= 0 ? 1.0 : -1.0
            let t = sign / (abs(tau) + Foundation.sqrt(1.0 + tau * tau))
            let c = 1.0 / Foundation.sqrt(1.0 + t * t)
            let s = t * c
            guard tau.isFinite, t.isFinite, c.isFinite, s.isFinite else {
                throw RegistrationError.degenerateConfiguration(
                    detail: "rotazione di Jacobi non finita"
                )
            }

            var k = 0
            while k < 4 {
                if k != p, k != q {
                    let kp = k * 4 + p
                    let kq = k * 4 + q
                    let oldKP = matrix[kp]
                    let oldKQ = matrix[kq]
                    let newKP = c * oldKP - s * oldKQ
                    let newKQ = s * oldKP + c * oldKQ
                    matrix[kp] = newKP
                    matrix[p * 4 + k] = newKP
                    matrix[kq] = newKQ
                    matrix[q * 4 + k] = newKQ
                }
                k += 1
            }
            matrix[pp] = c * c * app - 2.0 * s * c * apq + s * s * aqq
            matrix[qq] = s * s * app + 2.0 * s * c * apq + c * c * aqq
            matrix[pq] = 0
            matrix[q * 4 + p] = 0

            k = 0
            while k < 4 {
                let kp = k * 4 + p
                let kq = k * 4 + q
                let oldKP = eigenvectors[kp]
                let oldKQ = eigenvectors[kq]
                eigenvectors[kp] = c * oldKP - s * oldKQ
                eigenvectors[kq] = s * oldKP + c * oldKQ
                k += 1
            }
            rotationCount += 1
        }

        guard converged else {
            throw RegistrationError.degenerateConfiguration(
                detail: "l'algoritmo di Jacobi non converge"
            )
        }

        var largestIndex = 0
        var largestValue = matrix[0]
        diagonalIndex = 1
        while diagonalIndex < 4 {
            let value = matrix[diagonalIndex * 4 + diagonalIndex]
            if value > largestValue {
                largestValue = value
                largestIndex = diagonalIndex
            }
            diagonalIndex += 1
        }

        var vector = [Double](repeating: 0, count: 4)
        var lengthSquared = 0.0
        var component = 0
        while component < 4 {
            let value = eigenvectors[component * 4 + largestIndex]
            vector[component] = value
            lengthSquared += value * value
            component += 1
        }
        let length = Foundation.sqrt(lengthSquared)
        guard length.isFinite, length > 0 else {
            throw RegistrationError.degenerateConfiguration(
                detail: "quaternione di Horn non normalizzabile"
            )
        }
        component = 0
        while component < 4 {
            vector[component] /= length
            component += 1
        }
        return vector
    }
}
