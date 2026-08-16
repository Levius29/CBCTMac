#if canImport(Metal)

import DICOMCore
import Foundation
import Metal
import simd

// Il volume sulla GPU.
//
// Lato GPU del Contratto 3 (docs/architecture.md). Texture 3D `.r16Unorm`: sedici bit pieni,
// nessuna perdita, e soprattutto **filtrabile in hardware**, che è il requisito da cui discende
// tutta la scelta. Senza filtraggio trilineare hardware ogni piano obliquo verrebbe a scalini.
//
// `.r16Float` sembrerebbe l'alternativa naturale ed è invece una trappola: Float16 ha 11 bit di
// mantissa e rappresenta esattamente gli interi solo fino a 2048, con buchi crescenti oltre.
// I valori CBCT stanno proprio in quell'intervallo, quindi si perderebbero i bit bassi senza
// che l'immagine mostri il minimo segno del problema.

/// Volume caricato in una texture 3D, pronto per il campionamento.
///
/// `@unchecked Sendable`: `MTLTexture` non è `Sendable` in Swift 6, ma questa texture è
/// immutabile dopo la costruzione — si scrive una volta sola nell'inizializzatore e da lì in poi
/// si legge soltanto. Attraversare gli attori è quindi sicuro.
public final class VolumeTexture: @unchecked Sendable {

    /// Traslazione applicata in fase di upload per portare `Int16` in `UInt16`.
    public static let signedToUnsignedOffset: Int32 = 32768
    /// Fattore che riporta il valore unorm [0,1] al passo intero originale.
    public static let unormScale: Float = 65535.0

    public let texture: MTLTexture
    public let geometry: VolumeGeometry

    /// Da valore campionato in [0,1] a valore grezzo: `raw = sampled · rawScale + rawOffset`.
    public var rawScale: Float { Self.unormScale }
    public var rawOffset: Float { -Float(Self.signedToUnsignedOffset) }

    /// Rescale DICOM del volume di origine, per convertire fra grezzo e densità.
    public let rescaleSlope: Double
    public let rescaleIntercept: Double
    public let densityUnit: DensityUnit

    /// Millimetri Patient → coordinate texture normalizzate [0,1].
    ///
    /// Include lo scarto di mezzo voxel: l'indice `i` corrisponde alla coordinata
    /// `(i + 0.5) / dimensione`, perché i campioni stanno al **centro** dei voxel e non al
    /// loro spigolo. Dimenticarlo sposta l'intera immagine di mezzo voxel, che su una CBCT a
    /// 0,2 mm è un decimo di millimetro: invisibile a occhio, sistematico in ogni misura.
    public let patientToTexture: Transform3D

    /// Dimensione massima per lato supportata dalle GPU Apple per una texture 3D.
    public static let maxDimension = 2048

    // MARK: Costruzione

    public init(volume: Volume, device: MTLDevice) throws {
        let geometry = volume.geometry

        guard geometry.columnCount <= Self.maxDimension,
            geometry.rowCount <= Self.maxDimension,
            geometry.sliceCount <= Self.maxDimension
        else {
            throw VolumeTextureError.volumeTooLarge(
                columns: geometry.columnCount,
                rows: geometry.rowCount,
                slices: geometry.sliceCount,
                limit: Self.maxDimension)
        }

        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .r16Unorm
        descriptor.width = geometry.columnCount
        descriptor.height = geometry.rowCount
        descriptor.depth = geometry.sliceCount
        descriptor.mipmapLevelCount = 1
        descriptor.usage = [.shaderRead]
        // Su Apple Silicon la memoria è unificata: `shared` evita del tutto la copia
        // CPU→GPU, che su mezzo gigabyte non è un dettaglio.
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            let bytes = geometry.voxelCount * 2
            throw VolumeTextureError.allocationFailed(bytes: bytes)
        }

        self.texture = texture
        self.geometry = geometry
        self.rescaleSlope = volume.rescaleSlope
        self.rescaleIntercept = volume.rescaleIntercept
        self.densityUnit = volume.densityUnit

        // Voxel → texture: divisione per le dimensioni, con lo scarto di mezzo voxel.
        let voxelToTexture = Transform3D(
            columnX: Vec3(1.0 / Double(geometry.columnCount), 0, 0),
            columnY: Vec3(0, 1.0 / Double(geometry.rowCount), 0),
            columnZ: Vec3(0, 0, 1.0 / Double(geometry.sliceCount)),
            origin: Vec3(
                0.5 / Double(geometry.columnCount),
                0.5 / Double(geometry.rowCount),
                0.5 / Double(geometry.sliceCount))
        )
        self.patientToTexture = voxelToTexture.concatenating(geometry.patientToVoxel)

        try Self.upload(volume: volume, into: texture)
    }

    /// Carica i campioni una slice alla volta.
    ///
    /// La conversione `Int16 → UInt16` richiede un buffer d'appoggio. Farlo sull'intero volume
    /// significherebbe tenere in memoria due copie da mezzo gigabyte nello stesso istante; per
    /// slice il picco aggiuntivo è di qualche centinaio di kilobyte.
    private static func upload(volume: Volume, into texture: MTLTexture) throws {
        let geometry = volume.geometry
        let columns = geometry.columnCount
        let rows = geometry.rowCount
        let pixelsPerSlice = columns * rows
        let bytesPerRow = columns * MemoryLayout<UInt16>.stride
        let bytesPerSlice = bytesPerRow * rows

        var scratch = [UInt16](repeating: 0, count: pixelsPerSlice)
        let offset = signedToUnsignedOffset

        volume.withUnsafeSamples { source in
            for k in 0..<geometry.sliceCount {
                let base = k * pixelsPerSlice

                for n in 0..<pixelsPerSlice {
                    // Somma di 32768: porta l'intervallo [-32768, 32767] in [0, 65535]
                    // senza perdere alcun bit. Lo shader inverte l'operazione.
                    scratch[n] = UInt16(truncatingIfNeeded: Int32(source[base + n]) + offset)
                }

                let region = MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: k),
                    size: MTLSize(width: columns, height: rows, depth: 1))

                scratch.withUnsafeBytes { raw in
                    texture.replace(
                        region: region,
                        mipmapLevel: 0,
                        slice: 0,
                        withBytes: raw.baseAddress!,
                        bytesPerRow: bytesPerRow,
                        bytesPerImage: bytesPerSlice)
                }
            }
        }
    }

    // MARK: Conversioni di comodo

    /// Da valore grezzo a densità nell'unità del volume.
    public func densityValue(fromRaw raw: Double) -> Double {
        raw * rescaleSlope + rescaleIntercept
    }

    /// Da densità a valore grezzo. Serve a tradurre finestra/livello, che l'utente imposta in
    /// unità di densità, nei valori grezzi su cui lavora lo shader.
    public func rawValue(fromDensity density: Double) -> Double {
        guard rescaleSlope != 0 else { return density }
        return (density - rescaleIntercept) / rescaleSlope
    }

    /// Occupazione in byte della texture.
    public var byteCount: Int { geometry.voxelCount * 2 }
}

// MARK: - Errori

public enum VolumeTextureError: Error, Hashable, Sendable {
    case volumeTooLarge(columns: Int, rows: Int, slices: Int, limit: Int)
    case allocationFailed(bytes: Int)
    case metalUnavailable

    public var localizedDescription: String {
        switch self {
        case .volumeTooLarge(let c, let r, let s, let limit):
            return "Volume \(c)×\(r)×\(s) oltre il limite di \(limit) voxel per lato "
                + "supportato dalla GPU. Sarà necessario ridurre la risoluzione."
        case .allocationFailed(let bytes):
            let mb = Double(bytes) / 1_048_576.0
            return String(
                format: "Impossibile allocare la texture del volume (%.0f MB).", mb)
        case .metalUnavailable:
            return "Nessun dispositivo Metal disponibile su questo Mac."
        }
    }
}

// MARK: - Ponte verso simd

extension Transform3D {
    /// Conversione a `simd_float4x4`.
    ///
    /// È l'unico punto in cui la geometria scende a precisione singola, e avviene per
    /// necessità: gli shader lavorano in Float. Tutto ciò che sta a monte resta in Double,
    /// come prescrive il § 3 di docs/architecture.md.
    public var simdFloat4x4: simd_float4x4 {
        simd_float4x4(
            SIMD4<Float>(Float(columnX.x), Float(columnX.y), Float(columnX.z), 0),
            SIMD4<Float>(Float(columnY.x), Float(columnY.y), Float(columnY.z), 0),
            SIMD4<Float>(Float(columnZ.x), Float(columnZ.y), Float(columnZ.z), 0),
            SIMD4<Float>(Float(origin.x), Float(origin.y), Float(origin.z), 1)
        )
    }
}

extension Vec3 {
    public var simdFloat3: SIMD3<Float> {
        SIMD3<Float>(Float(x), Float(y), Float(z))
    }

    public var simdFloat4: SIMD4<Float> {
        SIMD4<Float>(Float(x), Float(y), Float(z), 0)
    }
}

#endif
