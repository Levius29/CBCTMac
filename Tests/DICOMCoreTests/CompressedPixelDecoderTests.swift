import Foundation
import Testing

@testable import DICOMCore

@Suite("PixelData incapsulato")
struct EncapsulatedPixelDataTests {
    @Test("Un frammento per fotogramma")
    func oneFragmentPerFrame() throws {
        let data = encapsulated(bot: [], fragments: [[1, 2], [3, 4]])
        let parsed = try EncapsulatedPixelData.parse(data, sourceName: "due-frame")
        #expect(try parsed.frameData(data, frameIndex: 0, frameCount: 2) == Data([1, 2]))
        #expect(try parsed.frameData(data, frameIndex: 1, frameCount: 2) == Data([3, 4]))
    }

    @Test("Più frammenti formano un singolo fotogramma")
    func multipleFragmentsForOneFrame() throws {
        let data = encapsulated(bot: [], fragments: [[1], [2, 3], [4]])
        let parsed = try EncapsulatedPixelData.parse(data, sourceName: "un-frame")
        #expect(try parsed.frameData(data, frameIndex: 0, frameCount: 1) == Data([1, 2, 3, 4]))
    }

    @Test("La Basic Offset Table prevale sul numero di frammenti")
    func basicOffsetTable() throws {
        // Il secondo frame comincia dal terzo item: 8+2 byte per il primo e 8+3 per il secondo.
        let data = encapsulated(bot: [0, 21], fragments: [[1, 2], [3, 4, 5], [6], [7, 8]])
        let parsed = try EncapsulatedPixelData.parse(data, sourceName: "bot")
        #expect(try parsed.frameData(data, frameIndex: 0, frameCount: 2) == Data([1, 2, 3, 4, 5]))
        #expect(try parsed.frameData(data, frameIndex: 1, frameCount: 2) == Data([6, 7, 8]))
    }

    @Test("Una suddivisione ambigua viene rifiutata")
    func ambiguousFragmentsThrow() throws {
        let data = encapsulated(bot: [], fragments: [[1], [2], [3]])
        let parsed = try EncapsulatedPixelData.parse(data, sourceName: "ambiguo")
        #expect(throws: PixelDecodingError.self) {
            _ = try parsed.frameData(data, frameIndex: 0, frameCount: 2)
        }
    }

    @Test("Una Basic Offset Table parziale non fonde gli ultimi fotogrammi")
    func partialBasicOffsetTableThrows() throws {
        let data = encapsulated(bot: [0, 9], fragments: [[1], [2], [3]])
        let parsed = try EncapsulatedPixelData.parse(data, sourceName: "bot-parziale")
        #expect(throws: PixelDecodingError.self) {
            _ = try parsed.frameData(data, frameIndex: 1, frameCount: 3)
        }
    }
}

@Suite("RLEPixelDecoder")
struct RLEPixelDecoderTests {
    private let decoder = RLEPixelDecoder()

    @Test("Round trip RLE a 8 bit")
    func eightBitRoundTrip() throws {
        let values: [UInt8] = [2, 2, 2, 9, 10, 11, 11, 4]
        let frame = try decoder.decode(
            rleFrame(segments: [packBits(values)]), frameIndex: 0,
            descriptor: descriptor(columns: values.count, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .rleLossless)
        #expect(frame.samples == values.map { Int16($0) })
    }

    @Test("I piani di byte RLE a 16 bit vengono ricomposti MSB poi LSB")
    func sixteenBitBytePlanes() throws {
        let values: [UInt16] = [0x0102, 0x20F0, 0xAB10, 0xFF7E]
        let msb = values.map { UInt8(($0 >> 8) & 0xFF) }
        let lsb = values.map { UInt8($0 & 0xFF) }
        let frame = try decoder.decode(
            rleFrame(segments: [packBits(msb), packBits(lsb)]), frameIndex: 0,
            descriptor: descriptor(columns: values.count, bitsAllocated: 16, bitsStored: 16),
            transferSyntax: .rleLossless)
        let expected = values.map { Int16(clamping: Int32($0) - 32768) }
        #expect(frame.samples == expected)
        #expect(frame.interceptAdjustment == 32768)
    }

    @Test("Run letterale, ripetuto e no-op 128 nello stesso segmento")
    func allPackBitsControls() throws {
        let segment: [UInt8] = [1, 4, 5, 128, 254, 9, 0, 7]
        let frame = try decoder.decode(
            rleFrame(segments: [segment]), frameIndex: 0,
            descriptor: descriptor(columns: 6, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .rleLossless)
        #expect(frame.samples == [4, 5, 9, 9, 9, 7])
    }

    @Test("Un offset RLE corrotto genera un errore")
    func corruptOffsetThrows() {
        var data = rleFrame(segments: [[0, 1]])
        replaceUInt32LE(&data, at: 4, value: UInt32.max)
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                data, frameIndex: 0,
                descriptor: descriptor(columns: 1, bitsAllocated: 8, bitsStored: 8),
                transferSyntax: .rleLossless)
        }
    }

    @Test("BitsStored è normalizzato come nel decoder nativo")
    func bitsStoredNormalisation() throws {
        let values: [UInt16] = [0xF001, 0x0FFF, 0x0800]
        let msb = values.map { UInt8($0 >> 8) }
        let lsb = values.map { UInt8($0 & 0xFF) }
        let frame = try decoder.decode(
            rleFrame(segments: [packBits(msb), packBits(lsb)]), frameIndex: 0,
            descriptor: descriptor(
                columns: 3, bitsAllocated: 16, bitsStored: 12, isSigned: true),
            transferSyntax: .rleLossless)
        #expect(frame.samples == [1, -1, -2048])
    }
}

@Suite("CompositePixelDecoder")
struct CompositePixelDecoderTests {
    @Test("Estrae il fotogramma incapsulato prima di invocare RLE")
    func extractsEncapsulatedFrame() throws {
        let first = rleFrame(segments: [packBits([1, 2, 3])])
        let second = rleFrame(segments: [packBits([7, 8, 9])])
        let itemStream = encapsulated(
            bot: [], fragments: [Array(first), Array(second)])

        // DICOMParser espone PixelData fino a prima del delimitatore di sequenza.
        let withoutDelimiter = itemStream.subdata(in: 0..<(itemStream.count - 8))
        let decoder = CompositePixelDecoder()
        let frame = try decoder.decode(
            withoutDelimiter, frameIndex: 1,
            descriptor: descriptor(
                columns: 3, bitsAllocated: 8, bitsStored: 8, frameCount: 2),
            transferSyntax: .rleLossless)
        #expect(frame.samples == [7, 8, 9])
    }
}

@Suite("JPEGLosslessDecoder")
struct JPEGLosslessDecoderTests {
    private let decoder = JPEGLosslessDecoder()

    @Test("Un SOF3 minimale viene decodificato bit per bit")
    func minimalSOF3() throws {
        let values: [UInt16] = [120, 121, 130, 129]
        let data = jpegLossless(values: values, columns: 2, rows: 2, predictor: 1)
        let frame = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(columns: 2, rows: 2, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .jpegLosslessNonHierarchical)
        #expect(frame.samples == values.map { Int16($0) })
    }

    @Test("Il byte stuffing FF 00 non interrompe il flusso entropy")
    func byteStuffing() throws {
        var selected: ([UInt16], Data)?
        for seed in 0..<4096 {
            var values: [UInt16] = []
            for index in 0..<12 {
                values.append(UInt16((seed * 37 + index * 71) & 0xFF))
            }
            let stream = jpegLossless(values: values, columns: 4, rows: 3, predictor: 4)
            if containsPair(stream, 0xFF, 0x00) {
                selected = (values, stream)
                break
            }
        }
        let pair = try #require(selected)
        let frame = try decoder.decode(
            pair.1, frameIndex: 0,
            descriptor: descriptor(columns: 4, rows: 3, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .jpegLosslessNonHierarchical)
        #expect(frame.samples == pair.0.map { Int16($0) })
    }

    private func verifyPredictor(_ predictor: Int) throws {
        let values: [UInt16] = [100, 104, 111, 98, 109, 117, 95, 108, 121]
        let data = jpegLossless(values: values, columns: 3, rows: 3, predictor: predictor)
        let frame = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(columns: 3, rows: 3, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .jpegLosslessNonHierarchical)
        #expect(frame.samples == values.map { Int16($0) })
    }

    @Test("Predittore JPEG 1 — Ra") func predictor1() throws { try verifyPredictor(1) }
    @Test("Predittore JPEG 2 — Rb") func predictor2() throws { try verifyPredictor(2) }
    @Test("Predittore JPEG 3 — Rc") func predictor3() throws { try verifyPredictor(3) }
    @Test("Predittore JPEG 4 — Ra+Rb−Rc") func predictor4() throws { try verifyPredictor(4) }
    @Test("Predittore JPEG 5") func predictor5() throws { try verifyPredictor(5) }
    @Test("Predittore JPEG 6") func predictor6() throws { try verifyPredictor(6) }
    @Test("Predittore JPEG 7") func predictor7() throws { try verifyPredictor(7) }

    @Test("Il primo campione di riga usa Rb")
    func firstSampleOfLineUsesAbove() throws {
        let values: [UInt16] = [80, 95, 110, 83, 99, 119, 90, 104, 125]
        let data = jpegLossless(values: values, columns: 3, rows: 3, predictor: 7)
        let frame = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(columns: 3, rows: 3, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .jpegLosslessNonHierarchical)
        #expect(frame.samples == values.map { Int16($0) })
    }

    @Test("La sintassi SV1 accetta soltanto il predittore 1")
    func sv1RequiresPredictorOne() throws {
        let valid = jpegLossless(values: [128, 130], columns: 2, rows: 1, predictor: 1)
        let frame = try decoder.decode(
            valid, frameIndex: 0,
            descriptor: descriptor(columns: 2, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .jpegLosslessNonHierarchicalSV1)
        #expect(frame.samples == [128, 130])

        let invalid = jpegLossless(values: [128, 130], columns: 2, rows: 1, predictor: 2)
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                invalid, frameIndex: 0,
                descriptor: descriptor(columns: 2, bitsAllocated: 8, bitsStored: 8),
                transferSyntax: .jpegLosslessNonHierarchicalSV1)
        }
    }

    @Test("I restart marker riallineano bit e predittori")
    func restartMarkers() throws {
        let values: [UInt16] = [100, 105, 111, 98, 103, 109, 90, 96, 102]
        let data = jpegLossless(
            values: values, columns: 3, rows: 3, predictor: 4, restartInterval: 3)
        let frame = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(columns: 3, rows: 3, bitsAllocated: 8, bitsStored: 8),
            transferSyntax: .jpegLosslessNonHierarchical)
        #expect(frame.samples == values.map { Int16($0) })
    }

    @Test("SOF0 viene rifiutato come codec differente")
    func rejectsSOF0() {
        var data = jpegLossless(values: [128], columns: 1, rows: 1, predictor: 1)
        if let marker = findPair(data, 0xFF, 0xC3) {
            data[marker + 1] = 0xC0
        }
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                data, frameIndex: 0,
                descriptor: descriptor(columns: 1, bitsAllocated: 8, bitsStored: 8),
                transferSyntax: .jpegLosslessNonHierarchical)
        }
    }

    @Test("La precisione SOF3 deve coincidere con BitsStored")
    func rejectsMismatchedPrecision() {
        let data = jpegLossless(values: [128], columns: 1, rows: 1, predictor: 1)
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                data, frameIndex: 0,
                descriptor: descriptor(columns: 1, bitsAllocated: 16, bitsStored: 12),
                transferSyntax: .jpegLosslessNonHierarchical)
        }
    }

    @Test("Un flusso JPEG troncato genera un errore")
    func truncatedThrows() {
        var data = jpegLossless(values: [128, 129], columns: 2, rows: 1, predictor: 1)
        data.removeLast(3)
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                data, frameIndex: 0,
                descriptor: descriptor(columns: 2, bitsAllocated: 8, bitsStored: 8),
                transferSyntax: .jpegLosslessNonHierarchical)
        }
    }
}

private func descriptor(
    columns: Int,
    rows: Int = 1,
    bitsAllocated: Int,
    bitsStored: Int,
    isSigned: Bool = false,
    frameCount: Int = 1
) -> PixelDescriptor {
    PixelDescriptor(
        columns: columns, rows: rows,
        bitsAllocated: bitsAllocated, bitsStored: bitsStored, highBit: bitsStored - 1,
        isSigned: isSigned, frameCount: frameCount)
}

private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

private func replaceUInt32LE(_ data: inout Data, at offset: Int, value: UInt32) {
    data[offset] = UInt8(value & 0xFF)
    data[offset + 1] = UInt8((value >> 8) & 0xFF)
    data[offset + 2] = UInt8((value >> 16) & 0xFF)
    data[offset + 3] = UInt8((value >> 24) & 0xFF)
}

private func appendTag(_ tag: DICOMTag, to data: inout Data) {
    appendUInt16LE(tag.group, to: &data)
    appendUInt16LE(tag.element, to: &data)
}

private func encapsulated(bot: [UInt32], fragments: [[UInt8]]) -> Data {
    var data = Data()
    appendTag(DICOMTags.item, to: &data)
    appendUInt32LE(UInt32(bot.count * 4), to: &data)
    for offset in bot { appendUInt32LE(offset, to: &data) }
    for fragment in fragments {
        appendTag(DICOMTags.item, to: &data)
        appendUInt32LE(UInt32(fragment.count), to: &data)
        data.append(contentsOf: fragment)
    }
    appendTag(DICOMTags.sequenceDelimitation, to: &data)
    appendUInt32LE(0, to: &data)
    return data
}

private func packBits(_ values: [UInt8]) -> [UInt8] {
    // Un encoder minimale per i test: un unico run letterale per blocchi fino a 128 byte.
    var output: [UInt8] = []
    var offset = 0
    while offset < values.count {
        let count = min(128, values.count - offset)
        output.append(UInt8(count - 1))
        for index in 0..<count { output.append(values[offset + index]) }
        offset += count
    }
    return output
}

private func rleFrame(segments: [[UInt8]]) -> Data {
    var data = Data(count: 64)
    replaceUInt32LE(&data, at: 0, value: UInt32(segments.count))
    var offset = 64
    for index in segments.indices {
        replaceUInt32LE(&data, at: 4 + index * 4, value: UInt32(offset))
        data.append(contentsOf: segments[index])
        offset += segments[index].count
    }
    return data
}

private struct TestJPEGWriter {
    var bytes: [UInt8] = []
    var pending = 0
    var pendingCount = 0

    mutating func appendBits(_ value: Int, count: Int) {
        for shift in stride(from: count - 1, through: 0, by: -1) {
            pending = (pending << 1) | ((value >> shift) & 1)
            pendingCount += 1
            if pendingCount == 8 {
                appendEntropyByte(UInt8(pending))
                pending = 0
                pendingCount = 0
            }
        }
    }

    mutating func alignWithOnes() {
        if pendingCount > 0 {
            let missing = 8 - pendingCount
            pending = (pending << missing) | ((1 << missing) - 1)
            appendEntropyByte(UInt8(pending))
            pending = 0
            pendingCount = 0
        }
    }

    private mutating func appendEntropyByte(_ byte: UInt8) {
        bytes.append(byte)
        if byte == 0xFF { bytes.append(0) }
    }
}

private func jpegLossless(
    values: [UInt16],
    columns: Int,
    rows: Int,
    predictor: Int,
    restartInterval: Int = 0
) -> Data {
    var result = Data([0xFF, 0xD8])
    // Codici canonici su tre lunghezze diverse: verifica anche le transizioni Annex C,
    // non soltanto il caso artificiale in cui ogni simbolo ha la medesima lunghezza.
    var bits = [UInt8](repeating: 0, count: 16)
    bits[1] = 1
    bits[3] = 2
    bits[4] = 7
    var dht: [UInt8] = [0]
    dht.append(contentsOf: bits)
    dht.append(contentsOf: (0...9).map { UInt8($0) })
    appendJPEGSegment(marker: 0xC4, payload: dht, to: &result)

    let sof: [UInt8] = [
        8, UInt8((rows >> 8) & 0xFF), UInt8(rows & 0xFF),
        UInt8((columns >> 8) & 0xFF), UInt8(columns & 0xFF),
        1, 1, 0x11, 0,
    ]
    appendJPEGSegment(marker: 0xC3, payload: sof, to: &result)
    if restartInterval > 0 {
        appendJPEGSegment(
            marker: 0xDD,
            payload: [UInt8((restartInterval >> 8) & 0xFF), UInt8(restartInterval & 0xFF)],
            to: &result)
    }
    appendJPEGSegment(marker: 0xDA, payload: [1, 1, 0, UInt8(predictor), 0, 0], to: &result)

    var entropy = TestJPEGWriter()
    var reconstructed = [Int](repeating: 0, count: values.count)
    var restartNumber = 0
    var reset = false
    for index in values.indices {
        if restartInterval > 0, index > 0, index % restartInterval == 0 {
            entropy.alignWithOnes()
            result.append(contentsOf: entropy.bytes)
            entropy = TestJPEGWriter()
            result.append(0xFF)
            result.append(UInt8(0xD0 + restartNumber))
            restartNumber = (restartNumber + 1) & 7
            reset = true
        }
        let row = index / columns
        let column = index % columns
        let predicted: Int
        if reset || (row == 0 && column == 0) {
            predicted = 128
            reset = false
        } else if column == 0 {
            predicted = reconstructed[index - columns]
        } else if row == 0 {
            predicted = reconstructed[index - 1]
        } else {
            let ra = reconstructed[index - 1]
            let rb = reconstructed[index - columns]
            let rc = reconstructed[index - columns - 1]
            predicted = jpegPrediction(predictor, ra, rb, rc)
        }
        let sample = Int(values[index])
        let difference = sample - predicted
        let category = differenceCategory(difference)
        let huffman = testHuffmanCode(for: category)
        entropy.appendBits(huffman.code, count: huffman.length)
        if category > 0 {
            let encoded = difference >= 0 ? difference : difference + ((1 << category) - 1)
            entropy.appendBits(encoded, count: category)
        }
        reconstructed[index] = sample
    }
    entropy.alignWithOnes()
    result.append(contentsOf: entropy.bytes)
    result.append(contentsOf: [0xFF, 0xD9])
    return result
}

private func testHuffmanCode(for category: Int) -> (code: Int, length: Int) {
    if category == 0 { return (0, 2) }
    if category == 1 { return (4, 4) }
    if category == 2 { return (5, 4) }
    return (category + 9, 5)
}

private func appendJPEGSegment(marker: UInt8, payload: [UInt8], to data: inout Data) {
    data.append(0xFF)
    data.append(marker)
    let length = payload.count + 2
    data.append(UInt8((length >> 8) & 0xFF))
    data.append(UInt8(length & 0xFF))
    data.append(contentsOf: payload)
}

private func differenceCategory(_ value: Int) -> Int {
    var magnitude = value < 0 ? -value : value
    var category = 0
    while magnitude > 0 {
        category += 1
        magnitude >>= 1
    }
    return category
}

private func jpegPrediction(_ selector: Int, _ ra: Int, _ rb: Int, _ rc: Int) -> Int {
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

private func containsPair(_ data: Data, _ first: UInt8, _ second: UInt8) -> Bool {
    findPair(data, first, second) != nil
}

private func findPair(_ data: Data, _ first: UInt8, _ second: UInt8) -> Int? {
    guard data.count >= 2 else { return nil }
    for index in 0..<(data.count - 1) {
        if data[index] == first, data[index + 1] == second { return index }
    }
    return nil
}
