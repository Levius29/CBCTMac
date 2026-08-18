import DICOMCore
import Testing

@testable import MeasureKit

// La macchina a stati degli strumenti.
//
// Le prove che contano qui sono due, e sono quelle che il difetto originale avrebbe fatto
// fallire: che `prepare` con la stessa forma **non** azzeri — altrimenti nessuna misura arriva
// mai al secondo punto — e che l'ancoraggio sia quello del **primo** punto.

@Suite("Sessione degli strumenti")
struct ToolSessionTests {

    private func anchor(_ x: Double) -> ToolAnchor {
        ToolAnchor(
            originMM: Vec3(x, 0, 0),
            normalMM: Vec3(0, 0, 1),
            rightMM: Vec3(1, 0, 0),
            downMM: Vec3(0, 1, 0),
            visibilityToleranceMM: 0.4)
    }

    // MARK: Chiusura automatica

    @Test("Una forma a due punti si chiude al secondo e lascia la sessione vuota")
    func twoPointShapeClosesOnTheSecond() {
        var session = ToolSession(shape: .twoPoints)

        #expect(session.add(Vec3(0, 0, 0)) == nil)
        #expect(session.pointsMM.count == 1)

        let completed = session.add(Vec3(10, 0, 0))
        #expect(completed?.count == 2)
        #expect(session.isEmpty, "chi chiama non deve doversi ricordare di ripulire")
    }

    @Test("Ogni forma si chiude al numero di punti che dichiara")
    func eachShapeClosesAtItsCount() {
        for shape in [ToolShape.singlePoint, .twoPoints, .threePoints, .fourPoints] {
            let required = shape.requiredPoints!
            var session = ToolSession(shape: shape)
            for index in 0..<(required - 1) {
                #expect(
                    session.add(Vec3(Double(index), 0, 0)) == nil,
                    "\(shape): chiusa troppo presto al punto \(index + 1)")
            }
            let completed = session.add(Vec3(Double(required), 0, 0))
            #expect(completed?.count == required, "\(shape): non si è chiusa al punto \(required)")
        }
    }

    @Test("La spezzata accumula e si chiude solo a comando")
    func openPolylineClosesOnDemand() {
        var session = ToolSession(shape: .openPolyline)
        for index in 0..<6 {
            #expect(session.add(Vec3(Double(index), 0, 0)) == nil)
        }
        #expect(session.pointsMM.count == 6)

        let completed = session.close()
        #expect(completed?.count == 6)
        #expect(session.isEmpty)
    }

    @Test("Chiudere una spezzata con un punto solo non produce nulla e non lascia residui")
    func closingTooEarlyProducesNothing() {
        var session = ToolSession(shape: .openPolyline)
        session.add(Vec3(1, 2, 3))
        #expect(session.close() == nil)
        #expect(session.isEmpty, "un ripensamento non deve lasciare un punto orfano")
    }

    // MARK: Cambio di strumento

    @Test("Preparare la stessa forma non azzera i punti già posati")
    func preparingTheSameShapeKeepsThePoints() {
        // È la prova che protegge dal difetto più facile da introdurre: la vista chiama
        // `prepare` a ogni clic, e se azzerasse ogni volta nessuna misura arriverebbe mai al
        // secondo punto — cioè esattamente il sintomo «lo strumento non fa niente».
        var session = ToolSession(shape: .twoPoints)
        session.prepare(for: .twoPoints)
        session.add(Vec3(0, 0, 0), anchor: anchor(1))
        session.prepare(for: .twoPoints)

        #expect(session.pointsMM.count == 1)
        #expect(session.anchor == anchor(1))
        #expect(session.add(Vec3(5, 0, 0))?.count == 2)
    }

    @Test("Cambiare forma butta via i punti della forma precedente")
    func changingShapeDiscardsThePoints() {
        var session = ToolSession(shape: .threePoints)
        session.add(Vec3(0, 0, 0), anchor: anchor(1))
        session.add(Vec3(1, 0, 0))
        #expect(session.pointsMM.count == 2)

        session.prepare(for: .twoPoints)
        #expect(session.isEmpty)
        #expect(session.anchor == nil, "l'ancoraggio è di quella misura, non della successiva")
    }

    // MARK: Ancoraggio

    @Test("L'ancoraggio è quello del primo punto, non dell'ultimo")
    func anchorComesFromTheFirstPoint() {
        // Un'ellisse posata a cavallo di due riquadri deve prendere l'orientamento da dove è
        // cominciata. Se prendesse l'ultimo, la stessa ellisse cambierebbe assi a seconda di dove
        // si chiude.
        var session = ToolSession(shape: .twoPoints)
        session.add(Vec3(0, 0, 0), anchor: anchor(1))
        let held = session.anchor
        session.add(Vec3(9, 0, 0), anchor: anchor(2))

        #expect(held == anchor(1))
    }

    @Test("Dopo una chiusura il prossimo primo punto porta il proprio ancoraggio")
    func anchorIsReplacedOnTheNextMeasurement() {
        var session = ToolSession(shape: .twoPoints)
        session.add(Vec3(0, 0, 0), anchor: anchor(1))
        session.add(Vec3(1, 0, 0), anchor: anchor(1))

        session.add(Vec3(2, 0, 0), anchor: anchor(7))
        #expect(session.anchor == anchor(7))
    }

    // MARK: Ripensamenti

    @Test("Togliere l'ultimo punto lascia gli altri e libera l'ancoraggio solo se si svuota")
    func removingTheLastPointStepsBack() {
        var session = ToolSession(shape: .openPolyline)
        session.add(Vec3(0, 0, 0), anchor: anchor(1))
        session.add(Vec3(1, 0, 0))

        #expect(session.removeLastPoint() == Vec3(1, 0, 0))
        #expect(session.pointsMM == [Vec3(0, 0, 0)])
        #expect(session.anchor == anchor(1), "c'è ancora un punto: l'ancoraggio serve ancora")

        #expect(session.removeLastPoint() == Vec3(0, 0, 0))
        #expect(session.anchor == nil)
        #expect(session.removeLastPoint() == nil, "da vuota non si torna più indietro")
    }

    @Test("Annullare svuota tutto")
    func cancelClearsEverything() {
        var session = ToolSession(shape: .fourPoints)
        session.add(Vec3(0, 0, 0), anchor: anchor(1))
        session.add(Vec3(1, 0, 0))
        session.cancel()

        #expect(session.isEmpty)
        #expect(session.anchor == nil)
    }

    // MARK: Che cosa si legge a schermo

    @Test("Il conto dice quanti punti mancano, e tace quando non c'è nulla in corso")
    func hintCountsWhatIsMissing() {
        var session = ToolSession(shape: .threePoints)
        #expect(session.progressHint == nil, "a mani vuote non c'è nulla da dire")

        session.add(Vec3(0, 0, 0))
        #expect(session.progressHint == "mancano 2 punti")

        session.add(Vec3(1, 0, 0))
        #expect(session.progressHint == "manca 1 punto")

        session.add(Vec3(2, 0, 0))
        #expect(session.progressHint == nil, "chiusa: non manca più niente")
    }

    @Test("La spezzata dice come si chiude, perché da sé non si chiude mai")
    func openPolylineHintExplainsHowToClose() {
        var session = ToolSession(shape: .openPolyline)
        session.add(Vec3(0, 0, 0))
        let first = try! #require(session.progressHint)
        #expect(first.contains("1 punto posato"))
        #expect(first.contains("doppio clic"))

        session.add(Vec3(1, 0, 0))
        #expect(session.progressHint?.contains("2 punti posati") == true)
    }

    @Test("Il conto dei punti mancanti non va sotto zero")
    func missingPointsNeverGoesNegative() {
        var session = ToolSession(shape: .singlePoint)
        #expect(session.missingPoints == 1)
        session.add(Vec3(0, 0, 0))
        #expect(session.missingPoints == 1, "chiusa e svuotata: ne manca di nuovo uno")
        #expect(ToolSession(shape: .openPolyline).missingPoints == nil)
    }
}
