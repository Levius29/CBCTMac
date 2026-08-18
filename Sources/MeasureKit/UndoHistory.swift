import Foundation

// Annulla e ripeti.
//
// È l'unica voce del catalogo che non compare in nessuna delle schermate di riferimento, e non
// perché manchi: si nota solo quando manca. Una funzione che nessuno guarda finché non serve, e
// quando serve serve subito.
//
// # A istantanee, non a comandi inversi
//
// La scuola classica è la pila di comandi, ognuno col proprio inverso. È elegante e qui sarebbe
// sbagliata: il documento di piano è piccolo — annotazioni, impianti, curve, qualche decina di
// kilobyte — e ogni operazione nuova costringerebbe a scrivere e mantenere *due* pezzi di codice
// invece di uno, con il rischio che l'inverso sia impreciso e che annullare non riporti
// esattamente indietro. Con le istantanee un'operazione nuova non richiede nulla: si registra lo
// stato dopo, e l'annullamento è esatto per costruzione.
//
// Il prezzo è la memoria, e qui non si paga. Sessantaquattro copie di qualche decina di kilobyte
// sono pochi megabyte; le copie del **volume** non entrano mai in cronologia, perché il volume
// non è parte del piano.

/// Cronologia a istantanee di un valore.
public struct UndoHistory<Value: Equatable & Sendable>: Sendable {

    private struct Step: Sendable {
        var value: Value
        var label: String
        var stampedAt: Date
    }

    /// Tutti gli stati, dal più vecchio al più recente. Non è mai vuota: il primo elemento è lo
    /// stato iniziale, e la sua presenza è ciò che permette di annullare la prima operazione.
    private var steps: [Step]
    private var position: Int
    private let limit: Int

    public init(initial: Value, limit: Int = 64) {
        self.steps = [Step(value: initial, label: "Stato iniziale", stampedAt: Date())]
        self.position = 0
        self.limit = max(limit, 1)
    }

    public var current: Value { steps[position].value }

    public var canUndo: Bool { position > 0 }
    public var canRedo: Bool { position + 1 < steps.count }

    /// Etichetta di ciò che «annulla» disferebbe.
    public var undoLabel: String? { canUndo ? steps[position].label : nil }

    /// Etichetta di ciò che «ripeti» rifarebbe.
    public var redoLabel: String? { canRedo ? steps[position + 1].label : nil }

    /// Quanti passi si possono annullare.
    public var undoCount: Int { position }

    // MARK: Registrare

    /// Registra uno stato nuovo.
    ///
    /// Uno stato uguale al corrente non produce un passo: senza questo controllo, ogni ridisegno
    /// che ricalcola lo stesso valore riempirebbe la cronologia di passi che non disfano niente,
    /// e «annulla» premuto dieci volte non cambierebbe nulla sullo schermo.
    public mutating func commit(_ value: Value, label: String) {
        guard value != current else { return }
        appendStep(Step(value: value, label: label, stampedAt: Date()))
    }

    /// Aggiorna l'ultimo passo invece di crearne uno nuovo, se ha la stessa etichetta ed è recente.
    ///
    /// **È la parte che rende utile la funzione.** Trascinando un impianto si producono centinaia
    /// di stati intermedi: senza raggrupparli, annullare quel gesto richiederebbe duecento
    /// pressioni, e la cronologia si riempirebbe di rumore fino a espellere le operazioni che
    /// contavano. Così un trascinamento intero è **un** passo.
    ///
    /// La finestra temporale, e non solo l'etichetta: due trascinamenti separati dello stesso
    /// impianto sono due operazioni distinte, e chi ha fatto una pausa fra i due si aspetta di
    /// poter disfare solo il secondo.
    public mutating func coalesce(_ value: Value, label: String, within seconds: TimeInterval) {
        guard value != current else { return }

        let now = Date()
        if position > 0,
            steps[position].label == label,
            now.timeIntervalSince(steps[position].stampedAt) <= seconds
        {
            steps[position].value = value
            steps[position].stampedAt = now
            // Anche aggiornando si taglia la coda: lo stato è cambiato, e ciò che seguiva non è
            // più raggiungibile da qui.
            if canRedo { steps.removeSubrange((position + 1)...) }
            return
        }
        appendStep(Step(value: value, label: label, stampedAt: now))
    }

    private mutating func appendStep(_ step: Step) {
        // Registrare dopo un annulla **cancella** la coda del ripeti. È il comportamento atteso
        // ovunque, e ometterlo produrrebbe un «ripeti» che riporta a uno stato incompatibile con
        // quello corrente: corromperebbe il documento invece di ripristinarlo.
        if canRedo { steps.removeSubrange((position + 1)...) }

        steps.append(step)
        position = steps.count - 1

        // Il limite conta i passi **annullabili**, cioè gli stati oltre quello iniziale.
        // Si scarta dalla testa e non dalla coda: buttare via il più recente sembra equivalente
        // e renderebbe «annulla» inefficace proprio sull'ultima cosa fatta, che è l'unica su cui
        // lo si preme davvero.
        while steps.count > limit + 1 {
            steps.removeFirst()
            position -= 1
        }
    }

    // MARK: Percorrere

    @discardableResult
    public mutating func undo() -> Value? {
        guard canUndo else { return nil }
        position -= 1
        return current
    }

    @discardableResult
    public mutating func redo() -> Value? {
        guard canRedo else { return nil }
        position += 1
        return current
    }

    /// Dimentica la cronologia tenendo lo stato corrente. Serve all'apertura di un altro studio:
    /// annullare fin dentro il caso precedente non ha senso, e sarebbe pericoloso.
    public mutating func reset(to value: Value) {
        steps = [Step(value: value, label: "Stato iniziale", stampedAt: Date())]
        position = 0
    }
}
