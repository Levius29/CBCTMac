import XCTest
import DICOMCore
@testable import MeshKit

final class PointRegistrationTests: XCTestCase {
    func testRecoversKnownRigidTransform() throws {
        let rotation = try XCTUnwrap(
            Transform3D.rotation(axis: Vec3(1, 2, 3), angle: 0.37)
        )
        let expected = Transform3D(
            columnX: rotation.columnX,
            columnY: rotation.columnY,
            columnZ: rotation.columnZ,
            origin: Vec3(12.5, -7.25, 3.75)
        )
        let source = registrationPoints()
        var target = [Vec3]()
        for point: Vec3 in source {
            target.append(expected.apply(toPoint: point))
        }

        let result = try PointRegistration.align(source: source, target: target)
        XCTAssertTrue(result.transform.isApproximatelyEqual(to: expected, tolerance: 1e-9))
        XCTAssertLessThan(result.rmsErrorMM, 1e-9)
        XCTAssertLessThan(result.maxErrorMM, 1e-9)
        XCTAssertEqual(result.pointCount, source.count)
        XCTAssertEqual(result.iterations, 0)
        XCTAssertTrue(result.converged)
    }

    func testResultIsRotationNotReflection() throws {
        let source = registrationPoints()
        var reflected = [Vec3]()
        for point: Vec3 in source {
            reflected.append(Vec3(-point.x + 3, point.y - 2, point.z + 1))
        }

        let result = try PointRegistration.align(source: source, target: reflected)
        XCTAssertGreaterThan(result.transform.determinant, 0)
        XCTAssertEqual(result.transform.determinant, 1.0, accuracy: 1e-9)
        XCTAssertGreaterThan(result.rmsErrorMM, 0.01)
    }

    func testMismatchedCountsThrow() {
        assertRegistrationError(
            source: [Vec3.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
            target: [Vec3.zero, Vec3(1, 0, 0)],
            expected: .mismatchedPointCounts(source: 3, target: 2)
        )
    }

    func testTooFewPointsThrow() {
        assertRegistrationError(
            source: [Vec3.zero, Vec3(1, 0, 0)],
            target: [Vec3.zero, Vec3(1, 0, 0)],
            expected: .tooFewPoints(count: 2, required: 3)
        )
    }

    func testCollinearPointsThrow() {
        let points = [Vec3(0, 0, 0), Vec3(1, 1, 1), Vec3(2, 2, 2), Vec3(4, 4, 4)]
        XCTAssertThrowsError(try PointRegistration.align(source: points, target: points)) {
            (error: any Error) in
            guard let registrationError = error as? RegistrationError,
                  case .degenerateConfiguration = registrationError
            else {
                XCTFail("Atteso degenerateConfiguration, ricevuto \(error)")
                return
            }
        }
    }

    func testCoincidentPointsThrow() {
        let points = [Vec3(2, 3, 4), Vec3(2, 3, 4), Vec3(2, 3, 4)]
        XCTAssertThrowsError(try PointRegistration.align(source: points, target: points)) {
            (error: any Error) in
            XCTAssertTrue(error is RegistrationError)
        }
    }

    func testNonFinitePointsThrow() {
        let source = [Vec3.zero, Vec3(1, 0, 0), Vec3(0, Double.infinity, 0)]
        XCTAssertThrowsError(try PointRegistration.align(source: source, target: source)) {
            (error: any Error) in
            guard let registrationError = error as? RegistrationError,
                  case .degenerateConfiguration = registrationError
            else {
                XCTFail("Atteso degenerateConfiguration, ricevuto \(error)")
                return
            }
        }
    }

    private func assertRegistrationError(
        source: [Vec3],
        target: [Vec3],
        expected: RegistrationError
    ) {
        XCTAssertThrowsError(try PointRegistration.align(source: source, target: target)) {
            (error: any Error) in
            XCTAssertEqual(error as? RegistrationError, expected)
        }
    }
}

func registrationPoints() -> [Vec3] {
    [
        Vec3(-2.0, 0.5, 1.0),
        Vec3(1.5, -1.0, 0.25),
        Vec3(0.25, 2.5, -0.75),
        Vec3(3.0, 1.25, 2.0),
        Vec3(-1.25, -2.0, 3.5),
        Vec3(0.75, 0.25, -2.5),
        Vec3(2.25, -0.5, 4.0),
    ]
}
