import DICOMCore
import Foundation

// Proposta dell'asse di un impianto.
//
// # Che cosa fa, e che cosa non pretende di fare
//
// Cerca, fra le inclinazioni possibili attorno a quella scelta, quella che sta più lontana dai
// canali e in osso migliore, senza allontanarsi troppo dalla verticale. **Non decide**: propone.
// La posizione di un impianto è una decisione protesica prima che ossea, e nessun punteggio
// calcolato sui voxel sa dove andrà la corona.
//
// Per questo il risultato dice sempre di quanto migliora rispetto a ciò che c'era, e non
// sostituisce nulla da sé.
//
// # Le due decisioni che rendono la ricerca sensata invece che assurda
//
// **Il margine dal nervo si satura.** Oltre la soglia di attenzione, un millimetro in più non
// vale niente: sono entrambe situazioni sicure. Senza saturazione la ricerca inclinerebbe
// l'impianto verso il lato opposto della mandibola per guadagnare margine inutile, e
// restituirebbe un asse tecnicamente ottimo e clinicamente ridicolo.
//
// **La compenetrazione è un rifiuto, non un punteggio basso.** Un asse che entra nel canale non
// è una soluzione peggiore delle altre: non è una soluzione. Si scarta, e se non ne resta
// nessuna lo si dice invece di proporre la meno peggio spacciandola per buona.

/// Un'inclinazione proposta, con le ragioni per cui lo è.
public struct AxisSuggestion: Sendable {

    public let axis: Vec3
    /// Inclinazione rispetto alla verticale di riferimento, in gradi.
    public let angulationDegrees: Double
    /// Distanza minima dai canali con questo asse. `nil` se non ci sono canali tracciati.
    public let minimumNerveDistanceMM: Double?
    /// Densità media attorno alla superficie implantare. `nil` senza volume.
    public let meanBoneGV: Double?
    /// Quanto migliora la distanza dal nervo rispetto all'asse di partenza, in millimetri.
    public let nerveGainMM: Double
    /// Se **nessuna** inclinazione esaminata rispetta la soglia di sicurezza.
    ///
    /// Vero significa che il problema non è l'asse: è il punto d'inserzione, o l'impianto scelto.
    /// Continuare a inclinare non lo risolve, e dirlo è più utile che proporre la meno peggio.
    public let allCandidatesUnsafe: Bool
}

public enum ImplantAxisAdvisor {

    /// Inclinazione massima esaminata rispetto all'asse di partenza, in gradi.
    ///
    /// Venti gradi non è un limite tecnico ma protesico: oltre, la corona ha bisogno di un
    /// moncone angolato e il vantaggio osseo si paga altrove. Cercare più in là proporrebbe assi
    /// che nessuno userebbe.
    public static let maximumTiltDegrees: Double = 20

    /// Propone un asse migliore, se c'è.
    ///
    /// - Returns: `nil` se non c'è nulla su cui decidere — nessun canale e nessun volume — perché
    ///   in quel caso qualunque asse vale quanto un altro e proporne uno sarebbe arbitrario.
    public static func suggest(
        for implant: ImplantPlacement,
        nerves: [NerveCanal],
        volume: Volume?,
        thresholds: SafetyThresholds = .nerve,
        referenceUp: Vec3 = Vec3(0, 0, 1),
        rings: Int = 4,
        stepsPerRing: Int = 12
    ) -> AxisSuggestion? {

        let usableNerves = nerves.filter(\.isUsable)
        guard !usableNerves.isEmpty || volume != nil else { return nil }
        guard let basis = implant.perpendicularBasis() else { return nil }

        let baseline = evaluate(
            axis: implant.axis, implant: implant, nerves: usableNerves, volume: volume)

        var candidates: [(axis: Vec3, nerve: Double?, bone: Double?)] = [
            (implant.axis, baseline.nerve, baseline.bone)
        ]

        // Una calotta sferica attorno all'asse di partenza: anelli d'inclinazione crescente, e
        // su ciascuno un giro di direzioni. Campionare a caso darebbe risultati diversi a ogni
        // chiamata, e una proposta che cambia senza che sia cambiato nulla non è utilizzabile.
        for ring in 1...max(rings, 1) {
            let tilt = maximumTiltDegrees * Double(ring) / Double(max(rings, 1)) * .pi / 180
            for step in 0..<max(stepsPerRing, 3) {
                let phi = 2 * .pi * Double(step) / Double(max(stepsPerRing, 3))
                let offset = basis.u * (Foundation.cos(phi) * Foundation.sin(tilt))
                    + basis.v * (Foundation.sin(phi) * Foundation.sin(tilt))
                guard let axis = (implant.axis * Foundation.cos(tilt) + offset).normalized else {
                    continue
                }
                let scores = evaluate(
                    axis: axis, implant: implant, nerves: usableNerves, volume: volume)
                candidates.append((axis, scores.nerve, scores.bone))
            }
        }

        // Chi entra nel canale è fuori, non ultimo in classifica.
        let safe = candidates.filter { ($0.nerve ?? .infinity) >= thresholds.dangerMM }
        let pool = safe.isEmpty ? candidates : safe

        let boneValues = pool.compactMap(\.bone)
        let boneRange = (boneValues.min() ?? 0, boneValues.max() ?? 1)

        func score(_ candidate: (axis: Vec3, nerve: Double?, bone: Double?)) -> Double {
            // Margine dal nervo, saturato alla soglia di attenzione: oltre, non serve.
            let margin = min(candidate.nerve ?? thresholds.cautionMM, thresholds.cautionMM)
            let nerveTerm = thresholds.cautionMM > 0 ? margin / thresholds.cautionMM : 1

            let span = boneRange.1 - boneRange.0
            let boneTerm = span > 1e-6 ? ((candidate.bone ?? boneRange.0) - boneRange.0) / span : 0

            let tilt = angleDegrees(candidate.axis, implant.axis)
            let tiltPenalty = tilt / maximumTiltDegrees

            // Il nervo pesa il doppio dell'osso, e l'inclinazione trattiene: un asse che guadagna
            // poco margine stravolgendo l'orientamento non è un miglioramento.
            return nerveTerm * 2 + boneTerm - tiltPenalty * 0.5
        }

        guard let best = pool.max(by: { score($0) < score($1) }) else { return nil }

        return AxisSuggestion(
            axis: best.axis,
            angulationDegrees: angleDegrees(best.axis, referenceUp),
            minimumNerveDistanceMM: best.nerve,
            meanBoneGV: best.bone,
            nerveGainMM: (best.nerve ?? 0) - (baseline.nerve ?? 0),
            allCandidatesUnsafe: safe.isEmpty && !usableNerves.isEmpty)
    }

    /// Distanza minima dai canali e densità media attorno alla superficie, per un asse dato.
    private static func evaluate(
        axis: Vec3, implant: ImplantPlacement, nerves: [NerveCanal], volume: Volume?
    ) -> (nerve: Double?, bone: Double?) {
        var moved = implant
        moved.axis = axis
        let surface = moved.surfacePoints(levels: 12, radialSteps: 12)
        guard !surface.isEmpty else { return (nil, nil) }

        var closest: Double?
        for nerve in nerves {
            for point in surface {
                guard let distance = nerve.signedDistance(from: point) else { continue }
                if closest == nil || distance < closest! { closest = distance }
            }
        }

        var bone: Double?
        if let volume {
            // Mezzo millimetro fuori dalla superficie: campionando sul contorno si prenderebbero
            // voxel a cavallo del bordo, mediando osso e ciò che sta oltre. Fuori si legge l'osso
            // che accoglierà l'impianto, che è ciò che interessa.
            let outside = moved.surfacePoints(aroundOffsetMM: 0.5, levels: 12, radialSteps: 12)
            var total = 0.0
            var count = 0
            for point in outside {
                guard let value = volume.interpolatedDensityValue(atPatient: point) else { continue }
                total += value
                count += 1
            }
            if count > 0 { bone = total / Double(count) }
        }

        return (closest, bone)
    }

    private static func angleDegrees(_ a: Vec3, _ b: Vec3) -> Double {
        guard let angle = a.angle(to: b) else { return 0 }
        return min(angle, Double.pi - angle) * 180 / .pi
    }
}
