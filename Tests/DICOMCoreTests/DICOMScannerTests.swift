import Foundation
import XCTest

@testable import DICOMCore

final class DICOMScannerTests: XCTestCase {
    func testGroupsHierarchyWithoutSortingInstances() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstURL = directory.appendingPathComponent("first-created.dcm")
        let secondURL = directory.appendingPathComponent("second-created.dcm")
        let reportsDirectory = directory.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(
            at: reportsDirectory,
            withIntermediateDirectories: false)
        let reportURL = reportsDirectory.appendingPathComponent("report.dcm")

        try makeDICOM(
            sopInstanceUID: "1.2.3.20",
            seriesInstanceUID: "1.2.3.100",
            studyInstanceUID: "1.2.3.1000",
            modality: "CT",
            instanceNumber: 20,
            positionZ: 20.0,
            includePixelData: true).write(to: firstURL)
        try makeDICOM(
            sopInstanceUID: "1.2.3.10",
            seriesInstanceUID: "1.2.3.100",
            studyInstanceUID: "1.2.3.1000",
            modality: "CT",
            instanceNumber: 10,
            positionZ: 10.0,
            includePixelData: true).write(to: secondURL)
        try makeDICOM(
            sopInstanceUID: "1.2.3.200",
            seriesInstanceUID: "1.2.3.200",
            studyInstanceUID: "1.2.3.1000",
            modality: "SR",
            instanceNumber: nil,
            positionZ: nil,
            includePixelData: false).write(to: reportURL)

        let discovered = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [])
        let expectedByName: [String: Int] = [
            firstURL.lastPathComponent: 20,
            secondURL.lastPathComponent: 10,
        ]
        var expectedInstanceOrder: [Int] = []
        for url: URL in discovered {
            if let number = expectedByName[url.lastPathComponent] {
                expectedInstanceOrder.append(number)
            }
        }

        let result = try DICOMScanner.scan(directory: directory, progress: nil)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertEqual(result.patients.count, 1)

        let patient = try XCTUnwrap(result.patients.first)
        XCTAssertEqual(patient.patientID, "PATIENT-1")
        XCTAssertEqual(patient.name, "MOTTA^TEST")
        XCTAssertEqual(patient.studies.count, 1)

        let study = try XCTUnwrap(patient.studies.first)
        XCTAssertEqual(study.studyInstanceUID, "1.2.3.1000")
        XCTAssertEqual(study.series.count, 2)

        var imageSeries: ScannedSeries?
        var reportSeries: ScannedSeries?
        for series: ScannedSeries in study.series {
            if series.seriesInstanceUID == "1.2.3.100" {
                imageSeries = series
            }
            if series.seriesInstanceUID == "1.2.3.200" {
                reportSeries = series
            }
        }

        let ct = try XCTUnwrap(imageSeries)
        XCTAssertTrue(ct.isImageSeries)
        XCTAssertEqual(ct.rows, 512)
        XCTAssertEqual(ct.columns, 640)
        XCTAssertEqual(ct.pixelSpacingMM, PixelSpacing(rowMM: 0.2, columnMM: 0.3))
        XCTAssertEqual(ct.sliceThicknessMM, 0.4)

        var actualInstanceOrder: [Int] = []
        for instance: ScannedInstance in ct.instances {
            if let number = instance.instanceNumber {
                actualInstanceOrder.append(number)
            }
            XCTAssertEqual(instance.orientation, SliceOrientation.standardAxial)
            XCTAssertNotNil(instance.positionMM)
        }
        XCTAssertEqual(actualInstanceOrder, expectedInstanceOrder)

        let sr = try XCTUnwrap(reportSeries)
        XCTAssertFalse(sr.isImageSeries)
        XCTAssertEqual(sr.modality, "SR")
        XCTAssertEqual(sr.instances.count, 1)
    }

    func testSkipsNonDICOMAndCollectsMalformedFiles() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let textURL = directory.appendingPathComponent("notes.txt")
        try Data("not a DICOM".utf8).write(to: textURL)

        var broken = DICOMByteStreamBuilder()
        broken.appendPreamble()
        broken.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: broken.paddedUI("1.2.840.10008.1.2.1"))
        broken.appendExplicit(tag: DICOMTags.rows, vr: .US, value: [0x00, 0x02])
        broken.removeLastByte()
        let brokenURL = directory.appendingPathComponent("broken.dcm")
        try broken.data.write(to: brokenURL)

        let recorder = ProgressRecorder()
        let result = try DICOMScanner.scan(
            directory: directory,
            progress: { (completed: Int, total: Int) in
                recorder.record(completed: completed, total: total)
            })

        XCTAssertTrue(result.patients.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
        let failure = try XCTUnwrap(result.failures.first)
        XCTAssertEqual(failure.url.lastPathComponent, "broken.dcm")
        XCTAssertTrue(failure.reason.contains("broken.dcm"))
        XCTAssertTrue(failure.reason.contains("offset"))

        let points = recorder.snapshot()
        let first = try XCTUnwrap(points.first)
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(first.completed, 0)
        XCTAssertEqual(first.total, 2)
        XCTAssertEqual(last.completed, 2)
        XCTAssertEqual(last.total, 2)
    }

    func testMissingRequiredUIDIsPerFileFailure() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(
            tag: DICOMTags.studyInstanceUID,
            vr: .UI,
            value: builder.paddedUI("1.2.3.1000"))
        builder.appendExplicit(
            tag: DICOMTags.seriesInstanceUID,
            vr: .UI,
            value: builder.paddedUI("1.2.3.100"))
        let url = directory.appendingPathComponent("missing-sop.dcm")
        try builder.data.write(to: url)

        let result = try DICOMScanner.scan(directory: directory, progress: nil)

        XCTAssertEqual(result.failures.count, 1)
        XCTAssertTrue(result.failures[0].reason.contains(DICOMTags.sopInstanceUID.description))
        XCTAssertTrue(result.failures[0].reason.contains("missing-sop.dcm"))
    }

    func testDirectoryErrorContainsPath() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CBCTMac-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try DICOMScanner.scan(
            directory: missing,
            progress: nil)) { (error: any Error) in
            XCTAssertTrue(error is DICOMScanningError)
            XCTAssertTrue(error.localizedDescription.contains(missing.path))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CBCTMac-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false)
        return directory
    }

    private func makeDICOM(
        sopInstanceUID: String,
        seriesInstanceUID: String,
        studyInstanceUID: String,
        modality: String,
        instanceNumber: Int?,
        positionZ: Double?,
        includePixelData: Bool
    ) -> Data {
        var builder = DICOMByteStreamBuilder()
        builder.appendPreamble()
        builder.appendExplicit(
            tag: DICOMTags.transferSyntaxUID,
            vr: .UI,
            value: builder.paddedUI("1.2.840.10008.1.2.1"))
        builder.appendExplicit(
            tag: DICOMTags.sopInstanceUID,
            vr: .UI,
            value: builder.paddedUI(sopInstanceUID))
        builder.appendExplicit(
            tag: DICOMTags.patientID,
            vr: .LO,
            value: builder.paddedText("PATIENT-1"))
        builder.appendExplicit(
            tag: DICOMTags.patientName,
            vr: .PN,
            value: builder.paddedText("MOTTA^TEST"))
        builder.appendExplicit(
            tag: DICOMTags.patientBirthDate,
            vr: .DA,
            value: builder.paddedText("19920428"))
        builder.appendExplicit(
            tag: DICOMTags.studyInstanceUID,
            vr: .UI,
            value: builder.paddedUI(studyInstanceUID))
        builder.appendExplicit(
            tag: DICOMTags.studyDate,
            vr: .DA,
            value: builder.paddedText("20260816"))
        builder.appendExplicit(
            tag: DICOMTags.studyDescription,
            vr: .LO,
            value: builder.paddedText("CBCT test"))
        builder.appendExplicit(
            tag: DICOMTags.seriesInstanceUID,
            vr: .UI,
            value: builder.paddedUI(seriesInstanceUID))
        builder.appendExplicit(
            tag: DICOMTags.seriesNumber,
            vr: .IS,
            value: builder.paddedText(modality == "CT" ? "7" : "8"))
        builder.appendExplicit(
            tag: DICOMTags.seriesDescription,
            vr: .LO,
            value: builder.paddedText(modality == "CT" ? "Volume" : "Report"))
        builder.appendExplicit(
            tag: DICOMTags.modality,
            vr: .CS,
            value: builder.paddedText(modality))

        if let instanceNumber {
            builder.appendExplicit(
                tag: DICOMTags.instanceNumber,
                vr: .IS,
                value: builder.paddedText(String(instanceNumber)))
        }
        if let positionZ {
            builder.appendExplicit(
                tag: DICOMTags.imagePositionPatient,
                vr: .DS,
                value: builder.paddedText("0\\0\\\(positionZ)"))
            builder.appendExplicit(
                tag: DICOMTags.imageOrientationPatient,
                vr: .DS,
                value: builder.paddedText("1\\0\\0\\0\\1\\0"))
        }

        builder.appendExplicit(tag: DICOMTags.rows, vr: .US, value: [0x00, 0x02])
        builder.appendExplicit(tag: DICOMTags.columns, vr: .US, value: [0x80, 0x02])
        builder.appendExplicit(
            tag: DICOMTags.pixelSpacing,
            vr: .DS,
            value: builder.paddedText("0.2\\0.3"))
        builder.appendExplicit(
            tag: DICOMTags.sliceThickness,
            vr: .DS,
            value: builder.paddedText("0.4"))

        if includePixelData {
            builder.appendExplicit(
                tag: DICOMTags.pixelData,
                vr: .OW,
                value: [0x00, 0x00])
        }
        return builder.data
    }
}

private struct ProgressPoint: Sendable {
    let completed: Int
    let total: Int
}

private final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [ProgressPoint] = []

    func record(completed: Int, total: Int) {
        lock.lock()
        points.append(ProgressPoint(completed: completed, total: total))
        lock.unlock()
    }

    func snapshot() -> [ProgressPoint] {
        lock.lock()
        let copy = points
        lock.unlock()
        return copy
    }
}
