import DICOMCore
import MeasureKit
import StudyKit
import SwiftUI
import VolumeKit

// Sovraimpressioni dei riquadri: etichette, mirino, annotazioni, barra di scala.
//
// Tutte disegnate in SwiftUI sopra la texture Metal, non dentro lo shader. Sono elementi di
// interfaccia, non parte dell'immagine: tenerli separati significa che una modifica al mirino
// non richiede di ricompilare uno shader, e che il testo resta nitido a qualunque scala perché
// lo rasterizza il sistema.

// MARK: - Angoli e barra di scala

struct ViewportChrome: View {

    let model: AppModel
    let slot: ViewportSlot
    let pointSize: CGSize

    var body: some View {
        ZStack {
            orientationLetters

            VStack {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(slot.localizedName.uppercased())
                            .font(Typography.viewportLabel)
                            .foregroundStyle(slot.accentColor)

                        if slot.anatomicalPlane != nil {
                            // La **quota in millimetri** in evidenza, e il numero di fetta come
                            // riga minore. È l'inversione di ciò che c'era prima, e la ragione è
                            // che il numero di fetta non è una grandezza: dipende da spaziatura e
                            // origine, non si confronta fra due studi, e non si comunica a
                            // nessuno. La quota sì.
                            if let position = model.positionLabel(for: slot) {
                                Text(position)
                                    .font(Typography.numeric)
                                    .foregroundStyle(Palette.textPrimary)
                            }
                            HStack(spacing: 6) {
                                if let indicator = model.sliceIndicator(for: slot) {
                                    Text("\(indicator.index)/\(indicator.count)")
                                }
                                Text(zoomText)
                            }
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary)
                        }
                    }

                    Spacer()

                    if slot.anatomicalPlane != nil {
                        Text(windowLevelText)
                            .font(Typography.numericSmall)
                            .foregroundStyle(Palette.textSecondary)
                            // Scende sotto i pulsanti d'angolo di `ViewportActions`, che occupano
                            // il posto naturale di questa etichetta.
                            .padding(.top, 24)
                    }
                }

                Spacer()

                HStack(alignment: .bottom) {
                    // L'algoritmo di ricostruzione, dichiarato come fanno i visori commerciali.
                    // Non è decorazione: dice da dove vengono i valori che si stanno misurando, e
                    // su una CBCT è il motivo per cui si scrive GV e non HU.
                    Text(model.reconstructionLabel)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary.opacity(0.7))
                    Spacer()
                    ScaleBar(millimetresPerPoint: millimetresPerPoint)
                }
            }
            .padding(Metrics.spacing)
        }
        .allowsHitTesting(false)
    }

    /// Lettere d'orientamento ai quattro bordi.
    ///
    /// Sono la difesa contro l'errore peggiore possibile su un'immagine radiologica: scambiare
    /// destra e sinistra del paziente. La convenzione radiologica mette la destra del paziente a
    /// sinistra dello schermo, cioè il contrario di quanto suggerisce l'istinto, e senza le lettere
    /// nulla lo ricorda.
    @ViewBuilder
    private var orientationLetters: some View {
        if let plane = slot.anatomicalPlane {
            let edges = plane.edgeLabels
            VStack {
                Text(edges.top)
                Spacer()
                Text(edges.bottom)
            }
            .font(Typography.numericSmall)
            .foregroundStyle(Palette.textSecondary.opacity(0.8))
            .padding(.vertical, 3)

            HStack {
                Text(edges.left)
                Spacer()
                Text(edges.right)
            }
            .font(Typography.numericSmall)
            .foregroundStyle(Palette.textSecondary.opacity(0.8))
            .padding(.horizontal, 3)
        }
    }

    private var zoomText: String {
        guard let plane = model.planes[slot], plane.widthMM > 0,
            let geometry = model.volume?.geometry
        else { return "" }
        // Lo zoom è il rapporto fra ciò che si vedrebbe inquadrando tutto e ciò che si vede ora:
        // a 1× il volume riempie il riquadro, a 4× se ne vede un quarto per lato.
        let size = geometry.physicalSizeMM
        let full = max(size.x, max(size.y, size.z))
        guard full > 0 else { return "" }
        return String(format: "%.2f×", full / plane.widthMM)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Ordine coerente con l'ispettore: **W** è l'ampiezza, **L** il livello.
    ///
    /// Nei mockup generati questa scritta risulta invertita rispetto all'ispettore. È un
    /// artefatto del modello immagine, non una scelta: vale quanto mostra l'ispettore.
    private var windowLevelText: String {
        String(format: "W %.0f   L %.0f", model.windowLevel.width, model.windowLevel.level)
            .replacingOccurrences(of: "-", with: "−")
    }

    private var millimetresPerPoint: Double? {
        guard let plane = model.planes[slot], pointSize.width > 0 else { return nil }
        let adjusted = plane.matchingAspect(
            pixelWidth: Int(pointSize.width), pixelHeight: Int(max(pointSize.height, 1)))
        return adjusted.widthMM / Double(pointSize.width)
    }
}

/// Barra di scala metrica.
///
/// Sempre presente, anche a schermo intero. È ciò che rende interpretabile uno screenshot preso
/// fuori dall'applicazione: senza, un'immagine ingrandita e una rimpicciolita sono
/// indistinguibili, e la seconda cosa che si chiede guardando una CBCT è «quanto misura».
struct ScaleBar: View {

    let millimetresPerPoint: Double?

    /// Lunghezze ammesse, in millimetri. Solo valori tondi: una barra da «7,3 mm» costringe a
    /// fare i conti invece di leggere.
    private static let candidates: [Double] = [1, 2, 5, 10, 20, 50, 100]

    var body: some View {
        if let mmPerPoint = millimetresPerPoint, mmPerPoint > 0, let choice = chooseLength(mmPerPoint) {
            VStack(spacing: 2) {
                Text("\(Int(choice.millimetres)) mm")
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                Rectangle()
                    .fill(Palette.textPrimary.opacity(0.85))
                    .frame(width: choice.points, height: 2)
                    .overlay(alignment: .leading) { tick }
                    .overlay(alignment: .trailing) { tick }
            }
        }
    }

    private var tick: some View {
        Rectangle()
            .fill(Palette.textPrimary.opacity(0.85))
            .frame(width: 2, height: 8)
    }

    /// Sceglie la lunghezza tonda che sta più vicina agli 80 punti.
    private func chooseLength(_ mmPerPoint: Double) -> (millimetres: Double, points: CGFloat)? {
        let target: Double = 80
        var best: (Double, CGFloat)?
        var bestError = Double.infinity
        for millimetres in Self.candidates {
            let points = millimetres / mmPerPoint
            guard points >= 30, points <= 200 else { continue }
            let error = abs(points - target)
            if error < bestError {
                bestError = error
                best = (millimetres, CGFloat(points))
            }
        }
        return best
    }
}

// MARK: - Annotazioni

struct AnnotationOverlay: View {

    let model: AppModel
    /// Riquadro ortogonale di provenienza, quando il piano viene da lì.
    var slot: ViewportSlot?
    /// Piano esplicito, per i riquadri che non sono uno dei tre ortogonali — una sezione
    /// trasversale ha il proprio piano e non compare in `model.planes`.
    var explicitPlane: MPRPlane?
    var pointSize: CGSize = .zero
    var pixelSize: CGSize = .zero
    /// Punti già posati dalla misura in corso, di qualunque forma sia.
    ///
    /// Uno solo: è il primo estremo di una distanza, e va mostrato perché un clic senza riscontro
    /// sembra un clic perso. Due o più: è una spezzata che cresce, e mostrarla evita di doverla
    /// rifare da capo quando al quarto punto non si ricorda più dove stavano gli altri.
    var pendingPointsMM: [Vec3] = []

    var body: some View {
        Canvas { context, size in
            guard let plane = resolvedPlane(size: size) else { return }
            let width = Int(size.width)
            let height = Int(size.height)

            for annotation in model.annotations where !annotation.metadata.isHidden {
                draw(
                    annotation, in: &context, plane: plane, width: width, height: height,
                    isSelected: annotation.id == model.selectedAnnotationID)
            }

            // Misura in corso: i punti già posati, e la spezzata che li unisce se sono più d'uno.
            if !pendingPointsMM.isEmpty {
                let projected = pendingPointsMM.map {
                    plane.pixelPosition(ofPatient: $0, pixelWidth: width, pixelHeight: height)
                }
                var path = Path()
                path.move(to: CGPoint(x: projected[0].x, y: projected[0].y))
                for point in projected.dropFirst() {
                    path.addLine(to: CGPoint(x: point.x, y: point.y))
                }
                context.stroke(
                    path, with: .color(Palette.accent.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                for point in projected {
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: point.x - 3, y: point.y - 3, width: 6, height: 6)),
                        with: .color(Palette.accent))
                }
                // Che cosa manca, accanto all'ultimo punto posato. Il testo lo decide la
                // sessione, che sa quale forma è in mano: una spezzata si chiude a comando e va
                // detto, una distanza a due punti no e dirlo sarebbe una bugia.
                if let hint = model.toolSession.progressHint {
                    context.draw(
                        Text(hint)
                            .font(Typography.label)
                            .foregroundStyle(Palette.textSecondary),
                        at: CGPoint(
                            x: projected[projected.count - 1].x + 6,
                            y: projected[projected.count - 1].y - 12),
                        anchor: .leading)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func resolvedPlane(size: CGSize) -> MPRPlane? {
        let source = explicitPlane ?? slot.flatMap { model.planes[$0] }
        guard let plane = source, size.width > 0, size.height > 0 else { return nil }
        return plane.matchingAspect(
            pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func draw(
        _ annotation: Annotation,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int,
        isSelected: Bool
    ) {
        let color = Color(hexString: annotation.metadata.colorHex) ?? Palette.accent

        // Un'annotazione tracciata su un'altra slice non si nasconde di colpo: sfuma. Farla
        // sparire renderebbe difficile ritrovarla, mostrarla piena la farebbe sembrare
        // appartenente alla slice corrente.
        let points = annotation.handlesMM.map {
            plane.pixelPosition(ofPatient: $0, pixelWidth: width, pixelHeight: height)
        }
        guard !points.isEmpty else { return }

        let meanDistance = points.map { abs($0.distanceMM) }.reduce(0, +) / Double(points.count)
        let tolerance = annotation.metadata.referencePlane?.visibilityToleranceMM ?? 2.0
        let opacity = max(0.0, min(1.0, 1.0 - meanDistance / max(tolerance * 4, 0.001)))
        guard opacity > 0.02 else { return }

        let lineWidth: CGFloat = isSelected ? 2 : 1
        let stroke = color.opacity(opacity)

        switch annotation {
        // I **valori** non si scrivono più qui: li colloca `LabelOverlay`, che li vede tutti
        // insieme e può quindi evitare che si sovrappongano. Qui restano le sole forme.
        case .distance:
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            path.addLine(to: CGPoint(x: points[1].x, y: points[1].y))
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
            drawHandles(points, in: &context, color: stroke)


        case .angle:
            guard points.count >= 3 else { return }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            path.addLine(to: CGPoint(x: points[1].x, y: points[1].y))
            path.addLine(to: CGPoint(x: points[2].x, y: points[2].y))
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
            drawHandles(points, in: &context, color: stroke)

        case .ellipseROI:
            guard points.count >= 3 else { return }
            let centre = CGPoint(x: points[0].x, y: points[0].y)
            let radiusX = abs(points[1].x - points[0].x)
            let radiusY = abs(points[2].y - points[0].y)
            let rect = CGRect(
                x: centre.x - radiusX, y: centre.y - radiusY,
                width: radiusX * 2, height: radiusY * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: lineWidth)

        case .sphereROI(let roi):
            let centre = CGPoint(x: points[0].x, y: points[0].y)
            // Il raggio apparente si riduce allontanandosi dal centro della sfera: è il raggio
            // della circonferenza di intersezione fra sfera e piano, non quello della sfera.
            let offset = abs(points[0].distanceMM)
            guard offset < roi.radiusMM else { return }
            let apparent = (roi.radiusMM * roi.radiusMM - offset * offset).squareRoot()
            let scale = pointsPerMillimetre(plane: plane, width: width)
            let radius = CGFloat(apparent * scale)
            let rect = CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: lineWidth)

        case .text(let note):
            drawLabel(
                note.text, at: CGPoint(x: points[0].x, y: points[0].y), in: &context,
                color: color, opacity: opacity)

        case .polyline(let measurement):
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            if measurement.isClosed { path.closeSubpath() }
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
            drawHandles(points, in: &context, color: stroke)

            // L'etichetta al baricentro dei vertici e non sull'ultimo: su un perimetro chiuso
            // l'ultimo lato è dove si è chiuso il giro, e mettere lì il numero lo fa sembrare la
            // misura di quel lato.

        case .lineAngle:
            guard points.count >= 4 else { return }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            path.addLine(to: CGPoint(x: points[1].x, y: points[1].y))
            path.move(to: CGPoint(x: points[2].x, y: points[2].y))
            path.addLine(to: CGPoint(x: points[3].x, y: points[3].y))
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
            drawHandles(points, in: &context, color: stroke)

            // Fra i due segmenti, non su uno dei due: l'angolo appartiene alla coppia, e
            // appoggiarlo a una delle due rette suggerirebbe che sia una sua proprietà.

        default:
            drawHandles(points, in: &context, color: stroke)
        }
    }

    private func pointsPerMillimetre(plane: MPRPlane, width: Int) -> Double {
        guard plane.widthMM > 0 else { return 1 }
        return Double(width) / plane.widthMM
    }

    private func drawHandles(
        _ points: [(x: Double, y: Double, distanceMM: Double)],
        in context: inout GraphicsContext,
        color: Color
    ) {
        for point in points {
            let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: 1)
        }
    }

    private func drawLabel(
        _ text: String,
        at point: CGPoint,
        in context: inout GraphicsContext,
        color: Color,
        opacity: Double
    ) {
        guard !text.isEmpty else { return }
        let resolved = context.resolve(
            Text(text)
                .font(Typography.numericSmall)
                .foregroundStyle(color.opacity(opacity)))
        let size = resolved.measure(in: CGSize(width: 400, height: 100))
        let origin = CGPoint(x: point.x + 8, y: point.y - size.height - 4)

        // Fondo semitrasparente: su un'immagine radiologica il testo chiaro sparisce appena
        // capita sopra dello smalto, che è la zona più bianca dell'immagine.
        let background = CGRect(
            x: origin.x - 3, y: origin.y - 2, width: size.width + 6, height: size.height + 4)
        context.fill(
            Path(roundedRect: background, cornerRadius: 3),
            with: .color(.black.opacity(0.55 * opacity)))
        context.draw(resolved, at: origin, anchor: .topLeading)
    }
}

// MARK: - Utilità

extension Color {
    /// Costruisce da una stringa `#RRGGBB`. `nil` se il formato non è quello.
    init?(hexString: String) {
        var trimmed = hexString.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { trimmed.removeFirst() }
        guard trimmed.count == 6, let value = UInt32(trimmed, radix: 16) else { return nil }
        self.init(hex: value)
    }
}
