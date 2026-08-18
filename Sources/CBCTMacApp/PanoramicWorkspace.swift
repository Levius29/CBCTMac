import AppKit
import DICOMCore
import DentalKit
import MeasureKit
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
    /// Clic sul panorex: lunghezza d'arco **e** punto Patient sotto il pixel.
    ///
    /// Il punto serve agli strumenti, che qui prima non funzionavano per la ragione più
    /// semplice possibile: nessuno aveva mai scritto la conversione da pixel a millimetri per
    /// questa immagine. Vedi `PanoramicLayout.patientPoint(atPixelX:y:...)`.
    var onClickArcLength: (Double, Vec3?) -> Void = { _, _ in }
    var onDoubleClick: () -> Void = {}
    var onDrawableSize: (CGSize) -> Void = { _ in }

    /// Scorrimento lungo l'arcata, in millimetri di lunghezza d'arco.
    var onScrollArc: (Double) -> Void = { _ in }
    /// Scorrimento in profondità, vestibolo-linguale, in millimetri.
    var onScrollDepth: (Double) -> Void = { _ in }
    /// ⌥ rotella: spessore dello slab, in millimetri.
    var onScrollSlab: (Double) -> Void = { _ in }
    /// Spostamento della quota verticale, in millimetri.
    var onScrollVertical: (Double) -> Void = { _ in }
    /// Inizio del trascinamento, con l'ascissa premuta in **frazione di larghezza**: serve a
    /// capire se si è afferrata la linea di taglio prima che il primo movimento la sposti.
    var onDragBegan: (Double, Double) -> Void = { _, _ in }
    var onDragEnded: () -> Void = {}
    /// Esc premuto mentre il riquadro ha il fuoco.
    var onCancel: () -> Void = {}
    /// Trascinamento in corso, in frazione di larghezza e di altezza.
    var onDragMoved: (Double, Double) -> Void = { _, _ in }
    /// Ingrandimento: fattore e pixel orizzontale su cui ancorarlo.
    var onZoom: (Double, Double, Int) -> Void = { _, _, _ in }
    /// Trascinamento col tasto destro: finestra e livello.
    ///
    /// Mancava, e il tasto destro sulla panorex non faceva nulla mentre nei riquadri ortogonali
    /// regolava il contrasto. Lo stesso gesto deve fare la stessa cosa ovunque, altrimenti chi lo
    /// prova conclude che il programma è incoerente — e ha ragione.
    var onWindowLevelDrag: (CGSize) -> Void = { _ in }

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
            let width = Int(view.drawableSize.width)
            let height = Int(view.drawableSize.height)
            onClickArcLength(
                layout.arcLengthMM(atPixelX: Double(point.x), pixelWidth: width),
                layout.patientPoint(
                    atPixelX: Double(point.x), y: Double(point.y),
                    pixelWidth: width, pixelHeight: height))
        }
        view.onDoubleClick = { onDoubleClick() }
        view.onWindowLevelDrag = { onWindowLevelDrag($0) }

        // La rotella **sfoglia l'arcata in profondità**, vestibolo-linguale.
        //
        // Non percorre l'arcata, che sarebbe l'associazione ovvia guardando una striscia lunga.
        // La ragione è che una curva d'arcata è un'approssimazione: i denti stanno un po' più
        // fuori o un po' più dentro, e con uno slab sottile — quello che serve per vedere l'apice
        // di una radice — bisogna poter attraversare l'arcata. Percorrerla in lunghezza si fa
        // trascinando, che è il gesto giusto per una striscia più larga della finestra.
        //
        // Quattro decimi di millimetro per passo, e un decimo con ⇧.
        //
        // Era un decimo fisso, ed è la ragione per cui il gesto sembrava morto: su un mouse a
        // rotella un decimo per scatto significa dieci scatti per un millimetro e duecento per
        // attraversare l'arcata. Sul trackpad non si notava, perché uno strofinamento produce
        // decine di eventi; con la rotella no. Quattro decimi sono metà di una corticale sottile,
        // quindi non se ne salta nessuna, e ⇧ resta per quando serve appoggiarsi esattamente.
        view.onScroll = { steps in
            onScrollDepth(steps * 0.4)
        }
        view.onFineScroll = { steps in
            onScrollDepth(steps * 0.1)
        }

        // ⌥ rotella: **spessore** dello slab.
        //
        // Serve perché sfogliare in profondità con uno slab spesso non si vede: venti millimetri
        // di proiezione a massima intensità restano identici a sé stessi se si sposta il centro
        // di un millimetro. Poterlo assottigliare sul posto è ciò che rende visibile il gesto
        // accanto, e stanno sulla stessa rotella perché si usano insieme.
        view.onAlternateScroll = { steps in
            onScrollSlab(steps * 1.0)
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
        // Il trascinamento ha due significati, e quale valga si decide alla pressione: sulla
        // linea di taglio la sposta o la ruota, altrove scorre l'immagine. Deciderlo al primo
        // movimento sarebbe tardi, perché il primo movimento è quello che sposta.
        view.onDragBegan = { [weak view] point in
            guard let view, view.drawableSize.width > 0, view.drawableSize.height > 0 else {
                return
            }
            onDragBegan(
                Double(point.x) / Double(view.drawableSize.width),
                Double(point.y) / Double(view.drawableSize.height))
        }
        view.onDragEnded = onDragEnded
        view.onCancel = onCancel

        view.onDrag = { [weak view] point, delta in
            guard let view, view.drawableSize.width > 0, view.drawableSize.height > 0 else {
                return
            }
            onDragMoved(
                Double(point.x) / Double(view.drawableSize.width),
                Double(point.y) / Double(view.drawableSize.height))
            drag(delta)
        }
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

    /// Che cosa si sta trascinando sulla linea di taglio, deciso alla pressione.
    @State private var cutLineDrag: CutLineDrag?

    private enum CutLineDrag {
        /// Il corpo della linea: sceglie **dove** tagliare.
        case position
        /// La maniglia in cima: sceglie **con che angolo**.
        case angle
    }

    /// Sezioni mostrate contemporaneamente nella griglia.

    /// Larghezza dell'assiale e altezza della striscia, ricordate fra una sessione e l'altra.
    ///
    /// Erano 300 e 240 punti fissi. Vanno bene per il caso medio e per nessun caso particolare:
    /// su una cresta atrofica servono sezioni alte il doppio, su una CBCT parziale ne avanzano.
    @AppStorage("panoramic.axialWidth") private var axialWidth = 300.0
    @AppStorage("panoramic.stripHeight") private var stripHeight = 240.0

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    axialWithArch
                        .frame(width: CGFloat(axialWidth))

                    DraggableDivider(
                        axis: .vertical,
                        value: $axialWidth,
                        // Sotto i 180 punti l'assiale non basta a disegnarci sopra la curva;
                        // sopra metà finestra la panorex diventa una striscia inutile.
                        range: 180...max(Double(geometry.size.width) * 0.5, 200),
                        isInverted: true)

                    panoramicPanel
                }
                .frame(maxHeight: .infinity)

                DraggableDivider(
                    axis: .horizontal,
                    value: $stripHeight,
                    // Fino a tre quarti della finestra: chi guarda le trasversali vuole quelle,
                    // e lasciare al panorex solo una fascia di riferimento è una scelta legittima.
                    range: 120...max(Double(geometry.size.height) * 0.75, 200))

                crossSectionStrip
                    .frame(height: CGFloat(min(stripHeight, max(Double(geometry.size.height) - 160, 120))))
            }
            .padding(Metrics.viewportGap)
            .background(Palette.viewportBackground)
        }
    }

    // MARK: La linea di taglio

    // # Perché questi due gesti vivono qui e non nella sovraimpressione che li disegna
    //
    // Ci vivevano, con un `DragGesture` di SwiftUI, e non funzionavano: sotto c'è un `MTKView`,
    // cioè una `NSView` vera, e AppKit consegna il mouse a quella. La sovraimpressione però
    // **assorbiva la rotella**, e con essa lo sfogliamento in profondità del panorex — una
    // funzione che c'era, tolta per aggiungerne una che non c'era. È la stessa lezione delle
    // maniglie del mirino, e la stessa regola: dentro un riquadro, un solo percorso di eventi.

    /// Quanto vicino alla linea bisogna premere per afferrarla, in frazione di larghezza.
    private let cutLineGrabFraction = 0.02

    /// Quanto in alto arriva la maniglia di rotazione, in frazione dell'altezza.
    private let cutHandleFraction = 0.24

    private func beginPanoramicDrag(atFractionX x: Double, y: Double) {
        cutLineDrag = nil

        // La linea di taglio ha la precedenza: è l'oggetto più usato della panorex, e afferrare
        // un impianto che le sta accanto invece della linea romperebbe un gesto che funziona.
        if let section = model.crossSectionBrowser.selectedSection {
            let range = model.panoramicLayout.visibleArcRangeMM
            let span = max(range.upperBound - range.lowerBound, 1e-6)
            let lineX = (section.arcLengthMM - range.lowerBound) / span
            if abs(x - lineX) < cutLineGrabFraction {
                // In cima è la maniglia dell'angolo, sotto è il corpo della linea. Due
                // significati sullo stesso oggetto, distinti da dove lo si afferra: sono le due
                // libertà di una sezione trasversale, e tenerle insieme rende il gesto immediato.
                cutLineDrag = y < cutHandleFraction ? .angle : .position
                return
            }
        }

        // Fuori dalla linea il trascinamento non faceva nulla. Adesso che il piano si **vede**
        // sulla panorex, deve anche potersi prendere: un oggetto disegnato e non afferrabile è
        // la stessa mezza funzione dell'oggetto afferrabile e non disegnato, letta dall'altro
        // verso.
        guard let patient = panoramicPatientPoint(atFractionX: x, y: y) else { return }
        if model.beginHandleDrag(at: patient, toleranceMM: panoramicGrabToleranceMM) { return }
        guard model.activeTool == .navigate || model.activeTool == .implant else { return }
        model.beginImplantDrag(at: patient, toleranceMM: panoramicGrabToleranceMM)
    }

    /// Il punto Patient sotto una frazione del riquadro panoramico.
    ///
    /// I richiami danno frazioni e non pixel, perché la linea di taglio ragiona in frazioni: la
    /// conversione a pixel passa da `panoramicPixelSize`, che è la dimensione del drawable —
    /// la stessa che il renderer ha usato per disegnare. Vedi `InteractiveMetalView`.
    private func panoramicPatientPoint(atFractionX x: Double, y: Double) -> Vec3? {
        let width = Int(panoramicPixelSize.width)
        let height = Int(panoramicPixelSize.height)
        guard width > 1, height > 1 else { return nil }
        return model.panoramicLayout.patientPoint(
            atPixelX: x * Double(width), y: y * Double(height),
            pixelWidth: width, pixelHeight: height)
    }

    /// Sei pixel convertiti in millimetri alla scala della panorex.
    private var panoramicGrabToleranceMM: Double {
        let width = Int(panoramicPixelSize.width)
        guard width > 1 else { return 2 }
        return model.panoramicLayout.millimetresPerPixel(pixelWidth: width) * 6
    }

    private func movePanoramicDrag(toFractionX x: Double, y: Double) {
        // Un trascinamento in corso su un oggetto del piano vince sulla linea: `cutLineDrag` è
        // nil in quel caso, e le due strade non si incrociano mai.
        if cutLineDrag == nil {
            guard let patient = panoramicPatientPoint(atFractionX: x, y: y) else { return }
            if model.annotationDrag != nil || model.nerveDrag != nil {
                model.dragHandle(toMM: patient)
            } else if model.implantDrag != nil {
                model.dragImplant(toMM: patient)
            }
            return
        }
        moveCutLine(toFractionX: x, y: y)
    }

    private func moveCutLine(toFractionX x: Double, y: Double) {
        guard let drag = cutLineDrag else { return }
        switch drag {
        case .position:
            let range = model.panoramicLayout.visibleArcRangeMM
            let span = range.upperBound - range.lowerBound
            model.selectCrossSection(
                nearestToArcLengthMM: range.lowerBound + min(max(x, 0), 1) * span)

        case .angle:
            guard let section = model.crossSectionBrowser.selectedSection else { return }
            let range = model.panoramicLayout.visibleArcRangeMM
            let span = max(range.upperBound - range.lowerBound, 1e-6)
            let lineX = (section.arcLengthMM - range.lowerBound) / span
            // L'angolo dallo scostamento orizzontale della maniglia rispetto alla base della
            // linea, con l'altezza del riquadro come braccio. Oltre i sessanta gradi la sezione
            // diventa quasi tangente alla curva e non rappresenta più una trasversale.
            let aspect = panoramicPixelSize.height > 0
                ? Double(panoramicPixelSize.width / panoramicPixelSize.height) : 2
            let offset = (lineX - x) * aspect / max(0.5 - cutHandleFraction, 0.1) * 0.5
            let angle = Foundation.atan(offset)
            model.crossSectionAngleOffset = min(max(angle, -.pi / 3), .pi / 3)
        }
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

    /// Scostamento vestibolo-linguale, con il verso scritto invece che affidato al segno.
    ///
    /// «−1,5 mm» dice quanto ma non da che parte, e chi guarda deve ricordare la convenzione.
    /// Scrivere «linguale» toglie l'ambiguità nel punto in cui costerebbe di più: quando si
    /// valuta lo spessore di corticale prima di posizionare un impianto.
    private var depthLabel: String {
        let offset = model.panoramicNormalOffsetMM
        if abs(offset) < 0.001 { return "Sulla curva" }
        let side = offset > 0 ? "vestibolare" : "linguale"
        return String(format: "%.2f mm %@", abs(offset), side)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Spessore dello slab, con il decimale quando è sottile.
    ///
    /// Sotto i sei millimetri si accende, perché lì la profondità comincia a vedersi e chi
    /// scorre deve sapere di essere entrato nel regime in cui il gesto ha effetto.
    private var slabLabel: String {
        let thickness = model.panoramicSlabThicknessMM
        if thickness < 10 {
            return String(format: "Spessore %.1f mm", thickness)
                .replacingOccurrences(of: ".", with: ",")
        }
        return String(format: "Spessore %.0f mm", thickness)
    }

    private var panoramicPanel: some View {
        ZStack {
            PanoramicViewportView(
                layout: model.panoramicLayout,
                volumeTexture: model.volumeTexture,
                renderer: model.panoramicRenderer,
                windowLevel: model.windowLevel,
                onHoverArcLength: { hoverArcLengthMM = $0 },
                onClickArcLength: { arcLength, patient in
                    // Un clic sul panorex seleziona la sezione corrispondente, e con essa porta
                    // le altre viste sul punto: è il modo naturale di passare dalla panoramica al
                    // dente che interessa.
                    model.selectCrossSection(nearestToArcLengthMM: arcLength)

                    // E con uno strumento in mano misura, come in ogni altro riquadro.
                    //
                    // Senza ancoraggio, di proposito: il panorex è una superficie **curva**, e
                    // dichiarare un piano di riferimento che non esiste farebbe sparire la misura
                    // dalle viste dove invece dovrebbe comparire. Vedi il commento in
                    // `PanoramicLayout.patientPoint` su che cosa significa un punto preso qui.
                    if model.activeTool != .navigate, let patient {
                        model.applyToolClick(at: patient, anchor: nil)
                    }
                },
                onDoubleClick: { model.closeToolSession() },
                onDrawableSize: { panoramicPixelSize = $0 },
                onScrollArc: { model.scrollPanoramic(byArcMM: $0) },
                onScrollDepth: { model.movePanoramicDepth(byMM: $0) },
                onScrollSlab: { model.changePanoramicSlab(byMM: $0) },
                onScrollVertical: { model.movePanoramicVertical(byMM: $0) },
                onDragBegan: beginPanoramicDrag,
                onDragEnded: {
                    cutLineDrag = nil
                    model.endHandleDrag()
                    model.endImplantDrag()
                },
                onCancel: { model.cancelToolSession() },
                onDragMoved: movePanoramicDrag,
                onZoom: { factor, x, width in
                    model.zoomPanoramic(by: factor, atPixelX: x, pixelWidth: width)
                },
                onWindowLevelDrag: { model.adjustWindowLevel(byDelta: $0) }
            )

            // Misure sulla panorex: quelle già poste e quella in corso.
            //
            // Solo quelle che stanno **dentro lo spessore campionato**. Proiettare tutto
            // riempirebbe la striscia di misure prese dall'altro lato della mandibola, che qui
            // non si vedono e non c'entrano nulla: la panorex è una superficie, non una
            // proiezione dell'intero volume.
            PanoramicMeasureOverlay(model: model)

            // Il piano sopra la panorex: impianti, canale e denti.
            //
            // È la vista d'insieme della pianificazione — è qui che si vede se gli impianti
            // sono paralleli fra loro e alla stessa altezza, e dove passa il canale rispetto
            // agli apici — e finora mostrava le misure e nient'altro.
            PanoramicPlanOverlay(model: model)

            // Linea di taglio: si trascina lungo l'arcata per scegliere dove tagliare, e si ruota
            // dalla maniglia in cima per scegliere con che angolo.
            CrossSectionCutLine(model: model)

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
                    // Lo scostamento in profondità va mostrato **sempre**, anche a zero: è lo
                    // stato che dice dove ci si trova nell'arcata, e vederlo solo quando è diverso
                    // da zero lascerebbe intendere che a zero non esista.
                    Text(depthLabel)
                        .foregroundStyle(
                            abs(model.panoramicNormalOffsetMM) < 0.001
                                ? Palette.textSecondary : Palette.accent)
                    Text("·")
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
                    Text(slabLabel)
                        .foregroundStyle(
                            model.panoramicSlabThicknessMM < 6 ? Palette.accent : Palette.textSecondary)
                }
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            }
            .padding(Metrics.spacing)
            .allowsHitTesting(false)
        }
        // Comandi della profondità, in basso a sinistra e sempre presenti.
        //
        // La rotella li fa già, ed è il gesto migliore: le dita restano sull'immagine. Ma un
        // gesto che nessuno documenta è un gesto che non esiste, e questo è già andato perso una
        // volta senza che nulla lo dichiarasse — una sovraimpressione che assorbiva la rotella lo
        // aveva spento in silenzio. Con i pulsanti la funzione si vede, e se il gesto smette di
        // funzionare si nota subito che è il gesto e non la funzione.
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 4) {
                Button {
                    model.movePanoramicDepth(byMM: -0.5)
                } label: {
                    Image(systemName: "arrow.left.to.line")
                        .font(.system(size: 10))
                        .frame(width: 22, height: 20)
                        .background(Palette.chrome.opacity(0.8), in: .rect(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Sposta la fetta di mezzo millimetro verso il linguale")

                Button {
                    model.movePanoramicDepth(byMM: 0.5)
                } label: {
                    Image(systemName: "arrow.right.to.line")
                        .font(.system(size: 10))
                        .frame(width: 22, height: 20)
                        .background(Palette.chrome.opacity(0.8), in: .rect(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .help("Sposta la fetta di mezzo millimetro verso il vestibolare")

                if abs(model.panoramicNormalOffsetMM) > 0.001 {
                    Button {
                        model.panoramicNormalOffsetMM = 0
                    } label: {
                        Text("Sulla curva")
                            .font(Typography.label)
                            .padding(.horizontal, 6)
                            .frame(height: 20)
                            .background(Palette.chrome.opacity(0.8), in: .rect(cornerRadius: 3))
                    }
                    .buttonStyle(.plain)
                    .help("Riporta la fetta sulla curva disegnata")
                }
            }
            .foregroundStyle(Palette.textPrimary)
            .padding(Metrics.spacing)
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

                // Inclinazione del taglio, che si regola anche ruotando la linea sul panorex.
                if abs(model.crossSectionAngleOffset) > 0.001 {
                    Text(angleLabel)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.accent)
                }

                Spacer()

                Button {
                    model.crossSectionBrowser.zoom /= 1.5
                } label: { Image(systemName: "minus.magnifyingglass") }
                    .disabled(model.crossSectionBrowser.zoom <= CrossSectionBrowser.minimumZoom)

                Text(String(format: "%.1f×", model.crossSectionBrowser.zoom)
                    .replacingOccurrences(of: ".", with: ","))
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 34)

                Button {
                    model.crossSectionBrowser.zoom *= 1.5
                } label: { Image(systemName: "plus.magnifyingglass") }
                    .disabled(model.crossSectionBrowser.zoom >= CrossSectionBrowser.maximumZoom)

                Button {
                    model.crossSectionBrowser.scrollWindow(
                        by: -model.crossSectionBrowser.effectiveVisibleCount)
                } label: { Image(systemName: "chevron.left") }
                    .disabled(model.crossSectionBrowser.visibleRange.lowerBound == 0)

                Text(pageLabel)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .frame(minWidth: 90)

                Button {
                    model.crossSectionBrowser.scrollWindow(
                        by: model.crossSectionBrowser.effectiveVisibleCount)
                } label: { Image(systemName: "chevron.right") }
                    .disabled(
                        model.crossSectionBrowser.visibleRange.upperBound
                            >= model.crossSectionBrowser.count)
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
                    ForEach(model.crossSectionBrowser.visibleSections) { section in
                        CrossSectionCell(
                            model: model,
                            section: section,
                            isSelected:
                                section.index == model.crossSectionBrowser.selectedIndex)
                    }
                }
                // La rotella e il pinch si ricevono **dentro ogni sezione**, non da una
                // sovraimpressione stesa sulla striscia.
                //
                // Ci stava, con `ScrollWheelCatcher`, e non poteva funzionare: quella vista
                // restituisce `nil` da `hitTest` per lasciar passare i clic, e AppKit consegna
                // rotella e pinch alla vista trovata **da hitTest** e poi ai suoi antenati — mai
                // a un fratello che si è chiamato fuori. Il gesto arrivava alla `MTKView` della
                // sezione, che non lo ascoltava, e finiva lì.
                //
                // È la stessa regola già imparata quattro volte sulle sovraimpressioni con i
                // gesti: dentro un riquadro c'è un solo percorso di eventi, quello di
                // `InteractiveMetalView`. Vale anche per la rotella.
            }
        }
        .background(Palette.chrome)
        .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
    }

    /// `1–10 di 51` **e** la posizione in millimetri: il numero d'ordine dice quante ne restano,
    /// la posizione dice dove si è sull'arcata. Servono tutt'e due, e prima c'era solo il primo.
    private var pageLabel: String {
        let browser = model.crossSectionBrowser
        guard !browser.isEmpty else { return "—" }
        let range = browser.visibleRange
        let position = browser.selectedSection.map {
            String(format: " · %.1f mm", $0.arcLengthMM)
                .replacingOccurrences(of: ".", with: ",")
        } ?? ""
        return "\(range.lowerBound + 1)–\(range.upperBound) di \(browser.count)\(position)"
    }

    private var angleLabel: String {
        let degrees = model.crossSectionAngleOffset * 180 / .pi
        return String(format: "taglio %+.0f°", degrees)
    }
}

// MARK: - Una sezione

struct CrossSectionCell: View {

    let model: AppModel
    let section: CrossSection
    var isSelected: Bool = false

    /// Piano della sezione con l'ingrandimento della striscia applicato.
    ///
    /// L'ingrandimento **restringe il campo**, non stira l'immagine: la scala
    /// millimetri-per-pixel resta quella, e la barra di scala continua a dire il vero.
    private var zoomedPlane: MPRPlane {
        var plane = section.plane
        let extent = model.crossSectionBrowser.sectionExtentMM(
            baseWidthMM: model.crossSectionWidthMM,
            baseHeightMM: model.crossSectionHeightMM)
        plane.widthMM = extent.widthMM
        plane.heightMM = extent.heightMM
        return plane
    }

    /// Dimensione del drawable in pixel, che è lo spazio in cui arrivano i clic.
    @State private var pixelSize: CGSize = .zero

    /// Il punto Patient sotto un pixel di questa sezione, se le dimensioni sono note.
    private func patientPoint(at point: CGPoint) -> Vec3? {
        guard pixelSize.width > 0, pixelSize.height > 0 else { return nil }
        let plane = zoomedPlane.matchingAspect(
            pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
        return plane.patientPoint(
            atPixelX: Double(point.x), y: Double(point.y),
            pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    /// Sei pixel convertiti alla scala della sezione. Vedi `ViewportGrid.grabToleranceMM`.
    private var grabToleranceMM: Double {
        guard pixelSize.width > 0 else { return 1 }
        return zoomedPlane.widthMM / Double(pixelSize.width) * 6
    }

    /// Un clic su una sezione: con la navigazione la sceglie, con uno strumento misura.
    ///
    /// Questa vista è arrivata tardi rispetto ai riquadri ortogonali, e per un po' l'unica cosa
    /// che sapeva fare era selezionarsi. Non era una scelta: era il gestore del clic che nessuno
    /// aveva ancora scritto, e all'uso si presentava come «le misure qui non funzionano».
    private func handleClick(_ point: CGPoint) {
        model.crossSectionBrowser.select(index: section.index)

        guard model.activeTool != .navigate else {
            // Con la navigazione in mano il clic porta le altre viste qui: è il gesto con cui si
            // passa dalla striscia al punto da guardare.
            model.focusSelectedCrossSection()
            return
        }

        guard let patient = patientPoint(at: point) else { return }
        let plane = zoomedPlane.matchingAspect(
            pixelWidth: Int(max(pixelSize.width, 1)), pixelHeight: Int(max(pixelSize.height, 1)))

        let spacing = model.volume?.geometry.spacingMM ?? Vec3(1, 1, 1)
        model.applyToolClick(
            at: patient,
            anchor: ToolAnchor(
                originMM: plane.centerMM,
                normalMM: plane.normalMM,
                rightMM: plane.rightMM,
                downMM: plane.downMM,
                visibilityToleranceMM: max(spacing.x, max(spacing.y, spacing.z)) * 2))
    }

    var body: some View {
        VStack(spacing: 2) {
            MPRViewportView(
                plane: zoomedPlane,
                volumeTexture: model.volumeTexture,
                renderer: model.mprRenderer,
                windowLevel: model.windowLevel,
                onScroll: { steps in
                    // La rotella scorre la striscia: si passa da un dente all'altro senza
                    // staccare la mano dall'immagine.
                    model.crossSectionBrowser.scrollWindow(by: Int(steps.rounded()))
                },
                onZoom: { factor, _ in
                    // ⌘ rotella **e pinch**: `InteractiveMetalView.magnify` arriva qui, ed è la
                    // ragione per cui il pinch adesso funziona e prima no.
                    //
                    // L'ancoraggio al puntatore si ignora di proposito: l'ingrandimento della
                    // striscia non è una lente sull'immagine, è **quanto campo mostra ogni
                    // sezione**. Non c'è un punto da tenere fermo, c'è un'estensione da
                    // stringere, e stringerla attorno al cursore sposterebbe il centro della
                    // sezione lontano dalla curva.
                    model.crossSectionBrowser.zoom *= factor
                },
                onDrag: { point, _ in
                    guard let patient = patientPoint(at: point) else { return }
                    if model.annotationDrag != nil || model.nerveDrag != nil {
                        model.dragHandle(toMM: patient)
                    } else if model.implantDrag != nil {
                        model.dragImplant(toMM: patient)
                    }
                },
                // gesto-non-richiesto: onPan — una sezione è centrata sulla curva per
                // costruzione, e spostarla lateralmente la porterebbe via dal dente che si sta
                // guardando. Per vedere più campo si allarga l'ingrandimento della striscia.
                onRotate: { delta in
                    // ⇧ trascinamento orizzontale inclina il taglio, come sulla linea del
                    // panorex. È lo stesso parametro, e si regola **guardando la sezione**, cioè
                    // nel momento in cui ci si accorge che il taglio è di sbieco rispetto al
                    // dente. Prima si poteva solo dal panorex, dove quell'inclinazione non si
                    // vede.
                    model.crossSectionAngleOffset += Double(delta.width) * 0.004
                },
                onWindowLevelDrag: { model.adjustWindowLevel(byDelta: $0) },
                onClick: handleClick,
                onHover: { point in
                    model.updateHover(atPatient: point.flatMap { patientPoint(at: $0) })
                },
                onDoubleClick: { model.closeToolSession() },
                onDragBegan: { point in
                    guard let grabbed = patientPoint(at: point) else { return }
                    if model.beginHandleDrag(at: grabbed, toleranceMM: grabToleranceMM) { return }

                    // Un impianto si aggiusta guardando la **sezione trasversale**: è lì che si
                    // vede il rapporto con la corticale vestibolare e col canale, ed è quindi lì
                    // che serve poterlo afferrare.
                    guard model.activeTool == .navigate || model.activeTool == .implant,
                        let patient = patientPoint(at: point)
                    else { return }
                    model.beginImplantDrag(at: patient, toleranceMM: grabToleranceMM)
                },
                onDragEnded: {
                    model.endHandleDrag()
                    model.endImplantDrag()
                },
                onCancel: { model.cancelToolSession() },
                onDrawableSize: { pixelSize = $0 }
            )
            .clipShape(.rect(cornerRadius: 3))
            .overlay {
                // Le misure si vedono anche qui. Poterle **fare** e non poterle **vedere** è
                // un mezzo strumento: la sezione ha il suo piano, e le annotazioni che gli
                // stanno vicine si proiettano su questo come su ogni altro riquadro.
                AnnotationOverlay(
                    model: model,
                    explicitPlane: zoomedPlane,
                    pendingPointsMM: model.toolSession.pointsMM)
                    .allowsHitTesting(false)

                // Impianti e denti sulla sezione trasversale.
                //
                // Mancavano, e la mancanza era peggio di un'omissione: il trascinamento
                // dell'impianto **era già collegato** qui: si poteva afferrare e spostare un
                // impianto che non si vedeva. La sezione trasversale è per giunta la vista su
                // cui un impianto si giudica davvero, perché è l'unica che mostra insieme le
                // due corticali e la distanza da ciascuna.
                ImplantOverlay(model: model, plane: zoomedPlane)

                ProstheticToothOverlay(model: model, plane: zoomedPlane)

                // Il contorno della scansione sulla sezione selezionata: è dove si vede se
                // segue lo smalto, e la sezione è il piano su cui si decide un impianto.
                if isSelected, model.isScanVisible, !model.selectedSectionContour.isEmpty {
                    ScanContourOverlay(
                        model: model,
                        explicitLoops: model.selectedSectionContour,
                        explicitPlane: zoomedPlane)
                }
            }
            .overlay {
                // La sezione selezionata è quella che le altre viste stanno mostrando: senza un
                // segno, la striscia e il resto dell'interfaccia sembrano scollegati.
                RoundedRectangle(cornerRadius: 3)
                    .stroke(isSelected ? Palette.accent : .clear, lineWidth: 1.5)
            }

            Text(section.label)
                .font(Typography.numericSmall)
                .foregroundStyle(isSelected ? Palette.accent : Palette.textSecondary)
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

                // Niente `Color.clear` con un `DragGesture`: sotto c'è un `MTKView`, cioè una
                // `NSView` vera, e AppKit consegna il mouse a quella. Il gesto non riceveva
                // nulla, quindi i punti dell'arcata non si potevano né posare né spostare — pur
                // vedendosi disegnati. Ora l'interazione passa da `ViewportGrid`, sull'unico
                // percorso di eventi che il riquadro ha davvero.
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

            // I **bordi dello slab**, cioè fin dove arriva ciò che il panorex sta mediando.
            //
            // Senza di essi lo spessore è un numero in un pannello e non si sa a quanta anatomia
            // corrisponda. Con essi si vede subito se la fascia comprende le corticali o se ne
            // taglia una via, che è la domanda che ci si pone davvero regolando quel cursore. Le
            // due curve seguono l'offset in profondità, quindi sfogliando in vestibolo-linguale
            // si spostano insieme all'immagine.
            let half = model.panoramicSlabThicknessMM * 0.5
            if half > 0.05 {
                var borders = Path()
                for side in [1.0, -1.0] {
                    let offset = model.panoramicNormalOffsetMM + half * side
                    for (index, sample) in samples.enumerated() {
                        let point = project(sample.positionMM + sample.normal * offset)
                        if index == 0 { borders.move(to: point) } else { borders.addLine(to: point) }
                    }
                }
                context.stroke(
                    borders, with: .color(Palette.accent.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            var path = Path()
            for (index, sample) in samples.enumerated() {
                let point = project(sample.positionMM)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            context.stroke(path, with: .color(Palette.accent.opacity(0.9)), lineWidth: 2)

            drawSectionTicks(&context, project: project)
        } else if curve.controlPointsMM.count == 1 {
            // Un punto solo non è una curva, ma va mostrato: altrimenti il primo clic sembra non
            // aver fatto nulla.
            let point = project(curve.controlPointsMM[0])
            context.stroke(
                Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)),
                with: .color(Palette.accent.opacity(0.5)),
                lineWidth: 1)
        }

        // Fuori dalla modifica i punti restano visibili ma minuti e spenti. Prima sparivano del
        // tutto, e sparendo portavano via l'informazione che la curva **ha** dei punti: chi non
        // sapeva già dell'interruttore di modifica non aveva modo di scoprire che fosse
        // modificabile. Piccoli e grigi dicono «ci sono, ma adesso non sono in mano tua».
        guard isEditable else {
            for control in curve.controlPointsMM {
                let point = project(control)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4)),
                    with: .color(Palette.textSecondary.opacity(0.7)))
            }
            return
        }

        for (index, control) in curve.controlPointsMM.enumerated() {
            let point = project(control)
            let isSelected = model.selectedArchPointIndex == index
            let radius: CGFloat = isSelected ? 6.5 : 5
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

    /// Dove cadono, sull'assiale, le sezioni che la striscia sta mostrando.
    ///
    /// È il legame che mancava fra la striscia in basso e l'anatomia: guardando una sezione
    /// stretta non si sa a quale punto dell'arcata appartenga, e finora l'unico modo di
    /// scoprirlo era selezionarla e guardare dove saltava il mirino. Ogni trattino è
    /// perpendicolare alla curva, cioè giace **sul** piano della sezione che rappresenta:
    /// disegnarlo parallelo alla curva sarebbe più facile e indicherebbe la direzione sbagliata.
    private func drawSectionTicks(
        _ context: inout GraphicsContext, project: (Vec3) -> CGPoint
    ) {
        let browser = model.crossSectionBrowser
        let range = browser.visibleRange
        guard !range.isEmpty else { return }

        var ticks = Path()
        var selected = Path()
        for index in range {
            guard browser.sections.indices.contains(index) else { continue }
            let section = browser.sections[index]
            let isSelected = index == browser.selectedIndex
            // Metà larghezza della sezione per quella scelta, un cenno per le altre: la
            // selezionata è quella che le altre viste stanno seguendo, e deve distinguersi senza
            // che si debba cercarla.
            let halfMM = isSelected ? section.plane.widthMM * 0.5 : 3.0
            let direction = section.plane.rightMM
            let a = project(section.originMM + direction * halfMM)
            let b = project(section.originMM - direction * halfMM)
            if isSelected {
                selected.move(to: a)
                selected.addLine(to: b)
            } else {
                ticks.move(to: a)
                ticks.addLine(to: b)
            }
        }
        context.stroke(ticks, with: .color(Palette.textPrimary.opacity(0.45)), lineWidth: 1)
        context.stroke(selected, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
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
    /// Punto di controllo più vicino, se entro la distanza di presa.
    ///
    /// Statico e interno perché lo usa anche `ViewportGrid`, che è dove l'interazione vive
    /// adesso: la stessa regola di presa in due posti diventerebbe due regole diverse.
    static func nearestControl(
        in curve: ArchCurve, to point: CGPoint, plane: MPRPlane, width: Int, height: Int
    ) -> Int? {
        var best: Int?
        var bestDistance = Double.infinity
        for (index, control) in curve.controlPointsMM.enumerated() {
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


// MARK: - Misure sulla panorex

/// Punti e segmenti delle misure, proiettati sulla ricostruzione curva.
///
/// Disegna solo ciò che sta entro mezzo spessore di slab dalla superficie campionata. È la stessa
/// regola con cui il riquadro decide che cosa mostrare, e applicarla anche qui evita l'effetto
/// peggiore: una misura che compare sulla panorex mentre la struttura che collega non si vede.
struct PanoramicMeasureOverlay: View {

    let model: AppModel

    var body: some View {
        Canvas { context, size in
            let width = Int(size.width)
            let height = Int(size.height)
            guard width > 1, height > 1, model.archCurve.isUsable else { return }
            let layout = model.panoramicLayout
            let tolerance = max(layout.slabThicknessMM * 0.5, 1.0)

            /// Proietta una serie di punti, o `nil` se anche uno solo sta fuori dallo spessore.
            /// Tutto o niente: mezza misura disegnata è peggio di nessuna, perché sembra una
            /// misura intera più corta.
            func project(_ pointsMM: [Vec3]) -> [CGPoint]? {
                var result: [CGPoint] = []
                result.reserveCapacity(pointsMM.count)
                for pointMM in pointsMM {
                    guard
                        let p = layout.projection(
                            ofPatient: pointMM, pixelWidth: width, pixelHeight: height),
                        abs(p.depthMM) <= tolerance
                    else { return nil }
                    result.append(CGPoint(x: p.x, y: p.y))
                }
                return result
            }

            func stroke(_ points: [CGPoint], color: Color, dashed: Bool) {
                guard let first = points.first else { return }
                var path = Path()
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                context.stroke(
                    path, with: .color(color),
                    style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 3] : []))
                for point in points {
                    context.fill(
                        Path(
                            ellipseIn: CGRect(
                                x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)),
                        with: .color(color))
                }
            }

            for annotation in model.annotations where !annotation.metadata.isHidden {
                let colour = Color(hexString: annotation.metadata.colorHex) ?? Palette.accent
                guard let points = project(vertices(of: annotation)), points.count >= 1 else {
                    continue
                }
                stroke(points, color: colour, dashed: false)
            }

            if let points = project(model.toolSession.pointsMM) {
                stroke(points, color: Palette.accent, dashed: true)
            }
        }
        .allowsHitTesting(false)
    }

    /// I vertici che vale la pena disegnare su una superficie curva.
    ///
    /// La base è `Annotation.handlesMM`, che ogni annotazione dichiara già. Qui c'era invece uno
    /// `switch` a undici rami che rifaceva lo stesso lavoro a mano, e che infatti sbagliava:
    /// chiedeva a una freccia `startMM` ed `endMM` quando i suoi punti si chiamano `tipMM` e
    /// `tailMM`. Riderivare un'informazione che il tipo già espone non è solo lavoro in più — è
    /// lavoro che diverge, e a ogni annotazione nuova diverge di un ramo.
    ///
    /// Restano tre eccezioni, e sono decisioni di **disegno**, non ripetizioni:
    ///
    /// - Le ROI danno solo il centro. Un'ellisse è definita su un piano, e le sue maniglie sono
    ///   gli estremi dei semiassi: stirarle su una ricostruzione curva disegnerebbe una forma
    ///   che lì non esiste. Il centro invece è un punto, e dice dove sta senza affermare altro.
    /// - Le forme chiuse ripetono il primo punto in coda, perché `handlesMM` elenca i vertici e
    ///   non il percorso: senza, un perimetro comparirebbe aperto proprio dove è chiuso.
    /// - L'angolo fra rette dà la sola prima retta. Le due rette non si toccano, e unirne i
    ///   quattro punti in un tratto solo disegnerebbe un segmento fra due rette che non c'è.
    private func vertices(of annotation: Annotation) -> [Vec3] {
        func closingLoop(_ points: [Vec3]) -> [Vec3] {
            guard points.count > 2, let first = points.first else { return points }
            return points + [first]
        }

        switch annotation {
        case .ellipseROI(let roi):
            return [roi.centerMM]
        case .sphereROI(let roi):
            return [roi.centerMM]
        case .polygonROI(let roi):
            return closingLoop(roi.verticesMM)
        case .polyline(let measurement) where measurement.isClosed:
            return closingLoop(measurement.pointsMM)
        case .freehand(let path) where path.isClosed:
            return closingLoop(path.pointsMM)
        case .lineAngle(let measurement):
            return [measurement.firstStartMM, measurement.firstEndMM]
        default:
            return annotation.handlesMM
        }
    }
}
