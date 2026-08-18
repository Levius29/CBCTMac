import DICOMCore
import Foundation

// I volumi dello studio, e da dove vengono.
//
// # Il difetto che questo file corregge
//
// Ritagliare e ricampionare **sostituiva** il volume aperto. Funziona finché si sceglie bene la
// regione al primo colpo; alla seconda volta si scopre che l'originale non c'è più, e l'unico
// modo di tornarci è riaprire lo studio — perdendo misure, curva e impianti.
//
// È un difetto della forma peggiore: non si manifesta durante l'operazione, ma dieci minuti dopo,
// quando serve un ritaglio diverso. Il rimedio non è un avviso, è che i volumi siano più d'uno.
//
// # Provenienza, e perché si registra
//
// Ogni volume derivato sa da quale viene e con quale operazione. Serve a tre cose concrete: la
// barra laterale può mostrarli annidati invece che in un elenco piatto; togliendo un derivato si
// può tornare al suo genitore invece che a un volume qualunque; e i numeri letti su un volume
// ricampionato portano con sé la catena che li ha prodotti, che è ciò che permette di dire da
// dove viene una misura.

/// Da dove viene un volume.
public enum VolumeProvenance: Hashable, Sendable {
    /// Letto da disco.
    case imported
    /// Ricavato da un altro volume di questa raccolta.
    case derived(from: UUID, operation: String)
    /// Fantoccio sintetico: né letto né derivato, e va detto.
    case synthetic

    public var isImported: Bool {
        if case .imported = self { return true }
        return false
    }

    public var parentID: UUID? {
        if case .derived(let parent, _) = self { return parent }
        return nil
    }
}

/// Un volume della raccolta, col suo nome e la sua origine.
public struct VolumeEntry: Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public let provenance: VolumeProvenance
    public let volume: Volume
    public let addedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        provenance: VolumeProvenance,
        volume: Volume,
        addedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.provenance = provenance
        self.volume = volume
        self.addedAt = addedAt
    }

    /// Riassunto per la barra laterale: dimensioni e passo.
    public var summary: String {
        let g = volume.geometry
        let spacing = g.spacingMM
        let isotropic =
            abs(spacing.x - spacing.y) < 1e-6 && abs(spacing.y - spacing.z) < 1e-6
        let step =
            isotropic
            ? String(format: "%.2f mm iso", spacing.x)
            : String(format: "%.2f × %.2f × %.2f mm", spacing.x, spacing.y, spacing.z)
        return "\(g.columnCount)×\(g.rowCount)×\(g.sliceCount) · \(step)"
    }
}

/// La raccolta dei volumi aperti, con quello selezionato.
public struct VolumeLibrary: Sendable {

    public private(set) var entries: [VolumeEntry] = []
    public private(set) var selectedID: UUID?

    public init() {}

    public var selected: VolumeEntry? {
        guard let selectedID else { return nil }
        return entries.first { $0.id == selectedID }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public subscript(id: UUID) -> VolumeEntry? {
        entries.first { $0.id == id }
    }

    // MARK: Aggiungere

    /// Apre uno studio: **svuota** la raccolta e mette dentro il volume letto.
    ///
    /// Svuota di proposito. I derivati di uno studio non hanno senso accanto a un altro studio, e
    /// tenerli sarebbe il modo più diretto di misurare sul paziente sbagliato.
    @discardableResult
    public mutating func open(_ volume: Volume, named name: String, provenance: VolumeProvenance)
        -> UUID
    {
        let entry = VolumeEntry(
            name: cleaned(name, fallback: "Studio"), provenance: provenance, volume: volume)
        entries = [entry]
        selectedID = entry.id
        return entry.id
    }

    /// Aggiunge un volume derivato e lo seleziona.
    ///
    /// Selezionarlo è la scelta giusta: chi ha appena ritagliato vuole lavorare sul ritaglio, e
    /// dover andare a sceglierlo dopo averlo creato sarebbe un passo in più ogni volta. Il
    /// genitore resta comunque nell'elenco, che è tutto il punto.
    ///
    /// - Returns: `nil` se il genitore indicato non esiste. Un derivato senza genitore
    ///   spezzerebbe la catena di provenienza, e un elenco con una catena rotta è peggio di uno
    ///   senza catena: sembra affidabile e non lo è.
    @discardableResult
    public mutating func addDerived(
        _ volume: Volume, named name: String, from parentID: UUID, operation: String
    ) -> UUID? {
        guard entries.contains(where: { $0.id == parentID }) else { return nil }
        let entry = VolumeEntry(
            name: uniqueName(cleaned(name, fallback: operation)),
            provenance: .derived(from: parentID, operation: operation),
            volume: volume)
        // Subito dopo il genitore e non in fondo: così l'elenco resta leggibile come un albero
        // anche quando è piatto, e un ritaglio del ritaglio sta sotto il ritaglio da cui viene.
        let insertion = lastIndexOfSubtree(rootedAt: parentID).map { $0 + 1 } ?? entries.count
        entries.insert(entry, at: insertion)
        selectedID = entry.id
        return entry.id
    }

    // MARK: Selezionare e togliere

    @discardableResult
    public mutating func select(_ id: UUID) -> Bool {
        guard entries.contains(where: { $0.id == id }) else { return false }
        selectedID = id
        return true
    }

    /// Toglie un volume derivato, e con esso tutto ciò che ne discende.
    ///
    /// I discendenti se ne vanno insieme perché senza il genitore sarebbero orfani, e un derivato
    /// orfano non si può più spiegare: resterebbe nell'elenco un volume di cui nessuno sa dire da
    /// dove viene.
    ///
    /// - Returns: `false` se l'identificatore non esiste o se è un volume di partenza. Quelli non
    ///   si tolgono: sono l'unica copia dei dati letti, e ricrearli richiede di riaprire lo studio.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let entry = self[id], let parentID = entry.provenance.parentID else { return false }

        var doomed: Set<UUID> = [id]
        // Un passaggio ripetuto finché nulla cambia: la catena è cortissima — un ritaglio di un
        // ritaglio è già raro — e un attraversamento esplicito non varrebbe le righe che costa.
        var changed = true
        while changed {
            changed = false
            for candidate in entries {
                guard let parent = candidate.provenance.parentID,
                    doomed.contains(parent), !doomed.contains(candidate.id)
                else { continue }
                doomed.insert(candidate.id)
                changed = true
            }
        }

        entries.removeAll { doomed.contains($0.id) }

        // Se si è tolto il volume selezionato si torna **al genitore**, non al primo dell'elenco:
        // è da lì che si era arrivati, ed è lì che si vuole tornare.
        if let selectedID, doomed.contains(selectedID) {
            self.selectedID = entries.contains(where: { $0.id == parentID }) ? parentID : entries.first?.id
        }
        return true
    }

    // MARK: Catena di provenienza

    /// Dal volume indicato risalendo fino a quello di partenza, incluso.
    public func ancestry(of id: UUID) -> [VolumeEntry] {
        var chain: [VolumeEntry] = []
        var seen: Set<UUID> = []
        var current: UUID? = id
        while let step = current, let entry = self[step], !seen.contains(step) {
            seen.insert(step)
            chain.append(entry)
            current = entry.provenance.parentID
        }
        return chain
    }

    /// Il volume di partenza da cui discende quello indicato.
    public func root(of id: UUID) -> VolumeEntry? {
        ancestry(of: id).last
    }

    /// Provenienza del volume di partenza dello studio in uso.
    ///
    /// È ciò che decide se i numeri che si stanno leggendo vengono da un paziente o dal fantoccio,
    /// e va letta da qui e non dal nome: il nome si può cambiare, e un fantoccio rinominato che
    /// passa per uno studio vero sarebbe il malinteso peggiore possibile su questi valori.
    public var selectedRootProvenance: VolumeProvenance? {
        guard let selectedID else { return nil }
        return root(of: selectedID)?.provenance
    }

    /// Quanto è annidato un volume, per rientrarlo nella barra laterale.
    public func depth(of id: UUID) -> Int {
        max(ancestry(of: id).count - 1, 0)
    }

    /// Descrizione della catena: «Studio → Ritaglio → Ricampionamento 150 µm».
    public func provenanceDescription(of id: UUID) -> String {
        ancestry(of: id).reversed().map(\.name).joined(separator: " → ")
    }

    // MARK: Nomi

    /// Un nome che non collide con quelli già presenti.
    ///
    /// Due volumi con lo stesso nome nell'elenco sono peggio di un nome brutto: si sceglie a caso
    /// quale dei due si sta guardando.
    public func uniqueName(_ base: String) -> String {
        let taken = Set(entries.map(\.name))
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    public mutating func rename(_ id: UUID, to name: String) {
        guard let position = entries.firstIndex(where: { $0.id == id }) else { return }
        let cleanedName = cleaned(name, fallback: entries[position].name)
        guard cleanedName != entries[position].name else { return }
        entries[position].name = uniqueName(cleanedName)
    }

    // MARK: Dettagli

    private func cleaned(_ name: String, fallback: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// Ultima posizione occupata dal sottoalbero di un volume, per inserirci sotto un figlio.
    private func lastIndexOfSubtree(rootedAt id: UUID) -> Int? {
        guard let start = entries.firstIndex(where: { $0.id == id }) else { return nil }
        var last = start
        var family: Set<UUID> = [id]
        for index in (start + 1)..<entries.count {
            guard let parent = entries[index].provenance.parentID, family.contains(parent) else {
                continue
            }
            family.insert(entries[index].id)
            last = index
        }
        return last
    }
}
