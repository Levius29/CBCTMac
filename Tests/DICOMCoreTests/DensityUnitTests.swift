import Foundation
import Testing

@testable import DICOMCore

// Scelta fra GV e HU, cioè il Contratto 4.
//
// Questa suite nasce da un difetto trovato su uno studio reale: la barra di stato mostrava «HU»
// accanto a valori che arrivavano a 6000 con intercetta nulla. Il file dichiarava
// `RescaleType = HU`, e l'inferenza restituiva `.declaredHounsfield` alla prima riga, prima di
// guardare il marchio dell'apparecchio e l'intercetta. Molte CBCT scrivono quel tag senza
// produrre unità Hounsfield.
//
// Il danno non è cosmetico. «1200 HU» si confronta con la letteratura sulla densità ossea, «1200
// GV» no, e la differenza è tutta lì.

@Suite("Unità di densità: GV oppure HU")
struct DensityUnitTests {

    private func dataset(
        rescaleType: String? = nil,
        intercept: Double? = nil,
        manufacturer: String? = nil
    ) -> DICOMDataset {
        var elements: [DICOMElement] = []
        if let rescaleType {
            elements.append(
                DICOMElement(
                    tag: DICOMTags.rescaleType, vr: .LO,
                    value: Data(padded(rescaleType).utf8)))
        }
        if let intercept {
            elements.append(
                DICOMElement(
                    tag: DICOMTags.rescaleIntercept, vr: .DS,
                    value: Data(padded("\(intercept)").utf8)))
        }
        if let manufacturer {
            elements.append(
                DICOMElement(
                    tag: DICOMTags.manufacturer, vr: .LO,
                    value: Data(padded(manufacturer).utf8)))
        }
        return DICOMDataset(elements: elements)
    }

    /// I valori DICOM di lunghezza dispari si completano con uno spazio.
    private func padded(_ text: String) -> String {
        text.count % 2 == 0 ? text : text + " "
    }

    private func series(modality: String?) -> ScannedSeries {
        ScannedSeries(
            seriesInstanceUID: "x", seriesNumber: nil, description: nil, modality: modality,
            instances: [], rows: 8, columns: 8,
            pixelSpacingMM: nil, sliceThicknessMM: 1, isImageSeries: true)
    }

    private func unit(
        rescaleType: String? = nil,
        intercept: Double? = nil,
        manufacturer: String? = nil,
        modality: String? = "CT"
    ) -> DensityUnit {
        VolumeBuilder.inferDensityUnit(
            from: dataset(
                rescaleType: rescaleType, intercept: intercept, manufacturer: manufacturer),
            series: series(modality: modality))
    }

    // MARK: Il difetto trovato su uno studio reale

    @Test("RescaleType HU con intercetta nulla resta GV")
    func declaredHUWithoutCalibrationStaysGreyValue() {
        // È il caso esatto dello studio reale: il file dichiara HU, l'intercetta è zero e i valori
        // arrivano a migliaia. Una scala calibrata in Hounsfield ha l'aria a −1000, quindi
        // richiede un'intercetta ampiamente negativa: con intercetta nulla la scala è arbitraria,
        // qualunque cosa dichiari il tag.
        #expect(unit(rescaleType: "HU", intercept: 0) == .greyValue)
        #expect(unit(rescaleType: "HU", intercept: nil) == .greyValue)
        #expect(unit(rescaleType: "HU", intercept: 0).symbol == "GV")
    }

    @Test("RescaleType HU su una scala calibrata è accettato")
    func declaredHUWithCalibrationIsHonoured() {
        // Con l'aria a −1000 la dichiarazione è coerente con i dati, e rifiutarla sarebbe
        // arroganza: il file lo dice e i numeri gli danno ragione.
        #expect(unit(rescaleType: "HU", intercept: -1024) == .declaredHounsfield)
        #expect(unit(rescaleType: "HU", intercept: -1000) == .declaredHounsfield)
    }

    @Test("Un marchio CBCT vince sulla dichiarazione del file")
    func cbctManufacturerOverridesDeclaredHU() {
        // Se l'apparecchio è una CBCT, ciò che dichiara sull'unità non cambia la fisica: la
        // ricostruzione parte da proiezioni incomplete e il valore dipende dall'apparecchio, dal
        // FOV e dalla posizione nell'immagine.
        for maker in ["NewTom VGi", "Planmeca ProMax 3D", "J. MORITA MFG. CORP.", "VATECH", "Prexion"]
        {
            #expect(
                unit(rescaleType: "HU", intercept: -1024, manufacturer: maker) == .greyValue,
                "marchio «\(maker)»")
        }
    }

    // MARK: Casi normali

    @Test("Una TC vera senza RescaleType è riconosciuta dall'intercetta")
    func realCTIsRecognisedByItsIntercept() {
        #expect(unit(intercept: -1024, modality: "CT") == .declaredHounsfield)
    }

    @Test("Senza indizi si sceglie GV")
    func defaultsToGreyValue() {
        #expect(unit() == .greyValue)
        #expect(unit(intercept: 0, modality: nil) == .greyValue)
        #expect(unit(rescaleType: "US", intercept: 0) == .greyValue)
        // Intercetta negativa ma senza dichiarazione né modalità CT: non basta.
        #expect(unit(intercept: -1024, modality: "OT") == .greyValue)
    }

    @Test("Il simbolo dell'unità non è mai ambiguo")
    func symbolsAreDistinct() {
        #expect(DensityUnit.greyValue.symbol == "GV")
        #expect(DensityUnit.declaredHounsfield.symbol != DensityUnit.greyValue.symbol)
    }
}
