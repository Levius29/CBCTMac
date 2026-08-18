import DICOMCore
import Foundation

// Annotazioni e misure.
//
// Regola che discende dal Contratto 1 di docs/architecture.md e vale per ogni tipo di questo
// file: **i punti sono in millimetri nello spazio Patient**. Mai in pixel, mai in coordinate
// schermo, mai in indici voxel.
//
// Non è pignoleria. Una misura salvata in pixel smette di essere valida appena l'utente
// cambia zoom, riorienta il volume sul piano occlusale o riapre il caso con un layout diverso —
// e continua a mostrare un numero, semplicemente sbagliato. Salvandola in mm Patient resta
// corretta attraverso qualunque trasformazione di vista.

// MARK: - Metadati comuni

/// Piano su cui è stata tracciata un'annotazione planare.
///
/// Serve a non mostrare una misura assiale sovrapposta a una slice sagittale distante 40 mm,
/// dove non significherebbe nulla. Le annotazioni compaiono a piena opacità sul loro piano e
/// sfumano allontanandosene.
public struct AnnotationPlaneReference: Hashable, Sendable, Codable {
    public var originMM: Vec3
    public var normalMM: Vec3
    /// Oltre questa distanza dal piano l'annotazione non si disegna più.
    public var visibilityToleranceMM: Double

    public init(originMM: Vec3, normalMM: Vec3, visibilityToleranceMM: Double = 1.0) {
        self.originMM = originMM
        self.normalMM = normalMM
        self.visibilityToleranceMM = visibilityToleranceMM
    }

    /// Distanza con segno di un punto dal piano.
    public func signedDistance(to p: Vec3) -> Double {
        guard let n = normalMM.normalized else { return .infinity }
        return (p - originMM).dot(n)
    }

    /// Opacità suggerita per il disegno: 1 sul piano, 0 oltre la tolleranza.
    public func opacity(atDistance distance: Double) -> Double {
        guard visibilityToleranceMM > 0 else { return abs(distance) < 1e-6 ? 1 : 0 }
        let t = abs(distance) / visibilityToleranceMM
        return max(0, min(1, 1 - t))
    }
}

/// Dati comuni a ogni annotazione.
public struct AnnotationMetadata: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var label: String
    /// Colore in formato `#RRGGBB`. Stringa e non tipo di piattaforma, così MeasureKit
    /// resta indipendente da AppKit e testabile su Linux.
    public var colorHex: String
    public var createdAt: Date
    public var isHidden: Bool
    public var referencePlane: AnnotationPlaneReference?
    /// Nota libera dell'utente.
    public var comment: String

    public init(
        id: UUID = UUID(),
        label: String = "",
        colorHex: String = "#32B8C6",
        createdAt: Date = Date(),
        isHidden: Bool = false,
        referencePlane: AnnotationPlaneReference? = nil,
        comment: String = ""
    ) {
        self.id = id
        self.label = label
        self.colorHex = colorHex
        self.createdAt = createdAt
        self.isHidden = isHidden
        self.referencePlane = referencePlane
        self.comment = comment
    }
}

/// Ciò che ogni annotazione sa fare.
public protocol AnnotationProtocol: Hashable, Sendable, Codable, Identifiable {
    var metadata: AnnotationMetadata { get set }
    /// Punti manipolabili dall'utente, in mm Patient, nell'ordine in cui vanno mostrati.
    var handlesMM: [Vec3] { get }
    /// Testo del valore principale, già formattato con l'unità. Vuoto se l'annotazione
    /// non esprime una misura (testo, freccia).
    var formattedValue: String { get }
}

extension AnnotationProtocol {
    public var id: UUID { metadata.id }
}

// MARK: - Distanza

/// Misura lineare fra due punti.
public struct DistanceMeasurement: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var startMM: Vec3
    public var endMM: Vec3

    public init(metadata: AnnotationMetadata = .init(), startMM: Vec3, endMM: Vec3) {
        self.metadata = metadata
        self.startMM = startMM
        self.endMM = endMM
    }

    public var lengthMM: Double { (endMM - startMM).length }
    public var midpointMM: Vec3 { startMM.lerp(to: endMM, t: 0.5) }
    public var handlesMM: [Vec3] { [startMM, endMM] }

    public var formattedValue: String {
        MeasurementFormatter.length(lengthMM)
    }
}

// MARK: - Angolo

/// Angolo fra due semirette con vertice comune.
public struct AngleMeasurement: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var vertexMM: Vec3
    public var firstArmMM: Vec3
    public var secondArmMM: Vec3

    public init(
        metadata: AnnotationMetadata = .init(),
        vertexMM: Vec3,
        firstArmMM: Vec3,
        secondArmMM: Vec3
    ) {
        self.metadata = metadata
        self.vertexMM = vertexMM
        self.firstArmMM = firstArmMM
        self.secondArmMM = secondArmMM
    }

    /// Angolo in radianti, `nil` se un braccio ha lunghezza nulla.
    public var angleRadians: Double? {
        (firstArmMM - vertexMM).angle(to: secondArmMM - vertexMM)
    }

    public var angleDegrees: Double? {
        angleRadians.map { $0 * 180.0 / Double.pi }
    }

    public var handlesMM: [Vec3] { [firstArmMM, vertexMM, secondArmMM] }

    public var formattedValue: String {
        guard let degrees = angleDegrees else { return "—" }
        return MeasurementFormatter.angle(degrees)
    }
}

// MARK: - Regioni di interesse

/// ROI ellittica su un piano.
///
/// Definita da centro e due semiassi **in mm Patient**, non da un rettangolo di schermo:
/// così resta corretta anche su piani obliqui e dopo il riorientamento.
public struct EllipseROI: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var centerMM: Vec3
    /// Primo semiasse, come vettore: direzione e lunghezza insieme.
    public var semiAxisAMM: Vec3
    /// Secondo semiasse, ortogonale al primo nel piano della ROI.
    public var semiAxisBMM: Vec3
    /// Spessore della fetta campionata attorno al piano.
    public var thicknessMM: Double

    public init(
        metadata: AnnotationMetadata = .init(),
        centerMM: Vec3,
        semiAxisAMM: Vec3,
        semiAxisBMM: Vec3,
        thicknessMM: Double = 1.0
    ) {
        self.metadata = metadata
        self.centerMM = centerMM
        self.semiAxisAMM = semiAxisAMM
        self.semiAxisBMM = semiAxisBMM
        self.thicknessMM = thicknessMM
    }

    public var areaMM2: Double {
        Double.pi * semiAxisAMM.length * semiAxisBMM.length
    }

    public var normalMM: Vec3 {
        semiAxisAMM.cross(semiAxisBMM).normalized ?? Vec3(0, 0, 1)
    }

    public var handlesMM: [Vec3] {
        [centerMM, centerMM + semiAxisAMM, centerMM + semiAxisBMM]
    }

    public var formattedValue: String {
        MeasurementFormatter.area(areaMM2)
    }

    /// Vero se `p` cade dentro il prisma ellittico.
    public func contains(_ p: Vec3) -> Bool {
        let d = p - centerMM
        guard let n = normalMM.normalized else { return false }
        guard abs(d.dot(n)) <= thicknessMM * 0.5 else { return false }

        let lenA = semiAxisAMM.length
        let lenB = semiAxisBMM.length
        guard lenA > 0, lenB > 0 else { return false }

        // Coordinate normalizzate lungo i due semiassi: dentro se u² + v² ≤ 1.
        let u = d.dot(semiAxisAMM) / (lenA * lenA)
        let v = d.dot(semiAxisBMM) / (lenB * lenB)
        return u * u + v * v <= 1.0
    }
}

/// ROI poligonale su un piano, per contorni irregolari.
public struct PolygonROI: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    /// Vertici in ordine, in mm Patient. Il poligono è implicitamente chiuso.
    public var verticesMM: [Vec3]
    public var thicknessMM: Double

    public init(
        metadata: AnnotationMetadata = .init(),
        verticesMM: [Vec3],
        thicknessMM: Double = 1.0
    ) {
        self.metadata = metadata
        self.verticesMM = verticesMM
        self.thicknessMM = thicknessMM
    }

    public var handlesMM: [Vec3] { verticesMM }

    /// Piano di giacenza stimato dai vertici col metodo di Newell, che a differenza di un
    /// semplice prodotto vettoriale su tre punti resta stabile su poligoni quasi degeneri.
    public var normalMM: Vec3 {
        guard verticesMM.count >= 3 else { return Vec3(0, 0, 1) }
        var n = Vec3.zero
        for i in 0..<verticesMM.count {
            let current = verticesMM[i]
            let next = verticesMM[(i + 1) % verticesMM.count]
            n.x += (current.y - next.y) * (current.z + next.z)
            n.y += (current.z - next.z) * (current.x + next.x)
            n.z += (current.x - next.x) * (current.y + next.y)
        }
        return n.normalized ?? Vec3(0, 0, 1)
    }

    public var centroidMM: Vec3 {
        guard !verticesMM.isEmpty else { return .zero }
        var sum = Vec3.zero
        for v in verticesMM { sum += v }
        return sum / Double(verticesMM.count)
    }

    /// Area con la formula di Gauss applicata nel piano del poligono.
    public var areaMM2: Double {
        guard verticesMM.count >= 3 else { return 0 }
        let n = normalMM
        var cross = Vec3.zero
        for i in 0..<verticesMM.count {
            let current = verticesMM[i]
            let next = verticesMM[(i + 1) % verticesMM.count]
            cross += current.cross(next)
        }
        return abs(cross.dot(n)) * 0.5
    }

    public var formattedValue: String {
        MeasurementFormatter.area(areaMM2)
    }

    /// Vero se `p` cade dentro il prisma poligonale.
    ///
    /// Test del raggio in coordinate 2D del piano: si proiettano vertici e punto su una base
    /// ortonormale locale e si contano gli attraversamenti.
    public func contains(_ p: Vec3) -> Bool {
        guard verticesMM.count >= 3 else { return false }
        let n = normalMM
        let d = p - centroidMM
        guard abs(d.dot(n)) <= thicknessMM * 0.5 else { return false }

        guard let basis = OrthonormalBasis(normal: n) else { return false }
        let point = basis.project(p - centroidMM)
        let poly = verticesMM.map { basis.project($0 - centroidMM) }

        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i]
            let b = poly[j]
            if (a.1 > point.1) != (b.1 > point.1) {
                let t = (point.1 - a.1) / (b.1 - a.1)
                if point.0 < a.0 + t * (b.0 - a.0) { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

/// ROI sferica, per campionare la densità di un volumetto attorno a un punto.
/// È la forma giusta per valutare l'osso in un sito implantare.
public struct SphereROI: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var centerMM: Vec3
    public var radiusMM: Double

    public init(metadata: AnnotationMetadata = .init(), centerMM: Vec3, radiusMM: Double) {
        self.metadata = metadata
        self.centerMM = centerMM
        self.radiusMM = radiusMM
    }

    public var volumeMM3: Double {
        4.0 / 3.0 * Double.pi * radiusMM * radiusMM * radiusMM
    }

    public var handlesMM: [Vec3] { [centerMM, centerMM + Vec3(radiusMM, 0, 0)] }

    public var formattedValue: String {
        MeasurementFormatter.volume(volumeMM3)
    }

    public func contains(_ p: Vec3) -> Bool {
        (p - centerMM).lengthSquared <= radiusMM * radiusMM
    }
}

// MARK: - Profilo

/// Profilo di densità lungo un segmento.
/// Utile a leggere lo spessore di una corticale, che a occhio si sovrastima sempre.
public struct ProfileLine: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var startMM: Vec3
    public var endMM: Vec3
    /// Numero di campioni lungo il segmento.
    public var sampleCount: Int

    public init(
        metadata: AnnotationMetadata = .init(),
        startMM: Vec3,
        endMM: Vec3,
        sampleCount: Int = 128
    ) {
        self.metadata = metadata
        self.startMM = startMM
        self.endMM = endMM
        self.sampleCount = max(2, sampleCount)
    }

    public var lengthMM: Double { (endMM - startMM).length }
    public var handlesMM: [Vec3] { [startMM, endMM] }
    public var formattedValue: String { MeasurementFormatter.length(lengthMM) }
}

// MARK: - Annotazioni non metriche

public struct TextNote: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var anchorMM: Vec3
    public var text: String

    public init(metadata: AnnotationMetadata = .init(), anchorMM: Vec3, text: String) {
        self.metadata = metadata
        self.anchorMM = anchorMM
        self.text = text
    }

    public var handlesMM: [Vec3] { [anchorMM] }
    public var formattedValue: String { "" }
}

public struct ArrowNote: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    /// Punta della freccia: il punto che si vuole indicare.
    public var tipMM: Vec3
    public var tailMM: Vec3
    public var text: String

    public init(
        metadata: AnnotationMetadata = .init(), tipMM: Vec3, tailMM: Vec3, text: String = ""
    ) {
        self.metadata = metadata
        self.tipMM = tipMM
        self.tailMM = tailMM
        self.text = text
    }

    public var handlesMM: [Vec3] { [tipMM, tailMM] }
    public var formattedValue: String { "" }
}

public struct FreehandPath: AnnotationProtocol {
    public var metadata: AnnotationMetadata
    public var pointsMM: [Vec3]
    public var isClosed: Bool

    public init(metadata: AnnotationMetadata = .init(), pointsMM: [Vec3], isClosed: Bool = false) {
        self.metadata = metadata
        self.pointsMM = pointsMM
        self.isClosed = isClosed
    }

    /// Lunghezza sviluppata del tracciato.
    public var lengthMM: Double {
        guard pointsMM.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<pointsMM.count {
            total += pointsMM[i].distance(to: pointsMM[i - 1])
        }
        if isClosed, let first = pointsMM.first, let last = pointsMM.last {
            total += last.distance(to: first)
        }
        return total
    }

    public var handlesMM: [Vec3] { pointsMM }
    public var formattedValue: String { MeasurementFormatter.length(lengthMM) }
}

// MARK: - Contenitore

/// Una qualunque annotazione.
///
/// Enum e non protocollo esistenziale: `Codable` si sintetizza da solo, `Sendable` pure, e la
/// serializzazione del piano resta banale.
public enum Annotation: Hashable, Sendable, Codable, Identifiable {
    case distance(DistanceMeasurement)
    case angle(AngleMeasurement)
    case ellipseROI(EllipseROI)
    case polygonROI(PolygonROI)
    case sphereROI(SphereROI)
    case profileLine(ProfileLine)
    case text(TextNote)
    case arrow(ArrowNote)
    case freehand(FreehandPath)

    /// Attributi comuni: nome, colore, visibilità, nota.
    ///
    /// Scrivibile, e non è un dettaglio di comodità. Prima era in sola lettura, e ogni punto che
    /// doveva nascondere o ricolorare un'annotazione era costretto a smontare il caso, ricostruire
    /// il valore e rimetterlo nell'array — nove rami ripetuti a ogni chiamante, con il rischio che
    /// uno di essi dimenticasse un caso e la modifica sparisse in silenzio per un tipo solo. Il
    /// `set` sta qui una volta e i nove rami sono scritti una volta.
    public var metadata: AnnotationMetadata {
        get {
            switch self {
            case .distance(let a): return a.metadata
            case .angle(let a): return a.metadata
            case .ellipseROI(let a): return a.metadata
            case .polygonROI(let a): return a.metadata
            case .sphereROI(let a): return a.metadata
            case .profileLine(let a): return a.metadata
            case .text(let a): return a.metadata
            case .arrow(let a): return a.metadata
            case .freehand(let a): return a.metadata
            }
        }
        set {
            switch self {
            case .distance(var a): a.metadata = newValue; self = .distance(a)
            case .angle(var a): a.metadata = newValue; self = .angle(a)
            case .ellipseROI(var a): a.metadata = newValue; self = .ellipseROI(a)
            case .polygonROI(var a): a.metadata = newValue; self = .polygonROI(a)
            case .sphereROI(var a): a.metadata = newValue; self = .sphereROI(a)
            case .profileLine(var a): a.metadata = newValue; self = .profileLine(a)
            case .text(var a): a.metadata = newValue; self = .text(a)
            case .arrow(var a): a.metadata = newValue; self = .arrow(a)
            case .freehand(var a): a.metadata = newValue; self = .freehand(a)
            }
        }
    }

    public var id: UUID { metadata.id }

    public var handlesMM: [Vec3] {
        switch self {
        case .distance(let a): return a.handlesMM
        case .angle(let a): return a.handlesMM
        case .ellipseROI(let a): return a.handlesMM
        case .polygonROI(let a): return a.handlesMM
        case .sphereROI(let a): return a.handlesMM
        case .profileLine(let a): return a.handlesMM
        case .text(let a): return a.handlesMM
        case .arrow(let a): return a.handlesMM
        case .freehand(let a): return a.handlesMM
        }
    }

    public var formattedValue: String {
        switch self {
        case .distance(let a): return a.formattedValue
        case .angle(let a): return a.formattedValue
        case .ellipseROI(let a): return a.formattedValue
        case .polygonROI(let a): return a.formattedValue
        case .sphereROI(let a): return a.formattedValue
        case .profileLine(let a): return a.formattedValue
        case .text(let a): return a.formattedValue
        case .arrow(let a): return a.formattedValue
        case .freehand(let a): return a.formattedValue
        }
    }

    /// Nome del tipo per la UI.
    public var kindName: String {
        switch self {
        case .distance: return "Distanza"
        case .angle: return "Angolo"
        case .ellipseROI: return "ROI ellittica"
        case .polygonROI: return "ROI poligonale"
        case .sphereROI: return "ROI sferica"
        case .profileLine: return "Profilo"
        case .text: return "Testo"
        case .arrow: return "Freccia"
        case .freehand: return "Mano libera"
        }
    }

    /// Nome del simbolo SF da mostrare nell'elenco misure.
    public var systemImageName: String {
        switch self {
        case .distance: return "ruler"
        case .angle: return "angle"
        case .ellipseROI: return "oval"
        case .polygonROI: return "pentagon"
        case .sphereROI: return "circle.circle"
        case .profileLine: return "chart.xyaxis.line"
        case .text: return "textformat"
        case .arrow: return "arrow.up.left"
        case .freehand: return "scribble"
        }
    }
}

// MARK: - Base ortonormale

/// Base ortonormale di un piano data la sua normale.
/// Serve a proiettare punti 3D in coordinate 2D di piano per i test di appartenenza.
public struct OrthonormalBasis: Sendable {
    public let u: Vec3
    public let v: Vec3
    public let normal: Vec3

    public init?(normal: Vec3) {
        guard let n = normal.normalized else { return nil }
        // Si sceglie come vettore ausiliario quello meno allineato alla normale, altrimenti
        // il prodotto vettoriale degenera quando la normale è quasi parallela all'asse scelto.
        let helper: Vec3 =
            abs(n.x) < 0.9 ? Vec3(1, 0, 0) : Vec3(0, 1, 0)
        guard let uAxis = helper.cross(n).normalized else { return nil }
        self.normal = n
        self.u = uAxis
        self.v = n.cross(uAxis)
    }

    /// Componenti di `p` nel piano.
    public func project(_ p: Vec3) -> (Double, Double) {
        (p.dot(u), p.dot(v))
    }

    /// Ricostruisce un punto 3D da coordinate di piano.
    public func unproject(_ a: Double, _ b: Double) -> Vec3 {
        u * a + v * b
    }
}

// MARK: - Formattazione

/// Formattazione dei valori per la UI.
///
/// Centralizzata perché il numero di decimali non è un dettaglio estetico: dichiarare
/// più precisione di quella che il voxel consente è fuorviante. Su una CBCT a 0,2 mm
/// due decimali sono già generosi.
public enum MeasurementFormatter {

    public static func length(_ mm: Double) -> String {
        String(format: "%.2f mm", mm)
    }

    public static func angle(_ degrees: Double) -> String {
        String(format: "%.1f°", degrees)
    }

    public static func area(_ mm2: Double) -> String {
        String(format: "%.1f mm²", mm2)
    }

    public static func volume(_ mm3: Double) -> String {
        if mm3 >= 1000 {
            return String(format: "%.2f cm³", mm3 / 1000.0)
        }
        return String(format: "%.1f mm³", mm3)
    }

    /// Densità, sempre accompagnata dall'unità corretta.
    /// Vedi il Contratto 4: su CBCT si scrive GV, non HU.
    public static func density(_ value: Double, unit: DensityUnit) -> String {
        String(format: "%.0f %@", value, unit.symbol)
    }

    public static func densityWithDeviation(
        mean: Double, standardDeviation: Double, unit: DensityUnit
    ) -> String {
        String(format: "%.0f ± %.0f %@", mean, standardDeviation, unit.symbol)
    }
}
