import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// Test del riorientamento e della curva proposta.
//
// Il controllo che conta è il secondo: verifica che i **dati** si siano davvero mossi con la
// rotazione, e non solo le etichette del riferimento. Un'implementazione che ruotasse la sola
// matrice di orientamento produrrebbe un volume dall'aspetto identico, passerebbe il primo test e
// fallirebbe questo — che è precisamente la differenza fra raddrizzare l'anatomia e rinominare gli
// assi.

@Suite("Riorientamento del volume e curva proposta")
struct ReorientationTests {

    /// Fantoccio piccolo con un cubo denso al centro: serve un punto anatomico riconoscibile da
    /// cercare dopo la rotazione.
    private func makeCubeVolume() throws -> Volume {
        let n = 40
        let geometry = try VolumeGeometry(
            columnCount: n, rowCount: n, sliceCount: n,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial,
            originMM: Vec3(-19.5, -19.5, -19.5))

        var samples = [Int16](repeating: 0, count: n * n * n)
        for k in 0..<n {
            for j in 0..<n {
                for i in 0..<n {
                    let point = geometry.patientPoint(
                        fromVoxel: Vec3(Double(i), Double(j), Double(k)))
                    let inside = abs(point.x) <= 6 && abs(point.y) <= 6 && abs(point.z) <= 6
                    samples[(k * n + j) * n + i] = inside ? 1200 : 0
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    // MARK: 1 — la rotazione fa il suo mestiere

    @Test("La rotazione porta la normale del piano sulla verticale")
    func rotationLevelsThePlane() throws {
        // Piano inclinato di venti gradi attorno all'asse x.
        let tilt = 20.0 * .pi / 180
        let rotate = try #require(Transform3D.rotation(axis: Vec3(1, 0, 0), angle: tilt))
        let plan = ReorientationPlan(
            referencePointsMM: [Vec3(-10, -10, 0), Vec3(10, -10, 0), Vec3(0, 10, 0)]
                .map { rotate.apply(toPoint: $0) })

        let normal = try #require(plan.planeNormalMM)
        let rotation = try #require(plan.rotation())
        let levelled = rotation.apply(toVector: normal)

        // Verticale entro l'errore di macchina, e nel verso giusto: se il verso della normale non
        // fosse normalizzato, metà delle volte il volume si capovolgerebbe.
        #expect(abs(abs(levelled.z) - 1) < 1e-9)
        #expect(abs(levelled.x) < 1e-9)
        #expect(abs(levelled.y) < 1e-9)
    }

    @Test("Un piano già orizzontale non muove nulla")
    func levelPlaneGivesIdentity() throws {
        let plan = ReorientationPlan(
            referencePointsMM: [Vec3(-10, -10, 3), Vec3(10, -10, 3), Vec3(0, 10, 3)])
        let rotation = try #require(plan.rotation())
        #expect(rotation.isApproximatelyEqual(to: .identity, tolerance: 1e-12))

        // E il punto trasformato resta dov'era.
        let point = try #require(plan.transformed(Vec3(4, -7, 9)))
        #expect(point.isApproximatelyEqual(to: Vec3(4, -7, 9), tolerance: 1e-12))
    }

    // MARK: 2 — il test che distingue i dati dal riferimento

    @Test("Il tessuto si muove con la rotazione, non solo le etichette degli assi")
    func theDataMovesWithTheRotation() throws {
        let volume = try makeCubeVolume()
        let tilt = 20.0 * .pi / 180
        let rotate = try #require(Transform3D.rotation(axis: Vec3(1, 0, 0), angle: tilt))
        let plan = ReorientationPlan(
            referencePointsMM: [Vec3(-10, -10, 0), Vec3(10, -10, 0), Vec3(0, 10, 0)]
                .map { rotate.apply(toPoint: $0) })

        let reoriented = try VolumeReorientation.reoriented(volume, plan: plan, spacingMM: 1)

        // Un angolo del cubo, che nel volume di partenza è denso. Il suo corrispondente nel nuovo
        // riferimento è il punto trasformato, e deve essere denso anche lì.
        for corner in [Vec3(5, 5, 5), Vec3(-5, 5, -5), Vec3(5, -5, 0), Vec3(0, 0, 0)] {
            let before = try #require(volume.densityValue(atPatient: corner))
            let moved = try #require(plan.transformed(corner))
            let after = try #require(reoriented.interpolatedDensityValue(atPatient: moved))
            #expect(before > 1000)
            // Interpolando su una griglia ruotata il valore non è esatto, ma resta dentro il
            // cubo: se i dati **non** si fossero mossi, qui si leggerebbe zero.
            #expect(after > 600, "densità \(after) al punto trasformato \(moved)")
        }

        // E fuori dal cubo resta vuoto: senza questo controllo, un'implementazione che riempie
        // tutto di 1200 passerebbe il precedente.
        let outside = try #require(plan.transformed(Vec3(15, 15, 15)))
        let value = reoriented.interpolatedDensityValue(atPatient: outside) ?? 0
        #expect(value < 300)
    }

    // MARK: 3 e 4 — i rifiuti

    @Test("Tre punti allineati vengono rifiutati con un errore nominato")
    func collinearPointsAreRejected() throws {
        let plan = ReorientationPlan(
            referencePointsMM: [Vec3(0, 0, 0), Vec3(5, 0, 0), Vec3(10, 0, 0)])
        #expect(plan.planeNormalMM == nil)
        #expect(plan.rotation() == nil)
        #expect(!plan.validate().isEmpty)

        let volume = try makeCubeVolume()
        #expect(throws: ReorientationError.collinearReferencePoints) {
            try VolumeReorientation.reoriented(volume, plan: plan, spacingMM: 1)
        }
    }

    @Test("Tre punti quasi allineati vengono rifiutati come quelli allineati")
    func nearlyCollinearPointsAreRejected() throws {
        // Perfettamente allineati il prodotto vettoriale è zero esatto e `normalized` restituisce
        // già `nil`: qualunque guardia, anche nessuna, li rifiuta. Il controllo esiste per
        // **questi**, che sono allineati a meno di un picometro: il prodotto vettoriale è rumore
        // di arrotondamento, si normalizza benissimo, e la sua direzione è arbitraria. Senza la
        // soglia si otterrebbe una rotazione grande ricavata dal rumore, cioè un volume ruotato a
        // caso — e un volume ruotato a caso somiglia troppo a uno ruotato bene.
        let plan = ReorientationPlan(
            referencePointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0), Vec3(20, 1e-12, 1e-12)])
        #expect(plan.planeNormalMM == nil)
        #expect(plan.rotation() == nil)
        #expect(!plan.validate().isEmpty)

        let volume = try makeCubeVolume()
        #expect(throws: ReorientationError.collinearReferencePoints) {
            try VolumeReorientation.reoriented(volume, plan: plan, spacingMM: 1)
        }
    }

    @Test("L'ordine dei tre punti non cambia la rotazione")
    func pointOrderDoesNotFlipTheVolume() throws {
        let tilt = 18.0 * .pi / 180
        let rotate = try #require(Transform3D.rotation(axis: Vec3(1, 0, 0), angle: tilt))
        let points = [Vec3(-10, -10, 0), Vec3(10, -10, 0), Vec3(0, 10, 0)]
            .map { rotate.apply(toPoint: $0) }

        let forward = ReorientationPlan(referencePointsMM: points)
        let backward = ReorientationPlan(referencePointsMM: points.reversed())

        // Il verso della normale dipende dall'ordine in cui l'utente ha cliccato i tre punti,
        // che non è informazione: cliccarli in senso orario o antiorario deve dare lo stesso
        // raddrizzamento. Senza normalizzare il verso, un ordine su due capovolge il volume.
        let a = try #require(forward.rotation())
        let b = try #require(backward.rotation())
        #expect(a.isApproximatelyEqual(to: b, tolerance: 1e-9))
    }

    @Test("Meno di tre punti, o un passo non valido, vengono rifiutati")
    func otherRejections() throws {
        let volume = try makeCubeVolume()

        let tooFew = ReorientationPlan(referencePointsMM: [Vec3(0, 0, 0), Vec3(1, 0, 0)])
        #expect(throws: ReorientationError.notEnoughReferencePoints(count: 2)) {
            try VolumeReorientation.reoriented(volume, plan: tooFew, spacingMM: 1)
        }

        let good = ReorientationPlan(
            referencePointsMM: [Vec3(-5, -5, 0), Vec3(5, -5, 0), Vec3(0, 5, 0)])
        #expect(throws: ReorientationError.invalidSpacing(0)) {
            try VolumeReorientation.reoriented(volume, plan: good, spacingMM: 0)
        }
    }

    @Test("Il volume riorientato contiene tutto quello di partenza, angoli compresi")
    func nothingIsCroppedAway() throws {
        let volume = try makeCubeVolume()
        let tilt = 25.0 * .pi / 180
        let rotate = try #require(Transform3D.rotation(axis: Vec3(0, 1, 0), angle: tilt))
        let plan = ReorientationPlan(
            referencePointsMM: [Vec3(-10, -10, 0), Vec3(10, -10, 0), Vec3(0, 10, 0)]
                .map { rotate.apply(toPoint: $0) })

        let reoriented = try VolumeReorientation.reoriented(volume, plan: plan, spacingMM: 1)

        // Ogni vertice del volume di partenza, trasformato, deve cadere dentro il nuovo.
        // Tenendo le dimensioni originali gli angoli finirebbero fuori — ed è lì che sta
        // l'anatomia periferica, condili compresi.
        for corner in volume.geometry.boundingBoxCornersMM {
            let moved = try #require(plan.transformed(corner))
            #expect(reoriented.geometry.containsPatientPoint(moved), "angolo perso: \(moved)")
        }
    }

    // MARK: 5, 6 e 7 — la curva proposta

    /// Fantoccio con un arco di corticale: una U di osso attorno a un centro, come un'arcata
    /// vista da sopra.
    private func makeArchVolume(withArch: Bool) throws -> Volume {
        let n = 60
        let geometry = try VolumeGeometry(
            columnCount: n, rowCount: n, sliceCount: 10,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial,
            originMM: Vec3(-29.5, -29.5, -4.5))

        var samples = [Int16](repeating: 100, count: n * n * 10)
        guard withArch else { return try Volume(geometry: geometry, samples: samples) }

        for k in 0..<10 {
            for j in 0..<n {
                for i in 0..<n {
                    let point = geometry.patientPoint(
                        fromVoxel: Vec3(Double(i), Double(j), Double(k)))
                    let radius = (point.x * point.x + point.y * point.y).squareRoot()
                    var angle = Foundation.atan2(point.y, point.x)
                    if angle < 0 { angle += 2 * .pi }
                    // Anello di raggio 20 mm, spesso 3, aperto sul settore posteriore.
                    let onRing = abs(radius - 20) < 1.5
                    let inOpening = angle > 4.2 && angle < 5.2
                    if onRing, !inOpening {
                        samples[(k * n + j) * n + i] = 1600
                    }
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    @Test("Su un'arcata sintetica i punti proposti cadono sull'arco")
    func suggestsPointsOnTheArch() throws {
        let volume = try makeArchVolume(withArch: true)
        let points = try #require(
            ArchDetection.suggestArchPoints(in: volume, atVerticalMM: 0, pointCount: 7))

        #expect(points.count == 7)
        for point in points {
            let radius = (point.x * point.x + point.y * point.y).squareRoot()
            // Sull'anello di raggio 20, entro pochi millimetri.
            #expect(abs(radius - 20) < 3, "punto a raggio \(radius)")
            #expect(abs(point.z) < 1e-9)
        }

        // I punti **percorrono** l'arco invece di ammucchiarsi. La distanza fra il primo e
        // l'ultimo sarebbe il controllo sbagliato, e l'avevo scritto così: su un arco quasi
        // chiuso i due capi si riavvicinano, e qui la corda misura 19,5 mm anche se i punti
        // coprono cinque radianti. Ciò che conta è la lunghezza **lungo** la spezzata.
        var traversed = 0.0
        var shortestStep = Double.infinity
        for index in 1..<points.count {
            let step = points[index].distance(to: points[index - 1])
            traversed += step
            shortestStep = min(shortestStep, step)
        }
        // Un arco di circa cinque radianti a raggio 20 misura un centinaio di millimetri.
        #expect(traversed > 80, "spezzata lunga \(traversed) mm")
        // E nessuna coppia consecutiva è ammucchiata sull'altra.
        #expect(shortestStep > 5, "due punti a \(shortestStep) mm")
    }

    @Test("Un anello chiuso non è un'arcata e viene rifiutato")
    func refusesAClosedRing() throws {
        // Stessa corticale, senza apertura: è il caso di una fetta presa all'altezza dei condili,
        // dove il cranio si chiude tutto attorno. Circonda il baricentro, quindi non è una U, e
        // una curva d'arcata ricavata da lì sarebbe un cerchio senza significato.
        let n = 60
        let geometry = try VolumeGeometry(
            columnCount: n, rowCount: n, sliceCount: 10,
            columnSpacingMM: 1, rowSpacingMM: 1, sliceSpacingMM: 1,
            orientation: .standardAxial,
            originMM: Vec3(-29.5, -29.5, -4.5))
        var samples = [Int16](repeating: 100, count: n * n * 10)
        for k in 0..<10 {
            for j in 0..<n {
                for i in 0..<n {
                    let point = geometry.patientPoint(
                        fromVoxel: Vec3(Double(i), Double(j), Double(k)))
                    let radius = (point.x * point.x + point.y * point.y).squareRoot()
                    if abs(radius - 20) < 1.5 { samples[(k * n + j) * n + i] = 1600 }
                }
            }
        }
        let volume = try Volume(geometry: geometry, samples: samples)
        #expect(ArchDetection.suggestArchPoints(in: volume, atVerticalMM: 0) == nil)
    }

    @Test("Su solo tessuto molle non propone nulla")
    func refusesOnSoftTissueOnly() throws {
        let volume = try makeArchVolume(withArch: false)
        // Densità uniforme: la soglia automatica al quinto più denso non separa niente, e la
        // figura risultante non ha un'apertura. Deve rifiutare invece di proporre un anello.
        #expect(ArchDetection.suggestArchPoints(in: volume, atVerticalMM: 0) == nil)
    }

    @Test("Su una quota fuori dal volume non propone nulla, e non va in errore")
    func refusesOutsideTheVolume() throws {
        let volume = try makeArchVolume(withArch: true)
        #expect(ArchDetection.suggestArchPoints(in: volume, atVerticalMM: 500) == nil)
    }

    @Test("Una soglia troppo alta produce un rifiuto, non una curva a caso")
    func refusesWhenNothingPassesTheThreshold() throws {
        let volume = try makeArchVolume(withArch: true)
        #expect(
            ArchDetection.suggestArchPoints(in: volume, atVerticalMM: 0, thresholdGV: 9000) == nil)
    }
}
