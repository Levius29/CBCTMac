import DICOMCore
import Foundation

// I tre modi di guardare due esami insieme, e perché servono tutti e tre.
//
// # Affiancati
//
// Il modo onesto: due immagini intere, nessuna sovrapposizione, niente che possa nascondere
// qualcosa. È quello in cui si guarda **che cosa** c'è. Il suo limite è che l'occhio confronta
// male due immagini distanti fra loro: uno spostamento di mezzo millimetro non si vede.
//
// # Tendina
//
// Una sola immagine, tagliata in verticale: a sinistra l'esame di riferimento, a destra quello di
// confronto. Il bordo si trascina. È il modo in cui si vede **dove** una struttura si è spostata,
// perché la discontinuità sul bordo salta all'occhio molto prima di qualunque differenza fra due
// immagini affiancate. Il suo limite è che mostra due metà, mai lo stesso punto due volte.
//
// # Lampeggio
//
// Lo stesso riquadro, alternato. È il più sensibile dei tre — il sistema visivo umano riconosce
// il movimento meglio di qualunque altra differenza, ed è il principio con cui gli astronomi
// trovavano i pianeti sulle lastre — e per la stessa ragione è il più insidioso: se i due esami
// non sono allineati bene, **tutto** lampeggia, e la sensazione di cambiamento è totale e falsa.
// Va usato dopo aver verificato l'allineamento sui reperi, non al posto di quella verifica.
//
// # Perché questo tipo non ha un timer dentro
//
// Perché un tipo con dentro un orologio non si può provare: si proverebbe l'orologio. Qui la fase
// del lampeggio è una **funzione del tempo** passato da fuori, e la vista gli dà il suo. Provare
// che al secondo 0,4 con periodo 0,8 si vede il riferimento non richiede di aspettare 0,4 secondi.

/// Come si mettono a confronto i due esami.
public enum ComparisonMode: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    /// Due riquadri, uno per esame.
    case sideBySide
    /// Un riquadro solo, tagliato da una tendina verticale trascinabile.
    case wipe
    /// Un riquadro solo, che alterna i due esami.
    case blink

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .sideBySide: return "Affiancati"
        case .wipe: return "Tendina"
        case .blink: return "Lampeggio"
        }
    }

    /// L'avvertenza da tenere accanto al comando, dove ce n'è una.
    public var caution: String? {
        switch self {
        case .sideBySide: return nil
        case .wipe: return nil
        case .blink:
            return
                "Con un allineamento impreciso lampeggia tutto: verifica i reperi prima di fidarti."
        }
    }
}

/// Lo stato del confronto: quale modo, dove sta la tendina, quanto dura il lampeggio, dov'è il mirino.
///
/// I valori si cambiano con i metodi, non scrivendo nelle proprietà: una tendina a 1,4 o un
/// periodo di lampeggio a zero non sono stati che il resto del programma debba sapersi difendere
/// dal ricevere.
// non-ancora-collegato: il modulo del confronto nel tempo è verificato, la sua schermata non c'è
// ancora. Vedi docs/follow-up.md e la fase 7 nel README.
public struct ComparisonState: Hashable, Sendable {

    /// Periodo minimo del lampeggio. Sotto, l'alternanza smette di essere leggibile e diventa uno
    /// sfarfallio: l'occhio non distingue più le due immagini, le fonde.
    public static let minimumBlinkPeriodSeconds = 0.2
    /// Periodo massimo: oltre, fra un'immagine e l'altra passa troppo tempo e il confronto
    /// diventa un ricordo invece che una percezione.
    public static let maximumBlinkPeriodSeconds = 4.0

    public private(set) var mode: ComparisonMode
    /// Posizione della tendina, da `0` (tutto riferimento) a `1` (tutto confronto).
    public private(set) var wipeFraction: Double
    /// Durata di un ciclo completo del lampeggio, in secondi.
    public private(set) var blinkPeriodSeconds: Double
    /// Il mirino condiviso, in millimetri Patient dell'esame **di riferimento**.
    ///
    /// Uno solo, e nello spazio del riferimento: due mirini indipendenti sarebbero il modo più
    /// diretto di confrontare due punti diversi credendo di confrontarne uno.
    public private(set) var cursorMM: Vec3

    public init(
        mode: ComparisonMode = .sideBySide,
        wipeFraction: Double = 0.5,
        blinkPeriodSeconds: Double = 0.8,
        cursorMM: Vec3 = .zero
    ) {
        self.mode = mode
        self.wipeFraction = Self.clampedFraction(wipeFraction)
        self.blinkPeriodSeconds = Self.clampedPeriod(blinkPeriodSeconds)
        self.cursorMM = cursorMM
    }

    // MARK: Modifiche

    public mutating func setMode(_ mode: ComparisonMode) {
        self.mode = mode
    }

    public mutating func setWipeFraction(_ fraction: Double) {
        wipeFraction = Self.clampedFraction(fraction)
    }

    public mutating func setBlinkPeriodSeconds(_ seconds: Double) {
        blinkPeriodSeconds = Self.clampedPeriod(seconds)
    }

    public mutating func moveCursor(toMM point: Vec3) {
        guard point.isFinite else { return }
        cursorMM = point
    }

    // MARK: Letture

    /// Se al tempo indicato si sta mostrando l'esame di confronto.
    ///
    /// Fuori dal lampeggio la risposta è sempre `false`: negli altri due modi il riferimento è
    /// sempre a schermo, e chi disegna non deve interrogare il tempo per saperlo.
    public func showsFollowUp(atSeconds time: Double) -> Bool {
        guard mode == .blink, time.isFinite else { return false }
        let phase = time.truncatingRemainder(dividingBy: blinkPeriodSeconds)
        let normalized = phase < 0 ? phase + blinkPeriodSeconds : phase
        return normalized >= blinkPeriodSeconds * 0.5
    }

    /// Dove cade il bordo della tendina, in punti, dentro un riquadro largo `width`.
    public func wipeSplit(inWidth width: Double) -> Double {
        guard width.isFinite, width > 0 else { return 0 }
        return width * wipeFraction
    }

    /// Il mirino portato nello spazio dell'esame di confronto.
    ///
    /// È l'unico modo corretto di tenere legati i due riquadri: si porta **il punto**, non
    /// l'indice di slice. Due esami hanno origini e passi diversi, e la slice 120 dell'uno non è
    /// la slice 120 dell'altro nemmeno dopo l'allineamento.
    public func cursorMM(in pose: RigidPose) -> Vec3 {
        pose.apply(toPoint: cursorMM)
    }

    // MARK: Limiti

    private static func clampedFraction(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return Swift.min(Swift.max(value, 0), 1)
    }

    private static func clampedPeriod(_ value: Double) -> Double {
        guard value.isFinite else { return 0.8 }
        return Swift.min(
            Swift.max(value, minimumBlinkPeriodSeconds), maximumBlinkPeriodSeconds)
    }
}
