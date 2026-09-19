import DICOMCore
import Foundation

// Il punto che si segue nel tempo, e le tre regole che lo rendono affidabile.
//
// # Perché una regione salvata e non semplicemente il mirino
//
// Perché il mirino si muove. Si apre il controllo a sei mesi, si scorre per arrivare al sito, e
// intanto il punto che si stava seguendo è già altrove: al confronto successivo si guarda un
// posto diverso credendo di guardare lo stesso, e la differenza che si osserva è la differenza
// fra due posti. La regione è un valore salvato che **non cambia scorrendo**, e per cambiarla
// serve un gesto esplicito.
//
// # Le tre regole, e perché sono queste
//
// 1. **Spostare il centro o cambiare il raggio azzera le verifiche.** Una verifica dice «ho
//    guardato i reperi e il punto è quello giusto», e vale per il punto che c'era allora. Tenerla
//    dopo uno spostamento significa dichiarare verificato qualcosa che nessuno ha guardato.
// 2. **Rinominare le conserva.** Il nome non è geometria.
// 3. **Ogni data ha la sua correzione, indipendente dalle altre.** La registrazione automatica
//    può sbagliare di un millimetro su una data e andare benissimo sulle altre; una correzione
//    unica le trascinerebbe tutte. La correzione è un `+` sopra la posa, non una sua sostituzione,
//    e il punto di riferimento resta quello di partenza.
//
// Sono le stesse regole di OpenMRI, che le ha ricavate dallo stesso problema. Qui cambia una
// cosa: il fuori campo si decide sulla **geometria originale** dell'esame di confronto, mai sul
// volume ricampionato. Sul ricampionato il fuori campo è riempito di aria, e l'aria è un valore
// come un altro: il punto sembrerebbe dentro, con un tessuto plausibile sotto, e non c'è.

/// La correzione manuale del punto per una data, sopra la registrazione automatica.
public struct FocusCorrection: Hashable, Sendable, Codable {
    /// Quale esame di confronto.
    public let studyID: UUID
    /// Scostamento in millimetri, **nello spazio Patient dell'esame di confronto**.
    public var offsetMM: Vec3

    public init(studyID: UUID, offsetMM: Vec3) {
        self.studyID = studyID
        self.offsetMM = offsetMM
    }
}

/// Se il punto seguito cade nel campo acquisito dell'esame di confronto.
public enum FocusFieldStatus: String, Hashable, Sendable, Codable {
    /// Il punto e tutto il suo intorno sono dentro il campo.
    case inside
    /// Il centro è dentro, una parte dell'intorno è fuori: si può guardare, non si può misurare.
    case clipped
    /// Il centro è fuori dal campo acquisito: quella data non mostra questa regione.
    case outside

    /// Vero se qualcosa si può mostrare. Il confronto lo usa per non disegnare il volume
    /// precedente sotto una data nuova, che è il modo più efficace di far credere a un cambiamento
    /// che non c'è.
    public var isDisplayable: Bool { self != .outside }
}

/// Dove finisce la regione seguita, dentro un esame di confronto.
public struct FocusPlacement: Hashable, Sendable {
    /// Centro della regione nello spazio Patient dell'esame di confronto, correzione inclusa.
    public let centerMM: Vec3
    /// Raggio, invariato: una posa rigida non cambia le distanze.
    public let radiusMM: Double
    public let status: FocusFieldStatus

    public init(centerMM: Vec3, radiusMM: Double, status: FocusFieldStatus) {
        self.centerMM = centerMM
        self.radiusMM = radiusMM
        self.status = status
    }
}

/// Una regione seguita nel tempo: dove sta, quanto è larga, e che cosa si è già verificato.
///
/// Il centro è in millimetri Patient dell'esame **di riferimento**. Non è una segmentazione: è un
/// intorno geometrico. Dopo un intervento la corrispondenza fra i tessuti dei due esami può
/// semplicemente non esistere, e nessuna sfera può inventarla.
// non-ancora-collegato: il modulo del confronto nel tempo è verificato, la sua schermata non c'è
// ancora. Vedi docs/follow-up.md e la fase 7 nel README.
public struct FocusRegion: Identifiable, Hashable, Sendable, Codable {

    public let id: UUID
    /// Il nome che le dà chi la segue. Non entra in nessun calcolo.
    public var name: String
    /// Centro in millimetri Patient dell'esame di riferimento.
    public private(set) var centerMM: Vec3
    /// Raggio dell'intorno, in millimetri.
    public private(set) var radiusMM: Double
    /// Le correzioni manuali, una per data al massimo.
    public private(set) var corrections: [FocusCorrection]
    /// Le date su cui qualcuno ha guardato i reperi e ha detto che il punto è quello giusto.
    public private(set) var checkedStudyIDs: [UUID]

    /// Raggio minimo: sotto, l'intorno è più piccolo di un voxel e non è più un intorno.
    public static let minimumRadiusMM = 0.5

    public init(id: UUID = UUID(), name: String, centerMM: Vec3, radiusMM: Double) {
        self.id = id
        self.name = name
        self.centerMM = centerMM
        self.radiusMM = Swift.max(radiusMM, Self.minimumRadiusMM)
        self.corrections = []
        self.checkedStudyIDs = []
    }

    // MARK: Modifiche

    /// Sposta il centro. Azzera ogni verifica: nessuno ha ancora guardato *questo* punto.
    public mutating func move(toMM point: Vec3) {
        guard point != centerMM else { return }
        centerMM = point
        checkedStudyIDs = []
    }

    /// Cambia il raggio. Azzera ogni verifica, per la stessa ragione.
    public mutating func setRadiusMM(_ radius: Double) {
        let clamped = Swift.max(radius, Self.minimumRadiusMM)
        guard clamped != radiusMM else { return }
        radiusMM = clamped
        checkedStudyIDs = []
    }

    /// Registra una correzione manuale per una data, e ne azzera la sola verifica.
    public mutating func correct(studyID: UUID, offsetMM: Vec3) {
        if let index = corrections.firstIndex(where: { $0.studyID == studyID }) {
            corrections[index].offsetMM = offsetMM
        } else {
            corrections.append(FocusCorrection(studyID: studyID, offsetMM: offsetMM))
        }
        checkedStudyIDs.removeAll { $0 == studyID }
    }

    /// Toglie la correzione manuale di una data e torna alla sola registrazione automatica.
    public mutating func clearCorrection(studyID: UUID) {
        corrections.removeAll { $0.studyID == studyID }
        checkedStudyIDs.removeAll { $0 == studyID }
    }

    /// Dichiara di aver guardato i reperi su una data e di aver trovato il punto al posto giusto.
    public mutating func markChecked(studyID: UUID) {
        guard !checkedStudyIDs.contains(studyID) else { return }
        checkedStudyIDs.append(studyID)
    }

    // MARK: Letture

    public func isChecked(studyID: UUID) -> Bool {
        checkedStudyIDs.contains(studyID)
    }

    public func correctionMM(forStudy studyID: UUID) -> Vec3? {
        corrections.first { $0.studyID == studyID }?.offsetMM
    }

    /// Dove cade la regione in un esame di confronto, e se quel campo l'ha davvero acquisita.
    ///
    /// `geometry` è la geometria **originale** dell'esame di confronto, non quella del volume
    /// ricampionato: sul ricampionato il fuori campo è indistinguibile dall'aria.
    public func placement(in geometry: VolumeGeometry, pose: RigidPose, studyID: UUID)
        -> FocusPlacement
    {
        let center = pose.apply(toPoint: centerMM) + (correctionMM(forStudy: studyID) ?? .zero)
        let status: FocusFieldStatus
        if !geometry.containsPatientPoint(center) {
            status = .outside
        } else {
            // Sei punti sugli assi: se l'intorno esce da qualche parte, esce da uno di questi.
            let probes = [
                center + Vec3(radiusMM, 0, 0), center - Vec3(radiusMM, 0, 0),
                center + Vec3(0, radiusMM, 0), center - Vec3(0, radiusMM, 0),
                center + Vec3(0, 0, radiusMM), center - Vec3(0, 0, radiusMM),
            ]
            status = probes.allSatisfy { geometry.containsPatientPoint($0) } ? .inside : .clipped
        }
        return FocusPlacement(centerMM: center, radiusMM: radiusMM, status: status)
    }
}
