import Foundation

/// Che cosa è un oggetto del piano. Determina l'icona e il pannello contestuale.
public enum PlanObjectKind: String, Hashable, Sendable, Codable, CaseIterable {
    case implant
    case prostheticTooth
    case nerveCanal
    case archCurve
    case annotation
    case mesh
    case guideDesign
}

/// Attributi comuni a ogni oggetto del piano, indipendenti dal suo contenuto.
///
/// Deliberatamente non contiene la geometria: quella resta nei tipi specifici. In questo modo
/// MeasureKit non deve dipendere da tutti i moduli che definiscono gli oggetti del piano.
public struct PlanObjectInfo: Hashable, Sendable, Codable, Identifiable {
    public let id: UUID
    public var kind: PlanObjectKind
    public var name: String
    public var isVisible: Bool
    public var isLocked: Bool
    /// Colore in esadecimale `RRGGBB`, senza cancelletto.
    public var colorHex: String
    /// Nota libera dell'utente.
    public var note: String
    /// Posizione nell'elenco, dentro il proprio tipo.
    public var order: Int

    public init(id: UUID, kind: PlanObjectKind, name: String, order: Int) {
        self.id = id
        self.kind = kind
        self.name = name
        self.isVisible = true
        self.isLocked = false
        self.colorHex = "32B8C6"
        self.note = ""
        self.order = order
    }
}

/// Registro degli oggetti del piano.
public struct PlanObjectRegistry: Hashable, Sendable, Codable {
    public private(set) var objects: [PlanObjectInfo]

    // La tavolozza è fissa perché un piano riaperto deve proporre gli stessi colori. Dodici
    // colori permettono di distinguere gli oggetti vicini nei casi clinici comuni senza usare
    // casualità, che renderebbe il colore instabile fra una sessione e l'altra.
    private static let colorPalette: [String] = [
        "32B8C6", "E15759", "F28E2B", "59A14F", "B07AA1", "EDC948",
        "4E79A7", "FF9DA7", "76B7B2", "9C755F", "AF7AA1", "BAB0AC",
    ]

    public init() {
        self.objects = []
    }

    /// Inserisce un oggetto oppure sostituisce quello che ha lo stesso identificatore.
    public mutating func register(_ info: PlanObjectInfo) {
        var existingIndex: Int?
        var index = 0
        while index < objects.count {
            if objects[index].id == info.id {
                existingIndex = index
                break
            }
            index += 1
        }

        if let existingIndex {
            let previousKind = objects[existingIndex].kind
            objects[existingIndex] = info
            normalizeOrders(for: previousKind)
            if previousKind != info.kind {
                normalizeOrders(for: info.kind)
            }
        } else {
            objects.append(info)
            normalizeOrders(for: info.kind)
        }
    }

    public mutating func remove(id: UUID) {
        var index = 0
        while index < objects.count {
            if objects[index].id == id {
                let kind = objects[index].kind
                objects.remove(at: index)
                normalizeOrders(for: kind)
                return
            }
            index += 1
        }
    }

    public mutating func removeAll(of kind: PlanObjectKind) {
        var index = objects.count
        while index > 0 {
            index -= 1
            if objects[index].kind == kind {
                objects.remove(at: index)
            }
        }
    }

    public subscript(id: UUID) -> PlanObjectInfo? {
        get {
            var index = 0
            while index < objects.count {
                if objects[index].id == id {
                    return objects[index]
                }
                index += 1
            }
            return nil
        }
        set {
            guard let newValue else {
                remove(id: id)
                return
            }
            // L'identificatore della chiave deve restare autorevole. Accettare un valore con
            // un altro UUID renderebbe possibile cercare lo stesso record sotto due identità.
            guard newValue.id == id else { return }
            register(newValue)
        }
    }

    public func objects(of kind: PlanObjectKind) -> [PlanObjectInfo] {
        var result: [PlanObjectInfo] = []
        for object in objects {
            guard object.kind == kind else { continue }

            // Inserimento stabile: a parità di ordine conserva la sequenza del file. Questo
            // evita che UUID casuali facciano cambiare disposizione dopo una riapertura.
            var insertionIndex = result.count
            while insertionIndex > 0 {
                let previous = result[insertionIndex - 1]
                if previous.order <= object.order { break }
                insertionIndex -= 1
            }
            result.insert(object, at: insertionIndex)
        }
        return result
    }

    public func isVisible(_ id: UUID) -> Bool {
        // Durante il caricamento il disegno può precedere la registrazione. Il valore prudente
        // è visibile: nascondere un UUID ancora sconosciuto farebbe sparire dati senza spiegazione.
        guard let object = self[id] else { return true }
        return object.isVisible
    }

    public mutating func setVisible(_ visible: Bool, id: UUID) {
        guard let index = index(of: id) else { return }
        objects[index].isVisible = visible
    }

    public mutating func setLocked(_ locked: Bool, id: UUID) {
        guard let index = index(of: id) else { return }
        objects[index].isLocked = locked
    }

    public mutating func rename(_ name: String, id: UUID) {
        guard let index = index(of: id) else { return }
        objects[index].name = name
    }

    public mutating func move(id: UUID, toOrder: Int) {
        guard let objectIndex = index(of: id) else { return }
        let kind = objects[objectIndex].kind
        var ordered = objects(of: kind)

        var currentIndex: Int?
        var index = 0
        while index < ordered.count {
            if ordered[index].id == id {
                currentIndex = index
                break
            }
            index += 1
        }
        guard let currentIndex else { return }

        let moved = ordered.remove(at: currentIndex)
        let destination = max(0, min(toOrder, ordered.count))
        ordered.insert(moved, at: destination)

        var order = 0
        while order < ordered.count {
            if let storedIndex = self.index(of: ordered[order].id) {
                objects[storedIndex].order = order
            }
            order += 1
        }
    }

    /// Nome proposto per un oggetto nuovo, senza riutilizzare un numero ancora presente.
    public func suggestedName(for kind: PlanObjectKind) -> String {
        let prefix = namePrefix(for: kind)
        let numberedPrefix = prefix + " "
        var highestNumber = 0

        for object in objects {
            guard object.kind == kind, object.name.hasPrefix(numberedPrefix) else { continue }
            let suffix = object.name.dropFirst(numberedPrefix.count)
            guard let number = Int(suffix), number > highestNumber else { continue }
            highestNumber = number
        }

        if highestNumber < Int.max {
            return "\(prefix) \(highestNumber + 1)"
        }

        // Un nome importato può contenere Int.max. In quel caso si usa una forma testuale
        // deterministica invece di sommare uno e provocare overflow.
        var candidate = prefix + " nuovo"
        var suffix = 2
        while containsName(candidate, kind: kind) {
            candidate = "\(prefix) nuovo \(suffix)"
            if suffix == Int.max { return prefix + " senza numero" }
            suffix += 1
        }
        return candidate
    }

    /// Colore proposto da una tavolozza fissa, saltando quelli in uso nello stesso tipo.
    public func suggestedColorHex(for kind: PlanObjectKind) -> String {
        var used: Set<String> = []
        var countForKind = 0
        for object in objects {
            guard object.kind == kind else { continue }
            used.insert(normalizedColor(object.colorHex))
            countForKind += 1
        }

        for color in Self.colorPalette {
            if !used.contains(color) {
                return color
            }
        }

        // Dopo l'esaurimento una ripetizione è inevitabile. La posizione nel ciclo dipende
        // soltanto dallo stato salvato, quindi resta stabile fra due chiamate e due riaperture.
        var paletteIndex = countForKind % Self.colorPalette.count
        let ordered = objects(of: kind)
        if let last = ordered.last {
            let lastColor = normalizedColor(last.colorHex)
            if Self.colorPalette[paletteIndex] == lastColor, Self.colorPalette.count > 1 {
                paletteIndex = (paletteIndex + 1) % Self.colorPalette.count
            }
        }
        return Self.colorPalette[paletteIndex]
    }

    private func index(of id: UUID) -> Int? {
        var index = 0
        while index < objects.count {
            if objects[index].id == id { return index }
            index += 1
        }
        return nil
    }

    private mutating func normalizeOrders(for kind: PlanObjectKind) {
        let ordered = objects(of: kind)
        var order = 0
        while order < ordered.count {
            if let storedIndex = index(of: ordered[order].id) {
                objects[storedIndex].order = order
            }
            order += 1
        }
    }

    private func namePrefix(for kind: PlanObjectKind) -> String {
        switch kind {
        case .implant: return "Impianto"
        case .prostheticTooth: return "Dente"
        case .nerveCanal: return "Canale nervoso"
        case .archCurve: return "Curva d'arcata"
        case .annotation: return "Annotazione"
        case .mesh: return "Mesh"
        case .guideDesign: return "Dima chirurgica"
        }
    }

    private func containsName(_ name: String, kind: PlanObjectKind) -> Bool {
        for object in objects {
            if object.kind == kind, object.name == name { return true }
        }
        return false
    }

    private func normalizedColor(_ color: String) -> String {
        if color.hasPrefix("#") {
            return String(color.dropFirst()).uppercased()
        }
        return color.uppercased()
    }
}
