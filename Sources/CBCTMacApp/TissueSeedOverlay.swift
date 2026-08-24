import DICOMCore
import SegmentKit
import SwiftUI
import VolumeKit

// I marcatori di tessuto, disegnati sopra le viste.
//
// # Perché esiste, e perché è la prima cosa da scrivere
//
// Perché un marcatore posato e non disegnato è un clic che non fa niente, dal punto di vista di
// chi lo fa. È già successo in questo programma con gli impianti: l'oggetto c'era, era
// nell'elenco, e non si vedeva da nessuna parte — e la conclusione ragionevole era che lo
// strumento fosse rotto.
//
// Sfuma con la distanza dal piano come tutto il resto, con la stessa regola: vedi
// `PlaneProximity`. Un marcatore è un punto, quindi non c'è un corpo da attraversare — la
// distanza è quella del punto, e oltre un paio di millimetri non è più su questa fetta.
struct TissueSeedOverlay: View {

    let model: AppModel
    let plane: MPRPlane?

    /// Oltre questa distanza dal piano il marcatore non appartiene più alla fetta che si guarda.
    private static let fadeOverMM = 2.5

    var body: some View {
        Canvas { context, size in
            guard let plane = adjusted(for: size), !model.tissueSeeds.isEmpty else { return }
            let width = Int(size.width)
            let height = Int(size.height)

            for seed in model.tissueSeeds {
                let projected = plane.pixelPosition(
                    ofPatient: seed.pointMM, pixelWidth: width, pixelHeight: height)
                let opacity = PlaneProximity.fadeOpacity(
                    distanceMM: abs(projected.distanceMM), fadeOverMM: Self.fadeOverMM)
                guard opacity > 0.03 else { continue }

                let centre = CGPoint(x: projected.x, y: projected.y)
                let colour = Color(hexString: seed.colorHex) ?? Palette.accent
                let radius: CGFloat = 5

                // Un cerchio pieno col bordo bianco: si deve vedere sia sull'osso chiaro sia
                // sull'aria nera, e un solo colore non ci riesce su tutti e due.
                let circle = Path(
                    ellipseIn: CGRect(
                        x: centre.x - radius, y: centre.y - radius,
                        width: radius * 2, height: radius * 2))
                context.fill(circle, with: .color(colour.opacity(0.85 * opacity)))
                context.stroke(
                    circle, with: .color(.white.opacity(0.9 * opacity)), lineWidth: 1.5)

                // Il nome accanto, perché con otto denti marcati il colore da solo non basta.
                context.draw(
                    Text(seed.name)
                        .font(Typography.viewportLabel)
                        .foregroundStyle(colour.opacity(opacity)),
                    at: CGPoint(x: centre.x + radius + 4, y: centre.y),
                    anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func adjusted(for size: CGSize) -> MPRPlane? {
        guard let plane, size.width > 0, size.height > 0 else { return nil }
        return plane.matchingAspect(pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }
}
