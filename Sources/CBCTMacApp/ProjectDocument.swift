import DICOMCore
import DentalKit
import Foundation
import ImplantKit
import MeasureKit
import VolumeKit

// Il documento di progetto `.cbctplan`.
//
// Compone quello che i moduli non possono comporre da soli: `MeasureKit` non conosce
// `ImplantKit`, e non deve — un modulo di misure che dipendesse dalla pianificazione
// implantare sarebbe una dipendenza nella direzione sbagliata. L'applicazione è l'unico
// livello che conosce tutti i moduli, quindi il documento completo appartiene a lei.
//
// Come `PlanDocument`, **non contiene immagini**: rimanda allo studio tramite UID. Un piano
// pesa così qualche decina di kilobyte invece di mezzo gigabyte, e soprattutto non trasporta
// dati clinici del paziente in giro per errore.

struct ProjectDocument: Codable, Sendable {

    /// Versione del formato. Si incrementa a ogni cambiamento incompatibile, così una versione
    /// futura può rifiutare esplicitamente un file che non sa leggere invece di interpretarlo
    /// male in silenzio.
    static let currentFormatVersion = 1

    var formatVersion: Int
    /// Misure, annotazioni, stato di vista e registro: tutto quanto già gestito da MeasureKit.
    var plan: PlanDocument

    // Pianificazione implantare.
    var implants: [ImplantPlacement]
    var nerveCanals: [NerveCanal]

    /// Denti protesici, la sagoma che dice dove la protesi vuole l'impianto.
    ///
    /// Opzionale, e non un array vuoto: i piani salvati prima che i denti esistessero non hanno
    /// la chiave, e un formato che li rifiutasse per una funzione aggiunta dopo perderebbe il
    /// lavoro di chi lo usava già. Con un opzionale la chiave assente decodifica a `nil` senza
    /// che serva alzare `formatVersion`, che resta riservato ai cambiamenti *incompatibili*.
    var teeth: [ProstheticTooth]?

    /// Dove sta la scansione intraorale rispetto al volume, dopo la registrazione.
    ///
    /// Qui la **posizione**, nell'archivio i triangoli. È la stessa divisione del resto del
    /// formato: il piano è leggero e non contiene immagini, quindi non può contenere nemmeno
    /// una superficie da qualche megabyte. Riaprendo un caso dall'archivio le due parti si
    /// ritrovano; aprendo un `.cbctplan` da solo si ritrova il piano senza la scansione, che è
    /// esattamente ciò che quel formato promette.
    var scanTransform: Transform3D?
    /// Scarto quadratico medio della registrazione, per non doverla rifare solo per sapere
    /// quanto valeva.
    var scanRegistrationRMSMM: Double?

    // Curva dell'arcata e parametri delle viste derivate.
    var archControlPointsMM: [[Double]]
    var archUpAxis: [Double]
    var panoramicHeightMM: Double
    var panoramicSlabThicknessMM: Double
    var crossSectionIntervalMM: Double
    var crossSectionWidthMM: Double
    var crossSectionHeightMM: Double
    var archVerticalCentreMM: Double

    /// I parametri della segmentazione, non la maschera.
    ///
    /// La maschera è grande quanto il volume e si ricalcola in pochi secondi; i quattro numeri
    /// che la producono stanno in una riga. Conservare quelli significa riaprire il caso e
    /// ritrovare la soglia su cui si era lavorato, invece di doverla ricercare
    /// sull'istogramma — che è la parte lenta, perché è quella che richiede di guardare.
    var segmentationLowerGV: Double?
    var segmentationUpperGV: Double?
    var segmentationKeepsLargest: Bool?
    var segmentationSpacingMM: Double?

    /// Transfer function corrente, così riaprendo il caso il 3D è com'era.
    var transferFunction: TransferFunction

    /// `@MainActor` perché legge lo stato del modello, che è isolato al main actor.
    @MainActor
    init(from model: AppModel) {
        self.formatVersion = Self.currentFormatVersion
        self.plan = model.makePlanDocument()
        self.implants = model.implants
        self.nerveCanals = model.nerveCanals
        self.teeth = model.teeth
        self.scanTransform = model.scan == nil ? nil : model.scanTransform
        self.scanRegistrationRMSMM = model.scanRegistration?.surfaceRMSMM
        self.archControlPointsMM = model.archCurve.controlPointsMM.map { [$0.x, $0.y, $0.z] }
        self.archUpAxis = [
            model.archCurve.upAxis.x, model.archCurve.upAxis.y, model.archCurve.upAxis.z,
        ]
        self.panoramicHeightMM = model.panoramicHeightMM
        self.panoramicSlabThicknessMM = model.panoramicSlabThicknessMM
        self.crossSectionIntervalMM = model.crossSectionIntervalMM
        self.crossSectionWidthMM = model.crossSectionWidthMM
        self.crossSectionHeightMM = model.crossSectionHeightMM
        self.archVerticalCentreMM = model.archVerticalCentreMM
        self.transferFunction = model.transferFunction
        self.segmentationLowerGV = model.segmentationLowerGV
        self.segmentationUpperGV = model.segmentationUpperGV
        self.segmentationKeepsLargest = model.segmentationKeepsLargest
        self.segmentationSpacingMM = model.segmentationSpacingMM
    }

    // MARK: Serializzazione

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        // Ordinate e indentate: un piano deve restare leggibile a occhio fra dieci anni anche
        // senza questo software, e produrre diff sensati sotto controllo di versione.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    static func decoded(from data: Data) throws -> ProjectDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(ProjectDocument.self, from: data)
        guard document.formatVersion <= currentFormatVersion else {
            throw ProjectDocumentError.unsupportedFormatVersion(
                found: document.formatVersion, supported: currentFormatVersion)
        }
        return document
    }

    func write(to url: URL) throws {
        try encoded().write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> ProjectDocument {
        try decoded(from: Data(contentsOf: url))
    }

    // MARK: Applicazione

    /// Riversa il documento nel modello.
    ///
    /// Restituisce gli avvisi da mostrare: il più importante è il disallineamento della
    /// geometria, che non impedisce di aprire il piano ma segnala che le coordinate potrebbero
    /// non indicare più la stessa anatomia. Lasciar credere che tutto combaci sarebbe peggio
    /// che rifiutare l'apertura.
    @MainActor
    func apply(to model: AppModel) -> [String] {
        var warnings: [String] = []

        if let fingerprint = plan.study.geometryFingerprint,
            let geometry = model.volume?.geometry,
            !fingerprint.matches(geometry)
        {
            warnings.append(
                "Il piano è stato creato su una geometria diversa da quella aperta. "
                    + "Le annotazioni potrebbero non trovarsi sull'anatomia attesa.")
        }

        model.annotations = plan.annotations
        model.implants = implants
        model.nerveCanals = nerveCanals
        model.teeth = teeth ?? []
        if let scanTransform { model.adoptScanTransform(scanTransform) }

        let points = archControlPointsMM.compactMap { values -> Vec3? in
            guard values.count >= 3 else { return nil }
            return Vec3(values[0], values[1], values[2])
        }
        if points.count >= 2 {
            let up = archUpAxis.count >= 3
                ? Vec3(archUpAxis[0], archUpAxis[1], archUpAxis[2])
                : Vec3(0, 0, 1)
            model.archCurve = ArchCurve(controlPointsMM: points, upAxis: up)
        }

        model.panoramicHeightMM = panoramicHeightMM
        model.panoramicSlabThicknessMM = panoramicSlabThicknessMM
        model.crossSectionIntervalMM = crossSectionIntervalMM
        model.crossSectionWidthMM = crossSectionWidthMM
        model.crossSectionHeightMM = crossSectionHeightMM
        model.archVerticalCentreMM = archVerticalCentreMM
        model.transferFunction = transferFunction
        if let segmentationLowerGV { model.segmentationLowerGV = segmentationLowerGV }
        if let segmentationUpperGV { model.segmentationUpperGV = segmentationUpperGV }
        if let segmentationKeepsLargest { model.segmentationKeepsLargest = segmentationKeepsLargest }
        if let segmentationSpacingMM { model.segmentationSpacingMM = segmentationSpacingMM }
        model.transferPresetName = "Personalizzato"

        if let state = plan.viewState {
            model.windowLevel = DensityWindow(width: state.windowWidth, level: state.windowLevel)
            model.slabThicknessMM = state.slabThicknessMM
            model.moveCrosshair(to: state.crosshairVec3)
        }

        model.rebuildCrossSections()
        model.recomputeSafety()

        for annotation in model.annotations {
            model.recomputeStatistics(for: annotation)
        }

        return warnings
    }
}

enum ProjectDocumentError: Error, LocalizedError {
    case unsupportedFormatVersion(found: Int, supported: Int)
    case noVolumeOpen

    var errorDescription: String? {
        switch self {
        case .unsupportedFormatVersion(let found, let supported):
            return "Il piano è in formato versione \(found), questa versione di CBCTMac ne "
                + "legge fino alla \(supported). Aggiorna l'applicazione."
        case .noVolumeOpen:
            return "Apri prima uno studio: un piano si riferisce a un volume."
        }
    }
}
