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

// Il verso in cui gira il modello quando si trascina.
//
// **Si trascina il modello, non la camera**: il punto che sta sotto il dito va dove va il dito.
// Erano sbagliati tutti e due i segni, e l'asimmetria del codice — uno negato e l'altro no —
// faceva pensare che uno fosse già a posto. Non lo era: quella negazione compensava soltanto il
// verso delle coordinate del drawable, dove y cresce verso il basso.
//
// È rimasto in piedi a lungo perché l'indicatore di orientamento era un quadrato piatto con una
// lettera: sull'asse verticale non poteva mostrare niente, e su un cranio quasi simmetrico chi
// gira corregge senza accorgersene. Le prove qui usano il **naso** — asimmetrico per
// costruzione, e a riposo esattamente al centro dello schermo — proprio per non dipendere da un
// osservatore che si accorga.

@Suite("Verso della rotazione")
struct OrbitDirectionTests {

    private let start = VolumeCamera(
        azimuth: 0, elevation: 0, halfHeightMM: 100, targetMM: .zero)

    /// Il naso: anteriore, cioè y negativo in LPS. A riposo cade al centro dello schermo, quindi
    /// il segno della sua posizione dice da che parte è andato.
    private let nose = Vec3(0, -80, 0)

    private func screen(_ point: Vec3, _ camera: VolumeCamera) -> (x: Double, y: Double) {
        (x: point.dot(camera.right), y: point.dot(camera.down))
    }

    @Test("A riposo il naso sta al centro: è il riferimento di tutto il resto")
    func theNoseStartsAtTheCentre() {
        #expect(abs(screen(nose, start).x) < 1e-9)
        #expect(abs(screen(nose, start).y) < 1e-9)
    }

    @Test("Trascinando a destra il naso va a destra")
    func draggingRightMovesTheNoseRight() {
        let turned = start.orbited(byDragX: 40, y: 0)
        #expect(screen(nose, turned).x > 5, "va a \(screen(nose, turned).x)")
    }

    @Test("Trascinando a sinistra il naso va a sinistra")
    func draggingLeftMovesTheNoseLeft() {
        let turned = start.orbited(byDragX: -40, y: 0)
        #expect(screen(nose, turned).x < -5)
    }

    @Test("Trascinando in basso il naso scende")
    func draggingDownMovesTheNoseDown() {
        // Sullo schermo y cresce verso il basso.
        let turned = start.orbited(byDragX: 0, y: 40)
        #expect(screen(nose, turned).y > 5, "va a \(screen(nose, turned).y)")
    }

    @Test("Trascinando in alto il naso sale")
    func draggingUpMovesTheNoseUp() {
        let turned = start.orbited(byDragX: 0, y: -40)
        #expect(screen(nose, turned).y < -5)
    }

    @Test("I due assi seguono il dito allo stesso modo")
    func bothAxesFollowTheFinger() {
        // È la prova che conta, e nessuna delle precedenti la sostituisce: correggerne uno solo
        // è esattamente lo stato da cui si è partiti, e ciascuna delle altre guarda un asse.
        let horizontal = start.orbited(byDragX: 40, y: 0)
        let vertical = start.orbited(byDragX: 0, y: 40)
        #expect(screen(nose, horizontal).x > 0)
        #expect(screen(nose, vertical).y > 0)
        #expect(
            abs(screen(nose, horizontal).x - screen(nose, vertical).y) < 1e-9,
            "stesso trascinamento, stesso spostamento sui due assi")
    }

    @Test("Un trascinamento nullo non muove niente")
    func noDragNoRotation() {
        let same = start.orbited(byDragX: 0, y: 0)
        #expect(abs(same.azimuth - start.azimuth) < 1e-12)
        #expect(abs(same.elevation - start.elevation) < 1e-12)
    }

    @Test("Quattrocento pixel valgono mezzo giro")
    func fourHundredPixelsIsHalfATurn() {
        let turned = start.orbited(byDragX: 400, y: 0)
        #expect(abs(abs(turned.azimuth) - Double.pi) < 1e-9)
    }
}
