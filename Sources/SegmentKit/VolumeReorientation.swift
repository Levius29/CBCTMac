import DICOMCore
import Foundation

// Riorientamento del volume su un piano di riferimento.
//
// # Perché pesa più di quanto sembri
//
// Nessuno se ne accorge finché non apre una CBCT con la testa inclinata — cioè quasi sempre. Su un
// volume storto ogni misura verticale si legge di traverso: l'altezza di cresta misurata su una
// fetta obliqua non è l'altezza di cresta, e l'errore cresce con l'inclinazione senza che nulla lo
// dichiari. Portare il piano occlusale in orizzontale rende leggibili misure che altrimenti si
// leggono male.
//
// # Una precisazione, perché il brief che ho scritto io diceva una cosa sbagliata
//
// Il brief chiedeva di «ruotare i dati lasciando invariate le coordinate Patient», presentandola
// come la strada giusta contro quella di «ruotare il sistema di riferimento». Le due cose però non
// sono alternative: sono la stessa cosa vista da due parti, e **non esiste** un modo di
// raddrizzare l'anatomia per ricampionamento lasciando invariate le coordinate. Se il tessuto si
// sposta rispetto all'origine Patient, il punto Patient che prima lo indicava adesso indica altro.
//
// La distinzione vera è un'altra, e questa conta davvero:
//
// - **Ricampionare** produce un volume nuovo in un riferimento nuovo. Le annotazioni esistenti
//   vanno trasformate con la stessa rotazione, altrimenti restano attaccate al vecchio
//   riferimento e indicano tessuto sbagliato. Per questo `rotation()` è pubblica: chi ricampiona
//   **deve** poterla applicare a tutto il resto del piano.
// - **Ruotare i piani di vista** — `MPRPlane.rotated(aboutAxis:)` — raddrizza ciò che si vede
//   senza toccare né i dati né le coordinate, quindi non invalida nulla. È più economico e va
//   preferito quando basta guardare.
//
// Si ricampiona quando serve un volume raddrizzato da esportare, da misurare a lungo, o da dare a
// un altro programma. Per il resto bastano i piani.

/// Errori del riorientamento.
public enum ReorientationError: Error, Hashable, Sendable, LocalizedError {
    case notEnoughReferencePoints(count: Int)
    case collinearReferencePoints
    case invalidSpacing(Double)
    case degenerateOutput

    public var errorDescription: String? {
        switch self {
        case .notEnoughReferencePoints(let count):
            return "Servono tre punti per definire il piano di riferimento, ne sono stati indicati \(count)."
        case .collinearReferencePoints:
            return "I tre punti di riferimento sono allineati e non definiscono un piano."
        case .invalidSpacing(let spacing):
            return "Il passo richiesto non è valido: \(spacing) mm."
        case .degenerateOutput:
            return "Il volume riorientato risulterebbe vuoto."
        }
    }
}

/// Riorientamento del volume su un piano di riferimento.
public struct ReorientationPlan: Hashable, Sendable, Codable {

    /// Tre punti che definiscono il piano di riferimento — di norma quello occlusale — in mm
    /// Patient. In pratica si posano su due cuspidi e un incisivo.
    public var referencePointsMM: [Vec3]

    /// Direzione su cui portare la normale del piano. Verticale del paziente per il piano
    /// occlusale; è un parametro perché lo stesso meccanismo serve anche per il piano sagittale
    /// mediano, dove la normale va su L-R.
    public var targetNormalMM: Vec3

    public init(referencePointsMM: [Vec3], targetNormalMM: Vec3 = Vec3(0, 0, 1)) {
        self.referencePointsMM = referencePointsMM
        self.targetNormalMM = targetNormalMM
    }

    /// Baricentro dei punti di riferimento: è il perno della rotazione.
    ///
    /// Ruotare attorno al baricentro del piano e non attorno all'origine Patient tiene ferma
    /// l'anatomia che interessa. Attorno all'origine, una testa inclinata di venti gradi
    /// traslerebbe di centimetri e uscirebbe dall'inquadratura.
    public var pivotMM: Vec3 {
        guard !referencePointsMM.isEmpty else { return .zero }
        return referencePointsMM.reduce(Vec3.zero, +) / Double(referencePointsMM.count)
    }

    /// Normale del piano definito dai tre punti, o `nil` se sono allineati.
    public var planeNormalMM: Vec3? {
        guard referencePointsMM.count >= 3 else { return nil }
        let a = referencePointsMM[1] - referencePointsMM[0]
        let b = referencePointsMM[2] - referencePointsMM[0]
        let cross = a.cross(b)
        // La soglia è relativa alla scala dei punti, non assoluta: tre punti a due millimetri
        // l'uno dall'altro danno un prodotto vettoriale piccolo anche quando sono ben distinti,
        // e una soglia fissa li rifiuterebbe.
        let scale = max(a.length * b.length, 1e-12)
        guard cross.length / scale > 1e-6 else { return nil }
        return cross.normalized
    }

    /// Rotazione che porta la normale del piano su `targetNormalMM`, attorno al baricentro.
    ///
    /// - Returns: `nil` se i punti non definiscono un piano. Tre punti quasi allineati danno una
    ///   normale quasi arbitraria, e una rotazione arbitraria è un volume ruotato a caso: qui
    ///   preferisco rifiutare, perché un volume ruotato a caso somiglia troppo a uno ruotato bene.
    public func rotation() -> Transform3D? {
        guard let normal = planeNormalMM, let target = targetNormalMM.normalized else {
            return nil
        }

        // Il verso della normale dipende dall'ordine dei tre punti, che l'utente sceglie senza
        // pensarci. Presa così com'è, mezza volta il volume si capovolgerebbe. Si prende il verso
        // che richiede la rotazione minore.
        let oriented = normal.dot(target) < 0 ? normal * -1 : normal

        let axis = oriented.cross(target)
        let cosine = min(max(oriented.dot(target), -1), 1)

        // Già allineato: identità esatta, non una rotazione di un angolo minuscolo attorno a un
        // asse arbitrario. Un piano già orizzontale non deve muovere nulla.
        guard let rotationAxis = axis.normalized, axis.length > 1e-12 else {
            return Transform3D.identity
        }
        return Transform3D.rotation(axis: rotationAxis, angle: Foundation.acos(cosine))
    }

    /// Problemi del piano, in forma leggibile. Vuoto quando è utilizzabile.
    public func validate() -> [String] {
        var problems: [String] = []
        if referencePointsMM.count < 3 {
            problems.append("Servono tre punti sul piano di riferimento.")
        } else if planeNormalMM == nil {
            problems.append("I tre punti sono allineati: non definiscono un piano.")
        }
        if !referencePointsMM.allSatisfy(\.isFinite) {
            problems.append("Un punto di riferimento non è valido.")
        }
        return problems
    }

    /// Porta un punto dal vecchio al nuovo riferimento.
    ///
    /// **Da applicare a ogni annotazione, impianto, curva e nervo** quando si adotta un volume
    /// riorientato: senza, restano nel vecchio riferimento e indicano tessuto sbagliato.
    public func transformed(_ pointMM: Vec3) -> Vec3? {
        guard let rotation = rotation() else { return nil }
        let pivot = pivotMM
        return pivot + rotation.apply(toVector: pointMM - pivot)
    }
}

public enum VolumeReorientation: Sendable {

    /// Produce un volume nuovo, ricampionato secondo la rotazione del piano.
    ///
    /// L'uscita è allineata agli assi del **nuovo** riferimento: righe lungo L, colonne lungo P,
    /// fette lungo S. È il punto del riorientamento — dopo, «fetta assiale» significa davvero un
    /// piano orizzontale rispetto all'occlusione.
    public static func reoriented(
        _ volume: Volume,
        plan: ReorientationPlan,
        spacingMM: Double
    ) throws -> Volume {
        guard plan.referencePointsMM.count >= 3 else {
            throw ReorientationError.notEnoughReferencePoints(count: plan.referencePointsMM.count)
        }
        guard let rotation = plan.rotation() else {
            throw ReorientationError.collinearReferencePoints
        }
        guard spacingMM.isFinite, spacingMM > 0 else {
            throw ReorientationError.invalidSpacing(spacingMM)
        }
        guard let inverse = rotation.inverse else {
            throw ReorientationError.collinearReferencePoints
        }

        let pivot = plan.pivotMM

        // Riquadro contenitore nel **nuovo** riferimento: si ruotano gli otto vertici del volume
        // di partenza e si prende il loro contenitore allineato agli assi. Tenere le dimensioni
        // originali produrrebbe angoli tagliati via, proprio dove sta l'anatomia periferica.
        var lower = Vec3(.infinity, .infinity, .infinity)
        var upper = Vec3(-.infinity, -.infinity, -.infinity)
        for corner in volume.geometry.boundingBoxCornersMM {
            let moved = pivot + rotation.apply(toVector: corner - pivot)
            lower = Vec3(min(lower.x, moved.x), min(lower.y, moved.y), min(lower.z, moved.z))
            upper = Vec3(max(upper.x, moved.x), max(upper.y, moved.y), max(upper.z, moved.z))
        }

        let size = upper - lower
        let columns = Int((size.x / spacingMM).rounded(.up)) + 1
        let rows = Int((size.y / spacingMM).rounded(.up)) + 1
        let slices = Int((size.z / spacingMM).rounded(.up)) + 1
        guard columns > 0, rows > 0, slices > 0, size.isFinite else {
            throw ReorientationError.degenerateOutput
        }

        let orientation = SliceOrientation(
            columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 1, 0))!
        let geometry = try VolumeGeometry(
            columnCount: columns, rowCount: rows, sliceCount: slices,
            columnSpacingMM: spacingMM, rowSpacingMM: spacingMM, sliceSpacingMM: spacingMM,
            orientation: orientation,
            originMM: lower)

        var samples = [Int16](repeating: 0, count: columns * rows * slices)
        let outside = rawSample(fromDensity: volume.densityRange.lowerBound, volume: volume)

        for k in 0..<slices {
            for j in 0..<rows {
                let rowBase = (k * rows + j) * columns
                for i in 0..<columns {
                    // Punto nel nuovo riferimento, riportato indietro nel vecchio per campionare.
                    let destination = geometry.patientPoint(fromVoxel: Vec3(Double(i), Double(j), Double(k)))
                    let source = pivot + inverse.apply(toVector: destination - pivot)
                    if let density = volume.interpolatedDensityValue(atPatient: source) {
                        samples[rowBase + i] = rawSample(fromDensity: density, volume: volume)
                    } else {
                        samples[rowBase + i] = outside
                    }
                }
            }
        }

        return try Volume(
            geometry: geometry,
            samples: samples,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept,
            densityUnit: volume.densityUnit)
    }

    /// Inversione della scala, come nel ricampionatore.
    ///
    /// Il campionamento trilineare pubblico restituisce densità già scalate, mentre `samples` deve
    /// restare grezzo: senza questa inversione slope e intercetta verrebbero applicate due volte.
    private static func rawSample(fromDensity density: Double, volume: Volume) -> Int16 {
        let raw = (density - volume.rescaleIntercept) / volume.rescaleSlope
        guard raw.isFinite else { return 0 }
        let rounded = raw.rounded()
        if rounded <= Double(Int16.min) { return Int16.min }
        if rounded >= Double(Int16.max) { return Int16.max }
        guard let integer = Int(exactly: rounded) else { return 0 }
        return Int16(clamping: integer)
    }
}
