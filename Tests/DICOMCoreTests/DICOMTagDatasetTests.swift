import Foundation
import XCTest

@testable import DICOMCore

final class DICOMTagTests: XCTestCase {
    func testDescriptionUsesFourHexDigits() {
        let tag = DICOMTag(group: 0x0028, element: 0x0030)
        XCTAssertEqual(tag.description, "(0028,0030)")
    }

    func testComparisonUsesGroupThenElement() {
        let earlierGroup = DICOMTag(group: 0x0010, element: 0xFFFF)
        let earlierElement = DICOMTag(group: 0x0020, element: 0x000D)
        let laterElement = DICOMTag(group: 0x0020, element: 0x000E)

        XCTAssertTrue(earlierGroup < earlierElement)
        XCTAssertTrue(earlierElement < laterElement)
        XCTAssertFalse(laterElement < earlierElement)
    }

    func testLongLengthVRsFollowTheBriefTable() {
        let longVRs: [VR] = [.OB, .OD, .OF, .OL, .OV, .OW, .SQ, .UC, .UN, .UR, .UT, .SV, .UV]
        for vr: VR in longVRs {
            XCTAssertTrue(vr.usesLongLength)
        }

        let shortVRs: [VR] = [.AE, .AS, .AT, .CS, .DA, .DS, .DT, .FL, .FD, .IS, .LO, .LT,
                              .PN, .SH, .SL, .SS, .ST, .TM, .UI, .UL, .US]
        for vr: VR in shortVRs {
            XCTAssertFalse(vr.usesLongLength)
        }
    }

    func testOnlyTextVRsAreStringLike() {
        XCTAssertTrue(VR.PN.isStringLike)
        XCTAssertTrue(VR.DS.isStringLike)
        XCTAssertTrue(VR.UT.isStringLike)
        XCTAssertFalse(VR.US.isStringLike)
        XCTAssertFalse(VR.OB.isStringLike)
    }
}

final class DICOMDatasetTests: XCTestCase {
    func testStringTrimsDICOMPadding() {
        let element = DICOMElement(
            tag: DICOMTags.patientName,
            vr: .PN,
            value: Data([0x20, 0x52, 0x6F, 0x73, 0x73, 0x69, 0x20, 0x00]))
        let dataset = DICOMDataset(elements: [element])

        XCTAssertEqual(dataset.string(DICOMTags.patientName), " Rossi")
    }

    func testDecimalStringValues() throws {
        let element = DICOMElement(
            tag: DICOMTags.pixelSpacing,
            vr: .DS,
            value: Data("0.2\\0.2 ".utf8))
        let dataset = DICOMDataset(elements: [element])
        let values = try XCTUnwrap(dataset.doubles(DICOMTags.pixelSpacing))

        XCTAssertEqual(values, [0.2, 0.2])
        XCTAssertEqual(dataset.double(DICOMTags.pixelSpacing), 0.2)
    }

    func testIntegerStringValues() {
        let element = DICOMElement(
            tag: DICOMTags.instanceNumber,
            vr: .IS,
            value: Data(" 7\\-2 ".utf8))
        let dataset = DICOMDataset(elements: [element])

        XCTAssertEqual(dataset.ints(DICOMTags.instanceNumber), [7, -2])
        XCTAssertEqual(dataset.int(DICOMTags.instanceNumber), 7)
    }

    func testUnsignedShortValues() {
        let element = DICOMElement(
            tag: DICOMTags.rows,
            vr: .US,
            value: Data([0x00, 0x02]))
        let dataset = DICOMDataset(elements: [element])

        XCTAssertEqual(dataset.ints(DICOMTags.rows), [512])
        XCTAssertEqual(dataset.doubles(DICOMTags.rows), [512.0])
    }

    func testSignedAndFloatingPointValues() {
        let signed = DICOMElement(
            tag: DICOMTag(group: 0x7777, element: 0x0001),
            vr: .SS,
            value: Data([0xFE, 0xFF]))
        let float = DICOMElement(
            tag: DICOMTag(group: 0x7777, element: 0x0002),
            vr: .FL,
            value: Data([0x00, 0x00, 0x20, 0xC0]))
        let double = DICOMElement(
            tag: DICOMTag(group: 0x7777, element: 0x0003),
            vr: .FD,
            value: Data([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xF4, 0x3F]))
        let dataset = DICOMDataset(elements: [signed, float, double])

        XCTAssertEqual(dataset.int(signed.tag), -2)
        XCTAssertEqual(dataset.double(float.tag), -2.5)
        XCTAssertEqual(dataset.double(double.tag), 1.25)
    }

    func testElementSpecificEndianness() {
        let littleTag = DICOMTag(group: 0x7777, element: 0x0010)
        let bigTag = DICOMTag(group: 0x7777, element: 0x0011)
        let little = DICOMElement(tag: littleTag, vr: .UL, value: Data([0x00, 0x02, 0x00, 0x00]))
        let big = DICOMElement(
            tag: bigTag,
            vr: .UL,
            value: Data([0x00, 0x00, 0x02, 0x00]),
            isBigEndian: true)
        let dataset = DICOMDataset(elements: [little, big])

        XCTAssertEqual(dataset.int(littleTag), 512)
        XCTAssertEqual(dataset.int(bigTag), 512)
    }

    func testVec3UsesDoublePrecision() throws {
        let element = DICOMElement(
            tag: DICOMTags.imagePositionPatient,
            vr: .DS,
            value: Data("-12.125\\3.5\\0.000000001".utf8))
        let dataset = DICOMDataset(elements: [element])
        let vector = try XCTUnwrap(dataset.vec3(DICOMTags.imagePositionPatient))

        XCTAssertEqual(vector, Vec3(-12.125, 3.5, 0.000000001))
    }

    func testTruncatedBinaryReturnsNil() {
        let element = DICOMElement(
            tag: DICOMTags.columns,
            vr: .US,
            value: Data([0x01]))
        let dataset = DICOMDataset(elements: [element])

        XCTAssertNil(dataset.ints(DICOMTags.columns))
        XCTAssertNil(dataset.doubles(DICOMTags.columns))
    }

    func testPreservesFileOrder() {
        let first = DICOMElement(tag: DICOMTags.patientID, vr: .LO, value: Data("A".utf8))
        let second = DICOMElement(tag: DICOMTags.modality, vr: .CS, value: Data("CT".utf8))
        let dataset = DICOMDataset(elements: [first, second])

        XCTAssertEqual(dataset.allElements.count, 2)
        XCTAssertEqual(dataset.allElements[0].tag, DICOMTags.patientID)
        XCTAssertEqual(dataset.allElements[1].tag, DICOMTags.modality)
        XCTAssertEqual(dataset[DICOMTags.modality]?.value, Data("CT".utf8))
    }
}
