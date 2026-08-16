import Foundation

/// Metadati necessari a identificare e collocare una singola istanza DICOM.
public struct ScannedInstance: Sendable {
    public let url: URL
    public let sopInstanceUID: String
    public let seriesInstanceUID: String
    public let studyInstanceUID: String
    public let instanceNumber: Int?
    public let positionMM: Vec3?
    public let orientation: SliceOrientation?

    public init(
        url: URL,
        sopInstanceUID: String,
        seriesInstanceUID: String,
        studyInstanceUID: String,
        instanceNumber: Int?,
        positionMM: Vec3?,
        orientation: SliceOrientation?
    ) {
        self.url = url
        self.sopInstanceUID = sopInstanceUID
        self.seriesInstanceUID = seriesInstanceUID
        self.studyInstanceUID = studyInstanceUID
        self.instanceNumber = instanceNumber
        self.positionMM = positionMM
        self.orientation = orientation
    }
}

/// Spaziatura dei pixel nell'ordine definito dal tag DICOM PixelSpacing.
public struct PixelSpacing: Hashable, Sendable {
    /// PixelSpacing[0]: distanza verticale fra righe adiacenti.
    public let rowMM: Double
    /// PixelSpacing[1]: distanza orizzontale fra colonne adiacenti.
    public let columnMM: Double

    public init(rowMM: Double, columnMM: Double) {
        self.rowMM = rowMM
        self.columnMM = columnMM
    }
}

/// Una serie DICOM e le sue istanze nell'ordine in cui sono state incontrate.
public struct ScannedSeries: Sendable {
    public let seriesInstanceUID: String
    public let seriesNumber: Int?
    public let description: String?
    public let modality: String?
    public let instances: [ScannedInstance]
    public let rows: Int?
    public let columns: Int?
    public let pixelSpacingMM: PixelSpacing?
    public let sliceThicknessMM: Double?
    /// Falso per gli oggetti strutturati SR, PR e KO, che restano visibili nell'elenco.
    public let isImageSeries: Bool

    public init(
        seriesInstanceUID: String,
        seriesNumber: Int?,
        description: String?,
        modality: String?,
        instances: [ScannedInstance],
        rows: Int?,
        columns: Int?,
        pixelSpacingMM: PixelSpacing?,
        sliceThicknessMM: Double?,
        isImageSeries: Bool
    ) {
        self.seriesInstanceUID = seriesInstanceUID
        self.seriesNumber = seriesNumber
        self.description = description
        self.modality = modality
        self.instances = instances
        self.rows = rows
        self.columns = columns
        self.pixelSpacingMM = pixelSpacingMM
        self.sliceThicknessMM = sliceThicknessMM
        self.isImageSeries = isImageSeries
    }
}

/// Uno studio DICOM con le serie nell'ordine di prima scoperta.
public struct ScannedStudy: Sendable {
    public let studyInstanceUID: String
    public let date: String?
    public let description: String?
    public let series: [ScannedSeries]

    public init(
        studyInstanceUID: String,
        date: String?,
        description: String?,
        series: [ScannedSeries]
    ) {
        self.studyInstanceUID = studyInstanceUID
        self.date = date
        self.description = description
        self.series = series
    }
}

/// Un paziente DICOM con gli studi nell'ordine di prima scoperta.
public struct ScannedPatient: Sendable {
    public let patientID: String
    public let name: String?
    public let birthDate: String?
    public let studies: [ScannedStudy]

    public init(
        patientID: String,
        name: String?,
        birthDate: String?,
        studies: [ScannedStudy]
    ) {
        self.patientID = patientID
        self.name = name
        self.birthDate = birthDate
        self.studies = studies
    }
}

/// Fallimento limitato a un singolo file durante una scansione di directory.
public struct ScanFailure: Sendable {
    public let url: URL
    public let reason: String

    public init(url: URL, reason: String) {
        self.url = url
        self.reason = reason
    }
}

/// Risultato completo della scansione ricorsiva.
public struct ScanResult: Sendable {
    public let patients: [ScannedPatient]
    public let failures: [ScanFailure]

    public init(patients: [ScannedPatient], failures: [ScanFailure]) {
        self.patients = patients
        self.failures = failures
    }
}

/// Errore che impedisce di enumerare la directory richiesta.
public enum DICOMScanningError: Error, Hashable, Sendable, LocalizedError {
    case cannotEnumerate(path: String, reason: String)

    public var localizedDescription: String {
        switch self {
        case .cannotEnumerate(let path, let reason):
            return "Impossibile enumerare il percorso '\(path)': \(reason)"
        }
    }

    public var errorDescription: String? {
        localizedDescription
    }
}

/// Scansiona directory di file DICOM senza caricare né ordinare i pixel.
public struct DICOMScanner: Sendable {
    public static func scan(
        directory: URL,
        progress: (@Sendable (Int, Int) -> Void)?
    ) throws -> ScanResult {
        let files = try regularFiles(in: directory)
        let total = files.count
        progress?(0, total)

        var patientAccumulators: [PatientAccumulator] = []
        var patientIndices: [String: Int] = [:]
        var failures: [ScanFailure] = []
        var completed = 0

        for url: URL in files {
            do {
                let parsed = try DICOMParser.parse(url: url, depth: .metadataOnly)
                let metadata = try makeMetadata(
                    dataset: parsed.dataset,
                    url: url)
                add(
                    metadata,
                    to: &patientAccumulators,
                    patientIndices: &patientIndices)
            } catch let parsingError as DICOMParsingError {
                switch parsingError {
                case .notDICOM:
                    // Le cartelle cliniche contengono spesso PDF, JSON e anteprime: non sono
                    // errori di importazione e non devono sommergere l'utente di avvisi.
                    break
                default:
                    failures.append(ScanFailure(
                        url: url,
                        reason: parsingError.localizedDescription))
                }
            } catch {
                failures.append(ScanFailure(
                    url: url,
                    reason: "Errore nel file '\(url.path)': \(error.localizedDescription)"))
            }

            completed += 1
            progress?(completed, total)
        }

        let patients = publicPatients(from: patientAccumulators)
        return ScanResult(patients: patients, failures: failures)
    }

    private static func regularFiles(in root: URL) throws -> [URL] {
        var pendingDirectories: [URL] = [root]
        var files: [URL] = []
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]

        while let directory = pendingDirectories.popLast() {
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: Array(keys),
                    options: [])
            } catch {
                throw DICOMScanningError.cannotEnumerate(
                    path: directory.path,
                    reason: error.localizedDescription)
            }

            for entry: URL in entries {
                let values: URLResourceValues
                do {
                    values = try entry.resourceValues(forKeys: keys)
                } catch {
                    throw DICOMScanningError.cannotEnumerate(
                        path: entry.path,
                        reason: error.localizedDescription)
                }

                if values.isSymbolicLink == true {
                    // Non seguire link evita cicli ricorsivi e impedisce di uscire dalla
                    // directory scelta dall'utente.
                    continue
                }
                if values.isDirectory == true {
                    pendingDirectories.append(entry)
                    continue
                }
                if values.isRegularFile == true {
                    files.append(entry)
                }
            }
        }
        return files
    }

    private static func makeMetadata(
        dataset: DICOMDataset,
        url: URL
    ) throws -> InstanceMetadata {
        let sourceName = url.path
        let sopInstanceUID = try requiredString(
            dataset: dataset,
            tag: DICOMTags.sopInstanceUID,
            sourceName: sourceName)
        let seriesInstanceUID = try requiredString(
            dataset: dataset,
            tag: DICOMTags.seriesInstanceUID,
            sourceName: sourceName)
        let studyInstanceUID = try requiredString(
            dataset: dataset,
            tag: DICOMTags.studyInstanceUID,
            sourceName: sourceName)

        let patientID = dataset.string(DICOMTags.patientID) ?? ""
        let patientName = nonEmpty(dataset.string(DICOMTags.patientName))
        let patientBirthDate = nonEmpty(dataset.string(DICOMTags.patientBirthDate))
        let studyDate = nonEmpty(dataset.string(DICOMTags.studyDate))
        let studyDescription = nonEmpty(dataset.string(DICOMTags.studyDescription))
        let seriesDescription = nonEmpty(dataset.string(DICOMTags.seriesDescription))
        let modality = nonEmpty(dataset.string(DICOMTags.modality))

        var orientation: SliceOrientation?
        if let values = dataset.doubles(DICOMTags.imageOrientationPatient) {
            orientation = SliceOrientation(dicomValues: values)
        }

        var pixelSpacing: PixelSpacing?
        if let values = dataset.doubles(DICOMTags.pixelSpacing), values.count >= 2 {
            let row = values[0]
            let column = values[1]
            if row.isFinite, column.isFinite, row > 0, column > 0 {
                pixelSpacing = PixelSpacing(rowMM: row, columnMM: column)
            }
        }

        let instance = ScannedInstance(
            url: url,
            sopInstanceUID: sopInstanceUID,
            seriesInstanceUID: seriesInstanceUID,
            studyInstanceUID: studyInstanceUID,
            instanceNumber: dataset.int(DICOMTags.instanceNumber),
            positionMM: dataset.vec3(DICOMTags.imagePositionPatient),
            orientation: orientation)

        return InstanceMetadata(
            patientKey: patientKey(
                patientID: patientID,
                name: patientName,
                birthDate: patientBirthDate),
            patientID: patientID,
            patientName: patientName,
            patientBirthDate: patientBirthDate,
            studyInstanceUID: studyInstanceUID,
            studyDate: studyDate,
            studyDescription: studyDescription,
            seriesInstanceUID: seriesInstanceUID,
            seriesNumber: dataset.int(DICOMTags.seriesNumber),
            seriesDescription: seriesDescription,
            modality: modality,
            rows: dataset.int(DICOMTags.rows),
            columns: dataset.int(DICOMTags.columns),
            pixelSpacing: pixelSpacing,
            sliceThickness: dataset.double(DICOMTags.sliceThickness),
            isImageSeries: isImageSeries(modality: modality),
            instance: instance)
    }

    private static func requiredString(
        dataset: DICOMDataset,
        tag: DICOMTag,
        sourceName: String
    ) throws -> String {
        guard let value = dataset.string(tag), !value.isEmpty else {
            throw DICOMParsingError.missingRequiredTag(
                sourceName: sourceName,
                tag: tag)
        }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func patientKey(
        patientID: String,
        name: String?,
        birthDate: String?
    ) -> String {
        if !patientID.isEmpty {
            return "id\u{001F}\(patientID)"
        }
        let namePart = name ?? ""
        let birthDatePart = birthDate ?? ""
        if !namePart.isEmpty || !birthDatePart.isEmpty {
            return "identity\u{001F}\(namePart)\u{001F}\(birthDatePart)"
        }
        return "anonymous"
    }

    private static func isImageSeries(modality: String?) -> Bool {
        guard let modality else {
            return true
        }
        switch modality {
        case "SR", "PR", "KO":
            return false
        default:
            return true
        }
    }

    private static func add(
        _ metadata: InstanceMetadata,
        to patients: inout [PatientAccumulator],
        patientIndices: inout [String: Int]
    ) {
        let patientIndex: Int
        if let existing = patientIndices[metadata.patientKey] {
            patientIndex = existing
        } else {
            patientIndex = patients.count
            patients.append(PatientAccumulator(
                patientID: metadata.patientID,
                name: metadata.patientName,
                birthDate: metadata.patientBirthDate,
                studies: [],
                studyIndices: [:]))
            patientIndices[metadata.patientKey] = patientIndex
        }

        let studyIndex: Int
        if let existing = patients[patientIndex].studyIndices[metadata.studyInstanceUID] {
            studyIndex = existing
        } else {
            studyIndex = patients[patientIndex].studies.count
            patients[patientIndex].studies.append(StudyAccumulator(
                studyInstanceUID: metadata.studyInstanceUID,
                date: metadata.studyDate,
                description: metadata.studyDescription,
                series: [],
                seriesIndices: [:]))
            patients[patientIndex].studyIndices[metadata.studyInstanceUID] = studyIndex
        }

        let seriesIndex: Int
        if let existing = patients[patientIndex].studies[studyIndex]
            .seriesIndices[metadata.seriesInstanceUID]
        {
            seriesIndex = existing
        } else {
            seriesIndex = patients[patientIndex].studies[studyIndex].series.count
            patients[patientIndex].studies[studyIndex].series.append(SeriesAccumulator(
                seriesInstanceUID: metadata.seriesInstanceUID,
                seriesNumber: metadata.seriesNumber,
                description: metadata.seriesDescription,
                modality: metadata.modality,
                instances: [],
                rows: metadata.rows,
                columns: metadata.columns,
                pixelSpacingMM: metadata.pixelSpacing,
                sliceThicknessMM: metadata.sliceThickness,
                isImageSeries: metadata.isImageSeries))
            patients[patientIndex].studies[studyIndex]
                .seriesIndices[metadata.seriesInstanceUID] = seriesIndex
        }

        // Append soltanto: l'ordinamento spaziale appartiene esclusivamente a SliceSorter.
        patients[patientIndex].studies[studyIndex].series[seriesIndex]
            .instances.append(metadata.instance)
    }

    private static func publicPatients(
        from accumulators: [PatientAccumulator]
    ) -> [ScannedPatient] {
        var patients: [ScannedPatient] = []
        patients.reserveCapacity(accumulators.count)

        for patientAccumulator: PatientAccumulator in accumulators {
            var studies: [ScannedStudy] = []
            studies.reserveCapacity(patientAccumulator.studies.count)

            for studyAccumulator: StudyAccumulator in patientAccumulator.studies {
                var series: [ScannedSeries] = []
                series.reserveCapacity(studyAccumulator.series.count)

                for seriesAccumulator: SeriesAccumulator in studyAccumulator.series {
                    series.append(ScannedSeries(
                        seriesInstanceUID: seriesAccumulator.seriesInstanceUID,
                        seriesNumber: seriesAccumulator.seriesNumber,
                        description: seriesAccumulator.description,
                        modality: seriesAccumulator.modality,
                        instances: seriesAccumulator.instances,
                        rows: seriesAccumulator.rows,
                        columns: seriesAccumulator.columns,
                        pixelSpacingMM: seriesAccumulator.pixelSpacingMM,
                        sliceThicknessMM: seriesAccumulator.sliceThicknessMM,
                        isImageSeries: seriesAccumulator.isImageSeries))
                }

                studies.append(ScannedStudy(
                    studyInstanceUID: studyAccumulator.studyInstanceUID,
                    date: studyAccumulator.date,
                    description: studyAccumulator.description,
                    series: series))
            }

            patients.append(ScannedPatient(
                patientID: patientAccumulator.patientID,
                name: patientAccumulator.name,
                birthDate: patientAccumulator.birthDate,
                studies: studies))
        }
        return patients
    }
}

private struct InstanceMetadata {
    let patientKey: String
    let patientID: String
    let patientName: String?
    let patientBirthDate: String?
    let studyInstanceUID: String
    let studyDate: String?
    let studyDescription: String?
    let seriesInstanceUID: String
    let seriesNumber: Int?
    let seriesDescription: String?
    let modality: String?
    let rows: Int?
    let columns: Int?
    let pixelSpacing: PixelSpacing?
    let sliceThickness: Double?
    let isImageSeries: Bool
    let instance: ScannedInstance
}

private struct SeriesAccumulator {
    let seriesInstanceUID: String
    let seriesNumber: Int?
    let description: String?
    let modality: String?
    var instances: [ScannedInstance]
    let rows: Int?
    let columns: Int?
    let pixelSpacingMM: PixelSpacing?
    let sliceThicknessMM: Double?
    let isImageSeries: Bool
}

private struct StudyAccumulator {
    let studyInstanceUID: String
    let date: String?
    let description: String?
    var series: [SeriesAccumulator]
    var seriesIndices: [String: Int]
}

private struct PatientAccumulator {
    let patientID: String
    let name: String?
    let birthDate: String?
    var studies: [StudyAccumulator]
    var studyIndices: [String: Int]
}
