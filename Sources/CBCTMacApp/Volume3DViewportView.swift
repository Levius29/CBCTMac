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
/// Non è un vezzo: ruotando un cranio senza tessuti molli si perde rapidamente il senso di
/// dove sia il davanti, e una faccia etichettata risolve in un colpo d'occhio quello che
/// altrimenti richiede di riportare la vista in posizione nota.
struct OrientationCube: View {

    let camera: VolumeCamera

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Palette.chromeElevated.opacity(0.85))
                .frame(width: 56, height: 56)
                .overlay {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Palette.separator, lineWidth: 1)
                }

            Text(faceLabel)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.textPrimary)
        }
        .allowsHitTesting(false)
    }

    /// Lettera anatomica della faccia rivolta verso l'osservatore.
    ///
    /// Si guarda la direzione **opposta** a quella di vista: `forward` va dalla camera verso il
    /// paziente, quindi la faccia che vediamo è quella che punta verso di noi.
    private var faceLabel: String {
        let toViewer = -camera.forward
        let x = abs(toViewer.x)
        let y = abs(toViewer.y)
        let z = abs(toViewer.z)

        if z >= x && z >= y {
            return toViewer.z > 0 ? "S" : "I"
        }
        if y >= x {
            return toViewer.y > 0 ? "P" : "A"
        }
        return toViewer.x > 0 ? "L" : "R"
    }
}
