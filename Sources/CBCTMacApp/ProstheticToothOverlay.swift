import DICOMCore
import ImplantKit
import SwiftUI
import VolumeKit

// La sagoma del dente protesico disegnata sopra le viste 2D.
//
// # Che cosa si guarda, esattamente
//
// Non la corona: l'ingombro. La domanda che questa sovraimpressione deve saper rispondere a
// colpo d'occhio è una sola — **l'impianto emerge dentro questo dente?** — e per rispondere
// servono due cose disegnate insieme: il perimetro della corona, e il punto in cui l'asse
// dell'impianto, prolungato, buca il piano occlusale.
//
// Il perimetro è la silhouette del parallelepipedo: l'inviluppo convesso degli otto vertici
// proiettati. Da una direzione qualunque un cubo si vede come un esagono, e disegnare invece
// il rettangolo delle sole misure nominali mostrerebbe la sagoma giusta soltanto guardandola
// esattamente di fronte — cioè quasi mai, perché i denti sono inclinati e le viste no.

struct ProstheticToothOverlay: View {

    let model: AppModel
    /// Come per `ImplantOverlay`: il piano è l'unico ingresso, così la sagoma compare anche
    /// sulle sezioni trasversali, che sono la vista su cui un impianto si giudica davvero.
    let plane: MPRPlane?

    var body: some View {
        Canvas { context, size in
            guard let plane = adjusted(for: size) else { return }
            let width = Int(size.width)
            let height = Int(size.height)

            for tooth in model.teeth where tooth.isVisible {
                draw(
                    tooth, in: &context, plane: plane, width: width, height: height,
                    isSelected: tooth.id == model.selectedToothID)
            }
        }
        .allowsHitTesting(false)
    }

    private func adjusted(for size: CGSize) -> MPRPlane? {
        guard let plane, size.width > 0, size.height > 0 else { return nil }
        return plane.matchingAspect(pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func draw(
        _ tooth: ProstheticTooth,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int,
        isSelected: Bool
    ) {
        let corners = tooth.corners(mesialDirectionMM: model.mesialDirection(for: tooth))
        guard corners.count == 8 else { return }

        var projected: [CGPoint] = []
        projected.reserveCapacity(8)
        var lowestSigned = Double.infinity
        var highestSigned = -Double.infinity
        for corner in corners {
            let position = plane.pixelPosition(
                ofPatient: corner, pixelWidth: width, pixelHeight: height)
            projected.append(CGPoint(x: position.x, y: position.y))
            lowestSigned = min(lowestSigned, position.distanceMM)
            highestSigned = max(highestSigned, position.distanceMM)
        }

        // La corona sfuma quando il piano le passa **fuori**, non quando le passa lontano dal
        // centro: un molare è alto sette millimetri, e sfumare sulla distanza dal centro lo
        // farebbe sparire proprio scorrendo lungo la sua altezza, che è quando lo si guarda.
        //
        // Le distanze si guardano **con il segno**, e non in valore assoluto: una scatola è
        // convessa, quindi il piano la taglia esattamente quando i suoi otto vertici stanno da
        // entrambe le parti. Con il valore assoluto un piano che passasse a metà altezza — nessun
        // vertice vicino, tutti a tre o quattro millimetri — dava una distanza di tre millimetri
        // su una sfumatura di quattro: sagoma disegnata al sei per cento di opacità, cioè
        // invisibile, proprio nel taglio che la attraversa da parte a parte.
        let nearest = PlaneProximity.distanceMM(from: lowestSigned, to: highestSigned)
        let opacity = PlaneProximity.fadeOpacity(distanceMM: nearest, fadeOverMM: 4)
        guard opacity > 0.03 else { return }

        let hull = convexHull(of: projected)
        guard hull.count >= 3 else { return }

        var outline = Path()
        outline.move(to: hull[0])
        for point in hull.dropFirst() { outline.addLine(to: point) }
        outline.closeSubpath()

        let colour = Color(hexString: tooth.colorHex) ?? Palette.textPrimary
        context.fill(outline, with: .color(colour.opacity(0.10 * opacity)))
        context.stroke(
            outline,
            with: .color(colour.opacity(0.75 * opacity)),
            style: StrokeStyle(
                lineWidth: isSelected ? 1.8 : 1.2,
                // Tratteggiata: la corona è una **sagoma di riferimento**, non anatomia
                // rilevata, e il tratteggio lo dice senza bisogno di una legenda. Un contorno
                // pieno la metterebbe sullo stesso piano visivo del tessuto vero.
                dash: [4, 3]))

        drawOcclusalMarks(
            tooth, in: &context, plane: plane, width: width, height: height,
            colour: colour, opacity: opacity, isSelected: isSelected)
    }

    /// Il centro occlusale e, se c'è un impianto sotto, il punto in cui emerge.
    private func drawOcclusalMarks(
        _ tooth: ProstheticTooth,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int,
        colour: Color,
        opacity: Double,
        isSelected: Bool
    ) {
        let centre = plane.pixelPosition(
            ofPatient: tooth.occlusalCentreMM, pixelWidth: width, pixelHeight: height)
        let centrePoint = CGPoint(x: centre.x, y: centre.y)

        // Crocetta sul centro occlusale: è il bersaglio, e senza un segno esplicito si
        // giudicherebbe l'emergenza «a occhio» rispetto a un perimetro tratteggiato.
        var cross = Path()
        cross.move(to: CGPoint(x: centrePoint.x - 4, y: centrePoint.y))
        cross.addLine(to: CGPoint(x: centrePoint.x + 4, y: centrePoint.y))
        cross.move(to: CGPoint(x: centrePoint.x, y: centrePoint.y - 4))
        cross.addLine(to: CGPoint(x: centrePoint.x, y: centrePoint.y + 4))
        context.stroke(cross, with: .color(colour.opacity(0.8 * opacity)), lineWidth: 1)

        guard let constraint = model.constraintForTooth(tooth), let emergence = constraint.emergenceMM
        else {
            if isSelected {
                drawLabel(
                    "Dente \(tooth.toothNumber)", at: centrePoint, in: &context,
                    color: colour, opacity: opacity)
            }
            return
        }

        let projected = plane.pixelPosition(
            ofPatient: emergence, pixelWidth: width, pixelHeight: height)
        let emergencePoint = CGPoint(x: projected.x, y: projected.y)

        let severityColour: Color =
            switch constraint.severity {
            case .acceptable: Palette.safe
            case .caution: Palette.caution
            case .unacceptable: Palette.danger
            }

        // Segmento fra bersaglio ed emergenza: è lo scostamento, disegnato invece che
        // riassunto in un numero nell'ispettore che nessuno guarda mentre trascina.
        var offsetPath = Path()
        offsetPath.move(to: centrePoint)
        offsetPath.addLine(to: emergencePoint)
        context.stroke(
            offsetPath, with: .color(severityColour.opacity(0.85 * opacity)), lineWidth: 1.4)

        let dot = CGRect(
            x: emergencePoint.x - 3.5, y: emergencePoint.y - 3.5, width: 7, height: 7)
        context.fill(Path(ellipseIn: dot), with: .color(severityColour.opacity(0.95 * opacity)))

        guard isSelected else { return }
        drawLabel(
            "\(tooth.toothNumber) · \(constraint.summary)", at: emergencePoint,
            in: &context, color: severityColour, opacity: opacity)
    }

    private func drawLabel(
        _ text: String,
        at point: CGPoint,
        in context: inout GraphicsContext,
        color: Color,
        opacity: Double
    ) {
        let resolved = context.resolve(
            Text(text).font(Typography.numericSmall).foregroundStyle(color.opacity(opacity)))
        let size = resolved.measure(in: CGSize(width: 320, height: 60))
        let origin = CGPoint(x: point.x + 10, y: point.y - size.height / 2)
        let background = CGRect(
            x: origin.x - 3, y: origin.y - 2, width: size.width + 6, height: size.height + 4)
        context.fill(
            Path(roundedRect: background, cornerRadius: 3),
            with: .color(.black.opacity(0.55 * opacity)))
        context.draw(resolved, at: origin, anchor: .topLeading)
    }
}

// MARK: - Inviluppo convesso

/// Catena monotona di Andrew, su otto punti al più.
///
/// Sta qui e non in un modulo di geometria perché è una faccenda di disegno: opera su punti
/// dello schermo, e in millimetri Patient non significherebbe niente.
///
/// - Returns: i vertici in senso orario nel sistema dello schermo, senza ripetere il primo.
///   Meno di tre punti quando la sagoma degenera — un cubo visto esattamente di taglio.
func convexHull(of points: [CGPoint]) -> [CGPoint] {
    guard points.count >= 3 else { return points }

    let sorted = points.sorted { left, right in
        left.x == right.x ? left.y < right.y : left.x < right.x
    }

    func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }

    var lower: [CGPoint] = []
    for point in sorted {
        while lower.count >= 2,
            cross(lower[lower.count - 2], lower[lower.count - 1], point) <= 0
        {
            lower.removeLast()
        }
        lower.append(point)
    }

    var upper: [CGPoint] = []
    for point in sorted.reversed() {
        while upper.count >= 2,
            cross(upper[upper.count - 2], upper[upper.count - 1], point) <= 0
        {
            upper.removeLast()
        }
        upper.append(point)
    }

    // L'ultimo di ciascuna catena è il primo dell'altra: si tolgono per non ripeterli.
    lower.removeLast()
    upper.removeLast()
    return lower + upper
}
