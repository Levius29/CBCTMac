import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Indicare un punto nel riquadro 3D.
//
// # Che cosa si verifica, e come
//
// Sul fantoccio, che ha un cubo di venti millimetri esatti al centro. Guardandolo da davanti, il
// raggio che passa per il pixel centrale deve incontrare la faccia anteriore del cubo a **dieci
// millimetri esatti** dal centro; girando la telecamera di novanta gradi, la faccia laterale,
// alla stessa distanza. Due numeri noti da due direzioni diverse: una sola formula sbagliata di
// segno passa la prima prova e cade sulla seconda.
//
// E poi l'invariante che non dipende dal fantoccio: il punto restituito, riproiettato, deve
// ricadere sul pixel da cui il raggio è partito. Se ci ricade, il punto sta sul raggio — che è
// tutto ciò che «indicare» significa.

@Suite("Indicare una superficie nel 3D")
struct SurfacePickingTests {

    static let side = 400

    func phantom() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 80, rows: 80, slices: 80, spacingMM: Vec3(0.75, 0.75, 0.75))
    }

    func projector(_ volume: Volume, azimuth: Double = 0, elevation: Double = 0) -> ScreenProjector
    {
        var camera = VolumeCamera.fitted(to: volume.geometry)
        camera.azimuth = azimuth
        camera.elevation = elevation
        return ScreenProjector(camera: camera, pixelWidth: Self.side, pixelHeight: Self.side)
    }

    private var centrePixel: Double { Double(Self.side) / 2 }

    @Test("Da davanti si colpisce la faccia anteriore del cubo")
    func theFrontFaceIsHitFromTheFront() throws {
        let volume = try phantom()
        let centre = volume.geometry.centerMM
        let picked = try #require(
            projector(volume).pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 0))

        // La faccia anteriore sta dieci millimetri davanti al centro, e davanti è `y` minore.
        #expect(abs(picked.y - (centre.y - SyntheticVolume.cubeEdgeMM / 2)) < 0.4)
        #expect(abs(picked.x - centre.x) < 0.4)
        #expect(abs(picked.z - centre.z) < 0.4)
    }

    @Test("Di lato si colpisce la faccia laterale, alla stessa distanza")
    func theSideFaceIsHitFromTheSide() throws {
        let volume = try phantom()
        let centre = volume.geometry.centerMM
        // Novanta gradi: la telecamera passa sul fianco e guarda verso `-L`.
        let picked = try #require(
            projector(volume, azimuth: .pi / 2).pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 0))

        #expect(abs(picked.x - (centre.x + SyntheticVolume.cubeEdgeMM / 2)) < 0.4)
        #expect(abs(picked.y - centre.y) < 0.4)
    }

    @Test("Dall'alto si colpisce la faccia superiore")
    func theTopFaceIsHitFromAbove() throws {
        let volume = try phantom()
        let centre = volume.geometry.centerMM
        // Elevazione positiva: la telecamera sale e guarda verso il basso.
        let picked = try #require(
            projector(volume, elevation: 1.5).pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 0))

        #expect(picked.z > centre.z)
        #expect(abs(picked.z - (centre.z + SyntheticVolume.cubeEdgeMM / 2)) < 1.0)
    }

    @Test("Il punto indicato sta sul raggio da cui è partito")
    func thePickedPointLiesOnItsOwnRay() throws {
        // L'invariante che non dipende dal fantoccio: riproiettando il punto si deve tornare al
        // pixel di partenza. Se ci si torna, il punto sta sul raggio — ed è tutto ciò che
        // «indicare» vuol dire.
        let volume = try phantom()
        let screen = projector(volume, azimuth: 0.7, elevation: 0.4)

        var found = 0
        for x in stride(from: 140.0, through: 260.0, by: 30) {
            for y in stride(from: 140.0, through: 260.0, by: 30) {
                guard
                    let picked = screen.pickSurfacePointMM(
                        x: x, y: y, in: volume, thresholdGV: 0)
                else { continue }
                found += 1
                let back = screen.project(picked)
                #expect(abs(back.x - x) < 0.5, "x \(back.x) invece di \(x)")
                #expect(abs(back.y - y) < 0.5, "y \(back.y) invece di \(y)")
            }
        }
        #expect(found >= 9, "solo \(found) raggi hanno colpito qualcosa")
    }

    @Test("Il bordo si affina fra due campioni, invece di cadere sul passo")
    func theEdgeIsRefinedBetweenSamples() throws {
        // Con un passo grossolano di due millimetri, un punto preso «dove il campione ha superato
        // la soglia» sbaglia di due millimetri esatti. Affinando si scende sotto il millimetro, e
        // la tolleranza sta in mezzo: è ciò che rende la prova viva invece che decorativa.
        //
        // Non si scende più giù, e la ragione è nel dato: il campionamento è trilineare su voxel
        // da 0,75 mm, quindi il bordo non è un gradino ma una rampa larga circa un voxel. Con un
        // passo di due millimetri i due campioni che la stringono cadono ai suoi lati e la retta
        // fra loro non è la rampa. Pretendere un decimo di millimetro qui vorrebbe dire pretendere
        // una precisione che il volume non ha — vedi il Contratto 5.
        let volume = try phantom()
        let centre = volume.geometry.centerMM
        let expected = centre.y - SyntheticVolume.cubeEdgeMM / 2

        let picked = try #require(
            projector(volume).pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 0, stepMM: 2))
        #expect(abs(picked.y - expected) < 1.0, "y \(picked.y) invece di \(expected)")
    }

    @Test("Un raggio che passa al largo non restituisce un punto")
    func aRayThatMissesReturnsNothing() throws {
        let volume = try phantom()
        // L'angolo del riquadro: lì il volume non c'è, e restituire il centro della scena
        // sarebbe peggio che non restituire niente — un punto plausibile e falso.
        #expect(
            projector(volume).pickSurfacePointMM(x: 1, y: 1, in: volume, thresholdGV: 0) == nil)
    }

    @Test("Una soglia più alta di tutto non trova niente")
    func aThresholdAboveEverythingFindsNothing() throws {
        let volume = try phantom()
        #expect(
            projector(volume).pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 5000) == nil)
    }

    @Test("La soglia decide che cosa si colpisce")
    func theThresholdDecidesWhatIsHit() throws {
        // Sul fantoccio la sfera di osso spongioso sta a `x` −18 e vale 400 GV; il cubo ne vale
        // 1200. Guardando di lato, una soglia bassa prende la sfera e una alta la attraversa.
        let volume = try phantom()
        let centre = volume.geometry.centerMM
        let screen = projector(volume, azimuth: -(.pi / 2))

        let soft = try #require(
            screen.pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 200))
        let hard = try #require(
            screen.pickSurfacePointMM(
                x: centrePixel, y: centrePixel, in: volume, thresholdGV: 800))

        // Con la soglia bassa si colpisce la sfera, che sta più in là del cubo lungo questa
        // direzione di vista: quindi i due punti non coincidono.
        #expect(abs(soft.x - hard.x) > 1)
        #expect(soft.x < centre.x)
    }
}
