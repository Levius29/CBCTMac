import DICOMCore
import StudyKit
import SwiftUI
import VolumeKit

// I tre punti del piano occlusale sulle viste 2D.
//
// # Perché si vedono anche quando la fetta non è la loro
//
// Perché è il punto di questa operazione: i tre punti stanno **a quote diverse** — due cuspidi e
// un incisivo non cadono mai sulla stessa fetta — e senza vedere dove sono i primi due non si
// può giudicare dove mettere il terzo. Sbiadiscono con la distanza dal piano invece di sparire,
// come i reperi cefalometrici e per la stessa ragione.

struct OcclusalPlaneOverlay: View {

    let model: AppModel
    var plane: MPRPlane?

    /// Oltre questa distanza dal piano il punto non si disegna più.
    ///
    /// Più larga di quella dei reperi cefalometrici, e di proposito: i punti sono tre soli,
    /// quindi non c'è il rischio di riempire il riquadro, e la quota fra una cuspide e un
    /// incisivo può superare i venti millimetri.
    static let visibilityMM: Double = 40

    /// Quanto vicino bisogna premere per colpirne uno, in pixel del riquadro.
    static let grabRadiusPixels: Double = 10

    /// L'indice del punto disegnato più vicino a una posizione del riquadro.
    ///
    /// In pixel e non in millimetri, per la stessa ragione di `CephOverlay.nearest`: quel che si
    /// colpisce dev'essere quel che si vede.
    static func nearest(
        in pointsMM: [Vec3], to point: CGPoint, plane: MPRPlane, width: Int, height: Int
    ) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, candidate) in pointsMM.enumerated() {
            let depth = abs((candidate - plane.centerMM).dot(plane.normalMM))
            guard depth <= visibilityMM else { continue }
            let projected = plane.pixelPosition(
                ofPatient: candidate, pixelWidth: width, pixelHeight: height)
            let dx = projected.x - Double(point.x)
            let dy = projected.y - Double(point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= grabRadiusPixels ? best : nil
    }

    var body: some View {
        Canvas { context, size in
            guard let plane, size.width > 1, size.height > 1 else { return }
            let width = Int(size.width)
            let height = Int(size.height)

            var projected: [(index: Int, location: CGPoint, fade: Double)] = []
            for (index, pointMM) in model.occlusalPointsMM.enumerated() {
                let depth = abs((pointMM - plane.centerMM).dot(plane.normalMM))
                guard depth <= Self.visibilityMM else { continue }
                let screen = plane.pixelPosition(
                    ofPatient: pointMM, pixelWidth: width, pixelHeight: height)
                projected.append(
                    (index, CGPoint(x: screen.x, y: screen.y),
                     1 - depth / Self.visibilityMM * 0.7))
            }

            // Il triangolo prima dei punti: dice a colpo d'occhio se i tre non sono allineati,
            // che è la sola condizione perché definiscano un piano. Tre punti quasi in fila
            // danno un triangolo schiacciato, e si vede prima di leggere l'avvertimento.
            if projected.count == 3 {
                var triangle = Path()
                triangle.move(to: projected[0].location)
                triangle.addLine(to: projected[1].location)
                triangle.addLine(to: projected[2].location)
                triangle.closeSubpath()
                let fade = projected.map(\.fade).min() ?? 1
                context.stroke(
                    triangle, with: .color(Palette.accent.opacity(0.45 * fade)),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            for entry in projected {
                let colour = Palette.accent.opacity(entry.fade)
                let radius: CGFloat = 4
                let dot = Path(
                    ellipseIn: CGRect(
                        x: entry.location.x - radius, y: entry.location.y - radius,
                        width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(colour))
                context.stroke(dot, with: .color(.black.opacity(0.6 * entry.fade)), lineWidth: 0.5)

                context.draw(
                    Text("\(entry.index + 1)")
                        .font(Typography.numericSmall)
                        .foregroundStyle(colour),
                    at: CGPoint(x: entry.location.x + 8, y: entry.location.y - 8),
                    anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }
}
