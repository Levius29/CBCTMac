import Foundation

// Collocazione delle etichette.
//
// # Non è grafica
//
// L'etichetta di un impianto — `Ø 3,85 · L 8,00` — deve stare accanto al suo oggetto senza coprire
// l'anatomia e senza sovrapporsi alle altre, collegata alla propria ancora da una linea di
// richiamo. Detto così sembra un problema di disegno; è invece un problema di **collocazione**, e
// si risolve e si verifica per intero senza disegnare nulla. Da qui la scelta di tenerlo in un
// modulo puro invece che dentro la vista: qui si prova, là si potrebbe solo guardare.
//
// # La proprietà che conta più di tutte è la stabilità
//
// Le ancore si muovono in continuazione: si scorre una fetta, si ruota il 3D, si trascina un
// impianto. Un algoritmo che ricolloca tutto da capo a ogni fotogramma produce etichette che
// **saltano**, ed è un difetto peggiore della sovrapposizione: l'occhio insegue il movimento e
// smette di leggere. Una sovrapposizione è brutta ma statica, e la si può leggere lo stesso.
//
// Qui la stabilità è per costruzione, e sono tre decisioni:
//
// 1. **L'ordine di collocazione non dipende dall'ordine di arrivo.** Si ordina per priorità e, a
//    parità, per identificatore. Se dipendesse dall'ordine dell'array, riordinare la sorgente —
//    cosa che succede ogni volta che si aggiunge o cancella un oggetto — rimescolerebbe tutto.
// 2. **Le posizioni candidate si provano sempre nella stessa sequenza**, dalla più vicina
//    all'ancora alla più lontana, girando attorno in un ordine fisso.
// 3. **Nessuna correzione a posteriori.** Nessuna forza di repulsione, nessun rilassamento
//    iterativo: sono le tecniche che danno i risultati più belli su un fotogramma fermo e le
//    etichette più irrequiete su una sequenza.
//
// La conseguenza è che uno spostamento piccolo dell'ancora produce uno spostamento piccolo
// dell'etichetta, tranne quando il candidato scelto smette di essere ammissibile — e lì il salto
// è inevitabile con qualunque metodo senza memoria.
//
// # «Non collocata» è un risultato, non un errore
//
// Con venti etichette in un riquadro piccolo non c'è posto per tutte. Sovrapporle è l'esito
// peggiore possibile: illeggibili tutte invece che alcune. Chi disegna omette quelle con
// `isPlaced == false`.

/// Un'etichetta da collocare.
public struct LabelRequest: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Punto a cui l'etichetta si riferisce, in pixel del riquadro.
    public var anchorX: Double
    public var anchorY: Double
    public var width: Double
    public var height: Double
    /// A parità di spazio vince la più alta. L'oggetto selezionato ha priorità massima.
    public var priority: Int

    public init(
        id: UUID,
        anchorX: Double,
        anchorY: Double,
        width: Double,
        height: Double,
        priority: Int = 0
    ) {
        self.id = id
        self.anchorX = anchorX
        self.anchorY = anchorY
        self.width = width
        self.height = height
        self.priority = priority
    }
}

/// Dove è finita un'etichetta.
public struct PlacedLabel: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Angolo alto-sinistro dell'etichetta collocata.
    public let x: Double
    public let y: Double
    /// Punto da cui parte la linea di richiamo, sul bordo dell'etichetta.
    public let leaderX: Double
    public let leaderY: Double
    /// Falso quando non c'è stato posto: chi disegna la omette invece di sovrapporla.
    public let isPlaced: Bool
}

public enum LabelLayout {

    /// Distanza minima fra l'ancora e il bordo dell'etichetta, in pixel.
    ///
    /// Serve a lasciar vedere il punto indicato: un'etichetta appoggiata all'ancora copre proprio
    /// la cosa che sta etichettando.
    public static let minimumGap = 10.0

    /// Di quanto si allontana a ogni giro, quando il giro precedente non ha posto.
    public static let ringStep = 14.0

    /// Quanti giri si provano prima di rinunciare.
    ///
    /// Cinque: oltre, l'etichetta è talmente lontana dalla propria ancora che la linea di richiamo
    /// attraversa mezzo riquadro, e a quel punto non aiuta più a capire a che cosa si riferisce.
    /// Meglio dichiararla non collocata e lasciare l'immagine pulita.
    public static let ringCount = 5

    /// Spazio minimo fra due etichette, in pixel. Due rettangoli che si toccano si leggono come
    /// un rettangolo solo.
    public static let labelGap = 3.0

    /// Otto direzioni, in ordine di preferenza.
    ///
    /// Destra per prima: il testo si legge da sinistra a destra, quindi un'etichetta alla destra
    /// dell'ancora si trova con lo sguardo già in movimento nel verso giusto. Poi sinistra, poi
    /// sopra e sotto, e infine le diagonali. L'ordine è fisso e non dipende da nulla: è la seconda
    /// delle tre decisioni che rendono stabile la collocazione.
    private static let directions: [(dx: Double, dy: Double)] = [
        (1, 0), (-1, 0), (0, -1), (0, 1),
        (1, -1), (-1, -1), (1, 1), (-1, 1),
    ]

    /// Colloca le etichette dentro un riquadro.
    ///
    /// - Returns: le etichette **in ordine di collocazione** — priorità decrescente, poi
    ///   identificatore — e non nell'ordine in cui sono arrivate. È voluto: così lo stesso insieme
    ///   di richieste produce esattamente lo stesso array comunque sia ordinato l'ingresso, e chi
    ///   chiama cerca per `id` invece di accoppiare per posizione.
    public static func place(
        _ requests: [LabelRequest],
        inWidth width: Double,
        height: Double,
        marginPoints: Double = 4
    ) -> [PlacedLabel] {
        guard width > 0, height > 0 else {
            return requests
                .sorted(by: precedes)
                .map { unplaced($0) }
        }

        let margin = max(marginPoints, 0)
        let frame = Rect(
            x: margin, y: margin,
            width: max(width - margin * 2, 0),
            height: max(height - margin * 2, 0))

        var taken: [Rect] = []
        var result: [PlacedLabel] = []
        result.reserveCapacity(requests.count)

        for request in requests.sorted(by: precedes) {
            guard request.width > 0, request.height > 0,
                request.anchorX.isFinite, request.anchorY.isFinite,
                request.width <= frame.width, request.height <= frame.height
            else {
                result.append(unplaced(request))
                continue
            }

            var placed: Rect?
            search: for ring in 0..<ringCount {
                let distance = minimumGap + Double(ring) * ringStep
                for direction in directions {
                    let rect = candidate(for: request, direction: direction, distance: distance)
                    guard frame.contains(rect) else { continue }
                    guard !taken.contains(where: { $0.intersects(rect, padding: labelGap) })
                    else { continue }
                    placed = rect
                    break search
                }
            }

            guard let rect = placed else {
                result.append(unplaced(request))
                continue
            }
            taken.append(rect)

            let leader = leaderPoint(
                on: rect, towardsX: request.anchorX, y: request.anchorY)
            result.append(
                PlacedLabel(
                    id: request.id,
                    x: rect.x, y: rect.y,
                    leaderX: leader.x, leaderY: leader.y,
                    isPlaced: true))
        }

        return result
    }

    // MARK: Dettagli

    /// Ordine di collocazione: priorità decrescente, poi identificatore.
    ///
    /// L'identificatore come secondo criterio non è un dettaglio: senza, due etichette di pari
    /// priorità si scambierebbero di posto ogni volta che l'array cambia ordine, e cambiare ordine
    /// è ciò che succede a ogni aggiunta o cancellazione.
    private static func precedes(_ a: LabelRequest, _ b: LabelRequest) -> Bool {
        if a.priority != b.priority { return a.priority > b.priority }
        return a.id.uuidString < b.id.uuidString
    }

    /// Rettangolo candidato: il bordo dell'etichetta a `distance` dall'ancora, lungo `direction`.
    ///
    /// Sulle direzioni pure l'etichetta resta centrata sull'altro asse — a destra dell'ancora sta
    /// alla sua stessa altezza — che è la collocazione che si legge come «appartiene a quello».
    private static func candidate(
        for request: LabelRequest, direction: (dx: Double, dy: Double), distance: Double
    ) -> Rect {
        let centreX = request.anchorX + direction.dx * (distance + request.width * 0.5)
        let centreY = request.anchorY + direction.dy * (distance + request.height * 0.5)
        return Rect(
            x: centreX - request.width * 0.5,
            y: centreY - request.height * 0.5,
            width: request.width,
            height: request.height)
    }

    /// Punto del bordo dell'etichetta più vicino all'ancora.
    ///
    /// Si ottiene proiettando l'ancora sul rettangolo. Poiché l'ancora è sempre fuori — la
    /// distanza minima è positiva per costruzione — la proiezione cade sul bordo, cioè
    /// esattamente sul lato rivolto verso l'ancora. Non c'è nessun caso da distinguere a mano, ed
    /// è il motivo per cui è scritta così invece che con otto rami.
    private static func leaderPoint(on rect: Rect, towardsX x: Double, y: Double)
        -> (x: Double, y: Double)
    {
        let clampedX = min(max(x, rect.x), rect.x + rect.width)
        let clampedY = min(max(y, rect.y), rect.y + rect.height)

        // Ancora dentro il rettangolo: non capita finché `minimumGap` è positivo, ma se qualcuno
        // lo azzerasse la proiezione cadrebbe all'interno e la linea di richiamo partirebbe da
        // dentro l'etichetta. Si spinge sul lato più vicino.
        let insideX = clampedX == x
        let insideY = clampedY == y
        guard insideX, insideY else { return (clampedX, clampedY) }

        let toLeft = x - rect.x
        let toRight = rect.x + rect.width - x
        let toTop = y - rect.y
        let toBottom = rect.y + rect.height - y
        let nearest = min(min(toLeft, toRight), min(toTop, toBottom))
        if nearest == toLeft { return (rect.x, y) }
        if nearest == toRight { return (rect.x + rect.width, y) }
        if nearest == toTop { return (x, rect.y) }
        return (x, rect.y + rect.height)
    }

    private static func unplaced(_ request: LabelRequest) -> PlacedLabel {
        PlacedLabel(
            id: request.id,
            x: request.anchorX, y: request.anchorY,
            leaderX: request.anchorX, leaderY: request.anchorY,
            isPlaced: false)
    }

    /// Rettangolo interno, per non dipendere da CoreGraphics: questo modulo compila anche dove
    /// non c'è, ed è la condizione che permette di provarlo qui invece che sul Mac.
    struct Rect: Hashable {
        var x: Double
        var y: Double
        var width: Double
        var height: Double

        func contains(_ other: Rect) -> Bool {
            other.x >= x - 1e-9
                && other.y >= y - 1e-9
                && other.x + other.width <= x + width + 1e-9
                && other.y + other.height <= y + height + 1e-9
        }

        func intersects(_ other: Rect, padding: Double) -> Bool {
            x - padding < other.x + other.width
                && other.x < x + width + padding
                && y - padding < other.y + other.height
                && other.y < y + height + padding
        }
    }
}
