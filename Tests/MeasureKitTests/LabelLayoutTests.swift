import Foundation
import Testing

@testable import MeasureKit

// Test della collocazione delle etichette.
//
// Sei degli otto controlli qui sotto verificano proprietà — nessuna esce, nessuna si sovrappone,
// due esecuzioni danno lo stesso esito — e uno solo verifica un numero. È l'equilibrio giusto per
// un algoritmo di collocazione: i numeri esatti dipendono dalle costanti, che possono cambiare
// per ragioni estetiche, mentre le proprietà devono valere sempre.
//
// Il test 4 è quello che decide se il lotto è fatto bene. La stabilità è invisibile su un
// fotogramma fermo e si nota subito su una sequenza, quindi è precisamente il tipo di cosa che
// nessuno prova a mano.

@Suite("Collocazione delle etichette")
struct LabelLayoutTests {

    /// Generatore lineare congruente: il seme fisso rende i test ripetibili, e non dipendere da
    /// `SystemRandomNumberGenerator` significa che un fallimento si riproduce.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    private func request(
        _ index: Int, x: Double, y: Double, w: Double = 70, h: Double = 18, priority: Int = 0
    ) -> LabelRequest {
        // UUID deterministico dall'indice: due esecuzioni devono confrontarsi, e un UUID casuale
        // cambierebbe anche l'ordine di collocazione, che dall'identificatore dipende.
        let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        return LabelRequest(
            id: id, anchorX: x, anchorY: y, width: w, height: h, priority: priority)
    }

    private func rect(_ label: PlacedLabel, _ request: LabelRequest)
        -> (x: Double, y: Double, w: Double, h: Double)
    {
        (label.x, label.y, request.width, request.height)
    }

    private func overlap(
        _ a: (x: Double, y: Double, w: Double, h: Double),
        _ b: (x: Double, y: Double, w: Double, h: Double)
    ) -> Bool {
        a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
    }

    // MARK: 1 e 2 — le due proprietà di base

    @Test("Su cento ancore casuali nessuna etichetta esce dal riquadro né si sovrappone")
    func noEscapesAndNoOverlaps() {
        var generator = Seeded(state: 20_260_818)
        let width = 900.0, height = 700.0
        var requests: [LabelRequest] = []
        for index in 0..<100 {
            requests.append(
                request(
                    index,
                    x: Double.random(in: 20...(width - 20), using: &generator),
                    y: Double.random(in: 20...(height - 20), using: &generator)))
        }

        let placed = LabelLayout.place(requests, inWidth: width, height: height)
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })

        var rects: [(x: Double, y: Double, w: Double, h: Double)] = []
        for label in placed where label.isPlaced {
            let source = byID[label.id]!
            let r = rect(label, source)
            #expect(r.x >= 4 - 1e-9)
            #expect(r.y >= 4 - 1e-9)
            #expect(r.x + r.w <= width - 4 + 1e-9)
            #expect(r.y + r.h <= height - 4 + 1e-9)
            rects.append(r)
        }

        #expect(rects.count > 40, "con cento ancore su un riquadro grande la maggior parte deve entrarci")
        for i in 0..<max(rects.count - 1, 0) {
            for j in (i + 1)..<rects.count {
                #expect(!overlap(rects[i], rects[j]))
            }
        }
    }

    // MARK: 3 — la priorità

    @Test("A parità di condizioni la priorità più alta si prende la posizione preferita")
    func priorityWinsThePreferredSpot() throws {
        // Due ancore quasi coincidenti: c'è posto per una sola etichetta a destra, che è la
        // posizione preferita. Gli identificatori sono scelti perché **senza** la priorità
        // vincerebbe l'altra: `low` ha indice 1 e ordinerebbe per primo.
        let low = request(1, x: 400, y: 300, priority: 0)
        let high = request(2, x: 404, y: 300, priority: 10)

        let placed = LabelLayout.place([low, high], inWidth: 900, height: 700)
        #expect(placed.first?.id == high.id)

        let highLabel = try #require(placed.first { $0.id == high.id })
        let lowLabel = try #require(placed.first { $0.id == low.id })
        #expect(highLabel.isPlaced)
        #expect(lowLabel.isPlaced)

        // «Più vicina» sarebbe il criterio sbagliato, e l'ho scoperto scrivendolo: destra e
        // sinistra allo stesso giro **sono** equidistanti dall'ancora, quindi le due etichette
        // finiscono a 45 px entrambe e il confronto non discrimina nulla. Ciò che la priorità
        // garantisce davvero è la posizione **preferita**, cioè la prima dell'ordine di ricerca.
        #expect(abs(highLabel.x - (high.anchorX + LabelLayout.minimumGap)) < 1e-9)
        #expect(lowLabel.x < low.anchorX)

        func distance(_ label: PlacedLabel, _ source: LabelRequest) -> Double {
            let cx = label.x + source.width / 2 - source.anchorX
            let cy = label.y + source.height / 2 - source.anchorY
            return (cx * cx + cy * cy).squareRoot()
        }
        // E in nessun caso può finire più lontana di quella che le ha ceduto il posto.
        #expect(distance(highLabel, high) <= distance(lowLabel, low) + 1e-9)
    }

    // MARK: 4 — la stabilità, il test che conta

    @Test("Spostando un'ancora di un pixel nessuna etichetta salta")
    func placementIsStableUnderTinyAnchorMoves() {
        // Ancore ben separate: qui un pixel non deve cambiare quale candidato è ammissibile, e
        // quindi non deve cambiare nulla se non di un pixel.
        let base = (0..<8).map { index in
            request(index, x: 120 + Double(index % 4) * 190, y: 160 + Double(index / 4) * 240)
        }
        var moved = base
        moved[3].anchorX += 1

        let before = LabelLayout.place(base, inWidth: 900, height: 700)
        let after = LabelLayout.place(moved, inWidth: 900, height: 700)

        let afterByID = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
        var maximumShift = 0.0
        for label in before {
            let other = afterByID[label.id]!
            #expect(label.isPlaced == other.isPlaced)
            let dx = other.x - label.x
            let dy = other.y - label.y
            maximumShift = max(maximumShift, (dx * dx + dy * dy).squareRoot())
        }
        // Un pixel di ancora, al più un pixel di etichetta. La soglia è 2 e non 1 per lasciar
        // passare l'arrotondamento, non per lasciar passare un salto: un salto vale decine di
        // pixel, e questa soglia lo prenderebbe comunque.
        #expect(maximumShift <= 2.0)
    }

    // MARK: 5 — il determinismo

    @Test("Lo stesso insieme mescolato produce esattamente lo stesso esito")
    func outputDoesNotDependOnInputOrder() {
        var generator = Seeded(state: 777)
        var requests: [LabelRequest] = []
        for index in 0..<24 {
            requests.append(
                request(
                    index,
                    x: Double.random(in: 30...870, using: &generator),
                    y: Double.random(in: 30...670, using: &generator),
                    priority: index % 3))
        }

        let straight = LabelLayout.place(requests, inWidth: 900, height: 700)
        let shuffled = LabelLayout.place(requests.shuffled(using: &generator), inWidth: 900, height: 700)

        // Uguaglianza fra array, non fra insiemi: l'esito è ordinato per priorità e
        // identificatore, quindi due ingressi con lo stesso contenuto devono dare due array
        // identici anche nell'ordine.
        #expect(straight == shuffled)
    }

    // MARK: 6 — quando non c'è posto

    @Test("Con più etichette dello spazio alcune restano fuori, e nessuna si sovrappone")
    func crowdingLeavesSomeUnplacedRatherThanOverlapping() {
        // Venti etichette larghe su un riquadro piccolo: non ci stanno tutte, e va bene così.
        let requests = (0..<20).map { index in
            request(index, x: 100 + Double(index % 5) * 8, y: 90 + Double(index / 5) * 8, w: 110, h: 22)
        }
        let placed = LabelLayout.place(requests, inWidth: 320, height: 240)
        let byID = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })

        let unplaced = placed.filter { !$0.isPlaced }
        #expect(!unplaced.isEmpty, "venti etichette larghe non entrano in 320×240")

        let rects = placed.filter(\.isPlaced).map { rect($0, byID[$0.id]!) }
        for i in 0..<max(rects.count - 1, 0) {
            for j in (i + 1)..<rects.count {
                #expect(!overlap(rects[i], rects[j]))
            }
        }
    }

    // MARK: 7 — i bordi

    @Test("Un'ancora sul bordo produce un'etichetta dentro, dal lato che ha posto")
    func anchorOnTheEdgePlacesInwards() throws {
        // Ancora contro il bordo destro: a destra non c'è spazio, quindi deve andare a sinistra.
        let right = request(1, x: 895, y: 350)
        let placedRight = try #require(
            LabelLayout.place([right], inWidth: 900, height: 700).first)
        #expect(placedRight.isPlaced)
        #expect(placedRight.x + right.width <= 900 - 4 + 1e-9)
        #expect(placedRight.x < right.anchorX)

        // E lo stesso in alto: deve scendere.
        let top = request(2, x: 450, y: 5)
        let placedTop = try #require(LabelLayout.place([top], inWidth: 900, height: 700).first)
        #expect(placedTop.isPlaced)
        #expect(placedTop.y >= 4 - 1e-9)
    }

    // MARK: 8 — la linea di richiamo

    @Test("Il richiamo parte dal bordo dell'etichetta rivolto verso l'ancora")
    func leaderStartsOnTheEdgeFacingTheAnchor() throws {
        for (index, position) in [(400.0, 300.0), (60.0, 60.0), (860.0, 660.0)].enumerated() {
            let source = request(index, x: position.0, y: position.1)
            let label = try #require(
                LabelLayout.place([source], inWidth: 900, height: 700).first)
            #expect(label.isPlaced)

            // Sul bordo: almeno una coordinata coincide con un lato, e l'altra ci sta dentro.
            let onVertical =
                abs(label.leaderX - label.x) < 1e-9
                || abs(label.leaderX - (label.x + source.width)) < 1e-9
            let onHorizontal =
                abs(label.leaderY - label.y) < 1e-9
                || abs(label.leaderY - (label.y + source.height)) < 1e-9
            #expect(onVertical || onHorizontal)
            #expect(label.leaderX >= label.x - 1e-9)
            #expect(label.leaderX <= label.x + source.width + 1e-9)
            #expect(label.leaderY >= label.y - 1e-9)
            #expect(label.leaderY <= label.y + source.height + 1e-9)

            // Rivolto verso l'ancora: fra tutti i punti del bordo è quello più vicino, quindi
            // nessun angolo del rettangolo può stargli davanti.
            func distanceToAnchor(_ x: Double, _ y: Double) -> Double {
                let dx = x - source.anchorX, dy = y - source.anchorY
                return (dx * dx + dy * dy).squareRoot()
            }
            let leaderDistance = distanceToAnchor(label.leaderX, label.leaderY)
            let corners = [
                (label.x, label.y), (label.x + source.width, label.y),
                (label.x, label.y + source.height),
                (label.x + source.width, label.y + source.height),
            ]
            for corner in corners {
                #expect(leaderDistance <= distanceToAnchor(corner.0, corner.1) + 1e-9)
            }
        }
    }
}
