import DICOMCore
import Foundation

// Il cubo di orientamento: geometria, separata dal disegno.
//
// # Perché un cubo vero e non un quadrato con una lettera
//
// Perché un quadrato dice **quale faccia guardi**, e basta. Ruotando un cranio senza tessuti
// molli si perde il senso di dove sia il davanti, e la domanda che ci si pone non è «che faccia
// vedo» ma «di quanto sono girato, e da che parte devo tornare». A quella risponde solo un
// oggetto che gira insieme al modello: si legge l'inclinazione dalle facce che si scorciano, e
// si sa da che parte tirare senza doverci pensare.
//
// La geometria sta qui e non nella vista perché è la parte che può essere sbagliata in modo
// silenzioso — una faccia etichettata al contrario manda l'utente a destra quando doveva andare
// a sinistra, e su una pianificazione implantare quello non è un dettaglio estetico. Nella vista
// resta il disegno, che sbagliato si vede.
public enum OrientationCubeGeometry: Sendable {

    /// Le sei facce, con la lettera anatomica che portano.
    ///
    /// Convenzione LPS, la stessa del resto del programma: +x è la sinistra del paziente, +y il
    /// posteriore, +z il superiore.
    public enum Face: String, CaseIterable, Sendable {
        case left = "L"
        case right = "R"
        case posterior = "P"
        case anterior = "A"
        case superior = "S"
        case inferior = "I"

        /// La normale uscente, in millimetri Patient.
        public var normal: Vec3 {
            switch self {
            case .left: return Vec3(1, 0, 0)
            case .right: return Vec3(-1, 0, 0)
            case .posterior: return Vec3(0, 1, 0)
            case .anterior: return Vec3(0, -1, 0)
            case .superior: return Vec3(0, 0, 1)
            case .inferior: return Vec3(0, 0, -1)
            }
        }

        /// Nome per esteso, per il suggerimento.
        public var localizedName: String {
            switch self {
            case .left: return "Sinistra"
            case .right: return "Destra"
            case .posterior: return "Posteriore"
            case .anterior: return "Anteriore"
            case .superior: return "Superiore"
            case .inferior: return "Inferiore"
            }
        }
    }

    /// Una faccia pronta da disegnare: i suoi quattro vertici sullo schermo, in ordine di giro.
    public struct ProjectedFace: Sendable {
        public let face: Face
        /// I quattro vertici, in coordinate da −1 a 1 con y verso il basso.
        public let corners: [(x: Double, y: Double)]
        /// Centro proiettato, dove va la lettera.
        public let centre: (x: Double, y: Double)
        /// Profondità del centro: cresce allontanandosi dall'osservatore.
        public let depth: Double
        /// Quanto la faccia è rivolta verso di noi, da 0 (di taglio) a 1 (di fronte).
        public let facing: Double
    }

    /// Le facce **visibili**, dalla più lontana alla più vicina.
    ///
    /// Ordinate così perché chi disegna le sovrappone in quest'ordine: su un cubo convesso le
    /// facce visibili non si coprono fra loro, ma l'ordine costa nulla e toglie di mezzo la
    /// domanda.
    ///
    /// Le facce che guardano dall'altra parte non compaiono affatto: su un cubo opaco stanno
    /// dietro, e disegnarle metterebbe la lettera sbagliata sopra quella giusta.
    public static func visibleFaces(camera: VolumeCamera) -> [ProjectedFace] {
        let right = camera.right
        let down = camera.down
        let forward = camera.forward

        func project(_ point: Vec3) -> (x: Double, y: Double, depth: Double) {
            (x: point.dot(right), y: point.dot(down), depth: point.dot(forward))
        }

        var result: [ProjectedFace] = []
        for face in Face.allCases {
            let normal = face.normal
            let facing = -normal.dot(forward)
            // Di taglio o rivolta via: non si disegna. La soglia è zero stretto, così una faccia
            // esattamente di profilo — che si vedrebbe come una riga — non compare.
            guard facing > 1e-6 else { continue }

            // I due assi della faccia: due qualunque fra i coordinati che non siano la normale.
            let (u, v) = axes(of: normal)
            let corners = [
                normal + u + v,
                normal - u + v,
                normal - u - v,
                normal + u - v,
            ].map { corner -> (x: Double, y: Double) in
                let projected = project(corner)
                return (x: projected.x, y: projected.y)
            }
            let centre = project(normal)
            result.append(
                ProjectedFace(
                    face: face, corners: corners,
                    centre: (x: centre.x, y: centre.y),
                    depth: centre.depth, facing: facing))
        }
        return result.sorted { $0.depth > $1.depth }
    }

    /// La faccia più rivolta verso l'osservatore, che è quella che dà il nome alla vista.
    public static func frontFace(camera: VolumeCamera) -> Face {
        var best = Face.anterior
        var bestFacing = -Double.infinity
        for face in Face.allCases {
            let facing = -face.normal.dot(camera.forward)
            if facing > bestFacing {
                bestFacing = facing
                best = face
            }
        }
        return best
    }

    /// I due assi che giacciono su una faccia, dati la sua normale.
    ///
    /// L'ordine è scelto perché i quattro vertici escano in giro invece che a zigzag: presi in
    /// ordine sbagliato il quadrilatero si annoda a farfalla, e a schermo compare una clessidra
    /// invece di una faccia.
    private static func axes(of normal: Vec3) -> (Vec3, Vec3) {
        if abs(normal.x) > 0.5 { return (Vec3(0, 1, 0), Vec3(0, 0, 1)) }
        if abs(normal.y) > 0.5 { return (Vec3(1, 0, 0), Vec3(0, 0, 1)) }
        return (Vec3(1, 0, 0), Vec3(0, 1, 0))
    }
}
