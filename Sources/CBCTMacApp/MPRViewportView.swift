import DICOMCore
import Metal
import MetalKit
import SwiftUI
import VolumeKit

// Ponte fra SwiftUI e Metal per un riquadro MPR.
//
// Il kernel scrive **direttamente nella texture del drawable**, senza texture intermedia né
// blit: basta `framebufferOnly = false`. Un passaggio in meno per riquadro, e con quattro
// riquadri che si ridisegnano a ogni movimento del mouse la differenza si sente.
//
// La vista non ridisegna di continuo. `isPaused` con `enableSetNeedsDisplay` la fa dipingere
// solo quando qualcosa cambia: un visore radiologico sta fermo la maggior parte del tempo, e un
// ciclo a 120 Hz su un'immagine immobile scalda il portatile per nulla.

struct MPRViewportView: NSViewRepresentable {

    /// Piano da campionare, **senza** adattamento delle proporzioni: le dimensioni reali si
    /// conoscono solo a valle del layout, e le applica il coordinatore.
    let plane: MPRPlane?
    let volumeTexture: VolumeTexture?
    let renderer: MPRRenderer?
    let windowLevel: DensityWindow

    // Eventi. Le posizioni sono in **pixel della texture, origine in alto a sinistra**, già
    // convertite da `InteractiveMetalView`.
    var onScroll: (Double) -> Void = { _ in }
    var onMagnify: (Double) -> Void = { _ in }
    var onDrag: (CGPoint, CGSize) -> Void = { _, _ in }
    var onWindowLevelDrag: (CGSize) -> Void = { _ in }
    var onClick: (CGPoint) -> Void = { _ in }
    var onHover: (CGPoint?) -> Void = { _ in }
    var onDoubleClick: () -> Void = {}

    /// Dimensione del drawable in pixel. Serve a chi sta sopra per convertire i clic in
    /// millimetri: senza di essa la conversione non è definita.
    var onDrawableSize: (CGSize) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> InteractiveMetalView {
        let view = InteractiveMetalView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Indispensabile: senza, la texture del drawable non è scrivibile da un compute kernel.
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
        context.coordinator.plane = plane
        context.coordinator.volumeTexture = volumeTexture
        context.coordinator.renderer = renderer
        context.coordinator.windowLevel = windowLevel
        context.coordinator.onDrawableSize = onDrawableSize

        // I callback catturano lo stato di SwiftUI e vanno riagganciati a ogni aggiornamento,
        // altrimenti la chiusura resta legata a un valore vecchio.
        attachHandlers(to: view)

        view.setNeedsDisplay(view.bounds)
    }

    private func attachHandlers(to view: InteractiveMetalView) {
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onDrag = onDrag
        view.onWindowLevelDrag = onWindowLevelDrag
        view.onClick = onClick
        view.onHover = onHover
        view.onDoubleClick = onDoubleClick
    }

    // MARK: - Coordinatore

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {

        var plane: MPRPlane?
        var volumeTexture: VolumeTexture?
        var renderer: MPRRenderer?
        var windowLevel: DensityWindow = .bone
        var onDrawableSize: ((CGSize) -> Void)?

        private var commandQueue: MTLCommandQueue?
        private var lastReportedSize: CGSize = .zero

        func configure(device: MTLDevice?) {
            guard let device else { return }
            commandQueue = device.makeCommandQueue()
            commandQueue?.label = "MPR"
        }

        // `MTKViewDelegate` non è isolato a un attore, questa classe sì. I metodi si dichiarano
        // `nonisolated` per soddisfare il protocollo e rientrano subito sul main actor: `MTKView`
        // invoca il delegato sul thread principale quando la vista è a schermo, quindi
        // l'assunzione è vera e non un aggiramento del controllo di concorrenza.
        nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            MainActor.assumeIsolated {
                reportSizeIfChanged(size)
            }
        }

        nonisolated func draw(in view: MTKView) {
            MainActor.assumeIsolated {
                render(in: view)
            }
        }

        private func reportSizeIfChanged(_ size: CGSize) {
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
            reportSizeIfChanged(CGSize(width: target.width, height: target.height))

            if let renderer, let volumeTexture, let plane, target.width > 0, target.height > 0 {
                // Le proporzioni si adattano qui, dove le dimensioni in pixel sono note.
                // Si allarga il lato che serve, mai si stringe: ridimensionando la finestra
                // l'anatomia inquadrata non deve uscire dal campo.
                let adjusted = plane.matchingAspect(
                    pixelWidth: target.width, pixelHeight: target.height)
                do {
                    try renderer.encode(
                        plane: adjusted,
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

        /// Riempie di nero. Serve quando non c'è ancora un volume o se l'encoding fallisce:
        /// meglio un riquadro nero che il contenuto casuale di un drawable riciclato.
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
