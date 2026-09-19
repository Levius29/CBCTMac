import DICOMCore
import Foundation

// Le date di un paziente, il loro stato, e la regola che impedisce il confronto peggiore di tutti.
//
// # Il difetto da cui nasce questo file
//
// Scorrere le date è il gesto naturale del controllo nel tempo: prima, sei mesi, un anno. Se
// mentre la data nuova si sta allineando il riquadro continua a mostrare quella vecchia, chi
// guarda vede l'immagine di prima sotto l'etichetta di dopo — e conclude che in sei mesi non è
// cambiato niente, che è esattamente la risposta sbagliata alla domanda per cui ha aperto il
// programma. Lo stesso vale per una data fallita e per una in cui il punto seguito è fuori campo.
//
// La regola è quindi una sola, e sta nel tipo invece che nelle viste: **una data si mostra solo
// se è pronta**. Negli altri casi il riquadro resta vuoto e dice perché.
//
// # Perché gli intervalli in giorni sono quelli veri
//
// Perché la distanza fra i controlli è parte del dato clinico: sei mesi e diciotto non si leggono
// allo stesso modo. Una striscia che mostrasse le date a intervalli uguali suggerirebbe una
// regolarità che non c'è.

/// A che punto è l'allineamento di una data.
public enum FollowUpAlignmentState: Hashable, Sendable {
    /// Mai tentato.
    case notPrepared
    /// In coda: l'allineamento è chiesto, non ancora partito.
    case queued
    /// In corso, con la riga da mostrare.
    case running(stage: String)
    /// Pronta, con la copertura dichiarata dalla registrazione.
    case ready(coverage: Double)
    /// Fallita, con il motivo.
    case failed(reason: String)

    /// Vero solo per `ready`. È la regola dell'intestazione, in una riga.
    public var isDisplayable: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Vero se qualcosa sta per succedere o sta succedendo: serve a non rimetterla in coda.
    public var isPending: Bool {
        switch self {
        case .queued, .running: return true
        case .notPrepared, .ready, .failed: return false
        }
    }

    /// Che cosa mostrare accanto alla data.
    public var localizedName: String {
        switch self {
        case .notPrepared: return "Da allineare"
        case .queued: return "In coda"
        case .running(let stage): return stage
        case .ready: return "Allineata · da verificare a occhio"
        case .failed(let reason): return "Non allineata: \(reason)"
        }
    }
}

/// Un esame del paziente in una data, con lo stato del suo allineamento.
public struct FollowUpStudy: Identifiable, Hashable, Sendable {
    public let id: UUID
    /// Come si chiama nella striscia: di solito la data, come la scrive l'interfaccia.
    public var label: String
    /// Quando è stato acquisito. È la sola cosa che ne decide l'ordine.
    public var acquiredOn: Date
    public var state: FollowUpAlignmentState

    public init(
        id: UUID = UUID(),
        label: String,
        acquiredOn: Date,
        state: FollowUpAlignmentState = .notPrepared
    ) {
        self.id = id
        self.label = label
        self.acquiredOn = acquiredOn
        self.state = state
    }
}

/// Le date di un paziente e quella presa come riferimento.
///
/// È dato, non interfaccia: quali date esistano, quale sia il riferimento e quale si possa
/// mostrare si decide qui, dove si verifica senza schermo — la stessa ragione per cui
/// `InspectorSections` sta in StudyKit e non nelle viste.
public struct FollowUpTimeline: Hashable, Sendable {

    /// Le date in ordine di acquisizione, dalla più vecchia alla più recente.
    public private(set) var studies: [FollowUpStudy]
    /// La data presa come riferimento: è la griglia su cui tutte le altre vengono portate.
    public private(set) var referenceID: UUID?

    public init() {
        studies = []
        referenceID = nil
    }

    // MARK: Composizione

    /// Aggiunge una data mantenendo l'ordine cronologico. La prima aggiunta diventa il riferimento.
    public mutating func add(_ study: FollowUpStudy) {
        guard !studies.contains(where: { $0.id == study.id }) else { return }
        studies.append(study)
        studies.sort { $0.acquiredOn < $1.acquiredOn }
        if referenceID == nil { referenceID = study.id }
    }

    public mutating func remove(studyID: UUID) {
        studies.removeAll { $0.id == studyID }
        if referenceID == studyID { referenceID = studies.first?.id }
    }

    /// Cambia il riferimento. Ogni allineamento fatto verso il riferimento precedente decade:
    /// era una posa verso un'altra griglia, e tenerla significherebbe confrontare con la data
    /// sbagliata senza dirlo.
    public mutating func setReference(_ studyID: UUID) {
        guard studies.contains(where: { $0.id == studyID }), referenceID != studyID else { return }
        referenceID = studyID
        for index in studies.indices {
            studies[index].state = .notPrepared
        }
    }

    public mutating func setState(_ state: FollowUpAlignmentState, forStudy studyID: UUID) {
        guard let index = studies.firstIndex(where: { $0.id == studyID }) else { return }
        studies[index].state = state
    }

    /// Mette in coda tutte le date che non sono il riferimento e non sono già pronte o in corso.
    @discardableResult
    public mutating func queueAllPending() -> Int {
        var queued = 0
        for index in studies.indices {
            let study = studies[index]
            guard study.id != referenceID, !study.state.isPending, !study.state.isDisplayable else {
                continue
            }
            studies[index].state = .queued
            queued += 1
        }
        return queued
    }

    /// Svuota la coda. Non tocca ciò che è già in corso: quello finisce, ed è giusto che finisca —
    /// interrompere a metà lascerebbe un file scritto per metà e nessuna posa.
    public mutating func cancelQueue() {
        for index in studies.indices where studies[index].state == .queued {
            studies[index].state = .notPrepared
        }
    }

    // MARK: Letture

    public var reference: FollowUpStudy? {
        guard let referenceID else { return nil }
        return studies.first { $0.id == referenceID }
    }

    public func study(_ studyID: UUID) -> FollowUpStudy? {
        studies.first { $0.id == studyID }
    }

    /// Le date che si possono mostrare in un confronto, riferimento escluso.
    public var displayable: [FollowUpStudy] {
        studies.filter { $0.id != referenceID && $0.state.isDisplayable }
    }

    /// La prossima data in coda da allineare, in ordine cronologico.
    public var nextQueued: FollowUpStudy? {
        studies.first { $0.state == .queued }
    }

    /// Vero se quella data si può disegnare adesso. La regola dell'intestazione: mai il volume
    /// precedente sotto una data nuova.
    public func canDisplay(_ studyID: UUID) -> Bool {
        study(studyID)?.state.isDisplayable ?? false
    }

    /// Giorni veri fra due date, negativi se la seconda precede la prima.
    ///
    /// Si contano sui secondi e non sul calendario di proposito: l'intervallo fra due esami è una
    /// durata, non un numero di caselle su un calendario, e la durata non cambia con il fuso né
    /// con l'ora legale.
    public func daysBetween(_ first: UUID, and second: UUID) -> Int? {
        guard let a = study(first), let b = study(second) else { return nil }
        let seconds = b.acquiredOn.timeIntervalSince(a.acquiredOn)
        return Int((seconds / 86_400).rounded())
    }

    /// Giorni trascorsi dal riferimento, per la striscia delle date.
    public func daysFromReference(_ studyID: UUID) -> Int? {
        guard let referenceID else { return nil }
        return daysBetween(referenceID, and: studyID)
    }

    /// L'ordine in cui scorrere la storia: le date mostrabili, dalla più vecchia alla più recente,
    /// riferimento compreso perché la storia comincia da lì.
    public var playbackOrder: [UUID] {
        studies.filter { $0.id == referenceID || $0.state.isDisplayable }.map(\.id)
    }

    /// La data mostrabile successiva a quella indicata, o `nil` se è l'ultima.
    public func studyAfter(_ studyID: UUID) -> UUID? {
        let order = playbackOrder
        guard let index = order.firstIndex(of: studyID), index + 1 < order.count else { return nil }
        return order[index + 1]
    }

    /// La data mostrabile precedente, o `nil` se è la prima.
    public func studyBefore(_ studyID: UUID) -> UUID? {
        let order = playbackOrder
        guard let index = order.firstIndex(of: studyID), index > 0 else { return nil }
        return order[index - 1]
    }
}
