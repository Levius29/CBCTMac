import DICOMCore
import MeshKit
import StudyKit
import SwiftUI
import VolumeKit

// Il contorno della scansione intraorale sulle viste 2D.
//
// # Perché è questo il modo di guardare una scansione, e non il 3D
//
// Perché è così che si giudica una registrazione. Il numero di scarto dice *quanto* le due
// superfici distano in media; il contorno dice **dove**, e su un piano alla volta. Un allineamento
// con scarto accettabile e un settore fuori posto si vede qui e non si vede in nessun numero — ed
// è precisamente il settore in cui si sta per mettere un impianto.
//
// # Perché i contorni arrivano già calcolati
//
// Intersecare centomila triangoli con un piano costa qualche millisecondo: trascurabile una volta
// per movimento del mirino, insostenibile sessanta volte al secondo per tre riquadri. Il modello
// li ricalcola quando i piani cambiano; qui si proietta e si disegna, e basta.

struct ScanContourOverlay: View {

    let model: AppModel
    /// Riquadro ortogonale, quando il contorno viene da lì.
    var slot: ViewportSlot?
    /// Anelli e piano espliciti, per una sezione trasversale, che un riquadro non è.
    var explicitLoops: [[Vec3]]?
    var explicitPlane: MPRPlane?

    var body: some View {
        Canvas { context, size in
            let source = explicitLoops ?? slot.flatMap { model.scanContours[$0] }
            guard let loops = source, !loops.isEmpty,
                let plane = resolvedPlane(size: size)
            else { return }

            let width = Int(size.width)
            let height = Int(size.height)

            for loop in loops where loop.count >= 2 {
                var path = Path()
                var started = false
                for point in loop {
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
                context.stroke(path, with: .color(colour), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    /// Il colore dice **quanto ci si può fidare**, e non è decorazione.
    ///
    /// Un contorno disegnato tutto uguale suggerisce che la registrazione sia un fatto. Non lo è
    /// finché lo scarto non lo dice, e chi guarda deve saperlo senza andare a cercare il numero.
    private var colour: Color {
        guard let quality = model.scanRegistration?.quality else {
            // Non registrata: sta dove la mette il suo file, cioè da nessuna parte in
            // particolare rispetto al paziente.
            return Palette.textSecondary.opacity(0.5)
        }
        switch quality {
        case .good: return Palette.safe
        case .acceptable: return Palette.warning
        case .poor: return Palette.danger
        }
    }

    private func resolvedPlane(size: CGSize) -> MPRPlane? {
        let source = explicitPlane ?? slot.flatMap { model.planes[$0] }
        guard let plane = source, size.width > 0, size.height > 0 else { return nil }
        return plane.matchingAspect(
            pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }
}
