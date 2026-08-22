import DICOMCore
import SegmentKit
import SwiftUI
import VolumeKit

// Riquadro di ritaglio sovrapposto a una vista ortogonale.
//
// **Solo disegno.** Aveva un `contentShape` e un `DragGesture` e non ha mai funzionato: sotto c'è
// una `MTKView`, cioè una `NSView` vera, e AppKit consegna il mouse alla vista più profonda sotto
// il puntatore. Una sovraimpressione SwiftUI è uno *strato* della stessa vista ospite, non
// un'altra `NSView`, e il suo gesto non parte mai. Il riquadro si disegnava e non si poteva
// regolare — la quarta volta che lo stesso difetto si presenta in questo progetto.
//
// La regola, adesso applicata ovunque: **dentro un riquadro c'è un solo percorso di eventi**,
// quello di `InteractiveMetalView`. Il trascinamento dei lati vive in `ReformatSheet`, e la
// geometria che decide dove disegnare e che cosa si è afferrato è una sola — `CropBoxGeometry`,
// in SegmentKit, dove si verifica con `swift test` invece che a occhio.
//
// I tre riquadri descrivono **un solo parallelepipedo**: chi disegna qui legge `regionMM`,
// quindi muovendo un lato in una vista le altre due si aggiornano da sole. Tre rettangoli
// indipendenti sarebbero più semplici da scrivere e discorderebbero al primo trascinamento,
// perché descriverebbero tre scatole diverse.

struct CropBoxOverlay: View {

    /// Il riquadro da disegnare, in millimetri Patient.
    ///
    /// Un `BoxMM` e non un `ReformatPlan`: la sovraimpressione disegna **un riquadro**, e legarla
    /// al piano di un ricampionamento la rendeva inservibile per il riquadro di sola lettura, che
    /// un ricampionamento non lo fa. Vedi `ClipBox`.
    let regionMM: BoxMM
    let viewPlane: MPRPlane
    /// Lato attualmente afferrato, per evidenziarlo mentre lo si trascina.
    var grabbedEdge: CropBoxEdge?

    var body: some View {
        // `proxy` e non `geometry`: nello stesso ambito c'è già la `VolumeGeometry` del volume, e
        // due cose diverse con lo stesso nome in una vista che converte fra millimetri e pixel
        // sono un incidente in attesa.
        GeometryReader { proxy in
            let size = proxy.size
            // Il piano **adattato alle proporzioni reali**, come lo adatta il renderer prima di
            // disegnare. Senza, il riquadro comparirebbe spostato rispetto all'immagine su cui
            // dovrebbe stare, e sarebbe un errore di posizione che non si spiega guardando i
            // numeri: i millimetri sarebbero giusti e il disegno no.
            let frame = CropBoxOverlay.frame(of: viewPlane, size: size)
            let rect = CropBoxGeometry.rect(
                of: regionMM, in: frame,
                width: Double(size.width), height: Double(size.height))
            let box = CGRect(
                x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)

            ZStack {
                // Ciò che resta fuori è oscurato invece che nascosto: si continua a vedere dove
                // sta il ritaglio rispetto all'anatomia intera, che è l'informazione che serve
                // mentre lo si regola.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(box)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                Rectangle()
                    .path(in: box)
                    .stroke(.white.opacity(0.9), lineWidth: 1.5)

                ForEach(Array(CropBoxGeometry.handles(of: rect).enumerated()), id: \.offset) {
                    index, handle in
                    let isGrabbed = grabbedEdge == CropBoxOverlay.edgeOfHandle(index)
                    Circle()
                        .fill(isGrabbed ? Palette.accent : .white)
                        .frame(width: isGrabbed ? 11 : 7, height: isGrabbed ? 11 : 7)
                        .position(x: handle.x, y: handle.y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Il rettangolo di vista corrispondente a un piano, adattato alle proporzioni date.
    ///
    /// Statica e condivisa con chi riceve i clic: disegnare con un rettangolo e afferrare con un
    /// altro è il modo più diretto di ottenere maniglie che non stanno dove si vedono.
    static func frame(of plane: MPRPlane, size: CGSize) -> CropBoxFrame {
        let adjusted = plane.matchingAspect(
            pixelWidth: Int(max(size.width, 1)), pixelHeight: Int(max(size.height, 1)))
        return CropBoxFrame(
            topLeftMM: adjusted.topLeftMM,
            rightMM: adjusted.rightMM,
            downMM: adjusted.downMM,
            widthMM: adjusted.widthMM,
            heightMM: adjusted.heightMM)
    }

    /// L'ordine è quello di `CropBoxGeometry.handles`: alto, basso, sinistra, destra.
    private static func edgeOfHandle(_ index: Int) -> CropBoxEdge {
        switch index {
        case 0: return .top
        case 1: return .bottom
        case 2: return .left
        default: return .right
        }
    }
}
