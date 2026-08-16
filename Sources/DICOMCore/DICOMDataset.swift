import Foundation

/// Un elemento DICOM con i byte del valore non interpretati.
public struct DICOMElement: Sendable {
    public let tag: DICOMTag
    public let vr: VR
    public let value: Data

    // L'endianness appartiene all'elemento, non all'intero dataset: il gruppo file meta è
    // sempre little endian anche quando il dataset principale è big endian.
    internal let isBigEndian: Bool

    public init(tag: DICOMTag, vr: VR, value: Data) {
        self.init(tag: tag, vr: vr, value: value, isBigEndian: false)
    }

    internal init(tag: DICOMTag, vr: VR, value: Data, isBigEndian: Bool) {
        self.tag = tag
        self.vr = vr
        self.value = value
        self.isBigEndian = isBigEndian
    }
}

/// Collezione degli elementi DICOM di primo livello.
///
/// Conserva l'ordine originale per il futuro ispettore dei tag e offre contemporaneamente
/// accesso diretto per tag. Gli accessor restituiscono `nil` su valori assenti o malformati.
public struct DICOMDataset: Sendable {
    private let orderedElements: [DICOMElement]
    private let elementsByTag: [DICOMTag: DICOMElement]

    public init(elements: [DICOMElement]) {
        self.orderedElements = elements

        var lookup: [DICOMTag: DICOMElement] = [:]
        for element: DICOMElement in elements {
            lookup[element.tag] = element
        }
        self.elementsByTag = lookup
    }

    public subscript(tag: DICOMTag) -> DICOMElement? {
        elementsByTag[tag]
    }

    /// Tutti gli elementi nell'ordine in cui compaiono nel file.
    public var allElements: [DICOMElement] {
        orderedElements
    }

    /// Legge un singolo valore testuale rimuovendo il padding DICOM finale.
    public func string(_ tag: DICOMTag) -> String? {
        guard let element = elementsByTag[tag], element.vr.isStringLike else {
            return nil
        }
        return decodedString(element.value)
    }

    /// Legge un valore testuale multiplo separato da barra inversa.
    public func strings(_ tag: DICOMTag) -> [String]? {
        guard let value = string(tag) else {
            return nil
        }
        return value.components(separatedBy: "\\")
    }

    /// Legge il primo numero come `Double`.
    public func double(_ tag: DICOMTag) -> Double? {
        guard let values = doubles(tag), !values.isEmpty else {
            return nil
        }
        return values[0]
    }

    /// Legge tutti i numeri come `Double`, scegliendo testo o binario dal VR.
    public func doubles(_ tag: DICOMTag) -> [Double]? {
        guard let element = elementsByTag[tag] else {
            return nil
        }

        switch element.vr {
        case .DS, .IS:
            return textDoubles(element.value)
        case .US:
            return unsignedShortDoubles(element)
        case .SS:
            return signedShortDoubles(element)
        case .UL:
            return unsignedLongDoubles(element)
        case .SL:
            return signedLongDoubles(element)
        case .SV:
            return signedVeryLongDoubles(element)
        case .UV:
            return unsignedVeryLongDoubles(element)
        case .FL:
            return binary32Doubles(element)
        case .FD:
            return doubleDoubles(element)
        default:
            return nil
        }
    }

    /// Legge il primo numero come `Int` senza arrotondare.
    public func int(_ tag: DICOMTag) -> Int? {
        guard let values = ints(tag), !values.isEmpty else {
            return nil
        }
        return values[0]
    }

    /// Legge tutti i numeri come `Int`; valori frazionari o fuori intervallo restituiscono nil.
    public func ints(_ tag: DICOMTag) -> [Int]? {
        guard let element = elementsByTag[tag] else {
            return nil
        }

        switch element.vr {
        case .DS, .IS:
            guard let values = textDoubles(element.value) else {
                return nil
            }
            return exactIntegers(values)
        case .US:
            return unsignedShortIntegers(element)
        case .SS:
            return signedShortIntegers(element)
        case .UL:
            return unsignedLongIntegers(element)
        case .SL:
            return signedLongIntegers(element)
        case .SV:
            return signedVeryLongIntegers(element)
        case .UV:
            return unsignedVeryLongIntegers(element)
        case .FL, .FD:
            guard let values = doubles(tag) else {
                return nil
            }
            return exactIntegers(values)
        default:
            return nil
        }
    }

    /// Legge i primi tre numeri del tag come vettore geometrico in `Double`.
    public func vec3(_ tag: DICOMTag) -> Vec3? {
        guard let values = doubles(tag) else {
            return nil
        }
        return Vec3(values)
    }

    private func decodedString(_ data: Data) -> String? {
        var decoded: String?
        decoded = String(data: data, encoding: .utf8)
        if decoded == nil {
            decoded = String(data: data, encoding: .isoLatin1)
        }
        guard var value = decoded else {
            return nil
        }

        // UI usa NUL; gli altri VR testuali usano spazio. Entrambi sono padding finale,
        // mentre gli spazi iniziali possono appartenere al valore e vanno conservati.
        while let last = value.last, last == "\0" || last == " " {
            value.removeLast()
        }
        return value
    }

    private func textDoubles(_ data: Data) -> [Double]? {
        guard let decoded = decodedString(data) else {
            return nil
        }
        let components = decoded.components(separatedBy: "\\")
        var result: [Double] = []
        result.reserveCapacity(components.count)

        let trimSet = CharacterSet.whitespacesAndNewlines.union(
            CharacterSet(charactersIn: "\0"))
        for component: String in components {
            let trimmed = component.trimmingCharacters(in: trimSet)
            guard !trimmed.isEmpty, let value = Double(trimmed), value.isFinite else {
                return nil
            }
            result.append(value)
        }
        return result
    }

    private func exactIntegers(_ values: [Double]) -> [Int]? {
        var result: [Int] = []
        result.reserveCapacity(values.count)
        for value: Double in values {
            guard value.isFinite, let integer = Int(exactly: value) else {
                return nil
            }
            result.append(integer)
        }
        return result
    }

    private func unsignedShortDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 2 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 2)
        var offset = 0
        while offset < element.value.count {
            guard let value = readUInt16(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Double(value))
            offset += 2
        }
        return result
    }

    private func signedShortDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 2 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 2)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt16(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Double(Int16(bitPattern: raw)))
            offset += 2
        }
        return result
    }

    private func unsignedLongDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 4 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 4)
        var offset = 0
        while offset < element.value.count {
            guard let value = readUInt32(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Double(value))
            offset += 4
        }
        return result
    }

    private func signedLongDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 4 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 4)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt32(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Double(Int32(bitPattern: raw)))
            offset += 4
        }
        return result
    }

    private func signedVeryLongDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 8 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 8)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt64(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Double(Int64(bitPattern: raw)))
            offset += 8
        }
        return result
    }

    private func unsignedVeryLongDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 8 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 8)
        var offset = 0
        while offset < element.value.count {
            guard let value = readUInt64(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Double(value))
            offset += 8
        }
        return result
    }

    private func binary32Doubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 4 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 4)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt32(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            guard let value = binary32AsDouble(raw) else { return nil }
            result.append(value)
            offset += 4
        }
        return result
    }

    private func binary32AsDouble(_ raw: UInt32) -> Double? {
        let exponentBits = Int((raw >> 23) & 0xFF)
        let fractionBits = raw & 0x007F_FFFF

        // Esponente tutto a uno significa infinito o NaN. Gli accessor numerici non
        // propagano valori non finiti perché produrrebbero geometrie plausibili ma errate.
        guard exponentBits != 0xFF else {
            return nil
        }

        let magnitude: Double
        if exponentBits == 0 {
            magnitude = Double(fractionBits) * powerOfTwo(-149)
        } else {
            let significand = 1.0 + Double(fractionBits) / 8_388_608.0
            magnitude = significand * powerOfTwo(exponentBits - 127)
        }

        if (raw & 0x8000_0000) != 0 {
            return -magnitude
        }
        return magnitude
    }

    private func powerOfTwo(_ exponent: Int) -> Double {
        var value = 1.0
        if exponent >= 0 {
            var remaining = exponent
            while remaining > 0 {
                value *= 2.0
                remaining -= 1
            }
        } else {
            var remaining = exponent
            while remaining < 0 {
                value *= 0.5
                remaining += 1
            }
        }
        return value
    }

    private func doubleDoubles(_ element: DICOMElement) -> [Double]? {
        guard element.value.count % 8 == 0 else { return nil }
        var result: [Double] = []
        result.reserveCapacity(element.value.count / 8)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt64(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            let value = Double(bitPattern: raw)
            guard value.isFinite else { return nil }
            result.append(value)
            offset += 8
        }
        return result
    }

    private func unsignedShortIntegers(_ element: DICOMElement) -> [Int]? {
        guard element.value.count % 2 == 0 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(element.value.count / 2)
        var offset = 0
        while offset < element.value.count {
            guard let value = readUInt16(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Int(value))
            offset += 2
        }
        return result
    }

    private func signedShortIntegers(_ element: DICOMElement) -> [Int]? {
        guard element.value.count % 2 == 0 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(element.value.count / 2)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt16(element.value, at: offset, bigEndian: element.isBigEndian)
            else { return nil }
            result.append(Int(Int16(bitPattern: raw)))
            offset += 2
        }
        return result
    }

    private func unsignedLongIntegers(_ element: DICOMElement) -> [Int]? {
        guard element.value.count % 4 == 0 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(element.value.count / 4)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt32(element.value, at: offset, bigEndian: element.isBigEndian),
                  let value = Int(exactly: raw)
            else { return nil }
            result.append(value)
            offset += 4
        }
        return result
    }

    private func signedLongIntegers(_ element: DICOMElement) -> [Int]? {
        guard element.value.count % 4 == 0 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(element.value.count / 4)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt32(element.value, at: offset, bigEndian: element.isBigEndian),
                  let value = Int(exactly: Int32(bitPattern: raw))
            else { return nil }
            result.append(value)
            offset += 4
        }
        return result
    }

    private func signedVeryLongIntegers(_ element: DICOMElement) -> [Int]? {
        guard element.value.count % 8 == 0 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(element.value.count / 8)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt64(element.value, at: offset, bigEndian: element.isBigEndian),
                  let value = Int(exactly: Int64(bitPattern: raw))
            else { return nil }
            result.append(value)
            offset += 8
        }
        return result
    }

    private func unsignedVeryLongIntegers(_ element: DICOMElement) -> [Int]? {
        guard element.value.count % 8 == 0 else { return nil }
        var result: [Int] = []
        result.reserveCapacity(element.value.count / 8)
        var offset = 0
        while offset < element.value.count {
            guard let raw = readUInt64(element.value, at: offset, bigEndian: element.isBigEndian),
                  let value = Int(exactly: raw)
            else { return nil }
            result.append(value)
            offset += 8
        }
        return result
    }

    private func readUInt16(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt16? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 2 else {
            return nil
        }
        let first = UInt16(data[data.startIndex + offset])
        let second = UInt16(data[data.startIndex + offset + 1])
        if bigEndian {
            return (first << 8) | second
        }
        return (second << 8) | first
    }

    private func readUInt32(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 4 else {
            return nil
        }
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }

    private func readUInt64(_ data: Data, at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset <= data.count, data.count - offset >= 8 else {
            return nil
        }

        var value: UInt64 = 0
        if bigEndian {
            var index = 0
            while index < 8 {
                value = (value << 8) | UInt64(data[data.startIndex + offset + index])
                index += 1
            }
        } else {
            var index = 8
            while index > 0 {
                index -= 1
                value = (value << 8) | UInt64(data[data.startIndex + offset + index])
            }
        }
        return value
    }
}
