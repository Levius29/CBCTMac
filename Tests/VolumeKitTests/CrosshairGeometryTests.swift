import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Test della geometria del mirino.
//
// Quello che si vuole provare qui non è che il codice giri: è che la linea disegnata **sia**
// l'intersezione dei due piani anche quando sono obliqui. È la proprietà che la vecchia croce
// disegnata a metà riquadro violava senza dirlo, ed è invisibile finché tutto resta allineato
// agli assi — motivo per cui metà di questi test partono da un piano già ruotato.

@Suite("Geometria del mirino")
struct CrosshairGeometryTests {

    private let width = 400
    private let height = 300

    private func axial(through point: Vec3 = .zero) -> MPRPlane {
        MPRPlane(plane: .axial, through: point, widthMM: 80, heightMM: 60)
    }

    private func sagittal(through point: Vec3 = .zero) -> MPRPlane {
        MPRPlane(plane: .sagittal, through: point, widthMM: 80, heightMM: 60)
    }

    private func coronal(through point: Vec3 = .zero) -> MPRPlane {
        MPRPlane(plane: .coronal, through: point, widthMM: 80, heightMM: 60)
    }

    // MARK: Il caso ortogonale, che deve restare quello di prima

    @Test("Nell'assiale la traccia del sagittale è verticale e passa per il mirino")
    func orthogonalSagittalTraceIsVertical() throws {
        let point = Vec3(4, -6, 2)
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: axial(through: point), through: point,
                pixelWidth: width, pixelHeight: height))

        // Verticale: stessa ascissa ai due capi.
        #expect(abs(trace.start.x - trace.end.x) < 1e-6)
        // Attraversa tutto il riquadro, da bordo a bordo.
        #expect(abs(min(trace.start.y, trace.end.y) + 0.5) < 1e-6)
        #expect(abs(max(trace.start.y, trace.end.y) - (Double(height) - 0.5)) < 1e-6)
        // E il perno le sta sopra.
        #expect(abs(trace.pivot.x - trace.start.x) < 1e-6)
    }

    @Test("Nell'assiale la traccia del coronale è orizzontale")
    func orthogonalCoronalTraceIsHorizontal() throws {
        let point = Vec3(4, -6, 2)
        let trace = try #require(
            CrosshairGeometry.trace(
                of: coronal(through: point), in: axial(through: point), through: point,
                pixelWidth: width, pixelHeight: height))

        #expect(abs(trace.start.y - trace.end.y) < 1e-6)
        #expect(abs(min(trace.start.x, trace.end.x) + 0.5) < 1e-6)
        #expect(abs(max(trace.start.x, trace.end.x) - (Double(width) - 0.5)) < 1e-6)
    }

    @Test("Il mirino fuori centro sposta la traccia, e la sposta della quantità giusta")
    func traceFollowsTheCrosshair() throws {
        let view = axial(through: .zero)
        // Mirino spostato di 20 mm verso destra dello schermo. Su un assiale standard `right` è
        // −x in LPS, quindi il punto ha x = −20 e deve finire a tre quarti di larghezza.
        let point = view.centerMM + view.rightMM * 20
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: view, through: point,
                pixelWidth: width, pixelHeight: height))

        // 20 mm su una finestra di 80 mm larga 400 px sono 100 px. Il centro del riquadro sta a
        // (400−1)/2 = 199,5 perché `pixelPosition` conta i **centri** dei pixel, quindi 299,5.
        #expect(abs(trace.pivot.x - 299.5) < 1e-6)
    }

    // MARK: Il caso che conta: piani obliqui

    @Test("Su un sagittale ruotato di 30° la traccia è inclinata di 30°")
    func obliqueTraceIsTilted() throws {
        let point = Vec3.zero
        let view = axial(through: point)
        let angle = 30.0 * .pi / 180
        let tilted = sagittal(through: point)
            .rotated(aboutAxis: view.normalMM, byRadians: angle, aboutMM: point)

        let trace = try #require(
            CrosshairGeometry.trace(
                of: tilted, in: view, through: point,
                pixelWidth: width, pixelHeight: height))
        let straight = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: view, through: point,
                pixelWidth: width, pixelHeight: height))

        // Si confronta con la traccia non inclinata invece di misurare un angolo assoluto,
        // perché il **verso** della direzione è arbitrario: `n × m` può uscire da una parte o
        // dall'altra a seconda di come sono orientate le normali, e un test che si aggrappasse a
        // quel verso proverebbe una convenzione interna invece della proprietà che interessa.
        // Da qui il valore assoluto: fra due rette l'angolo è definito a meno di π.
        let cosine = abs(trace.directionMM.dot(straight.directionMM))
        let measured = Foundation.acos(min(cosine, 1))
        #expect(abs(measured - angle) < 1e-9)

        // E la traccia inclinata non è più verticale: è la ragione per cui esiste questo file.
        #expect(abs(trace.start.x - trace.end.x) > 100)
    }

    @Test("La traccia obliqua passa comunque esattamente per il mirino")
    func obliqueTracePassesThroughTheCrosshair() throws {
        let point = Vec3(-7, 3, 11)
        var view = axial(through: point)
        view = view.rotated(aboutAxis: Vec3(1, 0, 0), byRadians: 0.22, aboutMM: point)
        let other = coronal(through: point)
            .rotated(aboutAxis: Vec3(0, 1, 0), byRadians: -0.31, aboutMM: point)

        let trace = try #require(
            CrosshairGeometry.trace(
                of: other, in: view, through: point,
                pixelWidth: width, pixelHeight: height))

        #expect(trace.distance(from: trace.pivot) < 1e-6)

        // E la direzione giace su entrambi i piani, che è la definizione di intersezione.
        #expect(abs(trace.directionMM.dot(view.normalMM)) < 1e-12)
        #expect(abs(trace.directionMM.dot(other.normalMM)) < 1e-12)
    }

    // MARK: Casi in cui non c'è nulla da disegnare

    @Test("Due piani paralleli non hanno traccia")
    func parallelPlanesHaveNoTrace() {
        let point = Vec3.zero
        let view = axial(through: point)
        let parallel = axial(through: point).advanced(byMM: 5)
        #expect(
            CrosshairGeometry.trace(
                of: parallel, in: view, through: point,
                pixelWidth: width, pixelHeight: height) == nil)
    }

    @Test("Un mirino fuori dal riquadro non produce traccia")
    func crosshairOutsideTheViewportHasNoTrace() {
        let view = axial(through: .zero)
        // Cento millimetri a destra su una finestra larga ottanta: ben fuori.
        let point = view.centerMM + view.rightMM * 100
        #expect(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: view, through: point,
                pixelWidth: width, pixelHeight: height) == nil)
    }

    @Test("Un mirino che non giace sulla vista non produce traccia")
    func crosshairOffThePlaneHasNoTrace() {
        let view = axial(through: .zero)
        let point = view.centerMM + view.normalMM * 3
        #expect(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: view, through: point,
                pixelWidth: width, pixelHeight: height) == nil)
    }

    // MARK: Maniglie

    @Test("Le maniglie stanno sulla linea, dentro il riquadro, e simmetriche rispetto al perno")
    func handlesSitOnTheLine() throws {
        let point = Vec3.zero
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: axial(through: point), through: point,
                pixelWidth: width, pixelHeight: height))

        let start = try #require(trace.startHandle)
        let end = try #require(trace.endHandle)

        #expect(trace.distance(from: start) < 1e-9)
        #expect(trace.distance(from: end) < 1e-9)
        #expect(start.y > 0 && start.y < Double(height))
        #expect(end.y > 0 && end.y < Double(height))
        // Il perno è a metà riquadro, quindi le due maniglie devono stargli alla stessa distanza.
        #expect(abs(start.distance(to: trace.pivot) - end.distance(to: trace.pivot)) < 1e-6)
    }

    @Test("Su un tratto visibile corto le maniglie non compaiono")
    func shortTraceHasNoHandles() throws {
        let view = axial(through: .zero)
        // Mirino a pochi pixel dal bordo inferiore: la traccia del coronale è orizzontale e
        // lunga, ma quella del sagittale resta lunga anche lei. Serve invece un riquadro basso.
        let point = view.centerMM + view.downMM * 29
        let trace = try #require(
            CrosshairGeometry.trace(
                of: coronal(through: point), in: view, through: point,
                pixelWidth: width, pixelHeight: 40))
        // Con un riquadro alto 40 px la traccia orizzontale è lunga 400: le maniglie ci sono.
        #expect(trace.startHandle != nil)

        // Un riquadro largo 50 px taglia la traccia orizzontale a 50: sotto la soglia.
        let narrow = try #require(
            CrosshairGeometry.trace(
                of: coronal(through: .zero), in: axial(through: .zero), through: .zero,
                pixelWidth: 50, pixelHeight: 300))
        #expect(narrow.lengthPixels == 50)
        #expect(narrow.startHandle == nil)
        #expect(narrow.endHandle == nil)
    }

    // MARK: Presa

    @Test("La maniglia vince sulla linea, e il centro non risponde")
    func gripPriority() throws {
        let point = Vec3.zero
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: axial(through: point), through: point,
                pixelWidth: width, pixelHeight: height))
        let handle = try #require(trace.startHandle)

        // Sulla maniglia: maniglia, benché la linea passi esattamente lì.
        #expect(trace.grip(at: handle) == .handle(isStart: true))
        // Sulla linea, lontano dalle maniglie e dal centro.
        // y = 100: lontano dal vuoto centrale (50 px) e da entrambe le maniglie (~65 px).
        #expect(trace.grip(at: PixelPoint(x: trace.pivot.x + 2, y: 100)) == .line)
        // Nel vuoto centrale: niente, il clic spetta al mirino.
        #expect(trace.grip(at: trace.pivot) == nil)
        #expect(trace.grip(at: PixelPoint(x: trace.pivot.x, y: trace.pivot.y + 5)) == nil)
        // Lontano dalla linea: niente.
        #expect(trace.grip(at: PixelPoint(x: trace.pivot.x + 60, y: 100)) == nil)
    }

    // MARK: Rotazione

    @Test("Il segno della rotazione è quello che serve a MPRPlane.rotated")
    func rotationSignMatchesThePlaneRotation() throws {
        // Questo è il test che giustifica il commento sul verso, e serve perché sbagliare il
        // segno non produce un errore: produce una linea che gira dalla parte opposta al dito.
        let point = Vec3.zero
        let view = axial(through: point)
        let plane = sagittal(through: point)

        let trace = try #require(
            CrosshairGeometry.trace(
                of: plane, in: view, through: point,
                pixelWidth: width, pixelHeight: height))

        // Il puntatore parte sotto il perno e si sposta a destra. Con l'asse y verso il basso,
        // «sotto» sta a +π/2 e «sotto a destra» a +π/4: l'angolo **cala**, ed è giusto che cali,
        // perché sullo schermo il punto gira in senso antiorario — dalle 6 verso le 4:30.
        let before = PixelPoint(x: trace.pivot.x, y: trace.pivot.y + 100)
        let after = PixelPoint(x: trace.pivot.x + 100, y: trace.pivot.y + 100)
        let delta = try #require(trace.rotation(from: before, to: after))
        #expect(abs(delta + .pi / 4) < 1e-12)

        // Questa è l'asserzione che conta, e le due sopra sono solo il suo contesto: applicando
        // quell'angolo al piano con l'asse che la traccia dichiara, la nuova traccia deve passare
        // **per il punto d'arrivo del dito**. È la proprietà che l'utente percepisce — la linea
        // segue la maniglia — e nessun errore di segno può soddisfarla per caso.
        let rotated = plane.rotated(
            aboutAxis: trace.rotationAxisMM, byRadians: delta, aboutMM: point)
        let newTrace = try #require(
            CrosshairGeometry.trace(
                of: rotated, in: view, through: point,
                pixelWidth: width, pixelHeight: height))
        #expect(newTrace.distance(from: after) < 1e-6)

        // Prova che l'asserzione sopra sia capace di fallire: col segno invertito la linea
        // finisce a 90° dal punto d'arrivo, cioè lontanissima.
        let wrongWay = plane.rotated(
            aboutAxis: trace.rotationAxisMM, byRadians: -delta, aboutMM: point)
        let wrongTrace = try #require(
            CrosshairGeometry.trace(
                of: wrongWay, in: view, through: point,
                pixelWidth: width, pixelHeight: height))
        #expect(wrongTrace.distance(from: after) > 100)
    }

    @Test("La rotazione ignora le posizioni troppo vicine al perno")
    func rotationRejectsPositionsOnThePivot() throws {
        let point = Vec3.zero
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: axial(through: point), through: point,
                pixelWidth: width, pixelHeight: height))
        #expect(trace.rotation(from: trace.pivot, to: PixelPoint(x: trace.pivot.x + 50, y: 10)) == nil)
    }

    @Test("La rotazione avvolge correttamente attraverso ±π")
    func rotationWrapsAcrossPi() throws {
        let point = Vec3.zero
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: axial(through: point), through: point,
                pixelWidth: width, pixelHeight: height))

        // Da poco sotto +π a poco sopra −π. La differenza grezza vale quasi −2π; quella giusta è
        // un angolo piccolo e positivo, perché a sinistra del perno passare da sotto a sopra
        // significa girare in senso orario sullo schermo — dalle 9 verso le 11.
        let before = PixelPoint(x: trace.pivot.x - 100, y: trace.pivot.y + 5)
        let after = PixelPoint(x: trace.pivot.x - 100, y: trace.pivot.y - 5)
        let delta = try #require(trace.rotation(from: before, to: after))
        #expect(delta > 0)
        #expect(abs(delta - 0.09991679) < 1e-6)
    }

    // MARK: Scorrimento

    @Test("Trascinando la linea si sposta il mirino solo perpendicolarmente a essa")
    func slideKeepsOnlyThePerpendicularComponent() throws {
        let point = Vec3.zero
        let view = axial(through: point)
        let plane = sagittal(through: point)
        let trace = try #require(
            CrosshairGeometry.trace(
                of: plane, in: view, through: point,
                pixelWidth: width, pixelHeight: height))

        // Trascinamento obliquo: 50 px a destra e 80 px in basso. La traccia del sagittale è
        // verticale, quindi la componente verticale non deve produrre nulla.
        let movement = trace.slide(
            from: PixelPoint(x: 200, y: 100),
            to: PixelPoint(x: 250, y: 180),
            in: view, pixelWidth: width, pixelHeight: height)

        // 50 px su 400 per 80 mm sono 10 mm lungo `right`.
        #expect(abs(movement.length - 10) < 1e-9)
        #expect(abs(movement.dot(trace.directionMM)) < 1e-12)
        #expect(movement.dot(view.rightMM) > 0)
    }

    @Test("Lo scorrimento lungo la linea non muove nulla")
    func slideAlongTheLineDoesNothing() throws {
        let point = Vec3.zero
        let view = axial(through: point)
        let trace = try #require(
            CrosshairGeometry.trace(
                of: sagittal(through: point), in: view, through: point,
                pixelWidth: width, pixelHeight: height))

        let movement = trace.slide(
            from: PixelPoint(x: 200, y: 40),
            to: PixelPoint(x: 200, y: 260),
            in: view, pixelWidth: width, pixelHeight: height)
        #expect(movement.length < 1e-12)
    }

    // MARK: Ritaglio

    @Test("Il ritaglio restituisce l'intervallo giusto e nulla quando la retta manca il riquadro")
    func clippingBounds() throws {
        // Retta orizzontale a metà altezza, origine al centro.
        let span = try #require(
            CrosshairGeometry.clipToRect(
                originX: 50, originY: 25, dx: 1, dy: 0,
                minX: 0, minY: 0, maxX: 100, maxY: 50))
        #expect(abs(span.lower - -50) < 1e-9)
        #expect(abs(span.upper - 50) < 1e-9)

        // Retta orizzontale sopra il riquadro: parallela a due bordi e fuori.
        #expect(
            CrosshairGeometry.clipToRect(
                originX: 50, originY: -10, dx: 1, dy: 0,
                minX: 0, minY: 0, maxX: 100, maxY: 50) == nil)

        // Retta diagonale che entra da un angolo ed esce dal bordo basso prima che dal destro.
        let diagonal = try #require(
            CrosshairGeometry.clipToRect(
                originX: 0, originY: 0, dx: 1, dy: 1,
                minX: 0, minY: 0, maxX: 100, maxY: 50))
        #expect(abs(diagonal.lower) < 1e-9)
        #expect(abs(diagonal.upper - 50) < 1e-9)

        // Estremi non nulli: è la forma con cui la usa `trace`, e va provata anche lei.
        let shifted = try #require(
            CrosshairGeometry.clipToRect(
                originX: 0, originY: 0, dx: 0, dy: 1,
                minX: -0.5, minY: -0.5, maxX: 99.5, maxY: 49.5))
        #expect(abs(shifted.lower + 0.5) < 1e-9)
        #expect(abs(shifted.upper - 49.5) < 1e-9)
    }
}
