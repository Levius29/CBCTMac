import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Il cubo di orientamento deve dire il vero.
//
// Una faccia etichettata al contrario manda a destra chi doveva andare a sinistra, e su una
// pianificazione implantare non è un dettaglio estetico. È anche il genere di errore che
// guardando non si scopre: un cubo con S e I scambiate sembra un cubo perfettamente normale
// finché non si prova a tornare dove si era.

@Suite("Cubo di orientamento")
struct OrientationCubeTests {

    private func camera(azimuth: Double, elevation: Double) -> VolumeCamera {
        VolumeCamera(
            azimuth: azimuth, elevation: elevation,
            halfHeightMM: 60, targetMM: .zero)
    }

    @Test("Da davanti si vede la faccia anteriore, e non le tre opposte")
    func fromTheFrontTheAnteriorFaceShows() {
        let faces = OrientationCubeGeometry.visibleFaces(camera: camera(azimuth: 0, elevation: 0))
        let names = Set(faces.map(\.face))
        #expect(names.contains(.anterior))
        #expect(!names.contains(.posterior), "la faccia dietro non si disegna")
        #expect(OrientationCubeGeometry.frontFace(camera: camera(azimuth: 0, elevation: 0)) == .anterior)
    }

    @Test("Girando di novanta gradi si passa a una faccia laterale")
    func aQuarterTurnShowsASide() {
        let quarter = camera(azimuth: .pi / 2, elevation: 0)
        let front = OrientationCubeGeometry.frontFace(camera: quarter)
        #expect(front == .left || front == .right, "a novanta gradi si guarda di lato, non \(front)")

        // E mezzo giro porta all'opposto di dove si era.
        let half = camera(azimuth: .pi, elevation: 0)
        #expect(OrientationCubeGeometry.frontFace(camera: half) == .posterior)
    }

    @Test("Guardando dall'alto si vede la faccia superiore")
    func fromAboveTheSuperiorFaceShows() {
        let above = camera(azimuth: 0, elevation: .pi / 2 - 0.01)
        #expect(OrientationCubeGeometry.frontFace(camera: above) == .superior)
        let below = camera(azimuth: 0, elevation: -.pi / 2 + 0.01)
        #expect(OrientationCubeGeometry.frontFace(camera: below) == .inferior)
    }

    @Test("Non si vedono mai due facce opposte insieme")
    func oppositeFacesAreNeverBothVisible() {
        let opposites: [(OrientationCubeGeometry.Face, OrientationCubeGeometry.Face)] = [
            (.left, .right), (.anterior, .posterior), (.superior, .inferior),
        ]
        for azimuth in stride(from: 0.0, to: 2 * .pi, by: 0.3) {
            for elevation in stride(from: -1.2, through: 1.2, by: 0.3) {
                let visible = Set(
                    OrientationCubeGeometry
                        .visibleFaces(camera: camera(azimuth: azimuth, elevation: elevation))
                        .map(\.face))
                for pair in opposites {
                    #expect(
                        !(visible.contains(pair.0) && visible.contains(pair.1)),
                        "a \(azimuth), \(elevation) si vedono sia \(pair.0) sia \(pair.1)")
                }
                // E da qualunque angolo se ne vede almeno una: un cubo non sparisce mai.
                #expect(!visible.isEmpty)
            }
        }
    }

    @Test("Le facce hanno quattro vertici in giro, non a farfalla")
    func facesAreProperQuadrilaterals() {
        // Presi in ordine sbagliato i quattro vertici si annodano, e a schermo compare una
        // clessidra invece di una faccia. Un quadrilatero che gira ha area non nulla e i due
        // lati opposti che non si incrociano: si verifica con l'area con segno del poligono.
        for azimuth in stride(from: 0.0, to: 2 * .pi, by: 0.4) {
            let faces = OrientationCubeGeometry.visibleFaces(
                camera: camera(azimuth: azimuth, elevation: 0.5))
            for projected in faces where projected.facing > 0.2 {
                #expect(projected.corners.count == 4)
                var area = 0.0
                for index in 0..<4 {
                    let a = projected.corners[index]
                    let b = projected.corners[(index + 1) % 4]
                    area += a.x * b.y - b.x * a.y
                }
                #expect(abs(area) > 1e-6, "faccia \(projected.face) degenere a \(azimuth)")
            }
        }
    }

    @Test("Le facce visibili sono ordinate dalla più lontana alla più vicina")
    func facesAreSortedBackToFront() {
        let faces = OrientationCubeGeometry.visibleFaces(
            camera: camera(azimuth: 0.7, elevation: 0.4))
        for index in 1..<faces.count {
            #expect(faces[index - 1].depth >= faces[index].depth)
        }
    }

    @Test("Il grado di frontalità va da zero a uno e vale uno di fronte")
    func facingIsNormalised() {
        let faces = OrientationCubeGeometry.visibleFaces(camera: camera(azimuth: 0, elevation: 0))
        let anterior = faces.first { $0.face == .anterior }
        #expect(anterior != nil)
        #expect(abs((anterior?.facing ?? 0) - 1) < 1e-9)
        for projected in faces {
            #expect(projected.facing > 0 && projected.facing <= 1 + 1e-9)
        }
    }
}
