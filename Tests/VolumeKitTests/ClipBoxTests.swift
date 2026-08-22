import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Il riquadro di lettura: guardare una parte senza toccare il volume.
//
// La prova che conta di più non è geometrica: è che le tre righe passate allo shader lascino
// passare **tutto** quando non c'è nulla da ritagliare. Da quello dipende che la strada senza
// riquadro costi quanto prima e che non serva un ramo nello shader — e un errore lì non si
// vedrebbe come un errore, si vedrebbe come metà volume sparito senza motivo.

@Suite("Riquadro di lettura")
struct ClipBoxTests {

    /// Cubo di cento millimetri, centrato nell'origine, assiale.
    private func makeGeometry() throws -> VolumeGeometry {
        try VolumeGeometry(
            columnCount: 100, rowCount: 100, sliceCount: 100,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial, originMM: Vec3(-49.5, -49.5, -49.5))
    }

    /// Volume ruotato di trenta gradi attorno a z: il caso in cui gli assi non coincidono.
    private func makeRotatedGeometry() throws -> VolumeGeometry {
        let angle = Double.pi / 6
        let orientation = try #require(
            SliceOrientation(
                columnDirection: Vec3(cos(angle), sin(angle), 0),
                rowDirection: Vec3(-sin(angle), cos(angle), 0)))
        return try VolumeGeometry(
            columnCount: 100, rowCount: 100, sliceCount: 100,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: orientation, originMM: Vec3(-49.5, -49.5, -49.5))
    }

    /// Applica le tre righe come fa lo shader.
    private func isInside(_ rows: [SIMD4<Float>], texture: Vec3) -> Bool {
        for row in rows {
            let value =
                Double(row.x) * texture.x + Double(row.y) * texture.y
                + Double(row.z) * texture.z + Double(row.w)
            if value < 0 || value > 1 { return false }
        }
        return true
    }

    @Test("Spento lascia passare tutto, e non serve un ramo nello shader")
    func inactiveLetsEverythingThrough() throws {
        let geometry = try makeGeometry()
        let texture = try makeTextureTransform(geometry)

        var box = ClipBox.wholeVolume(geometry)
        box.isActive = false
        let rows = box.textureRows(patientToTexture: texture)

        // Anche fuori dal volume: le righe non sanno niente di dove finisce il dato, e non
        // devono — quello lo controlla già `isInsideVolume`.
        for point in [Vec3(0, 0, 0), Vec3(0.5, 0.5, 0.5), Vec3(1, 1, 1), Vec3(-5, 9, 0.2)] {
            #expect(isInside(rows, texture: point))
        }
    }

    @Test("Un riquadro vuoto non ritaglia niente invece di far sparire tutto")
    func anEmptyBoxDoesNotHideEverything() throws {
        let geometry = try makeGeometry()
        let texture = try makeTextureTransform(geometry)
        var box = ClipBox(minMM: Vec3(10, 10, 10), maxMM: Vec3(10, 10, 10))
        box.isActive = true
        #expect(box.isEmpty)
        let rows = box.textureRows(patientToTexture: texture)
        #expect(isInside(rows, texture: Vec3(0.5, 0.5, 0.5)))
    }

    @Test("Un riquadro acceso taglia dove dice, in coordinate texture")
    func anActiveBoxCutsWhereItSays() throws {
        let geometry = try makeGeometry()
        let texture = try makeTextureTransform(geometry)

        // Metà destra del volume in x: da zero a cinquanta.
        var box = ClipBox(minMM: Vec3(0, -60, -60), maxMM: Vec3(60, 60, 60))
        box.isActive = true
        let rows = box.textureRows(patientToTexture: texture)

        // Il centro del volume sta sul bordo del riquadro: dentro.
        let centre = texture.apply(toPoint: Vec3(0, 0, 0))
        #expect(isInside(rows, texture: centre))
        // Venti millimetri a destra: dentro.
        let right = texture.apply(toPoint: Vec3(20, 0, 0))
        #expect(isInside(rows, texture: right))
        // Venti a sinistra: fuori.
        let left = texture.apply(toPoint: Vec3(-20, 0, 0))
        #expect(!isInside(rows, texture: left))
    }

    @Test("Su un volume ruotato taglia lungo gli assi Patient, non lungo quelli del volume")
    func aRotatedVolumeIsCutAlongPatientAxes() throws {
        // È il motivo per cui le righe sono una matrice e non un min/max in coordinate texture:
        // con il riquadro contenitore, su un volume inclinato, resterebbe dentro una fetta di
        // quel che si voleva togliere.
        let geometry = try makeRotatedGeometry()
        let texture = try makeTextureTransform(geometry)

        var box = ClipBox(minMM: Vec3(0, -80, -80), maxMM: Vec3(80, 80, 80))
        box.isActive = true
        let rows = box.textureRows(patientToTexture: texture)

        // Punti scelti in **Patient**: il taglio deve seguire x = 0 comunque sia ruotato il
        // volume sotto.
        for offset in [1.0, 10, 30] {
            #expect(isInside(rows, texture: texture.apply(toPoint: Vec3(offset, 5, 5))))
            #expect(!isInside(rows, texture: texture.apply(toPoint: Vec3(-offset, 5, 5))))
        }
    }

    @Test("Contiene un punto quando lo contiene, e sempre quando è spento")
    func containsAgreesWithItsState() {
        var box = ClipBox(minMM: Vec3(-10, -10, -10), maxMM: Vec3(10, 10, 10))
        #expect(box.contains(Vec3(100, 100, 100)), "spento non limita niente")

        box.isActive = true
        #expect(box.contains(Vec3(0, 0, 0)))
        #expect(box.contains(Vec3(10, -10, 0)), "il bordo è dentro")
        #expect(!box.contains(Vec3(11, 0, 0)))
    }

    @Test("Gli estremi si ordinano da soli")
    func extremesAreOrdered() {
        let box = ClipBox(minMM: Vec3(10, 5, 2), maxMM: Vec3(-10, -5, -2))
        #expect(box.minMM.x == -10 && box.maxMM.x == 10)
        #expect(box.sizeMM.x == 20 && box.sizeMM.y == 10 && box.sizeMM.z == 4)
    }

    @Test("Il riquadro dell'intero volume contiene il volume, e nasce spento")
    func theWholeVolumeBoxStartsInactive() throws {
        let geometry = try makeGeometry()
        let box = ClipBox.wholeVolume(geometry)
        #expect(!box.isActive)
        for corner in geometry.boundingBoxCornersMM {
            var active = box
            active.isActive = true
            #expect(active.contains(corner), "lo spigolo \(corner) resta fuori")
        }
    }

    @Test("Ristretto al volume, non ne esce")
    func clampingKeepsItInsideTheVolume() throws {
        let geometry = try makeGeometry()
        var box = ClipBox(minMM: Vec3(-500, -500, -500), maxMM: Vec3(500, 500, 500))
        box.isActive = true
        let clamped = box.clamped(to: geometry)
        let bounds = ClipBox.wholeVolume(geometry)
        #expect(clamped.minMM.x >= bounds.minMM.x - 1e-9)
        #expect(clamped.maxMM.x <= bounds.maxMM.x + 1e-9)
        #expect(clamped.isActive)
    }

    private func makeTextureTransform(_ geometry: VolumeGeometry) throws -> Transform3D {
        // Lo stesso incatenamento di `VolumeTexture`: voxel → texture, dopo Patient → voxel.
        let voxelToTexture = Transform3D(
            columnX: Vec3(1.0 / Double(geometry.columnCount), 0, 0),
            columnY: Vec3(0, 1.0 / Double(geometry.rowCount), 0),
            columnZ: Vec3(0, 0, 1.0 / Double(geometry.sliceCount)),
            origin: Vec3(
                0.5 / Double(geometry.columnCount),
                0.5 / Double(geometry.rowCount),
                0.5 / Double(geometry.sliceCount)))
        return voxelToTexture.concatenating(geometry.patientToVoxel)
    }
}
