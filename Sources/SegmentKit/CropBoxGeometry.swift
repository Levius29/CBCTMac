import DICOMCore

// Il riquadro di ritaglio proiettato su una vista, e le sue prese.
//
// # Perché sta qui e non nella sovraimpressione che lo disegna
//
// Perché è la stessa geometria che serve a **disegnarlo** e ad **afferrarlo**, e finché stava
// solo nella vista le due cose erano scritte una volta sola per un percorso di eventi che non
// arrivava mai. Il riquadro aveva un `DragGesture`, e sotto c'è una `MTKView`: AppKit consegna il
// mouse alla vista più profonda, la sovraimpressione SwiftUI è uno strato della stessa vista
// ospite e non un'altra `NSView`, e quel gesto non è mai partito. Il ritaglio si disegnava e non
// si poteva regolare.
//
// Stando qui la matematica si verifica con `swift test` invece che a occhio sul Mac, e chi
// disegna e chi riceve i clic chiamano le stesse funzioni — che è l'unico modo di garantire che
// ciò che si vede sia ciò che si afferra.

/// Il rettangolo di vista su cui il riquadro si proietta.
///
/// Non è una `MPRPlane` perché SegmentKit non dipende da VolumeKit, e non deve: qui servono un
/// angolo, due versori e due estensioni, che è tutto ciò che definisce un rettangolo nello spazio.
public struct CropBoxFrame: Hashable, Sendable {

    /// Angolo in alto a sinistra della vista, in millimetri Patient.
    public var topLeftMM: Vec3
    /// Versore verso destra dello schermo.
    public var rightMM: Vec3
    /// Versore verso il basso dello schermo.
    public var downMM: Vec3
    /// Estensione inquadrata in orizzontale, in millimetri.
    public var widthMM: Double
    /// Estensione inquadrata in verticale, in millimetri.
    public var heightMM: Double

    public init(
        topLeftMM: Vec3, rightMM: Vec3, downMM: Vec3, widthMM: Double, heightMM: Double
    ) {
        self.topLeftMM = topLeftMM
        self.rightMM = rightMM
        self.downMM = downMM
        self.widthMM = widthMM
        self.heightMM = heightMM
    }
}

/// Lato afferrabile del riquadro, nel verso dello schermo.
public enum CropBoxEdge: Hashable, Sendable, CaseIterable {
    case left, right, top, bottom
}

/// Rettangolo proiettato, in unità della vista.
public struct CropBoxRect: Hashable, Sendable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public var width: Double { maxX - minX }
    public var height: Double { maxY - minY }
    public var midX: Double { (minX + maxX) / 2 }
    public var midY: Double { (minY + maxY) / 2 }
}

public enum CropBoxGeometry {

    /// L'asse Patient che una direzione dello schermo percorre, col segno.
    ///
    /// Le viste ortogonali mostrano sempre due assi Patient allineati agli assi, quindi la
    /// direzione ha una sola componente non trascurabile. Sceglierla dal **modulo maggiore**
    /// invece che dal primo valore non nullo è ciò che rende la funzione insensibile agli
    /// arrotondamenti di una matrice DICOM che non è mai esattamente 0 e 1.
    static func axis(of direction: Vec3) -> (component: Int, sign: Double) {
        let values = [direction.x, direction.y, direction.z]
        var best = 0
        for index in 1..<3 where abs(values[index]) > abs(values[best]) { best = index }
        return (best, values[best] < 0 ? -1 : 1)
    }

    static func value(_ point: Vec3, component: Int) -> Double {
        switch component {
        case 0: return point.x
        case 1: return point.y
        default: return point.z
        }
    }

    /// La faccia del riquadro che un lato dello schermo comanda.
    ///
    /// Dipende dal **verso** dell'asse: sul sagittale destro l'asse orizzontale può crescere
    /// verso sinistra dello schermo, e allora il lato sinistro comanda la faccia di massimo. È il
    /// motivo per cui questa corrispondenza si calcola invece di scriverla a mano: scritta a mano
    /// darebbe un riquadro che si allarga dalla parte sbagliata su metà delle viste.
    public static func face(for edge: CropBoxEdge, in frame: CropBoxFrame) -> BoxFace {
        let horizontal = axis(of: frame.rightMM)
        let vertical = axis(of: frame.downMM)

        switch edge {
        case .left: return boxFace(component: horizontal.component, isMaximum: horizontal.sign < 0)
        case .right: return boxFace(component: horizontal.component, isMaximum: horizontal.sign > 0)
        case .top: return boxFace(component: vertical.component, isMaximum: vertical.sign < 0)
        case .bottom: return boxFace(component: vertical.component, isMaximum: vertical.sign > 0)
        }
    }

    private static func boxFace(component: Int, isMaximum: Bool) -> BoxFace {
        switch (component, isMaximum) {
        case (0, true): return .maxX
        case (0, false): return .minX
        case (1, true): return .maxY
        case (1, false): return .minY
        case (2, true): return .maxZ
        default: return .minZ
        }
    }

    /// Il riquadro proiettato sulla vista, in unità della vista.
    public static func rect(
        of box: BoxMM, in frame: CropBoxFrame, width: Double, height: Double
    ) -> CropBoxRect {
        let horizontal = axis(of: frame.rightMM)
        let vertical = axis(of: frame.downMM)

        let x0 = viewX(millimetres(box, horizontal, minimum: true), frame, horizontal, width)
        let x1 = viewX(millimetres(box, horizontal, minimum: false), frame, horizontal, width)
        let y0 = viewY(millimetres(box, vertical, minimum: true), frame, vertical, height)
        let y1 = viewY(millimetres(box, vertical, minimum: false), frame, vertical, height)

        return CropBoxRect(
            minX: min(x0, x1), minY: min(y0, y1), maxX: max(x0, x1), maxY: max(y0, y1))
    }

    /// Estremo del riquadro lungo un asse, nel verso dello schermo.
    private static func millimetres(
        _ box: BoxMM, _ axis: (component: Int, sign: Double), minimum: Bool
    ) -> Double {
        let low = value(box.minMM, component: axis.component)
        let high = value(box.maxMM, component: axis.component)
        if axis.sign > 0 { return minimum ? low : high }
        return minimum ? high : low
    }

    private static func viewX(
        _ valueMM: Double, _ frame: CropBoxFrame, _ axis: (component: Int, sign: Double),
        _ width: Double
    ) -> Double {
        let origin = value(frame.topLeftMM, component: axis.component)
        let span = axis.sign * frame.widthMM
        guard abs(span) > 1e-9 else { return 0 }
        return (valueMM - origin) / span * width
    }

    private static func viewY(
        _ valueMM: Double, _ frame: CropBoxFrame, _ axis: (component: Int, sign: Double),
        _ height: Double
    ) -> Double {
        let origin = value(frame.topLeftMM, component: axis.component)
        let span = axis.sign * frame.heightMM
        guard abs(span) > 1e-9 else { return 0 }
        return (valueMM - origin) / span * height
    }

    /// La quota in millimetri a cui portare la faccia comandata da un lato, dato dove si è
    /// trascinato.
    public static func millimetres(
        atX x: Double, y: Double, for edge: CropBoxEdge, in frame: CropBoxFrame,
        width: Double, height: Double
    ) -> Double {
        switch edge {
        case .left, .right:
            let axis = self.axis(of: frame.rightMM)
            let origin = value(frame.topLeftMM, component: axis.component)
            return origin + x / max(width, 1) * axis.sign * frame.widthMM
        case .top, .bottom:
            let axis = self.axis(of: frame.downMM)
            let origin = value(frame.topLeftMM, component: axis.component)
            return origin + y / max(height, 1) * axis.sign * frame.heightMM
        }
    }

    /// Lato più vicino al punto premuto, se entro la distanza di presa.
    ///
    /// Si sceglie il più vicino in assoluto e non il primo che rientra nella soglia: su un
    /// riquadro stretto due lati opposti stanno entrambi a portata, e prendere il primo
    /// dell'elenco significherebbe afferrare sempre lo stesso.
    public static func edge(
        nearX x: Double, y: Double, of rect: CropBoxRect, slop: Double
    ) -> CropBoxEdge? {
        let candidates: [(CropBoxEdge, Double)] = [
            (.left, abs(x - rect.minX)),
            (.right, abs(x - rect.maxX)),
            (.top, abs(y - rect.minY)),
            (.bottom, abs(y - rect.maxY)),
        ]
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= slop else { return nil }
        return best.0
    }

    /// I punti in cui disegnare le maniglie, al centro di ciascun lato.
    public static func handles(of rect: CropBoxRect) -> [(x: Double, y: Double)] {
        [
            (rect.midX, rect.minY),
            (rect.midX, rect.maxY),
            (rect.minX, rect.midY),
            (rect.maxX, rect.midY),
        ]
    }
}
