import DICOMCore
import Foundation

// L'identità di un paziente e di un esame, come le scrive il DICOM.
//
// # Perché questi tipi non stanno in DICOMCore
//
// Perché non servono a **leggere** un file: servono a conservarlo e a ritrovarlo. DICOMCore
// legge byte e produce un volume; qui si decide che cosa di quell'esame vale la pena tenere per
// poterlo riaprire fra sei mesi, e con quale chiave riconoscere che due cartelle diverse sono
// lo stesso paziente. Sono due mestieri distinti, e tenerli separati è ciò che permette di
// cambiare l'archivio senza toccare il parser.
//
// # Le date DICOM
//
// Arrivano come `YYYYMMDD` e `HHMMSS.FFFFFF`, senza fuso orario e senza garanzia di esserci.
// Si conservano **come stringhe**, esattamente come sono state lette, e si convertono solo per
// mostrarle. Convertirle in `Date` all'ingresso vorrebbe dire scegliere un fuso che il file non
// dichiara, e riscriverlo in archivio come se fosse un fatto.

// MARK: - Paziente

public struct PatientIdentity: Hashable, Sendable, Codable {

    /// `PatientID (0010,0020)`. Vuoto quando il file non lo porta.
    public var patientID: String
    /// `PatientName (0010,0010)`, nella forma DICOM `Cognome^Nome^^^`.
    public var name: String
    /// `PatientBirthDate (0010,0030)`, come `YYYYMMDD`.
    public var birthDate: String
    /// `PatientSex (0010,0040)`: `M`, `F`, `O`, o vuoto.
    public var sex: String

    public init(patientID: String = "", name: String = "", birthDate: String = "", sex: String = "") {
        self.patientID = patientID.trimmed
        self.name = name.trimmed
        self.birthDate = birthDate.trimmed
        self.sex = sex.trimmed
    }

    /// Il nome in forma leggibile: `Cognome^Nome^^^` diventa «Nome Cognome».
    ///
    /// Il DICOM separa le cinque componenti con `^` e riempie di caret le assenti. Mostrarlo
    /// grezzo è quello che fanno molti visori, ed è brutto senza motivo.
    public var displayName: String {
        guard !name.isEmpty else { return "Paziente senza nome" }
        let parts = name.split(separator: "^", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let family = parts.count > 0 ? parts[0] : ""
        let given = parts.count > 1 ? parts[1] : ""
        let joined = [given, family].filter { !$0.isEmpty }.joined(separator: " ")
        return joined.isEmpty ? name : joined
    }

    /// Data di nascita leggibile, o `nil` se assente o malformata.
    public var displayBirthDate: String? { DICOMDate.display(birthDate) }

    /// Sesso in forma leggibile.
    public var displaySex: String? {
        switch sex.uppercased() {
        case "M": return "Maschio"
        case "F": return "Femmina"
        case "O": return "Altro"
        default: return nil
        }
    }

    /// La chiave con cui due esami finiscono sotto lo **stesso** paziente.
    ///
    /// # La decisione più delicata dell'archivio
    ///
    /// `PatientID` quando c'è: è ciò per cui esiste. Altrimenti nome più data di nascita, che è
    /// il ripiego usuale e regge finché i nomi sono scritti allo stesso modo.
    ///
    /// Quando **non c'è nessuno dei due** — esami anonimizzati, che nella pratica sono la
    /// maggioranza di quelli che girano — la chiave è `nil`, e chi archivia deve dare a quell'
    /// esame un paziente tutto suo. È la scelta scomoda ed è l'unica difendibile: raggruppare
    /// tutti gli anonimi sotto una chiave comune metterebbe persone diverse nella stessa
    /// cartella clinica, e non ci sarebbe modo di accorgersene guardando l'elenco.
    public var mergeKey: String? {
        if !patientID.isEmpty { return "id:" + patientID.uppercased() }
        let normalizedName = name.uppercased().replacingOccurrences(of: "^", with: " ")
            .split(separator: " ").joined(separator: " ")
        if !normalizedName.isEmpty, !birthDate.isEmpty {
            return "nb:" + normalizedName + "|" + birthDate
        }
        return nil
    }

    /// Vero quando il file non porta niente con cui riconoscere questa persona.
    public var isAnonymous: Bool { mergeKey == nil }
}

// MARK: - Esame

/// Un esame: la serie effettivamente ricostruita, con i parametri con cui è stata acquisita.
public struct ExamMetadata: Hashable, Sendable, Codable {

    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    /// `StudyDate (0008,0020)`, come `YYYYMMDD`.
    public var studyDate: String
    /// `StudyTime (0008,0030)`, come `HHMMSS` con frazione facoltativa.
    public var studyTime: String
    public var studyDescription: String
    public var seriesDescription: String
    public var modality: String
    public var manufacturer: String
    public var modelName: String
    public var stationName: String
    public var institutionName: String
    public var protocolName: String
    /// `KVP (0018,0060)`.
    public var kvp: Double?
    /// `XRayTubeCurrent (0018,1151)`, in mA.
    public var tubeCurrentMA: Double?
    /// `Exposure (0018,1152)`, in mAs.
    public var exposureMAS: Double?
    /// `ExposureTime (0018,1150)`, in millisecondi.
    public var exposureTimeMS: Double?

    // Fatti dell'acquisizione, ricavati dal volume ricostruito e non da un tag.
    public var columnCount: Int
    public var rowCount: Int
    public var sliceCount: Int
    public var columnSpacingMM: Double
    public var rowSpacingMM: Double
    public var sliceSpacingMM: Double

    public init(
        studyInstanceUID: String = "",
        seriesInstanceUID: String = "",
        studyDate: String = "",
        studyTime: String = "",
        studyDescription: String = "",
        seriesDescription: String = "",
        modality: String = "",
        manufacturer: String = "",
        modelName: String = "",
        stationName: String = "",
        institutionName: String = "",
        protocolName: String = "",
        kvp: Double? = nil,
        tubeCurrentMA: Double? = nil,
        exposureMAS: Double? = nil,
        exposureTimeMS: Double? = nil,
        columnCount: Int = 0,
        rowCount: Int = 0,
        sliceCount: Int = 0,
        columnSpacingMM: Double = 0,
        rowSpacingMM: Double = 0,
        sliceSpacingMM: Double = 0
    ) {
        self.studyInstanceUID = studyInstanceUID.trimmed
        self.seriesInstanceUID = seriesInstanceUID.trimmed
        self.studyDate = studyDate.trimmed
        self.studyTime = studyTime.trimmed
        self.studyDescription = studyDescription.trimmed
        self.seriesDescription = seriesDescription.trimmed
        self.modality = modality.trimmed
        self.manufacturer = manufacturer.trimmed
        self.modelName = modelName.trimmed
        self.stationName = stationName.trimmed
        self.institutionName = institutionName.trimmed
        self.protocolName = protocolName.trimmed
        self.kvp = kvp
        self.tubeCurrentMA = tubeCurrentMA
        self.exposureMAS = exposureMAS
        self.exposureTimeMS = exposureTimeMS
        self.columnCount = columnCount
        self.rowCount = rowCount
        self.sliceCount = sliceCount
        self.columnSpacingMM = columnSpacingMM
        self.rowSpacingMM = rowSpacingMM
        self.sliceSpacingMM = sliceSpacingMM
    }

    /// Riempie le dimensioni dalla geometria del volume ricostruito.
    ///
    /// Dalla geometria e non dai tag `Rows`/`Columns`/`SliceThickness`: il passo fra le slice si
    /// ricava dalle posizioni, mai da `SliceThickness`, ed è il Contratto 1. Un archivio che
    /// scrivesse lo spessore dichiarato accanto a un volume ricostruito col passo misurato
    /// conserverebbe due numeri diversi per la stessa cosa.
    public mutating func adopt(geometry: VolumeGeometry) {
        columnCount = geometry.columnCount
        rowCount = geometry.rowCount
        sliceCount = geometry.sliceCount
        columnSpacingMM = geometry.columnSpacingMM
        rowSpacingMM = geometry.rowSpacingMM
        sliceSpacingMM = geometry.sliceSpacingMM
    }

    /// Data dell'esame in forma leggibile, o `nil`.
    public var displayDate: String? { DICOMDate.display(studyDate) }

    /// Data e ora insieme, quando l'ora c'è.
    public var displayDateTime: String? {
        guard let date = displayDate else { return nil }
        guard let time = DICOMDate.displayTime(studyTime) else { return date }
        return date + ", " + time
    }

    /// Come chiamare l'esame in un elenco.
    public var displayTitle: String {
        let candidates = [seriesDescription, studyDescription, protocolName]
        if let first = candidates.first(where: { !$0.isEmpty }) { return first }
        return modality.isEmpty ? "Esame" : modality
    }

    /// La macchina, quando si sa.
    public var displayDevice: String? {
        let parts = [manufacturer, modelName].filter { !$0.isEmpty }
        guard !parts.isEmpty else { return stationName.isEmpty ? nil : stationName }
        return parts.joined(separator: " ")
    }

    /// Voxel in forma leggibile: «0,20 mm iso» oppure i tre valori.
    public var displayVoxel: String? {
        guard columnSpacingMM > 0, rowSpacingMM > 0, sliceSpacingMM > 0 else { return nil }
        let isotropic =
            abs(columnSpacingMM - rowSpacingMM) < 1e-6
            && abs(columnSpacingMM - sliceSpacingMM) < 1e-6
        if isotropic {
            return decimal(columnSpacingMM, digits: 2) + " mm iso"
        }
        return decimal(columnSpacingMM, digits: 2) + " × " + decimal(rowSpacingMM, digits: 2)
            + " × " + decimal(sliceSpacingMM, digits: 2) + " mm"
    }

    /// Matrice in voxel.
    public var displayMatrix: String? {
        guard columnCount > 0, rowCount > 0, sliceCount > 0 else { return nil }
        return "\(columnCount) × \(rowCount) × \(sliceCount)"
    }

    /// Campo di vista in millimetri, dal prodotto fra numero di voxel e passo.
    public var displayFieldOfView: String? {
        guard columnCount > 0, sliceCount > 0, columnSpacingMM > 0, sliceSpacingMM > 0
        else { return nil }
        let width = Double(columnCount) * columnSpacingMM
        let height = Double(sliceCount) * sliceSpacingMM
        return decimal(width, digits: 0) + " × " + decimal(height, digits: 0) + " mm"
    }

    /// I parametri di esposizione, quelli che ci sono.
    ///
    /// Nessuna invenzione: un valore assente resta assente. Sulle CBCT la dose dipende da kV,
    /// mA e tempo insieme, e mostrarne due su tre facendo credere che sia il quadro completo
    /// sarebbe peggio che mostrarne uno solo dichiarando che è uno solo.
    public var displayExposure: String? {
        var parts: [String] = []
        if let kvp { parts.append(decimal(kvp, digits: 0) + " kV") }
        if let tubeCurrentMA { parts.append(decimal(tubeCurrentMA, digits: 1) + " mA") }
        if let exposureMAS { parts.append(decimal(exposureMAS, digits: 1) + " mAs") }
        if let exposureTimeMS { parts.append(decimal(exposureTimeMS, digits: 0) + " ms") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func decimal(_ value: Double, digits: Int) -> String {
        String(format: "%.\(digits)f", value).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Date DICOM

/// Conversione delle date e delle ore DICOM in testo leggibile.
public enum DICOMDate: Sendable {

    private static let months = [
        "gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno",
        "luglio", "agosto", "settembre", "ottobre", "novembre", "dicembre",
    ]

    /// `YYYYMMDD` → «17 agosto 2026».
    ///
    /// - Returns: `nil` per una stringa vuota, di lunghezza sbagliata, non numerica o con mese
    ///   e giorno fuori intervallo. Non si «aggiusta»: una data che il file scrive male è un
    ///   fatto sul file, e mostrarla corretta nasconderebbe che quel file ha qualcosa che non va.
    public static func display(_ dicom: String) -> String? {
        guard let parts = components(dicom) else { return nil }
        return "\(parts.day) \(months[parts.month - 1]) \(parts.year)"
    }

    /// `YYYYMMDD` → «17/08/2026», per gli elenchi dove lo spazio conta.
    public static func displayShort(_ dicom: String) -> String? {
        guard let parts = components(dicom) else { return nil }
        return String(format: "%02d/%02d/%04d", parts.day, parts.month, parts.year)
    }

    /// `YYYYMMDD` → i tre numeri, verificati.
    public static func components(_ dicom: String) -> (year: Int, month: Int, day: Int)? {
        let digits = dicom.filter(\.isNumber)
        guard digits.count == 8 else { return nil }
        let chars = Array(digits)
        guard let year = Int(String(chars[0..<4])),
            let month = Int(String(chars[4..<6])),
            let day = Int(String(chars[6..<8])),
            (1...12).contains(month),
            (1...31).contains(day),
            year > 0
        else { return nil }
        return (year, month, day)
    }

    /// `HHMMSS.FFFFFF` → «14:32».
    ///
    /// I secondi si scartano: l'ora di uno studio serve a distinguere due esami dello stesso
    /// giorno, e il secondo esatto non distingue niente che il minuto non distingua già.
    public static func displayTime(_ dicom: String) -> String? {
        let digits = dicom.prefix(while: { $0 != "." }).filter(\.isNumber)
        guard digits.count >= 4 else { return nil }
        let chars = Array(digits)
        guard let hour = Int(String(chars[0..<2])), let minute = Int(String(chars[2..<4])),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }

    /// Chiave ordinabile: `YYYYMMDDHHMMSS` normalizzato, per mettere in ordine gli esami.
    ///
    /// Le stringhe DICOM già si ordinano bene se sono complete; questa le completa con degli
    /// zeri, così un esame senza ora non finisce dopo tutti quelli dello stesso giorno che ce
    /// l'hanno — finisce prima, che è il posto giusto per «ora ignota».
    public static func sortKey(date: String, time: String) -> String {
        let d = date.filter(\.isNumber)
        let t = time.prefix(while: { $0 != "." }).filter(\.isNumber)
        let paddedDate = d.count >= 8 ? String(d.prefix(8)) : d.padding(toLength: 8, withPad: "0", startingAt: 0)
        let paddedTime = t.count >= 6 ? String(t.prefix(6)) : t.padding(toLength: 6, withPad: "0", startingAt: 0)
        return paddedDate + paddedTime
    }
}

extension String {
    fileprivate var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Dalla lettura DICOM

extension PatientIdentity {
    /// Il paziente, come lo scrive il file.
    public init(_ identity: StudyIdentity) {
        self.init(
            patientID: identity.patientID,
            name: identity.patientName,
            birthDate: identity.patientBirthDate,
            sex: identity.patientSex)
    }
}

extension ExamMetadata {
    /// L'esame, come lo scrive il file. Le dimensioni restano a zero finché non arriva la
    /// geometria del volume ricostruito: vedi `adopt(geometry:)`.
    public init(_ identity: StudyIdentity) {
        self.init(
            studyInstanceUID: identity.studyInstanceUID,
            seriesInstanceUID: identity.seriesInstanceUID,
            studyDate: identity.studyDate,
            studyTime: identity.studyTime,
            studyDescription: identity.studyDescription,
            seriesDescription: identity.seriesDescription,
            modality: identity.modality,
            manufacturer: identity.manufacturer,
            modelName: identity.modelName,
            stationName: identity.stationName,
            institutionName: identity.institutionName,
            protocolName: identity.protocolName,
            kvp: identity.kvp,
            tubeCurrentMA: identity.tubeCurrentMA,
            exposureMAS: identity.exposureMAS,
            exposureTimeMS: identity.exposureTimeMS)
    }
}
