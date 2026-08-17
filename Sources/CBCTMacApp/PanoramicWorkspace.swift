import AppKit
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
    let windowLevel: DensityWindow

    var onHoverArcLength: (Double?) -> Void = { _ in }
    var onClickArcLength: (Double) -> Void = { _ in }
    var onDrawableSize: (CGSize) -> Void = { _ in }

    /// Scorrimento lungo l'arcata, in millimetri di lunghezza d'arco.
    var onScrollArc: (Double) -> Void = { _ in }
    /// Spostamento della quota verticale, in millimetri.
    var onScrollVertical: (Double) -> Void = { _ in }
    /// Ingrandimento: fattore e pixel orizzontale su cui ancorarlo.
    var onZoom: (Double, Double, Int) -> Void = { _, _, _ in }

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
        let layout = self.layout

        // La coordinata orizzontale del panorex **è** la lunghezza d'arco, per costruzione: è la
        // proprietà che rende leggibile una misura orizzontale su questa immagine, e dipende
        // interamente dal fatto che i campioni siano equidistanti in lunghezza d'arco.
        //
        // La conversione passa da `layout.arcLengthMM(atPixelX:pixelWidth:)` e **non** da
        // `frazione × lunghezzaTotale`: quella formula vale solo a ingrandimento 1, quando la
        // finestra visibile è l'arcata intera. Ingranditi, il pixel 0 non sta più all'inizio della
        // curva, e usare la frazione darebbe una posizione sbagliata — il clic porterebbe le altre
        // viste sul dente accanto.
        //
        // `[weak view]` non è pedanteria: la vista possiede queste chiusure, e catturandola
        // forte si formerebbe un ciclo che tiene in vita vista e texture per tutta la sessione.
        view.onHover = { [weak view] point in
            guard let view, let point, view.drawableSize.width > 0 else {
                onHoverArcLength(nil)
                return
            }
            onHoverArcLength(
                layout.arcLengthMM(
                    atPixelX: Double(point.x), pixelWidth: Int(view.drawableSize.width)))
        }
        view.onClick = { [weak view] point in
            guard let view, view.drawableSize.width > 0 else { return }
            onClickArcLength(
                layout.arcLengthMM(
                    atPixelX: Double(point.x), pixelWidth: Int(view.drawableSize.width)))
        }

        // La rotella percorre l'arcata. È il gesto che l'immagine suggerisce da sé: un panorex è
        // una striscia lunga, e una striscia si scorre.
        view.onScroll = { [weak view] steps in
            guard let view, view.drawableSize.width > 0 else { return }
            let millimetresPerPixel = layout.millimetresPerPixel(
                pixelWidth: Int(view.drawableSize.width))
            // Otto pixel per passo: la stessa quantità di immagine che scorre in una lista, così
            // il gesto ha il "peso" a cui la mano è abituata.
            onScrollArc(steps * 8 * millimetresPerPixel)
        }

        // Trascinamento: orizzontale scorre lungo l'arcata, verticale sposta la quota. Un solo
        // gesto per entrambe le direzioni, come si sposta il contenuto di una finestra.
        let drag: (CGSize) -> Void = { [weak view] delta in
            guard let view, view.drawableSize.width > 0 else { return }
            let millimetresPerPixel = layout.millimetresPerPixel(
                pixelWidth: Int(view.drawableSize.width))
            // Segno invertito: trascinando verso sinistra il contenuto va a sinistra, quindi la
            // finestra avanza a destra. È la convenzione di ogni vista che si trascina.
            onScrollArc(-Double(delta.width) * millimetresPerPixel)
            // In verticale lo schermo scende verso i piedi, quindi trascinare in basso alza la
            // quota di lavoro.
            onScrollVertical(Double(delta.height) * millimetresPerPixel)
        }
        view.onDrag = { _, delta in drag(delta) }
        view.onPan = drag

        view.onZoom = { [weak view] factor, anchor in
            guard let view, view.drawableSize.width > 0 else { return }
            onZoom(factor, Double(anchor.x), Int(view.drawableSize.width))
        }
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {

        var layout: PanoramicLayout?
        var volumeTexture: VolumeTexture?
        var renderer: PanoramicRenderer?
        var windowLevel: DensityWindow = .bone
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
                VStack(spacing: Metrics.spacingSmall) {
                    if model.isEditingArch, !model.archCurve.isUsable {
                        // Il messaggio compare solo quando serve, cioè quando non c'è ancora una
                        // curva e non è ovvio che si debba cliccare.
                        Text("Clicca sull'assiale per posare i punti dell'arcata")
                            .font(Typography.label)
                            .foregroundStyle(Palette.textPrimary)
                            .padding(.horizontal, Metrics.spacing)
                            .padding(.vertical, 3)
                            .background(Palette.chrome.opacity(0.9), in: .capsule)
                    }

                    HStack(spacing: Metrics.spacing) {
                        // Scelta dell'arcata. Le due curve sono indipendenti: passando da una
                        // all'altra cambia anche la quota su cui si centrano panorex e sezioni.
                        Picker("", selection: $model.activeArch) {
                            ForEach(DentalArch.allCases) { arch in
                                Text(arch.shortName).tag(arch)
                            }
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .fixedSize()
                        .help("Arcata su cui lavorare: le due curve sono indipendenti")

                        Toggle(isOn: $model.isEditingArch) {
                            Label(
                                "Disegna",
                                systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help("Clic per posare un punto · trascina per spostarlo · ⌥ clic per cancellarlo")

                        Button {
                            model.suggestArchCurve()
                        } label: {
                            Image(systemName: "wand.and.stars")
                        }
                        .controlSize(.small)
                        .help("Proponi una parabola alla quota che stai guardando, da correggere")

                        Button {
                            model.flattenActiveArchCurve()
                        } label: {
                            Image(systemName: "arrow.down.to.line.compact")
                        }
                        .controlSize(.small)
                        .disabled(!model.archCurve.isUsable)
                        .help("Porta tutti i punti alla loro quota media")

                        Button {
                            model.clearActiveArchCurve()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .controlSize(.small)
                        .disabled(model.archCurve.controlPointsMM.isEmpty)
                        .help("Svuota la curva di questa arcata")

                        if model.archCurve.isUsable {
                            Text("\(model.archCurve.controlPointsMM.count) punti")
                                .font(Typography.numericSmall)
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
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
                onDrawableSize: { panoramicPixelSize = $0 },
                onScrollArc: { model.scrollPanoramic(byArcMM: $0) },
                onScrollVertical: { model.movePanoramicVertical(byMM: $0) },
                onZoom: { factor, x, width in
                    model.zoomPanoramic(by: factor, atPixelX: x, pixelWidth: width)
                }
            )

            // Righello della posizione lungo l'arcata sotto il puntatore.
            //
            // La frazione si calcola sulla **finestra visibile**, non sulla lunghezza totale:
            // ingranditi le due cose divergono, e il righello finirebbe altrove rispetto al
            // cursore che dovrebbe seguire.
            if let arcLength = hoverArcLengthMM, model.archCurve.isUsable {
                GeometryReader { geometry in
                    let range = model.panoramicLayout.visibleArcRangeMM
                    let span = max(range.upperBound - range.lowerBound, 1e-6)
                    let fraction = min(max((arcLength - range.lowerBound) / span, 0), 1)
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
                    if model.panoramicZoom > 1.001 {
                        // Ingranditi, la lunghezza totale non basta a orientarsi: serve sapere
                        // quale tratto si sta guardando.
                        let range = model.panoramicLayout.visibleArcRangeMM
                        Text(
                            String(
                                format: "· %.0f–%.0f mm · %.1f×",
                                range.lowerBound, range.upperBound, model.panoramicZoom)
                        )
                        .foregroundStyle(Palette.accent)
                    }
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
        .overlay(alignment: .topTrailing) {
            // Una via di ritorno all'arcata intera, come nei riquadri MPR: scorrendo e
            // ingrandendo si finisce per perdersi, e senza un ritorno l'unico rimedio sarebbe
            // riaprire lo studio.
            if model.panoramicZoom > 1.001 {
                Button {
                    model.resetPanoramicView()
                } label: {
                    Image(systemName: "viewfinder")
                        .font(.system(size: 10, weight: .medium))
                        .frame(width: 18, height: 18)
                        .background(Palette.chrome.opacity(0.75), in: .rect(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Torna all'arcata intera")
                .padding(Metrics.spacingSmall)
            }
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
    /// Vero quando il gesto in corso ha superato la soglia oltre cui è un trascinamento.
    @State private var didDrag = false
    /// Vero dopo la prima notifica del gesto: la presa si cerca una volta sola, alla pressione.
    @State private var hasBegun = false

    /// La curva si modifica sia con lo strumento apposito sia con l'interruttore del workspace
    /// panoramico. Due vie allo stesso stato, perché si arriva a volerla correggere da entrambi i
    /// contesti.
    private var isEditable: Bool {
        model.isEditingArch || model.activeTool == .archCurve
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Canvas { context, size in
                    guard let plane = adjusted(for: size) else { return }
                    drawCurve(&context, plane: plane, size: size)
                }
                .allowsHitTesting(false)

                if isEditable {
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
        let width = Int(size.width)
        let height = Int(size.height)

        func project(_ pointMM: Vec3) -> CGPoint {
            let projected = plane.pixelPosition(
                ofPatient: pointMM, pixelWidth: width, pixelHeight: height)
            return CGPoint(x: projected.x, y: projected.y)
        }

        // Si disegna la spline ricampionata, non la spezzata fra i punti di controllo:
        // altrimenti l'utente vedrebbe una linea diversa da quella che genera il panorex.
        if curve.isUsable {
            let samples = curve.resampled(count: 160)
            var path = Path()
            for (index, sample) in samples.enumerated() {
                let point = project(sample.positionMM)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Palette.accent.opacity(0.9)), lineWidth: 2)
        } else if curve.controlPointsMM.count == 1 {
            // Un punto solo non è una curva, ma va mostrato: altrimenti il primo clic sembra non
            // aver fatto nulla.
            let point = project(curve.controlPointsMM[0])
            context.stroke(
                Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)),
                with: .color(Palette.accent.opacity(0.5)),
                lineWidth: 1)
        }

        guard isEditable else { return }

        for (index, control) in curve.controlPointsMM.enumerated() {
            let point = project(control)
            let isSelected = model.selectedArchPointIndex == index
            let radius: CGFloat = draggingIndex == index ? 7 : (isSelected ? 6 : 5)
            let rect = CGRect(
                x: point.x - radius, y: point.y - radius,
                width: radius * 2, height: radius * 2)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(isSelected ? Palette.warning : Palette.accent))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1.5)
        }

        // Il verso di percorrenza, che decide da quale capo comincia il panorex: senza indicarlo,
        // un'immagine speculare rispetto all'attesa sembra un difetto invece che una conseguenza
        // dell'ordine in cui sono stati posati i punti.
        if curve.isUsable, let first = curve.controlPointsMM.first {
            let point = project(first)
            context.draw(
                Text("1").font(Typography.numericSmall).foregroundStyle(Palette.textPrimary),
                at: CGPoint(x: point.x + 10, y: point.y - 10))
        }
    }

    // MARK: Trascinamento

    /// Un solo gesto per tre azioni, distinte da ciò che l'utente fa e non da modalità da
    /// scegliere prima:
    ///
    /// - premere e trascinare **su un punto** lo sposta;
    /// - cliccare **nel vuoto** posa un punto nuovo, nella posizione giusta dell'ordine di
    ///   percorrenza — non in coda, vedi `ArchCurve.addControlPoint`;
    /// - ⌥ clic **su un punto** lo cancella.
    ///
    /// La presa si cerca una volta sola, alla pressione, e non a ogni notifica: cercarla ogni
    /// volta farebbe "saltare" la presa a un punto vicino nel mezzo di un trascinamento.
    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let plane = adjusted(for: size) else { return }
                let width = Int(size.width)
                let height = Int(size.height)

                if !hasBegun {
                    hasBegun = true
                    draggingIndex = nearestControl(
                        to: value.startLocation, plane: plane, width: width, height: height)
                }

                if abs(value.translation.width) + abs(value.translation.height) > 3 {
                    didDrag = true
                }

                guard didDrag, let index = draggingIndex else { return }
                let patient = plane.patientPoint(
                    atPixelX: Double(value.location.x),
                    y: Double(value.location.y),
                    pixelWidth: width,
                    pixelHeight: height)
                model.moveArchPoint(at: index, to: patient)
            }
            .onEnded { value in
                let index = draggingIndex
                let dragged = didDrag
                defer {
                    draggingIndex = nil
                    didDrag = false
                    hasBegun = false
                }

                if dragged {
                    // Le sezioni si ricostruiscono al rilascio e non durante il trascinamento:
                    // ricampionare la spline e rigenerare cento piani a ogni movimento del mouse
                    // renderebbe il gesto viscoso.
                    model.rebuildCrossSections()
                    return
                }

                // Il modificatore si legge da `NSEvent` perché un `DragGesture` di SwiftUI non lo
                // riporta. È la via diretta su macOS e non ha alternative pulite.
                let optionHeld = NSEvent.modifierFlags.contains(.option)

                if let index {
                    if optionHeld {
                        model.removeArchPoint(at: index)
                    } else {
                        model.selectedArchPointIndex = index
                    }
                    return
                }

                // ⌥ nel vuoto non fa nulla: cancellare è un'azione che deve colpire un bersaglio.
                guard !optionHeld, let plane = adjusted(for: size) else { return }
                let patient = plane.patientPoint(
                    atPixelX: Double(value.location.x),
                    y: Double(value.location.y),
                    pixelWidth: Int(size.width),
                    pixelHeight: Int(size.height))
                model.addArchPoint(at: patient)
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
        return bestDistance <= AppModel.archPointGrabRadiusPixels ? best : nil
    }
}
