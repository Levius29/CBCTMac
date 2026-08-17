import Foundation

/// Instrada i pixel verso il primo decoder compatibile con la sintassi di trasferimento.
public struct CompositePixelDecoder: PixelDecoder {
    private let decoders: [any PixelDecoder]

    public init(
        decoders: [any PixelDecoder] = [
            NativePixelDecoder(), RLEPixelDecoder(), JPEGLosslessDecoder(),
        ]
    ) {
        self.decoders = decoders
    }

    public func canDecode(_ transferSyntax: TransferSyntax) -> Bool {
        for decoder in decoders {
            if decoder.canDecode(transferSyntax) { return true }
        }
        return false
    }

    public func decode(
        _ data: Data,
        frameIndex: Int,
        descriptor: PixelDescriptor,
        transferSyntax: TransferSyntax
    ) throws -> DecodedFrame {
        var selected: (any PixelDecoder)?
        for decoder in decoders {
            if decoder.canDecode(transferSyntax) {
                selected = decoder
                break
            }
        }
        guard let selected else {
            throw PixelDecodingError.unsupportedTransferSyntax(transferSyntax)
        }

        if transferSyntax.isEncapsulated {
            // DICOMParser conserva per contratto l'intervallo fino a subito prima del
            // delimitatore. Il parser degli item, invece, verifica anche il delimitatore:
            // lo si ricostruisce qui senza alterare i byte o gli offset dei frammenti.
            var itemStream = data
            itemStream.append(contentsOf: [0xFE, 0xFF, 0xDD, 0xE0, 0, 0, 0, 0])
            let encapsulated = try EncapsulatedPixelData.parse(
                itemStream, sourceName: "PixelData")
            let frame = try encapsulated.frameData(
                itemStream,
                frameIndex: frameIndex,
                frameCount: max(descriptor.frameCount, 1))
            // Il decoder di codec riceve esattamente un fotogramma. Passare l'indice originale
            // lo farebbe interpretare una seconda volta come offset dentro quel singolo frame.
            return try selected.decode(
                frame,
                frameIndex: 0,
                descriptor: descriptor,
                transferSyntax: transferSyntax)
        }

        return try selected.decode(
            data,
            frameIndex: frameIndex,
            descriptor: descriptor,
            transferSyntax: transferSyntax)
    }
}
