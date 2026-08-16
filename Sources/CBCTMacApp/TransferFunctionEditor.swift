import DICOMCore
import SwiftUI
import VolumeKit

// Editor della transfer function.
//
// È il controllo che realizza il «rendering dei tessuti variabile», quindi sta in vista sotto
// il riquadro 3D e non in una finestra a parte: si regola guardando il risultato cambiare, e
// costringere l'utente a spostare lo sguardo altrove renderebbe l'operazione un tentativo alla
// cieca.
//
// Tre strati sovrapposti, come nei mockup: l'istogramma dei valori sullo sfondo, la curva di
// opacità con i punti trascinabili, e la fascia del gradiente risultante in basso.

struct TransferFunctionEditor: View {

    @Bindable var model: AppModel

    /// Intervallo di densità mostrato. Deve coincidere con quello che il raycaster usa per
    /// normalizzare la tabella, altrimenti la curva disegnata non corrisponde a quella
    /// applicata e regolarla diventa un indovinello.
    private let densityRange: ClosedRange<Double> = -1200...3600

    private let curveHeight: CGFloat = 72
    private let gradientHeight: CGFloat = 16

    @State private var draggingStopID: UUID?

    var body: some View {
        VStack(spacing: Metrics.spacingSmall) {
            presetPills

            VStack(spacing: 2) {
                curveArea
                gradientBar
            }
        }
        .padding(Metrics.spacing)
        .background(Palette.chrome.opacity(0.92))
    }

    // MARK: Preset

    private var presetPills: some View {
        HStack(spacing: Metrics.spacingSmall) {
            ForEach(TransferFunction.presets, id: \.name) { preset in
                let isActive = model.transferPresetName == preset.name
                Button {
                    model.applyTransferPreset(named: preset.name)
                } label: {
                    Text(preset.name)
                        .font(Typography.label)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            isActive ? Palette.accent.opacity(0.25) : Palette.chromeElevated,
                            in: .rect(cornerRadius: 5))
                        .foregroundStyle(isActive ? Palette.accent : Palette.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Curva

    private var curveArea: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    drawHistogram(&context, size: size)
                    drawCurve(&context, size: size)
                }
            }
            .contentShape(.rect)
            .gesture(dragGesture(in: geometry.size))
        }
        .frame(height: curveHeight)
        .background(Color.black.opacity(0.5), in: .rect(cornerRadius: 4))
    }

    private func drawHistogram(_ context: inout GraphicsContext, size: CGSize) {
        let bins = model.histogram
        guard bins.count > 1, let volume = model.volume else { return }

        // L'istogramma copre l'intervallo dei dati, l'editor quello fisso dei preset: le due
        // scale vanno allineate, altrimenti la curva sembra spostata rispetto ai picchi.
        let dataRange = volume.densityRange
        let span = densityRange.upperBound - densityRange.lowerBound
        guard span > 0 else { return }

        // Scala logaritmica: l'aria domina di due ordini di grandezza e in scala lineare
        // schiaccerebbe osso e smalto a una riga invisibile, che sono proprio i valori su cui
        // si lavora.
        let peak = bins.max() ?? 1
        let logPeak = Foundation.log(Double(peak) + 1)
        guard logPeak > 0 else { return }

        var path = Path()
        path.move(to: CGPoint(x: 0, y: size.height))

        for (index, count) in bins.enumerated() {
            let t = Double(index) / Double(bins.count - 1)
            let density = dataRange.lowerBound + (dataRange.upperBound - dataRange.lowerBound) * t
            let x = (density - densityRange.lowerBound) / span * Double(size.width)
            let height = Foundation.log(Double(count) + 1) / logPeak
            let y = Double(size.height) * (1 - height)
            path.addLine(to: CGPoint(x: x, y: y))
        }

        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()
        context.fill(path, with: .color(Palette.textSecondary.opacity(0.35)))
    }

    private func drawCurve(_ context: inout GraphicsContext, size: CGSize) {
        let stops = sortedStops
        guard stops.count >= 2 else { return }

        var path = Path()
        for (index, stop) in stops.enumerated() {
            let point = position(of: stop, in: size)
            if index == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }
        context.stroke(path, with: .color(Palette.textPrimary.opacity(0.9)), lineWidth: 1.5)

        for stop in stops {
            let point = position(of: stop, in: size)
            let isDragging = stop.id == draggingStopID
            let radius: CGFloat = isDragging ? 6 : 4.5
            let rect = CGRect(
                x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(Palette.textPrimary))
            context.stroke(
                Path(ellipseIn: rect), with: .color(Palette.accent),
                lineWidth: isDragging ? 2 : 1)
        }
    }

    // MARK: Fascia del gradiente

    private var gradientBar: some View {
        Canvas { context, size in
            // Si campiona la rampa a intervalli regolari e si disegna a strisce sottili: è più
            // fedele di un `LinearGradient` fra i punti di controllo, perché mostra anche il
            // contributo dell'opacità e non solo il colore.
            let steps = max(Int(size.width), 1)
            for index in 0..<steps {
                let t = Double(index) / Double(max(steps - 1, 1))
                let density =
                    densityRange.lowerBound
                    + (densityRange.upperBound - densityRange.lowerBound) * t
                let (color, opacity) = model.transferFunction.sample(at: density)
                let alpha = min(max(opacity * model.transferFunction.opacityScale, 0), 1)

                let swatch = Color(
                    .sRGB, red: color.red, green: color.green, blue: color.blue, opacity: 1)
                let rect = CGRect(x: CGFloat(index), y: 0, width: 1.2, height: size.height)
                // Il fondo nero mostra l'opacità: dove la rampa è trasparente resta scuro.
                context.fill(Path(rect), with: .color(swatch.opacity(alpha)))
            }
        }
        .frame(height: gradientHeight)
        .background(Color.black, in: .rect(cornerRadius: 3))
    }

    // MARK: Interazione

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if draggingStopID == nil {
                    draggingStopID = nearestStop(to: value.startLocation, in: size)?.id
                }
                guard let id = draggingStopID else { return }
                move(stopID: id, to: value.location, in: size)
            }
            .onEnded { _ in
                draggingStopID = nil
            }
    }

    private func nearestStop(to point: CGPoint, in size: CGSize) -> TransferStop? {
        var best: TransferStop?
        var bestDistance = Double.infinity
        for stop in sortedStops {
            let position = position(of: stop, in: size)
            let dx = Double(position.x - point.x)
            let dy = Double(position.y - point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = stop
            }
        }
        // Oltre venti punti si considera un clic a vuoto: trascinare il punto più vicino
        // ovunque si prema renderebbe impossibile guardare la curva senza modificarla.
        return bestDistance <= 20 ? best : nil
    }

    private func move(stopID: UUID, to point: CGPoint, in size: CGSize) {
        guard let index = model.transferFunction.stops.firstIndex(where: { $0.id == stopID }),
            size.width > 0, size.height > 0
        else { return }

        let span = densityRange.upperBound - densityRange.lowerBound
        let density =
            densityRange.lowerBound + Double(point.x / size.width) * span
        let opacity = 1.0 - Double(point.y / size.height)

        model.transferFunction.stops[index].density = min(
            max(density, densityRange.lowerBound), densityRange.upperBound)
        model.transferFunction.stops[index].opacity = min(max(opacity, 0), 1)
        // Toccando un punto la rampa non è più un preset: dirlo evita che l'utente creda di
        // avere ancora «Osso» quando ha ormai un'altra cosa.
        model.transferPresetName = "Personalizzato"
    }

    // MARK: Utilità

    private var sortedStops: [TransferStop] {
        model.transferFunction.stops.sorted { $0.density < $1.density }
    }

    private func position(of stop: TransferStop, in size: CGSize) -> CGPoint {
        let span = densityRange.upperBound - densityRange.lowerBound
        guard span > 0 else { return .zero }
        let x = (stop.density - densityRange.lowerBound) / span * Double(size.width)
        let y = (1 - stop.opacity) * Double(size.height)
        return CGPoint(x: x, y: y)
    }
}
