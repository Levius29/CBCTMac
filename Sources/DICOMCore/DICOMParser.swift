import Foundation

/// Quantità di dati da conservare durante il parsing.
public enum ParseDepth: Sendable {
    /// Legge i metadati e si arresta appena incontra PixelData.
    case metadataOnly
    /// Conserva anche i byte di PixelData senza decodificarli.
    case includingPixelData
}

/// Risultato del parsing di un singolo file DICOM.
public struct ParsedFile: Sendable {
    public let dataset: DICOMDataset
    public let transferSyntax: TransferSyntax
    public let pixelDataRange: Range<Int>?
    public let isEncapsulatedPixelData: Bool

    public init(
        dataset: DICOMDataset,
        transferSyntax: TransferSyntax,
        pixelDataRange: Range<Int>?,
        isEncapsulatedPixelData: Bool
    ) {
        self.dataset = dataset
        self.transferSyntax = transferSyntax
        self.pixelDataRange = pixelDataRange
        self.isEncapsulatedPixelData = isEncapsulatedPixelData
    }
}

/// Errori di lettura DICOM con il contesto necessario a individuare il byte problematico.
public enum DICOMParsingError: Error, Hashable, Sendable, LocalizedError {
    case notDICOM(sourceName: String)
    case truncated(sourceName: String, atOffset: Int)
    case unexpectedTag(sourceName: String, tag: DICOMTag, atOffset: Int)
    case deflatedNotSupported(sourceName: String)
    case missingRequiredTag(sourceName: String, tag: DICOMTag)
    case invalidVR(sourceName: String, tag: DICOMTag, atOffset: Int, rawValue: String)
    case invalidLength(sourceName: String, tag: DICOMTag, atOffset: Int, length: UInt32)
    case cannotRead(sourceName: String, reason: String)

    public var localizedDescription: String {
        switch self {
        case .notDICOM(let sourceName):
            return "Il file '\(sourceName)' non contiene un dataset DICOM riconoscibile."
        case .truncated(let sourceName, let offset):
            return "Il file '\(sourceName)' è troncato all'offset \(offset)."
        case .unexpectedTag(let sourceName, let tag, let offset):
            return "Nel file '\(sourceName)' il tag inatteso \(tag) compare all'offset \(offset)."
        case .deflatedNotSupported(let sourceName):
            return "Il file '\(sourceName)' usa Deflated Explicit VR Little Endian, "
                + "non supportato senza una dipendenza zlib portabile."
        case .missingRequiredTag(let sourceName, let tag):
            return "Nel file '\(sourceName)' manca il tag obbligatorio \(tag)."
        case .invalidVR(let sourceName, let tag, let offset, let rawValue):
            return "Nel file '\(sourceName)' il tag \(tag) ha VR non valido '\(rawValue)' "
                + "all'offset \(offset)."
        case .invalidLength(let sourceName, let tag, let offset, let length):
            return "Nel file '\(sourceName)' il tag \(tag) dichiara la lunghezza non valida "
                + "\(length) all'offset \(offset)."
        case .cannotRead(let sourceName, let reason):
            return "Impossibile leggere il file '\(sourceName)': \(reason)"
        }
    }

    public var errorDescription: String? {
        localizedDescription
    }
}

/// Parser DICOM Foundation-only, utilizzabile su macOS e Linux.
public struct DICOMParser: Sendable {
    public static func parse(
        data: Data,
        depth: ParseDepth,
        sourceName: String
    ) throws -> ParsedFile {
        if hasPreambleAndMagic(data) {
            var cursor = DICOMByteCursor(
                data: data,
                offset: 132,
                isBigEndian: false,
                sourceName: sourceName)
            var elements: [DICOMElement] = []
            try parseFileMeta(cursor: &cursor, elements: &elements)

            let metaDataset = DICOMDataset(elements: elements)
            let transferSyntax: TransferSyntax
            if let uid = metaDataset.string(DICOMTags.transferSyntaxUID) {
                transferSyntax = TransferSyntax(uid: uid)
            } else {
                transferSyntax = .implicitVRLittleEndian
            }

            if transferSyntax.isDeflated {
                throw DICOMParsingError.deflatedNotSupported(sourceName: sourceName)
            }

            var mainCursor = DICOMByteCursor(
                data: data,
                offset: cursor.offset,
                isBigEndian: transferSyntax.isBigEndian,
                sourceName: sourceName)
            let result = try parseMainDataset(
                cursor: &mainCursor,
                explicitVR: transferSyntax.isExplicitVR,
                transferSyntax: transferSyntax,
                depth: depth,
                elements: &elements)
            return ParsedFile(
                dataset: DICOMDataset(elements: elements),
                transferSyntax: transferSyntax,
                pixelDataRange: result.pixelDataRange,
                isEncapsulatedPixelData: result.isEncapsulatedPixelData)
        }

        guard plausibleHeaderlessImplicitDataset(data, sourceName: sourceName) else {
            throw DICOMParsingError.notDICOM(sourceName: sourceName)
        }

        let transferSyntax = TransferSyntax.implicitVRLittleEndian
        var cursor = DICOMByteCursor(
            data: data,
            offset: 0,
            isBigEndian: false,
            sourceName: sourceName)
        var elements: [DICOMElement] = []
        let result = try parseMainDataset(
            cursor: &cursor,
            explicitVR: false,
            transferSyntax: transferSyntax,
            depth: depth,
            elements: &elements)
        return ParsedFile(
            dataset: DICOMDataset(elements: elements),
            transferSyntax: transferSyntax,
            pixelDataRange: result.pixelDataRange,
            isEncapsulatedPixelData: result.isEncapsulatedPixelData)
    }

    public static func parse(url: URL, depth: ParseDepth) throws -> ParsedFile {
        let sourceName = url.path
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            return try parse(data: data, depth: depth, sourceName: sourceName)
        } catch let parsingError as DICOMParsingError {
            throw parsingError
        } catch {
            throw DICOMParsingError.cannotRead(
                sourceName: sourceName,
                reason: error.localizedDescription)
        }
    }

    private static func hasPreambleAndMagic(_ data: Data) -> Bool {
        guard data.count >= 132 else {
            return false
        }
        let start = data.startIndex
        return data[start + 128] == 0x44
            && data[start + 129] == 0x49
            && data[start + 130] == 0x43
            && data[start + 131] == 0x4D
    }

    private static func plausibleHeaderlessImplicitDataset(
        _ data: Data,
        sourceName: String
    ) -> Bool {
        guard data.count >= 8 else {
            return false
        }

        var cursor = DICOMByteCursor(
            data: data,
            offset: 0,
            isBigEndian: false,
            sourceName: sourceName)
        do {
            let tag = try cursor.readTag()
            let length = try cursor.readUInt32()
            guard tag.group >= 0x0008, tag.group <= 0x7FE0 else {
                return false
            }
            if length == UInt32.max {
                return tag == DICOMTags.pixelData
            }
            guard let count = Int(exactly: length) else {
                return false
            }
            return count <= data.count - cursor.offset
        } catch {
            return false
        }
    }

    private static func parseFileMeta(
        cursor: inout DICOMByteCursor,
        elements: inout [DICOMElement]
    ) throws {
        var declaredEndOffset: Int?

        while cursor.offset < cursor.data.count {
            if let endOffset = declaredEndOffset {
                if cursor.offset == endOffset {
                    return
                }
                if cursor.offset > endOffset {
                    throw DICOMParsingError.truncated(
                        sourceName: cursor.sourceName,
                        atOffset: endOffset)
                }
            }

            var lookahead = cursor
            let nextTag = try lookahead.readTag()
            if nextTag.group != 0x0002 {
                if declaredEndOffset != nil {
                    throw DICOMParsingError.unexpectedTag(
                        sourceName: cursor.sourceName,
                        tag: nextTag,
                        atOffset: cursor.offset)
                }
                return
            }

            let header = try readElementHeader(cursor: &cursor, explicitVR: true)
            guard header.length != UInt32.max,
                  let valueLength = Int(exactly: header.length)
            else {
                throw DICOMParsingError.invalidLength(
                    sourceName: cursor.sourceName,
                    tag: header.tag,
                    atOffset: header.headerOffset,
                    length: header.length)
            }
            let value = try cursor.readData(count: valueLength)
            elements.append(DICOMElement(
                tag: header.tag,
                vr: header.vr,
                value: value,
                isBigEndian: false))

            if header.tag == DICOMTags.fileMetaGroupLength {
                guard header.vr == .UL, value.count == 4 else {
                    throw DICOMParsingError.invalidLength(
                        sourceName: cursor.sourceName,
                        tag: header.tag,
                        atOffset: header.headerOffset,
                        length: header.length)
                }
                let start = value.startIndex
                let groupLength = UInt32(value[start])
                    | (UInt32(value[start + 1]) << 8)
                    | (UInt32(value[start + 2]) << 16)
                    | (UInt32(value[start + 3]) << 24)
                guard let groupLengthInt = Int(exactly: groupLength),
                      cursor.offset <= cursor.data.count,
                      groupLengthInt <= cursor.data.count - cursor.offset
                else {
                    throw DICOMParsingError.truncated(
                        sourceName: cursor.sourceName,
                        atOffset: cursor.offset)
                }
                declaredEndOffset = cursor.offset + groupLengthInt
            }

            if let endOffset = declaredEndOffset, cursor.offset > endOffset {
                throw DICOMParsingError.invalidLength(
                    sourceName: cursor.sourceName,
                    tag: header.tag,
                    atOffset: header.headerOffset,
                    length: header.length)
            }
        }

        if let endOffset = declaredEndOffset, cursor.offset != endOffset {
            throw DICOMParsingError.truncated(
                sourceName: cursor.sourceName,
                atOffset: cursor.offset)
        }
    }

    private static func parseMainDataset(
        cursor: inout DICOMByteCursor,
        explicitVR: Bool,
        transferSyntax: TransferSyntax,
        depth: ParseDepth,
        elements: inout [DICOMElement]
    ) throws -> MainDatasetResult {
        var pixelDataRange: Range<Int>?
        var isEncapsulatedPixelData = false

        while cursor.offset < cursor.data.count {
            let header = try readElementHeader(cursor: &cursor, explicitVR: explicitVR)

            if header.tag == DICOMTags.pixelData {
                if header.length == UInt32.max {
                    let range = try scanEncapsulatedPixelData(cursor: &cursor)
                    pixelDataRange = range
                    isEncapsulatedPixelData = true

                    let value: Data
                    switch depth {
                    case .metadataOnly:
                        value = Data()
                    case .includingPixelData:
                        value = try cursor.data(in: range)
                    }
                    elements.append(DICOMElement(
                        tag: header.tag,
                        vr: header.vr,
                        value: value,
                        isBigEndian: cursor.isBigEndian))

                    if case .metadataOnly = depth {
                        return MainDatasetResult(
                            pixelDataRange: pixelDataRange,
                            isEncapsulatedPixelData: isEncapsulatedPixelData)
                    }
                    continue
                }

                let valueLength = try checkedLength(header, sourceName: cursor.sourceName)
                let range = try cursor.validatedRange(count: valueLength)
                pixelDataRange = range
                isEncapsulatedPixelData = transferSyntax.isEncapsulated

                if case .metadataOnly = depth {
                    elements.append(DICOMElement(
                        tag: header.tag,
                        vr: header.vr,
                        value: Data(),
                        isBigEndian: cursor.isBigEndian))
                    return MainDatasetResult(
                        pixelDataRange: pixelDataRange,
                        isEncapsulatedPixelData: isEncapsulatedPixelData)
                }

                let value = try cursor.readData(count: valueLength)
                elements.append(DICOMElement(
                    tag: header.tag,
                    vr: header.vr,
                    value: value,
                    isBigEndian: cursor.isBigEndian))
                continue
            }

            if header.vr == .SQ {
                if header.length == UInt32.max {
                    try skipUndefinedSequence(cursor: &cursor, explicitVR: explicitVR)
                } else {
                    let valueLength = try checkedLength(header, sourceName: cursor.sourceName)
                    try cursor.skip(count: valueLength)
                }
                // TODO: un futuro tag inspector potrebbe conservare il contenuto della sequenza.
                elements.append(DICOMElement(
                    tag: header.tag,
                    vr: header.vr,
                    value: Data(),
                    isBigEndian: cursor.isBigEndian))
                continue
            }

            if header.length == UInt32.max {
                if header.vr == .UN {
                    // In Implicit VR un tag di sequenza non presente nella tabella minima è
                    // indistinguibile da UN. La lunghezza indefinita e la struttura a item
                    // permettono di saltarlo senza inventare il significato del tag.
                    try skipUndefinedSequence(cursor: &cursor, explicitVR: explicitVR)
                    elements.append(DICOMElement(
                        tag: header.tag,
                        vr: header.vr,
                        value: Data(),
                        isBigEndian: cursor.isBigEndian))
                    continue
                }
                throw DICOMParsingError.invalidLength(
                    sourceName: cursor.sourceName,
                    tag: header.tag,
                    atOffset: header.headerOffset,
                    length: header.length)
            }

            let valueLength = try checkedLength(header, sourceName: cursor.sourceName)
            let value = try cursor.readData(count: valueLength)
            elements.append(DICOMElement(
                tag: header.tag,
                vr: header.vr,
                value: value,
                isBigEndian: cursor.isBigEndian))
        }

        return MainDatasetResult(
            pixelDataRange: pixelDataRange,
            isEncapsulatedPixelData: isEncapsulatedPixelData)
    }

    private static func readElementHeader(
        cursor: inout DICOMByteCursor,
        explicitVR: Bool
    ) throws -> ElementHeader {
        let headerOffset = cursor.offset
        let tag = try cursor.readTag()
        if tag.group == 0xFFFE {
            throw DICOMParsingError.unexpectedTag(
                sourceName: cursor.sourceName,
                tag: tag,
                atOffset: headerOffset)
        }
        return try readElementHeaderAfterTag(
            cursor: &cursor,
            tag: tag,
            headerOffset: headerOffset,
            explicitVR: explicitVR)
    }

    private static func readElementHeaderAfterTag(
        cursor: inout DICOMByteCursor,
        tag: DICOMTag,
        headerOffset: Int,
        explicitVR: Bool
    ) throws -> ElementHeader {
        let vr: VR
        let length: UInt32

        if explicitVR {
            let first = try cursor.readUInt8()
            let second = try cursor.readUInt8()
            let rawBytes = [first, second]
            let rawValue = String(bytes: rawBytes, encoding: .ascii)
                ?? String(format: "%02X%02X", Int(first), Int(second))
            guard let parsedVR = VR(rawValue: rawValue) else {
                throw DICOMParsingError.invalidVR(
                    sourceName: cursor.sourceName,
                    tag: tag,
                    atOffset: headerOffset + 4,
                    rawValue: rawValue)
            }
            vr = parsedVR
            if vr.usesLongLength {
                _ = try cursor.readUInt8()
                _ = try cursor.readUInt8()
                length = try cursor.readUInt32()
            } else {
                length = UInt32(try cursor.readUInt16())
            }
        } else {
            vr = DICOMTags.inferredVR(for: tag)
            length = try cursor.readUInt32()
        }

        return ElementHeader(
            tag: tag,
            vr: vr,
            length: length,
            headerOffset: headerOffset,
            valueOffset: cursor.offset)
    }

    private static func checkedLength(
        _ header: ElementHeader,
        sourceName: String
    ) throws -> Int {
        guard header.length != UInt32.max,
              let valueLength = Int(exactly: header.length)
        else {
            throw DICOMParsingError.invalidLength(
                sourceName: sourceName,
                tag: header.tag,
                atOffset: header.headerOffset,
                length: header.length)
        }
        return valueLength
    }

    private static func skipUndefinedSequence(
        cursor: inout DICOMByteCursor,
        explicitVR: Bool
    ) throws {
        var containers: [UndefinedContainer] = [.sequence]

        while !containers.isEmpty {
            let tagOffset = cursor.offset
            let tag = try cursor.readTag()

            if tag.group == 0xFFFE {
                let length = try cursor.readUInt32()
                if tag == DICOMTags.item {
                    guard containerIsSequence(containers.last) else {
                        throw DICOMParsingError.unexpectedTag(
                            sourceName: cursor.sourceName,
                            tag: tag,
                            atOffset: tagOffset)
                    }
                    if length == UInt32.max {
                        containers.append(.item)
                    } else {
                        guard let itemLength = Int(exactly: length) else {
                            throw DICOMParsingError.invalidLength(
                                sourceName: cursor.sourceName,
                                tag: tag,
                                atOffset: tagOffset,
                                length: length)
                        }
                        try cursor.skip(count: itemLength)
                    }
                    continue
                }

                if tag == DICOMTags.itemDelimitation {
                    guard length == 0, containerIsItem(containers.last) else {
                        throw DICOMParsingError.unexpectedTag(
                            sourceName: cursor.sourceName,
                            tag: tag,
                            atOffset: tagOffset)
                    }
                    containers.removeLast()
                    continue
                }

                if tag == DICOMTags.sequenceDelimitation {
                    guard length == 0, containerIsSequence(containers.last) else {
                        throw DICOMParsingError.unexpectedTag(
                            sourceName: cursor.sourceName,
                            tag: tag,
                            atOffset: tagOffset)
                    }
                    containers.removeLast()
                    continue
                }

                throw DICOMParsingError.unexpectedTag(
                    sourceName: cursor.sourceName,
                    tag: tag,
                    atOffset: tagOffset)
            }

            guard containerIsItem(containers.last) else {
                throw DICOMParsingError.unexpectedTag(
                    sourceName: cursor.sourceName,
                    tag: tag,
                    atOffset: tagOffset)
            }

            let header = try readElementHeaderAfterTag(
                cursor: &cursor,
                tag: tag,
                headerOffset: tagOffset,
                explicitVR: explicitVR)

            if header.tag == DICOMTags.pixelData, header.length == UInt32.max {
                _ = try scanEncapsulatedPixelData(cursor: &cursor)
                continue
            }

            if header.vr == .SQ || (header.vr == .UN && header.length == UInt32.max) {
                if header.length == UInt32.max {
                    containers.append(.sequence)
                } else {
                    let valueLength = try checkedLength(header, sourceName: cursor.sourceName)
                    try cursor.skip(count: valueLength)
                }
                continue
            }

            let valueLength = try checkedLength(header, sourceName: cursor.sourceName)
            try cursor.skip(count: valueLength)
        }
    }

    private static func scanEncapsulatedPixelData(
        cursor: inout DICOMByteCursor
    ) throws -> Range<Int> {
        let firstItemOffset = cursor.offset
        var itemCount = 0

        while true {
            let tagOffset = cursor.offset
            let tag = try cursor.readTag()
            let length = try cursor.readUInt32()

            if tag == DICOMTags.item {
                guard length != UInt32.max, let itemLength = Int(exactly: length) else {
                    throw DICOMParsingError.invalidLength(
                        sourceName: cursor.sourceName,
                        tag: tag,
                        atOffset: tagOffset,
                        length: length)
                }
                try cursor.skip(count: itemLength)
                itemCount += 1
                continue
            }

            if tag == DICOMTags.sequenceDelimitation {
                guard length == 0, itemCount > 0 else {
                    throw DICOMParsingError.unexpectedTag(
                        sourceName: cursor.sourceName,
                        tag: tag,
                        atOffset: tagOffset)
                }
                return firstItemOffset..<tagOffset
            }

            throw DICOMParsingError.unexpectedTag(
                sourceName: cursor.sourceName,
                tag: tag,
                atOffset: tagOffset)
        }
    }

    private static func containerIsSequence(_ container: UndefinedContainer?) -> Bool {
        guard let container else { return false }
        switch container {
        case .sequence:
            return true
        case .item:
            return false
        }
    }

    private static func containerIsItem(_ container: UndefinedContainer?) -> Bool {
        guard let container else { return false }
        switch container {
        case .sequence:
            return false
        case .item:
            return true
        }
    }
}

private struct ElementHeader {
    let tag: DICOMTag
    let vr: VR
    let length: UInt32
    let headerOffset: Int
    let valueOffset: Int
}

private struct MainDatasetResult {
    let pixelDataRange: Range<Int>?
    let isEncapsulatedPixelData: Bool
}

private enum UndefinedContainer {
    case sequence
    case item
}

private struct DICOMByteCursor {
    let data: Data
    var offset: Int
    let isBigEndian: Bool
    let sourceName: String

    mutating func readUInt8() throws -> UInt8 {
        let range = try validatedRange(count: 1)
        let value = data[data.startIndex + range.lowerBound]
        offset = range.upperBound
        return value
    }

    mutating func readUInt16() throws -> UInt16 {
        let range = try validatedRange(count: 2)
        let first = UInt16(data[data.startIndex + range.lowerBound])
        let second = UInt16(data[data.startIndex + range.lowerBound + 1])
        offset = range.upperBound
        if isBigEndian {
            return (first << 8) | second
        }
        return (second << 8) | first
    }

    mutating func readUInt32() throws -> UInt32 {
        let range = try validatedRange(count: 4)
        let base = data.startIndex + range.lowerBound
        let b0 = UInt32(data[base])
        let b1 = UInt32(data[base + 1])
        let b2 = UInt32(data[base + 2])
        let b3 = UInt32(data[base + 3])
        offset = range.upperBound
        if isBigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    mutating func readTag() throws -> DICOMTag {
        let group = try readUInt16()
        let element = try readUInt16()
        return DICOMTag(group: group, element: element)
    }

    mutating func readData(count: Int) throws -> Data {
        let range = try validatedRange(count: count)
        let value = try data(in: range)
        offset = range.upperBound
        return value
    }

    mutating func skip(count: Int) throws {
        let range = try validatedRange(count: count)
        offset = range.upperBound
    }

    func validatedRange(count: Int) throws -> Range<Int> {
        guard count >= 0,
              offset >= 0,
              offset <= data.count,
              count <= data.count - offset
        else {
            throw DICOMParsingError.truncated(
                sourceName: sourceName,
                atOffset: offset)
        }
        return offset..<(offset + count)
    }

    func data(in range: Range<Int>) throws -> Data {
        guard range.lowerBound >= 0,
              range.lowerBound <= range.upperBound,
              range.upperBound <= data.count
        else {
            throw DICOMParsingError.truncated(
                sourceName: sourceName,
                atOffset: range.lowerBound)
        }
        let start = data.startIndex + range.lowerBound
        let end = data.startIndex + range.upperBound
        return Data(data[start..<end])
    }
}
