import AppKit
import MetalKit

// `MTKView` che inoltra gli eventi del mouse.
//
// SwiftUI su macOS non espone la rotella, il trascinamento con il tasto destro né il pinch del
// trackpad su una vista qualunque. Invece di aggirarli con soluzioni tortuose si scende a
// `NSView`, che è il posto giusto per gli eventi.
//
// **Le coordinate sono in pixel della texture, con origine in alto a sinistra.** La conversione
// avviene qui, una volta sola, così chi riceve i callback ragiona nello stesso sistema in cui
// lavora lo shader. Due passaggi facili da sbagliare, entrambi concentrati in questo file:
// `isFlipped` per l'asse verticale, e il fattore di scala del display per i pixel.

final class InteractiveMetalView: MTKView {

    // MARK: Callback

    /// Rotella. Il valore è in "passi": positivo scorre in avanti lungo la normale.
    var onScroll: ((Double) -> Void)?
    /// Pinch del trackpad. Il valore è il fattore moltiplicativo.
    var onMagnify: ((Double) -> Void)?
    /// Trascinamento con il tasto sinistro: posizione corrente e spostamento, in pixel.
    var onDrag: ((CGPoint, CGSize) -> Void)?
    /// Trascinamento con il tasto destro: spostamento in pixel. Regola finestra e livello.
    var onWindowLevelDrag: ((CGSize) -> Void)?
    /// Clic singolo.
    var onClick: ((CGPoint) -> Void)?
    /// Movimento del puntatore; `nil` quando esce dalla vista.
    var onHover: ((CGPoint?) -> Void)?
    /// Doppio clic: ingrandisce il riquadro a piena finestra.
    var onDoubleClick: (() -> Void)?

    // MARK: Configurazione

    /// Origine in alto a sinistra, come la texture. Senza questo l'asse verticale sarebbe
    /// rovesciato rispetto all'immagine, e ogni misura risulterebbe specchiata.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Conversione delle coordinate

    /// Da coordinate finestra a pixel della texture.
    ///
    /// `convert(_:from: nil)` porta nello spazio della vista, che grazie a `isFlipped` ha già
    /// l'origine in alto a sinistra; resta da moltiplicare per il fattore di scala del display,
    /// perché su Retina un punto vale due pixel e lo shader lavora in pixel.
    private func pixelLocation(of event: NSEvent) -> CGPoint {
        let inView = convert(event.locationInWindow, from: nil)
        let scale = window?.backingScaleFactor ?? 1.0
        return CGPoint(x: inView.x * scale, y: inView.y * scale)
    }

    private func pixelDelta(of event: NSEvent) -> CGSize {
        let scale = window?.backingScaleFactor ?? 1.0
        // `deltaY` di AppKit cresce verso l'alto; la vista è capovolta, quindi si inverte per
        // restare coerenti con `pixelLocation`.
        return CGSize(width: event.deltaX * scale, height: -event.deltaY * scale)
    }

    // MARK: Eventi

    override func scrollWheel(with event: NSEvent) {
        // I trackpad producono molti eventi piccoli e continui, i mouse a rotella pochi e
        // discreti. Normalizzare a "passi" evita che sul trackpad le slice sfreccino via.
        let raw = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 8.0 : event.scrollingDeltaY
        guard abs(raw) > 0.001 else { return }
        onScroll?(Double(raw))
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + Double(event.magnification)
        guard factor > 0 else { return }
        onMagnify?(factor)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?(pixelLocation(of: event))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        onDrag?(pixelLocation(of: event), pixelDelta(of: event))
    }

    override func rightMouseDragged(with event: NSEvent) {
        onWindowLevelDrag?(pixelDelta(of: event))
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(pixelLocation(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
}
