import CephKit
import DICOMCore
import StudyKit
import SwiftUI
import VolumeKit

// I reperi cefalometrici e il profilo del viso sulle viste 2D.
//
// # Perché un repere si vede anche quando la fetta non è la sua
//
// Perché è un punto nello spazio, e la fetta che si guarda ha uno spessore. Un nasion segnato tre
// millimetri più in là esiste ancora: nasconderlo del tutto farebbe credere di non averlo
// segnato, e riclicandoci sopra se ne otterrebbe un secondo. Sbiadisce invece di sparire, e la
// distanza dalla fetta si legge dall'opacità — la stessa convenzione degli impianti.
//
// # Perché il profilo si disegna solo sul sagittale
//
// Perché è una linea su un piano sagittale, e proiettarla su un assiale la ridurrebbe a una
// macchia verticale che non vuol dire niente. Su un riquadro che non è il suo non c'è.

struct CephOverlay: View {

    let model: AppModel
    /// Il piano del riquadro. `nil` quando il riquadro non ne ha uno: allora non si disegna.
    var plane: MPRPlane?
    /// Quale riquadro, per sapere se il profilo del viso ci va.
    var slot: ViewportSlot?

    /// Oltre questa distanza dal piano il repere non si disegna più.
    ///
    /// Venti millimetri: abbastanza da vedere un repere della fetta accanto mentre lo si cerca,
    /// poco abbastanza da non riempire un assiale di venticinque sigle che stanno altrove.
    static let visibilityMM: Double = 20

    /// Quanto vicino bisogna premere per colpire un repere, in pixel del riquadro.
    static let grabRadiusPixels: Double = 9

    /// Il repere disegnato più vicino a un punto del riquadro.
    ///
    /// # Perché in pixel e non in millimetri
    ///
    /// Perché quel che si colpisce dev'essere quel che si vede. Un repere a quindici millimetri
    /// dal piano è **disegnato**, sbiadito ma visibile; cercandolo con una tolleranza in
    /// millimetri nello spazio, un ⌥ clic proprio sopra di esso non lo troverebbe — e chi l'ha
    /// fatto concluderebbe che il programma non risponde. La regola è la stessa della curva
    /// d'arcata: si proietta e si misura sullo schermo.
    static func nearest(
        in tracing: CephTracing, to point: CGPoint, plane: MPRPlane, width: Int, height: Int
    ) -> CephPoint? {
        var best: CephPoint?
        var bestDistance = Double.infinity
        for candidate in tracing.points {
            let depth = abs((candidate.positionMM - plane.centerMM).dot(plane.normalMM))
            guard depth <= visibilityMM else { continue }
            let projected = plane.pixelPosition(
                ofPatient: candidate.positionMM, pixelWidth: width, pixelHeight: height)
            let dx = projected.x - Double(point.x)
            let dy = projected.y - Double(point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return bestDistance <= grabRadiusPixels ? best : nil
    }

    var body: some View {
        Canvas { context, size in
            guard let plane, size.width > 1, size.height > 1 else { return }
            let width = Int(size.width)
            let height = Int(size.height)

            drawProfile(in: context, plane: plane, width: width, height: height)

            for point in model.cephTracing.points {
                let distance = abs((point.positionMM - plane.centerMM).dot(plane.normalMM))
                guard distance <= Self.visibilityMM else { continue }

                let projected = plane.pixelPosition(
                    ofPatient: point.positionMM, pixelWidth: width, pixelHeight: height)
                let location = CGPoint(x: projected.x, y: projected.y)
                guard location.x > -20, location.y > -20,
                    location.x < size.width + 20, location.y < size.height + 20
                else { continue }

                // Piena sul piano, sbiadita a venti millimetri. Non sotto un terzo: un punto
                // quasi invisibile è un punto che si segna una seconda volta.
                let fade = 1 - distance / Self.visibilityMM * 0.7
                let isNext = point.landmark == model.cephLandmarkToPlace
                let colour = (isNext ? Palette.accent : Palette.segmentation).opacity(fade)

                let radius: CGFloat = 3
                let dot = Path(
                    ellipseIn: CGRect(
                        x: location.x - radius, y: location.y - radius,
                        width: radius * 2, height: radius * 2))
                context.fill(dot, with: .color(colour))
                context.stroke(dot, with: .color(.black.opacity(0.6 * fade)), lineWidth: 0.5)

                context.draw(
                    Text(point.displayName)
                        .font(Typography.numericSmall)
                        .foregroundStyle(colour),
                    at: CGPoint(x: location.x + 7, y: location.y - 7), anchor: .leading)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawProfile(
        in context: GraphicsContext, plane: MPRPlane, width: Int, height: Int
    ) {
        guard slot == .sagittal, let profile = model.faceProfile, profile.pointsMM.count >= 2
        else { return }

        var path = Path()
        var started = false
        for point in profile.pointsMM {
            let projected = plane.pixelPosition(
                ofPatient: point, pixelWidth: width, pixelHeight: height)
            let location = CGPoint(x: projected.x, y: projected.y)
            if started {
                path.addLine(to: location)
            } else {
                path.move(to: location)
                started = true
            }
        }
        context.stroke(path, with: .color(Palette.caution.opacity(0.85)), lineWidth: 1.5)
    }
}
