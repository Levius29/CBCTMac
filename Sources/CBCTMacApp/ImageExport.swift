import AppKit
import UniformTypeIdentifiers
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

    /// I formati in cui si può salvare un riquadro.
    ///
    /// # Perché tre e non uno
    ///
    /// PNG è la scelta giusta per un'immagine radiologica — senza perdite, quindi un valore
    /// grigio letto sull'immagine è quello che il programma ha disegnato — e resta il
    /// predefinito. JPEG serve quando l'immagine va in un documento o in una posta e il peso
    /// conta; TIFF quando la si porta in un programma di fotoritocco che il PNG a 16 bit non
    /// legge.
    ///
    /// La perdita del JPEG è **dichiarata** dove si sceglie: su un'immagine diagnostica una
    /// compressione con perdita cambia i valori dei pixel, e chi ci misura sopra deve saperlo.
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case png
        case jpeg
        case tiff

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .png: return "PNG"
            case .jpeg: return "JPEG"
            case .tiff: return "TIFF"
            }
        }

        var fileExtension: String {
            switch self {
            case .png: return "png"
            case .jpeg: return "jpg"
            case .tiff: return "tiff"
            }
        }

        var contentType: UTType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            }
        }

        /// Vero se il formato altera i valori dei pixel.
        var isLossy: Bool { self == .jpeg }

        var bitmapType: NSBitmapImageRep.FileType {
            switch self {
            case .png: return .png
            case .jpeg: return .jpeg
            case .tiff: return .tiff
            }
        }

        var properties: [NSBitmapImageRep.PropertyKey: Any] {
            // Novanta e non cento: a cento il JPEG pesa quasi quanto un PNG e non serve a
            // niente, sotto novanta gli artefatti si vedono sui bordi dell'osso.
            self == .jpeg ? [.compressionFactor: 0.9] : [:]
        }
    }

    /// Renderizza un piano e ne scrive il file nel formato indicato.
    static func export(
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int,
        format: Format,
        to url: URL
    ) throws {
        try imageData(
            plane: plane, model: model, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            format: format
        ).write(to: url, options: .atomic)
    }

    /// Renderizza un piano e ne restituisce i byte nel formato indicato.
    static func imageData(
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int,
        format: Format
    ) throws -> Data {
        let image = try render(
            plane: plane, model: model, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: format.bitmapType, properties: format.properties)
        else {
            throw ExportError.encodingFailed
        }
        return data
    }

    /// Renderizza un piano e ne scrive il PNG.
    static func exportPNG(
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int,
        to url: URL
    ) throws {
        try pngData(
            plane: plane, model: model, pixelWidth: pixelWidth, pixelHeight: pixelHeight
        ).write(to: url, options: .atomic)
    }

    /// Renderizza un piano e ne restituisce i byte PNG.
    ///
    /// Separato dalla scrittura su file perché la relazione le immagini non le scrive accanto a
    /// sé: se le mette dentro. Il rendering è lo stesso, e averne due copie significherebbe
    /// vederle divergere — una con la barra di scala e l'altra senza, e nessuno saprebbe quale
    /// delle due è quella giusta.
    static func pngData(
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> Data {
        try imageData(
            plane: plane, model: model, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
            format: .png)
    }

    /// Il riquadro renderizzato, prima della codifica in un formato.
    static func render(
        plane: MPRPlane,
        model: AppModel,
        pixelWidth: Int,
        pixelHeight: Int
    ) throws -> CGImage {
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

        return try compose(
            base: base,
            plane: plane,
            model: model,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight)
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

        let stamp = "\(AppIcon.displayName) \(AppModel.appVersion) · \(model.studyName) · \(timestamp())"
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

    /// Stampa il riquadro.
    ///
    /// # Perché la stampa non passa dalla relazione
    ///
    /// Perché stampare un'immagine e stampare un documento sono due cose diverse, e la seconda
    /// la fa già il browser aprendo la relazione. Qui si stampa **ciò che si sta guardando**,
    /// che è il gesto per cui esiste un comando Stampa in un visore: una sezione da appendere
    /// accanto al riunito, o da consegnare.
    ///
    /// L'immagine si adatta al foglio conservando le proporzioni. Deformarla per riempire la
    /// pagina cambierebbe la scala nei due versi in modo diverso, e su un'immagine che porta
    /// una barra di scala stampata sarebbe una misura sbagliata su carta.
    static func print(
        plane: MPRPlane,
        model: AppModel,
        jobTitle: String
    ) throws {
        // Risoluzione da stampa: 2400 punti sul lato lungo sono circa 300 dpi su venti
        // centimetri, che è il limite oltre il quale la carta non distingue più.
        let image = try render(plane: plane, model: model, pixelWidth: 2400, pixelHeight: 1800)

        let info = NSPrintInfo.shared
        info.orientation = .landscape
        let printable = CGSize(
            width: info.paperSize.width - info.leftMargin - info.rightMargin,
            height: info.paperSize.height - info.topMargin - info.bottomMargin)
        let scale = Swift.min(
            printable.width / CGFloat(image.width), printable.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)

        let view = NSImageView(frame: CGRect(origin: .zero, size: size))
        view.image = NSImage(cgImage: image, size: size)
        view.imageScaling = .scaleProportionallyUpOrDown

        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = jobTitle
        operation.run()
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
