import DICOMCore
import Foundation

// Il documento `.cbctplan`.
//
// JSON, non un formato binario. Un piano deve restare leggibile fra dieci anni anche senza
// questo software: è un requisito che discende dal § 4 di docs/architecture.md, dove si
// prevede la riproducibilità deterministica di una sessione di pianificazione.
//
// Il documento **non contiene immagini**: rimanda allo studio tramite `StudyInstanceUID` e
// `SeriesInstanceUID`. Così un piano pesa qualche decina di kilobyte invece di mezzo gigabyte,
// e soprattutto non trasporta dati clinici del paziente in giro per errore.

// MARK: - Riferimento allo studio

/// Identifica la serie a cui il piano si riferisce, senza incorporarne le immagini.
public struct StudyReference: Hashable, Sendable, Codable {
    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    /// `FrameOfReferenceUID`: se presente, garantisce che le coordinate Patient di questo
    /// piano e quelle della serie appartengano allo stesso sistema di riferimento.
    public var frameOfReferenceUID: String?
    /// Identificativo paziente **già anonimizzato** al momento della scrittura.
    public var anonymizedPatientID: String?
    public var studyDate: String?
    public var seriesDescription: String?

    /// Impronta della geometria al momento del salvataggio.
    ///
    /// Serve a rilevare che il piano è stato riaperto su una serie diversa o ricostruita
    /// altrimenti: in quel caso le coordinate in mm restano formalmente valide ma potrebbero
    /// non indicare più la stessa anatomia, e l'utente va avvertito invece di lasciargli
    /// credere che tutto combaci.
    public var geometryFingerprint: GeometryFingerprint?

    public init(
        studyInstanceUID: String,
        seriesInstanceUID: String,
        frameOfReferenceUID: String? = nil,
        anonymizedPatientID: String? = nil,
        studyDate: String? = nil,
        seriesDescription: String? = nil,
        geometryFingerprint: GeometryFingerprint? = nil
    ) {
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.frameOfReferenceUID = frameOfReferenceUID
        self.anonymizedPatientID = anonymizedPatientID
        self.studyDate = studyDate
        self.seriesDescription = seriesDescription
        self.geometryFingerprint = geometryFingerprint
    }
}

/// Impronta compatta della geometria di un volume.
public struct GeometryFingerprint: Hashable, Sendable, Codable {
    public var columnCount: Int
    public var rowCount: Int
    public var sliceCount: Int
    public var spacingMM: [Double]
    public var originMM: [Double]

    public init(_ geometry: VolumeGeometry) {
        self.columnCount = geometry.columnCount
        self.rowCount = geometry.rowCount
        self.sliceCount = geometry.sliceCount
        let s = geometry.spacingMM
        self.spacingMM = [s.x, s.y, s.z]
        let o = geometry.originMM
        self.originMM = [o.x, o.y, o.z]
    }

    /// Corrispondenza entro tolleranze pratiche.
    public func matches(_ geometry: VolumeGeometry, tolerance: Double = 1e-3) -> Bool {
        guard columnCount == geometry.columnCount,
            rowCount == geometry.rowCount,
            sliceCount == geometry.sliceCount,
            spacingMM.count == 3, originMM.count == 3
        else { return false }
        let s = geometry.spacingMM
        let o = geometry.originMM
        return abs(spacingMM[0] - s.x) <= tolerance
            && abs(spacingMM[1] - s.y) <= tolerance
            && abs(spacingMM[2] - s.z) <= tolerance
            && abs(originMM[0] - o.x) <= tolerance
            && abs(originMM[1] - o.y) <= tolerance
            && abs(originMM[2] - o.z) <= tolerance
    }
}

// MARK: - Stato di visualizzazione

/// Impostazioni di vista, salvate per riaprire il caso com'era.
public struct ViewState: Hashable, Sendable, Codable {
    public var crosshairMM: [Double]
    public var windowWidth: Double
    public var windowLevel: Double
    public var slabThicknessMM: Double
    public var projectionMode: String
    public var layout: String
    /// Riorientamento applicato dall'utente (allineamento al piano occlusale), come 12
    /// coefficienti della trasformazione affine. `nil` se il volume è nell'orientamento nativo.
    public var reorientation: [Double]?

    public init(
        crosshairMM: Vec3,
        windowWidth: Double,
        windowLevel: Double,
        slabThicknessMM: Double = 0,
        projectionMode: String = "none",
        layout: String = "grid2x2",
        reorientation: Transform3D? = nil
    ) {
        self.crosshairMM = [crosshairMM.x, crosshairMM.y, crosshairMM.z]
        self.windowWidth = windowWidth
        self.windowLevel = windowLevel
        self.slabThicknessMM = slabThicknessMM
        self.projectionMode = projectionMode
        self.layout = layout
        if let t = reorientation {
            self.reorientation = [
                t.columnX.x, t.columnX.y, t.columnX.z,
                t.columnY.x, t.columnY.y, t.columnY.z,
                t.columnZ.x, t.columnZ.y, t.columnZ.z,
                t.origin.x, t.origin.y, t.origin.z,
            ]
        } else {
            self.reorientation = nil
        }
    }

    public var crosshairVec3: Vec3 {
        guard crosshairMM.count >= 3 else { return .zero }
        return Vec3(crosshairMM[0], crosshairMM[1], crosshairMM[2])
    }

    public var reorientationTransform: Transform3D? {
        guard let r = reorientation, r.count >= 12 else { return nil }
        return Transform3D(
            columnX: Vec3(r[0], r[1], r[2]),
            columnY: Vec3(r[3], r[4], r[5]),
            columnZ: Vec3(r[6], r[7], r[8]),
            origin: Vec3(r[9], r[10], r[11])
        )
    }
}

// MARK: - Registro di sessione

/// Voce del registro, in sola aggiunta.
///
/// Predisposizione per un eventuale percorso normativo (docs/architecture.md § 4): serve a
/// ricostruire cosa è stato fatto e quando. Non si modifica e non si cancella: le correzioni
/// si aggiungono in coda.
public struct AuditEntry: Hashable, Sendable, Codable {
    public var timestamp: Date
    public var action: String
    public var detail: String
    /// Versione dell'applicazione che ha scritto la voce.
    public var appVersion: String

    public init(timestamp: Date = Date(), action: String, detail: String, appVersion: String) {
        self.timestamp = timestamp
        self.action = action
        self.detail = detail
        self.appVersion = appVersion
    }
}

// MARK: - Documento

/// Il piano completo.
public struct PlanDocument: Hashable, Sendable, Codable {

    /// Versione del formato. Si incrementa a ogni cambiamento incompatibile, così una versione
    /// futura può rifiutare esplicitamente un file che non sa leggere invece di interpretarlo
    /// male in silenzio.
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var study: StudyReference
    public var annotations: [Annotation]
    public var registry: PlanObjectRegistry
    public var viewState: ViewState?
    public var auditLog: [AuditEntry]
    public var createdAt: Date
    public var modifiedAt: Date
    /// Versione dell'applicazione, impressa anche in ogni esportazione.
    public var appVersion: String
    /// Nota di uso non diagnostico, scritta nel file perché accompagni il piano ovunque vada.
    public var disclaimer: String

    public static let standardDisclaimer =
        "Prodotto con CBCTMac, software non certificato come dispositivo medico. "
        + "Non utilizzabile per diagnosi o pianificazione di interventi su pazienti."

    public init(
        study: StudyReference,
        annotations: [Annotation] = [],
        registry: PlanObjectRegistry = PlanObjectRegistry(),
        viewState: ViewState? = nil,
        auditLog: [AuditEntry] = [],
        appVersion: String
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.study = study
        self.annotations = annotations
        self.registry = registry
        self.viewState = viewState
        self.auditLog = auditLog
        self.createdAt = Date()
        self.modifiedAt = Date()
        self.appVersion = appVersion
        self.disclaimer = Self.standardDisclaimer
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case study
        case annotations
        case registry
        case viewState
        case auditLog
        case createdAt
        case modifiedAt
        case appVersion
        case disclaimer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let foundVersion = try container.decode(Int.self, forKey: .formatVersion)

        // La versione si controlla prima di leggere qualunque altro campo. Un file futuro può
        // avere strutture che questa versione non conosce: decodificarlo a metà e poi salvarlo
        // cancellerebbe silenziosamente quei dati.
        guard foundVersion <= Self.currentFormatVersion else {
            throw PlanDocumentError.unsupportedFormatVersion(
                found: foundVersion, supported: Self.currentFormatVersion)
        }

        self.formatVersion = Self.currentFormatVersion
        self.study = try container.decode(StudyReference.self, forKey: .study)
        self.annotations = try container.decode([Annotation].self, forKey: .annotations)
        self.viewState = try container.decodeIfPresent(ViewState.self, forKey: .viewState)
        self.auditLog = try container.decode([AuditEntry].self, forKey: .auditLog)
        self.createdAt = try container.decode(Date.self, forKey: .createdAt)
        self.modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        self.appVersion = try container.decode(String.self, forKey: .appVersion)
        self.disclaimer = try container.decode(String.self, forKey: .disclaimer)

        if let decodedRegistry = try container.decodeIfPresent(
            PlanObjectRegistry.self, forKey: .registry)
        {
            self.registry = decodedRegistry
        } else {
            self.registry = Self.registryMigrated(from: annotations)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(study, forKey: .study)
        try container.encode(annotations, forKey: .annotations)
        try container.encode(registry, forKey: .registry)
        try container.encodeIfPresent(viewState, forKey: .viewState)
        try container.encode(auditLog, forKey: .auditLog)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(modifiedAt, forKey: .modifiedAt)
        try container.encode(appVersion, forKey: .appVersion)
        try container.encode(disclaimer, forKey: .disclaimer)
    }

    private static func registryMigrated(from annotations: [Annotation]) -> PlanObjectRegistry {
        var registry = PlanObjectRegistry()
        var order = 0
        for annotation in annotations {
            var info = PlanObjectInfo(
                id: annotation.id,
                kind: .annotation,
                name: registry.suggestedName(for: .annotation),
                order: order)
            let proposedColor = registry.suggestedColorHex(for: .annotation)
            info.colorHex = normalizedLegacyColor(
                annotation.metadata.colorHex, fallback: proposedColor)
            info.note = annotation.metadata.comment
            registry.register(info)
            order += 1
        }
        return registry
    }

    private static func normalizedLegacyColor(_ color: String, fallback: String) -> String {
        var candidate = color
        if candidate.hasPrefix("#") {
            candidate = String(candidate.dropFirst())
        }
        guard candidate.count == 6 else { return fallback }

        // Il vecchio campo era una stringa libera. Si conserva soltanto un vero RRGGBB:
        // propagare testo malformato sposterebbe l'errore fino al renderer o all'esportazione.
        for scalar in candidate.unicodeScalars {
            let value = scalar.value
            let isDigit = value >= 48 && value <= 57
            let isUppercaseHex = value >= 65 && value <= 70
            let isLowercaseHex = value >= 97 && value <= 102
            guard isDigit || isUppercaseHex || isLowercaseHex else { return fallback }
        }
        return candidate.uppercased()
    }

    // MARK: Serializzazione

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        // Ordinate e indentate: un piano deve restare leggibile a occhio e produrre diff
        // sensati sotto controllo di versione.
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    public func encoded() throws -> Data {
        var copy = self
        copy.modifiedAt = Date()
        return try Self.encoder().encode(copy)
    }

    public static func decoded(from data: Data) throws -> PlanDocument {
        let document = try decoder().decode(PlanDocument.self, from: data)
        guard document.formatVersion <= currentFormatVersion else {
            throw PlanDocumentError.unsupportedFormatVersion(
                found: document.formatVersion, supported: currentFormatVersion)
        }
        return document
    }

    public func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    public static func read(from url: URL) throws -> PlanDocument {
        try decoded(from: Data(contentsOf: url))
    }

    // MARK: Modifiche

    public mutating func append(_ annotation: Annotation, appVersion: String) {
        annotations.append(annotation)
        auditLog.append(
            AuditEntry(
                action: "annotation.add",
                detail: "\(annotation.kindName) \(annotation.formattedValue)",
                appVersion: appVersion))
        modifiedAt = Date()
    }

    public mutating func remove(annotationID: UUID, appVersion: String) {
        guard let index = annotations.firstIndex(where: { $0.id == annotationID }) else { return }
        let removed = annotations.remove(at: index)
        auditLog.append(
            AuditEntry(
                action: "annotation.remove",
                detail: "\(removed.kindName) \(removed.formattedValue)",
                appVersion: appVersion))
        modifiedAt = Date()
    }
}

public enum PlanDocumentError: Error, Hashable, Sendable, LocalizedError {
    case unsupportedFormatVersion(found: Int, supported: Int)
    case geometryMismatch

    public var errorDescription: String? {
        message
    }

    public var localizedDescription: String {
        message
    }

    private var message: String {
        switch self {
        case .unsupportedFormatVersion(let found, let supported):
            return "Il piano è in formato versione \(found), questa versione di CBCTMac ne "
                + "legge fino alla \(supported). Aggiorna l'applicazione."
        case .geometryMismatch:
            return "La geometria della serie non corrisponde a quella con cui il piano è stato "
                + "creato. Le annotazioni potrebbero non trovarsi sull'anatomia attesa."
        }
    }
}

// MARK: - Esportazione CSV

extension PlanDocument {

    /// Elenco misure in CSV.
    ///
    /// Separatore punto e virgola e decimali con la virgola: è ciò che si apre correttamente in
    /// un Excel con impostazioni italiane, dove un CSV con la virgola separatrice finisce tutto
    /// in una colonna sola.
    public func measurementsCSV(unit: DensityUnit = .greyValue) -> String {
        var lines: [String] = []
        lines.append("Tipo;Etichetta;Valore;Unità;Commento;Creata")

        let formatter = ISO8601DateFormatter()
        for annotation in annotations {
            let value = annotation.formattedValue
            guard !value.isEmpty else { continue }
            let fields = [
                annotation.kindName,
                annotation.metadata.label,
                value.replacingOccurrences(of: ".", with: ","),
                unit.symbol,
                annotation.metadata.comment,
                formatter.string(from: annotation.metadata.createdAt),
            ]
            lines.append(fields.map(escapeCSVField).joined(separator: ";"))
        }

        lines.append("")
        lines.append(escapeCSVField(disclaimer))
        lines.append("CBCTMac \(appVersion)")
        return lines.joined(separator: "\n")
    }

    private func escapeCSVField(_ field: String) -> String {
        if field.contains(";") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }
}
