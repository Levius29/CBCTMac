import DICOMCore
import Testing

@testable import SegmentKit

// Il riquadro di ritaglio proiettato su una vista.
//
// La proprietà che tutte queste prove difendono è una sola: **trascinare un lato deve spostare
// la faccia che sta sotto quel lato**, in tutte e tre le viste e con qualunque verso degli assi.
// È il punto in cui una svista non si vede leggendo il codice e si vede subito all'uso, perché il
// riquadro si allarga dalla parte sbagliata.

@Suite("Riquadro di ritaglio")
struct CropBoxGeometryTests {

    /// Vista assiale: destra dello schermo = +x, basso dello schermo = +y.
    private let axial = CropBoxFrame(
        topLeftMM: Vec3(-50, -60, 0),
        rightMM: Vec3(1, 0, 0),
        downMM: Vec3(0, 1, 0),
        widthMM: 100,
        heightMM: 120)

    /// Vista coronale: destra = +x, basso = **−z**, che è il caso col verso invertito.
    private let coronal = CropBoxFrame(
        topLeftMM: Vec3(-50, 0, 60),
        rightMM: Vec3(1, 0, 0),
        downMM: Vec3(0, 0, -1),
        widthMM: 100,
        heightMM: 120)

    private let box = BoxMM(minMM: Vec3(-20, -30, -15), maxMM: Vec3(30, 10, 25))

    // MARK: Quale faccia comanda quale lato

    @Test("Sull'assiale i lati comandano le facce nel verso naturale")
    func axialEdgesMapToFacesDirectly() {
        #expect(CropBoxGeometry.face(for: .left, in: axial) == .minX)
        #expect(CropBoxGeometry.face(for: .right, in: axial) == .maxX)
        #expect(CropBoxGeometry.face(for: .top, in: axial) == .minY)
        #expect(CropBoxGeometry.face(for: .bottom, in: axial) == .maxY)
    }

    @Test("Con un asse invertito il lato in alto comanda la faccia di massimo")
    func invertedAxisFlipsTheFaces() {
        // Sul coronale il basso dello schermo va verso i piedi, cioè z decrescente: il lato
        // **alto** è quindi la faccia di z massimo. Scrivere la corrispondenza a mano è la svista
        // che fa allargare il riquadro dalla parte opposta a dove si tira.
        #expect(CropBoxGeometry.face(for: .top, in: coronal) == .maxZ)
        #expect(CropBoxGeometry.face(for: .bottom, in: coronal) == .minZ)
        #expect(CropBoxGeometry.face(for: .left, in: coronal) == .minX)
        #expect(CropBoxGeometry.face(for: .right, in: coronal) == .maxX)
    }

    @Test("L'asse dominante si sceglie dal modulo maggiore, non dalla prima componente non nulla")
    func axisIgnoresRoundingNoise() {
        // Una matrice DICOM reale non dà mai 0 e 1 esatti. Prendere la prima componente non
        // trascurabile sceglierebbe l'asse sbagliato appena il rumore precede quello vero.
        let noisy = Vec3(-0.0004, 0.9999, 0.0011)
        let axis = CropBoxGeometry.axis(of: noisy)
        #expect(axis.component == 1)
        #expect(axis.sign == 1)

        let negative = CropBoxGeometry.axis(of: Vec3(0.0002, -0.0007, -0.99998))
        #expect(negative.component == 2)
        #expect(negative.sign == -1)
    }

    // MARK: Proiezione

    @Test("Il riquadro cade dove dicono le proporzioni della vista")
    func rectFollowsTheViewProportions() {
        let rect = CropBoxGeometry.rect(of: box, in: axial, width: 200, height: 240)

        // x da −20 a 30 su una finestra da −50 larga 100 mm, resa su 200 punti: 60 e 160.
        #expect(abs(rect.minX - 60) < 1e-9)
        #expect(abs(rect.maxX - 160) < 1e-9)
        // y da −30 a 10 su una finestra da −60 alta 120 mm, resa su 240 punti: 60 e 140.
        #expect(abs(rect.minY - 60) < 1e-9)
        #expect(abs(rect.maxY - 140) < 1e-9)
    }

    @Test("Con l'asse invertito il riquadro resta ordinato: il minimo a sinistra e in alto")
    func rectStaysOrderedWithAnInvertedAxis() {
        let rect = CropBoxGeometry.rect(of: box, in: coronal, width: 200, height: 240)
        #expect(rect.minX < rect.maxX)
        #expect(rect.minY < rect.maxY)
        // z da −15 a 25 con l'alto a +60 e 120 mm d'altezza su 240 punti: 25 mm sta a 70,
        // −15 mm sta a 150. Il **massimo** in millimetri è il **minimo** sullo schermo.
        #expect(abs(rect.minY - 70) < 1e-9)
        #expect(abs(rect.maxY - 150) < 1e-9)
    }

    // MARK: Andata e ritorno

    @Test("Trascinare un lato dove già sta non lo muove")
    func draggingAnEdgeToItsOwnPositionIsIdentity() {
        // È la prova che lega proiezione e conversione inversa: se non fossero l'una l'inversa
        // dell'altra, afferrare un lato lo farebbe **saltare** al primo movimento, che è il
        // difetto che si nota per primo e si spiega per ultimo.
        for frame in [axial, coronal] {
            let width = 200.0, height = 240.0
            let rect = CropBoxGeometry.rect(of: box, in: frame, width: width, height: height)

            for edge in CropBoxEdge.allCases {
                let (x, y): (Double, Double)
                switch edge {
                case .left: (x, y) = (rect.minX, rect.midY)
                case .right: (x, y) = (rect.maxX, rect.midY)
                case .top: (x, y) = (rect.midX, rect.minY)
                case .bottom: (x, y) = (rect.midX, rect.maxY)
                }

                let mm = CropBoxGeometry.millimetres(
                    atX: x, y: y, for: edge, in: frame, width: width, height: height)
                let face = CropBoxGeometry.face(for: edge, in: frame)
                let expected = expectedMM(of: box, face: face)
                #expect(abs(mm - expected) < 1e-9, "\(edge): \(mm) invece di \(expected)")
            }
        }
    }

    private func expectedMM(of box: BoxMM, face: BoxFace) -> Double {
        switch face {
        case .minX: return box.minMM.x
        case .maxX: return box.maxMM.x
        case .minY: return box.minMM.y
        case .maxY: return box.maxMM.y
        case .minZ: return box.minMM.z
        case .maxZ: return box.maxMM.z
        }
    }

    // MARK: Presa

    @Test("Si afferra il lato più vicino, non il primo dell'elenco")
    func grabPicksTheNearestEdge() {
        // Su un riquadro stretto due lati opposti stanno entrambi a portata. Prendere il primo
        // che rientra nella soglia significherebbe non poter mai afferrare l'altro.
        let narrow = CropBoxRect(minX: 100, minY: 20, maxX: 108, maxY: 200)
        #expect(CropBoxGeometry.edge(nearX: 107, y: 100, of: narrow, slop: 10) == .right)
        #expect(CropBoxGeometry.edge(nearX: 101, y: 100, of: narrow, slop: 10) == .left)
    }

    @Test("Fuori dalla distanza di presa non si afferra nulla")
    func grabRespectsTheSlop() {
        let rect = CropBoxRect(minX: 60, minY: 60, maxX: 160, maxY: 140)
        #expect(CropBoxGeometry.edge(nearX: 110, y: 100, of: rect, slop: 10) == nil)
        #expect(CropBoxGeometry.edge(nearX: 60, y: 100, of: rect, slop: 10) == .left)
    }

    @Test("Le maniglie stanno al centro dei quattro lati")
    func handlesSitAtTheEdgeCentres() {
        let rect = CropBoxRect(minX: 60, minY: 60, maxX: 160, maxY: 140)
        let handles = CropBoxGeometry.handles(of: rect)
        #expect(handles.count == 4)
        #expect(handles.contains { abs($0.x - 110) < 1e-9 && abs($0.y - 60) < 1e-9 })
        #expect(handles.contains { abs($0.x - 60) < 1e-9 && abs($0.y - 100) < 1e-9 })
    }
}
