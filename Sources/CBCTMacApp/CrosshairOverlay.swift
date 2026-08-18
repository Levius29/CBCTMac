import AppKit
import DICOMCore
import SwiftUI
import VolumeKit

// Il mirino: due tracce colorate, con le maniglie per ruotarle.
//
// # Che cosa è cambiato, e perché
//
// Prima erano una verticale e un'orizzontale a metà riquadro, disegnate lì per definizione. È
// corretto **solo** finché i tre piani restano ortogonali agli assi della macchina: al primo
// taglio obliquo la croce e i piani che dovrebbe rappresentare divergono, e l'immagine mente su
// dove sta tagliando. Ora ogni linea è l'intersezione vera fra il piano che rappresenta e quello
// del riquadro, calcolata da `CrosshairGeometry` — provata, e provata soprattutto sugli obliqui.
//
// # Il colore è la stessa informazione detta tre volte
//
// Una traccia porta il colore del **piano che rappresenta**, non del riquadro che la ospita.
// Nell'assiale la linea gialla è il sagittale, la verde è il coronale, e il bordo giallo in cima
// al riquadro sagittale è lo stesso giallo. Tre cose diverse — un bordo, una linea, un piano nel
// 3D — legate da un segno solo, così non c'è nulla da leggere per sapere dove si sta guardando.
//
// # Perché le maniglie e non un modificatore
//
// Inclinare il taglio si poteva già fare, con ⇧ + trascinamento. Funzionava e non si vedeva:
// niente sullo schermo diceva che il gesto esistesse. Una maniglia lo dice da sé, e in più sta
// lontana dal perno, dove l'angolo è una funzione ben condizionata della posizione del dito.

struct CrosshairOverlay: View {

    let model: AppModel
    let slot: ViewportSlot

    /// Che cosa si sta trascinando. Deciso alla pressione e non riletto: cercare la presa a ogni
    /// notifica farebbe saltare il gesto da una linea all'altra passandoci sopra.
    @State private var drag: ActiveDrag?

    private struct ActiveDrag {
        let represented: ViewportSlot
        let grip: CrosshairGrip
        /// Posizione precedente, per gli spostamenti incrementali.
        var lastPoint: PixelPoint
        /// Se ruotare il solo piano afferrato invece di entrambi. Fissato alla pressione: se il
        /// modificatore si rileggesse durante il gesto, alzare ⌥ a metà trascinamento cambierebbe
        /// il significato di ciò che si è già fatto.
        let isIndependent: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let items = traces(in: size)

            ZStack {
                Canvas { context, _ in
                    for item in items { draw(item, in: &context) }
                }
                .allowsHitTesting(false)

                // La zona sensibile è **solo** la sagoma delle linee e delle maniglie. Un
                // rettangolo pieno, che sarebbe la via breve, intercetterebbe ogni clic del
                // riquadro e lascerebbe l'immagine sotto senza navigazione.
                Color.clear
                    .contentShape(HitShape(traces: items))
                    .gesture(dragGesture(in: size, traces: items))
            }
        }
    }

    // MARK: Le tracce

    private struct TraceItem: Sendable {
        let represented: ViewportSlot
        let trace: CrosshairTrace
    }

    /// Piano del riquadro con le proporzioni della finestra, che è il riferimento di ogni
    /// conversione qui dentro.
    private func viewPlane(in size: CGSize) -> MPRPlane? {
        guard let plane = model.planes[slot], size.width > 1, size.height > 1 else { return nil }
        return plane.matchingAspect(pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func traces(in size: CGSize) -> [TraceItem] {
        guard let view = viewPlane(in: size), slot.anatomicalPlane != nil else { return [] }
        return ViewportSlot.allCases.compactMap { other -> TraceItem? in
            guard other != slot, other.anatomicalPlane != nil,
                let plane = model.planes[other],
                let trace = CrosshairGeometry.trace(
                    of: plane, in: view, through: model.crosshairMM,
                    pixelWidth: Int(size.width), pixelHeight: Int(size.height))
            else { return nil }
            return TraceItem(represented: other, trace: trace)
        }
    }

    // MARK: Disegno

    private func draw(_ item: TraceItem, in context: inout GraphicsContext) {
        let trace = item.trace
        let color = item.represented.accentColor

        context.stroke(
            Self.brokenLine(of: trace), with: .color(color.opacity(0.85)), lineWidth: 1)

        for handle in [trace.startHandle, trace.endHandle].compactMap({ $0 }) {
            let isActive = drag?.represented == item.represented
            let radius: CGFloat = isActive ? 6 : 5
            let rect = CGRect(
                x: handle.x - radius, y: handle.y - radius,
                width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.9)), lineWidth: 1)
        }
    }

    /// La linea spezzata all'incrocio: due tratti che si fermano prima del perno.
    ///
    /// Il vuoto centrale non è un vezzo. Senza, le due linee coprirebbero esattamente il voxel
    /// che si sta puntando, che è l'unico che interessa vedere.
    ///
    /// La usano **sia** il disegno sia la zona sensibile ai clic, e devono essere la stessa forma.
    /// Con una zona sensibile piena il centro del mirino diventerebbe una macchia morta: assorbe
    /// il clic perché la sagoma lo copre, e non fa nulla perché lì `grip` di proposito non
    /// risponde. Il punto più cliccato del riquadro smetterebbe di funzionare.
    private static func brokenLine(of trace: CrosshairTrace) -> Path {
        var path = Path()
        appendSegment(&path, from: trace.start, towards: trace.pivot)
        appendSegment(&path, from: trace.end, towards: trace.pivot)
        return path
    }

    private static func appendSegment(
        _ path: inout Path, from end: PixelPoint, towards pivot: PixelPoint
    ) {
        let gap = CrosshairGeometry.centreGapPixels
        let length = end.distance(to: pivot)
        guard length > gap else { return }
        let t = (length - gap) / length
        path.move(to: CGPoint(x: end.x, y: end.y))
        path.addLine(
            to: CGPoint(
                x: end.x + (pivot.x - end.x) * t,
                y: end.y + (pivot.y - end.y) * t))
    }

    /// Sagoma sensibile ai clic: le stesse linee spezzate, ingrossate, più le maniglie.
    ///
    /// Lo spessore è il doppio della tolleranza di presa di `grip`, così la sagoma e il criterio
    /// di presa concordano: dentro la sagoma `grip` risponde sempre, fuori non serve chiederglielo.
    private struct HitShape: Shape {
        let traces: [TraceItem]

        func path(in rect: CGRect) -> Path {
            var lines = Path()
            var result = Path()
            for item in traces {
                lines.addPath(CrosshairOverlay.brokenLine(of: item.trace))
                let handles = [item.trace.startHandle, item.trace.endHandle]
                for handle in handles.compactMap({ $0 }) {
                    result.addEllipse(
                        in: CGRect(
                            x: handle.x - handleRadius, y: handle.y - handleRadius,
                            width: handleRadius * 2, height: handleRadius * 2))
                }
            }
            result.addPath(lines.strokedPath(StrokeStyle(lineWidth: lineSlop * 2)))
            return result
        }

        private var lineSlop: CGFloat { 9 }
        private var handleRadius: CGFloat { 12 }
    }

    // MARK: Gesto

    private func dragGesture(in size: CGSize, traces: [TraceItem]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = PixelPoint(x: value.location.x, y: value.location.y)

                if drag == nil {
                    model.focusedSlot = slot
                    let start = PixelPoint(
                        x: value.startLocation.x, y: value.startLocation.y)
                    guard let found = grip(at: start, among: traces) else { return }
                    // Il modificatore si legge da `NSEvent`: un `DragGesture` di SwiftUI non lo
                    // riporta, ed è la via diretta su macOS.
                    drag = ActiveDrag(
                        represented: found.represented,
                        grip: found.grip,
                        lastPoint: start,
                        isIndependent: NSEvent.modifierFlags.contains(.option))
                }

                guard var active = drag,
                    let item = traces.first(where: { $0.represented == active.represented })
                else { return }

                apply(active, item: item, to: point, size: size)
                active.lastPoint = point
                drag = active
            }
            .onEnded { _ in drag = nil }
    }

    /// Presa più vicina fra tutte le tracce.
    ///
    /// Si sceglie la più vicina e non la prima che risponde: vicino all'incrocio le due linee sono
    /// entrambe a portata, e prendere la prima dell'elenco significherebbe afferrare sempre la
    /// stessa qualunque cosa si stia indicando.
    private func grip(at point: PixelPoint, among traces: [TraceItem])
        -> (represented: ViewportSlot, grip: CrosshairGrip)?
    {
        var best: (ViewportSlot, CrosshairGrip, Double)?
        for item in traces {
            guard let grip = item.trace.grip(at: point) else { continue }
            let distance: Double
            switch grip {
            case .handle(let isStart):
                let handle = isStart ? item.trace.startHandle : item.trace.endHandle
                distance = handle.map { point.distance(to: $0) } ?? .greatestFiniteMagnitude
            case .line:
                distance = item.trace.distance(from: point)
            }
            if best == nil || distance < best!.2 {
                best = (item.represented, grip, distance)
            }
        }
        guard let best else { return nil }
        return (best.0, best.1)
    }

    private func apply(_ active: ActiveDrag, item: TraceItem, to point: PixelPoint, size: CGSize) {
        switch active.grip {
        case .handle:
            guard let angle = item.trace.rotation(from: active.lastPoint, to: point) else {
                return
            }
            if active.isIndependent {
                model.rotatePlane(
                    active.represented, aboutAxis: item.trace.rotationAxisMM, byRadians: angle)
            } else {
                // Difetto: ruotano **entrambi** i piani perpendicolari a questo, dello stesso
                // angolo, quindi restano perpendicolari fra loro e le sezioni trasversali
                // continuano ad avere senso. ⌥ scollega la linea afferrata dall'altra, per chi
                // vuole due obliquità indipendenti.
                model.tiltPlanes(perpendicularTo: slot, byRadians: angle)
            }

        case .line:
            guard let view = viewPlane(in: size) else { return }
            let movement = item.trace.slide(
                from: active.lastPoint, to: point,
                in: view,
                pixelWidth: Int(size.width), pixelHeight: Int(size.height))
            model.moveCrosshair(to: model.crosshairMM + movement)
        }
    }
}
