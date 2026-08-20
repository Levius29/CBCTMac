import DICOMCore
import StudyKit
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

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let visibility = model.cutLineVisibility
            let items = visibility.drawsAnything ? traces(in: size) : []

            Canvas { context, _ in
                for item in items { draw(item, in: &context, opacity: visibility.opacity) }
            }
            // Solo disegno. I gesti passano dal percorso eventi di `InteractiveMetalView`, in
            // `ViewportGrid`: vedi lì il commento sul perché un `DragGesture` sopra un `MTKView`
            // non riceve nulla.
            .allowsHitTesting(false)
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

    /// - Parameter opacity: quanto si vedono adesso. Vedi `CutLineVisibility`: sbiadite mentre si
    ///   guarda, piene mentre si punta.
    private func draw(_ item: TraceItem, in context: inout GraphicsContext, opacity: Double) {
        let trace = item.trace
        let color = item.represented.accentColor

        context.stroke(
            Self.brokenLine(of: trace), with: .color(color.opacity(0.85 * opacity)), lineWidth: 1)

        // Le maniglie seguono la stessa opacità delle linee, e non una loro.
        //
        // Sbiadite si afferrano lo stesso — la tolleranza di presa non cambia — e appena si
        // preme il gesto le riporta piene. Tenerle accese sopra linee sbiadite darebbe sei
        // pallini luminosi in un'immagine che si stava sgombrando proprio da quelli.
        for handle in [trace.startHandle, trace.endHandle].compactMap({ $0 }) {
            let radius: CGFloat = 5
            let rect = CGRect(
                x: handle.x - radius, y: handle.y - radius,
                width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(color.opacity(opacity)))
            context.stroke(
                Path(ellipseIn: rect), with: .color(.white.opacity(0.9 * opacity)), lineWidth: 1)
        }
    }

    /// La linea spezzata all'incrocio: due tratti che si fermano prima del perno.
    ///
    /// Il vuoto centrale non è un vezzo. Senza, le due linee coprirebbero esattamente il voxel
    /// che si sta puntando, che è l'unico che interessa vedere.
    ///
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
}
