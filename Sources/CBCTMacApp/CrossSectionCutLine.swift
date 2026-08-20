import AppKit
import DentalKit
import SwiftUI

// Linea di taglio disegnata sul panorex.
//
// È **un solo oggetto con due gesti**, e questa è la parte che conta della sua progettazione.
// Trascinandola lungo l'arcata si sceglie *dove* tagliare; afferrandone la maniglia in cima e
// spostandosi in orizzontale si sceglie *con che angolo*. Sono le due libertà di una sezione
// trasversale, e tenerle sullo stesso oggetto è ciò che rende il gesto immediato: si guarda la
// linea e si vede insieme la posizione e l'inclinazione del taglio che si otterrà.
//
// L'alternativa — un cursore per la posizione e un campo per l'angolo, da qualche parte in un
// pannello — separa due grandezze che si scelgono guardando la stessa immagine, e obbliga a
// spostare lo sguardo avanti e indietro fra il comando e il suo effetto.
//
// # Perché sparisce col pulsante delle linee di taglio
//
// Perché è una linea di taglio: nasconderla di là e lasciarla di qua vorrebbe dire che il
// pulsante nasconde metà di quel che promette. E non toglie nulla di ciò che si può fare —
// la sezione si sceglie anche facendo clic sul panorex o con la rotella, e il taglio si inclina
// anche con ⇧ trascinamento sulla sezione stessa, che è il posto in cui l'inclinazione si vede.
// Quale sezione sia selezionata continua a dirlo la striscia, col bordo acceso e l'etichetta.

struct CrossSectionCutLine: View {

    @Bindable var model: AppModel

    /// Quanto in alto arriva la maniglia di rotazione, in frazione dell'altezza.
    private let handleFraction: CGFloat = 0.12

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            let visibility = model.cutLineVisibility
            if visibility.drawsAnything, let x = lineX(in: size) {
                ZStack(alignment: .topLeading) {
                    // La linea, inclinata dell'angolo di taglio. L'inclinazione a schermo è la
                    // stessa che il taglio ha nell'anatomia, quindi si vede cosa si otterrà prima
                    // di guardare la sezione.
                    Path { path in
                        let half = size.height / 2
                        let offset = CGFloat(Foundation.tan(model.crossSectionAngleOffset)) * half
                        path.move(to: CGPoint(x: x - offset, y: 0))
                        path.addLine(to: CGPoint(x: x + offset, y: size.height))
                    }
                    .stroke(Palette.accent.opacity(0.9 * visibility.opacity), lineWidth: 1.5)

                    // Maniglia di rotazione in cima, dove non copre l'anatomia che si sta
                    // guardando: la cresta e gli apici stanno in mezzo, non al bordo.
                    Circle()
                        .fill(Palette.accent)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .opacity(visibility.opacity)
                        .position(
                            x: x - CGFloat(Foundation.tan(model.crossSectionAngleOffset))
                                * size.height / 2,
                            y: size.height * handleFraction)

                    positionLabel(at: x, in: size).opacity(visibility.opacity)
                }
            }
        }
        // **Solo disegno.** Aveva `contentShape` e un `DragGesture`, e sotto c'è un `MTKView`:
        // AppKit consegna il mouse alla vista più profonda, quindi il gesto non riceveva niente —
        // ma la sovraimpressione **assorbiva comunque la rotella**, e con essa lo sfogliamento in
        // profondità del panorex, che era la cosa che funzionava prima. Un difetto che toglie una
        // funzione che c'era per aggiungerne una che non c'è.
        //
        // I due gesti vivono adesso in `PanoramicWorkspace`, sul percorso eventi del riquadro.
        .allowsHitTesting(false)
    }

    // MARK: Posizione

    /// Ascissa della linea nel riquadro, dalla lunghezza d'arco della sezione selezionata.
    ///
    /// Passa dalla **finestra visibile** e non dalla lunghezza totale: ingranditi le due cose
    /// divergono, e la linea finirebbe altrove rispetto alla sezione che rappresenta.
    private func lineX(in size: CGSize) -> CGFloat? {
        guard let section = model.crossSectionBrowser.selectedSection, size.width > 0 else {
            return nil
        }
        let range = model.panoramicLayout.visibleArcRangeMM
        let span = max(range.upperBound - range.lowerBound, 1e-6)
        let fraction = (section.arcLengthMM - range.lowerBound) / span
        guard fraction >= -0.05, fraction <= 1.05 else { return nil }
        return CGFloat(min(max(fraction, 0), 1)) * size.width
    }

    private func arcLength(atX x: CGFloat, in size: CGSize) -> Double {
        let range = model.panoramicLayout.visibleArcRangeMM
        let span = range.upperBound - range.lowerBound
        let fraction = size.width > 0 ? Double(x / size.width) : 0
        return range.lowerBound + min(max(fraction, 0), 1) * span
    }

    @ViewBuilder
    private func positionLabel(at x: CGFloat, in size: CGSize) -> some View {
        if let section = model.crossSectionBrowser.selectedSection {
            Text(section.label)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Palette.chrome.opacity(0.85), in: .capsule)
                // A sinistra o a destra della linea a seconda di dove c'è posto, così
                // l'etichetta non esce mai dal riquadro.
                .position(
                    x: x < size.width - 70 ? x + 42 : x - 42,
                    y: size.height * handleFraction)
        }
    }
}
