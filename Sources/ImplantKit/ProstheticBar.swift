import DICOMCore
import Foundation
import MeshKit

// La barra che unisce gli impianti.
//
// # A che cosa serve
//
// Su una riabilitazione a carico immediato — quattro o sei impianti che portano un'arcata
// intera — gli impianti non lavorano separati: sono uniti da una struttura rigida che
// distribuisce il carico. Pianificarla insieme agli impianti serve a due cose che la
// pianificazione dei soli impianti non dice.
//
// La prima è la **fattibilità**: una barra passa sopra le piattaforme, e se un impianto emerge
// tre millimetri più in basso degli altri la barra o lo scavalca — e lì lo spessore di resina
// si assottiglia — o si abbassa, e allora tocca la gengiva. Vederla disegnata lo dice prima.
//
// La seconda è l'**ingombro verticale**: fra la barra e i denti antagonisti deve restarci la
// protesi. È lo spazio protesico, ed è la ragione per cui un impianto a volte si affonda di due
// millimetri in più.
//
// # Che cosa non è
//
// Non è un progetto da fondere. Le barre vere hanno sezioni sagomate, ritenzioni e attacchi che
// dipendono dal sistema, e nessuno di quei dettagli si può indovinare da qui. Questa è un tubo
// che segue le piattaforme: dice dove passa e quanto ingombra, che sono le due domande della
// fase di piano.

public struct ProstheticBar: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    /// Gli impianti attraversati, nell'ordine in cui la barra li percorre.
    public var implantIDs: [UUID]
    /// Diametro del tubo, in millimetri.
    public var diameterMM: Double
    /// Quanto la barra sta **sopra** le piattaforme, verso l'occlusale.
    ///
    /// Positivo verso la bocca. Zero significa barra centrata sul piano delle piattaforme, che
    /// è la posizione di partenza: da lì si alza per lasciare spazio all'igiene sotto, o si
    /// abbassa per guadagnare spazio protesico sopra.
    public var offsetMM: Double
    public var label: String
    public var colorHex: String
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        implantIDs: [UUID],
        diameterMM: Double = 4,
        offsetMM: Double = 2,
        label: String = "Barra",
        colorHex: String = "#D8C88A",
        isVisible: Bool = true
    ) {
        self.id = id
        self.implantIDs = implantIDs
        self.diameterMM = Swift.max(diameterMM, 0.5)
        self.offsetMM = offsetMM
        self.label = label
        self.colorHex = colorHex
        self.isVisible = isVisible
    }

    /// I punti che la barra tocca, uno per impianto.
    ///
    /// Ogni punto sta sulla piattaforma del suo impianto, spostato di `offsetMM` lungo l'asse
    /// **verso l'occlusale** — cioè nel verso opposto all'apice, che è dove la protesi sta.
    ///
    /// Gli impianti non trovati si saltano: una barra sopravvive alla cancellazione di un
    /// impianto passando dai rimanenti, invece di sparire o di puntare al nulla.
    public func nodesMM(in implants: [ImplantPlacement]) -> [Vec3] {
        var byID: [UUID: ImplantPlacement] = [:]
        for implant in implants { byID[implant.id] = implant }

        var nodes: [Vec3] = []
        for identifier in implantIDs {
            guard let implant = byID[identifier] else { continue }
            let point = implant.platformMM - implant.axis * offsetMM
            guard point.isFinite else { continue }
            nodes.append(point)
        }
        return nodes
    }

    /// Lunghezza della barra, in millimetri.
    public func lengthMM(in implants: [ImplantPlacement]) -> Double {
        let nodes = nodesMM(in: implants)
        guard nodes.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<nodes.count {
            total += nodes[index].distance(to: nodes[index - 1])
        }
        return total
    }

    /// Vero quando la barra ha almeno due appoggi, cioè quando esiste.
    public func isUsable(in implants: [ImplantPlacement]) -> Bool {
        nodesMM(in: implants).count >= 2
    }
}

// MARK: - Ordinamento e costruzione

public enum ProstheticBarBuilder: Sendable {

    /// Ordina gli impianti lungo una polilinea, tipicamente la curva d'arcata.
    ///
    /// # Perché non basta l'ordine in cui sono stati posati
    ///
    /// Perché nessuno posa gli impianti da destra a sinistra: si comincia dal sito più delicato.
    /// Una barra che li unisse nell'ordine di creazione andrebbe avanti e indietro lungo
    /// l'arcata, e non sarebbe una barra — sarebbe un gomitolo.
    ///
    /// - Parameter alongMM: i punti della curva. Con meno di due punti si ripiega sull'ordine
    ///   dato, che è l'unico ordine disponibile.
    public static func ordered(
        _ implants: [ImplantPlacement], alongMM path: [Vec3]
    ) -> [ImplantPlacement] {
        guard path.count >= 2 else { return implants }

        /// Quanto lontano lungo la polilinea cade la proiezione del punto.
        func arcLength(of pointMM: Vec3) -> Double {
            var best = (distance: Double.infinity, arc: 0.0)
            var travelled = 0.0
            for index in 1..<path.count {
                let a = path[index - 1]
                let b = path[index]
                let segment = b - a
                let length = segment.length
                guard length > 1e-9 else { continue }
                let t = Swift.min(Swift.max((pointMM - a).dot(segment) / (length * length), 0), 1)
                let projected = a + segment * t
                let distance = projected.distance(to: pointMM)
                if distance < best.distance {
                    best = (distance, travelled + t * length)
                }
                travelled += length
            }
            return best.arc
        }

        return implants
            .map { (implant: $0, arc: arcLength(of: $0.platformMM)) }
            .sorted { $0.arc < $1.arc }
            .map(\.implant)
    }

    /// La superficie della barra: un tubo poligonale lungo i nodi.
    ///
    /// Gli spigoli non sono raccordati. In un gomito la sezione ruota di colpo e le due fasce si
    /// compenetrano leggermente all'interno della curva: è invisibile a questi angoli — fra due
    /// impianti adiacenti la barra piega di pochi gradi — e raccordarlo richiederebbe un
    /// arrotondamento che, non essendo quello della barra vera, sarebbe una precisione finta.
    public static func surface(
        of bar: ProstheticBar,
        implants: [ImplantPlacement],
        segments: Int = 16,
        name: String? = nil
    ) -> Mesh {
        let nodes = bar.nodesMM(in: implants)
        let label = name ?? bar.label
        guard nodes.count >= 2 else {
            return Mesh(verticesMM: [], triangles: [], name: label)
        }

        let sides = Swift.max(segments, 3)
        let radius = bar.diameterMM / 2
        var vertices: [Vec3] = []
        var triangles: [Triangle] = []

        // Una terna sola per tutta la barra invece di una per nodo: fra un nodo e il successivo
        // la sezione resterebbe altrimenti ruotata a caso, e le fasce si torcerebbero. Con una
        // terna comune il tubo è coerente, al prezzo di una sezione leggermente ellittica dove
        // la barra piega — che a questi angoli è sotto il decimo di millimetro.
        let overall = (nodes[nodes.count - 1] - nodes[0]).normalized ?? Vec3(1, 0, 0)
        let (right, up) = perpendicularFrame(to: overall)

        for node in nodes {
            for side in 0..<sides {
                let angle = 2 * Double.pi * Double(side) / Double(sides)
                vertices.append(
                    node + right * (Foundation.cos(angle) * radius)
                        + up * (Foundation.sin(angle) * radius))
            }
        }

        for ring in 0..<(nodes.count - 1) {
            let lower = ring * sides
            let upper = (ring + 1) * sides
            for side in 0..<sides {
                let next = (side + 1) % sides
                triangles.append(Triangle(a: lower + side, b: upper + next, c: upper + side))
                triangles.append(Triangle(a: lower + side, b: lower + next, c: upper + next))
            }
        }

        // I due tappi, come sull'impianto: una superficie aperta non si stampa.
        let firstCentre = vertices.count
        vertices.append(nodes[0])
        for side in 0..<sides {
            let next = (side + 1) % sides
            triangles.append(Triangle(a: firstCentre, b: next, c: side))
        }

        let lastRing = (nodes.count - 1) * sides
        let lastCentre = vertices.count
        vertices.append(nodes[nodes.count - 1])
        for side in 0..<sides {
            let next = (side + 1) % sides
            triangles.append(Triangle(a: lastCentre, b: lastRing + side, c: lastRing + next))
        }

        return Mesh(verticesMM: vertices, triangles: triangles, name: label)
    }

    private static func perpendicularFrame(to axis: Vec3) -> (right: Vec3, up: Vec3) {
        let candidates = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        var chosen = candidates[0]
        var smallest = Double.infinity
        for candidate in candidates {
            let alignment = Swift.abs(candidate.dot(axis))
            if alignment < smallest {
                smallest = alignment
                chosen = candidate
            }
        }
        let right = (chosen - axis * axis.dot(chosen)).normalized ?? Vec3(1, 0, 0)
        let up = axis.cross(right).normalized ?? Vec3(0, 1, 0)
        return (right, up)
    }
}
