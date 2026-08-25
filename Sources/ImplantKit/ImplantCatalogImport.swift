import Foundation

// Portare dentro un catalogo di impianti vero.
//
// # Perché un formato di testo e non la libreria di un altro programma
//
// Perché di un impianto, a questo programma, servono **le misure** e nient'altro. `ImplantModel`
// costruisce il profilo da diametro, lunghezza e diametro all'apice: non consuma un CAD, non ha
// dove metterlo, e la sagoma che disegna e con cui misura le distanze dal canale è quella
// parametrica. Le misure sono pubblicate dai produttori nei loro cataloghi — sono il numero che
// si legge sulla scatola — mentre la geometria dentro la libreria di un altro programma è cosa
// sua, e ricopiarla darebbe in cambio niente che non ci sia già.
//
// Da qui la scelta: un formato di testo che chiunque può scrivere, da un catalogo cartaceo, da
// un foglio di calcolo, o esportandolo da dove si vuole. Chi ha una libreria in un formato
// diverso la converte una volta, e da lì in poi il file è suo.
//
// # Che cosa si rifiuta, e perché rumorosamente
//
// Una riga che non si capisce **non si salta in silenzio**. Un catalogo importato a metà è la
// cosa peggiore che possa uscire da qui: si sceglie un impianto dal menu, si pianifica, si
// ordina — e la misura che manca è quella che serviva. Chi importa deve sapere esattamente
// quante righe sono entrate e quali no.
public enum ImplantCatalogImport: Sendable {

    /// Che cosa è andato storto in una riga.
    public struct Problem: Hashable, Sendable {
        /// Numero di riga nel file, contando dalla prima.
        public let line: Int
        public let reason: String
        public let text: String
    }

    public struct Result: Sendable {
        public let models: [ImplantModel]
        public let problems: [Problem]
    }

    public enum ImportError: Error, Hashable, Sendable, LocalizedError {
        case missingHeader
        case missingColumns([String])
        case noRows

        public var errorDescription: String? {
            switch self {
            case .missingHeader:
                return "Il file è vuoto: manca anche la riga d'intestazione."
            case .missingColumns(let names):
                return "Nell'intestazione mancano le colonne: \(names.joined(separator: ", "))."
            case .noRows:
                return "L'intestazione c'è ma sotto non c'è nessun impianto."
            }
        }
    }

    /// Le colonne obbligatorie. I nomi si confrontano senza distinguere maiuscole e accenti.
    public static let requiredColumns = ["produttore", "linea", "diametro", "lunghezza"]
    /// Le colonne facoltative, che se mancano si ricavano.
    public static let optionalColumns = ["piattaforma", "apice"]

    /// Un modello di file, da dare a chi deve prepararne uno.
    public static let templateCSV = """
        produttore,linea,diametro,lunghezza,piattaforma,apice
        Esempio,Conico,3.75,10,3.75,2.4
        Esempio,Conico,4.2,11.5,4.2,2.8
        """

    /// Legge un catalogo da testo separato da virgole o da tabulazioni.
    ///
    /// Il separatore si riconosce dall'intestazione invece di chiederlo: un foglio di calcolo
    /// esporta l'uno o l'altro a seconda di come è configurato, e chiedere all'utente di sapere
    /// quale sia significa farglielo scoprire sbagliando.
    ///
    /// La virgola decimale si accetta come il punto: in Italia un catalogo scrive `3,75`, e
    /// rifiutarlo perché non è `3.75` sarebbe pedanteria che costa un'ora a chi importa.
    public static func read(_ text: String) throws -> Result {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // L'intestazione è la prima riga che non sia vuota **né un commento**: chi trascrive un
        // listino ci mette sopra da dove viene e quando, ed è la cosa giusta da fare — un
        // catalogo senza provenienza, fra sei mesi, non si sa più se è ancora valido. Saltare
        // solo le righe vuote prendeva quel commento per intestazione, e il file non si apriva.
        guard let headerIndex = lines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("#") })
        else {
            throw ImportError.missingHeader
        }
        let header = lines[headerIndex]
        let separator: Character = header.contains("\t") ? "\t" : ","
        let columns = header
            .split(separator: separator, omittingEmptySubsequences: false)
            .map { normalised(String($0)) }

        var index: [String: Int] = [:]
        for (position, name) in columns.enumerated() where index[name] == nil {
            index[name] = position
        }
        let missing = requiredColumns.filter { index[$0] == nil }
        guard missing.isEmpty else { throw ImportError.missingColumns(missing) }

        var models: [ImplantModel] = []
        var problems: [Problem] = []

        for offset in (headerIndex + 1)..<lines.count {
            let row = lines[offset]
            guard !row.isEmpty else { continue }
            // Una riga di commento: comoda per annotare da dove viene il catalogo.
            guard !row.hasPrefix("#") else { continue }

            let fields = row.split(separator: separator, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }

            func field(_ name: String) -> String? {
                guard let position = index[name], position < fields.count else { return nil }
                let value = fields[position]
                return value.isEmpty ? nil : value
            }

            let number = offset + 1
            guard let manufacturer = field("produttore"), let line = field("linea") else {
                problems.append(
                    Problem(line: number, reason: "produttore o linea mancante", text: row))
                continue
            }
            guard let diameter = decimal(field("diametro")) else {
                problems.append(
                    Problem(line: number, reason: "diametro non è un numero", text: row))
                continue
            }
            guard let length = decimal(field("lunghezza")) else {
                problems.append(
                    Problem(line: number, reason: "lunghezza non è un numero", text: row))
                continue
            }
            guard diameter > 0, diameter < 20, length > 0, length < 60 else {
                // I limiti non sono per pignoleria: un diametro di ottanta millimetri o una
                // lunghezza negativa vengono da una colonna scambiata o da un'unità sbagliata —
                // pollici, o micrometri — e passarli oltre significherebbe pianificare su misure
                // che non esistono.
                problems.append(
                    Problem(
                        line: number,
                        reason: "misure fuori da ogni intervallo plausibile in millimetri",
                        text: row))
                continue
            }

            models.append(
                ImplantModel(
                    manufacturer: manufacturer,
                    line: line,
                    diameterMM: diameter,
                    lengthMM: length,
                    platformDiameterMM: decimal(field("piattaforma")),
                    apexDiameterMM: decimal(field("apice"))))
        }

        guard !models.isEmpty || !problems.isEmpty else { throw ImportError.noRows }
        return Result(models: models, problems: problems)
    }

    /// Costruisce i modelli dai **nomi** dei file `.impl` di una libreria.
    ///
    /// # Perché dai nomi e non dal contenuto
    ///
    /// Perché il contenuto è geometria cifrata — la libreria di un altro programma la protegge —
    /// e a questo programma non serve: `ImplantModel` costruisce la sagoma dalle misure, non da
    /// una mesh. E le misure stanno nel nome, che è esattamente il codice stampato sulla scatola:
    /// `1010_ICE_3.75_10.impl` è codice 1010, linea ICE, diametro 3,75, lunghezza 10. Leggere il
    /// nome dà quel che serve senza aprire — né dover aprire — niente di protetto.
    ///
    /// Lo schema atteso, separato da trattini bassi: `codice_linea_diametro_lunghezza`. La linea
    /// può contenere più parole; diametro e lunghezza sono gli **ultimi due** numeri, così un
    /// nome di linea che contiene un trattino basso non li sposta.
    ///
    /// - Parameter includingLines: se non vuoto, tiene solo le linee il cui nome contiene una di
    ///   queste voci, senza distinguere maiuscole. È il modo di prendere «solo i Multi-NeO» da
    ///   una libreria che ne ha dieci.
    ///
    /// Come per la lettura da CSV, un nome che non segue lo schema **non si salta in silenzio**:
    /// torna fra i problemi col suo testo, perché un catalogo a cui manca un impianto senza
    /// dirlo è peggio di uno che si sa incompleto.
    public static func models(
        fromImplantFilenames filenames: [String],
        includingLines: [String] = []
    ) -> Result {
        let wanted = includingLines.map { normalised($0) }
        var models: [ImplantModel] = []
        var problems: [Problem] = []

        for (offset, filename) in filenames.enumerated() {
            let number = offset + 1
            let base = filename
                .split(separator: "/").last.map(String.init) ?? filename
            let stem =
                base.lowercased().hasSuffix(".impl") ? String(base.dropLast(5)) : base

            let tokens = stem.split(separator: "_").map(String.init)
            guard tokens.count >= 4 else {
                problems.append(
                    Problem(line: number, reason: "il nome non ha codice, linea, diametro, lunghezza", text: base))
                continue
            }

            guard let length = decimal(tokens[tokens.count - 1]),
                let diameter = decimal(tokens[tokens.count - 2])
            else {
                problems.append(
                    Problem(line: number, reason: "diametro o lunghezza non numerici nel nome", text: base))
                continue
            }
            guard diameter > 0, diameter < 20, length > 0, length < 60 else {
                problems.append(
                    Problem(line: number, reason: "misure fuori da ogni intervallo plausibile", text: base))
                continue
            }

            let code = tokens[0]
            let line = tokens[1..<(tokens.count - 2)].joined(separator: " ")
            guard !line.isEmpty else {
                problems.append(
                    Problem(line: number, reason: "manca il nome della linea", text: base))
                continue
            }

            if !wanted.isEmpty {
                let haystack = normalised(line)
                guard wanted.contains(where: { haystack.contains($0) }) else { continue }
            }

            models.append(
                ImplantModel(
                    manufacturer: line,
                    line: "\(code) \(line)",
                    diameterMM: diameter,
                    lengthMM: length))
        }
        return Result(models: models, problems: problems)
    }

    /// Riscrive un catalogo nello stesso formato, così un'importazione si può rileggere.
    public static func write(_ models: [ImplantModel]) -> String {
        var lines = ["produttore,linea,diametro,lunghezza,piattaforma,apice"]
        for model in models {
            lines.append(
                [
                    escaped(model.manufacturer), escaped(model.line),
                    trimmed(model.diameterMM), trimmed(model.lengthMM),
                    trimmed(model.platformDiameterMM), trimmed(model.apexDiameterMM),
                ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Dettagli

    /// Minuscole, senza spazi e senza accenti, per confrontare i nomi delle colonne.
    private static func normalised(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespaces)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .replacingOccurrences(of: " ", with: "")
    }

    /// Un numero scritto col punto o con la virgola.
    private static func decimal(_ text: String?) -> Double? {
        guard let text else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces)
        guard let value = Double(cleaned), value.isFinite else { return nil }
        return value
    }

    /// Un separatore dentro un nome romperebbe il file riletto.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func trimmed(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded == rounded.rounded()
            ? String(Int(rounded)) : String(format: "%.2f", rounded)
    }
}
