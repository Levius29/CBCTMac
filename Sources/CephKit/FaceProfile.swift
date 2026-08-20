import DICOMCore
import Foundation

// Il profilo del viso.
//
// # Che cos'è, esattamente
//
// Il confine fra aria e pelle sul piano sagittale mediano, dalla fronte al collo. Si ottiene
// avanzando da davanti verso il paziente, a ogni quota, finché il valore non supera una soglia:
// il primo punto che la supera è la pelle.
//
// # Che cosa non è
//
// Non è una segmentazione dei tessuti molli. È una linea su un piano, e serve a due cose: vederla
// disegnata sulla sezione sagittale, e avere qualcosa contro cui confrontare i reperi cutanei
// della cefalometria — se il pronasale segnato non cade sul profilo, è segnato male.
//
// # I due modi in cui sbaglia
//
// Prende **qualunque cosa** stia davanti alla faccia e superi la soglia: un poggiamento, un
// cuscinetto, una mano. E dipende da una soglia in GV, che fra scanner diversi non significa la
// stessa cosa — vedi il Contratto 4. Per questo la soglia è un parametro e non una costante
// nascosta: il valore predefinito è quello del preset dei tessuti molli, ma su una macchina
// tarata diversamente va cambiato, e il profilo sbagliato si riconosce a occhio.

/// Il profilo del viso su un piano sagittale.
public struct FaceProfile: Hashable, Sendable {
    /// I punti, dall'alto verso il basso, in millimetri Patient.
    public var pointsMM: [Vec3]
    /// Su quale piano sagittale è stato estratto.
    public var lateralXMM: Double
    /// La soglia usata, in GV.
    public var thresholdGV: Double
    /// Il passo verticale fra un punto e il successivo.
    public var stepMM: Double

    public init(pointsMM: [Vec3], lateralXMM: Double, thresholdGV: Double, stepMM: Double) {
        self.pointsMM = pointsMM
        self.lateralXMM = lateralXMM
        self.thresholdGV = thresholdGV
        self.stepMM = stepMM
    }

    public var isEmpty: Bool { pointsMM.isEmpty }

    /// Il profilo proiettato sul piano sagittale, per confrontarlo coi reperi cefalometrici.
    public var planePoints: [CephPlanePoint] {
        pointsMM.map(CephPlanePoint.init(projecting:))
    }

    /// Il punto più avanzato del profilo: su una faccia intera è la punta del naso.
    public var anteriorMostPointMM: Vec3? {
        // `y` cresce all'indietro, quindi il più avanzato è quello con `y` minima.
        pointsMM.min { $0.y < $1.y }
    }

    /// Quanto un punto sta davanti (positivo) o dietro (negativo) al profilo, alla sua quota.
    ///
    /// Serve a controllare un repere cutaneo: un pronasale segnato bene cade sul profilo, cioè
    /// dà quasi zero. Dieci millimetri di scarto vogliono dire che il punto è stato segnato su
    /// un'altra struttura — o che il profilo ha preso il poggiamento invece della faccia.
    ///
    /// - Returns: `nil` se il profilo non arriva a quella quota.
    public func anteriorOffsetMM(of point: Vec3) -> Double? {
        guard let profilePoint = interpolatedPointMM(atSuperiorMM: point.z) else { return nil }
        // Positivo davanti, come la distanza dalla linea E: `y` cresce all'indietro, quindi un
        // punto davanti al profilo ha `y` minore e la differenza esce positiva.
        return profilePoint.y - point.y
    }

    /// Il punto del profilo a una quota qualsiasi, interpolando fra i due più vicini.
    public func interpolatedPointMM(atSuperiorMM z: Double) -> Vec3? {
        guard pointsMM.count >= 2 else { return pointsMM.first }
        // I punti sono ordinati dall'alto verso il basso: `z` decrescente.
        guard let first = pointsMM.first, let last = pointsMM.last else { return nil }
        guard z <= first.z, z >= last.z else { return nil }

        for index in 1..<pointsMM.count {
            let upper = pointsMM[index - 1]
            let lower = pointsMM[index]
            guard z <= upper.z, z >= lower.z else { continue }
            let span = upper.z - lower.z
            guard span > 1e-12 else { return upper }
            let t = (upper.z - z) / span
            return upper.lerp(to: lower, t: t)
        }
        return nil
    }
}

public enum FaceProfileExtractor: Sendable {

    /// La soglia predefinita: la stessa del preset «Tessuti molli e gengiva».
    ///
    /// Un valore solo per tutte le macchine è una semplificazione, ed è dichiarata: vedi il
    /// commento in testa al file.
    public static let defaultThresholdGV: Double = -300

    /// Estrae il profilo del viso da un volume.
    ///
    /// # Il verso della marcia
    ///
    /// Si avanza lungo l'asse Patient dall'avanti all'indietro, non lungo la direzione in cui è
    /// girata la testa. Su una testa inclinata dentro il campo il profilo esce storto — ed è
    /// giusto che esca storto, perché lo è: prima si raddrizza il volume sul piano occlusale,
    /// poi si traccia. Un'estrazione che raddrizzasse da sola nasconderebbe l'inclinazione a chi
    /// poi misura angoli.
    ///
    /// - Parameters:
    ///   - volume: il volume da attraversare.
    ///   - lateralXMM: su quale piano sagittale. `nil` prende quello che passa per il centro.
    ///   - thresholdGV: sopra questo valore comincia il tessuto.
    ///   - stepMM: distanza verticale fra un punto e il successivo.
    public static func extract(
        from volume: Volume,
        lateralXMM: Double? = nil,
        thresholdGV: Double = defaultThresholdGV,
        stepMM: Double = 1.0
    ) -> FaceProfile {
        let geometry = volume.geometry
        let x = lateralXMM ?? geometry.centerMM.x
        let vertical = Swift.max(stepMM, 0.05)

        let corners = geometry.boundingBoxCornersMM
        guard let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max(),
            let minZ = corners.map(\.z).min(), let maxZ = corners.map(\.z).max()
        else {
            return FaceProfile(
                pointsMM: [], lateralXMM: x, thresholdGV: thresholdGV, stepMM: vertical)
        }

        // Mezzo voxel: il passo più lungo che non può saltare una struttura sottile. Più fine
        // costerebbe tempo senza aggiungere informazione, perché sotto il voxel non c'è dato.
        let spacing = geometry.spacingMM
        let march = Swift.max(0.05, Swift.min(spacing.x, Swift.min(spacing.y, spacing.z)) / 2)

        var points: [Vec3] = []
        var z = maxZ
        while z >= minZ {
            if let hit = firstCrossing(
                in: volume, x: x, z: z, fromY: minY, toY: maxY, step: march,
                thresholdGV: thresholdGV)
            {
                points.append(Vec3(x, hit, z))
            }
            z -= vertical
        }

        return FaceProfile(
            pointsMM: points, lateralXMM: x, thresholdGV: thresholdGV, stepMM: vertical)
    }

    /// La `y` del primo punto che supera la soglia, avanzando dall'avanti all'indietro.
    ///
    /// Il valore restituito è interpolato fra l'ultimo campione sotto soglia e il primo sopra: il
    /// bordo di una struttura non sta al centro di un voxel, e arrotondarlo al passo di marcia
    /// darebbe un profilo a gradini larghi mezzo voxel.
    private static func firstCrossing(
        in volume: Volume, x: Double, z: Double, fromY: Double, toY: Double, step: Double,
        thresholdGV: Double
    ) -> Double? {
        var previousY = fromY
        var previousValue: Double?
        var y = fromY

        while y <= toY {
            let value = volume.interpolatedDensityValue(atPatient: Vec3(x, y, z))
            if let value, value >= thresholdGV {
                guard let previousValue, previousValue < thresholdGV, value > previousValue else {
                    return y
                }
                let t = (thresholdGV - previousValue) / (value - previousValue)
                return previousY + (y - previousY) * t
            }
            previousY = y
            // Fuori dal volume non c'è aria: non c'è niente. Trattarlo come un campione d'aria
            // farebbe interpolare fra il nulla e il primo voxel, cioè inventare un bordo mezzo
            // passo più avanti di dove comincia il dato.
            previousValue = value
            y += step
        }
        return nil
    }
}
