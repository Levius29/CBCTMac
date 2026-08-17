#if canImport(Metal)

import DICOMCore
import Foundation
import Metal
import simd

// Esecuzione del kernel MPR.
//
// Il compito di questa classe è tradurre una `MPRPlane`, espressa in millimetri Patient e in
// Double, negli uniform in coordinate texture e in Float che lo shader si aspetta. Tutta la
// trigonometria resta qui, sulla CPU: il kernel riceve un'origine e tre passi già pronti e non
// fa altro che sommarli, il che è anche la ragione per cui è così economico.

/// Uniform passati al kernel.
///
/// Il layout deve corrispondere byte per byte a `MPRUniforms` in `Shaders/MPR.metal`.
/// I vettori sono `SIMD4` e non `SIMD3` perché in Metal `float3` occupa comunque 16 byte:
/// usare tre componenti da questo lato produrrebbe un disallineamento silenzioso, e il
/// sintomo sarebbero immagini inclinate senza alcun errore a segnalarlo.
struct MPRUniforms {
    var texOrigin: SIMD4<Float>
    var texRightStep: SIMD4<Float>
    var texDownStep: SIMD4<Float>
    var texNormalStep: SIMD4<Float>

    var slabSampleCount: Int32
    var projectionMode: Int32
    var rawWindowMin: Float
    var rawWindowMax: Float

    var rawScale: Float
    var rawOffset: Float
    var invertGrayscale: Float
    var padding: Float
}

/// Disegna piani arbitrari del volume in una texture 2D.
public final class MPRRenderer {

    private let device: MTLDevice
    private let pipelineState: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        self.device = device

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: Bundle.module)
        } catch {
            throw MPRRendererError.shaderLibraryUnavailable(underlying: String(describing: error))
        }

        guard let function = library.makeFunction(name: "mprSample") else {
            throw MPRRendererError.kernelNotFound(name: "mprSample")
        }

        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw MPRRendererError.pipelineCreationFailed(underlying: String(describing: error))
        }
    }

    // MARK: Disegno

    /// Codifica il campionamento del piano nella texture di destinazione.
    ///
    /// Non attende il completamento: il chiamante decide quando fare `commit` e se attendere.
    /// Così una griglia 2×2 accoda quattro viste su un solo command buffer invece di
    /// sincronizzarsi quattro volte.
    public func encode(
        plane: MPRPlane,
        volume: VolumeTexture,
        windowLevel: DensityWindow,
        invertGrayscale: Bool = false,
        into output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {

        let pixelWidth = output.width
        let pixelHeight = output.height
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        var uniforms = makeUniforms(
            plane: plane,
            volume: volume,
            windowLevel: windowLevel,
            invertGrayscale: invertGrayscale,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MPRRendererError.encoderCreationFailed
        }
        encoder.label = "MPR \(pixelWidth)×\(pixelHeight)"
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(volume.texture, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<MPRUniforms>.stride, index: 0)

        // La griglia non multipla del gruppo è gestita dal controllo di bordo dentro il
        // kernel, quindi si può arrotondare per eccesso senza rischi.
        let threadgroupWidth = min(pipelineState.threadExecutionWidth, pixelWidth)
        let threadgroupHeight = min(
            max(pipelineState.maxTotalThreadsPerThreadgroup / max(threadgroupWidth, 1), 1),
            pixelHeight)
        let threadgroupSize = MTLSize(
            width: max(threadgroupWidth, 1), height: max(threadgroupHeight, 1), depth: 1)
        let threadgroupCount = MTLSize(
            width: (pixelWidth + threadgroupSize.width - 1) / threadgroupSize.width,
            height: (pixelHeight + threadgroupSize.height - 1) / threadgroupSize.height,
            depth: 1)

        encoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()
    }

    // MARK: Costruzione degli uniform

    func makeUniforms(
        plane: MPRPlane,
        volume: VolumeTexture,
        windowLevel: DensityWindow,
        invertGrayscale: Bool,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> MPRUniforms {

        let toTexture = volume.patientToTexture

        // Origine, passi e slab prima in millimetri Patient, poi nello spazio texture.
        let originMM = plane.originMM(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let rightStepMM = plane.rightStepMM(pixelWidth: pixelWidth)
        let downStepMM = plane.downStepMM(pixelHeight: pixelHeight)
        let slabStepMM = plane.slabStepMM(geometry: volume.geometry)

        // L'origine è un **punto** e va trasformata con la traslazione; i passi sono
        // **direzioni** e vanno trasformati senza. Confondere le due cose è l'errore che
        // sposta l'immagine di una costante, ed è il motivo per cui `Transform3D` espone due
        // metodi distinti invece di uno solo.
        let texOrigin = toTexture.apply(toPoint: originMM)
        let texRightStep = toTexture.apply(toVector: rightStepMM)
        let texDownStep = toTexture.apply(toVector: downStepMM)
        let texNormalStep = toTexture.apply(toVector: slabStepMM)

        // Finestra e livello arrivano in unità di densità: qui si tornano ai valori grezzi su
        // cui lavora lo shader. Con slope negativo gli estremi si scambiano, quindi si
        // riordinano invece di dare per scontato che il minimo resti il minimo.
        let rawA = volume.rawValue(fromDensity: windowLevel.lowerBound)
        let rawB = volume.rawValue(fromDensity: windowLevel.upperBound)

        return MPRUniforms(
            texOrigin: SIMD4<Float>(
                Float(texOrigin.x), Float(texOrigin.y), Float(texOrigin.z), 0),
            texRightStep: SIMD4<Float>(
                Float(texRightStep.x), Float(texRightStep.y), Float(texRightStep.z), 0),
            texDownStep: SIMD4<Float>(
                Float(texDownStep.x), Float(texDownStep.y), Float(texDownStep.z), 0),
            texNormalStep: SIMD4<Float>(
                Float(texNormalStep.x), Float(texNormalStep.y), Float(texNormalStep.z), 0),
            slabSampleCount: Int32(plane.slabSampleCount(geometry: volume.geometry)),
            projectionMode: plane.projection.shaderMode,
            rawWindowMin: Float(min(rawA, rawB)),
            rawWindowMax: Float(max(rawA, rawB)),
            rawScale: volume.rawScale,
            rawOffset: volume.rawOffset,
            invertGrayscale: invertGrayscale ? 1 : 0,
            padding: 0)
    }

    // MARK: Texture di destinazione

    /// Crea una texture adatta a ricevere il risultato.
    ///
    /// `bgra8Unorm` e non un formato a più bit perché lo shader emette già il risultato di
    /// finestra e livello, cioè un valore in [0,1] destinato allo schermo: la profondità in
    /// più andrebbe sprecata. Il dato a piena precisione resta nel volume, dove serve.
    public func makeOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MPRRendererError.outputTextureCreationFailed(width: width, height: height)
        }
        return texture
    }
}

// MARK: - Errori

public enum MPRRendererError: Error, Hashable, Sendable {
    case shaderLibraryUnavailable(underlying: String)
    case kernelNotFound(name: String)
    case pipelineCreationFailed(underlying: String)
    case encoderCreationFailed
    case outputTextureCreationFailed(width: Int, height: Int)

    public var localizedDescription: String {
        switch self {
        case .shaderLibraryUnavailable(let detail):
            return "Libreria Metal non caricabile: \(detail)"
        case .kernelNotFound(let name):
            return "Kernel «\(name)» non trovato nella libreria Metal."
        case .pipelineCreationFailed(let detail):
            return "Creazione della pipeline di calcolo fallita: \(detail)"
        case .encoderCreationFailed:
            return "Impossibile creare l'encoder di calcolo."
        case .outputTextureCreationFailed(let w, let h):
            return "Impossibile creare la texture di destinazione \(w)×\(h)."
        }
    }
}

#endif
