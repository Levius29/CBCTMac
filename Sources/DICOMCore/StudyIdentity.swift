import Foundation

// Chi è il paziente e com'è stato fatto l'esame.
//
// # Perché non passa dal DICOMScanner
//
// Lo scanner risponde a una domanda diversa: quali serie ci sono in questa cartella, e quali
// file le compongono. Per rispondere legge da ogni file i pochi tag che servono a raggrupparli,
// e li accumula in cinque strutture annidate. Infilarci dentro il kilovoltaggio e il nome
// dell'istituto vorrebbe dire allargare tutt'e cinque per un'informazione che serve **una volta
// sola**, quando l'esame è già stato scelto.
//
// Qui invece si rilegge un file solo — l'intestazione, non i pixel — e si prende tutto. Costa
// un'apertura, e in cambio lascia lo scanner esattamente com'è.
//
// # I valori mancanti restano mancanti
//
// Nessun tag è obbligatorio in questo tipo, e nessuno viene inventato. Un CBCT che non dichiara
// i mAs non li dichiara: scrivere zero, o dedurli da kV e tempo, produrrebbe un numero che
// sembra misurato e non lo è. `nil` è l'unica risposta onesta, e l'interfaccia sa non
// mostrare una riga vuota.

/// I dati identificativi e i parametri d'acquisizione letti da un'immagine DICOM.
public struct StudyIdentity: Hashable, Sendable {

    // Paziente.
    public var patientID: String
    public var patientName: String
    public var patientBirthDate: String
    public var patientSex: String

    // Studio e serie.
    public var studyInstanceUID: String
    public var seriesInstanceUID: String
    public var studyDate: String
    public var studyTime: String
    public var studyDescription: String
    public var seriesDescription: String
    public var accessionNumber: String
    public var modality: String

    // Apparecchio.
    public var manufacturer: String
    public var modelName: String
    public var stationName: String
    public var institutionName: String
    public var softwareVersions: String
    public var deviceSerialNumber: String
    public var protocolName: String

    // Esposizione.
    public var kvp: Double?
    public var tubeCurrentMA: Double?
    public var exposureMAS: Double?
    public var exposureTimeMS: Double?

    public init(
        patientID: String = "",
        patientName: String = "",
        patientBirthDate: String = "",
        patientSex: String = "",
        studyInstanceUID: String = "",
        seriesInstanceUID: String = "",
        studyDate: String = "",
        studyTime: String = "",
        studyDescription: String = "",
        seriesDescription: String = "",
        accessionNumber: String = "",
        modality: String = "",
        manufacturer: String = "",
        modelName: String = "",
        stationName: String = "",
        institutionName: String = "",
        softwareVersions: String = "",
        deviceSerialNumber: String = "",
        protocolName: String = "",
        kvp: Double? = nil,
        tubeCurrentMA: Double? = nil,
        exposureMAS: Double? = nil,
        exposureTimeMS: Double? = nil
    ) {
        self.patientID = patientID
        self.patientName = patientName
        self.patientBirthDate = patientBirthDate
        self.patientSex = patientSex
        self.studyInstanceUID = studyInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.studyDate = studyDate
        self.studyTime = studyTime
        self.studyDescription = studyDescription
        self.seriesDescription = seriesDescription
        self.accessionNumber = accessionNumber
        self.modality = modality
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.stationName = stationName
        self.institutionName = institutionName
        self.softwareVersions = softwareVersions
        self.deviceSerialNumber = deviceSerialNumber
        self.protocolName = protocolName
        self.kvp = kvp
        self.tubeCurrentMA = tubeCurrentMA
        self.exposureMAS = exposureMAS
        self.exposureTimeMS = exposureTimeMS
    }

    /// Legge quel che c'è in un dataset già aperto.
    public init(dataset: DICOMDataset) {
        func text(_ tag: DICOMTag) -> String {
            (dataset.string(tag) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        /// Un valore non finito è come un valore assente: un `NaN` scritto in un tag DS non è
        /// una misura, e propagarlo darebbe «NaN kV» nell'interfaccia.
        func number(_ tag: DICOMTag) -> Double? {
            guard let value = dataset.double(tag), value.isFinite else { return nil }
            return value
        }

        self.init(
            patientID: text(DICOMTags.patientID),
            patientName: text(DICOMTags.patientName),
            patientBirthDate: text(DICOMTags.patientBirthDate),
            patientSex: text(DICOMTags.patientSex),
            studyInstanceUID: text(DICOMTags.studyInstanceUID),
            seriesInstanceUID: text(DICOMTags.seriesInstanceUID),
            studyDate: text(DICOMTags.studyDate),
            studyTime: text(DICOMTags.studyTime),
            studyDescription: text(DICOMTags.studyDescription),
            seriesDescription: text(DICOMTags.seriesDescription),
            accessionNumber: text(DICOMTags.accessionNumber),
            modality: text(DICOMTags.modality),
            manufacturer: text(DICOMTags.manufacturer),
            modelName: text(DICOMTags.manufacturerModelName),
            stationName: text(DICOMTags.stationName),
            institutionName: text(DICOMTags.institutionName),
            softwareVersions: text(DICOMTags.softwareVersions),
            deviceSerialNumber: text(DICOMTags.deviceSerialNumber),
            protocolName: text(DICOMTags.protocolName),
            kvp: number(DICOMTags.kvp),
            tubeCurrentMA: number(DICOMTags.xRayTubeCurrent),
            exposureMAS: number(DICOMTags.exposure),
            exposureTimeMS: number(DICOMTags.exposureTime))
    }

    /// Legge l'intestazione di un file DICOM.
    ///
    /// - Returns: `nil` se il file non si apre o non è DICOM. Un'identità mancante non deve
    ///   impedire di **guardare** uno studio: si perde il nome del paziente, non l'immagine.
    public static func read(from url: URL) -> StudyIdentity? {
        guard let parsed = try? DICOMParser.parse(url: url, depth: .metadataOnly) else {
            return nil
        }
        return StudyIdentity(dataset: parsed.dataset)
    }

    /// Vero quando non c'è niente da mostrare: nessun nome, nessuna data, nessun apparecchio.
    public var isEmpty: Bool {
        patientID.isEmpty && patientName.isEmpty && studyDate.isEmpty
            && seriesDescription.isEmpty && studyDescription.isEmpty
            && manufacturer.isEmpty && modelName.isEmpty
    }
}
