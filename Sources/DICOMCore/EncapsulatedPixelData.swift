import Foundation

/// Struttura degli item che compongono un `PixelData` DICOM incapsulato.
public struct EncapsulatedPixelData: Sendable {
    /// Intervalli dei soli byte dei frammenti, nell'ordine del file, senza header degli item.
    public let fragments: [Range<Int>]
    /// Voci della Basic Offset Table, quando presente e non vuota.
    public let basicOffsetTable: [UInt32]

    private let fragmentItemOffsets: [Int]
    private let encodedLength: Int
    private let sourceName: String

    private init(
        fragments: [Range<Int>],
        basicOffsetTable: [UInt32],
        fragmentItemOffsets: [Int],
        encodedLength: Int,
        sourceName: String
    ) {
        self.fragments = fragments
        self.basicOffsetTable = basicOffsetTable
        self.fragmentItemOffsets = fragmentItemOffsets
        self.encodedLength = encodedLength
        self.sourceName = sourceName
    }

    /// Legge Basic Offset Table, frammenti e delimitatore da un valore PixelData incapsulato.
    public static func parse(_ data: Data, sourceName: String) throws -> EncapsulatedPixelData {
        var cursor = 0
        let botTagOffset = cursor
        let botTag = try readTag(data, cursor: &cursor, sourceName: sourceName)
        guard botTag == DICOMTags.item else {
            throw malformed(sourceName, "atteso l'item della Basic Offset Table all'offset \(botTagOffset)")
        }
        let botLengthValue = try readUInt32(data, cursor: &cursor, sourceName: sourceName)
        guard let botLength = Int(exactly: botLengthValue), botLength % 4 == 0 else {
            throw malformed(sourceName, "lunghezza \(botLengthValue) non valida per la Basic Offset Table")
        }
        let botEnd = try checkedEnd(cursor, count: botLength, dataCount: data.count, sourceName: sourceName)
        var offsets: [UInt32] = []
        offsets.reserveCapacity(botLength / 4)
        while cursor < botEnd {
            offsets.append(try readUInt32(data, cursor: &cursor, sourceName: sourceName))
        }

        // Gli offset DICOM sono misurati dall'inizio dell'header del primo frammento, non dai
        // suoi byte di valore. Conservare entrambi evita l'errore di otto byte per fotogramma.
        let firstFragmentItemOffset = cursor
        var fragments: [Range<Int>] = []
        var itemOffsets: [Int] = []

        while true {
            let itemOffset = cursor
            let tag = try readTag(data, cursor: &cursor, sourceName: sourceName)
            let lengthValue = try readUInt32(data, cursor: &cursor, sourceName: sourceName)

            if tag == DICOMTags.sequenceDelimitation {
                guard lengthValue == 0 else {
                    throw malformed(sourceName, "delimitatore di sequenza con lunghezza non zero all'offset \(itemOffset)")
                }
                return EncapsulatedPixelData(
                    fragments: fragments,
                    basicOffsetTable: offsets,
                    fragmentItemOffsets: itemOffsets,
                    encodedLength: itemOffset - firstFragmentItemOffset,
                    sourceName: sourceName)
            }

            guard tag == DICOMTags.item else {
                throw malformed(sourceName, "tag \(tag) inatteso all'offset \(itemOffset)")
            }
            guard lengthValue != UInt32.max, let length = Int(exactly: lengthValue) else {
                throw malformed(sourceName, "lunghezza indefinita di un frammento all'offset \(itemOffset)")
            }
            let end = try checkedEnd(cursor, count: length, dataCount: data.count, sourceName: sourceName)
            itemOffsets.append(itemOffset - firstFragmentItemOffset)
            fragments.append(cursor..<end)
            cursor = end
        }
    }

    /// Restituisce i frammenti concatenati che appartengono a un solo fotogramma.
    ///
    /// Non si indovina mai una suddivisione ambigua: byte del fotogramma sbagliato possono
    /// produrre rumore plausibile, quindi in quel caso è più sicuro fallire chiaramente.
    public func frameData(_ data: Data, frameIndex: Int, frameCount: Int) throws -> Data {
        guard frameCount > 0 else {
            throw PixelDecodingError.invalidDescriptor("NumberOfFrames \(frameCount)")
        }
        guard frameIndex >= 0, frameIndex < frameCount else {
            throw PixelDecodingError.frameIndexOutOfRange(frameIndex, frameCount: frameCount)
        }

        if !basicOffsetTable.isEmpty {
            guard basicOffsetTable.count == frameCount else {
                throw PixelDecodingError.malformedCompressedData(
                    "'\(sourceName)': la Basic Offset Table contiene "
                        + "\(basicOffsetTable.count) offset per \(frameCount) fotogrammi")
            }
            guard frameIndex < basicOffsetTable.count,
                  let start = Int(exactly: basicOffsetTable[frameIndex])
            else {
                throw PixelDecodingError.invalidFrameOffset(
                    sourceName: sourceName, frameIndex: frameIndex, offset: UInt32.max)
            }
            let end: Int
            if frameIndex + 1 < basicOffsetTable.count {
                guard let next = Int(exactly: basicOffsetTable[frameIndex + 1]) else {
                    throw PixelDecodingError.invalidFrameOffset(
                        sourceName: sourceName,
                        frameIndex: frameIndex + 1, offset: basicOffsetTable[frameIndex + 1])
                }
                end = next
            } else {
                end = encodedLength
            }
            let endIsBoundary = end == encodedLength || fragmentItemOffsets.contains(end)
            guard start >= 0, start < end, end <= encodedLength,
                  fragmentItemOffsets.contains(start), endIsBoundary
            else {
                throw PixelDecodingError.invalidFrameOffset(
                    sourceName: sourceName,
                    frameIndex: frameIndex, offset: basicOffsetTable[frameIndex])
            }
            var selected: [Range<Int>] = []
            for index in fragmentItemOffsets.indices {
                let itemOffset = fragmentItemOffsets[index]
                if itemOffset >= start, itemOffset < end {
                    selected.append(fragments[index])
                }
            }
            guard !selected.isEmpty else {
                throw PixelDecodingError.invalidFrameOffset(
                    sourceName: sourceName,
                    frameIndex: frameIndex, offset: basicOffsetTable[frameIndex])
            }
            return try concatenate(selected, from: data)
        }

        if fragments.count == frameCount {
            return try concatenate([fragments[frameIndex]], from: data)
        }
        if frameCount == 1 {
            return try concatenate(fragments, from: data)
        }
        throw PixelDecodingError.ambiguousFrameFragments(
            sourceName: sourceName,
            frameCount: frameCount, fragmentCount: fragments.count)
    }

    private func concatenate(_ ranges: [Range<Int>], from data: Data) throws -> Data {
        var result = Data()
        for range in ranges {
            guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
                  range.upperBound <= data.count
            else {
                throw PixelDecodingError.malformedCompressedData(
                    "il contenuto di '\(sourceName)' non corrisponde agli intervalli analizzati")
            }
            result.append(data.subdata(in: range))
        }
        return result
    }

    private static func malformed(_ sourceName: String, _ detail: String) -> PixelDecodingError {
        PixelDecodingError.malformedCompressedData("'\(sourceName)': \(detail)")
    }

    private static func checkedEnd(
        _ start: Int, count: Int, dataCount: Int, sourceName: String
    ) throws -> Int {
        guard count >= 0, start >= 0, start <= dataCount, count <= dataCount - start else {
            throw malformed(sourceName, "dati troncati all'offset \(start)")
        }
        return start + count
    }

    private static func readTag(
        _ data: Data, cursor: inout Int, sourceName: String
    ) throws -> DICOMTag {
        let group = try readUInt16(data, cursor: &cursor, sourceName: sourceName)
        let element = try readUInt16(data, cursor: &cursor, sourceName: sourceName)
        return DICOMTag(group: group, element: element)
    }

    private static func readUInt16(
        _ data: Data, cursor: inout Int, sourceName: String
    ) throws -> UInt16 {
        let end = try checkedEnd(cursor, count: 2, dataCount: data.count, sourceName: sourceName)
        let value = UInt16(data[cursor]) | (UInt16(data[cursor + 1]) << 8)
        cursor = end
        return value
    }

    private static func readUInt32(
        _ data: Data, cursor: inout Int, sourceName: String
    ) throws -> UInt32 {
        let end = try checkedEnd(cursor, count: 4, dataCount: data.count, sourceName: sourceName)
        let value = UInt32(data[cursor])
            | (UInt32(data[cursor + 1]) << 8)
            | (UInt32(data[cursor + 2]) << 16)
            | (UInt32(data[cursor + 3]) << 24)
        cursor = end
        return value
    }
}
