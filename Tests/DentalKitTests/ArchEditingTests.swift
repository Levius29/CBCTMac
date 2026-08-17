import DICOMCore
import Testing

@testable import DentalKit

// Modifica della curva d'arcata.
//
// Il test che conta è il primo: un punto cliccato fra due punti esistenti deve finire **fra** i
// due, non in coda. Accodando sempre, la Catmull-Rom — che percorre i punti nell'ordine
// dell'array — arriva ai molari, torna indietro al punto nuovo e riparte: un cappio. Chi lo prova
// conclude che la curva va per conto suo, e ha ragione.

@Suite("Modifica della curva d'arcata")
struct ArchEditingTests {

    /// Cinque punti su una U, dal molare destro al molare sinistro passando per gli incisivi.
    private func makeArch() -> ArchCurve {
        ArchCurve(controlPointsMM: [
            Vec3(-25, 10, 5),
            Vec3(-18, -6, 5),
            Vec3(0, -14, 5),
            Vec3(18, -6, 5),
            Vec3(25, 10, 5),
        ])
    }

    // MARK: Inserimento nell'ordine giusto

    @Test("Un punto cliccato fra due punti finisce fra i due, non in coda")
    func insertsIntoTheNearestSegment() {
        var curve = makeArch()
        // A metà fra il punto 1 e il punto 2, spostato di poco verso l'esterno: è il gesto tipico
        // di chi infittisce la curva dove l'anatomia gira.
        let clicked = Vec3(-9.5, -11.0, 5)

        let outcome = curve.addControlPoint(clicked)

        #expect(outcome == .inserted(index: 2))
        #expect(curve.controlPointsMM.count == 6)
        #expect(curve.controlPointsMM[2].isApproximatelyEqual(to: clicked))
        // L'ordine dei punti preesistenti non cambia.
        #expect(curve.controlPointsMM[1].isApproximatelyEqual(to: Vec3(-18, -6, 5)))
        #expect(curve.controlPointsMM[3].isApproximatelyEqual(to: Vec3(0, -14, 5)))
    }

    @Test("Il cappio non si forma: il confronto è con l'accodamento cieco")
    func insertionDoesNotCreateALoop() {
        let original = makeArch()
        let clicked = Vec3(-9.5, -11.0, 5)

        var inserted = original
        inserted.addControlPoint(clicked)

        // L'alternativa sbagliata, scritta per esteso: accodare sempre. La curva arriva ai molari
        // di sinistra, torna indietro fin qui e riparte.
        var appended = original
        appended.controlPointsMM.append(clicked)

        // Il confronto è fra le due, non con una soglia inventata: è l'accodamento a produrre il
        // cappio. Sull'arcata di prova sono 118 mm contro 75, cioè il tragitto in più per andare
        // dai molari di sinistra fino al punto nuovo e tornare.
        #expect(
            appended.lengthMM > inserted.lengthMM * 1.4,
            "inserito \(inserted.lengthMM) mm, accodato \(appended.lengthMM) mm")

        // Rispetto all'originale la lunghezza cambia di poco, e può anche **diminuire**: una
        // Catmull-Rom su pochi punti sborda oltre i vertici, e un punto in più la addomestica.
        // Pretendere che cresca sempre sarebbe un'asserzione falsa.
        #expect(abs(inserted.lengthMM - original.lengthMM) < original.lengthMM * 0.2)
    }

    @Test("Un punto oltre un estremo prolunga la curva da quel lato")
    func extendsBeyondTheEnds() {
        var curve = makeArch()

        // Oltre l'ultimo punto, in direzione posteriore: un molare più indietro.
        let outcome = curve.addControlPoint(Vec3(27, 20, 5))
        #expect(outcome == .appended(index: 5))
        #expect(curve.controlPointsMM.count == 6)
        #expect(curve.controlPointsMM[5].isApproximatelyEqual(to: Vec3(27, 20, 5)))

        // Oltre il primo, dall'altro lato: va in testa, non in coda, altrimenti la curva
        // tornerebbe indietro da un capo all'altro dell'arcata.
        let other = curve.addControlPoint(Vec3(-27, 20, 5))
        #expect(other == .appended(index: 0))
        #expect(curve.controlPointsMM[0].isApproximatelyEqual(to: Vec3(-27, 20, 5)))
        #expect(curve.controlPointsMM.count == 7)
    }

    @Test("I primi due punti si accodano, perché non c'è ancora un segmento")
    func firstTwoPointsAppend() {
        var curve = ArchCurve(controlPointsMM: [])

        let first = curve.addControlPoint(Vec3(0, 0, 0))
        let second = curve.addControlPoint(Vec3(10, 0, 0))
        #expect(first == .appended(index: 0))
        #expect(second == .appended(index: 1))
        #expect(curve.controlPointsMM.count == 2)
        #expect(curve.isUsable)
    }

    @Test("Un punto non finito non altera la curva")
    func rejectsNonFinitePoints() {
        var curve = makeArch()
        let before = curve.controlPointsMM
        curve.addControlPoint(Vec3(.nan, 0, 0))
        curve.addControlPoint(Vec3(0, .infinity, 0))
        #expect(curve.controlPointsMM == before)
    }

    @Test("Il punto più vicino sulla poligonale distingue tratto e vertice")
    func closestPointDistinguishesSegmentFromVertex() {
        let curve = ArchCurve(controlPointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0)])

        guard let inside = curve.closestPointOnControlPolyline(to: Vec3(5, 3, 0)) else {
            Issue.record("nessun punto più vicino")
            return
        }
        #expect(inside.segment == 0)
        #expect(abs(inside.t - 0.5) < 1e-12)
        #expect(abs(inside.distanceMM - 3) < 1e-12)

        // Oltre i capi il parametro si blocca sul vertice, ed è il segnale che il gesto è un
        // prolungamento e non un inserimento.
        guard let before = curve.closestPointOnControlPolyline(to: Vec3(-4, 1, 0)),
              let after = curve.closestPointOnControlPolyline(to: Vec3(14, 1, 0))
        else {
            Issue.record("nessun punto più vicino")
            return
        }
        #expect(before.t == 0)
        #expect(after.t == 1)
    }

    @Test("Su un'arcata a U un clic dietro l'ultimo molare non finisce sul lato opposto")
    func clickBehindLastMolarDoesNotJumpAcross() {
        let curve = makeArch()
        // È il caso che ha smascherato il difetto. Da (27, 20) la proiezione sul segmento del
        // lato **opposto** dell'arcata, fra (−25, 10) e (−18, −6), cade a t ≈ 0,67: interna, e
        // quindi vincente se il criterio fosse l'interiorità. Dista però una cinquantina di
        // millimetri, mentre l'ultimo vertice ne dista dieci.
        guard let closest = curve.closestPointOnControlPolyline(to: Vec3(27, 20, 5)) else {
            Issue.record("nessun punto più vicino")
            return
        }
        #expect(closest.segment == 3, "segmento \(closest.segment)")
        #expect(closest.t == 1)
        #expect(closest.distanceMM < 11)
    }

    @Test("Un segmento degenere non manda in errore il calcolo")
    func degenerateSegmentIsHandled() {
        // Due punti coincidenti: succede con un doppio clic nello stesso posto.
        let curve = ArchCurve(controlPointsMM: [
            Vec3(0, 0, 0), Vec3(0, 0, 0), Vec3(10, 0, 0),
        ])
        guard let closest = curve.closestPointOnControlPolyline(to: Vec3(5, 2, 0)) else {
            Issue.record("nessun punto più vicino")
            return
        }
        #expect(closest.distanceMM.isFinite)
        #expect(closest.t >= 0 && closest.t <= 1)
    }

    // MARK: Spostamento e rimozione

    @Test("Spostare e rimuovere per indice, e ignorare gli indici fuori intervallo")
    func moveAndRemove() {
        var curve = makeArch()

        curve.moveControlPoint(at: 2, to: Vec3(0, -18, 5))
        #expect(curve.controlPointsMM[2].isApproximatelyEqual(to: Vec3(0, -18, 5)))

        curve.moveControlPoint(at: 99, to: Vec3(1, 1, 1))
        curve.moveControlPoint(at: -1, to: Vec3(1, 1, 1))
        #expect(curve.controlPointsMM.count == 5)

        let removed = curve.removeControlPoint(at: 0)
        #expect(removed)
        #expect(curve.controlPointsMM.count == 4)
        #expect(curve.controlPointsMM[0].isApproximatelyEqual(to: Vec3(-18, -6, 5)))

        let missing = curve.removeControlPoint(at: 99)
        let negative = curve.removeControlPoint(at: -1)
        #expect(!missing)
        #expect(!negative)
    }

    @Test("Scendendo a un solo punto la curva non è più utilizzabile, e non va in errore")
    func degradesGracefully() {
        var curve = ArchCurve(controlPointsMM: [Vec3(0, 0, 0), Vec3(10, 0, 0)])
        #expect(curve.isUsable)
        curve.removeControlPoint(at: 1)
        #expect(!curve.isUsable)
        #expect(curve.lengthMM == 0)
        #expect(curve.resampled(count: 100).isEmpty)

        curve.removeAllControlPoints()
        #expect(curve.controlPointsMM.isEmpty)
        #expect(!curve.isUsable)
    }

    // MARK: Quota

    @Test("L'appiattimento porta tutti i punti alla stessa quota")
    func flattenLevelsThePoints() {
        var curve = ArchCurve(controlPointsMM: [
            Vec3(-20, 0, 3), Vec3(0, -10, 7), Vec3(20, 0, 11),
        ])
        #expect(abs((curve.averageVerticalMM ?? 0) - 7) < 1e-12)

        curve.flatten(toVerticalMM: 8)
        for point in curve.controlPointsMM {
            #expect(abs(point.z - 8) < 1e-12)
        }
        // Le componenti nel piano non si toccano: appiattire non è spostare.
        #expect(abs(curve.controlPointsMM[1].y + 10) < 1e-12)
        #expect(abs((curve.averageVerticalMM ?? 0) - 8) < 1e-12)
    }

    @Test("La quota media di una curva vuota non esiste")
    func averageVerticalOfEmptyCurve() {
        #expect(ArchCurve(controlPointsMM: []).averageVerticalMM == nil)
    }

    // MARK: Curva suggerita

    @Test("La curva suggerita nasce alla quota che le si passa")
    func suggestedArchSitsAtTheRequestedHeight() throws {
        let geometry = try VolumeGeometry(
            columnCount: 200, rowCount: 200, sliceCount: 200,
            columnSpacingMM: 0.3, rowSpacingMM: 0.3, sliceSpacingMM: 0.3,
            orientation: .standardAxial,
            originMM: Vec3(-30, -30, -30))

        // È la differenza che conta rispetto a `defaultArch(for:)`: quella nasce al centro del
        // volume, cioè a metà fra le due arcate, dove non c'è nessuna delle due.
        for height in [-12.0, 0.0, 14.5] {
            let curve = ArchCurve.suggested(
                for: geometry, atVerticalMM: height, arch: .mandibular)
            #expect(curve.isUsable)
            for point in curve.controlPointsMM {
                #expect(abs(point.z - height) < 1e-12)
            }
        }
    }

    @Test("Le due arcate suggerite hanno ampiezza diversa")
    func suggestedArchesDifferByArch() throws {
        let geometry = try VolumeGeometry(
            columnCount: 200, rowCount: 200, sliceCount: 200,
            columnSpacingMM: 0.3, rowSpacingMM: 0.3, sliceSpacingMM: 0.3,
            orientation: .standardAxial,
            originMM: Vec3(-30, -30, -30))

        let upper = ArchCurve.suggested(for: geometry, atVerticalMM: 10, arch: .maxillary)
        let lower = ArchCurve.suggested(for: geometry, atVerticalMM: -10, arch: .mandibular)

        // La superiore circoscrive l'inferiore: è la sovrapposizione normale delle arcate.
        #expect(upper.lengthMM > lower.lengthMM)
        #expect(upper.controlPointsMM.count == lower.controlPointsMM.count)
    }

    @Test("Il numero di punti suggeriti ha un minimo")
    func suggestedArchHasAMinimumOfPoints() throws {
        let geometry = try VolumeGeometry(
            columnCount: 100, rowCount: 100, sliceCount: 100,
            columnSpacingMM: 0.4, rowSpacingMM: 0.4, sliceSpacingMM: 0.4,
            orientation: .standardAxial,
            originMM: Vec3(-20, -20, -20))
        let curve = ArchCurve.suggested(
            for: geometry, atVerticalMM: 0, arch: .mandibular, pointCount: 1)
        #expect(curve.controlPointsMM.count >= 3)
    }

    // MARK: Identità delle arcate

    @Test("Le due arcate hanno nomi propri")
    func archIdentity() {
        #expect(DentalArch.allCases.count == 2)
        for arch in DentalArch.allCases {
            #expect(!arch.localizedName.isEmpty)
            #expect(!arch.shortName.isEmpty)
            #expect(arch.id == arch.rawValue)
        }
        #expect(DentalArch.maxillary != DentalArch.mandibular)
    }
}
