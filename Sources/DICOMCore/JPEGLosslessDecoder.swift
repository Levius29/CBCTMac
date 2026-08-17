import Foundation

/// Decodifica JPEG Lossless, processo 14, inclusa la variante SV1.
///
/// Il decoder implementa soltanto SOF3: le varianti DCT e aritmetiche sono codec diversi e
/// tentare di leggerle come lossless produrrebbe valori plausibili ma falsi. Il flusso entropy
/// gestisce inoltre byte stuffing e restart marker prima di esporre i bit al decoder Huffman.
public struct JPEGLosslessDecoder: PixelDecoder {
    public init() {}

    public func canDecode(_ transferSyntax: TransferSyntax) -> Bool {
        transferSyntax == .jpegLosslessNonHierarchical
            || transferSyntax == .jpegLosslessNonHierarchicalSV1
    }

    public func decode(
        _ data: Data,
        frameIndex: Int,
        descriptor: PixelDescriptor,
        transferSyntax: TransferSyntax
    ) throws -> DecodedFrame {
        guard canDecode(transferSyntax) else {
            throw PixelDecodingError.unsupportedTransferSyntax(transferSyntax)
        }
        let expectedPixels = try PixelSampleNormalizer.validate(
            descriptor, frameIndex: frameIndex)
        var parser = JPEGMarkerParser(data: data)
        let decoded = try parser.decodeScan(
            expectedColumns: descriptor.columns,
            expectedRows: descriptor.rows,
            expectedPixels: expectedPixels,
            expectedPrecision: descriptor.bitsStored,
            requiresPredictorOne: transferSyntax == .jpegLosslessNonHierarchicalSV1)
        return PixelSampleNormalizer.normalize(decoded, descriptor: descriptor)
    }
}

private struct JPEGFrameInfo {
    let precision: Int
    let rows: Int
    let columns: Int
    let componentID: UInt8
}

private struct JPEGHuffmanEntry {
    let code: Int
    let length: Int
    let symbol: UInt8
}

private struct JPEGHuffmanTable {
    let entries: [JPEGHuffmanEntry]

    func decode(_ reader: inout JPEGEntropyReader) throws -> Int {
        var code = 0
        for length in 1...16 {
            code = (code << 1) | (try reader.readBit())
            for entry in entries where entry.length == length {
                if entry.code == code {
                    return Int(entry.symbol)
                }
            }
        }
        throw PixelDecodingError.malformedCompressedData("codice Huffman JPEG non valido")
    }
}

private struct JPEGMarkerParser {
    let data: Data
    var cursor: Int = 0
    var frame: JPEGFrameInfo?
    var dcTables: [Int: JPEGHuffmanTable] = [:]
    var restartInterval = 0

    mutating func decodeScan(
        expectedColumns: Int,
        expectedRows: Int,
        expectedPixels: Int,
        expectedPrecision: Int,
        requiresPredictorOne: Bool
    ) throws -> [UInt16] {
        guard try readMarker() == 0xD8 else {
            throw malformed("manca il marker SOI")
        }

        while cursor < data.count {
            let marker = try readMarker()
            switch marker {
            case 0xC3:
                frame = try parseSOF3(try readSegment(marker: marker))
            case 0xC4:
                try parseDHT(try readSegment(marker: marker))
            case 0xDD:
                try parseDRI(try readSegment(marker: marker))
            case 0xDA:
                let scan = try parseSOS(try readSegment(marker: marker))
                guard let frame else {
                    throw malformed("SOS incontrato prima di SOF3")
                }
                guard frame.columns == expectedColumns, frame.rows == expectedRows,
                      frame.columns > 0, frame.rows > 0,
                      frame.columns <= Int.max / frame.rows,
                      frame.columns * frame.rows == expectedPixels
                else {
                    throw malformed(
                        "dimensioni JPEG \(frame.columns)×\(frame.rows) diverse dal descrittore "
                            + "\(expectedColumns)×\(expectedRows)")
                }
                guard frame.precision == expectedPrecision else {
                    throw malformed(
                        "precisione JPEG \(frame.precision) diversa da BitsStored "
                            + "\(expectedPrecision)")
                }
                guard scan.componentID == frame.componentID else {
                    throw malformed("il componente SOS non corrisponde a SOF3")
                }
                guard !requiresPredictorOne || scan.predictor == 1 else {
                    throw malformed(
                        "la sintassi JPEG Lossless SV1 richiede Ss = 1, trovato "
                            + "\(scan.predictor)")
                }
                guard let table = dcTables[scan.tableID] else {
                    throw malformed("tabella Huffman DC \(scan.tableID) assente")
                }
                return try decodeEntropy(
                    frame: frame,
                    table: table,
                    predictor: scan.predictor,
                    pointTransform: scan.pointTransform)
            case 0xD9:
                throw malformed("EOI incontrato prima di SOS")
            case 0xE0...0xEF, 0xFE:
                _ = try readSegment(marker: marker)
            case 0xC0, 0xC1, 0xC2, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB,
                 0xCD, 0xCE, 0xCF:
                throw malformed(
                    String(format: "marker SOF non lossless FFC%X non supportato", marker & 0x0F))
            default:
                throw malformed(String(format: "marker JPEG FF%02X non supportato", marker))
            }
        }
        throw malformed("flusso JPEG terminato prima di SOS")
    }

    private mutating func parseSOF3(_ bytes: Data) throws -> JPEGFrameInfo {
        guard bytes.count >= 6 else { throw malformed("segmento SOF3 troncato") }
        let precision = Int(bytes[0])
        let rows = Int(readUInt16BE(bytes, at: 1))
        let columns = Int(readUInt16BE(bytes, at: 3))
        let componentCount = Int(bytes[5])
        guard precision >= 2, precision <= 16 else {
            throw malformed("precisione JPEG \(precision) non valida")
        }
        guard componentCount == 1 else {
            throw PixelDecodingError.unsupportedSamplesPerPixel(componentCount)
        }
        guard bytes.count == 6 + componentCount * 3 else {
            throw malformed("lunghezza SOF3 incoerente con i componenti")
        }
        let sampling = bytes[7]
        guard sampling == 0x11 else {
            throw malformed("campionamento JPEG lossless diverso da 1×1")
        }
        return JPEGFrameInfo(
            precision: precision,
            rows: rows,
            columns: columns,
            componentID: bytes[6])
    }

    private mutating func parseDHT(_ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 17 else {
                throw malformed("segmento DHT troncato")
            }
            let tableInfo = bytes[offset]
            offset += 1
            let tableClass = Int(tableInfo >> 4)
            let tableID = Int(tableInfo & 0x0F)
            var counts = [Int](repeating: 0, count: 16)
            var symbolCount = 0
            for index in 0..<16 {
                counts[index] = Int(bytes[offset + index])
                symbolCount += counts[index]
            }
            offset += 16
            guard symbolCount <= bytes.count - offset else {
                throw malformed("valori HUFFVAL troncati")
            }

            var entries: [JPEGHuffmanEntry] = []
            entries.reserveCapacity(symbolCount)
            var code = 0
            var symbolOffset = offset
            for length in 1...16 {
                let count = counts[length - 1]
                for _ in 0..<count {
                    guard code < (1 << length) else {
                        throw malformed("tabella Huffman sovraccarica")
                    }
                    entries.append(
                        JPEGHuffmanEntry(
                            code: code, length: length, symbol: bytes[symbolOffset]))
                    symbolOffset += 1
                    code += 1
                }
                code <<= 1
            }
            offset += symbolCount
            if tableClass == 0 {
                dcTables[tableID] = JPEGHuffmanTable(entries: entries)
            } else if tableClass != 1 {
                throw malformed("classe Huffman \(tableClass) non valida")
            }
            // Le tabelle AC sono lecite in un contenitore JPEG, ma SOF3 non le usa.
        }
    }

    private mutating func parseDRI(_ bytes: Data) throws {
        guard bytes.count == 2 else { throw malformed("segmento DRI di lunghezza non valida") }
        restartInterval = Int(readUInt16BE(bytes, at: 0))
    }

    private mutating func parseSOS(_ bytes: Data) throws -> JPEGScanInfo {
        guard bytes.count >= 6 else { throw malformed("segmento SOS troncato") }
        let componentCount = Int(bytes[0])
        guard componentCount == 1 else {
            throw PixelDecodingError.unsupportedSamplesPerPixel(componentCount)
        }
        guard bytes.count == 1 + componentCount * 2 + 3 else {
            throw malformed("lunghezza SOS incoerente con i componenti")
        }
        let selector = bytes[2]
        let dcTable = Int(selector >> 4)
        let acTable = selector & 0x0F
        let predictor = Int(bytes[3])
        let spectralEnd = bytes[4]
        let approximation = bytes[5]
        guard acTable == 0, spectralEnd == 0, (approximation >> 4) == 0 else {
            throw malformed("parametri SOS non validi per JPEG lossless")
        }
        guard predictor >= 1, predictor <= 7 else {
            throw malformed("selettore di predizione Ss = \(predictor) non valido")
        }
        return JPEGScanInfo(
            componentID: bytes[1],
            tableID: dcTable,
            predictor: predictor,
            pointTransform: Int(approximation & 0x0F))
    }

    private func decodeEntropy(
        frame: JPEGFrameInfo,
        table: JPEGHuffmanTable,
        predictor: Int,
        pointTransform: Int
    ) throws -> [UInt16] {
        let reducedPrecision = frame.precision - pointTransform
        guard reducedPrecision > 0, reducedPrecision <= 16 else {
            throw malformed("trasformazione puntuale Al = \(pointTransform) non valida")
        }
        let mask = (1 << reducedPrecision) - 1
        let initialPrediction = 1 << (reducedPrecision - 1)
        let pixelCount = frame.columns * frame.rows
        var reduced = [Int](repeating: 0, count: pixelCount)
        var reader = JPEGEntropyReader(data: data, offset: cursor)
        var resetPrediction = false
        var expectedRestart = 0

        for index in 0..<pixelCount {
            if restartInterval > 0, index > 0, index % restartInterval == 0 {
                try reader.consumeRestart(expected: expectedRestart)
                expectedRestart = (expectedRestart + 1) & 7
                resetPrediction = true
            }

            let category = try table.decode(&reader)
            guard category >= 0, category <= 16 else {
                throw malformed("categoria Huffman \(category) non valida")
            }
            let difference: Int
            if category == 0 {
                difference = 0
            } else if category == 16 {
                difference = 32768
            } else {
                let bits = try reader.readBits(category)
                if bits < (1 << (category - 1)) {
                    difference = bits + ((-1 << category) + 1)
                } else {
                    difference = bits
                }
            }

            let row = index / frame.columns
            let column = index % frame.columns
            let prediction: Int
            if resetPrediction || (row == 0 && column == 0) {
                prediction = initialPrediction
                resetPrediction = false
            } else if column == 0 {
                // All'inizio di ogni riga si usa sempre Rb. Applicare qui il selettore Ss
                // inclina l'intera immagine e somiglia ingannevolmente a un artefatto scanner.
                prediction = reduced[index - frame.columns]
            } else if row == 0 {
                prediction = reduced[index - 1]
            } else {
                let ra = reduced[index - 1]
                let rb = reduced[index - frame.columns]
                let rc = reduced[index - frame.columns - 1]
                prediction = predict(selector: predictor, ra: ra, rb: rb, rc: rc)
            }
            reduced[index] = (prediction + difference) & mask
        }

        try reader.consumeEndOfImage()

        var words: [UInt16] = []
        words.reserveCapacity(pixelCount)
        let fullMask = frame.precision == 16 ? UInt16.max : UInt16((1 << frame.precision) - 1)
        for value in reduced {
            let shifted = UInt16(truncatingIfNeeded: value << pointTransform) & fullMask
            words.append(shifted)
        }
        return words
    }

    private func predict(selector: Int, ra: Int, rb: Int, rc: Int) -> Int {
        switch selector {
        case 1: return ra
        case 2: return rb
        case 3: return rc
        case 4: return ra + rb - rc
        case 5: return ra + ((rb - rc) >> 1)
        case 6: return rb + ((ra - rc) >> 1)
        default: return (ra + rb) >> 1
        }
    }

    private mutating func readMarker() throws -> UInt8 {
        guard cursor < data.count, data[cursor] == 0xFF else {
            throw malformed("marker JPEG atteso all'offset \(cursor)")
        }
        while cursor < data.count, data[cursor] == 0xFF { cursor += 1 }
        guard cursor < data.count else { throw malformed("marker JPEG troncato") }
        let marker = data[cursor]
        cursor += 1
        guard marker != 0 else { throw malformed("byte stuffed fuori dal flusso entropy") }
        return marker
    }

    private mutating func readSegment(marker: UInt8) throws -> Data {
        guard cursor <= data.count - 2 else {
            throw malformed(String(format: "segmento FF%02X troncato", marker))
        }
        let length = Int(readUInt16BE(data, at: cursor))
        cursor += 2
        guard length >= 2, length - 2 <= data.count - cursor else {
            throw malformed(String(format: "lunghezza non valida per il segmento FF%02X", marker))
        }
        let end = cursor + length - 2
        let result = data.subdata(in: cursor..<end)
        cursor = end
        return result
    }

    private func readUInt16BE(_ bytes: Data, at offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    private func malformed(_ detail: String) -> PixelDecodingError {
        PixelDecodingError.malformedCompressedData("JPEG Lossless: \(detail)")
    }
}

private struct JPEGScanInfo {
    let componentID: UInt8
    let tableID: Int
    let predictor: Int
    let pointTransform: Int
}

private struct JPEGEntropyReader {
    let data: Data
    var offset: Int
    var currentByte: UInt8 = 0
    var remainingBits = 0

    mutating func readBit() throws -> Int {
        if remainingBits == 0 {
            currentByte = try readEntropyByte()
            remainingBits = 8
        }
        remainingBits -= 1
        return Int((currentByte >> remainingBits) & 1)
    }

    mutating func readBits(_ count: Int) throws -> Int {
        var value = 0
        for _ in 0..<count {
            value = (value << 1) | (try readBit())
        }
        return value
    }

    mutating func consumeRestart(expected: Int) throws {
        // I bit di riempimento fino al confine di byte non fanno parte del prossimo MCU.
        remainingBits = 0
        guard offset < data.count, data[offset] == 0xFF else {
            throw malformed("restart marker atteso all'offset \(offset)")
        }
        while offset < data.count, data[offset] == 0xFF { offset += 1 }
        guard offset < data.count else { throw malformed("restart marker troncato") }
        let marker = data[offset]
        offset += 1
        guard marker == UInt8(0xD0 + expected) else {
            throw malformed(
                String(format: "atteso RST%d, trovato FF%02X", expected, marker))
        }
    }

    mutating func consumeEndOfImage() throws {
        remainingBits = 0
        guard offset < data.count, data[offset] == 0xFF else {
            throw malformed("marker EOI atteso all'offset \(offset)")
        }
        while offset < data.count, data[offset] == 0xFF { offset += 1 }
        guard offset < data.count else { throw malformed("marker EOI troncato") }
        let marker = data[offset]
        offset += 1
        guard marker == 0xD9 else {
            throw malformed(String(format: "atteso EOI, trovato FF%02X", marker))
        }
    }

    private mutating func readEntropyByte() throws -> UInt8 {
        guard offset < data.count else { throw malformed("flusso entropy troncato") }
        let value = data[offset]
        offset += 1
        guard value == 0xFF else { return value }
        guard offset < data.count else { throw malformed("0xFF finale nel flusso entropy") }
        let following = data[offset]
        offset += 1
        if following == 0x00 {
            // Byte stuffing: FF 00 rappresenta un singolo byte dati FF.
            return 0xFF
        }
        throw malformed(String(format: "marker FF%02X incontrato dentro un codice Huffman", following))
    }

    private func malformed(_ detail: String) -> PixelDecodingError {
        PixelDecodingError.malformedCompressedData("JPEG Lossless: \(detail)")
    }
}
