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
    /// Disegno della curva d'arcata, punto per punto, sulla vista assiale.
    case archCurve

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
        case .archCurve: return "Disegna arcata"
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
        case .archCurve: return "scribble.variable"
        }
    }

    /// Suggerimento mostrato quando lo strumento è attivo.
    var hint: String? {
        switch self {
        case .archCurve:
            return "Clicca sull'assiale per posare i punti dell'arcata · trascina per spostarli"
                + " · ⌥ clic per cancellarne uno"
        case .nerve:
            return "Clicca lungo il canale mandibolare per tracciarlo"
        default:
            return nil
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

/// Risoluzione di rendering dei riquadri 2D, in frazione di quella nativa.
///
/// Su un volume grande, e a piena risoluzione Retina, un riquadro può non stare nel budget di un
/// fotogramma: lo scorrimento delle fette diventa a scatti. Ridurre la risoluzione restituisce
/// fluidità e costa nitidezza, ed è un compromesso che ha senso lasciare scegliere invece di
/// imporre.
///
/// La riduzione **non** altera le misure: il fattore fra punti della vista e pixel della texture
/// viene misurato su `drawableSize`, non assunto. Vedi `InteractiveMetalView.pixelsPerPoint`.
enum MPRResolution: String, CaseIterable, Hashable, Sendable, Identifiable {
    case full
    case threeQuarters
    case half

    var id: String { rawValue }

    var scale: Double {
        switch self {
        case .full: return 1
        case .threeQuarters: return 0.75
        case .half: return 0.5
        }
    }

    var localizedName: String {
        switch self {
        case .full: return "Piena"
        case .threeQuarters: return "¾"
        case .half: return "Metà"
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
    /// Risoluzione di rendering dei riquadri 2D. Vedi `MPRResolution`.
    var mprResolution: MPRResolution = .full
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

    /// Curve d'arcata, una per arcata, indipendenti fra loro.
    ///
    /// Due e non una perché l'arcata superiore non ha la forma dell'inferiore e non sta alla
    /// stessa quota: con una curva sola la panoramica riesce su un'arcata e sull'altra i denti
    /// finiscono fuori dallo spessore campionato, cioè non compaiono affatto.
    ///
    /// Entrambe nascono **vuote**. Prima ne veniva imposta una all'apertura, una parabola al
    /// centro del volume, cioè a metà fra le due arcate dove non c'è nessuna delle due: da lì
    /// l'impressione, corretta, che il programma facesse di testa propria. Ora la curva la
    /// disegna chi guarda l'anatomia, e la parabola resta disponibile come suggerimento su
    /// richiesta — alla quota che si sta guardando, non al centro del volume.
    var archCurves: [DentalArch: ArchCurve] = [
        .maxillary: ArchCurve(controlPointsMM: []),
        .mandibular: ArchCurve(controlPointsMM: []),
    ]

    /// Arcata su cui si sta lavorando. Panorex e sezioni seguono questa.
    var activeArch: DentalArch = .mandibular {
        didSet {
            guard activeArch != oldValue else { return }
            selectedArchPointIndex = nil
            // Passando da un'arcata all'altra si va a guardare dove sta la sua curva: è la curva
            // a dire la quota, non l'utente a doverla ricordare e reimpostare a mano.
            if let vertical = archCurve.averageVerticalMM {
                archVerticalCentreMM = vertical
            }
            rebuildCrossSections()
        }
    }

    /// Curva dell'arcata attiva. Da qui derivano sia il panorex sia le sezioni trasversali.
    var archCurve: ArchCurve {
        get { archCurves[activeArch] ?? ArchCurve(controlPointsMM: []) }
        set { archCurves[activeArch] = newValue }
    }

    /// Vero mentre l'utente sta disegnando o correggendo la curva sull'assiale.
    var isEditingArch = false

    /// Punto di controllo selezionato, quello che il tasto Backspace cancella.
    var selectedArchPointIndex: Int?

    /// Raggio di presa di un punto di controllo, in **pixel** dello schermo.
    ///
    /// In pixel e non in millimetri, perché la presa deve stare dov'è il dito: un bersaglio di
    /// dimensione costante a schermo si afferra con la stessa facilità a ogni ingrandimento.
    /// Espresso in millimetri, a zoom ridotto valdrebbe pochi pixel e i punti diventerebbero
    /// impossibili da prendere.
    static let archPointGrabRadiusPixels: Double = 14

    var panoramicHeightMM: Double = 70
    var panoramicSlabThicknessMM: Double = 20
    var panoramicProjection: SlabProjection = .maximum

    /// Ingrandimento del panorex. A 1 l'arcata intera riempie il riquadro.
    ///
    /// È il presupposto dello scorrimento: a piena arcata non c'è niente in cui scorrere.
    var panoramicZoom: Double = 1
    /// Lunghezza d'arco al centro del panorex. `nil` significa il centro della curva.
    var panoramicArcCentreMM: Double?

    /// Scostamento vestibolo-linguale del panorex rispetto alla curva, in millimetri.
    ///
    /// È l'asse su cui si "sfoglia" l'arcata in profondità, e sta sulla rotella. Una curva
    /// d'arcata è un'approssimazione: i denti stanno un po' più fuori o un po' più dentro, e per
    /// trovare l'apice di una radice con uno slab sottile bisogna poterla attraversare.
    var panoramicNormalOffsetMM: Double = 0

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
            projection: panoramicProjection,
            zoom: panoramicZoom,
            arcCentreMM: panoramicArcCentreMM,
            normalOffsetMM: panoramicNormalOffsetMM)
    }

    // MARK: Navigazione del panorex

    /// Scorre il panorex lungo l'arcata, in millimetri di lunghezza d'arco.
    ///
    /// Lo stato che si aggiorna è il centro **limitato**, non quello richiesto: leggendo il valore
    /// grezzo, trascinare a lungo oltre un capo accumulerebbe un debito invisibile e poi
    /// servirebbe altrettanto trascinamento per far ripartire l'immagine nell'altro verso. Con il
    /// valore limitato l'arresto contro il capo è immediato in entrambi i sensi.
    func scrollPanoramic(byArcMM delta: Double) {
        guard delta.isFinite, archCurve.isUsable else { return }
        panoramicArcCentreMM = panoramicLayout.scrolled(byArcMM: delta).clampedArcCentreMM
    }

    /// Sposta la quota verticale del panorex e delle sezioni.
    func movePanoramicVertical(byMM delta: Double) {
        guard delta.isFinite else { return }
        archVerticalCentreMM += delta
    }

    /// Ingrandisce il panorex tenendo fermo il punto dell'arcata sotto il pixel indicato.
    func zoomPanoramic(by factor: Double, atPixelX x: Double, pixelWidth: Int) {
        guard archCurve.isUsable else { return }
        let zoomed = panoramicLayout.zoomed(
            by: factor, aboutPixelX: x, pixelWidth: pixelWidth)
        panoramicZoom = zoomed.effectiveZoom
        panoramicArcCentreMM = zoomed.clampedArcCentreMM
    }

    /// Sfoglia l'arcata in profondità, in millimetri vestibolo-linguali.
    ///
    /// Il limite è la metà dello spessore di slab più un margine: oltre, si esce dai dati che lo
    /// slab già somma, e l'immagine si svuota senza che sia chiaro perché. Meglio arrestarsi.
    func movePanoramicDepth(byMM delta: Double) {
        guard delta.isFinite else { return }
        let limit = max(panoramicSlabThicknessMM, 4) * 1.5
        panoramicNormalOffsetMM = min(max(panoramicNormalOffsetMM + delta, -limit), limit)
    }

    /// Riporta il panorex a inquadrare l'arcata intera, in profondità e in posizione.
    func resetPanoramicView() {
        panoramicZoom = 1
        panoramicArcCentreMM = nil
        panoramicNormalOffsetMM = 0
        if let vertical = archCurve.averageVerticalMM {
            archVerticalCentreMM = vertical
        }
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

    // MARK: Disegno della curva d'arcata

    /// Svuota entrambe le curve all'apertura di uno studio.
    ///
    /// Non impone più una parabola. Vedi il commento su `archCurves`: una curva imposta al centro
    /// del volume cade fra le due arcate, e produce un panorex che non somiglia a niente.
    func resetArchCurves() {
        for arch in DentalArch.allCases {
            archCurves[arch] = ArchCurve(controlPointsMM: [])
        }
        selectedArchPointIndex = nil
        archVerticalCentreMM = crosshairMM.z
        rebuildCrossSections()
    }

    /// Aggiunge un punto alla curva attiva, nella posizione giusta dell'ordine di percorrenza.
    ///
    /// L'ordinamento lo decide `ArchCurve.addControlPoint`, che inserisce fra due punti quando il
    /// clic cade lungo la curva e prolunga quando cade oltre un capo. Accodare sempre produrrebbe
    /// un cappio, ed è il difetto che faceva sembrare la curva incontrollabile.
    func addArchPoint(at pointMM: Vec3) {
        var curve = archCurve
        let outcome = curve.addControlPoint(pointMM)
        archCurve = curve

        switch outcome {
        case .inserted(let index), .appended(let index):
            selectedArchPointIndex = index
        }

        // La quota di lavoro segue la curva che si sta disegnando: i punti si posano sull'assiale,
        // quindi nascono alla quota della fetta che si guarda, e panorex e sezioni devono
        // centrarsi lì senza che l'utente lo chieda.
        if let vertical = curve.averageVerticalMM {
            archVerticalCentreMM = vertical
        }
        rebuildCrossSections()
    }

    func moveArchPoint(at index: Int, to pointMM: Vec3) {
        var curve = archCurve
        curve.moveControlPoint(at: index, to: pointMM)
        archCurve = curve
    }

    func removeArchPoint(at index: Int) {
        var curve = archCurve
        guard curve.removeControlPoint(at: index) else { return }
        archCurve = curve
        selectedArchPointIndex = nil
        rebuildCrossSections()
    }

    func removeSelectedArchPoint() {
        guard let index = selectedArchPointIndex else { return }
        removeArchPoint(at: index)
    }

    /// Svuota la curva dell'arcata attiva, lasciando intatta l'altra.
    func clearActiveArchCurve() {
        var curve = archCurve
        curve.removeAllControlPoints()
        archCurve = curve
        selectedArchPointIndex = nil
        rebuildCrossSections()
    }

    /// Propone una parabola d'arcata **alla quota che si sta guardando**.
    ///
    /// È un comando, non un comportamento automatico: la curva la decide chi guarda l'anatomia, e
    /// questo serve solo a non dover posare sette punti da zero quando la forma è quella tipica.
    func suggestArchCurve() {
        guard let geometry = volume?.geometry else { return }
        archCurve = ArchCurve.suggested(
            for: geometry,
            atVerticalMM: crosshairMM.z,
            arch: activeArch)
        archVerticalCentreMM = crosshairMM.z
        selectedArchPointIndex = nil
        isEditingArch = true
        rebuildCrossSections()
    }

    /// Porta tutti i punti della curva attiva alla loro quota media.
    ///
    /// Posando i punti mentre si scorre di qualche fetta la curva viene leggermente elicoidale, e
    /// su un panorex quella pendenza si legge come un'immagine che scivola in alto da un lato.
    func flattenActiveArchCurve() {
        var curve = archCurve
        guard let vertical = curve.averageVerticalMM else { return }
        curve.flatten(toVerticalMM: vertical)
        archCurve = curve
        archVerticalCentreMM = vertical
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

    /// Etichetta in basso a sinistra nei riquadri: da dove vengono i numeri che si stanno leggendo.
    ///
    /// I visori commerciali scrivono lì l'algoritmo di ricostruzione — «FDK» sulle CBCT — e la
    /// pratica è buona: dichiarare la provenienza dei valori. Noi non leggiamo quel tag, e
    /// inventarlo sarebbe peggio che tacere; scriviamo invece l'**unità**, che è l'informazione
    /// che serve davvero per sapere se un numero è confrontabile con la letteratura.
    ///
    /// Sul fantoccio lo dice apertamente, perché lì i numeri sono esatti per costruzione e
    /// scambiarlo per uno studio vero sarebbe il malinteso peggiore possibile.
    var reconstructionLabel: String {
        guard let volume else { return "—" }
        if volume.geometry.voxelCount > 0, studyName == "Fantoccio sintetico" {
            return "FANTOCCIO · \(volume.densityUnit.symbol)"
        }
        return volume.densityUnit.symbol
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
        windowLevel = DensityWindow.automatic(from: volume)
        camera = VolumeCamera.fitted(to: volume.geometry)
        histogram = volume.rawHistogram(binCount: 256)

        resetPlanes()
        resetArchCurves()
        annotations = []
        roiStatistics = [:]
        selectedAnnotationID = nil
    }

    // MARK: Piani

    /// Riporta i tre piani all'inquadratura completa, centrata sul volume.
    func resetPlanes() {
        guard let geometry = volume?.geometry else { return }
        for slot in ViewportSlot.allCases {
            guard let anatomical = slot.anatomicalPlane else { continue }
            // Spessore e proiezione sopravvivono al reimpostare l'inquadratura: sono una scelta di
            // lettura, non una posizione. Azzerarli qui costringerebbe a rifarli dopo ogni «adatta
            // alla finestra», che è il gesto più frequente di tutti.
            var plane = MPRPlane.fitted(plane: anatomical, geometry: geometry)
            plane.slabThicknessMM = planes[slot]?.slabThicknessMM ?? slabThicknessMM
            plane.projection = planes[slot]?.projection ?? projection
            planes[slot] = plane
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

    /// Piano corrente di un riquadro, con le proporzioni adattate al riquadro.
    ///
    /// Spessore e proiezione **non** vengono più sovrascritti da valori globali: vivono nel piano,
    /// uno per riquadro. Vedi `setSlabThickness(_:for:)`.
    func plane(for slot: ViewportSlot, pixelWidth: Int, pixelHeight: Int) -> MPRPlane? {
        guard let plane = planes[slot] else { return nil }
        return plane.matchingAspect(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
    }

    // MARK: Spessore e proiezione, per riquadro

    /// Spessore dello slab di un riquadro.
    ///
    /// Prima era un valore solo, condiviso da tutte le viste, e lo si passava la giornata a
    /// cambiare avanti e indietro: l'assiale lo si vuole sottile per leggere la corticale, il
    /// panorex spesso per l'immagine d'insieme, la sezione a un millimetro per misurare. Sono tre
    /// compiti diversi che convivono sullo schermo, quindi tre valori.
    func slabThickness(for slot: ViewportSlot) -> Double {
        planes[slot]?.slabThicknessMM ?? slabThicknessMM
    }

    func setSlabThickness(_ value: Double, for slot: ViewportSlot) {
        guard var plane = planes[slot], value.isFinite, value >= 0 else { return }
        plane.slabThicknessMM = value
        planes[slot] = plane
    }

    func projection(for slot: ViewportSlot) -> SlabProjection {
        planes[slot]?.projection ?? projection
    }

    func setProjection(_ value: SlabProjection, for slot: ViewportSlot) {
        guard var plane = planes[slot] else { return }
        plane.projection = value
        planes[slot] = plane
    }

    /// Porta spessore e proiezione di un riquadro su tutti gli altri.
    ///
    /// Serve perché avere tre valori indipendenti è giusto e ogni tanto se ne vuole uno solo:
    /// confrontare le tre viste ortogonali sullo stesso spessore è un gesto normale. Senza questo
    /// comando si dovrebbe ripetere la scelta tre volte, che è il difetto opposto a quello appena
    /// corretto.
    func applyViewportSettingsToAll(from slot: ViewportSlot) {
        let thickness = slabThickness(for: slot)
        let mode = projection(for: slot)
        for other in ViewportSlot.allCases where other != slot {
            setSlabThickness(thickness, for: other)
            setProjection(mode, for: other)
        }
        slabThicknessMM = thickness
        projection = mode
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

    /// Zoom ancorato a un pixel del riquadro: ciò che sta sotto il puntatore non si muove.
    ///
    /// `pixelSize` è la dimensione del drawable, che solo la vista conosce. Se non è ancora nota
    /// si ricade sullo zoom centrato, che è impreciso ma non sbagliato: succede al più per il
    /// primo fotogramma dopo l'apertura.
    func zoom(slot: ViewportSlot, factor: Double, atPixel point: CGPoint, pixelSize: CGSize) {
        guard let plane = planes[slot] else { return }
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            planes[slot] = plane.zoomed(by: factor)
            return
        }
        planes[slot] = plane.zoomed(
            by: factor,
            aboutPixelX: Double(point.x),
            y: Double(point.y),
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height))
    }

    /// Ruota l'inquadratura di un riquadro nel proprio piano, attorno al mirino.
    ///
    /// Il perno è il mirino e non il centro del riquadro: si ruota per raddrizzare *quel* punto,
    /// e ruotare attorno al centro lo porterebbe altrove costringendo a inseguirlo col pan.
    func rotate(slot: ViewportSlot, byRadians angle: Double) {
        guard let plane = planes[slot] else { return }
        planes[slot] = plane.rotatedInPlane(byRadians: angle, aboutMM: crosshairMM)
    }

    /// Riporta un riquadro a inquadrare tutto il volume, senza toccare orientamento né mirino.
    func resetView(slot: ViewportSlot) {
        guard let plane = planes[slot], let geometry = volume?.geometry else { return }
        planes[slot] = plane.fitted(to: geometry)
    }

    /// Riporta tutti i riquadri all'orientamento anatomico canonico e all'inquadratura piena.
    ///
    /// È la via di uscita quando si è ruotato e ingrandito fino a perdersi. Rimette anche gli assi
    /// a posto, cosa che `resetView(slot:)` di proposito non fa: lì si vuole tornare a vedere
    /// tutto conservando il raddrizzamento appena trovato, qui si vuole ricominciare.
    func resetAllViews() {
        guard let geometry = volume?.geometry else { return }
        for slot in ViewportSlot.allCases {
            guard let anatomical = slot.anatomicalPlane else { continue }
            let size = geometry.physicalSizeMM
            let extent = max(size.x, max(size.y, size.z)) * 1.05
            planes[slot] = MPRPlane(
                plane: anatomical,
                through: crosshairMM,
                widthMM: extent,
                heightMM: extent,
                // Anche qui spessore e proiezione del riquadro sopravvivono: «riporta tutto
                // all'origine» riguarda l'inquadratura, non il modo di leggere l'immagine.
                slabThicknessMM: planes[slot]?.slabThicknessMM ?? slabThicknessMM,
                projection: planes[slot]?.projection ?? projection
            ).fitted(to: geometry)
        }
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
