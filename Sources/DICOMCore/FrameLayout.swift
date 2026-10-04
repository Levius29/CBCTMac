import Foundation

// I file multiframe: un esame intero dentro un file solo.
//
// # Il difetto da cui nasce
//
// Il costruttore del volume è nato per la forma classica — un file per fetta — e trattava ogni
// file come una fetta. Su un file multiframe, che è come esportano molti apparecchi recenti, il
// risultato era il rifiuto con «la serie non dichiara la spaziatura dei pixel»: nei file Enhanced
// la spaziatura non sta al primo livello ma nei gruppi funzionali, e il parser le sequenze le
// saltava. Ci fosse stata, il volume sarebbe uscito di una fetta sola.
//
// # Dove sta che cosa
//
// Un file Enhanced divide gli attributi in due gruppi: quelli **condivisi** da tutti i
// fotogrammi (di solito spaziatura, orientamento, rescale) e quelli **per fotogramma** (di
// solito la posizione). Lo standard lascia al produttore la scelta di dove mettere che cosa, e i
// produttori la usano tutta. La regola di lettura è quindi una sola e vale per ogni attributo:
// prima il gruppo del fotogramma, poi quello condiviso, poi il primo livello.
//
// # I multiframe senza gruppi funzionali
//
// Esistono anche file multiframe «vecchio stile»: una sola posizione al primo livello, un
// orientamento, e i fotogrammi in fila. Lì la posizione di ciascun fotogramma **non è scritta**:
// si deduce, prima posizione più k volte la spaziatura lungo la normale. È una deduzione e non
// una lettura, e il volume lo dichiara fra gli avvisi — se l'apparecchio impilasse i fotogrammi
// nel verso opposto il volume uscirebbe capovolto, e solo chi guarda può accorgersene.

/// La geometria di un file DICOM letta dove il file la tiene: al primo livello nella forma
/// classica, nei gruppi funzionali nei file multiframe.
public struct FrameLayout: Sendable {

    /// Quanti fotogrammi contiene il file: 1 nella forma classica.
    public let frameCount: Int
    public let orientation: SliceOrientation?
    public let pixelSpacing: PixelSpacing?
    public let sliceThicknessMM: Double?
    /// La posizione di ciascun fotogramma, nell'ordine in cui stanno nel file.
    ///
    /// Per un file a fotogramma singolo è la sua posizione, se c'è. Per un multiframe è vuoto
    /// quando le posizioni non si possono né leggere né dedurre: meglio nessuna posizione che
    /// una inventata, e il costruttore del volume lo dice con un errore.
    public let framePositionsMM: [Vec3]
    /// Vero se le posizioni sono dedotte da prima posizione, orientamento e spaziatura invece
    /// che lette fotogramma per fotogramma.
    public let positionsAreDeduced: Bool
    public let rescaleSlope: Double?
    public let rescaleIntercept: Double?
    public let rescaleType: String?
    /// Vero se i fotogrammi dichiarano rescale diversi fra loro. Il volume ne usa uno solo, e
    /// va detto.
    public let rescaleVariesAcrossFrames: Bool

    public init(dataset: DICOMDataset) {
        let declaredFrames = dataset.int(DICOMTags.numberOfFrames) ?? 1
        let frameCount = max(declaredFrames, 1)
        self.frameCount = frameCount

        let shared = dataset.items(DICOMTags.sharedFunctionalGroupsSequence)?.first
        let perFrame = dataset.items(DICOMTags.perFrameFunctionalGroupsSequence) ?? []
        // Il gruppo del primo fotogramma vale per gli attributi che il volume prende una volta
        // sola: spaziatura, orientamento, rescale.
        let firstFrame = perFrame.first

        func resolve<Value>(
            _ macro: DICOMTag, _ read: (DICOMDataset) -> Value?, frame: DICOMDataset?
        ) -> Value? {
            if let item = frame?.items(macro)?.first, let value = read(item) { return value }
            if let item = shared?.items(macro)?.first, let value = read(item) { return value }
            return read(dataset)
        }

        let orientation = resolve(
            DICOMTags.planeOrientationSequence,
            {
                $0.doubles(DICOMTags.imageOrientationPatient)
                    .flatMap(SliceOrientation.init(dicomValues:))
            },
            frame: firstFrame)
        self.orientation = orientation
        self.pixelSpacing = resolve(
            DICOMTags.pixelMeasuresSequence, Self.pixelSpacing(in:), frame: firstFrame)
        let thickness = resolve(
            DICOMTags.pixelMeasuresSequence,
            { $0.double(DICOMTags.sliceThickness) },
            frame: firstFrame)
        self.sliceThicknessMM = thickness

        let slope = resolve(
            DICOMTags.pixelValueTransformationSequence,
            { $0.double(DICOMTags.rescaleSlope) },
            frame: firstFrame)
        let intercept = resolve(
            DICOMTags.pixelValueTransformationSequence,
            { $0.double(DICOMTags.rescaleIntercept) },
            frame: firstFrame)
        self.rescaleSlope = slope
        self.rescaleIntercept = intercept
        self.rescaleType = resolve(
            DICOMTags.pixelValueTransformationSequence,
            { $0.string(DICOMTags.rescaleType) },
            frame: firstFrame)

        var varies = false
        if perFrame.count > 1 {
            for item in perFrame.dropFirst() {
                guard let transform = item.items(DICOMTags.pixelValueTransformationSequence)?
                    .first
                else { continue }
                let s = transform.double(DICOMTags.rescaleSlope) ?? slope ?? 1
                let i = transform.double(DICOMTags.rescaleIntercept) ?? intercept ?? 0
                if abs(s - (slope ?? 1)) > 1e-9 || abs(i - (intercept ?? 0)) > 1e-9 {
                    varies = true
                    break
                }
            }
        }
        self.rescaleVariesAcrossFrames = varies

        let firstLevelPosition = dataset.vec3(DICOMTags.imagePositionPatient)
        guard frameCount > 1 else {
            self.framePositionsMM =
                resolve(
                    DICOMTags.planePositionSequence,
                    { $0.vec3(DICOMTags.imagePositionPatient) },
                    frame: firstFrame
                ).map { [$0] } ?? []
            self.positionsAreDeduced = false
            return
        }

        // Le posizioni lette, fotogramma per fotogramma. Ne basta una mancante per non fidarsi
        // delle altre: un fotogramma senza posizione non si colloca, e indovinarlo vorrebbe dire
        // inventare una fetta.
        if perFrame.count == frameCount {
            var positions: [Vec3] = []
            positions.reserveCapacity(frameCount)
            for item in perFrame {
                guard
                    let position = item.items(DICOMTags.planePositionSequence)?.first?
                        .vec3(DICOMTags.imagePositionPatient)
                else { break }
                positions.append(position)
            }
            if positions.count == frameCount {
                self.framePositionsMM = positions
                self.positionsAreDeduced = false
                return
            }
        }

        // Il multiframe vecchio stile: una posizione, e la fila si deduce. La spaziatura fra
        // fotogrammi è `SpacingBetweenSlices`, e solo in sua assenza lo spessore — che su una
        // CBCT coincide quasi sempre con il passo, ma non è detto.
        let step =
            dataset.double(DICOMTags.spacingBetweenSlices)
            ?? shared?.items(DICOMTags.pixelMeasuresSequence)?.first?
            .double(DICOMTags.spacingBetweenSlices)
            ?? thickness
        if let origin = firstLevelPosition, let orientation, let step, step.isFinite, step > 0 {
            let normal = orientation.normal
            self.framePositionsMM = (0..<frameCount).map { origin + normal * (Double($0) * step) }
            self.positionsAreDeduced = true
        } else {
            self.framePositionsMM = []
            self.positionsAreDeduced = false
        }
    }

    private static func pixelSpacing(in dataset: DICOMDataset) -> PixelSpacing? {
        guard let values = dataset.doubles(DICOMTags.pixelSpacing), values.count >= 2 else {
            return nil
        }
        let row = values[0]
        let column = values[1]
        guard row.isFinite, column.isFinite, row > 0, column > 0 else { return nil }
        return PixelSpacing(rowMM: row, columnMM: column)
    }
}
