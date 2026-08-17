import Foundation

struct MeshIOByteBuilder {
    private(set) var bytes: [UInt8] = []

    mutating func appendUInt8(_ value: UInt8) {
        bytes.append(value)
    }

    mutating func appendUInt16(_ value: UInt16, bigEndian: Bool = false) {
        if bigEndian {
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value))
        } else {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        }
    }

    mutating func appendUInt32(_ value: UInt32, bigEndian: Bool = false) {
        if bigEndian {
            bytes.append(UInt8(truncatingIfNeeded: value >> 24))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value))
        } else {
            bytes.append(UInt8(truncatingIfNeeded: value))
            bytes.append(UInt8(truncatingIfNeeded: value >> 8))
            bytes.append(UInt8(truncatingIfNeeded: value >> 16))
            bytes.append(UInt8(truncatingIfNeeded: value >> 24))
        }
    }

    mutating func appendUInt64(_ value: UInt64, bigEndian: Bool = false) {
        if bigEndian {
            var shift = 56
            while shift >= 0 {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
                shift -= 8
            }
        } else {
            var shift = 0
            while shift <= 56 {
                bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
                shift += 8
            }
        }
    }

    mutating func appendFloat32(_ value: Float, bigEndian: Bool = false) {
        appendUInt32(value.bitPattern, bigEndian: bigEndian)
    }

    mutating func appendFloat64(_ value: Double, bigEndian: Bool = false) {
        appendUInt64(value.bitPattern, bigEndian: bigEndian)
    }

    mutating func appendASCII(_ value: String) {
        bytes.append(contentsOf: value.utf8)
    }

    mutating func appendZeroes(count: Int) {
        guard count > 0 else { return }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: count))
    }

    var data: Data { Data(bytes) }
}
