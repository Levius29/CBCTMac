import Foundation

// Scrivere DICOM.
//
// # Perché serve, se i file originali ce li ha già l'utente
//
// Perché il volume che si vuole consegnare spesso **non** è quello originale. È quello
// raddrizzato sul piano occlusale, o quello con le strie ridotte, o un ritaglio attorno al
// settore che interessa. Nessuno di quei volumi esiste su disco come DICOM, e senza un
// esportatore l'unico modo di darli a un laboratorio o a un altro programma sarebbe rifare
// l'elaborazione là — cioè non darli affatto.
//
// # Che cosa si scrive, e con che coscienza
//
// Una serie CT Image Storage in Explicit VR Little Endian, un file per fetta. È la forma che
// ogni programma legge. Le fette portano `ImagePositionPatient` e `ImageOrientationPatient`
// veri, ricavati dalla matrice del volume: senza quelli il volume si aprirebbe come una pila di
// immagini senza spazio, e ogni misura fatta altrove sarebbe sbagliata.
//
// La serie riceve **UID nuovi**, e non è un dettaglio: è un volume diverso da quello acquisito,
// e riusarne gli identificatori direbbe a un PACS che le due cose sono la stessa. Lo studio
// resta quello, perché lo studio è la visita del paziente e quella non cambia.
//
// # Che cosa non si scrive
//
// La compressione. Un DICOM non compresso è più grande e lo legge chiunque; un JPEG-lossless
// scritto male lo legge nessuno, e qui non ci sarebbe modo di provarlo contro un altro
// implementatore.

public enum DICOMWriteError: Error, Sendable, LocalizedError {
    case emptyVolume
    case tooManySlices(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyVolume:
            return "Il volume non ha fette da scrivere."
        case .tooManySlices(let count):
            return "Il volume ha \(count) fette: oltre il limite di sicurezza dell'esportazione."
        }
    }
}

/// I dati identificativi da scrivere nei file esportati.
public struct DICOMExportIdentity: Sendable {
    public var patientName: String
    public var patientID: String
    public var patientBirthDate: String
    public var patientSex: String
    public var studyInstanceUID: String
    public var studyDate: String
    public var studyTime: String
    public var studyDescription: String
    /// Come chiamare la serie esportata. Ci finisce anche l'operazione che l'ha prodotta.
    public var seriesDescription: String

    public init(
        patientName: String = "",
        patientID: String = "",
        patientBirthDate: String = "",
        patientSex: String = "",
        studyInstanceUID: String = "",
        studyDate: String = "",
        studyTime: String = "",
        studyDescription: String = "",
        seriesDescription: String = "Serie esportata"
    ) {
        self.patientName = patientName
        self.patientID = patientID
        self.patientBirthDate = patientBirthDate
        self.patientSex = patientSex
        self.studyInstanceUID = studyInstanceUID
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.studyDescription = studyDescription
        self.seriesDescription = seriesDescription
    }
}

public enum DICOMWriter: Sendable {

    /// SOP Class di CT Image Storage.
    public static let ctImageStorage = "1.2.840.10008.5.1.4.1.1.2"
    /// Explicit VR Little Endian.
    public static let explicitVRLittleEndian = "1.2.840.10008.1.2.1"

    /// Un UID nuovo, dalla radice `2.25` derivata da un UUID.
    ///
    /// # Perché `2.25` e non una radice nostra
    ///
    /// Perché una radice OID va **registrata**, e inventarne una significa collidere prima o poi
    /// con quella di qualcun altro — su un identificatore che dovrebbe essere unico al mondo. La
    /// forma `2.25.<intero a 128 bit>` è prevista apposta: qualunque UUID diventa un UID valido
    /// e irripetibile senza chiedere niente a nessuno.
    public static func newUID() -> String {
        let bytes = withUnsafeBytes(of: UUID().uuid) { Array($0) }
        // L'intero a 128 bit in decimale, calcolato a mano: `UInt128` non c'è ovunque, e
        // moltiplicare per 256 una cifra alla volta è esatto e basta.
        var digits = [0]
        for byte in bytes {
            var carry = Int(byte)
            for index in digits.indices {
                let value = digits[index] * 256 + carry
                digits[index] = value % 10
                carry = value / 10
            }
            while carry > 0 {
                digits.append(carry % 10)
                carry /= 10
            }
        }
        let decimal = digits.reversed().map(String.init).joined()
        return "2.25." + (decimal.isEmpty ? "0" : decimal)
    }

    /// Scrive il volume come una serie di file DICOM nella cartella indicata.
    ///
    /// - Returns: gli URL scritti, uno per fetta, nell'ordine delle fette.
    @discardableResult
    public static func write(
        volume: Volume,
        identity: DICOMExportIdentity,
        to directory: URL,
        seriesInstanceUID: String? = nil
    ) throws -> [URL] {
        let geometry = volume.geometry
        guard geometry.sliceCount > 0, geometry.voxelCount > 0 else {
            throw DICOMWriteError.emptyVolume
        }
        // Diecimila fette sono già dieci volte una CBCT dentale: oltre, quasi certamente è un
        // errore di chi chiama, e riempire un disco di file è un modo scomodo di scoprirlo.
        guard geometry.sliceCount <= 10_000 else {
            throw DICOMWriteError.tooManySlices(geometry.sliceCount)
        }

        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let series = seriesInstanceUID ?? newUID()
        let frameOfReference = newUID()
        let study = identity.studyInstanceUID.isEmpty ? newUID() : identity.studyInstanceUID
        let sliceArea = geometry.columnCount * geometry.rowCount

        var written: [URL] = []
        written.reserveCapacity(geometry.sliceCount)

        for slice in 0..<geometry.sliceCount {
            let sop = newUID()
            let origin = geometry.patientPoint(i: 0, j: 0, k: slice)
            let start = slice * sliceArea
            let samples = Array(volume.samples[start..<(start + sliceArea)])

            let data = fileData(
                volume: volume,
                identity: identity,
                studyInstanceUID: study,
                seriesInstanceUID: series,
                sopInstanceUID: sop,
                frameOfReferenceUID: frameOfReference,
                instanceNumber: slice + 1,
                originMM: origin,
                samples: samples)

            let url = directory.appendingPathComponent(
                String(format: "IM%05d.dcm", slice + 1))
            try data.write(to: url, options: .atomic)
            written.append(url)
        }
        return written
    }

    // MARK: Composizione di un file

    private static func fileData(
        volume: Volume,
        identity: DICOMExportIdentity,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        sopInstanceUID: String,
        frameOfReferenceUID: String,
        instanceNumber: Int,
        originMM: Vec3,
        samples: [Int16]
    ) -> Data {
        let geometry = volume.geometry

        // Il gruppo 0002 va scritto per primo e la sua lunghezza dichiarata: si compone a parte
        // e la si misura, perché il valore di `FileMetaInformationGroupLength` è il numero di
        // byte che lo **seguono** dentro il gruppo, non la lunghezza totale.
        var meta = Data()
        append(&meta, DICOMTags.mediaStorageSOPClassUID, .UI, text: ctImageStorage)
        append(&meta, DICOMTags.mediaStorageSOPInstanceUID, .UI, text: sopInstanceUID)
        append(&meta, DICOMTags.transferSyntaxUID, .UI, text: explicitVRLittleEndian)

        var file = Data(repeating: 0, count: 128)
        file.append(contentsOf: Array("DICM".utf8))
        append(&file, DICOMTags.fileMetaGroupLength, .UL, uint32: UInt32(meta.count))
        file.append(meta)

        // Da qui il dataset, in ordine crescente di tag: è la sola forma che ogni lettore
        // accetta, e un tag fuori ordine fa fallire i parser rigorosi senza spiegare perché.
        var body = Data()
        append(&body, DICOMTags.studyDate, .DA, text: identity.studyDate)
        append(&body, DICOMTags.studyTime, .TM, text: identity.studyTime)
        append(&body, DICOMTags.sopClassUID, .UI, text: ctImageStorage)
        append(&body, DICOMTags.sopInstanceUID, .UI, text: sopInstanceUID)
        append(&body, DICOMTags.modality, .CS, text: "CT")
        append(&body, DICOMTags.manufacturer, .LO, text: "3DMED")
        append(&body, DICOMTags.studyDescription, .LO, text: identity.studyDescription)
        append(&body, DICOMTags.seriesDescription, .LO, text: identity.seriesDescription)
        append(&body, DICOMTags.patientName, .PN, text: identity.patientName)
        append(&body, DICOMTags.patientID, .LO, text: identity.patientID)
        append(&body, DICOMTags.patientBirthDate, .DA, text: identity.patientBirthDate)
        append(&body, DICOMTags.patientSex, .CS, text: identity.patientSex)
        append(&body, DICOMTags.sliceThickness, .DS, text: number(geometry.sliceSpacingMM))
        append(&body, DICOMTags.spacingBetweenSlices, .DS, text: number(geometry.sliceSpacingMM))
        append(&body, DICOMTags.studyInstanceUID, .UI, text: studyInstanceUID)
        append(&body, DICOMTags.seriesInstanceUID, .UI, text: seriesInstanceUID)
        append(&body, DICOMTags.seriesNumber, .IS, text: "1")
        append(&body, DICOMTags.instanceNumber, .IS, text: "\(instanceNumber)")
        append(
            &body, DICOMTags.imagePositionPatient, .DS,
            text: [originMM.x, originMM.y, originMM.z].map(number).joined(separator: "\\"))
        append(
            &body, DICOMTags.imageOrientationPatient, .DS,
            text: [
                geometry.orientation.columnDirection.x, geometry.orientation.columnDirection.y,
                geometry.orientation.columnDirection.z, geometry.orientation.rowDirection.x,
                geometry.orientation.rowDirection.y, geometry.orientation.rowDirection.z,
            ].map(number).joined(separator: "\\"))
        append(&body, DICOMTags.frameOfReferenceUID, .UI, text: frameOfReferenceUID)
        append(&body, DICOMTags.samplesPerPixel, .US, uint16: 1)
        append(&body, DICOMTags.photometricInterpretation, .CS, text: "MONOCHROME2")
        append(&body, DICOMTags.rows, .US, uint16: UInt16(geometry.rowCount))
        append(&body, DICOMTags.columns, .US, uint16: UInt16(geometry.columnCount))
        // `PixelSpacing` è **riga poi colonna**: è l'accoppiamento incrociato del Contratto 1, e
        // scriverlo al contrario darebbe un volume trasposto che su voxel isotropici nessuno
        // noterebbe.
        append(
            &body, DICOMTags.pixelSpacing, .DS,
            text: number(geometry.rowSpacingMM) + "\\" + number(geometry.columnSpacingMM))
        append(&body, DICOMTags.bitsAllocated, .US, uint16: 16)
        append(&body, DICOMTags.bitsStored, .US, uint16: 16)
        append(&body, DICOMTags.highBit, .US, uint16: 15)
        // Con segno: i campioni sono `Int16` e possono essere negativi. Dichiarare 0 li farebbe
        // rileggere come interi enormi, e l'aria diventerebbe più densa dell'osso.
        append(&body, DICOMTags.pixelRepresentation, .US, uint16: 1)
        append(&body, DICOMTags.rescaleIntercept, .DS, text: number(volume.rescaleIntercept))
        append(&body, DICOMTags.rescaleSlope, .DS, text: number(volume.rescaleSlope))
        append(&body, DICOMTags.pixelData, .OW, samples: samples)

        file.append(body)
        return file
    }

    // MARK: Codifica degli elementi

    private static func append(_ data: inout Data, _ tag: DICOMTag, _ vr: VR, text: String) {
        var value = Array(text.utf8)
        // Ogni valore ha lunghezza pari. Gli UID si riempiono con uno zero, il resto con uno
        // spazio: è la regola DICOM, e un riempimento sbagliato lascia un carattere spurio in
        // coda a chi rilegge.
        if value.count % 2 == 1 { value.append(vr == .UI ? 0x00 : 0x20) }
        appendHeader(&data, tag, vr, length: value.count)
        data.append(contentsOf: value)
    }

    private static func append(_ data: inout Data, _ tag: DICOMTag, _ vr: VR, uint16: UInt16) {
        appendHeader(&data, tag, vr, length: 2)
        data.append(UInt8(uint16 & 0xFF))
        data.append(UInt8((uint16 >> 8) & 0xFF))
    }

    private static func append(_ data: inout Data, _ tag: DICOMTag, _ vr: VR, uint32: UInt32) {
        appendHeader(&data, tag, vr, length: 4)
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((uint32 >> UInt32(shift)) & 0xFF))
        }
    }

    private static func append(
        _ data: inout Data, _ tag: DICOMTag, _ vr: VR, samples: [Int16]
    ) {
        appendHeader(&data, tag, vr, length: samples.count * 2)
        for sample in samples {
            let unsigned = UInt16(bitPattern: sample)
            data.append(UInt8(unsigned & 0xFF))
            data.append(UInt8((unsigned >> 8) & 0xFF))
        }
    }

    /// L'intestazione di un elemento in Explicit VR Little Endian.
    ///
    /// I VR `OB`, `OW`, `OF`, `SQ`, `UT` e `UN` hanno una forma diversa: due byte riservati e
    /// una lunghezza a 32 bit invece che a 16. Senza la distinzione, un `PixelData` da più di
    /// 65 535 byte — cioè qualunque immagine vera — scriverebbe una lunghezza troncata.
    private static func appendHeader(
        _ data: inout Data, _ tag: DICOMTag, _ vr: VR, length: Int
    ) {
        data.append(UInt8(tag.group & 0xFF))
        data.append(UInt8((tag.group >> 8) & 0xFF))
        data.append(UInt8(tag.element & 0xFF))
        data.append(UInt8((tag.element >> 8) & 0xFF))
        data.append(contentsOf: Array(vr.rawValue.utf8))

        switch vr {
        case .OB, .OW, .OF, .SQ, .UT, .UN:
            data.append(0)
            data.append(0)
            let value = UInt32(length)
            for shift in stride(from: 0, to: 32, by: 8) {
                data.append(UInt8((value >> UInt32(shift)) & 0xFF))
            }
        default:
            let value = UInt16(length)
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
    }

    /// Un numero come lo scrive un `DS`: al più sedici caratteri, senza notazione scientifica.
    ///
    /// `%g` produrrebbe `1e-05` su valori piccoli, e il VR `DS` non ammette l'esponente in quella
    /// forma su tutti i lettori. Sei decimali coprono il micron, che è mille volte più fine di
    /// qualunque voxel.
    private static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        var text = String(format: "%.6f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? "0" : text
    }
}

// MARK: - Dove scrivere

extension DICOMExportIdentity {
    /// Il nome da dare alla cartella dell'esportazione: paziente, data, serie.
    ///
    /// # Perché sanificare
    ///
    /// Un nome di paziente DICOM arriva nella forma `Rossi^Mario^^^` e può contenere qualunque
    /// carattere, barra compresa. Una barra dentro un nome di file non è un carattere: è un
    /// livello di cartella, e la scrittura fallirebbe lamentando un percorso inesistente mentre
    /// il problema è il nome. Qui i caret diventano spazi e tutto ciò che non è lettera o cifra
    /// diventa uno spazio solo.
    ///
    /// La data resta nella forma DICOM `AAAAMMGG` invece che leggibile: senza barre, e per di
    /// più i nomi si ordinano da soli in ordine cronologico.
    public var suggestedFolderName: String {
        var parts: [String] = []

        let person = DICOMWriter.folderComponent(
            patientName.replacingOccurrences(of: "^", with: " "))
        parts.append(person.isEmpty ? "Anonimo" : person)

        let digits = studyDate.filter(\.isNumber)
        if digits.count == 8 { parts.append(digits) }

        let series = DICOMWriter.folderComponent(seriesDescription)
        if !series.isEmpty { parts.append(series) }

        return parts.joined(separator: " - ")
    }
}

extension DICOMWriter {
    /// Un pezzo di nome di cartella, ridotto a caratteri che stanno in un nome di file.
    ///
    /// Il trattino e il trattino basso passano perché ci stanno e perché spesso portano
    /// informazione — `CBCT_MAX`, `arcata-inferiore`. Il punto no: un nome che comincia per
    /// punto è un file nascosto, e non è ciò che si vuole ottenere esportando.
    public static func folderComponent(_ text: String, limit: Int = 48) -> String {
        var out = ""
        var pendingSpace = false
        for character in text {
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(character)
                if out.count >= limit { break }
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// Un URL di cartella che **non esiste ancora**, a partire dal nome proposto.
    ///
    /// # Il guasto che evita
    ///
    /// Esportare due volte lo stesso esame nella stessa cartella scriverebbe le fette nuove
    /// sopra le vecchie. Finché il volume ha lo stesso numero di fette non si nota; appena la
    /// seconda esportazione ne ha meno — un ritaglio, per esempio — le fette in eccesso della
    /// prima restano lì, con UID di un'altra serie, e chi riapre la cartella legge un volume
    /// fatto di pezzi di due. Un nome nuovo costa niente e toglie il caso di mezzo.
    public static func availableDirectory(named name: String, in parent: URL) -> URL {
        let base = name.isEmpty ? "Esportazione" : name
        let manager = FileManager.default
        var candidate = parent.appendingPathComponent(base)
        var index = 2
        while manager.fileExists(atPath: candidate.path) {
            // Mille tentativi sono già assurdi; oltre, meglio un nome sicuramente libero che un
            // ciclo che non finisce.
            if index > 1000 {
                return parent.appendingPathComponent(base + " " + UUID().uuidString)
            }
            candidate = parent.appendingPathComponent("\(base) \(index)")
            index += 1
        }
        return candidate
    }
}
