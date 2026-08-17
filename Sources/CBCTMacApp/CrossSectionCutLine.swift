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

struct CrossSectionCutLine: View {

    @Bindable var model: AppModel

    /// Quanto in alto arriva la maniglia di rotazione, in frazione dell'altezza.
    private let handleFraction: CGFloat = 0.12

    @State private var dragMode: DragMode?

    private enum DragMode {
        case position
        case angle
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            if let x = lineX(in: size) {
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
                    .stroke(Palette.accent.opacity(0.9), lineWidth: 1.5)

                    // Maniglia di rotazione in cima, dove non copre l'anatomia che si sta
                    // guardando: la cresta e gli apici stanno in mezzo, non al bordo.
                    Circle()
                        .fill(Palette.accent)
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                        .frame(width: 11, height: 11)
                        .position(
                            x: x - CGFloat(Foundation.tan(model.crossSectionAngleOffset))
                                * size.height / 2,
                            y: size.height * handleFraction)

                    positionLabel(at: x, in: size)
                }
                .contentShape(.rect)
                .gesture(gesture(in: size))
            }
        }
        .allowsHitTesting(model.crossSectionBrowser.selectedSection != nil)
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

    // MARK: Gesti

    private func gesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragMode == nil {
                    // La modalità si decide alla prima notifica e non cambia più: leggerla a ogni
                    // evento farebbe commutare fra spostamento e rotazione a metà gesto.
                    dragMode =
                        value.startLocation.y < size.height * handleFraction * 2
                        ? .angle : .position
                }

                switch dragMode {
                case .angle:
                    // L'angolo dallo spostamento orizzontale della maniglia rispetto alla base
                    // della linea: è la stessa geometria che la linea disegna, quindi la maniglia
                    // segue il dito.
                    guard let x = lineX(in: size) else { return }
                    let half = size.height / 2
                    guard half > 1 else { return }
                    let offset = Double((x - value.location.x) / half)
                    let angle = Foundation.atan(offset)
                    // Oltre i sessanta gradi la sezione diventa quasi tangente alla curva e non
                    // rappresenta più una trasversale: si ferma prima invece di produrre immagini
                    // senza significato.
                    model.crossSectionAngleOffset = min(max(angle, -.pi / 3), .pi / 3)

                case .position, .none:
                    model.selectCrossSection(
                        nearestToArcLengthMM: arcLength(atX: value.location.x, in: size))
                }
            }
            .onEnded { _ in dragMode = nil }
    }
}
