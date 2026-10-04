import Foundation

// Assemblaggio del volume da una serie scansionata.
//
// È l'anello che collega il parser alla geometria: prende una `ScannedSeries`, ordina le slice
// con `SliceSorter`, decodifica i pixel e produce un `Volume` pronto per il rendering e le
// misure.
//
// Tre trappole vivono qui, e nessuna delle tre si manifesta come un errore visibile:
//
//  1. La compensazione dell'intercetta per i dati senza segno a 16 bit. Se si dimentica, tutte
//     le densità risultano spostate di una costante e l'immagine resta identica.
//  2. Il rescale che varia fra slice. È raro ma capita, e mediare o ignorare produrrebbe un
//     volume con scale diverse cucite insieme.
//  3. L'ordine dei campioni, che deve corrispondere a quello che `Volume` si aspetta.

// MARK: - Avanzamento

/// Stato del caricamento, per la barra di avanzamento.
public struct VolumeLoadProgress: Hashable, Sendable {
    public let completedSlices: Int
    public let totalSlices: Int

    public var fraction: Double {
        guard totalSlices > 0 else { return 0 }
        return Double(completedSlices) / Double(totalSlices)
    }
}

// MARK: - Esito

public struct VolumeLoadResult: Sendable {
    public let volume: Volume
    /// Anomalie geometriche riscontrate: spaziatura non uniforme, duplicati, slice singola.
    public let geometryIssues: [VolumeGeometryIssue]
    /// Avvisi non geometrici, in italiano e pronti per la UI.
    public let warnings: [String]

    public init(volume: Volume, geometryIssues: [VolumeGeometryIssue], warnings: [String]) {
        self.volume = volume
        self.geometryIssues = geometryIssues
        self.warnings = warnings
    }
}

// MARK: - Errori

public enum VolumeBuildError: Error, Hashable, Sendable {
    case noInstances
    case missingGeometry(sopInstanceUID: String)
    case missingImageDimensions
    case missingPixelSpacing
    case missingPixelData(sopInstanceUID: String)
    case unsupportedCompression(TransferSyntax)
    case sliceDecodingFailed(sopInstanceUID: String, reason: String)
    case inconsistentSliceSize(expected: Int, found: Int, sopInstanceUID: String)

    public var localizedDescription: String {
        switch self {
        case .noInstances:
            return "La serie non contiene immagini."
        case .missingGeometry(let uid):
            return "L'immagine \(uid) non ha posizione o orientamento: "
                + "senza, non è collocabile nel volume."
        case .missingImageDimensions:
            return "La serie non dichiara righe e colonne."
        case .missingPixelSpacing:
            return "La serie non dichiara la spaziatura dei pixel: "
                + "le misure sarebbero prive di significato."
        case .missingPixelData(let uid):
            return "L'immagine \(uid) non contiene dati pixel."
        case .unsupportedCompression(let syntax):
            return "Immagini compresse con \(syntax.displayName): nessun decoder disponibile."
        case .sliceDecodingFailed(let uid, let reason):
            return "Decodifica fallita per l'immagine \(uid): \(reason)"
        case .inconsistentSliceSize(let expected, let found, let uid):
            return "L'immagine \(uid) ha \(found) campioni invece dei \(expected) attesi: "
                + "le immagini della serie non hanno tutte le stesse dimensioni."
        }
    }
}

// MARK: - Costruttore

public enum VolumeBuilder {

    /// Costruisce un volume da una serie scansionata.
    ///
    /// - Parameters:
    ///   - series: la serie, con le istanze in ordine qualunque. L'ordinamento avviene qui,
    ///     tramite `SliceSorter`, e mai per `InstanceNumber`.
    ///   - decoder: decodificatore dei pixel. Il predefinito gestisce sintassi native, RLE e
    ///     JPEG Lossless.
    ///   - progress: chiamato dopo ogni slice; utile per una barra di avanzamento.
    public static func build(
        series: ScannedSeries,
        decoder: any PixelDecoder = CompositePixelDecoder(),
        progress: (@Sendable (VolumeLoadProgress) -> Void)? = nil
    ) throws -> VolumeLoadResult {

        guard !series.instances.isEmpty else { throw VolumeBuildError.noInstances }
        guard let columns = series.columns, let rows = series.rows, columns > 0, rows > 0 else {
            throw VolumeBuildError.missingImageDimensions
        }
        guard let spacing = series.pixelSpacingMM else {
            // Senza spaziatura si potrebbe comunque mostrare l'immagine, ma ogni misura
            // sarebbe un numero senza unità. Meglio rifiutare che produrre misure false.
            throw VolumeBuildError.missingPixelSpacing
        }

        var warnings: [String] = []

        // 1. Descrittori per l'ordinamento, uno per fotogramma: nella forma classica uno per
        //    file, in un multiframe tutti quelli del file, ciascuno con la sua posizione.
        //    Un fotogramma senza geometria non è collocabile.
        var slices: [(instance: Int, frame: Int)] = []
        var descriptors: [SliceDescriptor] = []
        descriptors.reserveCapacity(series.instances.count)
        var positionsWereDeduced = false

        for (index, instance) in series.instances.enumerated() {
            guard let orientation = instance.orientation else {
                throw VolumeBuildError.missingGeometry(sopInstanceUID: instance.sopInstanceUID)
            }
            if instance.frameCount > 1 {
                guard instance.framePositionsMM.count == instance.frameCount else {
                    throw VolumeBuildError.missingGeometry(
                        sopInstanceUID: instance.sopInstanceUID)
                }
                positionsWereDeduced = positionsWereDeduced || instance.framePositionsAreDeduced
                for (frame, position) in instance.framePositionsMM.enumerated() {
                    descriptors.append(
                        SliceDescriptor(
                            positionMM: position, orientation: orientation,
                            sourceIndex: slices.count))
                    slices.append((instance: index, frame: frame))
                }
            } else {
                guard let position = instance.positionMM else {
                    throw VolumeBuildError.missingGeometry(
                        sopInstanceUID: instance.sopInstanceUID)
                }
                descriptors.append(
                    SliceDescriptor(
                        positionMM: position, orientation: orientation,
                        sourceIndex: slices.count))
                slices.append((instance: index, frame: 0))
            }
        }

        if positionsWereDeduced {
            warnings.append(
                "Il file non scrive la posizione di ogni fetta: sono dedotte dalla prima "
                    + "posizione e dalla spaziatura. Controllare sulle viste sagittale e "
                    + "coronale che l'esame non sia capovolto.")
        }

        // 2. Ordinamento per proiezione sulla normale, mai per InstanceNumber.
        let sorted = try SliceSorter.sort(
            slices: descriptors,
            columnCount: columns,
            rowCount: rows,
            pixelSpacingMM: (row: spacing.rowMM, column: spacing.columnMM),
            fallbackSliceSpacingMM: series.sliceThicknessMM ?? 1.0)

        let geometry = sorted.geometry
        let pixelsPerSlice = columns * rows
        let totalSlices = sorted.order.count

        // 3. Allocazione. Su una CBCT tipica sono centinaia di megabyte: una sola volta,
        //    riempita per slice.
        var samples = [Int16](repeating: 0, count: pixelsPerSlice * totalSlices)

        var rescaleSlope: Double?
        var rescaleIntercept: Double?
        var interceptAdjustment: Double?
        var densityUnit: DensityUnit = .greyValue
        var reportedRescaleVariation = false

        // 4. Decodifica. Ogni file si legge **una volta sola**, anche quando contiene tutte le
        //    fette: un multiframe da mezzo gigabyte riletto per ciascuno dei suoi cinquecento
        //    fotogrammi non finirebbe più. I file si visitano nell'ordine geometrico della loro
        //    prima fetta, che per la forma classica è esattamente l'ordine di prima.
        var framesByInstance: [Int: [(destination: Int, frame: Int)]] = [:]
        var instanceOrder: [Int] = []
        for (destinationIndex, sourceIndex) in sorted.order.enumerated() {
            let slice = slices[sourceIndex]
            if framesByInstance[slice.instance] == nil { instanceOrder.append(slice.instance) }
            framesByInstance[slice.instance, default: []].append(
                (destination: destinationIndex, frame: slice.frame))
        }

        var completedSlices = 0
        for instanceIndex in instanceOrder {
            let instance = series.instances[instanceIndex]

            let parsed: ParsedFile
            do {
                parsed = try DICOMParser.parse(url: instance.url, depth: .includingPixelData)
            } catch {
                throw VolumeBuildError.sliceDecodingFailed(
                    sopInstanceUID: instance.sopInstanceUID,
                    reason: String(describing: error))
            }

            guard let pixelElement = parsed.dataset[DICOMTags.pixelData],
                !pixelElement.value.isEmpty
            else {
                throw VolumeBuildError.missingPixelData(sopInstanceUID: instance.sopInstanceUID)
            }

            let descriptor = pixelDescriptor(
                from: parsed.dataset, columns: columns, rows: rows)

            // 5. Rescale. Si prende dalla prima fetta; se una successiva dichiara valori
            //    diversi lo si segnala una volta sola. Mediarli produrrebbe un volume con due
            //    scale cucite insieme, e nessun segno visibile del problema. Nei multiframe il
            //    rescale sta nei gruppi funzionali: `FrameLayout` lo cerca anche lì.
            let layout = FrameLayout(dataset: parsed.dataset)
            let slope = layout.rescaleSlope ?? 1.0
            let intercept = layout.rescaleIntercept ?? 0.0
            var differs = layout.rescaleVariesAcrossFrames

            for (destinationIndex, frameIndex) in framesByInstance[instanceIndex] ?? [] {
                let frame: DecodedFrame
                do {
                    frame = try decoder.decode(
                        pixelElement.value,
                        frameIndex: frameIndex,
                        descriptor: descriptor,
                        transferSyntax: parsed.transferSyntax)
                } catch {
                    let reason =
                        (error as? PixelDecodingError)?.localizedDescription
                        ?? String(describing: error)
                    throw VolumeBuildError.sliceDecodingFailed(
                        sopInstanceUID: instance.sopInstanceUID,
                        reason: instance.frameCount > 1
                            ? "fotogramma \(frameIndex + 1) di \(instance.frameCount): \(reason)"
                            : reason)
                }

                guard frame.samples.count == pixelsPerSlice else {
                    throw VolumeBuildError.inconsistentSliceSize(
                        expected: pixelsPerSlice,
                        found: frame.samples.count,
                        sopInstanceUID: instance.sopInstanceUID)
                }

                if let existingSlope = rescaleSlope, let existingIntercept = rescaleIntercept {
                    differs =
                        differs || abs(existingSlope - slope) > 1e-9
                        || abs(existingIntercept - intercept) > 1e-9
                } else {
                    rescaleSlope = slope
                    rescaleIntercept = intercept
                    interceptAdjustment = frame.interceptAdjustment
                    densityUnit = inferDensityUnit(from: parsed.dataset, series: series)
                }
                if differs, !reportedRescaleVariation {
                    warnings.append(
                        "Il rescale varia fra le immagini della serie. Si usa quello della "
                            + "prima slice; i valori di densità delle altre potrebbero essere "
                            + "spostati.")
                    reportedRescaleVariation = true
                }

                let destination = destinationIndex * pixelsPerSlice
                samples.replaceSubrange(
                    destination..<(destination + pixelsPerSlice), with: frame.samples)

                completedSlices += 1
                progress?(
                    VolumeLoadProgress(
                        completedSlices: completedSlices, totalSlices: totalSlices))
            }
        }

        // 6. Compensazione della traslazione applicata ai dati senza segno a 16 bit.
        //
        //    Il decoder ha sottratto 32768 per far entrare i valori in `Int16`, restituendo
        //    l'entità della traslazione ma non potendola compensare: non conosce lo slope.
        //    Qui lo si conosce, e vale `densità = v·slope + intercetta` con `v = s + 32768`,
        //    da cui `intercetta += 32768 · slope`.
        //
        //    Dimenticarlo sposta l'intera scala di densità di una costante lasciando
        //    l'immagine identica: è il tipo di errore che si scopre solo confrontando un
        //    valore con un riferimento noto.
        let finalSlope = rescaleSlope ?? 1.0
        let finalIntercept = (rescaleIntercept ?? 0.0) + (interceptAdjustment ?? 0) * finalSlope

        let volume = try Volume(
            geometry: geometry,
            samples: samples,
            rescaleSlope: finalSlope,
            rescaleIntercept: finalIntercept,
            densityUnit: densityUnit)

        return VolumeLoadResult(
            volume: volume,
            geometryIssues: sorted.issues,
            warnings: warnings)
    }

    // MARK: Descrittore

    static func pixelDescriptor(
        from dataset: DICOMDataset, columns: Int, rows: Int
    ) -> PixelDescriptor {
        let bitsAllocated = dataset.int(DICOMTags.bitsAllocated) ?? 16
        let bitsStored = dataset.int(DICOMTags.bitsStored) ?? bitsAllocated
        return PixelDescriptor(
            columns: dataset.int(DICOMTags.columns) ?? columns,
            rows: dataset.int(DICOMTags.rows) ?? rows,
            bitsAllocated: bitsAllocated,
            bitsStored: bitsStored,
            highBit: dataset.int(DICOMTags.highBit) ?? (bitsStored - 1),
            isSigned: (dataset.int(DICOMTags.pixelRepresentation) ?? 0) == 1,
            samplesPerPixel: dataset.int(DICOMTags.samplesPerPixel) ?? 1,
            frameCount: dataset.int(DICOMTags.numberOfFrames) ?? 1)
    }

    // MARK: Unità di densità

    /// Decide se i valori vanno etichettati come GV o come HU dichiarati.
    ///
    /// Applica il Contratto 4: su CBCT si scrive **GV**. Una CBCT si dichiara quasi sempre con
    /// `Modality = CT`, quindi la modalità da sola non distingue nulla.
    ///
    /// - Important: `RescaleType = HU` **non basta**, e questo era un difetto vero. La versione
    ///   precedente restituiva `.declaredHounsfield` alla prima riga, appena letto quel tag, e
    ///   così ogni altro controllo — marchio dell'apparecchio, intercetta — non veniva mai
    ///   raggiunto. Molte CBCT scrivono `HU` senza produrre unità Hounsfield, e su uno studio
    ///   reale l'applicazione mostrava «HU» accanto a valori che arrivavano a 6000 con intercetta
    ///   nulla. Sono valori grigi, e chiamarli HU offre un numero apparentemente confrontabile con
    ///   la letteratura.
    ///
    /// Il discriminante affidabile è l'**intercetta**: una TC vera memorizza l'aria intorno a
    /// −1000, e questo richiede un'intercetta ampiamente negativa. Con intercetta nulla la scala è
    /// arbitraria, qualunque cosa dichiari `RescaleType`.
    static func inferDensityUnit(from dataset: DICOMDataset, series: ScannedSeries)
        -> DensityUnit
    {
        // Dal primo livello nella forma classica, dai gruppi funzionali nei multiframe.
        let layout = FrameLayout(dataset: dataset)
        let intercept = layout.rescaleIntercept ?? 0
        let rescaleType = (layout.rescaleType ?? "").uppercased()
        let modality = (series.modality ?? "").uppercased()
        let manufacturer = (dataset.string(DICOMTags.manufacturer) ?? "").uppercased()

        // Marchi noti di apparecchi CBCT. Vengono prima di tutto, `RescaleType` compreso: se
        // l'apparecchio è una CBCT, quello che dichiara sull'unità non cambia la fisica.
        let cbctMakers = [
            "NEWTOM", "IMAGING SCIENCES", "I-CAT", "PLANMECA", "MORITA", "VATECH",
            "CARESTREAM", "SIRONA", "DENTSPLY", "ACTEON", "CEFLA", "MYRAY", "OWANDY",
            "GENORAY", "POINTNIX", "AJAT", "VILLA", "PREXION", "ASAHI", "TROPHY", "INSTRUMENTARIUM",
        ]
        if cbctMakers.contains(where: { manufacturer.contains($0) }) {
            return .greyValue
        }

        // Firma di una TC calibrata: aria a −1000, quindi intercetta ampiamente negativa. La
        // soglia è larga perché non tutte le TC usano esattamente −1024, ma nessuna scala
        // calibrata in Hounsfield può avere intercetta prossima a zero.
        let looksCalibrated = intercept <= -500

        if rescaleType == "HU", looksCalibrated {
            return .declaredHounsfield
        }
        if modality == "CT", abs(intercept + 1024) < 1e-6 {
            return .declaredHounsfield
        }

        return .greyValue
    }
}
