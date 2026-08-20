import Foundation

// Il DICOMDIR: l'indice che trasforma una cartella di file in un supporto DICOM.
//
// # Perché non basta la cartella
//
// Perché senza indice chi la riceve deve aprire ogni file per sapere che cosa c'è dentro. Con
// l'indice, un lettore mostra subito paziente, studio e serie e apre solo ciò che gli si chiede.
// È la differenza fra «una cartella di file» e «un supporto che si consegna»: ogni PACS e ogni
// visore cerca prima il DICOMDIR.
//
// # La parte che si sbaglia: gli scostamenti
//
// I record sono una lista concatenata fatta di **scostamenti in byte dall'inizio del file**. Ogni
// record dice dove comincia il successivo dello stesso livello e dove comincia il primo dei suoi
// figli, e l'intestazione del file-set dice dove cominciano il primo e l'ultimo record di radice.
//
// Il che è circolare in apparenza: per scrivere gli scostamenti bisogna sapere quanto è lungo
// tutto, e per sapere quanto è lungo bisogna averlo scritto. Non lo è, perché gli scostamenti
// sono `UL` a lunghezza fissa: si compongono i record una prima volta con scostamenti a zero per
// misurarli, si calcola dove cadranno, e li si ricompone con i valori veri. La seconda passata ha
// esattamente la stessa lunghezza della prima, e questa è la ragione per cui il metodo funziona.
//
// # Una deviazione dichiarata
//
// Il profilo per i supporti ottici vuole nomi di file di otto caratteri senza estensione. Qui i
// file si chiamano `IM00001.dcm`, con l'estensione, perché la cartella la si apre quasi sempre su
// un computer e un file senza estensione non lo apre nessuno con due clic. È la scelta che fanno
// quasi tutti i supporti su chiavetta, e i lettori la accettano; su un CD da masterizzare secondo
// il profilo stretto non sarebbe conforme.

public enum DICOMDIRWriter: Sendable {

    /// SOP Class del Media Storage Directory Storage, cioè del DICOMDIR stesso.
    public static let mediaStorageDirectoryStorage = "1.2.840.10008.1.3.10"

    /// Il nome predefinito del file-set. `CS` ammette sedici caratteri.
    public static let defaultFileSetID = "CBCT"

    /// Una fetta da indicizzare.
    public struct ImageEntry: Hashable, Sendable {
        /// Il nome del file relativo alla cartella del DICOMDIR.
        public var fileID: String
        public var sopClassUID: String
        public var sopInstanceUID: String
        public var transferSyntaxUID: String
        public var instanceNumber: Int

        public init(
            fileID: String, sopClassUID: String, sopInstanceUID: String,
            transferSyntaxUID: String, instanceNumber: Int
        ) {
            self.fileID = fileID
            self.sopClassUID = sopClassUID
            self.sopInstanceUID = sopInstanceUID
            self.transferSyntaxUID = transferSyntaxUID
            self.instanceNumber = instanceNumber
        }
    }

    /// Compone il DICOMDIR di una singola serie.
    ///
    /// Un paziente, uno studio, una serie e le sue immagini: è la forma di ciò che questo
    /// programma esporta. Un file-set con più studi si comporrebbe allo stesso modo, con più
    /// record allo stesso livello, e la lista concatenata è già scritta per reggerlo.
    public static func data(
        identity: DICOMExportIdentity,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        modality: String = "CT",
        fileSetID: String = defaultFileSetID,
        images: [ImageEntry]
    ) -> Data {
        var records = buildRecords(
            identity: identity, studyInstanceUID: studyInstanceUID,
            seriesInstanceUID: seriesInstanceUID, modality: modality, images: images)

        // Dove comincia il primo record. Il preambolo, `DICM`, il gruppo 0002 e i primi quattro
        // elementi del dataset stanno tutti prima, e hanno lunghezza nota una volta composti.
        let meta = metaGroup()
        var prefix = Data(repeating: 0, count: 128)
        prefix.append(contentsOf: Array("DICM".utf8))
        DICOMWriter.append(
            &prefix, DICOMTags.fileMetaGroupLength, .UL, uint32: UInt32(meta.count))
        prefix.append(meta)
        prefix.append(fileSetElements(fileSetID: fileSetID, firstRoot: 0, lastRoot: 0))

        // L'intestazione della sequenza in Explicit VR: tag, «SQ», due byte riservati, lunghezza
        // a 32 bit. Dodici byte.
        let sequenceHeaderLength = 12
        // L'intestazione di un item **non** porta il VR nemmeno in Explicit VR: tag e lunghezza,
        // otto byte. Scriverla come un elemento qualunque aggiungerebbe quattro byte a ogni
        // record, e ogni scostamento cadrebbe in mezzo al record sbagliato.
        let itemHeaderLength = 8

        var cursor = prefix.count + sequenceHeaderLength
        var offsets: [UInt32] = []
        for record in records {
            offsets.append(UInt32(cursor))
            cursor += itemHeaderLength + record.bytes.count
        }

        // Gli scostamenti si scrivono **dentro** i record già composti, ai quattro byte del loro
        // valore. Ricomporli con i valori veri funzionerebbe soltanto finché la seconda passata
        // resta lunga come la prima — invariante vera ma da mantenere; sovrascrivere quattro
        // byte non ha invarianti da mantenere.
        for index in records.indices {
            records[index].patch(records[index].nextIndex.map { offsets[$0] } ?? 0, at: .next)
            records[index].patch(records[index].childIndex.map { offsets[$0] } ?? 0, at: .child)
        }

        var file = Data(repeating: 0, count: 128)
        file.append(contentsOf: Array("DICM".utf8))
        DICOMWriter.append(
            &file, DICOMTags.fileMetaGroupLength, .UL, uint32: UInt32(meta.count))
        file.append(meta)
        // Il primo e l'ultimo record **di radice**: qui c'è un solo paziente, quindi coincidono.
        // Con più pazienti l'ultimo sarebbe l'ultimo di essi, non l'ultimo record in assoluto —
        // che è un'immagine, e non sta alla radice.
        file.append(
            fileSetElements(
                fileSetID: fileSetID, firstRoot: offsets.first ?? 0,
                lastRoot: offsets.first ?? 0))

        var sequence = Data()
        for record in records {
            appendItemHeader(&sequence, length: record.bytes.count)
            sequence.append(record.bytes)
        }
        DICOMWriter.appendHeader(
            &file, DICOMTags.directoryRecordSequence, .SQ, length: sequence.count)
        file.append(sequence)
        return file
    }

    // MARK: Composizione

    /// Un record in costruzione: i byte, e dove stanno dentro di essi i due scostamenti.
    private struct Record {
        enum Field { case next, child }

        var bytes: Data
        /// Posizione, dentro `bytes`, dei quattro byte del valore di `OffsetOfTheNextRecord`.
        var nextValueAt: Int
        /// Idem per `OffsetOfTheReferencedLowerLevelDirectoryEntity`.
        var childValueAt: Int
        /// Indice del record successivo dello stesso livello, o `nil` se è l'ultimo.
        var nextIndex: Int?
        /// Indice del primo record figlio, o `nil` se non ne ha.
        var childIndex: Int?

        mutating func patch(_ value: UInt32, at field: Field) {
            let start = field == .next ? nextValueAt : childValueAt
            for byte in 0..<4 {
                bytes[bytes.startIndex + start + byte] =
                    UInt8((value >> UInt32(byte * 8)) & 0xFF)
            }
        }
    }

    private static func fileSetElements(
        fileSetID: String, firstRoot: UInt32, lastRoot: UInt32
    ) -> Data {
        var data = Data()
        DICOMWriter.append(&data, DICOMTags.fileSetID, .CS, text: fileSetID)
        DICOMWriter.append(&data, DICOMTags.offsetOfFirstRootRecord, .UL, uint32: firstRoot)
        DICOMWriter.append(&data, DICOMTags.offsetOfLastRootRecord, .UL, uint32: lastRoot)
        DICOMWriter.append(&data, DICOMTags.fileSetConsistencyFlag, .US, uint16: 0)
        return data
    }

    /// L'intestazione di un item: tag e lunghezza, senza VR.
    private static func appendItemHeader(_ data: inout Data, length: Int) {
        let tag = DICOMTags.item
        data.append(UInt8(tag.group & 0xFF))
        data.append(UInt8((tag.group >> 8) & 0xFF))
        data.append(UInt8(tag.element & 0xFF))
        data.append(UInt8((tag.element >> 8) & 0xFF))
        let value = UInt32(length)
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8((value >> UInt32(shift)) & 0xFF))
        }
    }

    private static func metaGroup() -> Data {
        var meta = Data()
        DICOMWriter.append(
            &meta, DICOMTags.mediaStorageSOPClassUID, .UI, text: mediaStorageDirectoryStorage)
        DICOMWriter.append(
            &meta, DICOMTags.mediaStorageSOPInstanceUID, .UI, text: DICOMWriter.newUID())
        DICOMWriter.append(
            &meta, DICOMTags.transferSyntaxUID, .UI,
            text: DICOMWriter.explicitVRLittleEndian)
        return meta
    }

    /// I record, nell'ordine paziente, studio, serie, immagini.
    private static func buildRecords(
        identity: DICOMExportIdentity,
        studyInstanceUID: String,
        seriesInstanceUID: String,
        modality: String,
        images: [ImageEntry]
    ) -> [Record] {
        // Indici dentro l'elenco: 0 paziente, 1 studio, 2 serie, 3… immagini.
        let firstImage = 3
        var result: [Record] = []

        var patient = newRecord(type: "PATIENT", next: nil, child: 1)
        DICOMWriter.append(&patient.bytes, DICOMTags.patientName, .PN, text: identity.patientName)
        DICOMWriter.append(&patient.bytes, DICOMTags.patientID, .LO, text: identity.patientID)
        result.append(patient)

        var study = newRecord(type: "STUDY", next: nil, child: 2)
        DICOMWriter.append(&study.bytes, DICOMTags.studyDate, .DA, text: identity.studyDate)
        DICOMWriter.append(&study.bytes, DICOMTags.studyTime, .TM, text: identity.studyTime)
        DICOMWriter.append(
            &study.bytes, DICOMTags.studyDescription, .LO, text: identity.studyDescription)
        DICOMWriter.append(&study.bytes, DICOMTags.studyID, .SH, text: "1")
        DICOMWriter.append(
            &study.bytes, DICOMTags.studyInstanceUID, .UI, text: studyInstanceUID)
        result.append(study)

        var series = newRecord(
            type: "SERIES", next: nil, child: images.isEmpty ? nil : firstImage)
        DICOMWriter.append(&series.bytes, DICOMTags.modality, .CS, text: modality)
        DICOMWriter.append(
            &series.bytes, DICOMTags.seriesInstanceUID, .UI, text: seriesInstanceUID)
        DICOMWriter.append(&series.bytes, DICOMTags.seriesNumber, .IS, text: "1")
        result.append(series)

        for (index, image) in images.enumerated() {
            let isLast = index == images.count - 1
            var record = newRecord(
                type: "IMAGE", next: isLast ? nil : firstImage + index + 1, child: nil)
            DICOMWriter.append(
                &record.bytes, DICOMTags.referencedFileID, .CS, text: image.fileID)
            DICOMWriter.append(
                &record.bytes, DICOMTags.referencedSOPClassUIDInFile, .UI,
                text: image.sopClassUID)
            DICOMWriter.append(
                &record.bytes, DICOMTags.referencedSOPInstanceUIDInFile, .UI,
                text: image.sopInstanceUID)
            DICOMWriter.append(
                &record.bytes, DICOMTags.referencedTransferSyntaxUIDInFile, .UI,
                text: image.transferSyntaxUID)
            DICOMWriter.append(
                &record.bytes, DICOMTags.instanceNumber, .IS, text: String(image.instanceNumber))
            result.append(record)
        }
        return result
    }

    /// Un record nuovo coi suoi quattro elementi comuni, e le posizioni degli scostamenti.
    ///
    /// Un elemento `UL` in Explicit VR occupa otto byte di intestazione — tag, VR, lunghezza —
    /// e poi i quattro byte del valore. La posizione del valore è quindi quella dell'inizio
    /// dell'elemento più otto, e non c'è modo che cambi: è la lunghezza fissa che rende
    /// possibile scrivere gli scostamenti dopo.
    private static func newRecord(type: String, next: Int?, child: Int?) -> Record {
        var bytes = Data()
        let nextAt = bytes.count + 8
        DICOMWriter.append(&bytes, DICOMTags.offsetOfNextRecord, .UL, uint32: 0)
        // 0xFFFF significa «in uso». Zero significherebbe cancellato, e un lettore lo salterebbe.
        DICOMWriter.append(&bytes, DICOMTags.recordInUseFlag, .US, uint16: 0xFFFF)
        let childAt = bytes.count + 8
        DICOMWriter.append(&bytes, DICOMTags.offsetOfLowerLevelEntity, .UL, uint32: 0)
        DICOMWriter.append(&bytes, DICOMTags.directoryRecordType, .CS, text: type)
        return Record(
            bytes: bytes, nextValueAt: nextAt, childValueAt: childAt, nextIndex: next,
            childIndex: child)
    }
}
