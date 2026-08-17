import DICOMCore
import MeasureKit
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
            VStack {
                HStack(alignment: .top) {
                    Text(slot.localizedName.uppercased())
                        .font(Typography.viewportLabel)
                        .foregroundStyle(slot.accentColor)
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
                    if slot.anatomicalPlane != nil {
                        VStack(alignment: .leading, spacing: 2) {
                            if let indicator = model.sliceIndicator(for: slot) {
                                Text("\(indicator.index) / \(indicator.count)")
                            }
                            if let position = model.positionLabel(for: slot) {
                                Text(position)
                            }
                        }
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                    }
                    Spacer()
                    ScaleBar(millimetresPerPoint: millimetresPerPoint)
                }
            }
            .padding(Metrics.spacing)
        }
        .allowsHitTesting(false)
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

// MARK: - Mirino

struct CrosshairOverlay: View {

    let model: AppModel
    let slot: ViewportSlot
    let pointSize: CGSize
    let pixelSize: CGSize

    /// Spazio lasciato all'incrocio, in punti. Senza, le due linee coprirebbero esattamente il
    /// voxel che l'utente sta puntando, che è l'unico che gli interessa vedere.
    private let centreGap: CGFloat = 12

    var body: some View {
        Canvas { context, size in
            guard let position = crosshairPoint(in: size) else { return }

            let horizontal = horizontalLineColor
            let vertical = verticalLineColor

            // Verticale, spezzata all'incrocio.
            var verticalPath = Path()
            verticalPath.move(to: CGPoint(x: position.x, y: 0))
            verticalPath.addLine(to: CGPoint(x: position.x, y: position.y - centreGap))
            verticalPath.move(to: CGPoint(x: position.x, y: position.y + centreGap))
            verticalPath.addLine(to: CGPoint(x: position.x, y: size.height))
            context.stroke(verticalPath, with: .color(vertical.opacity(0.85)), lineWidth: 1)

            // Orizzontale, idem.
            var horizontalPath = Path()
            horizontalPath.move(to: CGPoint(x: 0, y: position.y))
            horizontalPath.addLine(to: CGPoint(x: position.x - centreGap, y: position.y))
            horizontalPath.move(to: CGPoint(x: position.x + centreGap, y: position.y))
            horizontalPath.addLine(to: CGPoint(x: size.width, y: position.y))
            context.stroke(horizontalPath, with: .color(horizontal.opacity(0.85)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    /// Posizione del mirino in punti.
    private func crosshairPoint(in size: CGSize) -> CGPoint? {
        guard let plane = model.planes[slot], size.width > 0, size.height > 0 else { return nil }
        let width = Int(size.width)
        let height = Int(size.height)
        let adjusted = plane.matchingAspect(pixelWidth: width, pixelHeight: height)
        let projected = adjusted.pixelPosition(
            ofPatient: model.crosshairMM, pixelWidth: width, pixelHeight: height)
        return CGPoint(x: projected.x, y: projected.y)
    }

    // Ogni linea porta il colore **del piano che rappresenta**, non del riquadro che la ospita.
    // Nella vista assiale la verticale è una sezione sagittale, quindi gialla; l'orizzontale è
    // coronale, quindi verde. È la convenzione che permette di capire a colpo d'occhio dove si
    // sta guardando senza leggere etichette.

    private var verticalLineColor: Color {
        switch slot.anatomicalPlane {
        case .axial: return Palette.sagittal    // x costante
        case .coronal: return Palette.sagittal  // x costante
        case .sagittal: return Palette.coronal  // y costante
        case nil: return Palette.accent
        }
    }

    private var horizontalLineColor: Color {
        switch slot.anatomicalPlane {
        case .axial: return Palette.coronal   // y costante
        case .coronal: return Palette.axial   // z costante
        case .sagittal: return Palette.axial  // z costante
        case nil: return Palette.accent
        }
    }
}

// MARK: - Annotazioni

struct AnnotationOverlay: View {

    let model: AppModel
    let slot: ViewportSlot
    let pointSize: CGSize
    let pixelSize: CGSize
    let pendingStartMM: Vec3?

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

            // Estremo in attesa: dà un riscontro immediato che il primo clic è stato registrato.
            if let start = pendingStartMM {
                let p = plane.pixelPosition(ofPatient: start, pixelWidth: width, pixelHeight: height)
                let dot = Path(
                    ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
                context.fill(dot, with: .color(Palette.accent))
            }
        }
        .allowsHitTesting(false)
    }

    private func resolvedPlane(size: CGSize) -> MPRPlane? {
        guard let plane = model.planes[slot], size.width > 0, size.height > 0 else { return nil }
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
        case .distance(let measurement):
            guard points.count >= 2 else { return }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            path.addLine(to: CGPoint(x: points[1].x, y: points[1].y))
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
            drawHandles(points, in: &context, color: stroke)

            let midpoint = CGPoint(
                x: (points[0].x + points[1].x) / 2,
                y: (points[0].y + points[1].y) / 2)
            drawLabel(
                measurement.formattedValue, at: midpoint, in: &context, color: color,
                opacity: opacity)

        case .angle(let measurement):
            guard points.count >= 3 else { return }
            var path = Path()
            path.move(to: CGPoint(x: points[0].x, y: points[0].y))
            path.addLine(to: CGPoint(x: points[1].x, y: points[1].y))
            path.addLine(to: CGPoint(x: points[2].x, y: points[2].y))
            context.stroke(path, with: .color(stroke), lineWidth: lineWidth)
            drawHandles(points, in: &context, color: stroke)
            drawLabel(
                measurement.formattedValue,
                at: CGPoint(x: points[1].x, y: points[1].y),
                in: &context, color: color, opacity: opacity)

        case .ellipseROI(let roi):
            guard points.count >= 3 else { return }
            let centre = CGPoint(x: points[0].x, y: points[0].y)
            let radiusX = abs(points[1].x - points[0].x)
            let radiusY = abs(points[2].y - points[0].y)
            let rect = CGRect(
                x: centre.x - radiusX, y: centre.y - radiusY,
                width: radiusX * 2, height: radiusY * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: lineWidth)
            let text = model.roiStatistics[roi.id]?.summary ?? roi.formattedValue
            drawLabel(text, at: centre, in: &context, color: color, opacity: opacity)

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
            let text = model.roiStatistics[roi.id]?.summary ?? roi.formattedValue
            drawLabel(text, at: centre, in: &context, color: color, opacity: opacity)

        case .text(let note):
            drawLabel(
                note.text, at: CGPoint(x: points[0].x, y: points[0].y), in: &context,
                color: color, opacity: opacity)

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
