import DICOMCore
import Foundation

// Pianificazione guidata dalla protesi.
//
// # L'ordine giusto è l'inverso di quello comodo
//
// La via comoda è posizionare l'impianto dove c'è osso e poi arrangiare la protesi sopra. La via
// corretta è l'opposta: si mette prima il dente, dove la funzione e l'estetica lo vogliono, e poi
// l'impianto **sotto di esso**. L'impianto serve la protesi, non il contrario, e un impianto
// perfettamente inserito nell'osso che emerge fuori dalla corona è inservibile.
//
// Questo file fornisce i due pezzi che mancavano: una sagoma di dente da posare come riferimento,
// e il vincolo che lega il suo asse a quello dell'impianto.
//
// # Geometria generica, non da catalogo
//
// Il dente è un parallelepipedo con le misure medie del suo numero FDI. Non è pigrizia: per
// pianificare serve l'**ingombro** e la direzione, non la fedeltà estetica, e le forme dei denti
// dei produttori sono materiale protetto. Un blocco delle proporzioni giuste risponde alla
// domanda che si pone in fase di piano — «l'impianto emerge dentro questo dente?» — meglio di
// quanto farebbe una corona modellata, che invece serve al laboratorio.

// MARK: - Dente protesico

/// Dente protesico parametrico, come sagoma di riferimento.
public struct ProstheticTooth: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    /// Numerazione FDI: 11…18, 21…28, 31…38, 41…48.
    public var toothNumber: Int
    /// Centro della corona, in millimetri Patient.
    public var positionMM: Vec3
    /// Asse del dente, dall'occlusale **verso l'apice**. Stesso verso dell'asse implantare, così
    /// due assi allineati hanno divergenza nulla e non 180°.
    public var axisMM: Vec3
    public var widthMM: Double
    public var heightMM: Double
    public var depthMM: Double
    public var label: String
    public var colorHex: String
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        toothNumber: Int,
        positionMM: Vec3,
        axisMM: Vec3 = Vec3(0, 0, -1),
        widthMM: Double,
        heightMM: Double,
        depthMM: Double,
        label: String = "",
        colorHex: String = "#EFE7D8",
        isVisible: Bool = true
    ) {
        self.id = id
        self.toothNumber = toothNumber
        self.positionMM = positionMM
        self.axisMM = axisMM.normalized ?? Vec3(0, 0, -1)
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.depthMM = depthMM
        self.label = label.isEmpty ? "\(toothNumber)" : label
        self.colorHex = colorHex
        self.isVisible = isVisible
    }

    /// Vero se il numero appartiene alla numerazione FDI permanente.
    ///
    /// Si rifiuta invece di accettare e collocare: il primo numero è il quadrante, e un «19» non
    /// è un dente in fondo al primo quadrante — è un quadrante che non esiste. Accettarlo
    /// significherebbe mettere una corona da qualche parte e non poter dire dove.
    public static func isValidFDI(_ number: Int) -> Bool {
        let quadrant = number / 10
        let position = number % 10
        return (1...4).contains(quadrant) && (1...8).contains(position)
    }

    /// Misure medie per un dente permanente, dal suo numero FDI.
    ///
    /// I valori sono medie di popolazione arrotondate, non misure di questo paziente: servono a
    /// dare alla sagoma le proporzioni giuste, e vanno corrette a mano quando l'anatomia lo chiede.
    ///
    /// - Returns: `nil` per un numero che non appartiene alla numerazione FDI.
    public static func standard(forToothNumber number: Int, at positionMM: Vec3 = .zero)
        -> ProstheticTooth?
    {
        guard isValidFDI(number) else { return nil }
        let position = number % 10
        let isUpper = number / 10 <= 2

        // Larghezza mesio-distale, altezza della corona, spessore vestibolo-linguale.
        let size: (width: Double, height: Double, depth: Double)
        switch position {
        case 1: size = isUpper ? (8.6, 10.5, 7.1) : (5.3, 9.0, 6.0)   // incisivo centrale
        case 2: size = isUpper ? (6.6, 9.0, 6.4) : (5.7, 9.5, 6.5)    // incisivo laterale
        case 3: size = isUpper ? (7.6, 11.0, 8.1) : (6.8, 11.0, 7.5)  // canino
        case 4: size = isUpper ? (7.1, 8.5, 9.2) : (7.1, 8.5, 7.9)    // primo premolare
        case 5: size = isUpper ? (6.6, 8.5, 9.0) : (7.1, 8.0, 8.2)    // secondo premolare
        case 6: size = isUpper ? (10.4, 7.5, 11.0) : (11.2, 7.5, 10.5)  // primo molare
        case 7: size = isUpper ? (9.8, 7.0, 11.0) : (10.7, 7.0, 10.5)   // secondo molare
        default: size = isUpper ? (8.5, 6.5, 10.0) : (10.0, 6.5, 9.5)   // terzo molare
        }

        return ProstheticTooth(
            toothNumber: number,
            positionMM: positionMM,
            // Verso l'apice: in alto i denti superiori hanno l'apice sopra la corona, in basso
            // sotto. In LPS l'asse z cresce verso la testa.
            axisMM: isUpper ? Vec3(0, 0, 1) : Vec3(0, 0, -1),
            widthMM: size.width,
            heightMM: size.height,
            depthMM: size.depth)
    }

    /// Piano occlusale del dente: passa per la superficie masticante, perpendicolare all'asse.
    ///
    /// Sta a mezza altezza **dalla parte opposta all'apice**, cioè dove il dente incontra
    /// l'antagonista: è lì che l'impianto deve emergere, non al centro della corona.
    public var occlusalCentreMM: Vec3 { positionMM - axisMM * (heightMM * 0.5) }

    /// Terna ortonormale della corona: mesio-distale, vestibolo-linguale, asse.
    ///
    /// - Parameter mesialDirectionMM: la tangente all'arcata nel punto del dente. Serve
    ///   davvero: un asse ammette infinite perpendicolari, e sceglierne una qualunque
    ///   ruoterebbe la corona attorno a sé stessa mettendo la larghezza mesio-distale dove sta
    ///   lo spessore vestibolo-linguale. Su un molare i due valori differiscono di un
    ///   millimetro appena, su un incisivo centrale superiore di 8,6 contro 7,1 — e comunque
    ///   l'orientamento sbagliato si vede subito guardando l'assiale.
    ///
    ///   Quando manca — nessuna curva d'arcata tracciata — si prende la perpendicolare più
    ///   stabile che si possa costruire dall'asse. L'ingombro resta corretto; l'orientamento
    ///   attorno all'asse è convenzionale, e va corretto tracciando l'arcata.
    public func frame(mesialDirectionMM: Vec3? = nil)
        -> (mesial: Vec3, buccal: Vec3, axis: Vec3)
    {
        let axis = axisMM.normalized ?? Vec3(0, 0, -1)

        // Si toglie dalla direzione proposta la parte lungo l'asse: quel che resta giace nel
        // piano occlusale, che è dove la larghezza va misurata.
        var mesial: Vec3? = nil
        if let proposed = mesialDirectionMM, proposed.isFinite {
            let flattened = proposed - axis * axis.dot(proposed)
            // La soglia scarta una tangente quasi parallela all'asse: normalizzarla
            // amplificherebbe l'errore numerico in una direzione arbitraria, che è peggio
            // della convenzione dichiarata sotto.
            if flattened.length > 1e-6 { mesial = flattened.normalized }
        }

        if mesial == nil {
            // Fra i tre assi del riferimento si prende quello **meno** allineato all'asse del
            // dente: garantisce che la differenza non degeneri, qualunque sia l'inclinazione.
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
            mesial = (chosen - axis * axis.dot(chosen)).normalized ?? Vec3(1, 0, 0)
        }

        let m = mesial ?? Vec3(1, 0, 0)
        let buccal = axis.cross(m).normalized ?? Vec3(0, 1, 0)
        return (m, buccal, axis)
    }

    /// Gli otto vertici della sagoma, in millimetri Patient.
    ///
    /// L'ordine è quello di un cubo: prima la faccia occlusale, poi quella apicale, ciascuna
    /// percorsa in giro. Serve a chi disegna gli spigoli senza dover ricalcolare la terna.
    public func corners(mesialDirectionMM: Vec3? = nil) -> [Vec3] {
        let (mesial, buccal, axis) = frame(mesialDirectionMM: mesialDirectionMM)
        let halfWidth = widthMM * 0.5
        let halfDepth = depthMM * 0.5
        let halfHeight = heightMM * 0.5

        var result = [Vec3]()
        result.reserveCapacity(8)
        for alongAxis in [-halfHeight, halfHeight] {
            let centre = positionMM + axis * alongAxis
            result.append(centre - mesial * halfWidth - buccal * halfDepth)
            result.append(centre + mesial * halfWidth - buccal * halfDepth)
            result.append(centre + mesial * halfWidth + buccal * halfDepth)
            result.append(centre - mesial * halfWidth + buccal * halfDepth)
        }
        return result
    }

    /// Le dodici coppie di indici che formano gli spigoli di `corners(mesialDirectionMM:)`.
    public static let cornerEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 0),
        (4, 5), (5, 6), (6, 7), (7, 4),
        (0, 4), (1, 5), (2, 6), (3, 7),
    ]
}

// MARK: - Gravità del vincolo

public enum ConstraintSeverity: Hashable, Sendable, Codable {
    case acceptable
    case caution
    case unacceptable

    public var localizedName: String {
        switch self {
        case .acceptable: return "Accettabile"
        case .caution: return "Attenzione"
        case .unacceptable: return "Non accettabile"
        }
    }
}

/// Soglie di divergenza fra asse protesico e asse implantare, in gradi.
///
/// - Important: sono **orientative**, non una regola clinica. I valori predefiniti — 15° e 25° —
///   sono quelli comunemente citati per l'angolazione di un moncone, ma la soglia vera dipende dal
///   sistema implantare, dal tipo di connessione, dal carico previsto e dal singolo caso. Il
///   programma segnala, non decide, e chi legge il segnale deve poterlo scavalcare.
public struct ProstheticThresholds: Hashable, Sendable, Codable {
    public var cautionDegrees: Double
    public var unacceptableDegrees: Double
    /// Oltre questo scostamento l'emergenza cade fuori dalla corona.
    public var emergenceCautionMM: Double

    public init(
        cautionDegrees: Double = 15,
        unacceptableDegrees: Double = 25,
        emergenceCautionMM: Double = 2
    ) {
        self.cautionDegrees = cautionDegrees
        self.unacceptableDegrees = unacceptableDegrees
        self.emergenceCautionMM = emergenceCautionMM
    }

    public static let standard = ProstheticThresholds()
}

// MARK: - Vincolo

/// Vincolo fra un dente protesico e l'impianto che lo sostiene.
public struct ProstheticConstraint: Hashable, Sendable {

    public let toothAxisMM: Vec3
    public let implantAxisMM: Vec3
    /// Centro della superficie occlusale del dente, e punto attorno a cui si misura l'emergenza.
    public let occlusalCentreMM: Vec3
    /// Metà larghezza della corona: oltre questo scostamento l'emergenza è fuori dal dente.
    public let crownHalfWidthMM: Double
    public let implantPlatformMM: Vec3
    public let thresholds: ProstheticThresholds

    public init(
        toothAxisMM: Vec3,
        implantAxisMM: Vec3,
        occlusalCentreMM: Vec3,
        crownHalfWidthMM: Double,
        implantPlatformMM: Vec3,
        thresholds: ProstheticThresholds = .standard
    ) {
        self.toothAxisMM = toothAxisMM.normalized ?? Vec3(0, 0, -1)
        self.implantAxisMM = implantAxisMM.normalized ?? Vec3(0, 0, -1)
        self.occlusalCentreMM = occlusalCentreMM
        self.crownHalfWidthMM = crownHalfWidthMM
        self.implantPlatformMM = implantPlatformMM
        self.thresholds = thresholds
    }

    /// Comodità: costruisce il vincolo da un dente e da un impianto già posati.
    public init(
        tooth: ProstheticTooth,
        implant: ImplantPlacement,
        thresholds: ProstheticThresholds = .standard
    ) {
        self.init(
            toothAxisMM: tooth.axisMM,
            implantAxisMM: implant.axis,
            occlusalCentreMM: tooth.occlusalCentreMM,
            crownHalfWidthMM: tooth.widthMM * 0.5,
            implantPlatformMM: implant.platformMM,
            thresholds: thresholds)
    }

    /// Angolo fra i due assi, in gradi. Sempre l'acuto, per la stessa ragione di
    /// `LineAngleMeasurement`: il verso con cui sono stati posati non è informazione clinica.
    public var divergenceDegrees: Double {
        let cosine = min(max(abs(toothAxisMM.dot(implantAxisMM)), 0), 1)
        return Foundation.acos(cosine) * 180 / .pi
    }

    /// Punto in cui l'asse dell'impianto, prolungato, incontra il piano occlusale del dente.
    ///
    /// - Returns: `nil` quando l'asse è **parallelo** al piano occlusale. Lì l'intersezione non
    ///   esiste, e restituire un punto lontanissimo — che è ciò che produce la divisione per un
    ///   denominatore quasi nullo — darebbe uno scostamento di chilometri presentato come una
    ///   misura. Meglio dire che non c'è.
    public var emergenceMM: Vec3? {
        let denominator = implantAxisMM.dot(toothAxisMM)
        guard abs(denominator) > 1e-6 else { return nil }
        let t = (occlusalCentreMM - implantPlatformMM).dot(toothAxisMM) / denominator
        let point = implantPlatformMM + implantAxisMM * t
        return point.isFinite ? point : nil
    }

    /// Scostamento fra l'emergenza e il centro della corona, in millimetri.
    public var emergenceOffsetMM: Double? {
        emergenceMM.map { $0.distance(to: occlusalCentreMM) }
    }

    /// Vero quando l'impianto emerge **dentro** il perimetro della corona.
    public var emergesWithinCrown: Bool {
        guard let offset = emergenceOffsetMM else { return false }
        return offset <= crownHalfWidthMM
    }

    /// Gravità complessiva.
    ///
    /// **L'emergenza pesa più della divergenza**, e questa è la decisione che rende utile il
    /// vincolo. Un impianto molto divergente resta protesicamente corretto se emerge nel punto
    /// giusto — si compensa con un moncone angolato, che è routine. Un impianto quasi parallelo
    /// che emerge fuori dalla corona non si compensa con nulla. Un giudizio basato sul solo
    /// angolo direbbe il contrario in entrambi i casi.
    public var severity: ConstraintSeverity {
        guard let offset = emergenceOffsetMM else { return .unacceptable }

        if offset > crownHalfWidthMM { return .unacceptable }
        if divergenceDegrees > thresholds.unacceptableDegrees { return .unacceptable }
        if divergenceDegrees > thresholds.cautionDegrees { return .caution }
        if offset > thresholds.emergenceCautionMM { return .caution }
        return .acceptable
    }

    /// Riassunto per l'ispettore e per la relazione.
    public var summary: String {
        guard let offset = emergenceOffsetMM else {
            return "Asse parallelo al piano occlusale: emergenza non definita"
        }
        return String(
            format: "Divergenza %.0f° · emergenza %.1f mm dal centro", divergenceDegrees, offset
        ).replacingOccurrences(of: ".", with: ",")
    }
}
