import Foundation

@testable import DICOMCore

/// Costruisce stream DICOM minimi senza condividere logica con il parser di produzione.
struct DICOMByteStreamBuilder {
    private(set) var bytes: [UInt8] = []

    var data: Data {
        Data(bytes)
    }

    mutating func appendPreamble() {
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 128))
        bytes.append(contentsOf: [0x44, 0x49, 0x43, 0x4D])
    }

    mutating func appendUInt16(_ value: UInt16, bigEndian: Bool = false) {
        if bigEndian {
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        } else {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
        }
    }

    mutating func appendUInt32(_ value: UInt32, bigEndian: Bool = false) {
        if bigEndian {
            bytes.append(UInt8((value >> 24) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8(value & 0xFF))
        } else {
            bytes.append(UInt8(value & 0xFF))
            bytes.append(UInt8((value >> 8) & 0xFF))
            bytes.append(UInt8((value >> 16) & 0xFF))
            bytes.append(UInt8((value >> 24) & 0xFF))
        }
    }

    mutating func appendTag(_ tag: DICOMTag, bigEndian: Bool = false) {
        appendUInt16(tag.group, bigEndian: bigEndian)
        appendUInt16(tag.element, bigEndian: bigEndian)
    }

    @discardableResult
    mutating func appendExplicit(
        tag: DICOMTag,
        vr: VR,
        value: [UInt8],
        bigEndian: Bool = false
    ) -> Range<Int> {
        appendTag(tag, bigEndian: bigEndian)
        bytes.append(contentsOf: Array(vr.rawValue.utf8))
        if vr.usesLongLength {
            bytes.append(0)
            bytes.append(0)
            appendUInt32(UInt32(value.count), bigEndian: bigEndian)
        } else {
            appendUInt16(UInt16(value.count), bigEndian: bigEndian)
        }

        let start = bytes.count
        bytes.append(contentsOf: value)
        return start..<bytes.count
    }

    @discardableResult
    mutating func appendImplicit(
        tag: DICOMTag,
        value: [UInt8],
        bigEndian: Bool = false
    ) -> Range<Int> {
        appendTag(tag, bigEndian: bigEndian)
        appendUInt32(UInt32(value.count), bigEndian: bigEndian)
        let start = bytes.count
        bytes.append(contentsOf: value)
        return start..<bytes.count
    }

    mutating func appendExplicitUndefinedLengthHeader(
        tag: DICOMTag,
        vr: VR,
        bigEndian: Bool = false
    ) {
        appendTag(tag, bigEndian: bigEndian)
        bytes.append(contentsOf: Array(vr.rawValue.utf8))
        bytes.append(0)
        bytes.append(0)
        appendUInt32(UInt32.max, bigEndian: bigEndian)
    }

    mutating func appendSpecial(
        tag: DICOMTag,
        length: UInt32,
        bigEndian: Bool = false
    ) {
        appendTag(tag, bigEndian: bigEndian)
        appendUInt32(length, bigEndian: bigEndian)
    }

    mutating func appendRaw(_ value: [UInt8]) {
        bytes.append(contentsOf: value)
    }

    mutating func removeLastByte() {
        if !bytes.isEmpty {
            bytes.removeLast()
        }
    }

    func paddedUI(_ value: String) -> [UInt8] {
        var result = Array(value.utf8)
        if result.count % 2 != 0 {
            result.append(0)
        }
        return result
    }

    func paddedText(_ value: String) -> [UInt8] {
        var result = Array(value.utf8)
        if result.count % 2 != 0 {
            result.append(0x20)
        }
        return result
    }

    func littleEndianUInt32(_ value: UInt32) -> [UInt8] {
        [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF),
        ]
    }
}
