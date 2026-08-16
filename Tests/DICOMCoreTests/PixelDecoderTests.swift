import Foundation
import Testing

@testable import DICOMCore

// Test del decoder dei pixel.
//
// Coprono i due casi che corrompono i valori senza dare alcun segno: l'estensione del segno
// quando `BitsStored` è minore di `BitsAllocated`, e i dati senza segno a 16 bit, che non
// entrano in `Int16` e vanno traslati. Un errore qui non fa sbagliare l'immagine — la fa
// sbagliare *plausibilmente*, con l'aria più densa dell'osso o tutta la scala spostata di una
// costante.

@Suite("NativePixelDecoder")
struct PixelDecoderTests {

    private let decoder = NativePixelDecoder()

    private func descriptor(
        bitsAllocated: Int, bitsStored: Int, isSigned: Bool, pixels: Int = 4
    ) -> PixelDescriptor {
        PixelDescriptor(
            columns: pixels,
            rows: 1,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: bitsStored - 1,
            isSigned: isSigned)
    }

    private func littleEndian(_ values: [UInt16]) -> Data {
        var data = Data()
        for value in values {
            data.append(UInt8(value & 0xFF))
            data.append(UInt8((value >> 8) & 0xFF))
        }
        return data
    }

    @Test("Dati senza segno a 12 bit passano invariati")
    func unsigned12Bit() throws {
        let raw: [UInt16] = [0, 1000, 2048, 4095]
        let frame = try decoder.decode(
            littleEndian(raw), frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 16, bitsStored: 12, isSigned: false),
            transferSyntax: .explicitVRLittleEndian)

        #expect(frame.samples == [0, 1000, 2048, 4095])
        // Con dodici bit il massimo è 4095: entra in Int16, nessuna traslazione necessaria.
        #expect(frame.interceptAdjustment == 0)
    }

    @Test("I bit oltre BitsStored vengono azzerati")
    func masksHighBits() throws {
        // Lo standard non definisce i bit sopra BitsStored: alcuni apparecchi ci lasciano
        // spazzatura. Interpretarli produce valori enormi in mezzo a un'immagine normale.
        let raw: [UInt16] = [0xF000 | 100, 0xA000 | 2000, 100, 2000]
        let frame = try decoder.decode(
            littleEndian(raw), frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 16, bitsStored: 12, isSigned: false),
            transferSyntax: .explicitVRLittleEndian)

        #expect(frame.samples[0] == 100)
        #expect(frame.samples[1] == 2000)
        #expect(frame.samples[0] == frame.samples[2])
        #expect(frame.samples[1] == frame.samples[3])
    }

    @Test("Il segno viene esteso dal bit BitsStored − 1")
    func signExtension() throws {
        // A 12 bit con segno l'intervallo è [−2048, 2047]. Il valore 0xFFF è −1: senza
        // estensione del segno diventerebbe 4095, e l'aria risulterebbe più densa dell'osso.
        let raw: [UInt16] = [0x000, 0x001, 0xFFF, 0x800]
        let frame = try decoder.decode(
            littleEndian(raw), frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 16, bitsStored: 12, isSigned: true),
            transferSyntax: .explicitVRLittleEndian)

        #expect(frame.samples[0] == 0)
        #expect(frame.samples[1] == 1)
        #expect(frame.samples[2] == -1)
        #expect(frame.samples[3] == -2048)
    }

    @Test("Dati senza segno a 16 bit vengono traslati e la traslazione è dichiarata")
    func unsigned16BitOffset() throws {
        // 0…65535 non entra in Int16. La traslazione di −32768 è esatta e reversibile, ma va
        // compensata nell'intercetta: `interceptAdjustment` è ciò che lo comunica a monte.
        let raw: [UInt16] = [0, 32768, 65535, 1000]
        let frame = try decoder.decode(
            littleEndian(raw), frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 16, bitsStored: 16, isSigned: false),
            transferSyntax: .explicitVRLittleEndian)

        #expect(frame.samples[0] == -32768)
        #expect(frame.samples[1] == 0)
        #expect(frame.samples[2] == 32767)
        #expect(frame.samples[3] == 1000 - 32768)
        #expect(frame.interceptAdjustment == 32768)
    }

    @Test("L'ordine dei byte big endian viene rispettato")
    func bigEndian() throws {
        // Stessi byte, sintassi diversa: il risultato deve differire, altrimenti l'endianness
        // viene ignorata e gli archivi datati si leggono come rumore.
        var data = Data()
        for value in [UInt16(0x0102), UInt16(0x0304)] {
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        let frame = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 16, bitsStored: 16, isSigned: false, pixels: 2),
            transferSyntax: .explicitVRBigEndian)

        #expect(frame.samples[0] == Int16(clamping: 0x0102 - 32768))
        #expect(frame.samples[1] == Int16(clamping: 0x0304 - 32768))
    }

    @Test("Dati a 8 bit, con e senza segno")
    func eightBit() throws {
        let data = Data([0, 127, 128, 255])

        let unsigned = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 8, bitsStored: 8, isSigned: false),
            transferSyntax: .explicitVRLittleEndian)
        #expect(unsigned.samples == [0, 127, 128, 255])

        let signed = try decoder.decode(
            data, frameIndex: 0,
            descriptor: descriptor(bitsAllocated: 8, bitsStored: 8, isSigned: true),
            transferSyntax: .explicitVRLittleEndian)
        #expect(signed.samples == [0, 127, -128, -1])
    }

    @Test("Dati troncati producono un errore, non una lettura fuori limite")
    func truncatedThrows() {
        let data = Data([0, 0])  // due byte per quattro pixel richiesti
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                data, frameIndex: 0,
                descriptor: descriptor(bitsAllocated: 16, bitsStored: 16, isSigned: false),
                transferSyntax: .explicitVRLittleEndian)
        }
    }

    @Test("Le sintassi compresse vengono rifiutate con chiarezza")
    func rejectsCompressed() {
        #expect(!decoder.canDecode(.jpeg2000Lossless))
        #expect(throws: PixelDecodingError.self) {
            _ = try decoder.decode(
                Data(count: 16), frameIndex: 0,
                descriptor: descriptor(bitsAllocated: 16, bitsStored: 16, isSigned: false),
                transferSyntax: .jpeg2000Lossless)
        }
    }

    @Test("Una sintassi sconosciuta è trattata come compressa, non come dati in chiaro")
    func unknownSyntaxIsEncapsulated() {
        // Prudenza deliberata: interpretare byte compressi come campioni produrrebbe
        // un'immagine di rumore invece di un errore leggibile.
        let unknown = TransferSyntax(uid: "1.2.840.10008.1.2.4.999")
        #expect(unknown.isEncapsulated)
        #expect(!unknown.isNativelySupported)
    }
}
