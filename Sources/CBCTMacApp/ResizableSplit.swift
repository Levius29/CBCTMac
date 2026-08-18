import SwiftUI

// Divisori trascinabili fra i riquadri.
//
// # Perché le dimensioni fisse non vanno bene
//
// La striscia delle sezioni trasversali era alta 240 punti, sempre. Su una CBCT parziale con
// sezioni strette ne avanzava; guardando una cresta atrofica servivano il doppio, e non c'era
// modo di averlo. Una misura scelta a tavolino va bene per il caso medio e per nessun caso
// particolare — e in radiologia il caso particolare è la regola: il compito cambia da paziente a
// paziente, e con esso cambia quale riquadro merita lo spazio.
//
// # Perché si ricorda
//
// Chi lavora sulle sezioni trasversali le allarga una volta e le vuole larghe anche domani.
// Ripristinare la misura di fabbrica a ogni avvio significa rifare lo stesso gesto ogni giorno,
// che è il modo più sicuro di far sembrare scomodo un programma.
//
// # Perché il divisore è più largo di quello che si vede
//
// La riga disegnata è di due punti; l'area che risponde è di dieci. Un bersaglio di due punti si
// manca, e mancarlo qui significa trascinare il contenuto del riquadro invece del divisore —
// cioè fare una cosa diversa da quella voluta, che è peggio che non fare niente.

struct DraggableDivider: View {

    enum Axis {
        /// Divisore orizzontale: si trascina in su e in giù per cambiare un'altezza.
        case horizontal
        /// Divisore verticale: si trascina di lato per cambiare una larghezza.
        case vertical
    }

    let axis: Axis
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Se il valore cresce muovendo verso il basso o verso destra.
    var isInverted: Bool = false

    @State private var isHovering = false
    @State private var valueAtDragStart: Double?

    var body: some View {
        Rectangle()
            .fill(isHovering ? Palette.accent.opacity(0.7) : Palette.separator)
            .frame(
                width: axis == .vertical ? 2 : nil,
                height: axis == .horizontal ? 2 : nil)
            // L'area di presa, invisibile e più generosa del segno.
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .frame(
                        width: axis == .vertical ? 10 : nil,
                        height: axis == .horizontal ? 10 : nil)
                    .onHover { isHovering = $0 }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { drag in
                                // Il valore di partenza si fissa alla prima notifica e non si
                                // rilegge: sommando i delta a ogni evento l'errore si accumula, e
                                // il divisore scivola rispetto al puntatore.
                                let start = valueAtDragStart ?? value
                                if valueAtDragStart == nil { valueAtDragStart = start }

                                let movement =
                                    axis == .horizontal
                                    ? Double(drag.translation.height)
                                    : Double(drag.translation.width)
                                let delta = isInverted ? movement : -movement
                                value = min(max(start + delta, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in valueAtDragStart = nil }
                    )
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
