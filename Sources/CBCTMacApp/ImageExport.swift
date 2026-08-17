import AppKit
import CoreGraphics
import DICOMCore
import ImplantKit
import MeasureKit
import Metal
import SwiftUI
import VolumeKit

// Esportazione di un riquadro come immagine.
//
// Non basta catturare la vista SwiftUI: `ImageRenderer` non vede il contenuto di una `MTKView`,
// perché il livello Metal non fa parte dell'albero che sa disegnare. Serve quindi un percorso
// in due tempi — rendering fuori schermo in una texture leggibile dalla CPU, poi le
// sovraimpressioni disegnate sopra con Core Graphics.
//
// Barra di scala e disclaimer sono **impressi nei pixel**, non sovrapposti a video. Un'immagine
// esportata gira per email, finisce in una presentazione, viene ritagliata: deve restare
// interpretabile e riconoscibile come non diagnostica anche staccata da questa applicazione.

@MainActor
enum ImageExport {

    /// Margine attorno all'immagine per le diciture, in pixel.
    private static let footerHeight: CGFloat = 64

    // MARK: Punto d'ingresso

    /// Renderizza un piano e ne scrive il PNG.
    static func exportPNG(
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int,
        to url: URL
    ) throws {
        guard let device = model.device,
            let renderer = model.mprRenderer,
            let volumeTexture = model.volumeTexture
        else {
            throw ExportError.metalUnavailable
        }

        let base = try renderMPR(
            plane: plane,
            volumeTexture: volumeTexture,
            renderer: renderer,
            device: device,
            windowLevel: model.windowLevel,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight)

        let composed = try compose(
            base: base,
            plane: plane,
            model: model,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight)

        try writePNG(composed, to: url)
    }

    // MARK: Rendering fuori schermo

    private static func renderMPR(
        plane: MPRPlane,
        volumeTexture: VolumeTexture,
        renderer: MPRRenderer,
        device: MTLDevice,
        windowLevel: DensityWindow,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> CGImage {

        // `storageModeShared` e non `private`: la texture va riletta dalla CPU, e una privata
        // non è leggibile. È l'unica differenza rispetto al rendering a schermo.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .shared

        guard let target = device.makeTexture(descriptor: descriptor),
            let queue = device.makeCommandQueue(),
            let commandBuffer = queue.makeCommandBuffer()
        else {
            throw ExportError.textureCreationFailed
        }

        let adjusted = plane.matchingAspect(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        try renderer.encode(
            plane: adjusted,
            volume: volumeTexture,
            windowLevel: windowLevel,
            into: target,
            commandBuffer: commandBuffer)

        commandBuffer.commit()
        // Qui si attende davvero: l'esportazione è un'operazione puntuale, non un fotogramma,
        // e senza attesa si leggerebbero byte non ancora scritti.
        commandBuffer.waitUntilCompleted()

        if let error = commandBuffer.error {
            throw ExportError.renderFailed(String(describing: error))
        }

        return try makeImage(from: target)
    }

    private static func makeImage(from texture: MTLTexture) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)

        bytes.withUnsafeMutableBytes { raw in
            texture.getBytes(
                raw.baseAddress!,
                bytesPerRow: bytesPerRow,
                from: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0)
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            throw ExportError.imageCreationFailed
        }

        // La texture è BGRA: senza `byteOrder32Little` con l'alfa in testa, rosso e blu si
        // scambiano. Su un'immagine in scala di grigi non si noterebbe nulla — ma le
        // annotazioni colorate sì, e sarebbero sbagliate in modo difficile da spiegare.
        let bitmapInfo: CGBitmapInfo = [
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
            .byteOrder32Little,
        ]

        guard let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent)
        else {
            throw ExportError.imageCreationFailed
        }
        return image
    }

    // MARK: Composizione

    private static func compose(
        base: CGImage,
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> CGImage {

        let totalHeight = CGFloat(pixelHeight) + footerHeight
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: Int(totalHeight),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw ExportError.imageCreationFailed
        }

        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: totalHeight))

        // Core Graphics ha l'origine in basso a sinistra: l'immagine va sopra la fascia.
        context.draw(
            base,
            in: CGRect(
                x: 0, y: footerHeight, width: CGFloat(pixelWidth), height: CGFloat(pixelHeight)))

        let adjusted = plane.matchingAspect(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        drawScaleBar(
            in: context, plane: adjusted, pixelWidth: pixelWidth,
            imageBottom: footerHeight)
        drawFooter(in: context, model: model, pixelWidth: pixelWidth)

        guard let image = context.makeImage() else { throw ExportError.imageCreationFailed }
        return image
    }

    private static func drawScaleBar(
        in context: CGContext, plane: MPRPlane, pixelWidth: Int, imageBottom: CGFloat
    ) {
        let mmPerPixel = plane.widthMM / Double(pixelWidth)
        guard mmPerPixel > 0 else { return }

        let candidates: [Double] = [1, 2, 5, 10, 20, 50, 100]
        let targetPixels = Double(pixelWidth) * 0.12
        var chosen: Double?
        var bestError = Double.infinity
        for millimetres in candidates {
            let pixels = millimetres / mmPerPixel
            guard pixels >= 40, pixels <= Double(pixelWidth) * 0.4 else { continue }
            let error = abs(pixels - targetPixels)
            if error < bestError {
                bestError = error
                chosen = millimetres
            }
        }
        guard let millimetres = chosen else { return }

        let barWidth = CGFloat(millimetres / mmPerPixel)
        let margin: CGFloat = 24
        let y = imageBottom + margin

        context.setFillColor(CGColor(gray: 1, alpha: 0.9))
        context.fill(
            CGRect(x: CGFloat(pixelWidth) - margin - barWidth, y: y, width: barWidth, height: 3))
        // Tacche agli estremi: senza, un ritaglio potrebbe tagliare la barra senza che si veda.
        context.fill(
            CGRect(x: CGFloat(pixelWidth) - margin - barWidth, y: y - 4, width: 3, height: 11))
        context.fill(CGRect(x: CGFloat(pixelWidth) - margin - 3, y: y - 4, width: 3, height: 11))

        drawText(
            "\(Int(millimetres)) mm",
            in: context,
            at: CGPoint(x: CGFloat(pixelWidth) - margin - barWidth, y: y + 12),
            size: 13,
            color: CGColor(gray: 1, alpha: 0.9))
    }

    private static func drawFooter(in context: CGContext, model: AppModel, pixelWidth: Int) {
        // Striscia ambra come nell'applicazione: il colore è parte del messaggio, ed è la cosa
        // che si nota per prima guardando l'immagine fuori contesto.
        let bannerHeight: CGFloat = 22
        context.setFillColor(CGColor(red: 1.0, green: 0.624, blue: 0.039, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(pixelWidth), height: bannerHeight))

        drawText(
            "USO NON DIAGNOSTICO — software non certificato come dispositivo medico",
            in: context,
            at: CGPoint(x: 16, y: 5),
            size: 13,
            color: CGColor(gray: 0, alpha: 1),
            bold: true)

        let stamp = "CBCTMac \(AppModel.appVersion) · \(model.studyName) · \(timestamp())"
        drawText(
            stamp,
            in: context,
            at: CGPoint(x: 16, y: bannerHeight + 10),
            size: 12,
            color: CGColor(gray: 0.7, alpha: 1))
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd/MM/yyyy HH:mm"
        return formatter.string(from: Date())
    }

    private static func drawText(
        _ string: String,
        in context: CGContext,
        at point: CGPoint,
        size: CGFloat,
        color: CGColor,
        bold: Bool = false
    ) {
        let font = bold
            ? NSFont.boldSystemFont(ofSize: size)
            : NSFont.monospacedSystemFont(ofSize: size, weight: .regular)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(cgColor: color) ?? NSColor.white,
        ]
        let attributed = NSAttributedString(string: string, attributes: attributes)

        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attributed.draw(at: point)
        NSGraphicsContext.current = previous
    }

    // MARK: Scrittura

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw ExportError.encodingFailed
        }
        try data.write(to: url, options: .atomic)
    }

    // MARK: Errori

    enum ExportError: Error, LocalizedError {
        case metalUnavailable
        case textureCreationFailed
        case renderFailed(String)
        case imageCreationFailed
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .metalUnavailable:
                return "Metal non disponibile: impossibile esportare."
            case .textureCreationFailed:
                return "Impossibile creare la texture di esportazione."
            case .renderFailed(let detail):
                return "Rendering fallito durante l'esportazione: \(detail)"
            case .imageCreationFailed:
                return "Impossibile comporre l'immagine."
            case .encodingFailed:
                return "Codifica PNG fallita."
            }
        }
    }
}
