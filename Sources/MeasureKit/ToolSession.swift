import DICOMCore

// Lo strumento in corso, cioè i punti già posati e quanti ne mancano.
//
// # Perché non sta nella vista
//
// Ci stava, come stato locale di un riquadro. La conseguenza era che ogni riquadro aveva la
// *sua* misura a metà: il righello funzionava sull'assiale, sul coronale e sul sagittale — dove
// quello stato esisteva — e sulla panorex e sulle sezioni trasversali no, perché lì nessuno
// l'aveva scritto. Non era una scelta, era un'assenza, e all'uso si presentava come «gli
// strumenti funzionano solo in alcuni riquadri».
//
// Uno strumento è dell'applicazione, non del riquadro. I punti sono in millimetri Patient e
// non appartengono a nessuna vista in particolare: una misura cominciata su una sezione e
// chiusa su un'altra è una distanza tridimensionale vera, non un errore da impedire.

/// Quanti punti chiede una forma, e come si chiude.
public enum ToolShape: Hashable, Sendable {

    /// Nota di testo, impianto, nodo del nervo: si posa e si è finito.
    case singlePoint
    /// Distanza, ROI ellittica, ROI sferica.
    case twoPoints
    /// Angolo a tre punti, vertice per primo.
    case threePoints
    /// Angolo fra rette: due punti per retta.
    case fourPoints
    /// Spezzata o perimetro: si accumula finché non si chiude a comando.
    case openPolyline

    /// Numero di punti dopo il quale la forma si chiude da sé, o `nil` se non è noto.
    public var requiredPoints: Int? {
        switch self {
        case .singlePoint: return 1
        case .twoPoints: return 2
        case .threePoints: return 3
        case .fourPoints: return 4
        case .openPolyline: return nil
        }
    }
}

/// Il piano su cui è cominciata la misura.
///
/// Si registra al **primo** punto e non cambia più: è lì che la misura è ancorata, ed è quel
/// piano che decide su quali fette resterà visibile e come è orientata un'ellisse. Prendere
/// l'ultimo piano invece del primo farebbe cambiare orientamento a un'ellisse a seconda di dove
/// si chiude, che è il genere di comportamento che nessuno riesce a spiegarsi.
public struct ToolAnchor: Hashable, Sendable {

    public var originMM: Vec3
    public var normalMM: Vec3
    /// Versore orizzontale del piano, verso destra dello schermo.
    public var rightMM: Vec3
    /// Versore verticale del piano, verso il basso dello schermo.
    public var downMM: Vec3
    public var visibilityToleranceMM: Double

    public init(
        originMM: Vec3, normalMM: Vec3, rightMM: Vec3, downMM: Vec3,
        visibilityToleranceMM: Double
    ) {
        self.originMM = originMM
        self.normalMM = normalMM
        self.rightMM = rightMM
        self.downMM = downMM
        self.visibilityToleranceMM = visibilityToleranceMM
    }

    public var planeReference: AnnotationPlaneReference {
        AnnotationPlaneReference(
            originMM: originMM,
            normalMM: normalMM,
            visibilityToleranceMM: visibilityToleranceMM)
    }
}

/// I punti posati finora dallo strumento attivo.
public struct ToolSession: Sendable, Equatable {

    public private(set) var shape: ToolShape
    public private(set) var pointsMM: [Vec3]
    public private(set) var anchor: ToolAnchor?

    public init(shape: ToolShape = .singlePoint) {
        self.shape = shape
        self.pointsMM = []
        self.anchor = nil
    }

    public var isEmpty: Bool { pointsMM.isEmpty }

    /// Prepara la sessione per una forma.
    ///
    /// Chiamarla con la forma già in corso **non fa nulla**: la vista la chiama a ogni clic, e se
    /// azzerasse ogni volta nessuna misura arriverebbe al secondo punto. Cambiare forma invece
    /// azzera, perché due punti di una distanza non sono i primi due di un angolo.
    public mutating func prepare(for shape: ToolShape) {
        guard shape != self.shape else { return }
        self.shape = shape
        pointsMM = []
        anchor = nil
    }

    /// Posa un punto.
    ///
    /// - Returns: i punti completi se la forma si chiude qui, altrimenti `nil`. Quando restituisce
    ///   i punti la sessione è già vuota: chi chiama costruisce l'annotazione e non deve ricordarsi
    ///   di ripulire.
    @discardableResult
    public mutating func add(_ pointMM: Vec3, anchor: ToolAnchor? = nil) -> [Vec3]? {
        if pointsMM.isEmpty { self.anchor = anchor }
        pointsMM.append(pointMM)

        guard let required = shape.requiredPoints, pointsMM.count >= required else { return nil }
        let completed = pointsMM
        pointsMM = []
        return completed
    }

    /// Chiude a comando una forma che non si chiude da sé — il doppio clic di una spezzata.
    ///
    /// - Returns: i punti se ce n'erano abbastanza, altrimenti `nil`. In entrambi i casi la
    ///   sessione resta vuota: chiudere con un punto solo è un ripensamento, non un errore da
    ///   segnalare.
    @discardableResult
    public mutating func close(minimumPoints: Int = 2) -> [Vec3]? {
        defer { pointsMM = [] }
        guard pointsMM.count >= max(minimumPoints, 1) else { return nil }
        return pointsMM
    }

    /// Toglie l'ultimo punto posato. È l'annullamento a portata di Esc mentre si sta disegnando.
    @discardableResult
    public mutating func removeLastPoint() -> Vec3? {
        guard !pointsMM.isEmpty else { return nil }
        let removed = pointsMM.removeLast()
        if pointsMM.isEmpty { anchor = nil }
        return removed
    }

    public mutating func cancel() {
        pointsMM = []
        anchor = nil
    }

    /// Quanti punti mancano, o `nil` se la forma non ne chiede un numero fisso.
    public var missingPoints: Int? {
        guard let required = shape.requiredPoints else { return nil }
        return max(required - pointsMM.count, 0)
    }

    /// Che cosa dire a chi sta guardando.
    ///
    /// Uno strumento che chiede tre clic e non lo dice sembra rotto a chi ne dà uno: è la stessa
    /// ragione per cui ogni strumento ha già un suggerimento nella palette, ma qui il conto è
    /// vivo e sa a che punto è.
    public var progressHint: String? {
        guard !pointsMM.isEmpty else { return nil }
        guard let missing = missingPoints else {
            let posati = pointsMM.count == 1 ? "1 punto posato" : "\(pointsMM.count) punti posati"
            return "\(posati) · doppio clic per chiudere, Esc per annullare"
        }
        guard missing > 0 else { return nil }
        return missing == 1 ? "manca 1 punto" : "mancano \(missing) punti"
    }
}
