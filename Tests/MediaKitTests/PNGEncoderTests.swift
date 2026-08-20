import Foundation
import Testing

@testable import MediaKit

// Il codificatore PNG.
//
// # Come si prova un formato binario senza aprirlo a occhio
//
// Con un lettore scritto apposta, dentro il test, che rifà il percorso all'indietro: legge i
// blocchi, ne verifica i CRC, srotola il flusso zlib e ricostruisce i pixel. Se i pixel che
// tornano sono quelli di partenza, il file è giusto — e il lettore non condivide codice con lo
// scrittore, quindi non può sbagliare insieme a lui.
//
// Le somme di controllo si verificano invece contro i valori noti pubblicati: `crc32` di
// «123456789» e `adler32` di «Wikipedia» sono numeri che chiunque può ritrovare.

@Suite("PNG in scala di grigi")
struct PNGEncoderTests {

    // MARK: Somme di controllo, contro valori pubblicati

    @Test("Il CRC32 dà il valore noto")
    func crc32MatchesTheKnownVector() {
        #expect(PNGEncoder.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
        #expect(PNGEncoder.crc32(Data()) == 0)
    }

    @Test("L'Adler32 dà il valore noto")
    func adler32MatchesTheKnownVector() {
        #expect(PNGEncoder.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
        #expect(PNGEncoder.adler32(Data()) == 1)
    }

    @Test("L'Adler32 regge oltre il blocco da 5552 byte")
    func adler32SurvivesPastOneBlock() {
        // Il modulo si applica fuori dal ciclo interno, ogni 5552 byte: un'immagine vera ne ha
        // molti di più, e un errore lì si vedrebbe solo su file grandi.
        let long = Data(repeating: 0xFF, count: 20_000)
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in long {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        #expect(PNGEncoder.adler32(long) == (b << 16) | a)
    }

    // MARK: Andata e ritorno

    /// Un lettore PNG minimo: solo ciò che il nostro scrittore produce.
    struct MinimalPNGReader {
        var width = 0
        var height = 0
        var bitDepth: UInt8 = 0
        var colorType: UInt8 = 0
        var pixels: [UInt8] = []

        init?(_ data: Data) {
            let bytes = [UInt8](data)
            guard bytes.count > 8,
                Array(bytes[0..<8]) == [137, 80, 78, 71, 13, 10, 26, 10]
            else { return nil }

            func be32(_ offset: Int) -> Int {
                Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16
                    | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            }

            var offset = 8
            var compressed = Data()
            var sawEnd = false

            while offset + 8 <= bytes.count {
                let length = be32(offset)
                let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
                let payloadStart = offset + 8
                guard payloadStart + length + 4 <= bytes.count else { return nil }
                let payload = Data(bytes[payloadStart..<(payloadStart + length)])

                // Il CRC copre tipo e dati, e si verifica su ogni blocco.
                let declared = UInt32(be32(payloadStart + length))
                let computed = PNGEncoder.crc32(
                    Data(bytes[(offset + 4)..<(offset + 8)]) + payload)
                guard declared == computed else { return nil }

                switch type {
                case "IHDR":
                    guard length == 13 else { return nil }
                    width = be32(payloadStart)
                    height = be32(payloadStart + 4)
                    bitDepth = bytes[payloadStart + 8]
                    colorType = bytes[payloadStart + 9]
                case "IDAT":
                    compressed.append(payload)
                case "IEND":
                    sawEnd = true
                default:
                    break
                }
                offset = payloadStart + length + 4
            }

            guard sawEnd, width > 0, height > 0 else { return nil }
            guard let raw = Self.inflateStored(compressed) else { return nil }

            // Ogni riga comincia col byte del filtro, che deve essere zero.
            var output: [UInt8] = []
            output.reserveCapacity(width * height)
            var cursor = 0
            for _ in 0..<height {
                guard cursor < raw.count, raw[cursor] == 0 else { return nil }
                cursor += 1
                guard cursor + width <= raw.count else { return nil }
                output.append(contentsOf: raw[cursor..<(cursor + width)])
                cursor += width
            }
            guard cursor == raw.count else { return nil }
            pixels = output
        }

        /// Srotola un flusso zlib fatto di soli blocchi «stored», verificando l'Adler32.
        static func inflateStored(_ data: Data) -> [UInt8]? {
            let bytes = [UInt8](data)
            guard bytes.count > 6 else { return nil }
            // L'intestazione zlib deve essere divisibile per 31.
            let check = Int(bytes[0]) << 8 | Int(bytes[1])
            guard check % 31 == 0, bytes[0] & 0x0F == 8 else { return nil }

            var offset = 2
            var output: [UInt8] = []
            var final = false
            while !final {
                guard offset + 5 <= bytes.count else { return nil }
                let header = bytes[offset]
                final = header & 1 == 1
                guard (header >> 1) & 3 == 0 else { return nil }  // solo blocchi «stored»
                let length = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
                let complement = Int(bytes[offset + 3]) | Int(bytes[offset + 4]) << 8
                guard length ^ 0xFFFF == complement else { return nil }
                offset += 5
                guard offset + length <= bytes.count else { return nil }
                output.append(contentsOf: bytes[offset..<(offset + length)])
                offset += length
            }
            guard offset + 4 <= bytes.count else { return nil }
            let declared = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16
                | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            guard declared == PNGEncoder.adler32(Data(output)) else { return nil }
            return output
        }
    }

    @Test("Un'immagine scritta e riletta è la stessa immagine")
    func anImageSurvivesTheRoundTrip() throws {
        let width = 37
        let height = 23
        // Un motivo che cambia su tutte e due le direzioni: uno scambio fra righe e colonne su
        // un'immagine quadrata a strisce non darebbe alcun sintomo.
        var pixels: [UInt8] = []
        for row in 0..<height {
            for column in 0..<width {
                pixels.append(UInt8((row * 7 + column * 3) % 256))
            }
        }

        let data = try #require(PNGEncoder.grayscale(pixels: pixels, width: width, height: height))
        let read = try #require(MinimalPNGReader(data))

        #expect(read.width == width)
        #expect(read.height == height)
        #expect(read.bitDepth == 8)
        #expect(read.colorType == 0)
        #expect(read.pixels == pixels)
    }

    @Test("Un'immagine più grande di un blocco «stored» si scrive lo stesso")
    func anImageLargerThanOneStoredBlockStillWorks() throws {
        // Un blocco «stored» arriva a 65535 byte: un'immagine di 300 × 300 ne richiede cinque, e
        // lo scrittore deve spezzarli e marcare come finale solo l'ultimo.
        let side = 300
        var pixels: [UInt8] = []
        pixels.reserveCapacity(side * side)
        for index in 0..<(side * side) { pixels.append(UInt8(index % 251)) }

        let data = try #require(PNGEncoder.grayscale(pixels: pixels, width: side, height: side))
        #expect(data.count > 65535)

        let read = try #require(MinimalPNGReader(data))
        #expect(read.pixels == pixels)
    }

    @Test("Dimensioni che non tornano coi pixel non producono un file")
    func mismatchedDimensionsProduceNothing() {
        // Meglio niente che un PNG con l'intestazione giusta e i pixel di un'altra immagine:
        // quello si apre, e sembra soltanto strano.
        #expect(PNGEncoder.grayscale(pixels: [1, 2, 3], width: 2, height: 2) == nil)
        #expect(PNGEncoder.grayscale(pixels: [], width: 0, height: 0) == nil)
        #expect(PNGEncoder.grayscale(pixels: [1], width: -1, height: 1) == nil)
    }

    @Test("Un'immagine di un pixel resta un'immagine valida")
    func aSinglePixelIsStillValid() throws {
        let data = try #require(PNGEncoder.grayscale(pixels: [128], width: 1, height: 1))
        let read = try #require(MinimalPNGReader(data))
        #expect(read.pixels == [128])
    }
}
