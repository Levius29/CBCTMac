import AppKit
import SwiftUI

// Intercettazione della rotella su una vista SwiftUI qualunque.
//
// SwiftUI su macOS non espone la rotella fuori da `ScrollView`, e una `ScrollView` qui non serve:
// la striscia di sezioni non scorre il proprio contenuto, cambia **quali** sezioni mostra. Sono
// due cose diverse, e usare una `ScrollView` per ottenere la seconda significherebbe tenere in
// memoria e disegnare tutte le sezioni per poi mostrarne dieci.
//
// Si scende quindi a `NSView`, come già fa `InteractiveMetalView`, ma con una vista trasparente e
// **senza sottrarre i clic** a chi sta sotto: `hitTest` restituisce `nil`, quindi il puntatore
// attraversa. La rotella arriva lo stesso, perché AppKit la consegna alla catena delle viste sotto
// il cursore indipendentemente da `hitTest`.

private final class ScrollWheelView: NSView {

    /// Passi di rotella, e se il modificatore ⌘ è premuto.
    var onScroll: ((Double, Bool) -> Void)?

    /// Lascia passare i clic a chi sta sotto: questa vista esiste solo per la rotella.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func scrollWheel(with event: NSEvent) {
        // La stessa normalizzazione di `InteractiveMetalView`: i trackpad producono molti eventi
        // piccoli e continui, i mouse a rotella pochi e discreti, e senza normalizzare sul
        // trackpad la striscia sfreccerebbe via.
        let raw = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 8.0
            : event.scrollingDeltaY
        guard abs(raw) > 0.001 else {
            super.scrollWheel(with: event)
            return
        }
        onScroll?(Double(raw), event.modifierFlags.contains(.command))
    }
}

private struct ScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (Double, Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = ScrollWheelView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ScrollWheelView)?.onScroll = onScroll
    }
}

extension View {
    /// Riceve la rotella su questa vista: passi e stato del modificatore ⌘.
    ///
    /// Positivo verso l'alto, come ovunque su macOS. Il secondo parametro è vero quando ⌘ è
    /// premuto, che per convenzione in questa applicazione significa «ingrandisci invece di
    /// scorrere» — la stessa scelta fatta nei riquadri, così non c'è una convenzione in più da
    /// ricordare.
    func onScrollWheel(_ action: @escaping (Double, Bool) -> Void) -> some View {
        overlay(ScrollWheelCatcher(onScroll: action))
    }
}
