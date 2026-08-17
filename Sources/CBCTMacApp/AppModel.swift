import DICOMCore
import DentalKit
import ImplantKit
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
    case implant
    case nerve

    var localizedName: String {
        switch self {
        case .navigate: return "Naviga"
        case .distance: return "Distanza"
        case .angle: return "Angolo"
        case .ellipseROI: return "ROI ellittica"
        case .sphereROI: return "ROI sferica"
        case .text: return "Testo"
        case .implant: return "Impianto"
        case .nerve: return "Traccia nervo"
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
        case .implant: return "screwdriver"
        case .nerve: return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }
}

// MARK: - Layout

enum ViewportLayout: String, CaseIterable, Hashable, Sendable {
    case single
    case grid2x2
    case onePlusThree
    /// Panorex in alto e griglia di sezioni trasversali sotto. È la disposizione con cui si
    /// valuta la cresta e si pianifica un impianto.
    case panoramic

    var localizedName: String {
        switch self {
        case .single: return "Singolo"
        case .grid2x2: return "Griglia 2×2"
        case .onePlusThree: return "Uno grande e tre"
        case .panoramic: return "Panorex e sezioni"
        }
    }

    var systemImageName: String {
        switch self {
        case .single: return "square"
        case .grid2x2: return "square.grid.2x2"
        case .onePlusThree: return "rectangle.split.2x2"
        case .panoramic: return "rectangle.grid.1x2"
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

    var windowLevel: DensityWindow = .bone
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

    // MARK: Arcata, panorex e sezioni

    /// Curva dell'arcata. Da qui derivano sia il panorex sia le sezioni trasversali.
    var archCurve = ArchCurve(controlPointsMM: [])

    /// Vero mentre l'utente sta correggendo la curva sull'assiale.
    var isEditingArch = false

    var panoramicHeightMM: Double = 70
    var panoramicSlabThicknessMM: Double = 20
    var panoramicProjection: SlabProjection = .maximum

    var crossSectionIntervalMM: Double = 1.0
    var crossSectionWidthMM: Double = 30
    var crossSectionHeightMM: Double = 45
    var crossSectionThicknessMM: Double = 0

    /// Prima sezione mostrata nella griglia. La griglia ne mostra poche per volta e si scorre.
    var crossSectionPageStart: Int = 0

    /// Quota verticale su cui si centrano panorex e sezioni.
    /// Segue il mirino, così spostandosi sull'assiale le sezioni restano centrate sulla cresta.
    var archVerticalCentreMM: Double = 0

    var panoramicLayout: PanoramicLayout {
        PanoramicLayout(
            curve: archCurve,
            heightMM: panoramicHeightMM,
            verticalCentreMM: archVerticalCentreMM,
            slabThicknessMM: panoramicSlabThicknessMM,
            projection: panoramicProjection)
    }

    var crossSectionLayout: CrossSectionLayout {
        CrossSectionLayout(
            curve: archCurve,
            intervalMM: crossSectionIntervalMM,
            widthMM: crossSectionWidthMM,
            heightMM: crossSectionHeightMM,
            verticalCentreMM: archVerticalCentreMM,
            thicknessMM: crossSectionThicknessMM)
    }

    /// Sezioni calcolate, ricostruite quando la curva o i parametri cambiano.
    ///
    /// Non è una proprietà calcolata: generarle richiede di ricampionare la spline, e farlo a
    /// ogni ridisegno di ogni riquadro renderebbe il trascinamento della curva una melassa.
    private(set) var crossSections: [CrossSection] = []

    func rebuildCrossSections() {
        guard archCurve.isUsable else {
            crossSections = []
            return
        }
        crossSections = crossSectionLayout.sections()
        crossSectionPageStart = min(crossSectionPageStart, max(0, crossSections.count - 1))
    }

    /// Reimposta la curva sull'arcata predefinita ricavata dal volume.
    func resetArchCurve() {
        guard let geometry = volume?.geometry else { return }
        archCurve = ArchCurve.defaultArch(for: geometry)
        archVerticalCentreMM = crosshairMM.z
        rebuildCrossSections()
    }

    // MARK: Nervo e impianti

    var nerveCanals: [NerveCanal] = []
    var implants: [ImplantPlacement] = []
    var selectedImplantID: UUID?
    /// Canale in corso di tracciamento; `nil` quando non si sta tracciando.
    var tracingNerveID: UUID?

    var implantCatalog: [ImplantModel] = ImplantModel.genericCatalog()
    /// Modello scelto per il prossimo impianto inserito.
    var pendingImplantModel: ImplantModel = .default

    /// Rapporti di sicurezza, uno per impianto.
    ///
    /// Ricalcolati quando qualcosa cambia, non a ogni ridisegno: l'analisi campiona centinaia
    /// di punti sulla superficie implantare contro ogni canale, ed è lavoro da CPU.
    private(set) var safetyReports: [UUID: SafetyReport] = [:]

    var safetyThresholds: SafetyThresholds = .nerve

    var selectedImplant: ImplantPlacement? {
        guard let id = selectedImplantID else { return nil }
        return implants.first { $0.id == id }
    }

    func recomputeSafety() {
        var reports: [UUID: SafetyReport] = [:]
        for implant in implants {
            reports[implant.id] = SafetyAnalyzer.analyze(
                implant: implant,
                nerves: nerveCanals,
                otherImplants: implants,
                volume: volume,
                thresholds: safetyThresholds)
        }
        safetyReports = reports
    }

    func addImplant(at pointMM: Vec3, axis: Vec3 = Vec3(0, 0, -1)) {
        // La piattaforma va dove l'utente ha cliccato e l'impianto scende da lì: è il gesto
        // atteso, perché si sceglie il punto di emergenza guardando la cresta.
        let placement = ImplantPlacement(
            model: pendingImplantModel,
            platformMM: pointMM,
            axis: axis,
            label: "Impianto \(implants.count + 1)")
        implants.append(placement)
        selectedImplantID = placement.id
        recomputeSafety()
    }

    func updateSelectedImplant(_ transform: (inout ImplantPlacement) -> Void) {
        guard let id = selectedImplantID,
            let index = implants.firstIndex(where: { $0.id == id })
        else { return }
        transform(&implants[index])
        recomputeSafety()
    }

    func removeSelectedImplant() {
        guard let id = selectedImplantID else { return }
        implants.removeAll { $0.id == id }
        safetyReports.removeValue(forKey: id)
        selectedImplantID = nil
        recomputeSafety()
    }

    func beginTracingNerve(side: MandibularSide) {
        let canal = NerveCanal(side: side)
        nerveCanals.append(canal)
        tracingNerveID = canal.id
    }

    func addNerveNode(at pointMM: Vec3) {
        guard let id = tracingNerveID,
            let index = nerveCanals.firstIndex(where: { $0.id == id })
        else { return }
        nerveCanals[index].addNode(NerveNode(positionMM: pointMM))
        recomputeSafety()
    }

    func finishTracingNerve() {
        tracingNerveID = nil
        recomputeSafety()
    }

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
    private(set) var panoramicRenderer: PanoramicRenderer?
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
                self.panoramicRenderer = try PanoramicRenderer(device: device)
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

    /// Apre una cartella di file DICOM.
    ///
    /// La scansione legge i soli metadati, quindi l'albero delle serie compare subito anche su
    /// cartelle da migliaia di file; i pixel si leggono solo per la serie scelta.
    func loadStudy(from directory: URL) async {
        loadingMessage = "Scansione della cartella…"
        loadIssues = []

        let outcome = await Task.detached(priority: .userInitiated) { () -> StudyOutcome in
            do {
                let scan = try DICOMScanner.scan(directory: directory, progress: nil)

                // Si sceglie la serie di immagini con più slice: su un export CBCT è
                // praticamente sempre il volume, mentre le altre sono scout e localizzatori.
                let candidates = scan.patients
                    .flatMap(\.studies)
                    .flatMap(\.series)
                    .filter { $0.isImageSeries && $0.instances.count > 1 }

                guard let series = candidates.max(by: { $0.instances.count < $1.instances.count })
                else {
                    return .failed("Nessuna serie di immagini trovata nella cartella.")
                }

                let result = try VolumeBuilder.build(series: series)
                var messages = result.warnings
                messages.append(contentsOf: result.geometryIssues.map(\.localizedDescription))
                messages.append(contentsOf: scan.failures.map { "\($0.url.lastPathComponent): \($0.reason)" })

                return .loaded(result.volume, messages, series.description ?? "Serie CBCT")
            } catch let error as VolumeBuildError {
                return .failed(error.localizedDescription)
            } catch let error as DICOMParsingError {
                return .failed(error.localizedDescription)
            } catch {
                return .failed(String(describing: error))
            }
        }.value

        switch outcome {
        case .failed(let message):
            loadingMessage = nil
            loadIssues = [message]
        case .loaded(let volume, let messages, let name):
            adopt(volume: volume)
            // Gli avvisi si impostano **dopo** `adopt`, che azzera lo stato: altrimenti
            // sparirebbero proprio quando servono.
            loadIssues = messages
            studyName = name
            loadingMessage = nil
        }
    }

    private enum StudyOutcome: Sendable {
        case loaded(Volume, [String], String)
        case failed(String)
    }

    /// Nome della serie aperta, per il titolo della finestra e la barra laterale.
    private(set) var studyName: String = "Fantoccio sintetico"

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
        windowLevel = DensityWindow.automatic(from: volume)
        camera = VolumeCamera.fitted(to: volume.geometry)
        histogram = volume.rawHistogram(binCount: 256)

        resetPlanes()
        resetArchCurve()
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
