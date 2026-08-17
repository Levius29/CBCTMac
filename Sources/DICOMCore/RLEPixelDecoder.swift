import Foundation

/// Decodifica DICOM RLE Lossless (PS3.5, Annex G) in Swift puro.
///
/// Nei campioni a 16 bit i segmenti sono piani di byte: prima tutti i byte più significativi,
/// poi tutti quelli meno significativi. Trattarli come blocchi consecutivi di campioni crea
/// immagini riconoscibili ma con valori completamente errati.
public struct RLEPixelDecoder: PixelDecoder {
    public init() {}

    public func canDecode(_ transferSyntax: TransferSyntax) -> Bool {
        transferSyntax == .rleLossless
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
        let pixelCount = try PixelSampleNormalizer.validate(descriptor, frameIndex: frameIndex)
        guard data.count >= 64 else {
            throw PixelDecodingError.truncatedPixelData(expected: 64, available: data.count)
        }

        let segmentCountValue = readUInt32LE(data, at: 0)
        guard let segmentCount = Int(exactly: segmentCountValue),
              segmentCount == descriptor.bytesPerSample,
              segmentCount > 0,
              segmentCount <= 15
        else {
            throw PixelDecodingError.malformedCompressedData(
                "RLE dichiara \(segmentCountValue) segmenti; attesi \(descriptor.bytesPerSample)")
        }

        var offsets: [Int] = []
        offsets.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let rawOffset = readUInt32LE(data, at: 4 + index * 4)
            guard let offset = Int(exactly: rawOffset), offset >= 64, offset < data.count else {
                throw PixelDecodingError.malformedCompressedData(
                    "offset \(rawOffset) non valido per il segmento RLE \(index)")
            }
            if let previous = offsets.last, offset <= previous {
                throw PixelDecodingError.malformedCompressedData(
                    "offset dei segmenti RLE non strettamente crescenti")
            }
            offsets.append(offset)
        }

        var planes: [[UInt8]] = []
        planes.reserveCapacity(segmentCount)
        for index in 0..<segmentCount {
            let end = index + 1 < segmentCount ? offsets[index + 1] : data.count
            let plane = try decodePackBits(
                data, range: offsets[index]..<end, expectedCount: pixelCount, segmentIndex: index)
            planes.append(plane)
        }

        var words = [UInt16](repeating: 0, count: pixelCount)
        if descriptor.bitsAllocated == 8 {
            for index in 0..<pixelCount {
                words[index] = UInt16(planes[0][index])
            }
        } else {
            // Annex G ordina i piani dal byte più significativo al meno significativo,
            // indipendentemente dall'endianness del dataset che contiene PixelData.
            for index in 0..<pixelCount {
                words[index] = (UInt16(planes[0][index]) << 8) | UInt16(planes[1][index])
            }
        }
        return PixelSampleNormalizer.normalize(words, descriptor: descriptor)
    }

    private func decodePackBits(
        _ data: Data,
        range: Range<Int>,
        expectedCount: Int,
        segmentIndex: Int
    ) throws -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(expectedCount)
        var cursor = range.lowerBound

        while output.count < expectedCount {
            guard cursor < range.upperBound else {
                throw PixelDecodingError.truncatedPixelData(
                    expected: expectedCount, available: output.count)
            }
            let control = data[cursor]
            cursor += 1

            if control <= 127 {
                let count = Int(control) + 1
                guard cursor <= range.upperBound, count <= range.upperBound - cursor else {
                    throw PixelDecodingError.malformedCompressedData(
                        "run letterale troncato nel segmento RLE \(segmentIndex)")
                }
                guard count <= expectedCount - output.count else {
                    throw PixelDecodingError.malformedCompressedData(
                        "segmento RLE \(segmentIndex) produce troppi campioni")
                }
                for offset in 0..<count {
                    output.append(data[cursor + offset])
                }
                cursor += count
            } else if control == 128 {
                // 128 è esplicitamente un no-op PackBits; alcuni encoder lo usano come padding.
                continue
            } else {
                let count = 257 - Int(control)
                guard cursor < range.upperBound else {
                    throw PixelDecodingError.malformedCompressedData(
                        "run ripetuto troncato nel segmento RLE \(segmentIndex)")
                }
                guard count <= expectedCount - output.count else {
                    throw PixelDecodingError.malformedCompressedData(
                        "segmento RLE \(segmentIndex) produce troppi campioni")
                }
                let value = data[cursor]
                cursor += 1
                for _ in 0..<count {
                    output.append(value)
                }
            }
        }
        return output
    }

    private func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
