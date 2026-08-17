import XCTest
import DICOMCore
@testable import MeshKit

final class ICPTests: XCTestCase {
    func testRefinementRecoversKnownTransform() throws {
        let source = makeICPPointCloud(count: 60)
        let expected = try makeICPTransform()
        let target = transformedPoints(source, by: expected)
        let initial = try perturbedTransform(around: expected)
        var options = ICPOptions()
        options.maxIterations = 30
        options.toleranceMM = 1e-8
        options.maxCorrespondenceDistanceMM = 2.0
        options.trimFraction = 0.9
        options.sampleLimit = 5_000

        let result = try ICP.refine(
            source: source,
            target: target,
            initial: initial,
            options: options
        )

        XCTAssertLessThan(result.rmsErrorMM, 0.01)
        XCTAssertGreaterThan(result.transform.determinant, 0)
        XCTAssertTrue(result.transform.isApproximatelyEqual(to: expected, tolerance: 1e-5))
        XCTAssertTrue(result.converged)
        XCTAssertEqual(result.pointCount, 54)
    }

    func testTrimmedICPRejectsThirtyPercentUnmatchedPoints() throws {
        let inliers = makeICPPointCloud(count: 30)
        var source = inliers
        var outlierIndex = 0
        while outlierIndex < 10 {
            let base = inliers[outlierIndex * 2]
            source.append(base + Vec3(0.35, -0.25, 1.25 + Double(outlierIndex) * 0.02))
            outlierIndex += 1
        }

        let expected = try makeICPTransform()
        let target = transformedPoints(inliers, by: expected)
        let initial = try perturbedTransform(around: expected)
        var options = ICPOptions()
        options.maxIterations = 30
        options.toleranceMM = 1e-8
        options.maxCorrespondenceDistanceMM = 2.0
        options.trimFraction = 0.7

        let result = try ICP.refine(
            source: source,
            target: target,
            initial: initial,
            options: options
        )

        XCTAssertLessThan(result.rmsErrorMM, 0.01)
        XCTAssertTrue(result.transform.isApproximatelyEqual(to: expected, tolerance: 1e-4))
        XCTAssertEqual(result.pointCount, 28)
    }

    func testIterationLimitReturnsUsableNonConvergedResult() throws {
        let source = makeICPPointCloud(count: 20)
        let expected = try makeICPTransform()
        var target = transformedPoints(source, by: expected)
        target[0] += Vec3(0.0012, -0.0007, 0.0003)
        let initial = try perturbedTransform(around: expected)
        var options = ICPOptions()
        options.maxIterations = 1
        options.toleranceMM = 0
        options.trimFraction = 1

        let result = try ICP.refine(
            source: source,
            target: target,
            initial: initial,
            options: options
        )

        XCTAssertFalse(result.converged)
        XCTAssertEqual(result.iterations, 1)
        XCTAssertTrue(result.rmsErrorMM.isFinite)
        XCTAssertTrue(result.transform.origin.isFinite)
    }

    func testTooFewCorrespondencesThrowDidNotConverge() {
        let source = [Vec3.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)]
        let target = [Vec3(100, 100, 100), Vec3(101, 100, 100), Vec3(100, 101, 100)]
        var options = ICPOptions()
        options.maxCorrespondenceDistanceMM = 0.1

        XCTAssertThrowsError(try ICP.refine(
            source: source,
            target: target,
            initial: .identity,
            options: options
        )) { (error: any Error) in
            guard let registrationError = error as? RegistrationError,
                  case .didNotConverge(let iterations, _) = registrationError
            else {
                XCTFail("Atteso didNotConverge, ricevuto \(error)")
                return
            }
            XCTAssertEqual(iterations, 1)
        }
    }

    func testDegenerateAlignErrorPropagatesUnchanged() {
        let line = [Vec3(0, 0, 0), Vec3(0.5, 0, 0), Vec3(1, 0, 0), Vec3(1.5, 0, 0)]
        var options = ICPOptions()
        options.trimFraction = 1

        XCTAssertThrowsError(try ICP.refine(
            source: line,
            target: line,
            initial: .identity,
            options: options
        )) { (error: any Error) in
            guard let registrationError = error as? RegistrationError,
                  case .degenerateConfiguration = registrationError
            else {
                XCTFail("Atteso degenerateConfiguration, ricevuto \(error)")
                return
            }
        }
    }

    func testNonFinitePointsAreSkippedWithoutGridConversionTrap() throws {
        var source = makeICPPointCloud(count: 12)
        var target = source
        source.append(Vec3(Double.nan, 0, 0))
        target.append(Vec3(0, Double.infinity, 0))
        var options = ICPOptions()
        options.trimFraction = 1

        let result = try ICP.refine(
            source: source,
            target: target,
            initial: .identity,
            options: options
        )
        XCTAssertTrue(result.rmsErrorMM.isFinite)
        XCTAssertEqual(result.pointCount, 12)
    }

    func testInvalidOptionsThrowDegenerateConfiguration() {
        let points = makeICPPointCloud(count: 5)
        var options = ICPOptions()
        options.sampleLimit = 2

        XCTAssertThrowsError(try ICP.refine(
            source: points,
            target: points,
            initial: .identity,
            options: options
        )) { (error: any Error) in
            guard let registrationError = error as? RegistrationError,
                  case .degenerateConfiguration = registrationError
            else {
                XCTFail("Atteso degenerateConfiguration, ricevuto \(error)")
                return
            }
        }
    }

    func testFiveConsecutiveRMSIncreasesThrowDivergence() throws {
        var tracker = ICPConvergenceTracker()
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.0, toleranceMM: 0, iteration: 1))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.1, toleranceMM: 0, iteration: 2))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.2, toleranceMM: 0, iteration: 3))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.3, toleranceMM: 0, iteration: 4))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.4, toleranceMM: 0, iteration: 5))

        XCTAssertThrowsError(
            try tracker.record(rmsErrorMM: 1.5, toleranceMM: 0, iteration: 6)
        ) { (error: any Error) in
            XCTAssertEqual(
                error as? RegistrationError,
                .didNotConverge(iterations: 6, rmsErrorMM: 1.5)
            )
        }
    }

    func testRMSDecreaseResetsDivergenceCounter() throws {
        var tracker = ICPConvergenceTracker()
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.0, toleranceMM: 0, iteration: 1))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.1, toleranceMM: 0, iteration: 2))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.2, toleranceMM: 0, iteration: 3))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.15, toleranceMM: 0, iteration: 4))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.2, toleranceMM: 0, iteration: 5))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.3, toleranceMM: 0, iteration: 6))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.4, toleranceMM: 0, iteration: 7))
        XCTAssertFalse(try tracker.record(rmsErrorMM: 1.5, toleranceMM: 0, iteration: 8))
    }

    func testEmptyPointCloudThrowsEmptyMesh() {
        XCTAssertThrowsError(try ICP.refine(
            source: [],
            target: [Vec3.zero],
            initial: .identity,
            options: ICPOptions()
        )) { (error: any Error) in
            XCTAssertEqual(error as? RegistrationError, .emptyMesh)
        }
    }

    private func makeICPTransform() throws -> Transform3D {
        let rotation = try XCTUnwrap(
            Transform3D.rotation(axis: Vec3(0.3, 0.7, 0.2), angle: 0.18)
        )
        return Transform3D(
            columnX: rotation.columnX,
            columnY: rotation.columnY,
            columnZ: rotation.columnZ,
            origin: Vec3(3.2, -1.7, 0.8)
        )
    }

    private func perturbedTransform(around expected: Transform3D) throws -> Transform3D {
        let smallRotation = try XCTUnwrap(
            Transform3D.rotation(axis: Vec3(1, -0.5, 0.25), angle: 0.008)
        )
        let perturbation = Transform3D(
            columnX: smallRotation.columnX,
            columnY: smallRotation.columnY,
            columnZ: smallRotation.columnZ,
            origin: Vec3(0.08, -0.06, 0.04)
        )
        return perturbation.concatenating(expected)
    }

    private func transformedPoints(_ points: [Vec3], by transform: Transform3D) -> [Vec3] {
        var result = [Vec3]()
        result.reserveCapacity(points.count)
        for point: Vec3 in points {
            result.append(transform.apply(toPoint: point))
        }
        return result
    }
}

func makeICPPointCloud(count: Int) -> [Vec3] {
    var points = [Vec3]()
    guard count > 0 else { return points }
    points.reserveCapacity(count)
    var index = 0
    while index < count {
        let i = Double(index)
        let x = Double(index % 7) * 1.4 + 0.03 * i
        let y = Double((index * 3) % 11) * 1.1 + 0.02 * i
        let z = Double((index * index + 3 * index) % 13) * 0.7 + 0.015 * i
        points.append(Vec3(x, y, z))
        index += 1
    }
    return points
}
