import DICOMCore
import Foundation

// Modifica della curva d'arcata, e identità delle due arcate.
//
// Sta in DentalKit e non nell'applicazione perché è geometria: dove finisce un punto quando lo si
// clicca è una decisione che si verifica con un test, non guardando lo schermo. L'interfaccia si
// limita a tradurre i clic in millimetri e a chiamare questi metodi.
//
// # Perché due curve e non una
//
// L'arcata superiore non ha la forma di quella inferiore, e non sta alla stessa quota. Con una
// curva sola la panoramica viene corretta su un'arcata e sfocata sull'altra: i denti che stanno
// fuori dalla curva finiscono oltre lo spessore campionato e semplicemente non compaiono. Le due
// curve sono indipendenti — punti, forma e quota — e si sceglie quale è attiva.

/// Quale arcata descrive una curva.
public enum DentalArch: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    case maxillary
    case mandibular

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .maxillary: return "Arcata superiore"
        case .mandibular: return "Arcata inferiore"
        }
    }

    public var shortName: String {
        switch self {
        case .maxillary: return "Sup."
        case .mandibular: return "Inf."
        }
    }

    public var systemImageName: String {
        switch self {
        case .maxillary: return "arrow.up.circle"
        case .mandibular: return "arrow.down.circle"
        }
    }
}

// MARK: - Modifica dei punti di controllo

extension ArchCurve {

    /// Esito dell'aggiunta di un punto: dove è finito nell'ordine di percorrenza.
    public enum InsertionOutcome: Hashable, Sendable {
        /// Inserito **fra** due punti esistenti, all'indice indicato.
        case inserted(index: Int)
        /// Aggiunto in coda, prolungando la curva verso i molari di un lato.
        case appended(index: Int)
    }

    /// Aggiunge un punto scegliendo da sé la posizione nell'ordine di percorrenza.
    ///
    /// È il metodo che rende l'editor usabile, e la ragione è tutta nell'ordine. I punti di una
    /// Catmull-Rom vengono percorsi nell'ordine dell'array: aggiungere sempre in coda significa
    /// che un punto cliccato fra il canino e il primo molare crea un cappio — la curva arriva ai
    /// molari, torna indietro al punto nuovo, e riparte. Chi lo prova conclude, correttamente,
    /// che la curva «va per conto suo».
    ///
    /// La regola è quella che il gesto suggerisce:
    ///
    /// - se la proiezione del punto cade **dentro** un segmento fra due punti di controllo, il
    ///   punto va inserito lì, e la curva si infittisce dove serve;
    /// - se cade oltre un estremo, il punto **prolunga** la curva da quel lato.
    ///
    /// Con meno di due punti non c'è ancora un segmento e si accoda.
    @discardableResult
    public mutating func addControlPoint(_ pointMM: Vec3) -> InsertionOutcome {
        guard pointMM.isFinite else { return .appended(index: max(controlPointsMM.count - 1, 0)) }

        guard controlPointsMM.count >= 2 else {
            controlPointsMM.append(pointMM)
            return .appended(index: controlPointsMM.count - 1)
        }

        guard let closest = closestPointOnControlPolyline(to: pointMM) else {
            controlPointsMM.append(pointMM)
            return .appended(index: controlPointsMM.count - 1)
        }

        let lastSegment = controlPointsMM.count - 2

        // Proiezione interna a un segmento: il punto va lì, e la curva si infittisce dove serve.
        if closest.t > 0, closest.t < 1 {
            let index = closest.segment + 1
            controlPointsMM.insert(pointMM, at: index)
            return .inserted(index: index)
        }

        // Proiezione bloccata su un vertice. Se è un estremo della curva, il gesto è un
        // prolungamento; se è un vertice interno — succede all'esterno di una convessità — il
        // punto va accanto a quel vertice, che è la posizione che conserva l'ordine.
        if closest.t <= 0 {
            if closest.segment == 0 {
                controlPointsMM.insert(pointMM, at: 0)
                return .appended(index: 0)
            }
            controlPointsMM.insert(pointMM, at: closest.segment)
            return .inserted(index: closest.segment)
        }

        if closest.segment == lastSegment {
            controlPointsMM.append(pointMM)
            return .appended(index: controlPointsMM.count - 1)
        }
        let index = closest.segment + 1
        controlPointsMM.insert(pointMM, at: index)
        return .inserted(index: index)
    }

    /// Punto più vicino sulla **poligonale** dei punti di controllo.
    ///
    /// Restituisce il segmento, il parametro `t` limitato a `[0, 1]` e la distanza. È la primitiva
    /// su cui si decide dove finisce un punto cliccato, e la limitazione di `t` è la parte
    /// essenziale: un `t` di 0 o 1 dice che il punto più vicino è un vertice, non un tratto, cioè
    /// che il clic sta *oltre* quel vertice.
    ///
    /// Cercare invece «un segmento la cui proiezione sia interna» è la via ovvia e sbagliata, e
    /// vale la pena averlo scritto perché il difetto è istruttivo. Su un'arcata a U, un clic
    /// dietro l'ultimo molare ha una proiezione interna al segmento del **lato opposto**, a
    /// cinquanta millimetri di distanza: geometricamente legittima, e se è l'unica interna vince.
    /// Il punto veniva inserito a metà dell'arcata invece di prolungarla. Il confronto va fatto
    /// sulla distanza globale, non sull'interiorità.
    ///
    /// La poligonale e non la spline: i punti si spostano trascinando i vertici, quindi è la
    /// poligonale a definire l'ordine di percorrenza, e valutare la spline costerebbe di più
    /// dicendo la stessa cosa.
    public func closestPointOnControlPolyline(
        to pointMM: Vec3
    ) -> (segment: Int, t: Double, distanceMM: Double)? {
        guard controlPointsMM.count >= 2, pointMM.isFinite else { return nil }

        var best: (segment: Int, t: Double, distanceMM: Double)?

        for index in 0..<(controlPointsMM.count - 1) {
            let a = controlPointsMM[index]
            let b = controlPointsMM[index + 1]
            let ab = b - a
            let lengthSquared = ab.lengthSquared

            // Segmento degenere: i due vertici coincidono, e il punto più vicino è il vertice.
            let t = lengthSquared > 1e-12
                ? min(max((pointMM - a).dot(ab) / lengthSquared, 0), 1)
                : 0
            let distance = pointMM.distance(to: a + ab * t)

            if best == nil || distance < best!.distanceMM {
                best = (segment: index, t: t, distanceMM: distance)
            }
        }

        return best
    }

    /// Sposta un punto di controllo. Un indice fuori intervallo non fa nulla.
    public mutating func moveControlPoint(at index: Int, to pointMM: Vec3) {
        guard controlPointsMM.indices.contains(index), pointMM.isFinite else { return }
        controlPointsMM[index] = pointMM
    }

    /// Porta tutti i punti alla stessa quota lungo l'asse verticale.
    ///
    /// I punti si posano cliccando sulla vista assiale, quindi nascono già complanari. Ma
    /// scorrendo di una fetta fra due clic si ottiene una curva leggermente elicoidale, e su un
    /// panorex quella pendenza si legge come un'immagine che scivola in alto da un lato. Il
    /// comando è a disposizione dell'utente e non automatico: appiattire d'ufficio impedirebbe
    /// una curva volutamente inclinata, che su un'occlusione asimmetrica ha senso.
    public mutating func flatten(toVerticalMM value: Double) {
        guard value.isFinite else { return }
        let up = upAxis
        controlPointsMM = controlPointsMM.map { point in
            point - up * point.dot(up) + up * value
        }
    }

    /// Quota media dei punti lungo l'asse verticale; `nil` se la curva è vuota.
    ///
    /// È la quota su cui centrare panorex e sezioni quando si passa da un'arcata all'altra: la
    /// curva stessa dice dove guardare, senza che l'utente debba anche spostare il mirino.
    public var averageVerticalMM: Double? {
        guard !controlPointsMM.isEmpty else { return nil }
        let up = upAxis
        let total = controlPointsMM.reduce(0.0) { $0 + $1.dot(up) }
        return total / Double(controlPointsMM.count)
    }

    // MARK: Curva suggerita

    /// Parabola d'arcata suggerita, **alla quota indicata**.
    ///
    /// Differisce da `defaultArch(for:)` in un punto che conta: la quota non è il centro del
    /// volume ma quella che si passa, cioè la fetta che l'utente sta guardando. Una curva
    /// suggerita al centro del volume finisce a metà fra le due arcate, dove non c'è né l'una né
    /// l'altra, e da lì l'impressione che il programma faccia di testa propria.
    ///
    /// Resta una proposta da correggere, e va offerta come comando esplicito: la curva la decide
    /// chi guarda l'anatomia.
    public static func suggested(
        for geometry: VolumeGeometry,
        atVerticalMM verticalMM: Double,
        arch: DentalArch,
        pointCount: Int = 7
    ) -> ArchCurve {
        let centre = geometry.centerMM
        let size = geometry.physicalSizeMM

        // Semilarghezza e profondità di un'arcata adulta, limitate a valori plausibili anche su
        // un FOV piccolo. La superiore è leggermente più ampia dell'inferiore.
        let widthFactor = arch == .maxillary ? 0.34 : 0.32
        let halfWidth = min(max(size.x * widthFactor, 18.0), 33.0)
        let depth = min(max(size.y * 0.30, 16.0), 30.0)

        let count = max(3, pointCount)
        var points: [Vec3] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let t = Double(index) / Double(count - 1) * 2.0 - 1.0  // da −1 a +1
            let x = centre.x + t * halfWidth
            let y = centre.y - depth * (1.0 - t * t) + depth * 0.5
            points.append(Vec3(x, y, verticalMM))
        }

        return ArchCurve(controlPointsMM: points)
    }
}
