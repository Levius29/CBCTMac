import DICOMCore
import Metal
import MetalKit
import SwiftUI
import VolumeKit

// Riquadro del rendering 3D.
//
// Gemello di `MPRViewportView`: stessa struttura, stesso ciclo di ridisegno su richiesta, ma
// il kernel è il raycaster invece del campionatore di piani.
//
// Una differenza sostanziale: durante la rotazione si rende a qualità ridotta e si raffina al
// rilascio. Un volume da quattordici milioni di voxel non si attraversa a piena risoluzione
// mantenendo la fluidità del trascinamento, e non serve: su un'immagine in movimento il
// dettaglio non si coglie, mentre uno scatto sì.

struct Volume3DViewportView: NSViewRepresentable {

    let camera: VolumeCamera
    let volumeTexture: VolumeTexture?
    let raycaster: VolumeRaycaster?
    let transferFunction: TransferFunction
    let quality: RenderQuality
    let lighting: LightingParameters
    /// Riquadro di sola lettura: fuori da esso il raggio non campiona. Vedi `ClipBox`.
    var clip: ClipBox?

    var onOrbit: (CGSize) -> Void = { _ in }
    var onMagnify: (Double) -> Void = { _ in }
    var onInteractionChanged: (Bool) -> Void = { _ in }
    /// Pressione iniziale, in pixel del drawable. Restituisce `true` se ha afferrato qualcosa:
    /// in quel caso il trascinamento **non** deve far orbitare la telecamera.
    var onGrab: (CGPoint) -> Bool = { _ in false }
    var onGrabbedDrag: (CGPoint) -> Void = { _ in }
    /// Clic senza trascinamento, in pixel del drawable. Serve a posare un punto indicando una
    /// superficie: è l'unico modo di dare una profondità a un clic in una vista che non ha un
    /// piano.
    var onClick: (CGPoint) -> Void = { _ in }
    var onDrawableSize: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

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
        attachHandlers(to: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: InteractiveMetalView, context: Context) {
        context.coordinator.camera = camera
        context.coordinator.volumeTexture = volumeTexture
        context.coordinator.raycaster = raycaster
        context.coordinator.transferFunction = transferFunction
        context.coordinator.quality = quality
        context.coordinator.lighting = lighting
        context.coordinator.clip = clip
        context.coordinator.onDrawableSize = onDrawableSize
        attachHandlers(to: view, coordinator: context.coordinator)
        view.setNeedsDisplay(view.bounds)
    }

    private func attachHandlers(to view: InteractiveMetalView, coordinator: Coordinator) {
        // # Orbitare, oppure spostare un oggetto — mai tutt'e due
        //
        // Sul 3D il trascinamento fa girare la scena, ed è il gesto che ci si aspetta. Ma un
        // impianto disegnato lì dentro deve potersi prendere, e le due cose partono dallo stesso
        // evento. Si distinguono al momento della **pressione**: se sotto il puntatore c'è un
        // oggetto afferrabile, il trascinamento appartiene a quello e la telecamera resta ferma.
        //
        // Il coordinatore ricorda la decisione per tutta la durata del gesto. Riprovare a
        // decidere a ogni movimento farebbe scappare l'oggetto non appena il puntatore ne esce,
        // e la scena comincerebbe a girare a metà di uno spostamento.
        view.onDragBegan = { point in
            coordinator.isMovingObject = onGrab(point)
            onInteractionChanged(true)
        }
        view.onDrag = { point, delta in
            if coordinator.isMovingObject {
                onGrabbedDrag(point)
            } else {
                onOrbit(delta)
            }
        }
        // ⌥ e ⇧ sul 3D non hanno un significato proprio: entrambi restano orbita, così un
        // modificatore premuto per abitudine non blocca il gesto.
        view.onPan = { delta in onOrbit(delta) }
        view.onRotate = { delta in onOrbit(delta) }
        // Il punto d'ancoraggio non serve qui: la camera orbita e ingrandisce attorno al centro
        // del volume, non attorno al puntatore.
        view.onZoom = { factor, _ in onMagnify(factor) }
        view.onClick = onClick
        // La rotella regola lo zoom: sul 3D non ci sono slice da scorrere, e lasciarla inerte
        // sarebbe una piccola frustrazione ripetuta.
        view.onScroll = { steps in onMagnify(1.0 + steps * 0.05) }
        view.onDragEnded = {
            coordinator.isMovingObject = false
            onInteractionChanged(false)
        }
    }

    // MARK: - Coordinatore

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {

        var camera = VolumeCamera()
        /// Vero quando il trascinamento in corso sta spostando un oggetto invece di orbitare.
        ///
        /// Deciso alla pressione e tenuto per tutto il gesto: ridecidere a ogni movimento
        /// farebbe scappare l'oggetto appena il puntatore ne esce, e la scena comincerebbe a
        /// girare a metà di uno spostamento.
        var isMovingObject = false
        var onDrawableSize: ((CGSize) -> Void)?
        private var lastReportedSize: CGSize = .zero
        var volumeTexture: VolumeTexture?
        var raycaster: VolumeRaycaster?
        var transferFunction: TransferFunction = .bone
        var quality: RenderQuality = .standard
        var lighting: LightingParameters = .standard
        var clip: ClipBox?

        private var commandQueue: MTLCommandQueue?

        func configure(device: MTLDevice?) {
            guard let device else { return }
            commandQueue = device.makeCommandQueue()
            commandQueue?.label = "Raycast"
        }

        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated { render(in: view) }
        }

        func reportSizeIfChanged(_ size: CGSize) {
            guard size != lastReportedSize else { return }
            lastReportedSize = size
            onDrawableSize?(size)
        }

        private func render(in view: MTKView) {
            guard let drawable = view.currentDrawable,
                let commandQueue,
                let commandBuffer = commandQueue.makeCommandBuffer()
            else { return }

            let target = drawable.texture
            // La dimensione **vera** del drawable, non quella dei punti della vista: è la
            // griglia su cui il raycaster ha disegnato, ed è la sola con cui un clic si può
            // riconvertire in millimetri. Vedi `MPRViewportView`.
            reportSizeIfChanged(CGSize(width: target.width, height: target.height))

            if let raycaster, let volumeTexture, target.width > 0, target.height > 0 {
                do {
                    try raycaster.encode(
                        camera: camera,
                        volume: volumeTexture,
                        transferFunction: transferFunction,
                        quality: quality,
                        lighting: lighting,
                        clip: clip,
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

// MARK: - Cubo di orientamento

/// Indicatore di orientamento in alto a destra del riquadro 3D.
///
/// # Un cubo che gira, non un quadrato con una lettera
///
/// Era un quadrato con dentro la lettera della faccia rivolta verso l'osservatore. Diceva
/// **quale faccia guardi**, e basta. Ruotando un cranio senza tessuti molli, però, la domanda
/// che ci si pone non è quella: è «di quanto sono girato, e da che parte devo tornare». A quella
/// risponde solo un oggetto che gira insieme al modello — si legge l'inclinazione dalle facce
/// che si scorciano, e si sa da che parte tirare senza pensarci.
///
/// La geometria non è qui ma in `OrientationCubeGeometry`, dove si può provare: una faccia
/// etichettata al contrario manda a destra chi doveva andare a sinistra, e su una pianificazione
/// implantare non è un dettaglio estetico. Qui resta il disegno, che sbagliato si vede.
struct OrientationCube: View {

    let camera: VolumeCamera

    /// Lato del riquadro, in punti.
    private let side: CGFloat = 62

    var body: some View {
        Canvas { context, size in
            let half = Swift.min(size.width, size.height) * 0.5
            // Il cubo va da −1 a 1 lungo ogni asse, e la sua diagonale è √3: si sta dentro
            // qualunque sia la rotazione, senza che gli spigoli escano girando.
            let scale = half / 1.75
            let centre = CGPoint(x: size.width * 0.5, y: size.height * 0.5)

            func screen(_ point: (x: Double, y: Double)) -> CGPoint {
                CGPoint(
                    x: centre.x + CGFloat(point.x) * scale,
                    y: centre.y + CGFloat(point.y) * scale)
            }

            for projected in OrientationCubeGeometry.visibleFaces(camera: camera) {
                var path = Path()
                path.move(to: screen(projected.corners[0]))
                for corner in projected.corners.dropFirst() {
                    path.addLine(to: screen(corner))
                }
                path.closeSubpath()

                // Più una faccia è di fronte, più è chiara: è la differenza che fa leggere il
                // cubo come un solido invece che come un esagono piatto.
                let shade = 0.30 + 0.45 * projected.facing
                context.fill(path, with: .color(Palette.chromeElevated.opacity(0.92)))
                context.fill(path, with: .color(Palette.textPrimary.opacity(shade * 0.22)))
                context.stroke(path, with: .color(Palette.separator), lineWidth: 1)

                // La lettera solo dove c'è spazio per leggerla: su una faccia molto scorciata
                // sarebbe una macchia sopra il bordo, e confonderebbe invece di orientare.
                guard projected.facing > 0.30 else { continue }
                context.draw(
                    Text(projected.face.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.textPrimary.opacity(0.35 + 0.65 * projected.facing)),
                    at: screen(projected.centre),
                    anchor: .center)
            }
        }
        .frame(width: side, height: side)
        .allowsHitTesting(false)
        .help("Orientamento: \(OrientationCubeGeometry.frontFace(camera: camera).localizedName)")
    }
}
