import Foundation

// Un codificatore PNG in Swift puro.
//
// # Perché non si usa quello del sistema
//
// Perché `NSBitmapImageRep` vive in AppKit, e AppKit esiste solo sul Mac. Tutto ciò che passa da
// lì smette di essere verificabile con `swift test` in questo ambiente, e un'anteprima che
// nessuno può provare finché non la guarda a occhio è un'anteprima che sbaglia in silenzio.
// Centoventi righe di PNG comprano la possibilità di provarlo.
//
// # Che PNG scrive
//
// Scala di grigi a 8 bit, senza filtri e con la compressione «stored» del deflate — cioè nessuna
// compressione. Un PNG non compresso è grande quanto i suoi pixel: per un'anteprima ridotta va
// bene, per un volume intero no, ed è la ragione per cui l'anteprima è ridotta.
//
// Non è un formato inventato: chiunque lo apre. Lo scrivere senza comprimere è previsto dallo
// standard, non una scorciatoia che qualche lettore potrebbe rifiutare.

public enum PNGEncoder: Sendable {

    /// Codifica un'immagine in scala di grigi a 8 bit.
    ///
    /// - Parameters:
    ///   - pixels: `width * height` byte, per righe, dall'alto in basso.
    ///   - width: larghezza in pixel.
    ///   - height: altezza in pixel.
    /// - Returns: i byte del file PNG, o `nil` se le dimensioni non tornano coi pixel.
    public static func grayscale(pixels: [UInt8], width: Int, height: Int) -> Data? {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }

        var data = Data([137, 80, 78, 71, 13, 10, 26, 10])

        var header = Data()
        header.append(bigEndian: UInt32(width))
        header.append(bigEndian: UInt32(height))
        header.append(8)  // profondità di bit
        header.append(0)  // scala di grigi
        header.append(0)  // compressione deflate, l'unica prevista
        header.append(0)  // filtro adattativo, l'unico previsto
        header.append(0)  // non interlacciato
        data.append(chunk(type: "IHDR", payload: header))

        // Ogni riga porta davanti il byte del filtro. Zero significa «nessun filtro»: i filtri
        // servono a far comprimere meglio, e qui non si comprime.
        var raw = Data()
        raw.reserveCapacity((width + 1) * height)
        for row in 0..<height {
            raw.append(0)
            raw.append(contentsOf: pixels[(row * width)..<((row + 1) * width)])
        }

        data.append(chunk(type: "IDAT", payload: zlibStored(raw)))
        data.append(chunk(type: "IEND", payload: Data()))
        return data
    }

    /// Un blocco PNG: lunghezza, tipo, dati, CRC di tipo e dati.
    static func chunk(type: String, payload: Data) -> Data {
        var data = Data()
        data.append(bigEndian: UInt32(payload.count))
        let typeBytes = Data(type.utf8)
        data.append(typeBytes)
        data.append(payload)
        data.append(bigEndian: crc32(typeBytes + payload))
        return data
    }

    /// Un flusso zlib fatto di soli blocchi «stored».
    ///
    /// L'intestazione è `78 01`: metodo deflate, finestra da 32 KiB, livello «più veloce». I due
    /// byte devono formare un numero divisibile per 31 — è il controllo che lo standard prevede
    /// per accorgersi di un flusso che non è zlib affatto.
    static func zlibStored(_ payload: Data) -> Data {
        var data = Data([0x78, 0x01])

        // Un blocco «stored» dichiara la propria lunghezza in due byte, quindi al più 65535 byte
        // per volta.
        let maximum = 65535
        var offset = 0
        repeat {
            let length = Swift.min(maximum, payload.count - offset)
            let isLast = offset + length >= payload.count
            data.append(isLast ? 1 : 0)
            data.append(UInt8(length & 0xFF))
            data.append(UInt8((length >> 8) & 0xFF))
            let complement = ~UInt16(length)
            data.append(UInt8(complement & 0xFF))
            data.append(UInt8((complement >> 8) & 0xFF))
            if length > 0 {
                data.append(payload[payload.startIndex + offset..<payload.startIndex + offset + length])
            }
            offset += length
        } while offset < payload.count

        data.append(bigEndian: adler32(payload))
        return data
    }

    // MARK: Somme di controllo

    private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in data {
            value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
        }
        return value ^ 0xFFFF_FFFF
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        // 5552 è il numero massimo di byte che si possono sommare prima che `b` possa
        // traboccare da 32 bit. Il modulo fuori dal ciclo interno costa molto meno di uno a
        // ogni byte.
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: Swift.min(5552, data.endIndex - index))
            for byte in data[index..<end] {
                a += UInt32(byte)
                b += a
            }
            a %= 65521
            b %= 65521
            index = end
        }
        return (b << 16) | a
    }
}

extension Data {
    fileprivate mutating func append(bigEndian value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
