import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// La curva proposta dall'anatomia, su una fetta costruita apposta.
//
// # Perché serve una fetta finta
//
// Perché su una CBCT vera non si sa quale sia la risposta giusta, e su un fantoccio cubico non
// c'è nessuna arcata. Qui la fetta ha una U di raggio noto e, dietro, una macchia separata che
// fa le veci della colonna cervicale — che sulle fette vere c'è quasi sempre, ed è ciò che
// mandava fuori strada la proposta: tirava il baricentro all'indietro e riempiva i settori
// posteriori, quindi l'apertura della U spariva e la curva girava attorno alla testa.

@Suite("Proposta della curva d'arcata")
struct ArchDetectionShapeTests {

    /// Centro di curvatura della U, in millimetri Patient.
    static let archCentre = (x: 0.0, y: 15.0)
    /// Raggio della linea mediana dell'arcata.
    static let archRadius = 27.0
    /// Metà spessore della banda d'osso.
    static let archHalfWidth = 3.0
    /// La macchia posteriore: centro e raggio.
    static let spine = (x: 0.0, y: 46.0, radius: 8.0)

    /// Una fetta con l'arcata, e volendo la colonna.
    ///
    /// - Parameters:
    ///   - includingSpine: se aggiungere la macchia posteriore.
    ///   - closedRing: se chiudere la U in un anello, che non è un'arcata.
    /// - Parameter openingDegrees: quanto è larga l'apertura della figura. Un'arcata vera ne ha
    ///   un centinaio; venti gradi sono una tacca, non un'apertura.
    static func slice(
        includingSpine: Bool, closedRing: Bool = false, openingDegrees: Double? = nil
    ) throws -> Volume {
        let side = 140
        let orientation = try #require(SliceOrientation.standardAxial)
        let geometry = try VolumeGeometry(
            columnCount: side, rowCount: side, sliceCount: 3,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: orientation,
            originMM: Vec3(-Double(side) / 2, -Double(side) / 2, -1))

        var samples = [Int16](repeating: -1000, count: geometry.voxelCount)
        for k in 0..<geometry.sliceCount {
            for j in 0..<geometry.rowCount {
                for i in 0..<geometry.columnCount {
                    let point = geometry.patientPoint(i: i, j: j, k: k)
                    let dx = point.x - archCentre.x
                    let dy = point.y - archCentre.y
                    let radius = (dx * dx + dy * dy).squareRoot()

                    // La banda dell'arcata, aperta all'indietro: `y` cresce verso il posteriore,
                    // quindi tagliare sopra una quota lascia l'apertura dove deve stare.
                    let onBand = abs(radius - archRadius) <= archHalfWidth
                    let inFront: Bool
                    if let openingDegrees {
                        // Un anello con una tacca: pieno tutto intorno tranne uno spicchio.
                        var angle = Foundation.atan2(dy, dx) * 180 / .pi
                        if angle < 0 { angle += 360 }
                        inFront = abs(angle - 90) > openingDegrees / 2
                    } else {
                        inFront = closedRing || dy <= 10
                    }
                    var isBone = onBand && inFront

                    if includingSpine {
                        let sx = point.x - spine.x
                        let sy = point.y - spine.y
                        if (sx * sx + sy * sy).squareRoot() <= spine.radius { isBone = true }
                    }
                    if isBone {
                        samples[(k * geometry.rowCount + j) * geometry.columnCount + i] = 1400
                    }
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    static func distanceFromArchCentre(_ point: Vec3) -> Double {
        let dx = point.x - archCentre.x
        let dy = point.y - archCentre.y
        return (dx * dx + dy * dy).squareRoot()
    }

    @Test("I punti proposti seguono l'arcata")
    func theSuggestedPointsFollowTheArch() throws {
        let volume = try Self.slice(includingSpine: false)
        let points = try #require(
            ArchDetection.suggestArchPoints(in: volume, atVerticalMM: 0, pointCount: 9))

        #expect(points.count == 9)
        for point in points {
            let radius = Self.distanceFromArchCentre(point)
            #expect(
                abs(radius - Self.archRadius) <= Self.archHalfWidth + 2,
                "raggio \(radius) invece di \(Self.archRadius)")
        }
        // E la percorrono tutta: dal molare di un lato a quello dell'altro.
        let xs = points.map(\.x)
        #expect(try #require(xs.min()) < -18)
        #expect(try #require(xs.max()) > 18)
    }

    @Test("La colonna dietro non sposta la curva")
    func theSpineBehindDoesNotDragTheCurve() throws {
        // È la prova che conta. Con la macchia posteriore inclusa nel conto, il baricentro
        // arretrava e i settori dietro si riempivano: l'apertura della U spariva e la curva
        // girava attorno alla testa.
        let withSpine = try #require(
            ArchDetection.suggestArchPoints(
                in: try Self.slice(includingSpine: true), atVerticalMM: 0, pointCount: 9))

        for point in withSpine {
            let radius = Self.distanceFromArchCentre(point)
            #expect(
                abs(radius - Self.archRadius) <= Self.archHalfWidth + 2,
                "raggio \(radius): la curva è finita fuori dall'arcata")

            // E nessun punto cade dentro la macchia posteriore.
            let sx = point.x - Self.spine.x
            let sy = point.y - Self.spine.y
            #expect((sx * sx + sy * sy).squareRoot() > Self.spine.radius + 2)
        }

        // Con e senza colonna la curva è praticamente la stessa: è la definizione di «non si
        // lascia trascinare».
        let withoutSpine = try #require(
            ArchDetection.suggestArchPoints(
                in: try Self.slice(includingSpine: false), atVerticalMM: 0, pointCount: 9))
        for (a, b) in zip(withSpine, withoutSpine) {
            #expect(a.distance(to: b) < 3, "\(a) contro \(b)")
        }
    }

    @Test("Un anello chiuso non è un'arcata, e viene rifiutato")
    func aClosedRingIsRefused() throws {
        // Capita sulle fette prese all'altezza dei condili, dove il cranio si chiude tutto
        // intorno. Proporre una curva lì vorrebbe dire proporre un anello.
        let ring = try Self.slice(includingSpine: false, closedRing: true)
        #expect(ArchDetection.suggestArchPoints(in: ring, atVerticalMM: 0, pointCount: 9) == nil)
    }

    @Test("Una tacca di venti gradi non è l'apertura di un'arcata")
    func aTwentyDegreeNotchIsNotAnOpening() throws {
        // Il difetto che questo blocca: bastava **un** settore vuoto perché la figura passasse
        // per un'arcata. Un anello con una tacca da cinque gradi veniva preso per una U, e la
        // curva partiva da un lato della tacca girando per trecentocinquanta gradi attorno al
        // baricentro — un anello attorno alla testa, che è la «curva senza logica».
        let notched = try Self.slice(includingSpine: false, openingDegrees: 20)
        #expect(
            ArchDetection.suggestArchPoints(in: notched, atVerticalMM: 0, pointCount: 9) == nil)

        // Un'apertura vera invece passa: la soglia distingue, non rifiuta tutto.
        let real = try Self.slice(includingSpine: false, openingDegrees: 110)
        #expect(ArchDetection.suggestArchPoints(in: real, atVerticalMM: 0, pointCount: 9) != nil)
    }

    @Test("La componente più grande isola l'arcata dal resto")
    func theLargestComponentIsolatesTheArch() {
        // Due macchie separate su una griglia minuscola: la grande vince, e la piccola non
        // contribuisce nemmeno con un punto.
        let columns = 10
        let rows = 6
        var densities = [Double](repeating: 0, count: columns * rows)
        for index in [0, 1, 2, 10, 11, 12, 20, 21] { densities[index] = 100 }  // grande
        for index in [8, 9, 18] { densities[index] = 100 }  // piccola

        let component = ArchDetection.largestComponent(
            densities: densities, columns: columns, rows: rows, threshold: 50)
        #expect(component.count == 8)
        #expect(!component.contains(8))
        #expect(!component.contains(9))
        #expect(!component.contains(18))
    }

    @Test("Due macchie che si sfiorano in diagonale restano due")
    func diagonalTouchDoesNotMergeComponents() {
        // Connessione a quattro vicini: a otto, la corticale linguale e la punta di un processo
        // che si sfiorano diventerebbero una macchia sola, ed è la fusione che questo filtro
        // esiste per evitare.
        let columns = 4
        let rows = 4
        var densities = [Double](repeating: 0, count: columns * rows)
        densities[0] = 100
        densities[1] = 100
        densities[6] = 100  // tocca l'1 solo in diagonale

        let component = ArchDetection.largestComponent(
            densities: densities, columns: columns, rows: rows, threshold: 50)
        #expect(component.count == 2)
    }
}
