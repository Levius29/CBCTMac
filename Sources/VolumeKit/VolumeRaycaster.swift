#if canImport(Metal)

import DICOMCore
import Foundation
import Metal
import simd

// Driver del rendering volumetrico.
//
// Come per `MPRRenderer`, tutta la geometria si risolve qui sulla CPU e in Double: il kernel
// riceve un'origine e tre passi gia' pronti in coordinate texture e si limita a sommarli.
// Grazie alla proiezione ortografica la direzione del raggio e' identica per ogni pixel, quindi
// la struttura degli uniform e' la stessa dell'MPR con un passo in piu'.

/// Uniform del raycaster. Il layout deve corrispondere byte per byte a `RaycastUniforms`
/// in `Shaders/Raycast.metal`.
struct RaycastUniforms {
    var texOrigin: SIMD4<Float>
    var texRightStep: SIMD4<Float>
    var texDownStep: SIMD4<Float>
    var texRayStep: SIMD4<Float>
    var gradientScale: SIMD4<Float>
    var lightDirection: SIMD4<Float>

    var sampleCount: Int32
    var rawScale: Float
    var rawOffset: Float
    var rescaleSlope: Float

    var rescaleIntercept: Float
    var densityMin: Float
    var densityMax: Float
    var ambient: Float

    var diffuse: Float
    var specular: Float
    var shininess: Float
    var gradientStepTex: Float
}

public final class VolumeRaycaster {

    private let device: MTLDevice
    private let pipelineState: MTLComputePipelineState

    /// Tabella della transfer function, come texture 2D alta un pixel.
    ///
    /// Non `texture1d`: una 2D di altezza uno si campiona con filtro lineare su qualunque
    /// famiglia di GPU, mentre il supporto al filtraggio delle 1D e' meno uniforme. Costa
    /// nulla e toglie una variabile.
    private var tableTexture: MTLTexture?
    private var cachedTableKey: Int?

    public static let tableEntryCount = 512

    public init(device: MTLDevice) throws {
        self.device = device

        let library: MTLLibrary
        do {
            library = try MetalShaderLibrary.load(
                device: device, bundle: Bundle.module, sourceName: "Raycast")
        } catch {
            throw MPRRendererError.shaderLibraryUnavailable(underlying: String(describing: error))
        }
        guard let function = library.makeFunction(name: "volumeRaycast") else {
            throw MPRRendererError.kernelNotFound(name: "volumeRaycast")
        }
        do {
            self.pipelineState = try device.makeComputePipelineState(function: function)
        } catch {
            throw MPRRendererError.pipelineCreationFailed(underlying: String(describing: error))
        }
    }

    // MARK: Tabella

    /// Aggiorna la texture della transfer function se e' cambiata.
    ///
    /// Ricostruirla a ogni fotogramma sarebbe inutile: cambia quando l'utente muove un punto di
    /// controllo, non sessanta volte al secondo. La chiave di cache tiene conto anche
    /// dell'intervallo di densita', perche' la stessa rampa su un volume diverso produce una
    /// tabella diversa.
    private func updateTable(
        _ function: TransferFunction, densityRange: ClosedRange<Double>
    ) throws {
        var hasher = Hasher()
        hasher.combine(function)
        hasher.combine(densityRange.lowerBound)
        hasher.combine(densityRange.upperBound)
        let key = hasher.finalize()

        if key == cachedTableKey, tableTexture != nil { return }

        let entries = Self.tableEntryCount
        let values = function.bake(entryCount: entries, densityRange: densityRange)

        if tableTexture == nil {
            // `rgba32Float` e non `rgba16Float`: `Float16` non è disponibile su Mac Intel, e
            // una tabella da 512 voci occupa 8 KB anche a precisione piena. Risparmiare quattro
            // kilobyte al prezzo di un vincolo di architettura sarebbe un pessimo affare.
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba32Float, width: entries, height: 1, mipmapped: false)
            descriptor.usage = [.shaderRead]
            descriptor.storageMode = .shared
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw MPRRendererError.outputTextureCreationFailed(width: entries, height: 1)
            }
            tableTexture = texture
        }

        values.withUnsafeBytes { raw in
            tableTexture?.replace(
                region: MTLRegionMake2D(0, 0, entries, 1),
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: entries * 4 * MemoryLayout<Float>.stride)
        }

        cachedTableKey = key
    }

    // MARK: Disegno

    public func encode(
        camera: VolumeCamera,
        volume: VolumeTexture,
        transferFunction: TransferFunction,
        quality: RenderQuality,
        lighting: LightingParameters = .standard,
        into output: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {

        let pixelWidth = output.width
        let pixelHeight = output.height
        guard pixelWidth > 0, pixelHeight > 0 else { return }

        let densityRange = densityRange(for: volume)
        try updateTable(transferFunction, densityRange: densityRange)
        guard let tableTexture else { return }

        var uniforms = makeUniforms(
            camera: camera,
            volume: volume,
            quality: quality,
            lighting: lighting,
            densityRange: densityRange,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MPRRendererError.encoderCreationFailed
        }
        encoder.label = "Raycast \(pixelWidth)×\(pixelHeight)"
        encoder.setComputePipelineState(pipelineState)
        encoder.setTexture(volume.texture, index: 0)
        encoder.setTexture(tableTexture, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setBytes(&uniforms, length: MemoryLayout<RaycastUniforms>.stride, index: 0)

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

    // MARK: Uniform

    private func densityRange(for volume: VolumeTexture) -> ClosedRange<Double> {
        // Intervallo generoso e fisso invece che dedotto dai dati: cosi' i preset della
        // transfer function, che sono espressi in valori assoluti, significano la stessa cosa
        // su volumi diversi. Adattarlo ai dati farebbe scivolare i colori da un caso all'altro.
        -1200...3600
    }

    func makeUniforms(
        camera: VolumeCamera,
        volume: VolumeTexture,
        quality: RenderQuality,
        lighting: LightingParameters,
        densityRange: ClosedRange<Double>,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> RaycastUniforms {

        let geometry = volume.geometry
        let toTexture = volume.patientToTexture

        let forward = camera.forward
        let right = camera.right
        let down = camera.down

        // Raggio della sfera che contiene il volume: definisce quanto indietro far partire i
        // raggi e quanto lontano farli arrivare, indipendentemente dall'angolo di vista.
        var radius = 0.0
        for corner in geometry.boundingBoxCornersMM {
            radius = max(radius, corner.distance(to: camera.targetMM))
        }
        radius = max(radius, 1.0)

        // Passo di campionamento, legato al voxel piu' fine: sotto mezzo voxel non c'e'
        // informazione da guadagnare, sopra il voxel intero si perdono le strutture sottili.
        let spacing = geometry.spacingMM
        let finestSpacing = min(spacing.x, min(spacing.y, spacing.z))
        let stepMM = max(finestSpacing * quality.stepInVoxels, 1e-4)
        let sampleCount = max(1, Int((2.0 * radius / stepMM).rounded(.up)))

        // Inquadratura in millimetri.
        let halfHeight = camera.halfHeightMM
        let aspect = Double(pixelWidth) / Double(max(pixelHeight, 1))
        let halfWidth = halfHeight * aspect

        let rightStepMM = right * (2.0 * halfWidth / Double(pixelWidth))
        let downStepMM = down * (2.0 * halfHeight / Double(pixelHeight))
        let rayStepMM = forward * stepMM

        // Origine del raggio del pixel (0,0): angolo alto-sinistro del piano di ingresso,
        // arretrato di un raggio rispetto al bersaglio, piu' il consueto mezzo pixel.
        let planeCentre = camera.targetMM - forward * radius
        let originMM =
            planeCentre
            - right * halfWidth
            - down * halfHeight
            + rightStepMM * 0.5
            + downStepMM * 0.5

        // Punti con la traslazione, direzioni senza: e' la distinzione che, se sbagliata,
        // sposta l'intera immagine di una costante.
        let texOrigin = toTexture.apply(toPoint: originMM)
        let texRightStep = toTexture.apply(toVector: rightStepMM)
        let texDownStep = toTexture.apply(toVector: downStepMM)
        let texRayStep = toTexture.apply(toVector: rayStepMM)

        // Il gradiente in spazio texture va riportato in millimetri, altrimenti su volumi
        // anisotropici le superfici risultano inclinate in modo sistematico. Vale per volumi
        // allineati agli assi, che e' il caso di ogni CBCT: per un volume ruotato servirebbe
        // la trasposta della Jacobiana inversa, e non ne abbiamo incontrati.
        let physical = geometry.physicalSizeMM
        let gradientScale = Vec3(
            1.0 / max(physical.x, 1e-6),
            1.0 / max(physical.y, 1e-6),
            1.0 / max(physical.z, 1e-6))

        // Luce solidale alla camera, da sinistra e dall'alto: e' l'illuminazione che rende
        // leggibile il rilievo senza che l'utente debba orientare una sorgente.
        let lightDirection =
            (-forward - right * 0.4 - down * 0.5).normalized ?? Vec3(0, -1, 0)

        // Passo delle differenze centrali: mezzo voxel, espresso in unita' di texture.
        let gradientStepTex = 0.5 / Double(max(geometry.columnCount, 1))

        return RaycastUniforms(
            texOrigin: SIMD4<Float>(
                Float(texOrigin.x), Float(texOrigin.y), Float(texOrigin.z), 0),
            texRightStep: SIMD4<Float>(
                Float(texRightStep.x), Float(texRightStep.y), Float(texRightStep.z), 0),
            texDownStep: SIMD4<Float>(
                Float(texDownStep.x), Float(texDownStep.y), Float(texDownStep.z), 0),
            texRayStep: SIMD4<Float>(
                Float(texRayStep.x), Float(texRayStep.y), Float(texRayStep.z), 0),
            gradientScale: SIMD4<Float>(
                Float(gradientScale.x), Float(gradientScale.y), Float(gradientScale.z), 0),
            lightDirection: SIMD4<Float>(
                Float(lightDirection.x), Float(lightDirection.y), Float(lightDirection.z), 0),
            sampleCount: Int32(sampleCount),
            rawScale: volume.rawScale,
            rawOffset: volume.rawOffset,
            rescaleSlope: Float(volume.rescaleSlope),
            rescaleIntercept: Float(volume.rescaleIntercept),
            densityMin: Float(densityRange.lowerBound),
            densityMax: Float(densityRange.upperBound),
            ambient: Float(lighting.ambient),
            diffuse: Float(lighting.diffuse),
            specular: Float(lighting.specular),
            shininess: Float(max(lighting.shininess, 1)),
            gradientStepTex: Float(gradientStepTex)
        )
    }

    /// Texture di destinazione per il rendering 3D.
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

#endif
