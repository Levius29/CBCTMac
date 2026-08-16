import DICOMCore
import MeasureKit
import Metal
import Observation
import SwiftUI
import VolumeKit

// Stato dell'applicazione.
//
// Un solo proprietario dello stato condiviso, sul main actor. Le viste leggono e scrivono qui;
// nessuna vista tiene una copia propria della posizione del mirino o della finestra/livello,
// altrimenti le quattro viste si disallineano appena una cambia.
//
// Regola che discende dal Contratto 1: **il mirino è in millimetri Patient**, non in indici di
// slice. I contatori di slice mostrati nei riquadri sono una derivazione per la UI, non lo
// stato: derivarli dal mirino e non viceversa è ciò che tiene coerenti viste con orientamenti
// e spaziature diverse.

// MARK: - Strumenti

enum Tool: String, CaseIterable, Hashable, Sendable {
    case navigate
    case distance
    case angle
    case ellipseROI
    case sphereROI
    case text

    var localizedName: String {
        switch self {
        case .navigate: return "Naviga"
        case .distance: return "Distanza"
        case .angle: return "Angolo"
        case .ellipseROI: return "ROI ellittica"
        case .sphereROI: return "ROI sferica"
        case .text: return "Testo"
        }
    }

    var systemImageName: String {
        switch self {
        case .navigate: return "cursorarrow"
        case .distance: return "ruler"
        case .angle: return "angle"
        case .ellipseROI: return "oval"
        case .sphereROI: return "circle.circle"
        case .text: return "textformat"
        }
    }
}

// MARK: - Layout

enum ViewportLayout: String, CaseIterable, Hashable, Sendable {
    case single
    case grid2x2
    case onePlusThree

    var localizedName: String {
        switch self {
        case .single: return "Singolo"
        case .grid2x2: return "Griglia 2×2"
        case .onePlusThree: return "Uno grande e tre"
        }
    }

    var systemImageName: String {
        switch self {
        case .single: return "square"
        case .grid2x2: return "square.grid.2x2"
        case .onePlusThree: return "rectangle.split.2x2"
        }
    }
}

/// I quattro riquadri possibili.
enum ViewportSlot: String, CaseIterable, Hashable, Sendable, Identifiable {
    case axial
    case coronal
    case sagittal
    case volume3D

    var id: String { rawValue }

    /// Piano anatomico corrispondente, `nil` per il riquadro 3D.
    var anatomicalPlane: AnatomicalPlane? {
        switch self {
        case .axial: return .axial
        case .coronal: return .coronal
        case .sagittal: return .sagittal
        case .volume3D: return nil
        }
    }

    var localizedName: String {
        switch self {
        case .axial: return "Assiale"
        case .coronal: return "Coronale"
        case .sagittal: return "Sagittale"
        case .volume3D: return "3D"
        }
    }

    var accentColor: Color {
        switch self {
        case .axial: return Palette.axial
        case .coronal: return Palette.coronal
        case .sagittal: return Palette.sagittal
        case .volume3D: return Palette.volume3D
        }
    }
}

// MARK: - Modello

@MainActor
@Observable
final class AppModel {

    // MARK: Dati

    private(set) var volume: Volume?
    private(set) var volumeTexture: VolumeTexture?
    private(set) var loadingMessage: String?
    private(set) var loadIssues: [String] = []

    // MARK: Vista

    /// Posizione del mirino, in millimetri Patient. È lo stato condiviso da cui ogni riquadro
    /// deriva la propria slice.
    var crosshairMM: Vec3 = .zero {
        didSet { syncPlanesToCrosshair() }
    }

    var windowLevel: WindowLevel = .bone
    var slabThicknessMM: Double = 0
    var projection: SlabProjection = .average
    var layout: ViewportLayout = .grid2x2
    var focusedSlot: ViewportSlot = .axial
    var activeTool: Tool = .navigate

    /// Piano di taglio per ciascun riquadro 2D. Il centro fuori piano segue il mirino; la
    /// posizione nel piano e l'estensione sono indipendenti, così zoom e pan di una vista non
    /// si propagano alle altre.
    var planes: [ViewportSlot: MPRPlane] = [:]

    // MARK: Annotazioni

    var annotations: [Annotation] = []
    var selectedAnnotationID: UUID?
    /// Statistiche calcolate, indicizzate per annotazione. Ricalcolate a richiesta, non a ogni
    /// ridisegno: scorrere i voxel di una ROI è un'operazione da CPU, non da frame.
    var roiStatistics: [UUID: ROIStatistics] = [:]

    // MARK: Lettura sotto il cursore

    var hoverPositionMM: Vec3?
    var hoverDensity: Double?

    // MARK: Rendering 3D

    var camera = VolumeCamera()
    var transferFunction: TransferFunction = .bone
    var transferPresetName: String = "Osso"
    var renderQuality: RenderQuality = .standard
    var lighting: LightingParameters = .standard

    /// Istogramma dei valori grezzi, per lo sfondo dell'editor di transfer function.
    ///
    /// Calcolato una volta all'apertura del volume e conservato: scorrere quattordici milioni
    /// di voxel a ogni ridisegno dell'editor renderebbe intrattabile il trascinamento di un
    /// punto di controllo.
    private(set) var histogram: [Int] = []

    /// Vero mentre l'utente sta ruotando il volume.
    ///
    /// Durante la rotazione si scende a qualità ridotta: un volume da quattordici milioni di
    /// voxel non si attraversa a piena risoluzione restando fluidi, e su un'immagine in
    /// movimento il dettaglio non si coglie mentre uno scatto sì.
    var isInteractingWith3D = false

    /// Qualità effettiva, che tiene conto dell'interazione in corso.
    var effectiveQuality: RenderQuality {
        isInteractingWith3D ? .interactive : renderQuality
    }

    // MARK: Metal

    let device: MTLDevice?
    private(set) var mprRenderer: MPRRenderer?
    private(set) var raycaster: VolumeRaycaster?
    private(set) var metalError: String?

    // MARK: Versione

    static let appVersion = "0.1.0-dev"

    // MARK: Inizializzazione

    init() {
        self.device = MTLCreateSystemDefaultDevice()
        if let device {
            do {
                self.mprRenderer = try MPRRenderer(device: device)
                self.raycaster = try VolumeRaycaster(device: device)
            } catch {
                self.metalError = String(describing: error)
            }
        } else {
            self.metalError = "Nessun dispositivo Metal disponibile su questo Mac."
        }
    }

    // MARK: Caricamento

    /// Carica il fantoccio sintetico.
    ///
    /// All'avvio l'applicazione non ha ancora un parser DICOM, ma avere qualcosa di reale da
    /// disegnare cambia tutto: le misure si possono provare subito contro valori noti, e senza
    /// toccare dati di pazienti. Vedi `SyntheticVolume`.
    func loadSyntheticPhantom() async {
        loadingMessage = "Generazione del fantoccio sintetico…"
        loadIssues = []

        // Fuori dal main actor: sono quattordici milioni di voxel, e bloccare la UI mentre si
        // generano si vedrebbe.
        //
        // L'esito passa da un enum `Sendable` invece che da `Result<Volume, Error>`: `any Error`
        // non è `Sendable`, quindi in modalità Swift 6 non attraversa il confine dell'attore.
        // Il messaggio si estrae subito, dove l'errore è ancora a portata di mano.
        let outcome = await Task.detached(priority: .userInitiated) { () -> PhantomOutcome in
            do {
                return .loaded(try SyntheticVolume.makePhantom())
            } catch {
                return .failed(String(describing: error))
            }
        }.value

        switch outcome {
        case .failed(let message):
            loadingMessage = nil
            loadIssues = ["Generazione del fantoccio fallita: \(message)"]
        case .loaded(let volume):
            adopt(volume: volume)
            loadingMessage = nil
        }
    }

    private enum PhantomOutcome: Sendable {
        case loaded(Volume)
        case failed(String)
    }

    /// Adotta un volume: costruisce la texture, imposta mirino, finestra e inquadrature.
    func adopt(volume: Volume) {
        self.volume = volume

        if let device {
            do {
                self.volumeTexture = try VolumeTexture(volume: volume, device: device)
            } catch {
                self.loadIssues.append("Texture non creata: \(error)")
                self.volumeTexture = nil
            }
        }

        // Il mirino parte dal centro del volume, che è l'inquadratura naturale all'apertura.
        crosshairMM = volume.geometry.centerMM
        windowLevel = WindowLevel.automatic(from: volume)
        camera = VolumeCamera.fitted(to: volume.geometry)
        histogram = volume.rawHistogram(binCount: 256)

        resetPlanes()
        annotations = []
        roiStatistics = [:]
        selectedAnnotationID = nil
    }

    // MARK: Piani

    /// Riporta i tre piani all'inquadratura completa, centrata sul volume.
    func resetPlanes() {
        guard let geometry = volume?.geometry else { return }
        for slot in ViewportSlot.allCases {
            guard let plane = slot.anatomicalPlane else { continue }
            planes[slot] = MPRPlane.fitted(plane: plane, geometry: geometry)
        }
        syncPlanesToCrosshair()
    }

    /// Sposta ogni piano perché passi per il mirino, conservando pan e zoom nel piano.
    ///
    /// Si corregge solo la componente lungo la normale. Assegnare `centerMM = crosshairMM`
    /// sarebbe più semplice e sbagliato: annullerebbe la panoramica dell'utente ogni volta che
    /// sposta il mirino in un'altra vista, e l'immagine salterebbe.
    private func syncPlanesToCrosshair() {
        for (slot, plane) in planes {
            let n = plane.normalMM
            let delta = (crosshairMM - plane.centerMM).dot(n)
            guard abs(delta) > 1e-9 else { continue }
            var updated = plane
            updated.centerMM = plane.centerMM + n * delta
            planes[slot] = updated
        }
    }

    /// Piano corrente di un riquadro, con slab e proiezione applicati e proporzioni adattate.
    func plane(for slot: ViewportSlot, pixelWidth: Int, pixelHeight: Int) -> MPRPlane? {
        guard var plane = planes[slot] else { return nil }
        plane.slabThicknessMM = slabThicknessMM
        plane.projection = projection
        return plane.matchingAspect(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    // MARK: Navigazione

    /// Scorre le slice del riquadro indicato, in numero di passi di voxel.
    func scroll(slot: ViewportSlot, steps: Double) {
        guard let plane = planes[slot], let geometry = volume?.geometry else { return }
        let spacing = geometry.spacingMM
        let step = min(spacing.x, min(spacing.y, spacing.z))
        // Spostare il mirino, non il piano: così le altre viste seguono e le linee del mirino
        // restano coerenti fra i riquadri.
        crosshairMM = crosshairMM + plane.normalMM * (steps * step)
        clampCrosshairToVolume()
    }

    func zoom(slot: ViewportSlot, factor: Double) {
        guard let plane = planes[slot] else { return }
        planes[slot] = plane.zoomed(by: factor)
    }

    func pan(slot: ViewportSlot, byMM offset: Vec3) {
        guard var plane = planes[slot] else { return }
        plane.centerMM = plane.centerMM + offset
        planes[slot] = plane
    }

    // MARK: Navigazione 3D

    /// Ruota la camera. Lo spostamento arriva in pixel e si converte in radianti.
    func orbit(byPixels delta: CGSize) {
        // Circa mezzo giro per 400 pixel di trascinamento: abbastanza reattivo da girare il
        // cranio con un gesto, abbastanza lento da fermarsi dove si vuole.
        let scale = Double.pi / 400.0
        camera = camera.orbited(
            deltaAzimuth: Double(delta.width) * scale,
            deltaElevation: Double(-delta.height) * scale)
    }

    func zoom3D(by factor: Double) {
        camera = camera.zoomed(by: factor)
    }

    func applyTransferPreset(named name: String) {
        guard let preset = TransferFunction.presets.first(where: { $0.name == name }) else {
            return
        }
        // L'opacità globale impostata dall'utente sopravvive al cambio di preset: è una
        // regolazione di gusto sulla resa, non parte della scelta del tessuto.
        var function = preset.value
        function.opacityScale = transferFunction.opacityScale
        transferFunction = function
        transferPresetName = name
    }

    /// Sposta il mirino su un punto, mantenendolo dentro il volume.
    func moveCrosshair(to pointMM: Vec3) {
        crosshairMM = pointMM
        clampCrosshairToVolume()
    }

    private func clampCrosshairToVolume() {
        guard let geometry = volume?.geometry else { return }
        let v = geometry.voxelPoint(fromPatient: crosshairMM)
        let clamped = Vec3(
            min(max(v.x, 0), Double(geometry.columnCount - 1)),
            min(max(v.y, 0), Double(geometry.rowCount - 1)),
            min(max(v.z, 0), Double(geometry.sliceCount - 1))
        )
        if !clamped.isApproximatelyEqual(to: v, tolerance: 1e-9) {
            // Assegnazione diretta: passare da `crosshairMM` rientrerebbe in `didSet` e
            // rifarebbe la sincronizzazione dei piani senza necessità.
            crosshairMM = geometry.patientPoint(fromVoxel: clamped)
        }
    }

    // MARK: Indicatori per la UI

    /// Indice di slice e conteggio per il riquadro, derivati dal mirino.
    func sliceIndicator(for slot: ViewportSlot) -> (index: Int, count: Int)? {
        guard let geometry = volume?.geometry, let anatomical = slot.anatomicalPlane else {
            return nil
        }
        let v = geometry.voxelPoint(fromPatient: crosshairMM)
        switch anatomical {
        case .axial: return (Int(v.z.rounded()) + 1, geometry.sliceCount)
        case .coronal: return (Int(v.y.rounded()) + 1, geometry.rowCount)
        case .sagittal: return (Int(v.x.rounded()) + 1, geometry.columnCount)
        }
    }

    /// Etichetta della posizione fuori piano, per esempio `Z −38,1 mm`.
    func positionLabel(for slot: ViewportSlot) -> String? {
        guard let anatomical = slot.anatomicalPlane else { return nil }
        let value: Double
        let axis: String
        switch anatomical {
        case .axial:
            value = crosshairMM.z
            axis = "Z"
        case .coronal:
            value = crosshairMM.y
            axis = "Y"
        case .sagittal:
            value = crosshairMM.x
            axis = "X"
        }
        return String(format: "%@ %.1f mm", axis, value).replacingOccurrences(of: ".", with: ",")
    }

    /// Unità di densità del volume corrente. Su CBCT è GV, mai HU: vedi il Contratto 4.
    var densityUnit: DensityUnit {
        volume?.densityUnit ?? .greyValue
    }

    // MARK: Annotazioni

    func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
        recomputeStatistics(for: annotation)
    }

    func removeSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        roiStatistics.removeValue(forKey: id)
        selectedAnnotationID = nil
    }

    /// Ricalcola le statistiche di una ROI.
    ///
    /// Il campionamento avviene sugli `Int16` di CPU, come prescrive il Contratto 3: leggere la
    /// texture restituirebbe valori interpolati, con minimi e massimi che nel dato reale non
    /// esistono.
    func recomputeStatistics(for annotation: Annotation) {
        guard let volume else { return }
        do {
            let stats: ROIStatistics?
            switch annotation {
            case .ellipseROI(let roi):
                stats = try ROISampler.statistics(for: roi, in: volume)
            case .polygonROI(let roi):
                stats = try ROISampler.statistics(for: roi, in: volume)
            case .sphereROI(let roi):
                stats = try ROISampler.statistics(for: roi, in: volume)
            default:
                stats = nil
            }
            if let stats {
                roiStatistics[annotation.id] = stats
            }
        } catch {
            roiStatistics.removeValue(forKey: annotation.id)
        }
    }

    // MARK: Esportazione

    func makePlanDocument() -> PlanDocument {
        var document = PlanDocument(
            study: StudyReference(
                studyInstanceUID: "sintetico",
                seriesInstanceUID: "fantoccio",
                seriesDescription: "Fantoccio sintetico",
                geometryFingerprint: volume.map { GeometryFingerprint($0.geometry) }
            ),
            annotations: annotations,
            viewState: ViewState(
                crosshairMM: crosshairMM,
                windowWidth: windowLevel.width,
                windowLevel: windowLevel.level,
                slabThicknessMM: slabThicknessMM,
                projectionMode: projection.rawValue,
                layout: layout.rawValue
            ),
            appVersion: Self.appVersion
        )
        document.annotations = annotations
        return document
    }
}
