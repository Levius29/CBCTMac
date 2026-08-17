#if canImport(Metal)

import DICOMCore
import Foundation
import Metal
import VolumeKit
import simd

// Driver della ricostruzione panoramica.
//
// Come per gli altri renderer, la geometria si risolve qui in Double e il kernel riceve valori
// già in coordinate texture. La differenza è che al posto di quattro vettori passa un buffer
// con una voce per colonna, perché ogni colonna del panorex campiona un piano diverso.

/// Voce per colonna. Il layout deve corrispondere a `PanoramicColumn` in `Shaders/Panoramic.metal`.
struct PanoramicColumnData {
    var texTop: SIMD4<Float>
    var texSlabStep: SIMD4<Float>
}

/// Uniform comuni. Corrisponde a `PanoramicUniforms` nello shader.
struct PanoramicUniformData {
    var texDownStep: SIMD4<Float>

    var slabSampleCount: Int32
    var projectionMode: Int32
    var rawWindowMin: Float
    var rawWindowMax: Float

    var rawScale: Float
    var rawOffset: Float
    var invertGrayscale: Float
    var padding: Float
}

public final class PanoramicRenderer {

    private let device: MTLDevice
    private let pipelineState: MTLComputePipelineState

    /// Buffer delle colonne, riusato fra i fotogrammi.
    ///
    /// Riallocarlo a ogni ridisegno significherebbe una allocazione da decine di kilobyte per
    /// fotogramma mentre l'utente trascina un punto della curva, cioè proprio quando serve
    /// reattività. Si ricrea solo se serve più capienza.
    private var columnBuffer: MTLBuffer?
    private var columnCapacity: Int = 0

    public init(device: MTLDevice) throws {
        self.device = device

        let library: MTLLibrary
        do {
            library = try MetalShaderLibrary.load(
                device: device, bundle: Bundle.module, sourceName: "Panoramic")
        } catch {
            throw PanoramicRendererError.shaderLibraryUnavailable(
                underlying: String(describing: error))
        }
        guard let function = library.makeFunction(name: "panoramicSample") else {
            throw PanoramicRendererError.kernelNotFound(name: "panoramicSample")
        }
        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw PanoramicRendererError.pipelineCreationFailed(
                underlying: String(describing: error))
        }
    }

    // MARK: Disegno

    public func encode(
        layout: PanoramicLayout,
        volume: VolumeTexture,
        windowLevel: DensityWindow,
        invertGrayscale: Bool = false,
        into output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {

        let pixelWidth = output.width
        let pixelHeight = output.height
        guard pixelWidth > 0, pixelHeight > 0, layout.curve.isUsable else { return }

        let samples = layout.columnSamples(pixelWidth: pixelWidth)
        guard samples.count >= pixelWidth else { return }

        let toTexture = volume.patientToTexture
        let slabCount = layout.slabSampleCount(geometry: volume.geometry)

        // Una voce per colonna, calcolata sulla CPU: la spline non entra nello shader.
        var columns = [PanoramicColumnData](
            repeating: PanoramicColumnData(texTop: .zero, texSlabStep: .zero),
            count: pixelWidth)

        for index in 0..<pixelWidth {
            let sample = samples[index]
            let topMM = layout.topOfColumn(sample)
            let slabStepMM = layout.slabStep(for: sample, sampleCount: slabCount)

            // Il punto porta la traslazione, il passo no.
            let texTop = toTexture.apply(toPoint: topMM)
            let texSlab = toTexture.apply(toVector: slabStepMM)

            columns[index] = PanoramicColumnData(
                texTop: SIMD4<Float>(Float(texTop.x), Float(texTop.y), Float(texTop.z), 0),
                texSlabStep: SIMD4<Float>(
                    Float(texSlab.x), Float(texSlab.y), Float(texSlab.z), 0))
        }

        try ensureColumnBuffer(count: pixelWidth)
        guard let columnBuffer else { return }
        columns.withUnsafeBytes { raw in
            columnBuffer.contents().copyMemory(
                from: raw.baseAddress!,
                byteCount: pixelWidth * MemoryLayout<PanoramicColumnData>.stride)
        }

        // Il passo verticale è lo stesso per ogni colonna, quindi resta negli uniform.
        let downStepMM = layout.downStepMM()
        let texDownStep = toTexture.apply(toVector: downStepMM)

        let rawA = volume.rawValue(fromDensity: windowLevel.lowerBound)
        let rawB = volume.rawValue(fromDensity: windowLevel.upperBound)

        var uniforms = PanoramicUniformData(
            texDownStep: SIMD4<Float>(
                Float(texDownStep.x), Float(texDownStep.y), Float(texDownStep.z), 0),
            slabSampleCount: Int32(slabCount),
            projectionMode: layout.projection.shaderMode,
            rawWindowMin: Float(min(rawA, rawB)),
            rawWindowMax: Float(max(rawA, rawB)),
            rawScale: volume.rawScale,
            rawOffset: volume.rawOffset,
            invertGrayscale: invertGrayscale ? 1 : 0,
            padding: 0)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw PanoramicRendererError.encoderCreationFailed
        }
        encoder.label = "Panorex \(pixelWidth)×\(pixelHeight)"
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(volume.texture, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setBytes(&uniforms, length: MemoryLayout<PanoramicUniformData>.stride, index: 0)
        encoder.setBuffer(columnBuffer, offset: 0, index: 1)

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

    private func ensureColumnBuffer(count: Int) throws {
        guard count > columnCapacity || columnBuffer == nil else { return }
        let length = count * MemoryLayout<PanoramicColumnData>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw PanoramicRendererError.bufferAllocationFailed(bytes: length)
        }
        buffer.label = "Colonne panorex"
        columnBuffer = buffer
        columnCapacity = count
    }

    /// Texture di destinazione per il panorex.
    public func makeOutputTexture(width: Int, height: Int) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: max(width, 1),
            height: max(height, 1),
            mipmapped: false)
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw PanoramicRendererError.outputTextureCreationFailed(width: width, height: height)
        }
        return texture
    }
}

// MARK: - Errori

public enum PanoramicRendererError: Error, Hashable, Sendable {
    case shaderLibraryUnavailable(underlying: String)
    case kernelNotFound(name: String)
    case pipelineCreationFailed(underlying: String)
    case encoderCreationFailed
    case bufferAllocationFailed(bytes: Int)
    case outputTextureCreationFailed(width: Int, height: Int)

    public var localizedDescription: String {
        switch self {
        case .shaderLibraryUnavailable(let detail):
            return "Libreria Metal di DentalKit non caricabile: \(detail)"
        case .kernelNotFound(let name):
            return "Kernel «\(name)» non trovato."
        case .pipelineCreationFailed(let detail):
            return "Creazione della pipeline panoramica fallita: \(detail)"
        case .encoderCreationFailed:
            return "Impossibile creare l'encoder di calcolo per il panorex."
        case .bufferAllocationFailed(let bytes):
            return "Impossibile allocare \(bytes) byte per le colonne del panorex."
        case .outputTextureCreationFailed(let w, let h):
            return "Impossibile creare la texture del panorex \(w)×\(h)."
        }
    }
}

#endif
