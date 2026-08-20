import Foundation
import Testing

@testable import DICOMCore

// Il DICOMDIR.
//
// # Come si prova una lista concatenata di scostamenti
//
// Percorrendola. Il test legge il file come lo leggerebbe un visore: parte dallo scostamento del
// primo record di radice, verifica che lì cominci davvero un item, ne legge il tipo, scende al
// figlio, e dal primo figlio segue i «successivo» fino allo zero finale. Se un solo scostamento è
// sbagliato di un byte, la lettura cade fuori da un item e il test se ne accorge — che è
// esattamente ciò che farebbe il visore, ma senza doverlo aprire.
//
// Il lettore è scritto qui dentro e non condivide codice con lo scrittore: non possono sbagliare
// insieme.

@Suite("DICOMDIR")
struct DICOMDIRWriterTests {

    /// Un lettore minimo di elementi Explicit VR Little Endian.
    struct Reader {
        let bytes: [UInt8]

        init(_ data: Data) { bytes = [UInt8](data) }

        func uint16(_ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
        func uint32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 24
        }

        /// Vero se a questo scostamento comincia un item `(FFFE,E000)`.
        func isItem(at offset: Int) -> Bool {
            guard offset >= 0, offset + 8 <= bytes.count else { return false }
            return uint16(offset) == 0xFFFE && uint16(offset + 2) == 0xE000
        }

        /// Gli elementi di un item, dal suo scostamento: mappa «gruppo,elemento» → byte.
        func item(at offset: Int) -> (elements: [String: [UInt8]], length: Int)? {
            guard isItem(at: offset) else { return nil }
            let length = uint32(offset + 4)
            let start = offset + 8
            guard start + length <= bytes.count else { return nil }
            return (elements(from: start, count: length), length)
        }

        func elements(from start: Int, count: Int) -> [String: [UInt8]] {
            var result: [String: [UInt8]] = [:]
            var cursor = start
            let end = start + count
            while cursor + 8 <= end {
                let group = uint16(cursor)
                let element = uint16(cursor + 2)
                let vr = String(decoding: bytes[(cursor + 4)..<(cursor + 6)], as: UTF8.self)
                let longForm = ["OB", "OW", "OF", "SQ", "UT", "UN"].contains(vr)
                let valueLength = longForm ? uint32(cursor + 8) : uint16(cursor + 6)
                let valueStart = cursor + (longForm ? 12 : 8)
                guard valueStart + valueLength <= end else { break }
                let key = String(format: "%04X,%04X", group, element)
                result[key] = Array(bytes[valueStart..<(valueStart + valueLength)])
                cursor = valueStart + valueLength
            }
            return result
        }

        func text(_ elements: [String: [UInt8]], _ key: String) -> String? {
            guard let value = elements[key] else { return nil }
            return String(decoding: value, as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: " \0"))
        }

        func offset(_ elements: [String: [UInt8]], _ key: String) -> Int? {
            guard let value = elements[key], value.count == 4 else { return nil }
            return Int(value[0]) | Int(value[1]) << 8 | Int(value[2]) << 16 | Int(value[3]) << 24
        }

        /// Gli elementi del dataset del file-set, cioè quelli fuori dalla sequenza.
        func fileSetElements() -> [String: [UInt8]] {
            // Dopo il preambolo e `DICM` c'è la lunghezza del gruppo 0002, poi il gruppo, poi il
            // dataset. Si salta il gruppo usando la lunghezza dichiarata.
            let groupLengthValueAt = 132 + 8
            let metaLength = uint32(groupLengthValueAt)
            let datasetStart = groupLengthValueAt + 4 + metaLength
            return elements(from: datasetStart, count: bytes.count - datasetStart)
        }
    }

    static func images(_ count: Int) -> [DICOMDIRWriter.ImageEntry] {
        (1...count).map { index in
            DICOMDIRWriter.ImageEntry(
                fileID: String(format: "IM%05d.dcm", index),
                sopClassUID: DICOMWriter.ctImageStorage,
                sopInstanceUID: "1.2.3.4.\(index)",
                transferSyntaxUID: DICOMWriter.explicitVRLittleEndian,
                instanceNumber: index)
        }
    }

    static func makeDICOMDIR(imageCount: Int = 5) -> Data {
        DICOMDIRWriter.data(
            identity: DICOMExportIdentity(
                patientName: "Rossi^Mario", patientID: "PZ-1",
                studyInstanceUID: "1.2.3", studyDate: "20240312", studyTime: "101500",
                studyDescription: "CBCT mascellare"),
            studyInstanceUID: "1.2.3",
            seriesInstanceUID: "1.2.3.9",
            images: images(imageCount))
    }

    @Test("Il file comincia col preambolo e dichiara di essere una directory")
    func theFileAnnouncesItselfAsADirectory() {
        let reader = Reader(Self.makeDICOMDIR())
        #expect(reader.bytes.count > 132)
        #expect(reader.bytes[0..<128].allSatisfy { $0 == 0 })
        #expect(String(decoding: reader.bytes[128..<132], as: UTF8.self) == "DICM")

        let meta = reader.elements(from: 132, count: 200)
        #expect(reader.text(meta, "0002,0002") == DICOMDIRWriter.mediaStorageDirectoryStorage)
        #expect(reader.text(meta, "0002,0010") == DICOMWriter.explicitVRLittleEndian)
    }

    @Test("Lo scostamento di radice cade su un item, e quell'item è il paziente")
    func theRootOffsetLandsOnThePatientRecord() throws {
        let data = Self.makeDICOMDIR()
        let reader = Reader(data)
        let fileSet = reader.fileSetElements()

        #expect(reader.text(fileSet, "0004,1130") == "CBCT")
        let first = try #require(reader.offset(fileSet, "0004,1200"))
        let last = try #require(reader.offset(fileSet, "0004,1202"))
        // Un paziente solo: primo e ultimo record di radice coincidono.
        #expect(first == last)

        let patient = try #require(reader.item(at: first)?.elements)
        #expect(reader.text(patient, "0004,1430") == "PATIENT")
        #expect(reader.text(patient, "0010,0010") == "Rossi^Mario")
        #expect(reader.text(patient, "0010,0020") == "PZ-1")
        // Il paziente è l'unico alla radice: nessun successivo.
        #expect(reader.offset(patient, "0004,1400") == 0)
    }

    @Test("La discesa paziente → studio → serie → immagine arriva in fondo")
    func theHierarchyCanBeWalkedDown() throws {
        let data = Self.makeDICOMDIR()
        let reader = Reader(data)
        let fileSet = reader.fileSetElements()

        let patientOffset = try #require(reader.offset(fileSet, "0004,1200"))
        let patient = try #require(reader.item(at: patientOffset)?.elements)

        let studyOffset = try #require(reader.offset(patient, "0004,1420"))
        let study = try #require(reader.item(at: studyOffset)?.elements)
        #expect(reader.text(study, "0004,1430") == "STUDY")
        #expect(reader.text(study, "0020,000D") == "1.2.3")
        #expect(reader.text(study, "0008,0020") == "20240312")

        let seriesOffset = try #require(reader.offset(study, "0004,1420"))
        let series = try #require(reader.item(at: seriesOffset)?.elements)
        #expect(reader.text(series, "0004,1430") == "SERIES")
        #expect(reader.text(series, "0020,000E") == "1.2.3.9")
        #expect(reader.text(series, "0008,0060") == "CT")

        let firstImageOffset = try #require(reader.offset(series, "0004,1420"))
        let firstImage = try #require(reader.item(at: firstImageOffset)?.elements)
        #expect(reader.text(firstImage, "0004,1430") == "IMAGE")
        #expect(reader.text(firstImage, "0004,1500") == "IM00001.dcm")
    }

    @Test("La catena delle immagini le tocca tutte, in ordine, e finisce")
    func theImageChainVisitsEveryImageInOrder() throws {
        // È il controllo che conta: uno scostamento sbagliato di un byte fa cadere la lettura
        // fuori da un item, e uno scostamento che punta indietro farebbe girare a vuoto un
        // visore. Qui il ciclo ha un tetto, e se lo tocca il test fallisce.
        let count = 12
        let data = Self.makeDICOMDIR(imageCount: count)
        let reader = Reader(data)
        let fileSet = reader.fileSetElements()

        let patientOffset = try #require(reader.offset(fileSet, "0004,1200"))
        let patient = try #require(reader.item(at: patientOffset)?.elements)
        let studyOffset = try #require(reader.offset(patient, "0004,1420"))
        let study = try #require(reader.item(at: studyOffset)?.elements)
        let seriesOffset = try #require(reader.offset(study, "0004,1420"))
        let series = try #require(reader.item(at: seriesOffset)?.elements)

        var visited: [String] = []
        var cursor = try #require(reader.offset(series, "0004,1420"))
        var guardCount = 0
        while cursor != 0 {
            guardCount += 1
            #expect(guardCount <= count, "la catena non finisce")
            guard guardCount <= count else { break }

            let record = try #require(reader.item(at: cursor)?.elements, "scostamento \(cursor)")
            #expect(reader.text(record, "0004,1430") == "IMAGE")
            visited.append(try #require(reader.text(record, "0004,1500")))
            #expect(reader.text(record, "0004,1510") == DICOMWriter.ctImageStorage)
            #expect(reader.text(record, "0004,1512") == DICOMWriter.explicitVRLittleEndian)
            cursor = try #require(reader.offset(record, "0004,1400"))
        }

        #expect(visited.count == count)
        #expect(visited == (1...count).map { String(format: "IM%05d.dcm", $0) })
    }

    @Test("Ogni record dichiara di essere in uso")
    func everyRecordIsMarkedInUse() throws {
        let data = Self.makeDICOMDIR(imageCount: 4)
        let reader = Reader(data)
        let fileSet = reader.fileSetElements()

        let rootOffset = try #require(reader.offset(fileSet, "0004,1200"))
        var offsets = [rootOffset]
        var index = 0
        while index < offsets.count {
            let record = try #require(reader.item(at: offsets[index])?.elements)
            let flag = try #require(record["0004,1410"])
            // 0xFFFF: zero significherebbe cancellato, e un lettore salterebbe il record.
            #expect(flag == [0xFF, 0xFF])
            for key in ["0004,1400", "0004,1420"] {
                if let next = reader.offset(record, key), next != 0 { offsets.append(next) }
            }
            index += 1
        }
        // Paziente, studio, serie e quattro immagini.
        #expect(offsets.count == 7)
    }

    @Test("Una serie senza immagini resta un file valido")
    func aSeriesWithNoImagesIsStillValid() throws {
        let data = DICOMDIRWriter.data(
            identity: DICOMExportIdentity(patientName: "Vuoto"),
            studyInstanceUID: "1.2.3", seriesInstanceUID: "1.2.3.9", images: [])
        let reader = Reader(data)
        let fileSet = reader.fileSetElements()

        let patientOffset = try #require(reader.offset(fileSet, "0004,1200"))
        let patient = try #require(reader.item(at: patientOffset)?.elements)
        let studyOffset = try #require(reader.offset(patient, "0004,1420"))
        let study = try #require(reader.item(at: studyOffset)?.elements)
        let seriesOffset = try #require(reader.offset(study, "0004,1420"))
        let series = try #require(reader.item(at: seriesOffset)?.elements)
        // La serie non ha figli, e lo dice con uno zero invece che con uno scostamento a caso.
        #expect(reader.offset(series, "0004,1420") == 0)
    }

    @Test("Il nome del file-set non è più lungo di quanto CS permetta")
    func theFileSetIDFitsItsValueRepresentation() {
        // `CS` ammette sedici caratteri. Un nome più lungo verrebbe scritto per intero e
        // renderebbe il file non conforme senza che nulla lo segnali.
        #expect(DICOMDIRWriter.defaultFileSetID.count <= 16)
    }
}
