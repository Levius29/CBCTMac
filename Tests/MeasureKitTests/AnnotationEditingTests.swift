import DICOMCore
import Testing

@testable import MeasureKit

// Correggere un'annotazione già posata.
//
// La prova che conta di più non è che una maniglia si sposti — quello è quasi tautologico — ma
// che si sposti **conservando ciò che definisce la forma**: un'ellisse deve restare con gli assi
// perpendicolari, una sfera deve restare sferica, e trascinare il centro di una ROI deve muovere
// la figura intera invece di stirarla.

@Suite("Correzione delle annotazioni")
struct AnnotationEditingTests {

    // MARK: Vertici semplici

    @Test("Le misure a vertici spostano il punto che si afferra e nessun altro")
    func plainVerticesMoveAlone() {
        let distance = Annotation.distance(
            DistanceMeasurement(startMM: Vec3(0, 0, 0), endMM: Vec3(10, 0, 0)))
        let moved = distance.movingHandle(at: 1, toMM: Vec3(10, 5, 0))
        #expect(moved.handlesMM == [Vec3(0, 0, 0), Vec3(10, 5, 0)])

        let angle = Annotation.angle(
            AngleMeasurement(
                vertexMM: .zero, firstArmMM: Vec3(10, 0, 0), secondArmMM: Vec3(0, 10, 0)))
        // L'ordine di `handlesMM` mette il **vertice in mezzo**: chi lo desse per primo
        // sposterebbe un braccio credendo di spostare il vertice.
        let bent = angle.movingHandle(at: 1, toMM: Vec3(1, 1, 0))
        guard case .angle(let corrected) = bent else {
            Issue.record("tipo cambiato"); return
        }
        #expect(corrected.vertexMM == Vec3(1, 1, 0))
        #expect(corrected.firstArmMM == Vec3(10, 0, 0))
    }

    @Test("La spezzata e la mano libera spostano il vertice all'indice giusto")
    func polylineMovesTheRightVertex() {
        let points = [Vec3(0, 0, 0), Vec3(5, 0, 0), Vec3(10, 0, 0)]
        let polyline = Annotation.polyline(PolylineMeasurement(pointsMM: points, isClosed: false))
        let moved = polyline.movingHandle(at: 1, toMM: Vec3(5, 3, 0))
        #expect(moved.handlesMM == [Vec3(0, 0, 0), Vec3(5, 3, 0), Vec3(10, 0, 0)])

        let freehand = Annotation.freehand(FreehandPath(pointsMM: points))
        #expect(freehand.movingHandle(at: 2, toMM: Vec3(9, 1, 0)).handlesMM[2] == Vec3(9, 1, 0))
    }

    @Test("La freccia distingue punta e coda, nell'ordine che dichiara")
    func arrowKeepsTipFirst() {
        let arrow = Annotation.arrow(ArrowNote(tipMM: Vec3(1, 0, 0), tailMM: Vec3(5, 0, 0)))
        guard case .arrow(let moved) = arrow.movingHandle(at: 0, toMM: Vec3(2, 2, 0)) else {
            Issue.record("tipo cambiato"); return
        }
        #expect(moved.tipMM == Vec3(2, 2, 0))
        #expect(moved.tailMM == Vec3(5, 0, 0))
    }

    // MARK: Forme con invarianti

    @Test("Il centro di un'ellisse trascina la figura intera, non la deforma")
    func ellipseCentreTranslates() {
        let roi = EllipseROI(
            centerMM: Vec3(0, 0, 0),
            semiAxisAMM: Vec3(4, 0, 0),
            semiAxisBMM: Vec3(0, 3, 0),
            thicknessMM: 1)
        let annotation = Annotation.ellipseROI(roi)

        guard case .ellipseROI(let moved) = annotation.movingHandle(at: 0, toMM: Vec3(7, 2, 0))
        else { Issue.record("tipo cambiato"); return }

        #expect(moved.centerMM == Vec3(7, 2, 0))
        // I semiassi sono **vettori**: una traslazione non li tocca. Se li toccasse, l'ellisse si
        // gonfierebbe di quanto la si è spostata.
        #expect(moved.semiAxisAMM == roi.semiAxisAMM)
        #expect(moved.semiAxisBMM == roi.semiAxisBMM)
    }

    @Test("Gli estremi dei semiassi scorrono lungo il proprio asse e restano perpendicolari")
    func ellipseAxesStayPerpendicular() {
        // È l'invariante che rende sensata l'area: due semiassi non perpendicolari descrivono un
        // parallelogramma, non un'ellisse, e l'area calcolata non sarebbe di ciò che si vede.
        let annotation = Annotation.ellipseROI(
            EllipseROI(
                centerMM: .zero,
                semiAxisAMM: Vec3(4, 0, 0),
                semiAxisBMM: Vec3(0, 3, 0),
                thicknessMM: 1))

        // Si trascina l'estremo del primo semiasse **fuori asse**: deve prendere solo la
        // componente lungo l'asse.
        guard case .ellipseROI(let moved) = annotation.movingHandle(at: 1, toMM: Vec3(6, 9, 0))
        else { Issue.record("tipo cambiato"); return }

        #expect(moved.semiAxisAMM == Vec3(6, 0, 0))
        #expect(moved.semiAxisBMM == Vec3(0, 3, 0))
        #expect(abs(moved.semiAxisAMM.dot(moved.semiAxisBMM)) < 1e-12)
    }

    @Test("La seconda maniglia di una sfera ne cambia il raggio, non la sposta")
    func sphereHandleSetsTheRadius() {
        let annotation = Annotation.sphereROI(SphereROI(centerMM: Vec3(1, 1, 1), radiusMM: 2))

        // Un punto a distanza 5 dal centro, in una direzione qualsiasi: il raggio deve diventare
        // 5 e il centro restare dov'è. Se il codice assegnasse una posizione invece di una
        // distanza, la sfera si sposterebbe.
        guard case .sphereROI(let moved) = annotation.movingHandle(at: 1, toMM: Vec3(1, 1, 6))
        else { Issue.record("tipo cambiato"); return }

        #expect(moved.centerMM == Vec3(1, 1, 1))
        #expect(abs(moved.radiusMM - 5) < 1e-9)
    }

    @Test("Il centro di una sfera la sposta senza cambiarne il raggio")
    func sphereCentreTranslates() {
        let annotation = Annotation.sphereROI(SphereROI(centerMM: .zero, radiusMM: 3))
        guard case .sphereROI(let moved) = annotation.movingHandle(at: 0, toMM: Vec3(4, 0, 0))
        else { Issue.record("tipo cambiato"); return }
        #expect(moved.centerMM == Vec3(4, 0, 0))
        #expect(moved.radiusMM == 3)
    }

    // MARK: Robustezza

    @Test("Un indice fuori intervallo lascia tutto com'era")
    func outOfRangeIndexIsInert() {
        let annotation = Annotation.distance(
            DistanceMeasurement(startMM: .zero, endMM: Vec3(1, 0, 0)))
        #expect(annotation.movingHandle(at: 5, toMM: Vec3(9, 9, 9)) == annotation)
        #expect(annotation.movingHandle(at: -1, toMM: Vec3(9, 9, 9)) == annotation)
    }

    @Test("Ogni tipo espone tante maniglie quante ne sa spostare")
    func everyHandleIsMovable() {
        // Prova di copertura: se un tipo dichiara maniglie e il ramo che le sposta ne ignora
        // qualcuna, quella maniglia si disegna e non risponde — che è il difetto originale
        // ridotto a un solo punto invece che a tutti.
        let samples: [Annotation] = [
            .distance(DistanceMeasurement(startMM: .zero, endMM: Vec3(1, 0, 0))),
            .angle(AngleMeasurement(vertexMM: .zero, firstArmMM: Vec3(1, 0, 0), secondArmMM: Vec3(0, 1, 0))),
            .ellipseROI(EllipseROI(centerMM: .zero, semiAxisAMM: Vec3(2, 0, 0), semiAxisBMM: Vec3(0, 1, 0), thicknessMM: 1)),
            .polygonROI(PolygonROI(verticesMM: [.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)])),
            .sphereROI(SphereROI(centerMM: .zero, radiusMM: 2)),
            .profileLine(ProfileLine(startMM: .zero, endMM: Vec3(3, 0, 0))),
            .text(TextNote(anchorMM: .zero, text: "x")),
            .arrow(ArrowNote(tipMM: .zero, tailMM: Vec3(2, 0, 0))),
            .freehand(FreehandPath(pointsMM: [.zero, Vec3(1, 0, 0), Vec3(2, 0, 0)])),
            .polyline(PolylineMeasurement(pointsMM: [.zero, Vec3(1, 0, 0)], isClosed: false)),
            .lineAngle(LineAngleMeasurement(
                firstStartMM: .zero, firstEndMM: Vec3(1, 0, 0),
                secondStartMM: Vec3(0, 1, 0), secondEndMM: Vec3(1, 1, 0))),
        ]

        // Tre direzioni e non una: una maniglia può legittimamente ignorare uno spostamento
        // **fuori dal proprio piano** — l'estremo del semiasse di un'ellisse scorre lungo
        // l'asse, e spingerlo in verticale non ne cambia la lunghezza. L'affermazione giusta è
        // che ogni maniglia risponda a *qualche* trascinamento, non a uno in particolare.
        let directions = [Vec3(2.5, 0, 0), Vec3(0, 2.5, 0), Vec3(0, 0, 2.5)]

        for annotation in samples {
            for index in annotation.handlesMM.indices {
                let responds = directions.contains { direction in
                    annotation.movingHandle(
                        at: index, toMM: annotation.handlesMM[index] + direction) != annotation
                }
                #expect(
                    responds,
                    "\(annotation.kindName): la maniglia \(index) non risponde a nulla")
            }
        }
    }

    // MARK: Ricerca della maniglia

    @Test("Si trova la maniglia più vicina, e solo entro la tolleranza")
    func nearestHandleRespectsTolerance() {
        let annotation = Annotation.polyline(
            PolylineMeasurement(
                pointsMM: [.zero, Vec3(10, 0, 0), Vec3(20, 0, 0)], isClosed: false))

        #expect(annotation.nearestHandle(to: Vec3(11, 0, 0), toleranceMM: 2)?.index == 1)
        #expect(annotation.nearestHandle(to: Vec3(19, 0, 0), toleranceMM: 2)?.index == 2)
        #expect(annotation.nearestHandle(to: Vec3(5, 0, 0), toleranceMM: 2) == nil)
    }

    @Test("Fra due maniglie entrambe a portata si sceglie la più vicina")
    func nearestHandlePicksTheClosest() {
        // Su una misura corta due maniglie stanno entrambe nella tolleranza: restituire la prima
        // che rientra renderebbe la seconda inafferrabile.
        let annotation = Annotation.distance(
            DistanceMeasurement(startMM: .zero, endMM: Vec3(3, 0, 0)))
        #expect(annotation.nearestHandle(to: Vec3(2.6, 0, 0), toleranceMM: 4)?.index == 1)
        #expect(annotation.nearestHandle(to: Vec3(0.4, 0, 0), toleranceMM: 4)?.index == 0)
    }
}
