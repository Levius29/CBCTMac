import Testing

@testable import DICOMCore

@Suite("Campionamento del volume")
struct VolumeTests {

    private func volume() throws -> Volume {
        let geometry = try VolumeGeometry(
            columnCount: 2,
            rowCount: 2,
            sliceCount: 2,
            columnSpacingMM: 1,
            rowSpacingMM: 1,
            sliceSpacingMM: 1,
            orientation: .standardAxial,
            originMM: .zero)
        return try Volume(geometry: geometry, samples: (0..<8).map { Int16($0) })
    }

    @Test("Il nearest neighbour rifiuta coordinate non rappresentabili")
    func nearestRejectsInvalidCoordinates() throws {
        let volume = try volume()

        #expect(volume.densityValue(atPatient: Vec3(.nan, 0, 0)) == nil)
        #expect(volume.densityValue(atPatient: Vec3(.infinity, 0, 0)) == nil)
        #expect(volume.densityValue(atPatient: Vec3(Double.greatestFiniteMagnitude, 0, 0)) == nil)
    }
}
