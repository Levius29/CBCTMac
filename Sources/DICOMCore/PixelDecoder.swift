import Foundation

// Decodifica dei pixel, dietro un protocollo.
//
// La Fase 1 gestisce in Swift puro le sintassi non compresse, che coprono la gran parte degli
// export CBCT. Le sintassi compresse arriveranno con `DCMTKPixelDecoder`, che si limiterà ad
// adottare questo stesso protocollo: nessun altro modulo dovrà cambiare.

// MARK: - Descrittore

/// Come sono organizzati i campioni di un'immagine, dai tag del gruppo 0028.
public struct PixelDescriptor: Hashable, Sendable {
    /// `Columns (0028,0011)`
    public let columns: Int
    /// `Rows (0028,0010)`
    public let rows: Int
    /// `BitsAllocated (0028,0100)` — 8 o 16 nei dati CBCT.
    public let bitsAllocated: Int
    /// `BitsStored (0028,0101)` — tipicamente 12–16 su CBCT.
    public let bitsStored: Int
    /// `HighBit (0028,0102)`
    public let highBit: Int
    /// `PixelRepresentation (0028,0103)`: 0 = senza segno, 1 = complemento a due.
    public let isSigned: Bool
    /// `SamplesPerPixel (0028,0002)` — 1 per le immagini in scala di grigi.
    public let samplesPerPixel: Int
    /// `NumberOfFrames (0028,0008)`, 1 se assente.
    public let frameCount: Int

    public init(
        columns: Int,
        rows: Int,
        bitsAllocated: Int,
        bitsStored: Int,
        highBit: Int,
        isSigned: Bool,
        samplesPerPixel: Int = 1,
        frameCount: Int = 1
    ) {
        self.columns = columns
        self.rows = rows
        self.bitsAllocated = bitsAllocated
        self.bitsStored = bitsStored
        self.highBit = highBit
        self.isSigned = isSigned
        self.samplesPerPixel = samplesPerPixel
        self.frameCount = frameCount
    }

    public var pixelsPerFrame: Int { columns * rows }
    public var bytesPerSample: Int { (bitsAllocated + 7) / 8 }
    public var bytesPerFrame: Int { pixelsPerFrame * bytesPerSample * samplesPerPixel }
}

// MARK: - Esito

/// Una slice decodificata.
public struct DecodedFrame: Sendable {
    /// Campioni normalizzati a `Int16`, in ordine riga per riga.
    public let samples: [Int16]

    /// Correzione da **sommare** a `RescaleIntercept` prima di calcolare le densità.
    ///
    /// Non è un dettaglio trascurabile. I dati senza segno a 16 bit occupano 0…65535 e non
    /// entrano in `Int16`: vengono traslati di −32768 per starci. La traslazione è esatta e
    /// reversibile, ma va compensata nell'intercetta, altrimenti tutte le densità risultano
    /// spostate di una costante — un errore che sposta l'intera scala e non altera per nulla
    /// l'aspetto dell'immagine, quindi passa inosservato.
    public let interceptAdjustment: Double

    public init(samples: [Int16], interceptAdjustment: Double = 0) {
        self.samples = samples
        self.interceptAdjustment = interceptAdjustment
    }
}

// MARK: - Protocollo

public protocol PixelDecoder: Sendable {
    func canDecode(_ transferSyntax: TransferSyntax) -> Bool

    /// Decodifica un fotogramma.
    /// - Parameter data: per le sintassi native, i byte di `PixelData` dell'intera immagine;
    ///   per quelle incapsulate, il frammento corrispondente al fotogramma.
    func decode(
        _ data: Data,
        frameIndex: Int,
        descriptor: PixelDescriptor,
        transferSyntax: TransferSyntax
    ) throws -> DecodedFrame
}

// MARK: - Errori

public enum PixelDecodingError: Error, Hashable, Sendable {
    case unsupportedTransferSyntax(TransferSyntax)
    case unsupportedBitsAllocated(Int)
    case unsupportedSamplesPerPixel(Int)
    case truncatedPixelData(expected: Int, available: Int)
    case frameIndexOutOfRange(Int, frameCount: Int)
    case invalidDescriptor(String)

    public var localizedDescription: String {
        switch self {
        case .unsupportedTransferSyntax(let ts):
            return "Sintassi di trasferimento non ancora supportata: \(ts.displayName). "
                + "Il supporto alle immagini compresse richiede DCMTK (vedi Fase 1.1)."
        case .unsupportedBitsAllocated(let bits):
            return "BitsAllocated = \(bits) non supportato: attesi 8 o 16."
        case .unsupportedSamplesPerPixel(let n):
            return "SamplesPerPixel = \(n) non supportato: attesa un'immagine in scala di grigi."
        case .truncatedPixelData(let expected, let available):
            return "PixelData troncato: attesi \(expected) byte, disponibili \(available)."
        case .frameIndexOutOfRange(let index, let count):
            return "Fotogramma \(index) fuori intervallo (\(count) disponibili)."
        case .invalidDescriptor(let detail):
            return "Descrittore pixel non valido: \(detail)."
        }
    }
}

// MARK: - Decoder nativo

/// Decodifica le sintassi non compresse in Swift puro.
///
/// Copre `implicitVRLittleEndian`, `explicitVRLittleEndian` ed `explicitVRBigEndian`.
/// Gestisce 8 e 16 bit, con e senza segno, e `BitsStored` minore di `BitsAllocated`.
public struct NativePixelDecoder: PixelDecoder {

    public init() {}

    public func canDecode(_ transferSyntax: TransferSyntax) -> Bool {
        transferSyntax.isNativelySupported
    }

    public func decode(
        _ data: Data,
        frameIndex: Int,
        descriptor d: PixelDescriptor,
        transferSyntax: TransferSyntax
    ) throws -> DecodedFrame {

        guard canDecode(transferSyntax) else {
            throw PixelDecodingError.unsupportedTransferSyntax(transferSyntax)
        }
        guard d.samplesPerPixel == 1 else {
            throw PixelDecodingError.unsupportedSamplesPerPixel(d.samplesPerPixel)
        }
        guard d.columns > 0, d.rows > 0 else {
            throw PixelDecodingError.invalidDescriptor("dimensioni \(d.columns)×\(d.rows)")
        }
        guard d.bitsStored > 0, d.bitsStored <= d.bitsAllocated else {
            throw PixelDecodingError.invalidDescriptor(
                "BitsStored \(d.bitsStored) incompatibile con BitsAllocated \(d.bitsAllocated)")
        }
        guard frameIndex >= 0, frameIndex < max(d.frameCount, 1) else {
            throw PixelDecodingError.frameIndexOutOfRange(frameIndex, frameCount: d.frameCount)
        }

        let pixelCount = d.pixelsPerFrame
        let frameBytes = d.bytesPerFrame
        let offset = frameIndex * frameBytes
        guard data.count >= offset + frameBytes else {
            throw PixelDecodingError.truncatedPixelData(
                expected: offset + frameBytes, available: data.count)
        }

        switch d.bitsAllocated {
        case 8:
            return decode8Bit(data, offset: offset, pixelCount: pixelCount, descriptor: d)
        case 16:
            return decode16Bit(
                data, offset: offset, pixelCount: pixelCount, descriptor: d,
                bigEndian: transferSyntax.isBigEndian)
        default:
            throw PixelDecodingError.unsupportedBitsAllocated(d.bitsAllocated)
        }
    }

    // MARK: 8 bit

    private func decode8Bit(
        _ data: Data, offset: Int, pixelCount: Int, descriptor d: PixelDescriptor
    ) -> DecodedFrame {
        var out = [Int16](repeating: 0, count: pixelCount)
        // A 8 bit ogni valore entra in Int16 senza traslazioni, con o senza segno.
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            if d.isSigned {
                for n in 0..<pixelCount {
                    out[n] = Int16(Int8(bitPattern: base[n]))
                }
            } else {
                for n in 0..<pixelCount {
                    out[n] = Int16(base[n])
                }
            }
        }
        return DecodedFrame(samples: out, interceptAdjustment: 0)
    }

    // MARK: 16 bit

    private func decode16Bit(
        _ data: Data, offset: Int, pixelCount: Int, descriptor d: PixelDescriptor,
        bigEndian: Bool
    ) -> DecodedFrame {

        // Maschera dei soli bit realmente occupati: i bit alti oltre `BitsStored` non sono
        // definiti dallo standard e vanno azzerati prima di qualunque interpretazione.
        let storedMask: UInt16 =
            d.bitsStored >= 16 ? 0xFFFF : UInt16((1 << d.bitsStored) - 1)

        // I dati senza segno a 16 bit pieni non entrano in Int16: si trasla di −32768 e si
        // compensa nell'intercetta. Con 15 bit o meno il valore massimo è 32767 e ci sta.
        let needsOffset = !d.isSigned && d.bitsStored >= 16
        let offsetValue: Int32 = needsOffset ? 32768 : 0

        var out = [Int16](repeating: 0, count: pixelCount)

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let base = raw.baseAddress!.advanced(by: offset)

            for n in 0..<pixelCount {
                // Lettura byte per byte: `PixelData` non ha garanzia di allineamento a 2 byte
                // dentro il file, quindi un load diretto di UInt16 sarebbe scorretto.
                let b0 = base.load(fromByteOffset: n * 2, as: UInt8.self)
                let b1 = base.load(fromByteOffset: n * 2 + 1, as: UInt8.self)
                let word: UInt16 =
                    bigEndian
                    ? (UInt16(b0) << 8) | UInt16(b1)
                    : (UInt16(b1) << 8) | UInt16(b0)

                let masked = word & storedMask
                var value: Int32

                if d.isSigned {
                    // Estensione del segno dal bit `bitsStored - 1`. Senza questo passaggio
                    // i valori negativi diventano positivi grandi e l'aria risulta più densa
                    // dell'osso.
                    let signBit: UInt16 = 1 << (d.bitsStored - 1)
                    if d.bitsStored < 16, (masked & signBit) != 0 {
                        value = Int32(Int16(bitPattern: masked | ~storedMask))
                    } else {
                        value = Int32(Int16(bitPattern: masked))
                    }
                } else {
                    value = Int32(masked) - offsetValue
                }

                out[n] = Int16(clamping: value)
            }
        }

        return DecodedFrame(
            samples: out,
            // density = v·slope + intercept, con v = s + 32768 ⇒ intercetta += 32768·slope.
            // Lo slope non è noto qui: si restituisce la traslazione grezza e la compensazione
            // avviene in `VolumeBuilder`, che conosce lo slope.
            interceptAdjustment: needsOffset ? 32768 : 0
        )
    }
}
