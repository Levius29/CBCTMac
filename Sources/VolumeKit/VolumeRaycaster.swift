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
        guard let upscale = library.makeFunction(name: "upscaleBlit") else {
            throw MPRRendererError.kernelNotFound(name: "upscaleBlit")
        }
        do {
            self.upscaleState = try device.makeComputePipelineState(function: upscale)
        } catch {
            throw MPRRendererError.pipelineCreationFailed(underlying: String(describing: error))
        }
    }

    /// Pipeline che riporta il disegno a risoluzione ridotta sulla dimensione piena.
    private let upscaleState: MTLComputePipelineState

    /// Texture intermedia per il disegno a risoluzione ridotta, tenuta fra un fotogramma e
    /// l'altro: ricrearla sessanta volte al secondo sarebbe un'allocazione per fotogramma.
    private var reducedTexture: MTLTexture?

    // MARK: Tabella

    /// Aggiorna la texture della transfer function se e' cambiata.
    ///
    /// Ricostruirla a ogni fotogramma sarebbe inutile: cambia quando l'utente muove un punto di
    /// controllo, non sessanta volte al secondo. La chiave di cache tiene conto anche
    /// dell'intervallo di densita', perche' la stessa rampa su un volume diverso produce una
    /// tabella diversa.
    private func updateTable(
        _ function: TransferFunction,
        densityRange: ClosedRange<Double>,
        quality: RenderQuality
    ) throws {
        // Il passo entra nella chiave: la tabella porta la correzione per il passo, quindi
        // cambiando qualità va rifatta. Senza, ruotando si sarebbe continuato a usare la tabella
        // della qualità precedente — il difetto che la correzione doveva togliere, spostato.
        let stepScale = RayCompositing.opacityStepScale(for: quality)
        var hasher = Hasher()
        hasher.combine(function)
        hasher.combine(densityRange.lowerBound)
        hasher.combine(densityRange.upperBound)
        hasher.combine(stepScale)
        let key = hasher.finalize()

        if key == cachedTableKey, tableTexture != nil { return }

        let entries = Self.tableEntryCount
        let values = function.bake(
            entryCount: entries, densityRange: densityRange, opacityStepScale: stepScale)

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

        guard output.width > 0, output.height > 0 else { return }

        // # A risoluzione ridotta mentre si gira
        //
        // Il divisore della qualità esisteva e non lo leggeva nessuno: si è sempre disegnato un
        // raggio per pixel del drawable, cioè qualche milione su un pannello Retina, ciascuno
        // con qualche centinaio di passi e sei campioni di gradiente per passo. È la ragione per
        // cui il riquadro 3D era lento a girare, e nessun ritocco al passo del raggio poteva
        // rimediarci: il numero dei raggi non cambiava.
        //
        // Metà lato durante la rotazione sono **quattro volte** meno raggi. Il dettaglio perso
        // su un'immagine in movimento non si coglie, e al rilascio si torna pieni.
        let divisor = max(quality.resolutionDivisor, 1)
        let target = try renderTarget(for: output, divisor: divisor)

        let pixelWidth = target.width
        let pixelHeight = target.height

        let densityRange = densityRange(for: volume)
        try updateTable(
            transferFunction, densityRange: densityRange, quality: quality)
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
        encoder.setTexture(target, index: 2)
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

        // A piena risoluzione si è disegnato direttamente nel drawable e non c'è altro da fare.
        if target !== output {
            try upscale(from: target, into: output, commandBuffer: commandBuffer)
        }
    }

    /// La texture su cui disegnare: il drawable stesso, o una più piccola da ingrandire.
    private func renderTarget(for output: MTLTexture, divisor: Int) throws -> MTLTexture {
        guard divisor > 1 else { return output }
        let width = max(output.width / divisor, 1)
        let height = max(output.height / divisor, 1)

        if let existing = reducedTexture, existing.width == width, existing.height == height {
            return existing
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: output.pixelFormat, width: width, height: height, mipmapped: false)
        // Scritta dal raycaster, riletta dall'ingranditore: servono entrambi gli usi.
        descriptor.usage = [.shaderWrite, .shaderRead]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MPRRendererError.outputTextureCreationFailed(width: width, height: height)
        }
        reducedTexture = texture
        return texture
    }

    /// Riporta il disegno ridotto sulla dimensione piena, interpolando.
    private func upscale(
        from source: MTLTexture, into destination: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MPRRendererError.encoderCreationFailed
        }
        encoder.label = "Ingrandimento \(source.width)×\(source.height) → "
            + "\(destination.width)×\(destination.height)"
        encoder.setComputePipelineState(upscaleState)
        encoder.setTexture(source, index: 0)
        encoder.setTexture(destination, index: 1)

        let width = min(upscaleState.threadExecutionWidth, destination.width)
        let height = min(
            max(upscaleState.maxTotalThreadsPerThreadgroup / max(width, 1), 1),
            destination.height)
        let size = MTLSize(width: max(width, 1), height: max(height, 1), depth: 1)
        let count = MTLSize(
            width: (destination.width + size.width - 1) / size.width,
            height: (destination.height + size.height - 1) / size.height,
            depth: 1)
        encoder.dispatchThreadgroups(count, threadsPerThreadgroup: size)
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
            gradientStepTex: Float(gradientStepTex),
            boundarySharpness: Float(lighting.boundarySharpness),
            gradientReference: Float(
                RayCompositing.gradientReference(
                    densitySpan: densityRange.upperBound - densityRange.lowerBound,
                    rescaleSlope: volume.rescaleSlope,
                    rawScale: Double(volume.rawScale))),
            reserved0: 0,
            reserved1: 0
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
