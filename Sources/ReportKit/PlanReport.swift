import DICOMCore
import Foundation
import ImplantKit
import MeasureKit

// La relazione del piano.
//
// # Perché genera HTML e non un PDF
//
// Perché l'HTML è **testo**, e il testo si verifica con `swift test`: che un numero ci sia, che
// un avvertimento non sparisca, che un commento dell'utente non diventi marcatura. Un generatore
// di PDF si può solo guardare, e guardarlo non è verificarlo. Il PDF si ottiene poi stampando,
// che è un passaggio del sistema e non del programma.
//
// # Che cosa la relazione deve dire, e che nessuno mette
//
// Un elenco di misure non è una relazione. Serve che ogni numero porti con sé **come è stato
// ottenuto**: su quale volume — l'acquisito o un suo derivato — con che incertezza, e con quali
// avvertimenti. È il Contratto 5 applicato al documento che esce, ed è precisamente il punto in
// cui un numero smette di essere verificabile: da lì in poi viaggia da solo.
//
// E deve dire di non essere diagnostica. Non come una riga in fondo che nessuno legge: in cima,
// dove si guarda per primo.

public struct PlanReportInput: Sendable {

    public var studyName: String
    public var patientReference: String
    /// La catena di come il volume è stato prodotto, dall'acquisito in poi.
    public var volumeProvenance: [String]
    public var densityUnitSymbol: String
    public var annotations: [Annotation]
    public var roiStatistics: [UUID: ROIStatistics]
    public var implants: [ImplantPlacement]
    public var safetyReports: [UUID: SafetyReport]
    /// Le immagini dei riquadri, già codificate in PNG.
    ///
    /// # Perché i byte e non degli URL
    ///
    /// Perché una relazione che rimanda a dei file accanto a sé smette di essere una relazione
    /// appena qualcuno la sposta o la manda per posta — e mandarla è precisamente ciò per cui
    /// esiste. Le immagini entrano nel documento come `data:` URI: il file cresce, ed è un file
    /// solo che si apre ovunque e si stampa in PDF dal browser senza portarsi dietro niente.
    public var images: [ReportImage]
    /// Vincolo protesico per impianto, quando sotto c'è un dente da servire.
    public var prostheticConstraints: [UUID: ProstheticConstraint]
    /// Quanti denti protesici sono stati posati. Serve a distinguere «nessun vincolo perché
    /// l'impianto sta lontano da ogni corona» da «nessun vincolo perché non c'è nessuna
    /// corona» — che è la differenza fra una verifica superata e una verifica non fatta.
    public var prostheticToothCount: Int
    /// Scarto della registrazione della scansione, se è stata fatta.
    public var registrationRMSMM: Double?
    public var registrationQuality: String?
    /// Verifiche della dima, se è stata costruita.
    public var guideVolumeMM3: Double?
    public var guideIsPrintable: Bool?
    public var guideWarnings: [String]
    /// L'analisi cefalometrica, già formattata. Vuota quando non ne è stata fatta nessuna.
    public var cephalometry: [ReportCephRow]
    public var generatedAt: Date

    public init(
        studyName: String,
        patientReference: String = "",
        volumeProvenance: [String] = [],
        densityUnitSymbol: String = "GV",
        annotations: [Annotation] = [],
        roiStatistics: [UUID: ROIStatistics] = [:],
        implants: [ImplantPlacement] = [],
        safetyReports: [UUID: SafetyReport] = [:],
        images: [ReportImage] = [],
        prostheticConstraints: [UUID: ProstheticConstraint] = [:],
        prostheticToothCount: Int = 0,
        registrationRMSMM: Double? = nil,
        registrationQuality: String? = nil,
        guideVolumeMM3: Double? = nil,
        guideIsPrintable: Bool? = nil,
        guideWarnings: [String] = [],
        cephalometry: [ReportCephRow] = [],
        generatedAt: Date = Date()
    ) {
        self.studyName = studyName
        self.patientReference = patientReference
        self.volumeProvenance = volumeProvenance
        self.densityUnitSymbol = densityUnitSymbol
        self.annotations = annotations
        self.roiStatistics = roiStatistics
        self.implants = implants
        self.safetyReports = safetyReports
        self.images = images
        self.prostheticConstraints = prostheticConstraints
        self.prostheticToothCount = prostheticToothCount
        self.registrationRMSMM = registrationRMSMM
        self.registrationQuality = registrationQuality
        self.guideVolumeMM3 = guideVolumeMM3
        self.guideIsPrintable = guideIsPrintable
        self.guideWarnings = guideWarnings
        self.cephalometry = cephalometry
        self.generatedAt = generatedAt
    }
}

/// Una riga dell'analisi cefalometrica nella relazione.
///
/// Testo già formattato, e non i tipi di `CephKit`: la relazione non calcola nulla, impagina. Con
/// i tipi veri `ReportKit` dipenderebbe da `CephKit` per usarne tre stringhe, e ogni modulo che
/// aggiunge una sezione alla relazione ne aggiungerebbe una dipendenza.
public struct ReportCephRow: Hashable, Sendable {
    public var group: String
    public var name: String
    public var value: String
    public var reference: String
    /// Vero quando il valore cade fuori dall'intervallo: la relazione lo segnala, non lo giudica.
    public var isOutOfRange: Bool

    public init(
        group: String, name: String, value: String, reference: String, isOutOfRange: Bool
    ) {
        self.group = group
        self.name = name
        self.value = value
        self.reference = reference
        self.isOutOfRange = isOutOfRange
    }
}

/// Un'immagine da mettere nella relazione.
public struct ReportImage: Hashable, Sendable {
    /// Che cosa mostra: «Assiale», «Sezione 46», «Panorex».
    public var title: String
    /// Dove sta il mirino quando l'immagine è stata presa, o un'altra riga di contesto.
    public var caption: String
    /// I byte del PNG.
    public var pngData: Data

    public init(title: String, caption: String = "", pngData: Data) {
        self.title = title
        self.caption = caption
        self.pngData = pngData
    }
}

public enum PlanReport {

    /// L'avvertenza, testuale e riusabile: compare in cima al documento e nei metadati.
    public static let disclaimer =
        "Documento prodotto da software non certificato come dispositivo medico. "
        + "Non utilizzabile per diagnosi. I valori di densità delle CBCT sono valori grigi (GV) "
        + "e non unità Hounsfield: non sono confrontabili con soglie di letteratura né fra "
        + "apparecchi diversi."

    public static func html(_ input: PlanReportInput) -> String {
        var body = ""
        body += header(input)
        body += reviewSection(input)
        body += provenanceSection(input)
        body += imagesSection(input)
        body += measurementsSection(input)
        body += cephalometrySection(input)
        body += implantsSection(input)
        body += workflowSection(input)
        return document(title: "Piano — \(input.studyName)", body: body)
    }

    // MARK: Sezioni

    private static func header(_ input: PlanReportInput) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMMM yyyy, HH:mm"
        formatter.locale = Locale(identifier: "it_IT")

        return """
            <div class="warning"><strong>Uso non diagnostico.</strong> \(escape(disclaimer))</div>
            <h1>\(escape(input.studyName))</h1>
            <p class="meta">
              \(input.patientReference.isEmpty ? "" : escape(input.patientReference) + " · ")
              generato il \(escape(formatter.string(from: input.generatedAt)))
            </p>
            """
    }

    /// Ciò che non torna, **prima** di tutto il resto.
    ///
    /// In cima e non in fondo: una relazione che elenca prima i numeri e poi i problemi si legge
    /// nell'ordine sbagliato, e chi la stampa per firmarla vede i numeri.
    private static func reviewSection(_ input: PlanReportInput) -> String {
        let issues = PlanReview.issues(in: input)
        guard !issues.isEmpty else { return "" }

        let rows = issues.map { issue in
            """
            <li class="\(issue.severity == .blocking ? "danger" : issue.severity == .warning ? "caution" : "")">
              <strong>\(escape(issue.title))</strong><br>
              <span class="note">\(escape(issue.detail))</span>
            </li>
            """
        }.joined()

        let blocking = issues.filter { $0.severity == .blocking }.count
        let heading = blocking > 0
            ? "Da risolvere (\(blocking) bloccanti)"
            : "Da guardare"
        return "<h2>\(escape(heading))</h2><ul class=\"issues\">\(rows)</ul>"
    }

    private static func provenanceSection(_ input: PlanReportInput) -> String {
        guard !input.volumeProvenance.isEmpty else { return "" }
        // La catena per intero, e non solo il nome del volume: una misura presa su un volume con
        // le strie ridotte non è una misura sul dato acquisito, e chi legge la relazione un mese
        // dopo non ha altro modo di saperlo.
        let steps = input.volumeProvenance
            .map { "<li>\(escape($0))</li>" }
            .joined()
        return "<h2>Volume</h2><ol class=\"chain\">\(steps)</ol>"
    }

    private static func measurementsSection(_ input: PlanReportInput) -> String {
        guard !input.annotations.isEmpty else {
            return "<h2>Misure</h2><p class=\"empty\">Nessuna misura nel piano.</p>"
        }

        var rows = ""
        for annotation in input.annotations {
            let statistics = input.roiStatistics[annotation.id]
            let value = statistics.map {
                MeasurementFormatter.densityWithDeviation(
                    mean: $0.mean, standardDeviation: $0.standardDeviation,
                    unit: $0.unit)
            } ?? annotation.formattedValue

            rows += """
                <tr>
                  <td>\(escape(annotation.kindName))</td>
                  <td>\(escape(annotation.metadata.label))</td>
                  <td class="num">\(escape(value))</td>
                  <td class="note">\(caveatText(annotation))</td>
                </tr>
                """
        }

        return """
            <h2>Misure</h2>
            <table>
              <thead><tr><th>Tipo</th><th>Etichetta</th><th>Valore</th><th>Come è stata presa</th></tr></thead>
              <tbody>\(rows)</tbody>
            </table>
            """
    }

    /// L'analisi cefalometrica.
    ///
    /// Assente del tutto quando non se n'è fatta nessuna, invece di una tabella vuota: una
    /// sezione vuota in un documento suggerisce che qualcosa sia andato perso.
    private static func cephalometrySection(_ input: PlanReportInput) -> String {
        guard !input.cephalometry.isEmpty else { return "" }

        var rows = ""
        var lastGroup: String?
        for row in input.cephalometry {
            if row.group != lastGroup {
                rows += "<tr><th colspan=\"4\">\(escape(row.group))</th></tr>"
                lastGroup = row.group
            }
            // `caution` esiste già nel foglio di stile: una classe nuova per lo stesso
            // significato sarebbe una seconda definizione dello stesso giallo.
            let cellClass = row.isOutOfRange ? "num caution" : "num"
            rows += """
                <tr>
                  <td>\(escape(row.name))</td>
                  <td class="\(cellClass)">\(escape(row.value))</td>
                  <td class="note">\(escape(row.reference))</td>
                  <td class="note">\(row.isOutOfRange ? "fuori intervallo" : "")</td>
                </tr>
                """
        }

        return """
            <h2>Cefalometria</h2>
            <p class="note">Gli angoli sono calcolati sulla proiezione dei reperi sul piano
            sagittale mediano. Gli intervalli di riferimento vengono dalle analisi classiche su
            popolazioni adulte: non si applicano a un paziente in crescita, e un valore fuori
            intervallo non è una diagnosi.</p>
            <table>
              <thead><tr><th>Misura</th><th>Valore</th><th>Riferimento</th><th></th></tr></thead>
              <tbody>\(rows)</tbody>
            </table>
            """
    }

    /// Gli avvertimenti di una misura, o la sua incertezza se non ne ha.
    private static func caveatText(_ annotation: Annotation) -> String {
        guard let context = annotation.metadata.acquisition else {
            // Nessun contesto significa un piano salvato prima che esistesse. Dirlo è meglio che
            // tacere: chi legge deve sapere che quel numero non porta la propria incertezza.
            return "<em>contesto di acquisizione non registrato</em>"
        }
        let quality = MeasurementUncertainty.quality(ofLengthMM: 0, context: context)
        let uncertainty = MeasurementUncertainty.roundedUncertaintyMM(
            quality.standardUncertaintyMM)
        var parts = [
            String(format: "± %.2f mm", uncertainty).replacingOccurrences(of: ".", with: ",")
        ]
        parts += quality.caveats.map { escape($0.localizedDescription) }
        return parts.joined(separator: "<br>")
    }

    private static func implantsSection(_ input: PlanReportInput) -> String {
        guard !input.implants.isEmpty else { return "" }

        var rows = ""
        for implant in input.implants {
            let report = input.safetyReports[implant.id]
            let findings = report?.findings
                .map { "\(escape($0.structureName)) \(escape($0.formattedDistance))" }
                .joined(separator: "<br>") ?? "—"
            let density = report?.density?.overall.summary ?? "—"
            let angulation = implant.angleDegrees(to: Vec3(0, 0, 1))
                .map { String(format: "%.0f°", $0) } ?? "—"

            let constraint = input.prostheticConstraints[implant.id]
            // La cella vuota e la cella «non verificato» dicono cose diverse, e un trattino
            // solo le confonderebbe: la prima è un impianto lontano da ogni corona, la seconda
            // è un piano in cui la protesi non è stata considerata affatto.
            let prosthetic = constraint.map { escape($0.summary) }
                ?? (input.prostheticToothCount == 0
                    ? "<em>non verificato</em>" : "nessun dente sopra")

            rows += """
                <tr>
                  <td>\(escape(implant.label))</td>
                  <td>\(escape(implant.model.displayName))</td>
                  <td class="num">\(escape(angulation))</td>
                  <td class="\(levelClass(report?.worstLevel))">\(findings)</td>
                  <td class="num">\(escape(density))</td>
                  <td class="\(constraintClass(constraint?.severity))">\(prosthetic)</td>
                </tr>
                """
        }

        let prostheticNote = input.prostheticToothCount == 0
            ? """
                <p class="note">
                  <strong>Nessun dente protesico è stato posato.</strong> La colonna della
                  verifica protesica è vuota perché il controllo non è stato eseguito, non
                  perché sia stato superato.
                </p>
                """
            : """
                <p class="note">
                  La verifica protesica confronta l'asse dell'impianto con quello del dente che
                  deve sostenere. Le sagome dei denti hanno misure medie di popolazione, non di
                  questo paziente: dicono l'ingombro e la direzione, non la forma della corona
                  che verrà costruita.
                </p>
                """

        return """
            <h2>Impianti</h2>
            <table>
              <thead><tr><th>Sito</th><th>Modello</th><th>Inclinazione</th><th>Prossimità</th><th>Densità attorno</th><th>Verifica protesica</th></tr></thead>
              <tbody>\(rows)</tbody>
            </table>
            <p class="note">
              Le distanze sono fra le <strong>superfici</strong>: quella dell'impianto e quella
              della struttura tracciata. Il canale è tracciato a mano, quindi la sua posizione
              porta l'incertezza di chi l'ha tracciato, che è la voce dominante e non compare in
              questi numeri.
            </p>
            \(prostheticNote)
            """
    }

    private static func constraintClass(_ severity: ConstraintSeverity?) -> String {
        switch severity {
        case .unacceptable: return "danger"
        case .caution: return "caution"
        case .acceptable, nil: return ""
        }
    }

    /// Le immagini, in una griglia.
    ///
    /// Dopo la provenienza e prima delle misure: si guarda l'immagine e poi si legge il numero,
    /// che è l'ordine in cui si legge un referto. Un'immagine senza dicitura non dice dove sta,
    /// quindi ognuna porta la propria.
    private static func imagesSection(_ input: PlanReportInput) -> String {
        let usable = input.images.filter { !$0.pngData.isEmpty }
        guard !usable.isEmpty else { return "" }

        var figures = ""
        for image in usable {
            let encoded = image.pngData.base64EncodedString()
            let caption = image.caption.isEmpty
                ? "" : "<figcaption>\(escape(image.caption))</figcaption>"
            figures += """
                <figure>
                  <img src="data:image/png;base64,\(encoded)" alt="\(escape(image.title))">
                  <figcaption><strong>\(escape(image.title))</strong></figcaption>
                  \(caption)
                </figure>
                """
        }

        return """
            <h2>Immagini</h2>
            <div class="figures">\(figures)</div>
            <p class="note">
              Immagini ricostruite dal volume con la finestra di densità in uso al momento
              dell'esportazione. Non sono le proiezioni acquisite: una misura presa su carta da
              queste immagini non ha la scala di quelle, e va fatta nel programma.
            </p>
            """
    }

    private static func workflowSection(_ input: PlanReportInput) -> String {
        var items: [String] = []

        if let rms = input.registrationRMSMM {
            let quality = input.registrationQuality.map { " (\(escape($0)))" } ?? ""
            items.append(
                String(format: "Scansione registrata con scarto %.2f mm", rms)
                    .replacingOccurrences(of: ".", with: ",") + quality)
        }
        if let volume = input.guideVolumeMM3 {
            let printable = input.guideIsPrintable == true
                ? "verifiche superate" : "<strong>verifiche non superate</strong>"
            items.append(
                String(format: "Dima costruita, %.1f cm³ — ", volume / 1000)
                    .replacingOccurrences(of: ".", with: ",") + printable)
        }
        items += input.guideWarnings.map { escape($0) }

        guard !items.isEmpty else { return "" }
        let list = items.map { "<li>\($0)</li>" }.joined()
        return "<h2>Lavorazione</h2><ul>\(list)</ul>"
    }

    private static func levelClass(_ level: SafetyLevel?) -> String {
        switch level {
        case .danger: return "danger"
        case .caution: return "caution"
        default: return ""
        }
    }

    // MARK: Impaginazione

    /// Sostituisce i caratteri che in HTML sono marcatura.
    ///
    /// Non è prudenza teorica: le etichette e i commenti li scrive l'utente, e un commento che
    /// contiene `<` spezzerebbe il documento a metà — la relazione finirebbe lì, senza che nulla
    /// lo segnali.
    ///
    /// Carattere per carattere, e **non** con una catena di `replacingOccurrences`. Quella
    /// catena ha un difetto classico: sostituendo `<` prima di `&`, la `&amp;` appena prodotta
    /// viene ri-sostituita e diventa `&amp;amp;`, che a schermo si legge come testo invece che
    /// come simbolo. Scorrendo i caratteri il problema non esiste, perché ciascuno si tratta una
    /// volta sola — è la ragione della forma, e vale la pena scriverla perché la forma comoda è
    /// l'altra.
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    private static func document(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="it">
        <head>
        <meta charset="utf-8">
        <title>\(escape(title))</title>
        <style>
        body { font: 14px -apple-system, system-ui, sans-serif; color: #1a1a1a;
               max-width: 900px; margin: 40px auto; padding: 0 24px; line-height: 1.55; }
        h1 { font-size: 24px; margin: 0 0 4px; }
        h2 { font-size: 16px; margin: 32px 0 10px; padding-bottom: 5px;
             border-bottom: 1px solid #ddd; }
        .warning { background: #fff4e5; border-left: 3px solid #d97706; padding: 12px 16px;
                   margin-bottom: 28px; font-size: 13px; }
        .meta, .note, .empty { color: #666; font-size: 12.5px; }
        table { width: 100%; border-collapse: collapse; margin-top: 8px; font-size: 13px; }
        th { text-align: left; font-weight: 600; font-size: 11px; text-transform: uppercase;
             letter-spacing: 0.05em; color: #666; border-bottom: 1px solid #ccc;
             padding: 0 12px 6px 0; }
        td { padding: 8px 12px 8px 0; border-bottom: 1px solid #eee; vertical-align: top; }
        td.num { font-variant-numeric: tabular-nums; white-space: nowrap; }
        td.caution { color: #b45309; }
        td.danger { color: #b91c1c; font-weight: 600; }
        ol.chain li { color: #444; }
        ul.issues { padding-left: 20px; }
        ul.issues li { margin-bottom: 10px; }
        ul.issues li.danger::marker { color: #b91c1c; }
        ul.issues li.caution::marker { color: #b45309; }
        .figures { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr));
                   gap: 16px; margin-top: 12px; }
        figure { margin: 0; }
        figure img { width: 100%; height: auto; display: block; background: #000;
                     border: 1px solid #ddd; }
        figcaption { font-size: 12px; color: #666; margin-top: 4px; }
        figcaption strong { color: #1a1a1a; }
        /* In stampa una figura non deve spezzarsi fra due pagine: mezza immagine in fondo a un
           foglio e mezza in cima al successivo non si legge, e questa relazione si stampa. */
        @media print {
            body { margin: 0; }
            .warning { border-color: #000; }
            figure { break-inside: avoid; page-break-inside: avoid; }
            .figures { grid-template-columns: repeat(2, 1fr); }
        }
        </style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }
}
