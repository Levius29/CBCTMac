import Foundation
import XCTest

@testable import DICOMCore

final class DICOMParserTests: XCTestCase {
    func testExplicitLittleEndianRoundTrip() throws {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(
            tag: DICOMTags.sopInstanceUID,
            vr: .UI,
            value: builder.paddedUI("1.2.3.4"))
        builder.appendExplicit(tag: DICOMTags.rows, vr: .US, value: [0x00, 0x02])

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .includingPixelData,
            sourceName: "explicit.dcm")

        XCTAssertEqual(parsed.transferSyntax, .explicitVRLittleEndian)
        XCTAssertEqual(parsed.dataset.string(DICOMTags.sopInstanceUID), "1.2.3.4")
        XCTAssertEqual(parsed.dataset.int(DICOMTags.rows), 512)
    }

    func testImplicitLittleEndianInfersPixelDataVR() throws {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2"))
        builder.appendImplicit(
            tag: DICOMTags.sopInstanceUID,
            value: builder.paddedUI("1.2.3.5"))
        builder.appendImplicit(tag: DICOMTags.rows, value: [0x00, 0x02])
        let expectedRange = builder.appendImplicit(
            tag: DICOMTags.pixelData,
            value: [0x10, 0x20, 0x30, 0x40])

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .includingPixelData,
            sourceName: "implicit.dcm")

        XCTAssertEqual(parsed.transferSyntax, .implicitVRLittleEndian)
        XCTAssertEqual(parsed.dataset[DICOMTags.pixelData]?.vr, .OW)
        XCTAssertEqual(
            parsed.dataset[DICOMTags.pixelData]?.value,
            Data([0x10, 0x20, 0x30, 0x40]))
        XCTAssertEqual(parsed.pixelDataRange, expectedRange)
    }

    func testHeaderlessImplicitFallback() throws {
        var builder = DICOMByteStreamBuilder()
        builder.appendImplicit(
            tag: DICOMTags.sopInstanceUID,
            value: builder.paddedUI("1.2.3.6"))
        builder.appendImplicit(tag: DICOMTags.columns, value: [0x80, 0x02])

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "headerless.dcm")

        XCTAssertEqual(parsed.transferSyntax, .implicitVRLittleEndian)
        XCTAssertEqual(parsed.dataset.string(DICOMTags.sopInstanceUID), "1.2.3.6")
        XCTAssertEqual(parsed.dataset.int(DICOMTags.columns), 640)
    }

    func testRandomBytesAreNotDICOM() {
        let random = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00])

        XCTAssertThrowsError(try DICOMParser.parse(
            data: random,
            depth: .metadataOnly,
            sourceName: "image.png")) { (error: any Error) in
                XCTAssertTrue(error is DICOMParsingError)
            }
    }

    func testTruncatedValueThrows() {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(tag: DICOMTags.rows, vr: .US, value: [0x00, 0x02])
        builder.removeLastByte()

        XCTAssertThrowsError(try DICOMParser.parse(
            data: builder.data,
            depth: .includingPixelData,
            sourceName: "truncated.dcm")) { (error: any Error) in
                XCTAssertTrue(error is DICOMParsingError)
            }
    }

    func testFileMetaGroupLength() throws {
        var metaTail = DICOMByteStreamBuilder()
        metaTail.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: metaTail.paddedUI("1.2.840.10008.1.2"))

        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.fileMetaGroupLength,
            vr: .UL,
            value: builder.littleEndianUInt32(UInt32(metaTail.bytes.count)))
        builder.appendRaw(metaTail.bytes)
        builder.appendImplicit(
            tag: DICOMTags.sopInstanceUID,
            value: builder.paddedUI("1.2.3.7"))

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "group-length.dcm")

        XCTAssertEqual(parsed.dataset.string(DICOMTags.sopInstanceUID), "1.2.3.7")
    }

    func testExplicitBigEndian() throws {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.2"))
        builder.appendExplicit(
            tag: DICOMTags.rows,
            vr: .US,
            value: [0x02, 0x00],
            bigEndian: true)

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "big-endian.dcm")

        XCTAssertEqual(parsed.transferSyntax, .explicitVRBigEndian)
        XCTAssertEqual(parsed.dataset.int(DICOMTags.rows), 512)
    }

    func testMetadataOnlyStopsAtPixelData() throws {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(tag: DICOMTags.rows, vr: .US, value: [0x00, 0x02])
        let expectedRange = builder.appendExplicit(
            tag: DICOMTags.pixelData,
            vr: .OW,
            value: [0x01, 0x02, 0x03, 0x04])
        builder.appendExplicit(
            tag: DICOMTags.modality,
            vr: .CS,
            value: builder.paddedText("CT"))

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "metadata-only.dcm")

        XCTAssertEqual(parsed.pixelDataRange, expectedRange)
        XCTAssertEqual(parsed.dataset[DICOMTags.pixelData]?.value.isEmpty, true)
        XCTAssertNil(parsed.dataset[DICOMTags.modality])
    }

    func testDeflatedIsRejected() {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1.99"))

        XCTAssertThrowsError(try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "deflated.dcm")) { (error: any Error) in
                guard let parsingError = error as? DICOMParsingError else {
                    XCTFail("Atteso deflatedNotSupported, ricevuto \(error)")
                    return
                }
                guard case .deflatedNotSupported = parsingError else {
                    XCTFail("Atteso deflatedNotSupported, ricevuto \(error)")
                    return
                }
            }
    }

    func testDefinedLengthSequenceIsSkipped() throws {
        let sequenceTag = DICOMTag(group: 0x0008, element: 0x1115)
        var sequenceValue = DICOMByteStreamBuilder()
        sequenceValue.appendSpecial(tag: DICOMTags.item, length: 0)

        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(tag: sequenceTag, vr: .SQ, value: sequenceValue.bytes)
        builder.appendExplicit(
            tag: DICOMTags.modality,
            vr: .CS,
            value: builder.paddedText("CT"))

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "defined-sequence.dcm")

        XCTAssertEqual(parsed.dataset[sequenceTag]?.vr, .SQ)
        XCTAssertEqual(parsed.dataset[sequenceTag]?.value.isEmpty, true)
        XCTAssertEqual(parsed.dataset.string(DICOMTags.modality), "CT")
    }

    func testNestedUndefinedLengthSequenceIsSkipped() throws {
        let outerSequence = DICOMTag(group: 0x0008, element: 0x1115)
        let innerSequence = DICOMTag(group: 0x0008, element: 0x1140)

        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicitUndefinedLengthHeader(tag: outerSequence, vr: .SQ)
        builder.appendSpecial(tag: DICOMTags.item, length: UInt32.max)
        builder.appendExplicitUndefinedLengthHeader(tag: innerSequence, vr: .SQ)
        builder.appendSpecial(tag: DICOMTags.item, length: 0)
        builder.appendSpecial(tag: DICOMTags.sequenceDelimitation, length: 0)
        builder.appendSpecial(tag: DICOMTags.itemDelimitation, length: 0)
        builder.appendSpecial(tag: DICOMTags.sequenceDelimitation, length: 0)
        builder.appendExplicit(
            tag: DICOMTags.modality,
            vr: .CS,
            value: builder.paddedText("CT"))

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "nested-sequence.dcm")

        XCTAssertEqual(parsed.dataset[outerSequence]?.value.isEmpty, true)
        XCTAssertEqual(parsed.dataset.string(DICOMTags.modality), "CT")
    }

    func testEncapsulatedPixelDataRange() throws {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.4.50"))
        builder.appendExplicitUndefinedLengthHeader(tag: DICOMTags.pixelData, vr: .OB)
        let firstItemOffset = builder.bytes.count
        builder.appendSpecial(tag: DICOMTags.item, length: 0)
        builder.appendSpecial(tag: DICOMTags.item, length: 4)
        builder.appendRaw([0xFF, 0xD8, 0xFF, 0xD9])
        let delimiterOffset = builder.bytes.count
        builder.appendSpecial(tag: DICOMTags.sequenceDelimitation, length: 0)

        let parsed = try DICOMParser.parse(
            data: builder.data,
            depth: .metadataOnly,
            sourceName: "encapsulated.dcm")

        XCTAssertEqual(parsed.pixelDataRange, firstItemOffset..<delimiterOffset)
        XCTAssertTrue(parsed.isEncapsulatedPixelData)
        XCTAssertEqual(parsed.dataset[DICOMTags.pixelData]?.value.isEmpty, true)
    }

    func testLocalizedErrorsContainContext() {
        let truncated = DICOMParsingError.truncated(
            sourceName: "broken.dcm",
            atOffset: 145)
        let unexpected = DICOMParsingError.unexpectedTag(
            sourceName: "sequence.dcm",
            tag: DICOMTags.itemDelimitation,
            atOffset: 300)

        XCTAssertTrue(truncated.localizedDescription.contains("broken.dcm"))
        XCTAssertTrue(truncated.localizedDescription.contains("145"))
        XCTAssertTrue(unexpected.localizedDescription.contains("sequence.dcm"))
        XCTAssertTrue(unexpected.localizedDescription.contains("(FFFE,E00D)"))
        XCTAssertTrue(unexpected.localizedDescription.contains("300"))
    }
}
