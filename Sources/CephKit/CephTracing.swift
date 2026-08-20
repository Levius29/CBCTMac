import DICOMCore
import Foundation

/// Un repere segnato: quale punto, su quale lato, dove.
public struct CephPoint: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var landmark: CephLandmark
    public var side: CephSide
    /// Posizione in **millimetri Patient**, come ogni altra coordinata del programma.
    public var positionMM: Vec3

    public init(
        id: UUID = UUID(), landmark: CephLandmark, side: CephSide = .median, positionMM: Vec3
    ) {
        self.id = id
        self.landmark = landmark
        self.side = side
        self.positionMM = positionMM
    }

    public var displayName: String {
        guard landmark.isBilateral, side != .median else { return landmark.abbreviation }
        return landmark.abbreviation + (side == .right ? " dx" : " sx")
    }
}

/// Il punto di un repere sul piano sagittale mediano.
///
/// Due coordinate e non tre, e con nomi anatomici invece che `x` e `y`: un angolo cefalometrico
/// è definito su un piano, e chiamare le sue coordinate «anteriore» e «superiore» toglie di mezzo
/// la domanda su quale verso sia positivo — la domanda che, sbagliata, fa uscire 155° dove
/// dovrebbero uscirne 25°.
public struct CephPlanePoint: Hashable, Sendable {
    /// Positivo verso la faccia.
    public var anteriorMM: Double
    /// Positivo verso l'alto.
    public var superiorMM: Double

    public init(anteriorMM: Double, superiorMM: Double) {
        self.anteriorMM = anteriorMM
        self.superiorMM = superiorMM
    }

    /// Proiezione di un punto Patient sul piano sagittale mediano.
    ///
    /// In coordinate Patient `x` cresce verso sinistra del paziente, `y` all'indietro, `z` in
    /// alto. Proiettare sul sagittale è **buttare via la `x`**: è ciò che fa una teleradiografia
    /// laterale, ed è la ragione per cui i suoi angoli si possono confrontare con le norme.
    ///
    /// Quale piano sagittale non conta: sono tutti paralleli, e la proiezione ortogonale su piani
    /// paralleli dà le stesse distanze e gli stessi angoli. Per questo qui non c'è un parametro
    /// che chieda dove sia la linea mediana — un parametro che non cambia nulla è un parametro
    /// che prima o poi qualcuno imposta male.
    public init(projecting patientMM: Vec3) {
        self.anteriorMM = -patientMM.y
        self.superiorMM = patientMM.z
    }

    public static func - (a: CephPlanePoint, b: CephPlanePoint) -> CephPlanePoint {
        CephPlanePoint(
            anteriorMM: a.anteriorMM - b.anteriorMM, superiorMM: a.superiorMM - b.superiorMM)
    }

    public var length: Double {
        (anteriorMM * anteriorMM + superiorMM * superiorMM).squareRoot()
    }

    public func distance(to other: CephPlanePoint) -> Double { (self - other).length }

    public func dot(_ other: CephPlanePoint) -> Double {
        anteriorMM * other.anteriorMM + superiorMM * other.superiorMM
    }

    public var normalized: CephPlanePoint? {
        let l = length
        guard l > 1e-12 else { return nil }
        return CephPlanePoint(anteriorMM: anteriorMM / l, superiorMM: superiorMM / l)
    }
}

/// I reperi segnati su un esame.
public struct CephTracing: Hashable, Sendable, Codable {
    public var points: [CephPoint]

    public init(points: [CephPoint] = []) {
        self.points = points
    }

    public var isEmpty: Bool { points.isEmpty }

    /// I reperi segnati almeno una volta.
    public var placedLandmarks: Set<CephLandmark> { Set(points.map(\.landmark)) }

    /// La posizione da usare per un repere: la media di tutte le sue segnature.
    ///
    /// Media e non «la prima»: per porion, orbitale, gonion e articulare le segnature sono due, e
    /// il punto cefalometrico è quello di mezzo. Per gli altri la media di una segnatura sola è
    /// quella segnatura, quindi la regola è una sola e non ha casi.
    public func positionMM(of landmark: CephLandmark) -> Vec3? {
        let matching = points.filter { $0.landmark == landmark }
        guard !matching.isEmpty else { return nil }
        var sum = Vec3(0, 0, 0)
        for point in matching { sum += point.positionMM }
        return sum / Double(matching.count)
    }

    /// Il repere proiettato sul piano sagittale mediano.
    public func planePoint(of landmark: CephLandmark) -> CephPlanePoint? {
        positionMM(of: landmark).map(CephPlanePoint.init(projecting:))
    }

    /// Quanto distano fra loro le due segnature di un repere bilaterale, se ci sono entrambe.
    ///
    /// Non serve al calcolo — la media lo assorbe — ma serve a chi guarda: due gonion a
    /// quaranta millimetri di distanza sono normali, a novanta uno dei due è segnato male, e la
    /// media di un punto sbagliato non avverte di nulla.
    public func spreadMM(of landmark: CephLandmark) -> Double? {
        let matching = points.filter { $0.landmark == landmark }
        guard matching.count == 2 else { return nil }
        return matching[0].positionMM.distance(to: matching[1].positionMM)
    }

    /// I lati già segnati per un repere.
    public func sides(of landmark: CephLandmark) -> Set<CephSide> {
        Set(points.filter { $0.landmark == landmark }.map(\.side))
    }

    /// Vero quando il repere è completo: entrambi i lati se bilaterale, uno se mediano.
    public func isComplete(_ landmark: CephLandmark) -> Bool {
        let sides = sides(of: landmark)
        guard landmark.isBilateral else { return !sides.isEmpty }
        return sides.contains(.right) && sides.contains(.left)
    }

    /// Segna un repere, sostituendo quello che c'era per lo stesso lato.
    ///
    /// Sostituire e non aggiungere: chi riclicca sta correggendo la posizione, e tenerle tutte e
    /// due farebbe una media fra il punto sbagliato e quello giusto — cioè un terzo punto, che
    /// non è nessuno dei due.
    public mutating func place(_ landmark: CephLandmark, side: CephSide = .median, at point: Vec3) {
        let effective: CephSide = landmark.isBilateral ? side : .median
        points.removeAll { $0.landmark == landmark && $0.side == effective }
        points.append(CephPoint(landmark: landmark, side: effective, positionMM: point))
    }

    /// Toglie tutte le segnature di un repere.
    public mutating func remove(_ landmark: CephLandmark) {
        points.removeAll { $0.landmark == landmark }
    }

    /// Toglie una singola segnatura.
    public mutating func remove(id: UUID) {
        points.removeAll { $0.id == id }
    }

    // Non c'è un «repere più vicino a un punto nello spazio», e non è una dimenticanza: la
    // ricerca che serve è in pixel, sul riquadro, perché quel che si colpisce dev'essere quel
    // che si vede — un repere a quindici millimetri dal piano è disegnato, e un test in
    // millimetri non lo troverebbe. Vive in `CephOverlay.nearest`, dove c'è il piano.
}
