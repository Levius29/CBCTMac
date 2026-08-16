import DICOMCore
import DentalKit
import Metal
import MetalKit
import SwiftUI
import VolumeKit

// Spazio di lavoro panoramico: panorex in alto, sezioni trasversali sotto, assiale con la
// curva modificabile a lato.
//
// Le sezioni trasversali riusano `MPRViewportView` senza una riga di codice di rendering nuova:
// ogni sezione è una `MPRPlane` con gli assi ricavati dalla spline. È il dividendo di aver
// scritto il kernel MPR attorno a un piano arbitrario invece che ai tre assi anatomici.

// MARK: - Vista del panorex

struct PanoramicViewportView: NSViewRepresentable {

    let layout: PanoramicLayout
    let volumeTexture: VolumeTexture?
    let renderer: PanoramicRenderer?
    let windowLevel: WindowLevel

    var onHoverArcLength: (Double?) -> Void = { _ in }
    var onClickArcLength: (Double) -> Void = { _ in }
    var onDrawableSize: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.delegate = context.coordinator
        context.coordinator.configure(device: view.device)
        context.coordinator.onDrawableSize = onDrawableSize
        attachHandlers(to: view)
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        context.coordinator.layout = layout
        context.coordinator.volumeTexture = volumeTexture
        context.coordinator.renderer = renderer
        context.coordinator.windowLevel = windowLevel
        context.coordinator.onDrawableSize = onDrawableSize
        attachHandlers(to: view)
        view.setNeedsDisplay(view.bounds)
    }

    private func attachHandlers(to view: InteractiveMetalView) {
        let totalLength = layout.curve.lengthMM

        // La coordinata orizzontale del panorex **è** la distanza d'arco, per costruzione: è la
        // proprietà che rende leggibile una misura orizzontale su questa immagine, e dipende
        // interamente dal fatto che i campioni siano equidistanti in lunghezza d'arco.
        //
        // `[weak view]` non è pedanteria: la vista possiede queste chiusure, e catturandola
        // forte si formerebbe un ciclo che tiene in vita vista e texture per tutta la sessione.
        view.onHover = { [weak view] point in
            guard let view, let point, view.drawableSize.width > 0 else {
                onHoverArcLength(nil)
                return
            }
            let fraction = Double(point.x) / Double(view.drawableSize.width)
            onHoverArcLength(min(max(fraction, 0), 1) * totalLength)
        }
        view.onClick = { [weak view] point in
            guard let view, view.drawableSize.width > 0 else { return }
            let fraction = Double(point.x) / Double(view.drawableSize.width)
            onClickArcLength(min(max(fraction, 0), 1) * totalLength)
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {

        var layout: PanoramicLayout?
        var volumeTexture: VolumeTexture?
        var renderer: PanoramicRenderer?
        var windowLevel: WindowLevel = .bone
        var onDrawableSize: ((CGSize) -> Void)?

        private var commandQueue: MTLCommandQueue?
        private var lastSize: CGSize = .zero

        func configure(device: MTLDevice?) {
            guard let device else { return }
            commandQueue = device.makeCommandQueue()
            commandQueue?.label = "Panorex"
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated { report(size) }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(in: view) }
        }

        private func report(_ size: CGSize) {
            guard size != lastSize else { return }
            lastSize = size
            onDrawableSize?(size)
        }

        private func render(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                let commandQueue,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            let target = drawable.texture
            report(CGSize(width: target.width, height: target.height))

            if let renderer, let volumeTexture, let layout, layout.curve.isUsable,
                target.width > 0, target.height > 0
            {
                do {
                    try renderer.encode(
                        layout: layout,
                        volume: volumeTexture,
                        windowLevel: windowLevel,
                        into: target,
                        commandBuffer: commandBuffer)
                } catch {
                    clear(target, commandBuffer: commandBuffer)
                }
            } else {
                clear(target, commandBuffer: commandBuffer)
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }

        private func clear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 1)
            commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)?.endEncoding()
        }
    }
}

// MARK: - Spazio di lavoro

struct PanoramicWorkspace: View {

    @Bindable var model: AppModel

    @State private var panoramicPixelSize: CGSize = .zero
    @State private var hoverArcLengthMM: Double?

    /// Sezioni mostrate contemporaneamente nella griglia.
    private let visibleSectionCount = 10

    var body: some View {
        VStack(spacing: Metrics.viewportGap) {
            HStack(spacing: Metrics.viewportGap) {
                axialWithArch
                    .frame(width: 300)
                panoramicPanel
            }
            .frame(maxHeight: .infinity)

            crossSectionStrip
                .frame(height: 240)
        }
        .padding(Metrics.viewportGap)
        .background(Palette.viewportBackground)
    }

    // MARK: Assiale con la curva

    private var axialWithArch: some View {
        ViewportContainer(model: model, slot: .axial)
            .overlay(alignment: .bottom) {
                HStack(spacing: Metrics.spacing) {
                    Toggle(isOn: $model.isEditingArch) {
                        Label("Modifica arcata", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)

                    Button {
                        model.resetArchCurve()
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                    .help("Ripristina l'arcata predefinita")
                }
                .padding(Metrics.spacing)
            }
    }

    // MARK: Panorex

    private var panoramicPanel: some View {
        ZStack {
            PanoramicViewportView(
                layout: model.panoramicLayout,
                volumeTexture: model.volumeTexture,
                renderer: model.panoramicRenderer,
                windowLevel: model.windowLevel,
                onHoverArcLength: { hoverArcLengthMM = $0 },
                onClickArcLength: { arcLength in
                    // Un clic sul panorex porta la griglia alla sezione corrispondente: è il
                    // modo naturale di passare dalla panoramica al punto che interessa.
                    guard let section = model.crossSectionLayout.section(
                        nearestToArcLength: arcLength, in: model.crossSections)
                    else { return }
                    model.crossSectionPageStart = max(
                        0, section.index - visibleSectionCount / 2)
                },
                onDrawableSize: { panoramicPixelSize = $0 }
            )

            // Righello della posizione lungo l'arcata sotto il puntatore.
            if let arcLength = hoverArcLengthMM, model.archCurve.isUsable {
                GeometryReader { geometry in
                    let fraction = arcLength / max(model.archCurve.lengthMM, 1)
                    let x = fraction * geometry.size.width
                    Rectangle()
                        .fill(Palette.accent.opacity(0.7))
                        .frame(width: 1)
                        .position(x: x, y: geometry.size.height / 2)
                }
                .allowsHitTesting(false)
            }

            VStack {
                HStack {
                    Text("PANOREX")
                        .font(Typography.viewportLabel)
                        .foregroundStyle(Palette.accent)
                    Spacer()
                    if let arcLength = hoverArcLengthMM {
                        Text(
                            String(format: "%.1f mm", arcLength)
                                .replacingOccurrences(of: ".", with: ",")
                        )
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.textSecondary)
                    }
                }
                Spacer()
                HStack {
                    Text(
                        String(format: "Arcata %.0f mm", model.archCurve.lengthMM)
                    )
                    Spacer()
                    Text(
                        String(format: "Spessore %.0f mm", model.panoramicSlabThicknessMM)
                    )
                }
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            }
            .padding(Metrics.spacing)
            .allowsHitTesting(false)
        }
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.accent).frame(height: Metrics.viewportBorderWidth)
        }
    }

    // MARK: Griglia delle sezioni

    private var crossSectionStrip: some View {
        VStack(spacing: Metrics.spacingSmall) {
            HStack(spacing: Metrics.spacing) {
                Text("SEZIONI TRASVERSALI")
                    .font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textSecondary)

                Text(
                    String(format: "ogni %.1f mm", model.crossSectionIntervalMM)
                        .replacingOccurrences(of: ".", with: ",")
                )
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)

                Spacer()

                Button {
                    model.crossSectionPageStart = max(
                        0, model.crossSectionPageStart - visibleSectionCount)
                } label: { Image(systemName: "chevron.left") }
                    .disabled(model.crossSectionPageStart == 0)

                Text(pageLabel)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 90)

                Button {
                    model.crossSectionPageStart = min(
                        max(0, model.crossSections.count - visibleSectionCount),
                        model.crossSectionPageStart + visibleSectionCount)
                } label: { Image(systemName: "chevron.right") }
                    .disabled(
                        model.crossSectionPageStart + visibleSectionCount
                            >= model.crossSections.count)
            }
            .controlSize(.small)
            .padding(.horizontal, Metrics.spacing)

            if model.crossSections.isEmpty {
                Text("Nessuna sezione: definisci prima la curva dell'arcata.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: Metrics.viewportGap) {
                    ForEach(visibleSections) { section in
                        CrossSectionCell(model: model, section: section)
                    }
                }
            }
        }
        .background(Palette.chrome)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
    }

    private var visibleSections: [CrossSection] {
        let start = min(model.crossSectionPageStart, max(0, model.crossSections.count - 1))
        let end = min(start + visibleSectionCount, model.crossSections.count)
        guard start < end else { return [] }
        return Array(model.crossSections[start..<end])
    }

    private var pageLabel: String {
        guard !model.crossSections.isEmpty else { return "—" }
        let start = model.crossSectionPageStart + 1
        let end = min(
            model.crossSectionPageStart + visibleSectionCount, model.crossSections.count)
        return "\(start)–\(end) di \(model.crossSections.count)"
    }
}

// MARK: - Una sezione

struct CrossSectionCell: View {

    let model: AppModel
    let section: CrossSection

    var body: some View {
        VStack(spacing: 2) {
            MPRViewportView(
                plane: section.plane,
                volumeTexture: model.volumeTexture,
                renderer: model.mprRenderer,
                windowLevel: model.windowLevel
            )
            .clipShape(.rect(cornerRadius: 3))

            Text(section.label)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Curva sull'assiale

/// Disegna e consente di modificare la curva dell'arcata sopra la vista assiale.
struct ArchCurveOverlay: View {

    @Bindable var model: AppModel
    let plane: MPRPlane?
    let pixelSize: CGSize

    @State private var draggingIndex: Int?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    guard let plane = adjusted(for: size) else { return }
                    drawCurve(&context, plane: plane, size: size)
                }
                .allowsHitTesting(false)

                if model.isEditingArch {
                    Color.clear
                        .contentShape(.rect)
                        .gesture(dragGesture(in: geometry.size))
                }
            }
        }
    }

    private func adjusted(for size: CGSize) -> MPRPlane? {
        guard let plane, size.width > 0, size.height > 0 else { return nil }
        return plane.matchingAspect(pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func drawCurve(_ context: inout GraphicsContext, plane: MPRPlane, size: CGSize) {
        let curve = model.archCurve
        guard curve.isUsable else { return }

        let width = Int(size.width)
        let height = Int(size.height)

        // Si disegna la spline ricampionata, non la spezzata fra i punti di controllo:
        // altrimenti l'utente vedrebbe una linea diversa da quella che genera il panorex.
        let samples = curve.resampled(count: 160)
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let projected = plane.pixelPosition(
                ofPatient: sample.positionMM, pixelWidth: width, pixelHeight: height)
            let point = CGPoint(x: projected.x, y: projected.y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        context.stroke(path, with: .color(Palette.accent.opacity(0.9)), lineWidth: 2)

        guard model.isEditingArch else { return }

        for (index, control) in curve.controlPointsMM.enumerated() {
            let projected = plane.pixelPosition(
                ofPatient: control, pixelWidth: width, pixelHeight: height)
            let radius: CGFloat = draggingIndex == index ? 7 : 5
            let rect = CGRect(
                x: projected.x - radius, y: projected.y - radius,
                width: radius * 2, height: radius * 2)
            context.fill(Path(ellipseIn: rect), with: .color(Palette.accent))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
        }
    }

    // MARK: Trascinamento

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plane = adjusted(for: size) else { return }
                let width = Int(size.width)
                let height = Int(size.height)

                if draggingIndex == nil {
                    draggingIndex = nearestControl(
                        to: value.startLocation, plane: plane, width: width, height: height)
                }
                guard let index = draggingIndex else { return }

                let patient = plane.patientPoint(
                    atPixelX: Double(value.location.x),
                    y: Double(value.location.y),
                    pixelWidth: width,
                    pixelHeight: height)

                guard model.archCurve.controlPointsMM.indices.contains(index) else { return }
                model.archCurve.controlPointsMM[index] = patient
            }
            .onEnded { _ in
                draggingIndex = nil
                // Le sezioni si ricostruiscono al rilascio e non durante il trascinamento:
                // ricampionare la spline e rigenerare cento piani a ogni movimento del mouse
                // renderebbe il gesto viscoso.
                model.rebuildCrossSections()
            }
    }

    private func nearestControl(
        to point: CGPoint, plane: MPRPlane, width: Int, height: Int
    ) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, control) in model.archCurve.controlPointsMM.enumerated() {
            let projected = plane.pixelPosition(
                ofPatient: control, pixelWidth: width, pixelHeight: height)
            let dx = projected.x - Double(point.x)
            let dy = projected.y - Double(point.y)
            let distance = (dx * dx + dy * dy).squareRoot()
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return bestDistance <= 24 ? best : nil
    }
}
