import ArchiveKit
import ArtifactKit
import DICOMCore
import DentalKit
import GuideKit
import ImplantKit
import MeasureKit
import MeshKit
import Metal
import StudyKit
import Observation
import ReportKit
import SegmentKit
import SwiftUI
import UniformTypeIdentifiers
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
    /// Profilo di densità lungo un segmento: il risultato è una curva, non un numero, ed è per
    /// questo che ha un pulsante suo invece di essere una variante del righello.
    case profile
    /// Tracciato a mano libera: si disegna trascinando, non facendo clic.
    case freehand
    case implant
    /// Sagoma di dente protesico: si posa **prima** dell'impianto, dove la protesi lo vuole.
    case prostheticTooth
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
        case .profile: return "Profilo di densità"
        case .freehand: return "Mano libera"
        case .implant: return "Impianto"
        case .prostheticTooth: return "Dente protesico"
        case .nerve: return "Traccia nervo"
        case .archCurve: return "Disegna arcata"
        }
    }

    /// Una riga che dice come si usa. Compare sotto la palette, e vale piu' di un'icona: un
    /// righello che chiede **due** clic non lo dice da se', e chi ne dà uno solo pensa sia rotto.
    var hint: String? {
        switch self {
        case .navigate: return nil
        case .distance: return "Trascina fra i due estremi, o fai clic su ciascuno."
        case .angle: return "Fai clic sui tre punti, il vertice per primo."
        case .ellipseROI: return "Trascina dal centro al bordo, o fai clic sui due punti."
        case .sphereROI: return "Trascina dal centro al bordo, o fai clic sui due punti."
        case .text: return "Fai clic dove vuoi la nota."
        case .profile: return "Trascina lungo il segmento: legge le densità che attraversa."
        case .freehand: return "Trascina per disegnare: il tracciato si chiude alzando il dito."
        case .implant: return "Fai clic sulla cresta: l'impianto scende da lì."
        case .prostheticTooth:
            return "Scegli il numero e fai clic sull'occlusale: la corona si posa lì."
        case .nerve: return "Fai clic lungo il canale, un nodo per volta."
        case .archCurve: return "Fai clic sull'assiale per posare i punti. ⌥ clic per togliere."
        }
    }

    /// Scorciatoia a tasto singolo, come nei visori: si cambia strumento senza modificatori,
    /// perché lo si cambia venti volte in una sessione e ⌘ moltiplicato per venti si sente.
    var shortcut: Character {
        switch self {
        case .navigate: return "n"
        case .distance: return "d"
        case .angle: return "g"
        case .ellipseROI: return "e"
        case .sphereROI: return "s"
        case .text: return "t"
        case .profile: return "p"
        case .freehand: return "f"
        case .implant: return "i"
        case .prostheticTooth: return "c"
        case .nerve: return "v"
        case .archCurve: return "a"
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
        case .profile: return "chart.xyaxis.line"
        case .freehand: return "scribble"
        case .implant: return "screwdriver"
        case .prostheticTooth: return "mouth"
        case .nerve: return "point.topleft.down.curvedto.point.bottomright.up"
        case .archCurve: return "scribble.variable"
        }
    }

}

// MARK: - Layout

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

// I riquadri e la loro disposizione vivono in `StudyKit`: sono dati, e stando lì si verificano
// con `swift test` invece che soltanto sul Mac. Qui resta ciò che è davvero interfaccia.

extension ViewportSlot {
    /// Colore del piano, che è **la stessa informazione** del bordo del riquadro, della traccia
    /// del mirino sugli altri due e del piano disegnato nel 3D. Una sola definizione perché
    /// quelle tre cose devono restare d'accordo: se divergessero, il colore smetterebbe di
    /// essere un'indicazione e diventerebbe rumore.
    var accentColor: Color {
        guard let anatomical = anatomicalPlane else { return Palette.volume3D }
        return Palette.color(for: anatomical)
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

    /// Preset della finestra di densità, quelli che governano le **viste 2D**.
    ///
    /// Distinti dai preset di rendering, che governano il solo riquadro 3D: sono due filtri
    /// diversi e la confusione fra i due è già costata una segnalazione di «non cambia nulla».
    static let densityWindowPresets: [(name: String, value: DensityWindow)] = [
        ("Osso", .bone),
        ("Denti", .teeth),
        ("Tessuti molli", .softTissue),
        ("ATM", .tmj),
    ]

    var windowLevel: DensityWindow = .bone
    var slabThicknessMM: Double = 0
    var projection: SlabProjection = .average
    /// Risoluzione di rendering dei riquadri 2D. Vedi `MPRResolution`.
    var mprResolution: MPRResolution = .full
    /// Modo di lavoro corrente e memoria dei modi. Vedi `WorkspaceSession`.
    var session = WorkspaceSession()

    /// Disposizione e riquadro attivo **del modo corrente**.
    ///
    /// Sono proiezioni della sessione e non due campi a sé: con due campi, cambiare scheda
    /// significherebbe riassegnarli, e tornando indietro si troverebbe la disposizione di
    /// fabbrica invece della propria. Passando dalla sessione la memoria è per modo senza che
    /// nessuna vista debba occuparsene.
    var layout: ViewportLayout {
        get { session.layout }
        set { session.layout = newValue }
    }

    var focusedSlot: ViewportSlot {
        get { session.focusedSlot }
        set { session.focusedSlot = newValue }
    }

    var workMode: WorkMode { session.mode }

    /// Passa a un altro modo di lavoro.
    ///
    /// Il mirino, la finestra di densità, le annotazioni, la curva e gli impianti **non** si
    /// toccano: sono proprietà del caso, non del modo in cui lo si guarda, e ritrovarli spostati
    /// dopo un giro fra le schede farebbe perdere il punto che si stava esaminando. Cambiano solo
    /// disposizione e riquadro attivo, che la sessione ricorda per ciascun modo.
    func activate(mode: WorkMode) {
        guard mode != session.mode else { return }
        session.activate(mode)
        // Entrando in modo curvo con una curva già disegnata, le sezioni vanno ricostruite: si
        // può esserci arrivati dopo aver ritagliato il volume, e quelle vecchie apparterrebbero a
        // dati che non ci sono più.
        if mode.usesArchCurve, archCurve.isUsable, crossSectionBrowser.sections.isEmpty {
            rebuildCrossSections()
        }
        // In sola lettura nessuno strumento di modifica resta in mano.
        if !mode.isEditable { activeTool = .navigate }
    }

    /// Variante scelta, **una per strumento**.
    ///
    /// Una variabile sola per tutti gli strumenti se la portava dietro passando dall'uno
    /// all'altro: scelto «perimetro» sul righello, il goniometro si ritrovava una variante che
    /// non gli appartiene, e la corrispondenza fra ciò che l'icona mostra e ciò che lo strumento
    /// fa dipendeva dall'ordine in cui li si era usati. Tenendone una per strumento, ciascuno
    /// ricorda la propria e nessuno eredita quella di un altro.
    ///
    /// L'assenza vale «la variante predefinita», che per ogni strumento è la prima: distanza fra
    /// due punti, angolo a tre punti, ROI ellittica, nota di testo.
    private var toolVariants: [Tool: String] = [:]

    /// Variante dello strumento attivo. Vedi `ToolPalette`.
    var toolVariant: String {
        get { toolVariants[activeTool] ?? "" }
        set { toolVariants[activeTool] = newValue }
    }

    var activeTool: Tool = .navigate {
        didSet {
            // Uno strumento di modifica non si prende in «Rivedi». Il guard sta qui e non in ogni
            // pulsante perché gli strumenti si attivano anche da tastiera e dal menu, e tre vie
            // allo stesso stato vogliono un solo controllo.
            if !session.mode.isEditable, activeTool != .navigate { activeTool = .navigate }
        }
    }

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

    /// Vero quando è aperta la finestra di ritaglio e ricampionamento.
    var isShowingReformat = false

    /// Legenda dei comandi. Vedi `ShortcutsSheet`.
    var isShowingShortcuts = false

    /// Finestra di raddrizzamento. Vedi `ReorientSheet`.
    var isShowingReorient = false

    /// Finestra di riduzione delle strie. Vedi `ArtifactSheet`.
    var isShowingArtifact = false

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

    /// Passi disponibili fra una sezione trasversale e l'altra.
    ///
    /// Parte da 150 µm e non da mezzo millimetro. Su una cresta stretta due sezioni a un
    /// millimetro possono cadere una davanti e una dietro la corticale vestibolare senza mai
    /// mostrarla, e l'osso che c'è si scambia per osso che manca.
    static let crossSectionIntervalPresetsMM: [Double] = [
        0.15, 0.25, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0,
    ]

    var crossSectionIntervalMM: Double = 1.0
    var crossSectionWidthMM: Double = 30
    var crossSectionHeightMM: Double = 45
    var crossSectionThicknessMM: Double = 0

    /// Inclinazione del taglio rispetto alla perpendicolare all'arcata, in radianti.
    ///
    /// Si regola ruotando la linea disegnata sul panorex. La perpendicolare non è sempre ciò che
    /// serve: l'asse di un dente incluso o di un impianto già posato si vede bene solo lungo il
    /// proprio asse.
    var crossSectionAngleOffset: Double = 0 {
        didSet {
            guard crossSectionAngleOffset != oldValue else { return }
            rebuildCrossSections()
        }
    }

    /// Navigazione della striscia: finestra visibile, selezione, ingrandimento.
    ///
    /// Tutta la logica sta in `CrossSectionBrowser`, in DentalKit, dove si verifica con i test.
    /// Qui resta solo la proprietà.
    var crossSectionBrowser = CrossSectionBrowser(visibleCount: 10)

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

    /// Cambia lo spessore dello slab del panorex.
    ///
    /// Da mezzo millimetro — una fetta sola, che è ciò che serve per seguire un canale — a trenta,
    /// oltre i quali tutto si sovrappone e l'immagine diventa una nebbia.
    func changePanoramicSlab(byMM delta: Double) {
        guard delta.isFinite else { return }
        panoramicSlabThicknessMM = min(max(panoramicSlabThicknessMM + delta, 0.5), 30)
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
            thicknessMM: crossSectionThicknessMM,
            angleOffsetRadians: crossSectionAngleOffset)
    }

    /// Sezioni calcolate, ricostruite quando la curva o i parametri cambiano.
    ///
    /// Non è una proprietà calcolata: generarle richiede di ricampionare la spline, e farlo a
    /// ogni ridisegno di ogni riquadro renderebbe il trascinamento della curva una melassa.
    var crossSections: [CrossSection] { crossSectionBrowser.sections }

    func rebuildCrossSections() {
        guard archCurve.isUsable else {
            crossSectionBrowser.replaceSections([])
            return
        }
        // `replaceSections` conserva la **posizione lungo l'arcata** e non l'indice: cambiando il
        // passo la selezione resta sul dente che si stava guardando.
        crossSectionBrowser.replaceSections(crossSectionLayout.sections())
    }

    /// Porta il mirino e le altre viste sulla sezione selezionata.
    func focusSelectedCrossSection() {
        guard let section = crossSectionBrowser.selectedSection else { return }
        crosshairMM = section.originMM
    }

    /// Seleziona la sezione più vicina a una posizione lungo l'arcata, e ci porta le altre viste.
    func selectCrossSection(nearestToArcLengthMM arcLength: Double) {
        crossSectionBrowser.select(nearestToArcLengthMM: arcLength)
        focusSelectedCrossSection()
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
        recordUndo("Aggiungi punto dell'arcata")
    }

    func moveArchPoint(at index: Int, to pointMM: Vec3) {
        var curve = archCurve
        curve.moveControlPoint(at: index, to: pointMM)
        archCurve = curve
        // Raggruppato: trascinare un punto produce un evento per pixel.
        recordContinuousUndo("Sposta punto dell'arcata")
    }

    func removeArchPoint(at index: Int) {
        var curve = archCurve
        guard curve.removeControlPoint(at: index) else { return }
        archCurve = curve
        selectedArchPointIndex = nil
        rebuildCrossSections()
        recordUndo("Togli punto dell'arcata")
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

    /// Riporta la finestra di densità a quella ricavata dall'istogramma del volume.
    func resetWindowLevel() {
        guard let volume else { return }
        windowLevel = DensityWindow.automatic(from: volume)
    }

    /// Propone una curva d'arcata **alla quota che si sta guardando**.
    ///
    /// È un comando, non un comportamento automatico: la curva la decide chi guarda l'anatomia, e
    /// questo serve a non dover posare nove punti da zero.
    ///
    /// Prova due strade in ordine, e **dice quale ha usato**. Prima cerca l'osso alla quota del
    /// mirino con `ArchDetection`, che segue l'anatomia di questo paziente; se non trova
    /// un'arcata riconoscibile ripiega sulla parabola tipica, che è una forma media e non ha
    /// niente a che vedere con questa bocca. La differenza fra le due conta: la prima si corregge
    /// spostando due punti, la seconda va rifatta quasi da capo, e chi la riceve deve sapere
    /// quale ha in mano invece di scoprirlo dal risultato del panorex.
    func suggestArchCurve() {
        guard let volume else { return }
        let geometry = volume.geometry

        if let points = ArchDetection.suggestArchPoints(
            in: volume, atVerticalMM: crosshairMM.z, pointCount: 9)
        {
            archCurves[activeArch] = ArchCurve(controlPointsMM: points)
            lastActionMessage =
                "Curva ricavata dall'osso, \(points.count) punti. Correggila trascinandoli."
        } else {
            archCurves[activeArch] = ArchCurve.suggested(
                for: geometry, atVerticalMM: crosshairMM.z, arch: activeArch)
            lastActionMessage =
                "Nessuna arcata riconoscibile a questa quota: proposta una forma tipica, da correggere."
        }

        archVerticalCentreMM = crosshairMM.z
        selectedArchPointIndex = nil
        isEditingArch = true
        rebuildCrossSections()
        recordUndo("Curva proposta")
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

    // MARK: Esportazione

    /// Le quattro azioni del pannello «Esporta», raccolte qui invece che nelle viste.
    ///
    /// Nelle viste ci stavano già, sparse: il CSV nell'ispettore, il salvataggio nel menu
    /// dell'applicazione. Tre punti diversi per tre cose che l'utente vede come una sola famiglia,
    /// e nessuno che le trovasse. Concentrarle nel modello significa che il pannello le chiama e
    /// basta, e che aggiungerne una quinta non richiede di decidere dove metterla.

    /// Messaggio dell'ultima azione, mostrato in barra di stato. `nil` quando non c'è nulla da
    /// dire: un'azione riuscita in silenzio lascia il dubbio che non sia successo niente.
    var lastActionMessage: String?

    /// Istantanea del riquadro attivo, in PNG.
    ///
    /// Risoluzione fissa e generosa, indipendente da quella della finestra: chi esporta vuole
    /// un'immagine da guardare altrove, non una copia di quanto sta a schermo.
    func requestSnapshot() {
        guard volume != nil, let plane = planes[focusedSlot] else {
            lastActionMessage = "Nessuno studio aperto."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(focusedSlot.localizedName.lowercased()).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ImageExport.exportPNG(
                plane: plane, model: self, pixelWidth: 1600, pixelHeight: 1200, to: url)
            lastActionMessage = "Immagine salvata in \(url.lastPathComponent)."
        } catch {
            lastActionMessage = "Esportazione fallita: \(error.localizedDescription)"
        }
    }

    func copyMeasurementsToClipboard() {
        guard !annotations.isEmpty else {
            lastActionMessage = "Nessuna misura da copiare."
            return
        }
        let csv = makePlanDocument().measurementsCSV(unit: densityUnit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(csv, forType: .string)
        lastActionMessage = "\(annotations.count) misure copiate negli appunti."
    }

    func exportMeasurementsCSV() {
        guard !annotations.isEmpty else {
            lastActionMessage = "Nessuna misura da esportare."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "misure.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = makePlanDocument().measurementsCSV(unit: densityUnit)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            lastActionMessage = "Misure esportate in \(url.lastPathComponent)."
        } catch {
            lastActionMessage = "Esportazione fallita: \(error.localizedDescription)"
        }
    }

    func savePlan() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(studyName).cbctplan"
        panel.allowedContentTypes = [.data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectDocument(from: self).write(to: url)
            lastActionMessage = "Piano salvato in \(url.lastPathComponent)."
        } catch {
            lastActionMessage = "Salvataggio fallito: \(error.localizedDescription)"
        }
    }

    // MARK: Oggetti del piano

    /// Attributi comuni degli oggetti — nome, visibilità, colore, nota, ordine. Vedi
    /// `PlanObjectRegistry`.
    ///
    /// Vive accanto agli oggetti invece che dentro di essi perché gli oggetti stanno in moduli
    /// diversi — impianti in ImplantKit, curve in DentalKit, misure in MeasureKit — e mettere gli
    /// attributi comuni dentro ciascuno significherebbe ripeterli tre volte e vederli divergere.
    private(set) var registry = PlanObjectRegistry()

    /// Allinea il registro agli oggetti realmente presenti.
    ///
    /// Si chiama dopo ogni mutazione del piano. Gli oggetti nuovi entrano con nome e colore
    /// proposti; quelli spariti escono. Senza, l'elenco mostrerebbe voci per oggetti cancellati —
    /// che si potrebbero selezionare senza che accada nulla.
    func syncRegistry() {
        var updated = registry

        var live: Set<UUID> = []
        for implant in implants {
            live.insert(implant.id)
            if updated[implant.id] == nil {
                var info = PlanObjectInfo(
                    id: implant.id, kind: .implant,
                    name: implant.label.isEmpty
                        ? updated.suggestedName(for: .implant) : implant.label,
                    order: updated.objects(of: .implant).count)
                info.colorHex = updated.suggestedColorHex(for: .implant)
                updated.register(info)
            }
        }
        for tooth in teeth {
            live.insert(tooth.id)
            if updated[tooth.id] == nil {
                var info = PlanObjectInfo(
                    id: tooth.id, kind: .prostheticTooth,
                    name: "Dente \(tooth.toothNumber)",
                    order: updated.objects(of: .prostheticTooth).count)
                info.colorHex = updated.suggestedColorHex(for: .prostheticTooth)
                updated.register(info)
            }
        }
        for nerve in nerveCanals {
            live.insert(nerve.id)
            if updated[nerve.id] == nil {
                var info = PlanObjectInfo(
                    id: nerve.id, kind: .nerveCanal,
                    name: updated.suggestedName(for: .nerveCanal),
                    order: updated.objects(of: .nerveCanal).count)
                info.colorHex = updated.suggestedColorHex(for: .nerveCanal)
                updated.register(info)
            }
        }
        for annotation in annotations {
            live.insert(annotation.id)
            if updated[annotation.id] == nil {
                var info = PlanObjectInfo(
                    id: annotation.id, kind: .annotation,
                    name: annotation.metadata.label.isEmpty
                        ? annotation.kindName : annotation.metadata.label,
                    order: updated.objects(of: .annotation).count)
                info.colorHex = updated.suggestedColorHex(for: .annotation)
                updated.register(info)
            }
        }

        if segmentationMesh != nil {
            live.insert(Self.segmentationObjectID)
            if updated[Self.segmentationObjectID] == nil {
                var info = PlanObjectInfo(
                    id: Self.segmentationObjectID, kind: .mesh,
                    name: "Segmentazione",
                    order: updated.objects(of: .mesh).count)
                info.colorHex = "9B6BFF"
                updated.register(info)
            }
        }

        for object in updated.objects where !live.contains(object.id) {
            updated.remove(id: object.id)
        }
        registry = updated
    }

    /// Accende o spegne un oggetto.
    func setObjectVisible(_ visible: Bool, id: UUID) {
        registry.setVisible(visible, id: id)
        // La visibilità vive in due posti per gli impianti — nel registro e nell'oggetto — perché
        // il disegno 3D legge l'oggetto. Si tengono allineati qui, in un punto solo.
        if let index = implants.firstIndex(where: { $0.id == id }) {
            implants[index].isVisible = visible
        }
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].metadata.isHidden = !visible
        }
        if let index = nerveCanals.firstIndex(where: { $0.id == id }) {
            nerveCanals[index].isVisible = visible
        }
        if let index = teeth.firstIndex(where: { $0.id == id }) {
            teeth[index].isVisible = visible
        }
        if id == Self.segmentationObjectID {
            isSegmentationVisible = visible
        }
        recordUndo(visible ? "Mostra oggetto" : "Nascondi oggetto")
    }

    func setObjectColor(_ hex: String, id: UUID) {
        if var info = registry[id] {
            info.colorHex = hex
            registry[id] = info
        }
        if let index = implants.firstIndex(where: { $0.id == id }) {
            implants[index].colorHex = hex.hasPrefix("#") ? hex : "#" + hex
        }
        if let index = annotations.firstIndex(where: { $0.id == id }) {
            annotations[index].metadata.colorHex = hex.hasPrefix("#") ? hex : "#" + hex
        }
        if let index = nerveCanals.firstIndex(where: { $0.id == id }) {
            nerveCanals[index].colorHex = hex.hasPrefix("#") ? hex : "#" + hex
        }
        if let index = teeth.firstIndex(where: { $0.id == id }) {
            teeth[index].colorHex = hex.hasPrefix("#") ? hex : "#" + hex
        }
        recordUndo("Cambia colore")
    }

    func renameObject(_ name: String, id: UUID) {
        registry.rename(name, id: id)
        if let index = implants.firstIndex(where: { $0.id == id }) {
            implants[index].label = name
        }
        if let index = teeth.firstIndex(where: { $0.id == id }) {
            teeth[index].label = name
        }
        recordUndo("Rinomina")
    }

    func setObjectLocked(_ locked: Bool, id: UUID) {
        registry.setLocked(locked, id: id)
    }

    /// Porta tutte le viste su un oggetto.
    ///
    /// È l'azione più usata di un elenco di oggetti e la più facile da dimenticare: senza, per
    /// tornare su un impianto pianificato mezz'ora prima bisogna cercarlo scorrendo le fette.
    func centreOnObject(id: UUID) {
        if let implant = implants.first(where: { $0.id == id }) {
            moveCrosshair(to: implant.platformMM)
            selectedImplantID = id
            return
        }
        if let tooth = teeth.first(where: { $0.id == id }) {
            moveCrosshair(to: tooth.positionMM)
            selectedToothID = id
            return
        }
        if let nerve = nerveCanals.first(where: { $0.id == id }), let first = nerve.nodes.first {
            moveCrosshair(to: first.positionMM)
            return
        }
        if let annotation = annotations.first(where: { $0.id == id }),
            let handle = annotation.handlesMM.first
        {
            moveCrosshair(to: handle)
            selectedAnnotationID = id
        }
    }

    func deleteObject(id: UUID) {
        if id == Self.segmentationObjectID {
            clearSegmentation()
            return
        }
        implants.removeAll { $0.id == id }
        teeth.removeAll { $0.id == id }
        nerveCanals.removeAll { $0.id == id }
        annotations.removeAll { $0.id == id }
        if selectedImplantID == id { selectedImplantID = nil }
        if selectedToothID == id { selectedToothID = nil }
        if selectedAnnotationID == id { selectedAnnotationID = nil }
        registry.remove(id: id)
        recomputeSafety()
        recordUndo("Cancella oggetto")
    }

    /// Cancella tutti gli oggetti di un tipo.
    func deleteObjects(of kind: PlanObjectKind) {
        let doomed = Set(registry.objects(of: kind).map(\.id))
        guard !doomed.isEmpty else { return }
        implants.removeAll { doomed.contains($0.id) }
        teeth.removeAll { doomed.contains($0.id) }
        nerveCanals.removeAll { doomed.contains($0.id) }
        annotations.removeAll { doomed.contains($0.id) }
        if let id = selectedToothID, doomed.contains(id) { selectedToothID = nil }
        if let id = selectedImplantID, doomed.contains(id) { selectedImplantID = nil }
        registry.removeAll(of: kind)
        recomputeSafety()
        recordUndo("Cancella tutti")
    }

    /// Duplica un impianto, spostandolo di un passo perché non resti nascosto sotto l'originale.
    func duplicateImplant(id: UUID) {
        guard let source = implants.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.label = ""
        // Cinque millimetri lungo l'arcata, non lungo un asse della macchina: si duplica un
        // impianto per metterlo accanto al precedente nella stessa arcata.
        let offset = archCurve.isUsable ? archTangent(near: source.platformMM) : Vec3(5, 0, 0)
        copy.platformMM = source.platformMM + offset * 5
        implants.append(copy)
        selectedImplantID = copy.id
        recomputeSafety()
        syncRegistry()
        recordUndo("Duplica impianto")
    }

    /// Specchia un impianto sul lato opposto, ribaltando la componente L-R.
    ///
    /// Ribalta rispetto a x = 0, che in LPS è il piano sagittale mediano nominale. Su un paziente
    /// non centrato nella macchina non è il suo vero piano mediano, e il risultato va controllato:
    /// è un punto di partenza, non una simmetria anatomica.
    func mirrorImplant(id: UUID) {
        guard let source = implants.first(where: { $0.id == id }) else { return }
        var copy = source
        copy.id = UUID()
        copy.label = ""
        copy.platformMM = Vec3(-source.platformMM.x, source.platformMM.y, source.platformMM.z)
        copy.axis = Vec3(-source.axis.x, source.axis.y, source.axis.z)
        implants.append(copy)
        selectedImplantID = copy.id
        recomputeSafety()
        syncRegistry()
        recordUndo("Specchia impianto")
    }

    /// Tangente all'arcata vicino a un punto, per duplicare lungo la curva.
    func archTangent(near pointMM: Vec3) -> Vec3 {
        let samples = archCurve.resampled(count: 80)
        var best = samples.first
        var bestDistance = Double.infinity
        for sample in samples {
            let distance = sample.positionMM.distance(to: pointMM)
            if distance < bestDistance {
                bestDistance = distance
                best = sample
            }
        }
        return best?.tangent ?? Vec3(1, 0, 0)
    }

    // MARK: Annulla e ripeti

    /// Tutto ciò che «annulla» deve poter riportare indietro.
    ///
    /// Contiene il **piano**, non la vista: annotazioni, impianti, nervi, curve. Zoom, finestra di
    /// densità e fetta corrente restano fuori di proposito. Sono navigazione, non lavoro: chi
    /// preme ⌘Z dopo aver cancellato un impianto vuole l'impianto, non l'inquadratura di prima, e
    /// una cronologia che mescola le due cose costringe a premere venti volte per tornare a
    /// un'operazione vera.
    struct PlanSnapshot: Equatable, Sendable {
        var annotations: [Annotation]
        var implants: [ImplantPlacement]
        var teeth: [ProstheticTooth]
        var nerveCanals: [NerveCanal]
        var archCurves: [DentalArch: ArchCurve]
    }

    private var undoHistory = UndoHistory<PlanSnapshot>(initial: PlanSnapshot(
        annotations: [], implants: [], teeth: [], nerveCanals: [], archCurves: [:]))

    /// Vero mentre si sta applicando un annulla: le mutazioni che ne derivano non vanno
    /// registrate, altrimenti annullare creerebbe un passo nuovo e «ripeti» non tornerebbe mai.
    private var isRestoring = false

    var canUndo: Bool { undoHistory.canUndo }
    var canRedo: Bool { undoHistory.canRedo }
    var undoLabel: String? { undoHistory.undoLabel }
    var redoLabel: String? { undoHistory.redoLabel }

    private var planSnapshot: PlanSnapshot {
        PlanSnapshot(
            annotations: annotations, implants: implants, teeth: teeth,
            nerveCanals: nerveCanals, archCurves: archCurves)
    }

    /// Registra lo stato attuale come un passo annullabile.
    func recordUndo(_ label: String) {
        guard !isRestoring else { return }
        undoHistory.commit(planSnapshot, label: label)
    }

    /// Come `recordUndo`, ma unisce le chiamate ravvicinate con la stessa etichetta.
    ///
    /// Da usare durante i trascinamenti: senza, spostare un impianto lascia in cronologia un
    /// passo per ogni pixel percorso.
    func recordContinuousUndo(_ label: String) {
        guard !isRestoring else { return }
        undoHistory.coalesce(planSnapshot, label: label, within: 1.2)
    }

    func undo() { apply(undoHistory.undo()) }
    func redo() { apply(undoHistory.redo()) }

    private func apply(_ snapshot: PlanSnapshot?) {
        guard let snapshot else { return }
        isRestoring = true
        annotations = snapshot.annotations
        implants = snapshot.implants
        teeth = snapshot.teeth
        nerveCanals = snapshot.nerveCanals
        archCurves = snapshot.archCurves
        isRestoring = false

        // Ciò che deriva dal piano si ricalcola invece di essere conservato nell'istantanea:
        // sono funzioni dello stato, e tenerne una copia significherebbe poterle avere in
        // disaccordo con esso.
        recomputeSafety()
        syncRegistry()
        if archCurve.isUsable { rebuildCrossSections() }
    }

    // MARK: Nervo e impianti

    var nerveCanals: [NerveCanal] = []
    var implants: [ImplantPlacement] = []
    var selectedImplantID: UUID?

    // MARK: Denti protesici
    //
    // L'ordine corretto è l'inverso di quello comodo: prima il dente, dove la funzione e
    // l'estetica lo vogliono, poi l'impianto sotto di esso. `ProstheticPlanning` esisteva da
    // tempo e non aveva un modo per arrivare allo schermo — un impianto perfetto nell'osso che
    // emerge fuori dalla corona è inservibile, e finora il programma non sapeva dirlo.

    var teeth: [ProstheticTooth] = []
    var selectedToothID: UUID?
    /// Numero FDI del prossimo dente posato. Si sceglie prima del clic, come il modello implantare.
    var pendingToothNumber: Int = 46
    var prostheticThresholds: ProstheticThresholds = .standard

    var selectedTooth: ProstheticTooth? {
        guard let id = selectedToothID else { return nil }
        return teeth.first { $0.id == id }
    }
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

    /// Maniglia di annotazione afferrata.
    private(set) var annotationDrag: (id: UUID, handle: Int)?
    /// Nodo di nervo afferrato.
    private(set) var nerveDrag: (canal: UUID, node: UUID)?

    /// Prova ad afferrare la maniglia di una misura o il nodo di un nervo.
    ///
    /// `handlesMM` esisteva dall'inizio e nessuno lo manipolava: una misura posata un millimetro
    /// più in là andava cancellata e rifatta, e su un angolo a tre punti significava rifarne tre.
    /// Lo stesso per un nervo, che si traccia con quindici clic e per un nodo sbagliato si
    /// ricominciava da capo.
    ///
    /// - Returns: `true` se qualcosa è stato afferrato.
    @discardableResult
    func beginHandleDrag(at pointMM: Vec3, toleranceMM: Double) -> Bool {
        annotationDrag = nil
        nerveDrag = nil
        guard workMode.isEditable else { return false }

        // Il più vicino in assoluto fra tutti i candidati, misure e nodi insieme: su un nervo che
        // passa sotto una misura le due prese si sovrappongono, e decidere per categoria invece
        // che per distanza renderebbe una delle due irraggiungibile.
        var bestDistance = Double.infinity
        var chosen: (() -> Void)?

        for annotation in annotations where !annotation.metadata.isHidden {
            guard let hit = annotation.nearestHandle(to: pointMM, toleranceMM: toleranceMM),
                hit.distanceMM < bestDistance
            else { continue }
            bestDistance = hit.distanceMM
            let id = annotation.id
            chosen = { [self] in
                annotationDrag = (id, hit.index)
                nerveDrag = nil
                selectedAnnotationID = id
            }
        }

        for canal in nerveCanals {
            guard let node = canal.nearestNode(to: pointMM, toleranceMM: toleranceMM) else {
                continue
            }
            let distance = node.positionMM.distance(to: pointMM)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            chosen = { [self] in
                nerveDrag = (canal.id, node.id)
                annotationDrag = nil
            }
        }

        chosen?()
        return chosen != nil
    }

    /// Continua il trascinamento di una maniglia.
    func dragHandle(toMM pointMM: Vec3) {
        if let drag = annotationDrag,
            let index = annotations.firstIndex(where: { $0.id == drag.id })
        {
            annotations[index] = annotations[index].movingHandle(at: drag.handle, toMM: pointMM)
            recomputeStatistics(for: annotations[index])
            recordContinuousUndo("Correggi misura")
            return
        }

        if let drag = nerveDrag,
            let canalIndex = nerveCanals.firstIndex(where: { $0.id == drag.canal }),
            let nodeIndex = nerveCanals[canalIndex].nodes.firstIndex(where: { $0.id == drag.node })
        {
            nerveCanals[canalIndex].nodes[nodeIndex].positionMM = pointMM
            recomputeSafety()
            recordContinuousUndo("Correggi nervo")
        }
    }

    func endHandleDrag() {
        annotationDrag = nil
        nerveDrag = nil
    }

    /// Toglie il nodo di nervo più vicino a un punto. È il ⌥ clic, come sulla curva d'arcata.
    @discardableResult
    func removeNerveNode(near pointMM: Vec3, toleranceMM: Double) -> Bool {
        for index in nerveCanals.indices {
            guard let node = nerveCanals[index].nearestNode(to: pointMM, toleranceMM: toleranceMM)
            else { continue }
            nerveCanals[index].removeNode(id: node.id)
            // Un canale rimasto senza nodi a sufficienza non è più un canale: toglierlo evita un
            // oggetto nell'elenco che non si disegna e non si può più afferrare.
            if nerveCanals[index].nodes.count < 2 {
                let doomed = nerveCanals[index].id
                nerveCanals.removeAll { $0.id == doomed }
                if tracingNerveID == doomed { tracingNerveID = nil }
            }
            recomputeSafety()
            syncRegistry()
            recordUndo("Togli nodo del nervo")
            return true
        }
        return false
    }

    /// Presa sull'impianto in corso, con l'ultimo punto raggiunto.
    ///
    /// Sta nel modello e non nella vista perché un impianto si afferra in un riquadro e lo si
    /// guarda in tutti: il trascinamento comincia sull'assiale e la sezione trasversale deve
    /// mostrarlo muoversi nello stesso istante.
    private(set) var implantDrag: (id: UUID, grip: ImplantGrip, lastMM: Vec3)?

    /// Prova ad afferrare un impianto in un punto.
    ///
    /// - Parameter toleranceMM: quanto lontano dalla superficie si può premere, commisurato a
    ///   quanto vale un pixel nel riquadro. Una tolleranza fissa in millimetri renderebbe la
    ///   presa impossibile su una vista d'insieme e troppo facile su una molto ingrandita.
    /// - Returns: `true` se qualcosa è stato afferrato, così chi chiama sa di non dover
    ///   interpretare lo stesso gesto anche in altri modi.
    @discardableResult
    func beginImplantDrag(at pointMM: Vec3, toleranceMM: Double) -> Bool {
        implantDrag = nil
        guard workMode.isEditable else { return false }

        // Il più vicino all'asse fra quelli che si possono afferrare, non il primo dell'elenco:
        // su due impianti adiacenti a tre millimetri l'uno dall'altro le zone di presa si
        // sovrappongono, e prendere sempre il primo renderebbe il secondo inafferrabile.
        var best: (implant: ImplantPlacement, grip: ImplantGrip, distance: Double)?
        for implant in implants where implant.isVisible {
            guard
                let grip = ImplantManipulation.grip(
                    at: pointMM, of: implant, toleranceMM: toleranceMM)
            else { continue }
            let relative = pointMM - implant.platformMM
            let z = relative.dot(implant.axis)
            let radial = (relative - implant.axis * z).length
            if best == nil || radial < best!.distance {
                best = (implant, grip, radial)
            }
        }

        guard let best else { return false }
        implantDrag = (best.implant.id, best.grip, pointMM)
        selectedImplantID = best.implant.id
        return true
    }

    /// Continua il trascinamento di un impianto.
    func dragImplant(toMM pointMM: Vec3) {
        guard let drag = implantDrag,
            let index = implants.firstIndex(where: { $0.id == drag.id })
        else { return }

        implants[index] = ImplantManipulation.dragged(
            implants[index], grip: drag.grip, toMM: pointMM, fromMM: drag.lastMM)
        implantDrag?.lastMM = pointMM
        recomputeSafety()
        recordContinuousUndo("Sposta impianto")
    }

    func endImplantDrag() {
        implantDrag = nil
    }

    // MARK: Trascinamento dei denti

    /// Dente afferrato, con la presa e l'ultimo punto del passo.
    private(set) var toothDrag: (id: UUID, grip: ToothGrip, lastMM: Vec3)?

    /// Prova ad afferrare un dente in un punto.
    ///
    /// Ha la **precedenza sull'impianto** quando le due prese si sovrappongono, e non è
    /// arbitrario: un impianto sta sotto la corona che serve, quindi le due zone di presa si
    /// intersecano quasi sempre. La corona è il pezzo esterno, quello che si vede sopra; nel
    /// mondo fisico è ciò che la mano incontra per primo, e nell'interfaccia deve valere lo
    /// stesso — per raggiungere l'impianto basta nascondere il dente o afferrarlo più in basso,
    /// mentre un dente che non si prende mai perché sotto c'è un impianto non ha rimedio.
    func beginToothDrag(at pointMM: Vec3, toleranceMM: Double) -> Bool {
        toothDrag = nil
        guard workMode.isEditable else { return false }

        var best: (tooth: ProstheticTooth, grip: ToothGrip, distance: Double)?
        for tooth in teeth where tooth.isVisible {
            guard
                let grip = ToothManipulation.grip(
                    at: pointMM, of: tooth, toleranceMM: toleranceMM)
            else { continue }
            let distance = pointMM.distance(to: tooth.positionMM)
            if best == nil || distance < best!.distance {
                best = (tooth, grip, distance)
            }
        }

        guard let best else { return false }
        toothDrag = (best.tooth.id, best.grip, pointMM)
        selectedToothID = best.tooth.id
        return true
    }

    /// Continua il trascinamento di un dente.
    func dragTooth(toMM pointMM: Vec3) {
        guard let drag = toothDrag,
            let index = teeth.firstIndex(where: { $0.id == drag.id })
        else { return }

        teeth[index] = ToothManipulation.dragged(
            teeth[index], grip: drag.grip, toMM: pointMM, fromMM: drag.lastMM)
        toothDrag?.lastMM = pointMM
        recordContinuousUndo("Sposta dente")
    }

    func endToothDrag() {
        toothDrag = nil
    }

    /// Afferra ciò che sta sotto il puntatore: prima un dente, poi un impianto.
    ///
    /// Un solo punto d'ingresso perché i riquadri sono cinque e la regola di precedenza deve
    /// essere una sola. Quando stava scritta in ogni riquadro, un riquadro l'aveva diversa —
    /// ed è così che il trascinamento dell'impianto era collegato sulle sezioni trasversali
    /// mentre il disegno non c'era.
    func beginObjectDrag(at pointMM: Vec3, toleranceMM: Double) -> Bool {
        if beginToothDrag(at: pointMM, toleranceMM: toleranceMM) { return true }
        return beginImplantDrag(at: pointMM, toleranceMM: toleranceMM)
    }

    /// Continua il trascinamento in corso, qualunque sia l'oggetto.
    func dragObject(toMM pointMM: Vec3) {
        if toothDrag != nil {
            dragTooth(toMM: pointMM)
        } else if implantDrag != nil {
            dragImplant(toMM: pointMM)
        }
    }

    func endObjectDrag() {
        endToothDrag()
        endImplantDrag()
    }

    /// Vero se un oggetto del piano è in corso di trascinamento.
    var isDraggingObject: Bool { toothDrag != nil || implantDrag != nil }

    // MARK: Trascinamento nel riquadro 3D

    /// Il piano di trascinamento in corso nel 3D: perpendicolare alla vista, per l'oggetto preso.
    private var volume3DDragAnchor: Vec3?

    /// Afferra un oggetto nel riquadro 3D, da un punto in pixel del drawable.
    ///
    /// # Perché nel 3D la profondità va scelta, e non ricavata
    ///
    /// In un riquadro 2D un clic identifica **un** punto: il piano di taglio fissa la terza
    /// coordinata. Nel 3D no — un pixel corrisponde a una retta, e su quella retta ci può stare
    /// mezzo cranio. Non esiste un modo geometrico di sapere quale profondità intendeva l'utente.
    ///
    /// La scelta è: si prende l'oggetto **più vicino all'osservatore** fra quelli il cui
    /// disegno passa sotto il puntatore, e da lì in poi lo si trascina sul piano che passa per
    /// esso, perpendicolare alla vista. È la regola dei programmi di modellazione, e ha il
    /// pregio di essere prevedibile: si sposta ciò che si vede davanti, e la profondità non
    /// cambia da sola. Per cambiarla si gira la scena e si trascina di nuovo.
    ///
    /// - Returns: `true` se qualcosa è stato afferrato. In quel caso il riquadro non deve
    ///   orbitare, altrimenti l'oggetto e la scena si muoverebbero insieme.
    func beginVolume3DDrag(atPixel point: CGPoint, pixelSize: CGSize) -> Bool {
        volume3DDragAnchor = nil
        guard workMode.isEditable, pixelSize.width > 1, pixelSize.height > 1 else { return false }

        let projector = ScreenProjector(
            camera: camera,
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height))

        // Tolleranza in millimetri: quanto vale un pugno di pixel a questo ingrandimento. Senza
        // conversione la presa sarebbe generosa da vicino e impossibile da lontano.
        let millimetresPerPixel = camera.halfHeightMM * 2 / Double(max(pixelSize.height, 1))
        let toleranceMM = millimetresPerPixel * 10

        /// Il punto sulla retta di vista, alla profondità dell'oggetto candidato.
        func pointer(at anchorMM: Vec3) -> Vec3 {
            projector.unproject(
                x: Double(point.x), y: Double(point.y), onPlaneThrough: anchorMM)
        }

        // Il più vicino all'osservatore fra quelli afferrabili: `depthMM` cresce allontanandosi.
        var best: (anchor: Vec3, depth: Double, grab: () -> Bool)?
        func consider(_ anchorMM: Vec3, _ grab: @escaping () -> Bool) {
            let depth = projector.project(anchorMM).depthMM
            guard depth.isFinite else { return }
            if best == nil || depth < best!.depth {
                best = (anchorMM, depth, grab)
            }
        }

        for tooth in teeth where tooth.isVisible {
            let probe = pointer(at: tooth.positionMM)
            guard ToothManipulation.grip(at: probe, of: tooth, toleranceMM: toleranceMM) != nil
            else { continue }
            consider(tooth.positionMM) { [weak self] in
                self?.beginToothDrag(at: probe, toleranceMM: toleranceMM) ?? false
            }
        }
        for implant in implants where implant.isVisible {
            let centre = implant.platformMM + implant.axis * (implant.model.lengthMM * 0.5)
            let probe = pointer(at: centre)
            guard ImplantManipulation.grip(at: probe, of: implant, toleranceMM: toleranceMM) != nil
            else { continue }
            consider(centre) { [weak self] in
                self?.beginImplantDrag(at: probe, toleranceMM: toleranceMM) ?? false
            }
        }

        guard let best, best.grab() else { return false }
        volume3DDragAnchor = best.anchor
        return true
    }

    /// Continua il trascinamento nel riquadro 3D.
    ///
    /// Il piano resta quello scelto alla presa: ricalcolarlo sulla posizione corrente
    /// dell'oggetto lo farebbe scivolare in profondità a ogni movimento, e l'impianto
    /// scapperebbe verso l'osservatore o dentro l'osso senza che nessuno l'abbia chiesto.
    func dragVolume3D(toPixel point: CGPoint, pixelSize: CGSize) {
        guard let anchor = volume3DDragAnchor, pixelSize.width > 1, pixelSize.height > 1
        else { return }
        let projector = ScreenProjector(
            camera: camera,
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height))
        let target = projector.unproject(
            x: Double(point.x), y: Double(point.y), onPlaneThrough: anchor)
        dragObject(toMM: target)
    }

    func endVolume3DDrag() {
        volume3DDragAnchor = nil
        endObjectDrag()
    }

    /// Propone e applica un asse migliore per l'impianto selezionato.
    ///
    /// Applica subito invece di chiedere conferma: la si annulla con ⌘Z come qualunque altra
    /// modifica, e vedere l'asse spostato è il modo più rapido di giudicare se la proposta ha
    /// senso. Una finestra di conferma chiederebbe di decidere prima di poter guardare.
    func suggestAxisForSelectedImplant() {
        guard let id = selectedImplantID,
            let index = implants.firstIndex(where: { $0.id == id })
        else { return }

        guard
            let suggestion = ImplantAxisAdvisor.suggest(
                for: implants[index], nerves: nerveCanals, volume: volume,
                thresholds: safetyThresholds)
        else {
            lastActionMessage =
                "Niente su cui decidere: senza canali tracciati e senza volume, un asse vale "
                + "l'altro."
            return
        }

        if suggestion.allCandidatesUnsafe {
            lastActionMessage =
                "Nessuna inclinazione entro venti gradi rispetta il margine dal canale. Il "
                + "problema non è l'asse: è il punto d'inserzione o l'impianto scelto."
            return
        }

        implants[index].axis = suggestion.axis
        recomputeSafety()
        recordUndo("Proponi asse")

        if abs(suggestion.nerveGainMM) < 0.05 {
            lastActionMessage = "L'asse attuale è già il migliore fra quelli esaminati."
        } else {
            lastActionMessage = String(
                format: "Asse proposto: %+.2f mm dal canale, inclinazione %.0f°.",
                suggestion.nerveGainMM, suggestion.angulationDegrees
            ).replacingOccurrences(of: ".", with: ",")
        }
    }

    /// Fa scorrere l'impianto selezionato lungo il proprio asse.
    ///
    /// È la regolazione più frequente — quanto la piattaforma sta sotto la cresta — e merita un
    /// comando esplicito: farla trascinando in diagonale costringerebbe a correggere subito dopo
    /// la posizione trasversale, cioè a lottare col gesto invece di usarlo.
    func slideSelectedImplant(byMM depth: Double) {
        guard let id = selectedImplantID,
            let index = implants.firstIndex(where: { $0.id == id })
        else { return }
        implants[index] = ImplantManipulation.slid(implants[index], byMM: depth)
        recomputeSafety()
        recordUndo("Profondità impianto")
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
        syncRegistry()
        recordUndo("Aggiungi impianto")
    }

    /// Cambia un impianto per identificatore, e registra un passo annullabile.
    ///
    /// Raggruppato: chi preme il passo del diametro sei volte di fila sta facendo **una**
    /// scelta, e annullarla deve costare una pressione sola.
    func updateImplant(id: UUID, _ transform: (inout ImplantPlacement) -> Void) {
        guard let index = implants.firstIndex(where: { $0.id == id }) else { return }
        transform(&implants[index])
        recomputeSafety()
        recordContinuousUndo("Modifica impianto")
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

    // MARK: - Denti protesici

    /// Posa un dente col numero corrente, centrando la **corona** sul punto cliccato.
    ///
    /// Si clicca guardando dove deve stare la superficie masticante, quindi il punto è
    /// l'occlusale e il centro della corona sta mezza altezza più in là verso l'apice. Posare il
    /// centro sul clic affonderebbe il dente di mezza corona dentro l'osso, che è l'errore che
    /// rende inutile la sagoma.
    func addProstheticTooth(at pointMM: Vec3) {
        guard var tooth = ProstheticTooth.standard(forToothNumber: pendingToothNumber) else {
            return
        }
        tooth.positionMM = pointMM + tooth.axisMM * (tooth.heightMM * 0.5)
        teeth.append(tooth)
        selectedToothID = tooth.id
        syncRegistry()
        recordUndo("Posa dente")
    }

    func updateTooth(id: UUID, _ transform: (inout ProstheticTooth) -> Void) {
        guard let index = teeth.firstIndex(where: { $0.id == id }) else { return }
        transform(&teeth[index])
        recordContinuousUndo("Modifica dente")
    }

    func updateSelectedTooth(_ transform: (inout ProstheticTooth) -> Void) {
        guard let id = selectedToothID else { return }
        updateTooth(id: id, transform)
    }

    func removeSelectedTooth() {
        guard let id = selectedToothID else { return }
        teeth.removeAll { $0.id == id }
        selectedToothID = nil
        syncRegistry()
        recordUndo("Cancella dente")
    }

    /// Vincolo protesico di un impianto, se sotto c'è un dente da servire.
    ///
    /// L'associazione è per **vicinanza**, non per un legame esplicito: chi pianifica non vuole
    /// dichiarare che l'impianto 46 sta sotto il dente 46, lo vuole vedere. Si prende il dente il
    /// cui centro occlusale è più vicino alla piattaforma, e solo se sta abbastanza vicino da
    /// poter essere quello — oltre una corona di distanza è un altro elemento, e accoppiarli
    /// produrrebbe un giudizio di divergenza fra oggetti che non hanno niente a che fare.
    func prostheticConstraint(for implant: ImplantPlacement) -> ProstheticConstraint? {
        var best: (tooth: ProstheticTooth, distance: Double)?
        for tooth in teeth {
            let distance = tooth.occlusalCentreMM.distance(to: implant.platformMM)
            guard distance.isFinite else { continue }
            // Una corona intera più mezza larghezza: abbastanza per accettare un impianto
            // profondo sotto il suo dente, troppo poco per raggiungere quello accanto.
            let reach = tooth.heightMM + tooth.widthMM * 0.5
            guard distance <= reach else { continue }
            if best == nil || distance < best!.distance {
                best = (tooth, distance)
            }
        }
        guard let found = best else { return nil }
        return ProstheticConstraint(
            tooth: found.tooth, implant: implant, thresholds: prostheticThresholds)
    }

    /// Il vincolo visto **dalla parte del dente**: l'impianto che questo dente riceve.
    ///
    /// Non è l'inverso banale di `prostheticConstraint(for:)`. Quella prende il dente più vicino
    /// a un impianto; questa deve prendere l'impianto più vicino a un dente, e le due scelte
    /// possono non coincidere quando due impianti stanno sotto la stessa corona. Si tiene
    /// l'accoppiamento **reciproco**: si guarda l'impianto più vicino e si accetta solo se
    /// quell'impianto sceglie a sua volta questo dente. Altrimenti la sovraimpressione
    /// mostrerebbe una linea di scostamento fra oggetti che l'ispettore non considera legati.
    func constraintForTooth(_ tooth: ProstheticTooth) -> ProstheticConstraint? {
        var best: (implant: ImplantPlacement, distance: Double)?
        for implant in implants {
            let distance = tooth.occlusalCentreMM.distance(to: implant.platformMM)
            guard distance.isFinite else { continue }
            if best == nil || distance < best!.distance {
                best = (implant, distance)
            }
        }
        guard let found = best,
            let reciprocal = prostheticConstraint(for: found.implant),
            reciprocal.occlusalCentreMM.distance(to: tooth.occlusalCentreMM) < 1e-9
        else { return nil }
        return reciprocal
    }

    /// Direzione mesio-distale nel punto del dente, cioè la tangente all'arcata.
    ///
    /// Si ricalcola invece di conservarla: è una funzione della curva e della posizione, e
    /// tenerne una copia significherebbe poterla avere in disaccordo con esse — spostando il
    /// dente lungo l'arcata la corona resterebbe orientata come nel punto di partenza.
    ///
    /// - Returns: `nil` senza una curva utilizzabile. La sagoma prende allora un orientamento
    ///   convenzionale, dichiarato in `ProstheticTooth.frame(mesialDirectionMM:)`.
    func mesialDirection(for tooth: ProstheticTooth) -> Vec3? {
        guard archCurve.isUsable else { return nil }
        return archTangent(near: tooth.positionMM)
    }

    /// Vincoli di ogni impianto che ne ha uno, per la relazione e per la revisione.
    var prostheticConstraints: [UUID: ProstheticConstraint] {
        var result: [UUID: ProstheticConstraint] = [:]
        for implant in implants {
            if let constraint = prostheticConstraint(for: implant) {
                result[implant.id] = constraint
            }
        }
        return result
    }

    /// Allinea l'asse dell'impianto a quello del dente che serve, tenendo ferma la piattaforma.
    ///
    /// È la correzione più richiesta dopo aver visto un'emergenza fuori posto, e farla a mano
    /// significa inseguire due gradi per volta su due viste.
    func alignSelectedImplantToTooth() {
        guard let id = selectedImplantID,
            let index = implants.firstIndex(where: { $0.id == id }),
            let constraint = prostheticConstraint(for: implants[index])
        else { return }
        implants[index].axis = constraint.toothAxisMM
        recomputeSafety()
        recordUndo("Allinea al dente")
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
        syncRegistry()
        // Raggruppato: tracciare un canale sono venti clic di seguito, e annullarli uno per uno
        // sarebbe venti pressioni per disfare un gesto solo.
        recordContinuousUndo("Traccia nervo")
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

    /// Come è stato avviato il programma: bundle `.app` oppure eseguibile nudo di SwiftPM.
    ///
    /// # Perché è informazione che deve stare a schermo
    ///
    /// Perché le due strade non danno la stessa applicazione, e la differenza si manifesta in
    /// modi che sembrano difetti. Senza bundle macOS non trova un `Info.plist`: il menu accanto
    /// alla mela prende il nome dal file eseguibile, le finestre di dialogo dei file si
    /// comportano in modo irregolare, e i tipi di documento non sono dichiarati. Chi vede un
    /// nome che non si aspetta finisce per chiedersi che cosa abbia compilato — ed è successo.
    ///
    /// Si legge da `bundleIdentifier`, che è `nil` esattamente per un eseguibile senza bundle.
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Riga d'identità della build: nome, versione, e come è stata avviata.
    static var buildIdentity: String {
        "\(AppIcon.displayName) \(appVersion) · \(isBundled ? "app" : "SwiftPM")"
    }

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
            openStudy(volume: volume, named: "Fantoccio sintetico", provenance: .synthetic)
            clearIdentity(examTitle: "Fantoccio sintetico")
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

                // L'identità si legge dalla **prima immagine della serie scelta**, non da un
                // file qualunque della cartella: una cartella può contenere più studi, e
                // prendere il primo file darebbe il paziente sbagliato quando la serie
                // ricostruita è di un altro.
                let identity = series.instances.first.flatMap { StudyIdentity.read(from: $0.url) }
                if identity == nil {
                    messages.append(
                        "Metadati del paziente non leggibili: l'esame si apre lo stesso, ma "
                        + "senza nome né data non si può archiviare in modo ritrovabile.")
                }

                return .loaded(
                    result.volume, messages, series.description ?? "Serie CBCT",
                    identity ?? StudyIdentity(), directory.path)
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
        case .loaded(let volume, let messages, let name, let identity, let sourcePath):
            openStudy(volume: volume, named: name, provenance: .imported)
            // Gli avvisi si impostano **dopo** `openStudy`, che azzera lo stato: altrimenti
            // sparirebbero proprio quando servono. Vale anche per l'identità.
            adoptIdentity(identity, sourcePath: sourcePath, volume: volume)
            loadIssues = messages
            loadingMessage = nil
            offerToArchive()
        }
    }

    private enum StudyOutcome: Sendable {
        case loaded(Volume, [String], String, StudyIdentity, String)
        case failed(String)
    }

    /// I volumi dello studio: quello letto e tutto ciò che se ne è derivato. Vedi `VolumeLibrary`.
    private(set) var library = VolumeLibrary()

    /// Nome del volume in uso, per il titolo della finestra e la barra laterale.
    var studyName: String { library.selected?.name ?? "Nessuno studio" }

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
        // Il fantoccio si riconosce dalla **provenienza** registrata, non dal nome: il nome si
        // può cambiare, e un fantoccio rinominato che si spaccia per uno studio vero sarebbe il
        // malinteso peggiore possibile su questi numeri.
        if case .synthetic = library.selectedRootProvenance {
            return "FANTOCCIO · \(volume.densityUnit.symbol)"
        }
        return volume.densityUnit.symbol
    }

    /// Passo di ricostruzione del volume: ogni quanto ci sono dati veri.
    ///
    /// Va scritto accanto allo spessore perché sono due numeri diversi che si confondono di
    /// continuo. Lo spessore dice quanto volume si somma in un'immagine; il passo dice ogni quanto
    /// ci sono campioni. Chiedere una fetta di 0,15 mm a un volume con passo 0,3 mm non produce
    /// più dettaglio: produce interpolazione, e chi valuta una corticale sottile deve poter
    /// distinguere le due cose senza aprire un pannello.
    var reconstructionStepLabel: String? {
        guard let geometry = volume?.geometry else { return nil }
        let s = geometry.spacingMM
        if geometry.isIsotropic() {
            return String(format: "%.2f", s.x).replacingOccurrences(of: ".", with: ",")
        }
        return String(format: "%.2f/%.2f/%.2f", s.x, s.y, s.z)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Accoglie un volume **derivato** — un ritaglio, un ricampionamento — accanto a quello da
    /// cui viene, e ci si sposta sopra.
    ///
    /// Accanto e non al posto: prima sostituiva, e l'originale non tornava più. Il difetto non si
    /// vedeva durante l'operazione ma dieci minuti dopo, quando serviva un ritaglio diverso e
    /// l'unica via era riaprire lo studio perdendo misure, curva e impianti.
    func adopt(volume: Volume, named name: String, operation: String = "Riformattazione") {
        guard let parent = library.selectedID else {
            openStudy(volume: volume, named: name, provenance: .imported)
            return
        }
        guard library.addDerived(volume, named: name, from: parent, operation: operation) != nil
        else { return }
        adopt(volume: volume)
    }

    /// Torna su un volume già presente nella raccolta.
    ///
    /// Ricostruisce texture e inquadrature perché la griglia è un'altra, ma **non** azzera
    /// annotazioni e impianti: sono in millimetri Patient, e i millimetri sono gli stessi in un
    /// ritaglio e nel volume da cui viene. Cancellarli sarebbe la scelta prudente e sbagliata —
    /// costringerebbe a rifare le misure ogni volta che si confronta un ritaglio con l'originale,
    /// che è precisamente ciò per cui la raccolta esiste.
    func selectVolume(_ id: UUID) {
        guard id != library.selectedID, library.select(id), let entry = library[id] else { return }
        adopt(volume: entry.volume, preservingPlan: true)
    }

    /// Toglie un volume derivato dalla raccolta.
    func removeVolume(_ id: UUID) {
        let wasSelected = id == library.selectedID
        guard library.remove(id) else { return }
        if wasSelected, let entry = library.selected {
            adopt(volume: entry.volume, preservingPlan: true)
        }
    }

    /// Accoglie un volume raddrizzato, **trasformando con esso tutto il piano**.
    ///
    /// È la parte che rende il riorientamento utilizzabile invece che distruttivo. Il volume
    /// nuovo sta in un riferimento nuovo: senza applicare la stessa rotazione a misure, impianti,
    /// nervi e curve, quelli resterebbero attaccati al vecchio e indicherebbero tessuto sbagliato
    /// — un impianto pianificato sul 36 finirebbe da qualche parte nell'osso, e nulla lo direbbe.
    func adoptReoriented(_ reoriented: Volume, plan: ReorientationPlan) {
        guard plan.rotation() != nil else { return }

        func moved(_ point: Vec3) -> Vec3 { plan.transformed(point) ?? point }
        /// Le direzioni ruotano senza traslare: un asse è un vettore, non un punto.
        func movedDirection(_ direction: Vec3) -> Vec3 {
            let origin = plan.pivotMM
            return moved(origin + direction) - moved(origin)
        }

        let movedAnnotations = annotations.map { annotation -> Annotation in
            var copy = annotation
            copy.transform(point: moved, vector: movedDirection)
            return copy
        }
        let movedImplants = implants.map { implant -> ImplantPlacement in
            var copy = implant
            copy.platformMM = moved(implant.platformMM)
            copy.axis = movedDirection(implant.axis).normalized ?? implant.axis
            return copy
        }
        let movedNerves = nerveCanals.map { canal -> NerveCanal in
            var copy = canal
            copy.nodes = canal.nodes.map { node in
                var moving = node
                moving.positionMM = moved(node.positionMM)
                return moving
            }
            return copy
        }
        let movedTeeth = teeth.map { tooth -> ProstheticTooth in
            var copy = tooth
            copy.positionMM = moved(tooth.positionMM)
            copy.axisMM = movedDirection(tooth.axisMM).normalized ?? tooth.axisMM
            return copy
        }
        let movedCurves = archCurves.mapValues { curve -> ArchCurve in
            ArchCurve(controlPointsMM: curve.controlPointsMM.map(moved), upAxis: curve.upAxis)
        }

        let parent = library.selectedID
        let name = library.uniqueName("Raddrizzato")
        if let parent,
            library.addDerived(reoriented, named: name, from: parent, operation: "Raddrizzamento")
                != nil
        {
            adopt(volume: reoriented, preservingPlan: true)
        } else {
            openStudy(volume: reoriented, named: name, provenance: .imported)
        }

        annotations = movedAnnotations
        implants = movedImplants
        teeth = movedTeeth
        nerveCanals = movedNerves
        archCurves = movedCurves
        crosshairMM = moved(crosshairMM)
        clampCrosshairToVolume()
        recomputeSafety()
        syncRegistry()
        if archCurve.isUsable { rebuildCrossSections() }
        recordUndo("Raddrizza il volume")
        lastActionMessage = "Volume raddrizzato; misure e impianti sono stati ruotati con esso."
    }

    /// Apre uno studio letto da disco o il fantoccio: svuota la raccolta e riparte.
    func openStudy(volume: Volume, named name: String, provenance: VolumeProvenance) {
        library.open(volume, named: name, provenance: provenance)
        adopt(volume: volume)
    }

    /// Adotta un volume: costruisce la texture, imposta mirino, finestra e inquadrature.
    func adopt(volume: Volume, preservingPlan: Bool = false) {
        // La geometria **precedente**, prima di sostituirla: serve a decidere se le inquadrature
        // restano valide. Una riduzione delle strie non cambia un voxel di posto, un ritaglio sì.
        let previousGeometry = self.volume?.geometry
        self.volume = volume

        if let device {
            do {
                self.volumeTexture = try VolumeTexture(volume: volume, device: device)
            } catch {
                self.loadIssues.append("Texture non creata: \(error)")
                self.volumeTexture = nil
            }
        }

        // Passando da un volume all'altro dello stesso studio il mirino **resta dov'è**, se il
        // nuovo volume lo contiene. I millimetri Patient sono gli stessi in un ritaglio e nel
        // volume da cui viene, quindi riportarlo al centro sarebbe buttare via un'informazione
        // valida: si sta confrontando *quel* punto, ed è l'unica ragione per cui si passa da un
        // volume all'altro. Se il punto è fuori — un ritaglio che non lo comprende — il centro è
        // l'unica scelta sensata che resti.
        //
        // Non serve riassegnarlo per riallineare i piani: `resetPlanes()`, poche righe sotto,
        // chiama già `syncPlanesToCrosshair()`.
        if !(preservingPlan && volume.geometry.containsPatientPoint(crosshairMM)) {
            crosshairMM = volume.geometry.centerMM
        }
        histogram = volume.rawHistogram(binCount: 256)

        // Finestra e inquadratura **si conservano** passando da un volume all'altro dello stesso
        // studio, e si ricalcolano solo aprendone uno nuovo.
        //
        // Si passa dall'originale alle strie ridotte per **confrontarli**, e un confronto in cui
        // cambiano anche finestra di densità e punto di vista non confronta niente: le due
        // immagini risulterebbero diverse per ragioni che non c'entrano con la correzione.
        if !preservingPlan {
            windowLevel = DensityWindow.automatic(from: volume)
            camera = VolumeCamera.fitted(to: volume.geometry)
        }

        // Con la stessa geometria le inquadrature restano valide, e conservarle è il punto:
        // confrontando due volumi si è ingranditi su un dente, e ripartire dall'inquadratura
        // completa costringerebbe a ritrovarlo a ogni scambio. Se invece la geometria è
        // cambiata — un ritaglio, un ricampionamento — l'inquadratura vecchia può cadere fuori
        // dal volume nuovo, e allora si riparte.
        if preservingPlan, previousGeometry == volume.geometry {
            syncPlanesToCrosshair()
        } else {
            resetPlanes()
        }

        if preservingPlan {
            // Tutto ciò che è **misurato sui voxel** va rifatto sul volume nuovo. Le annotazioni
            // restano dove sono — i millimetri Patient sono gli stessi — ma i loro valori no:
            // una ROI su un volume con le strie ridotte legge densità diverse, ed è esattamente
            // la ragione per cui si è passati all'altro volume. Lasciare i numeri vecchi
            // mostrerebbe la stessa cifra su due volumi diversi, cioè risponderebbe «nessuna
            // differenza» a chiunque avesse fatto la correzione per vedere la differenza.
            for annotation in annotations {
                recomputeStatistics(for: annotation)
            }
            recomputeSafety()
            return
        }

        resetArchCurves()
        annotations = []
        implants = []
        teeth = []
        nerveCanals = []
        roiStatistics = [:]
        selectedAnnotationID = nil
        selectedImplantID = nil
        selectedToothID = nil
        registry = PlanObjectRegistry()
        // La cronologia riparte: annullare fin dentro il caso precedente non ha senso, e su dati
        // clinici sarebbe pericoloso — riporterebbe nell'immagine di questo paziente gli impianti
        // pianificati per un altro.
        undoHistory.reset(to: planSnapshot)
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
        defer { rebuildDerivedContours() }
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

    /// Inclina il taglio: ruota i piani **perpendicolari** a quello mostrato nel riquadro.
    ///
    /// È la ricostruzione obliqua, e va distinta da `rotate(slot:byRadians:)`, che gira l'immagine
    /// lasciando la fetta dov'è. Qui cambia proprio come il volume viene tagliato: trascinando
    /// sull'assiale si inclinano coronale e sagittale, come ruotare le due linee del mirino.
    ///
    /// Serve perché l'anatomia non è allineata agli assi della macchina. Un ramo mandibolare,
    /// l'asse di un dente incluso, un condilo: nessuno di questi si guarda bene su un piano
    /// ortogonale, e senza obliquità l'unica alternativa è stimare a occhio su una fetta storta.
    ///
    /// Il piano del riquadro su cui si trascina **non** ruota, e non è una dimenticanza: è la
    /// superficie su cui si sta indicando l'angolo, e vederla girare sotto il dito mentre la si
    /// usa come riferimento renderebbe il gesto incontrollabile. Gli altri due ruotano insieme,
    /// dello stesso angolo, quindi restano perpendicolari fra loro.
    func tiltPlanes(perpendicularTo slot: ViewportSlot, byRadians angle: Double) {
        guard angle.isFinite, let reference = planes[slot] else { return }
        let axis = reference.normalMM
        for other in ViewportSlot.allCases
        where other != slot && other.anatomicalPlane != nil {
            guard let plane = planes[other] else { continue }
            planes[other] = plane.rotated(
                aboutAxis: axis, byRadians: angle, aboutMM: crosshairMM)
        }
    }

    /// Ruota **un solo** piano attorno a un asse, col mirino come perno.
    ///
    /// È la variante scollegata di `tiltPlanes`: si usa tenendo ⌥ su una maniglia del mirino,
    /// quando si vuole inclinare una linea lasciando l'altra dov'è. Il risultato sono due piani
    /// non più perpendicolari fra loro, e va detto che è una scelta con un costo: le sezioni
    /// trasversali ricavate da due piani obliqui fra loro non sono più ortogonali, quindi le
    /// misure prese su una non si compongono con quelle prese sull'altra. Serve per guardare,
    /// meno per misurare — da cui il modificatore, invece del gesto normale.
    func rotatePlane(_ slot: ViewportSlot, aboutAxis axis: Vec3, byRadians angle: Double) {
        guard angle.isFinite, let plane = planes[slot] else { return }
        planes[slot] = plane.rotated(aboutAxis: axis, byRadians: angle, aboutMM: crosshairMM)
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

    // MARK: - Strumenti, in ogni riquadro

    // # Il difetto che questa sezione chiude
    //
    // I punti a metà di una misura stavano nella vista, come stato locale del riquadro. Ne
    // seguiva che il righello funzionasse dove quello stato era stato scritto — assiale,
    // coronale, sagittale — e non altrove: sulla panorex e sulle sezioni trasversali nessuno
    // l'aveva messo, e all'uso si presentava come «gli strumenti funzionano solo in alcuni
    // riquadri». Non era una scelta di progetto, era un'assenza.
    //
    // Adesso i punti stanno qui, in millimetri Patient. Qualunque vista sappia convertire un
    // clic in millimetri può guidare lo stesso strumento, e una vista nuova ne eredita il
    // comportamento senza riscriverlo.

    /// Punti già posati dallo strumento attivo.
    var toolSession = ToolSession()

    /// Che cosa fare con lo strumento **e la variante** in mano.
    ///
    /// `Tool.hint` conosce lo strumento e non la variante, e con le varianti la stessa icona fa
    /// cose diverse: il righello a due punti si chiude da sé, la spezzata no e va detto. Una
    /// riga di istruzioni che descrive un altro gesto è peggio di nessuna riga — chi la segue
    /// conclude che il programma è rotto, e ha ragione a metà.
    var activeToolHint: String? {
        switch (activeTool, toolVariant) {
        case (.distance, "polyline"):
            return "Fai clic lungo il percorso. Doppio clic per chiudere, Esc per annullare."
        case (.distance, "perimeter"):
            return "Fai clic sui vertici. Doppio clic chiude il perimetro, Esc annulla."
        case (.angle, "lines"):
            return "Fai clic sui due estremi della prima retta, poi della seconda."
        case (.ellipseROI, "polygon"):
            return "Fai clic sui vertici del contorno. Doppio clic per chiuderlo."
        case (.text, "arrow"):
            return "Trascina da dove sta il testo a ciò che vuoi indicare."
        default:
            return activeTool.hint
        }
    }

    /// Forma che lo strumento attivo chiede, con la variante corrente.
    var activeToolShape: ToolShape {
        switch activeTool {
        case .navigate, .archCurve:
            return .singlePoint
        case .distance:
            return toolVariant == "polyline" || toolVariant == "perimeter"
                ? .openPolyline : .twoPoints
        case .angle:
            return toolVariant == "lines" ? .fourPoints : .threePoints
        case .ellipseROI:
            // La ROI poligonale è una variante dell'ellittica e non un pulsante in più: si sceglie
            // fra «una forma regolare» e «un contorno irregolare», che è la stessa decisione.
            return toolVariant == "polygon" ? .openPolyline : .twoPoints
        case .sphereROI:
            return .twoPoints
        case .text:
            // La freccia è testo che **indica**: due punti, coda e punta.
            return toolVariant == "arrow" ? .twoPoints : .singlePoint
        case .profile:
            return .twoPoints
        case .freehand:
            return .openPolyline
        case .implant, .nerve, .prostheticTooth:
            return .singlePoint
        }
    }

    /// Regola finestra e livello da un trascinamento col tasto destro.
    ///
    /// Convenzione radiologica diffusa: orizzontale regola l'ampiezza, verticale il livello.
    ///
    /// Sta nel modello e non in una vista perché **ogni** riquadro deve regolarla allo stesso
    /// modo. Stava in `ViewportGrid`, quindi esisteva solo lì: sulle sezioni trasversali e sulla
    /// panorex il tasto destro non faceva nulla, ed è proprio guardando una sezione che si
    /// aggiusta il contrasto per giudicare una corticale.
    func adjustWindowLevel(byDelta delta: CGSize) {
        var adjusted = windowLevel
        adjusted.width = max(1, adjusted.width + Double(delta.width) * 4)
        adjusted.level += Double(-delta.height) * 4
        windowLevel = adjusted
    }

    /// Aggiorna la lettura sotto il puntatore.
    ///
    /// Campionamento **nearest** sui dati di CPU, come prescrive il Contratto 3: il valore
    /// mostrato è un valore realmente presente nel volume, non una media fra vicini.
    func updateHover(atPatient pointMM: Vec3?) {
        guard let pointMM else {
            hoverPositionMM = nil
            hoverDensity = nil
            return
        }
        hoverPositionMM = pointMM
        hoverDensity = volume?.densityValue(atPatient: pointMM)
    }

    // MARK: - Scansione intraorale

    /// La superficie importata, nel proprio sistema di riferimento.
    private(set) var scan: Mesh?
    /// Trasformazione che la porta nello spazio Patient. Identità finché non si registra.
    private(set) var scanTransform: Transform3D = .identity
    /// Esito dell'ultima registrazione, con lo scarto.
    private(set) var scanRegistration: ScanRegistrationOutcome?
    /// Coppie di punti corrispondenti indicate a mano.
    var scanLandmarks: [LandmarkPair] = []
    var isScanVisible = true

    /// Contorno della scansione sulla **sezione trasversale selezionata**.
    ///
    /// Solo quella, e non tutte le visibili: la striscia ne mostra dieci, e intersecare
    /// centomila triangoli dieci volte a ogni scorrimento renderebbe lo scorrimento viscoso. La
    /// sezione selezionata è quella che si sta studiando, ed è lì che serve vedere se la
    /// scansione segue lo smalto.
    private(set) var selectedSectionContour: [[Vec3]] = []

    /// Contorno della scansione su ciascun riquadro, in millimetri Patient.
    ///
    /// Si ricalcola quando i piani cambiano, **non** a ogni ridisegno: intersecare centomila
    /// triangoli è lavoro da qualche millisecondo, trascurabile una volta per movimento del
    /// mirino e insostenibile sessanta volte al secondo.
    private(set) var scanContours: [ViewportSlot: [[Vec3]]] = [:]

    /// Importa una superficie e la mostra dov'è, senza registrarla.
    ///
    /// Senza registrazione la scansione sta dove la mette il suo file, che non ha nulla a che
    /// vedere con lo spazio del paziente: comparirà lontana dall'anatomia, ed è giusto che sia
    /// evidente. Fingere un allineamento plausibile sarebbe peggio — chi lo vede quasi giusto
    /// smette di registrare.
    func adoptScan(_ mesh: Mesh) {
        scan = mesh
        scanTransform = .identity
        scanRegistration = nil
        scanLandmarks = []
        rebuildScanContours()
        lastActionMessage =
            "Scansione «\(mesh.name)» importata: \(mesh.triangles.count) triangoli. "
            + "Va registrata prima di poterla usare."
    }

    func removeScan() {
        scan = nil
        scanTransform = .identity
        scanRegistration = nil
        scanLandmarks = []
        scanContours = [:]
    }

    /// Registra la scansione sul volume, usando le coppie di punti indicate.
    ///
    /// - Parameter regionMM: la zona in cui estrarre la superficie ossea di riferimento. Va
    ///   scelta sui denti **sani e senza metallo**: attorno a una corona la superficie estratta
    ///   non è quella del dente, è quella di un artefatto, e la registrazione risulterebbe
    ///   precisa rispetto a qualcosa che non esiste.
    func registerScan(inRegionMM regionMM: (min: Vec3, max: Vec3), thresholdGV: Double) {
        guard let scan, let volume else { return }
        guard scanLandmarks.count >= 3 else {
            lastActionMessage = "Servono almeno tre coppie di punti corrispondenti."
            return
        }

        let targets = VolumeSurface.points(
            in: volume,
            extraction: SurfaceExtraction(
                minMM: regionMM.min, maxMM: regionMM.max, thresholdGV: thresholdGV))
        guard !targets.isEmpty else {
            lastActionMessage =
                "Nessuna superficie trovata in quella zona con questa soglia. Abbassala, oppure "
                + "scegli una zona che contenga dello smalto."
            return
        }

        do {
            let outcome = try ScanRegistration.register(
                scan: scan, landmarks: scanLandmarks, targetPoints: targets)
            scanTransform = outcome.transform
            scanRegistration = outcome
            rebuildScanContours()
            lastActionMessage = String(
                format: "Registrata: scarto %.2f mm su %d punti — %@",
                outcome.surfaceRMSMM, outcome.surfacePointCount,
                outcome.quality.localizedName)
        } catch {
            lastActionMessage =
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Ricalcola **ogni** contorno derivato da una superficie: scansione e segmentazione.
    ///
    /// Un solo punto perché le due cose dipendono dagli stessi piani e cambiano insieme. Con due
    /// richiami separati sparsi per il modello sarebbe bastato dimenticarne uno perché la
    /// segmentazione restasse ferma su una fetta mentre l'immagine scorre — e un contorno fermo
    /// sull'immagine sbagliata è peggio di nessun contorno.
    func rebuildDerivedContours() {
        rebuildScanContours()
        rebuildSegmentationContours()
    }

    /// Ricalcola il contorno della scansione su ogni riquadro ortogonale.
    func rebuildScanContours() {
        guard let scan, isScanVisible else {
            scanContours = [:]
            selectedSectionContour = []
            return
        }
        let placed = scan.transformed(by: scanTransform)
        var contours: [ViewportSlot: [[Vec3]]] = [:]
        for (slot, plane) in planes where slot.anatomicalPlane != nil {
            let contour = MeshSlicer.contour(
                of: placed, planeOriginMM: plane.centerMM, planeNormalMM: plane.normalMM,
                toleranceMM: 1e-4)
            if !contour.loops.isEmpty { contours[slot] = contour.loops }
        }
        scanContours = contours

        if let section = crossSectionBrowser.selectedSection {
            selectedSectionContour = MeshSlicer.contour(
                of: placed,
                planeOriginMM: section.plane.centerMM,
                planeNormalMM: section.plane.normalMM,
                toleranceMM: 1e-4
            ).loops
        } else {
            selectedSectionContour = []
        }
    }

    // MARK: - Archivio dei pazienti

    // # Che cosa conserva, e che cosa no
    //
    // Il volume ricostruito, i metadati del paziente e dell'esame, e il piano. **Non** i file
    // DICOM originali: rileggerli sarebbe cinquecento aperture a ogni riapertura, e conservarli
    // raddoppierebbe lo spazio. Chi deve consegnarli a un laboratorio si tiene la cartella, e
    // l'archivio ne registra il percorso proprio per poterla ritrovare.
    //
    // # Dati di paziente su disco
    //
    // Questo è il punto in cui il programma smette di essere solo un visore. Il fascicolo sta
    // in `~/Libreria/Application Support/3DMED/Archivio`, in chiaro, sotto la protezione del
    // disco del Mac e di nient'altro. È una scelta dell'utente, e l'interfaccia gliela mette
    // davanti scritta invece di lasciargliela scoprire.

    /// Che cosa fare quando si apre un esame nuovo.
    enum ArchivePolicy: String, CaseIterable, Hashable, Sendable, Identifiable {
        /// Chiede ogni volta. È il valore predefinito: archiviare è una decisione su dei dati
        /// di una persona, e prenderla al posto dell'utente la prima volta sarebbe sbagliato in
        /// tutt'e due i versi possibili.
        case ask
        case always
        case never

        var id: String { rawValue }

        var localizedName: String {
            switch self {
            case .ask: return "Chiedi ogni volta"
            case .always: return "Archivia sempre"
            case .never: return "Non archiviare mai"
            }
        }
    }

    private static let archivePolicyKey = "archivePolicy"

    var archivePolicy: ArchivePolicy {
        get {
            ArchivePolicy(
                rawValue: UserDefaults.standard.string(forKey: Self.archivePolicyKey) ?? "")
                ?? .ask
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: Self.archivePolicyKey) }
    }

    /// La cartella dell'archivio, creata alla prima archiviazione e non prima.
    static var archiveRootURL: URL {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        return support.appendingPathComponent(AppIcon.displayName)
            .appendingPathComponent("Archivio")
    }

    private var archive: PatientArchive { PatientArchive(rootURL: Self.archiveRootURL) }

    /// Il paziente e l'esame aperti adesso, come li scrive il file.
    private(set) var patient = PatientIdentity()
    private(set) var exam = ExamMetadata()
    /// La cartella da cui l'esame è stato importato.
    private(set) var examSourcePath = ""
    /// L'identificatore della voce d'archivio, se l'esame aperto viene dall'archivio o vi è
    /// stato messo. Serve a riarchiviare sulla stessa voce invece di crearne una nuova.
    private(set) var archivedExamID: UUID?

    /// Vero quando c'è qualcosa da mostrare nel pannello dei metadati.
    var hasExamMetadata: Bool { !patient.name.isEmpty || !exam.studyDate.isEmpty || archivedExamID != nil }

    /// Elenco dei pazienti in archivio, ricaricato su richiesta.
    private(set) var archivedPatients: [ArchivedPatient] = []
    private(set) var archiveBytes = 0
    private(set) var archiveMessage: String?
    private(set) var isArchiving = false
    var isShowingArchive = false
    /// La domanda «lo archivio?» dopo l'apertura di un esame nuovo.
    var isAskingToArchive = false
    var archiveSearchText = ""

    /// Prende i metadati dopo il caricamento di uno studio.
    func adoptIdentity(_ identity: StudyIdentity, sourcePath: String, volume: Volume) {
        patient = PatientIdentity(identity)
        var metadata = ExamMetadata(identity)
        metadata.adopt(geometry: volume.geometry)
        exam = metadata
        examSourcePath = sourcePath
        archivedExamID = nil
    }

    /// Azzera i metadati: il fantoccio non è di nessuno.
    func clearIdentity(examTitle: String) {
        patient = PatientIdentity()
        exam = ExamMetadata(seriesDescription: examTitle)
        if let volume { exam.adopt(geometry: volume.geometry) }
        examSourcePath = ""
        archivedExamID = nil
    }

    /// Decide che cosa fare dopo aver aperto un esame nuovo.
    ///
    /// Non chiede per un esame che **viene** dall'archivio — sarebbe chiedere di archiviare
    /// qualcosa che è già archiviato — né per il fantoccio, che non è di nessuno.
    func offerToArchive() {
        guard archivedExamID == nil, !isPhantomOpen else { return }
        switch archivePolicy {
        case .ask: isAskingToArchive = true
        case .always: Task { await archiveCurrentExam() }
        case .never: break
        }
    }

    /// Mette in archivio l'esame aperto, col piano corrente.
    func archiveCurrentExam(includingPlan: Bool = true) async {
        guard let volume, !isArchiving else { return }
        isArchiving = true
        archiveMessage = nil

        let plan: Data? = includingPlan ? try? ProjectDocument(from: self).encoded() : nil
        let store = archive
        let identity = patient
        let metadata = exam
        let source = examSourcePath

        let outcome = await Task.detached(priority: .userInitiated) { () -> Result<ArchiveEntry, Error> in
            do {
                return .success(
                    try store.store(
                        volume: volume, patient: identity, exam: metadata,
                        sourcePath: source, plan: plan))
            } catch {
                return .failure(error)
            }
        }.value

        isArchiving = false
        switch outcome {
        case .success(let entry):
            archivedExamID = entry.id
            let name = entry.patient.isAnonymous
                ? "Esame anonimo" : entry.patient.displayName
            lastActionMessage = "Archiviato: \(name) — \(entry.summary)"
            await reloadArchive()
        case .failure(let error):
            archiveMessage = error.localizedDescription
            loadIssues.append("Archiviazione non riuscita: \(error.localizedDescription)")
        }
    }

    /// Rilegge l'indice dell'archivio.
    func reloadArchive() async {
        let store = archive
        let outcome = await Task.detached(priority: .userInitiated) {
            () -> (patients: [ArchivedPatient], bytes: Int, message: String?) in
            do {
                let index = try store.loadIndex()
                return (store.patients(in: index), store.totalBytes(in: index), nil)
            } catch {
                return ([], 0, error.localizedDescription)
            }
        }.value
        archivedPatients = outcome.patients
        archiveBytes = outcome.bytes
        archiveMessage = outcome.message
    }

    /// Riapre un esame dall'archivio, col piano che ci era stato salvato.
    func openArchived(_ entry: ArchiveEntry) async {
        guard !isArchiving else { return }
        loadingMessage = "Apertura dall'archivio…"
        let store = archive
        let id = entry.id

        let outcome = await Task.detached(priority: .userInitiated) {
            () -> Result<(Volume, Data?), Error> in
            do { return .success((try store.loadVolume(id: id), store.loadPlan(id: id))) }
            catch { return .failure(error) }
        }.value

        loadingMessage = nil
        switch outcome {
        case .failure(let error):
            loadIssues = [error.localizedDescription]
        case .success(let (volume, plan)):
            openStudy(
                volume: volume,
                named: entry.exam.displayTitle,
                provenance: .imported)
            patient = entry.patient
            exam = entry.exam
            examSourcePath = entry.sourcePath
            archivedExamID = entry.id

            // Il piano **dopo** `openStudy`, che azzera tutto: nell'ordine inverso sparirebbe.
            if let plan, let document = try? ProjectDocument.decoded(from: plan) {
                let warnings = document.apply(to: self)
                if !warnings.isEmpty { loadIssues = warnings }
            }
            isShowingArchive = false
        }
    }

    /// Toglie un esame dall'archivio.
    func removeArchived(_ entry: ArchiveEntry) async {
        let store = archive
        let id = entry.id
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try store.remove(id: id); return nil } catch { return error.localizedDescription }
        }.value
        if let error {
            archiveMessage = error
        } else {
            if archivedExamID == id { archivedExamID = nil }
            await reloadArchive()
        }
    }

    /// Aggiorna la nota di un esame archiviato.
    func setArchiveNote(_ note: String, for entry: ArchiveEntry) async {
        let store = archive
        let id = entry.id
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do { try store.setNote(note, for: id); return nil } catch { return error.localizedDescription }
        }.value
        if let error { archiveMessage = error } else { await reloadArchive() }
    }

    /// Ricostruisce l'indice dalle cartelle degli esami.
    func rebuildArchiveIndex() async {
        let store = archive
        let error = await Task.detached(priority: .userInitiated) { () -> String? in
            do { _ = try store.rebuildIndex(); return nil } catch { return error.localizedDescription }
        }.value
        if let error { archiveMessage = error } else { await reloadArchive() }
        lastActionMessage = "Indice dell'archivio ricostruito dalle cartelle."
    }

    /// I pazienti filtrati dalla casella di ricerca.
    var filteredArchivedPatients: [ArchivedPatient] {
        archive.search(archiveSearchText, in: archivedPatients)
    }

    // MARK: - Segmentazione

    // # Perché la segmentazione compare come contorno e non come voxel colorati
    //
    // La via ovvia è dipingere i voxel selezionati sopra le fette, e richiede una texture di
    // maschera dentro lo shader MPR. È la via giusta a lungo termine ed è anche l'unica che qui
    // non si può verificare in alcun modo. Il contorno invece arriva sullo schermo per una
    // strada che nel programma funziona già — `MeshSlicer`, la stessa della scansione
    // intraorale — e dice le stesse cose: dove passa il confine, se ha buchi, se ha isole. Sopra
    // l'anatomia è per giunta più leggibile, perché non la copre.

    /// Identificatore fisso della segmentazione nell'elenco degli oggetti.
    ///
    /// Fisso e non generato: la segmentazione è **una**, si rifà cambiando la soglia, e un
    /// identificatore nuovo a ogni esecuzione lascerebbe nell'elenco una riga morta per ogni
    /// tentativo — con visibilità e colore scelti dall'utente che si perdono a ogni giro.
    static let segmentationObjectID = UUID(
        uuidString: "5E6DE7A0-0000-4000-8000-000000000001") ?? UUID()

    /// La maschera corrente, se una segmentazione è stata eseguita.
    private(set) var segmentationMask: VolumeMask?
    /// La superficie estratta dalla maschera.
    private(set) var segmentationMesh: Mesh?
    private(set) var segmentationStatistics: MaskStatistics?
    private(set) var segmentationContours: [ViewportSlot: [[Vec3]]] = [:]
    private(set) var segmentationSectionContour: [[Vec3]] = []
    private(set) var isSegmenting = false
    private(set) var segmentationMessage: String?

    var isShowingSegmentation = false

    var isSegmentationVisible = true {
        didSet { rebuildSegmentationContours() }
    }

    /// Finestra di densità della soglia, in unità del volume corrente.
    var segmentationLowerGV: Double = 1000
    var segmentationUpperGV: Double = 3500
    /// Tenere solo il componente più grande. Predefinito acceso: su una CBCT la soglia dell'osso
    /// prende anche la colonna, il mento e ogni scheggia di rumore sopra soglia, e il risultato
    /// utile è quasi sempre il pezzo più grande.
    var segmentationKeepsLargest = true
    /// Passo di campionamento della superficie. Più grosso costa meno e perde dettaglio.
    var segmentationSpacingMM: Double = 0.6

    /// Soglia, componente più grande, superficie. In quest'ordine e fuori dal main actor.
    ///
    /// Non è lavoro da fare mentre l'interfaccia aspetta: su un volume da 512³ la sola soglia
    /// tocca centotrenta milioni di voxel, e marching cubes ne campiona altrettanti. Lasciarlo
    /// sul main actor bloccherebbe la finestra per secondi senza nemmeno un cursore che gira.
    func runSegmentation() async {
        guard let volume, !isSegmenting else { return }
        isSegmenting = true
        segmentationMessage = nil

        let lower = Swift.min(segmentationLowerGV, segmentationUpperGV)
        let upper = Swift.max(segmentationLowerGV, segmentationUpperGV)
        let largestOnly = segmentationKeepsLargest
        let spacing = segmentationSpacingMM

        struct Outcome: Sendable {
            var mask: VolumeMask?
            var mesh: Mesh?
            var statistics: MaskStatistics?
            var message: String?
        }

        let outcome = await Task.detached(priority: .userInitiated) { () -> Outcome in
            do {
                var mask = try ThresholdSegmentation.segment(
                    volume, densityRange: lower...upper, label: 1, within: nil)
                if largestOnly {
                    mask = try ConnectedComponents.keepingLargest(mask, count: 1)
                }
                guard !MaskSurface.isEmpty(mask, label: 1) else {
                    return Outcome(message: "Nessun voxel in questa finestra di densità.")
                }
                let statistics = try MaskAnalysis.statistics(of: volume, within: mask, label: 1)
                guard
                    let mesh = MaskSurface.mesh(
                        of: mask, label: 1, spacingMM: spacing, name: "Segmentazione")
                else {
                    // I due «no» di `MaskSurface` sono diversi, e qui si è già escluso il vuoto:
                    // resta il rifiuto per dimensione della griglia.
                    return Outcome(
                        mask: mask, statistics: statistics,
                        message: "Regione troppo estesa per questo passo. Aumenta il passo di "
                            + "campionamento.")
                }
                return Outcome(mask: mask, mesh: mesh, statistics: statistics)
            } catch {
                return Outcome(message: String(describing: error))
            }
        }.value

        segmentationMask = outcome.mask
        segmentationMesh = outcome.mesh
        segmentationStatistics = outcome.statistics
        segmentationMessage = outcome.message
        isSegmenting = false
        rebuildSegmentationContours()
        syncRegistry()
    }

    func clearSegmentation() {
        segmentationMask = nil
        segmentationMesh = nil
        segmentationStatistics = nil
        segmentationMessage = nil
        segmentationContours = [:]
        segmentationSectionContour = []
        syncRegistry()
    }

    /// Ricalcola i contorni della segmentazione sui riquadri e sulla sezione selezionata.
    ///
    /// Stessa struttura di `rebuildScanContours`, e per le stesse ragioni — inclusa quella per
    /// cui la sezione trasversale si calcola solo per quella **selezionata**.
    func rebuildSegmentationContours() {
        guard let mesh = segmentationMesh, isSegmentationVisible else {
            segmentationContours = [:]
            segmentationSectionContour = []
            return
        }
        var contours: [ViewportSlot: [[Vec3]]] = [:]
        for (slot, plane) in planes where slot.anatomicalPlane != nil {
            let contour = MeshSlicer.contour(
                of: mesh, planeOriginMM: plane.centerMM, planeNormalMM: plane.normalMM,
                toleranceMM: 1e-4)
            if !contour.loops.isEmpty { contours[slot] = contour.loops }
        }
        segmentationContours = contours

        if let section = crossSectionBrowser.selectedSection {
            segmentationSectionContour = MeshSlicer.contour(
                of: mesh,
                planeOriginMM: section.plane.centerMM,
                planeNormalMM: section.plane.normalMM,
                toleranceMM: 1e-4
            ).loops
        } else {
            segmentationSectionContour = []
        }
    }

    // MARK: - Dima chirurgica

    /// L'ultima dima costruita, con le sue verifiche.
    private(set) var guideResult: GuideResult?
    private(set) var isBuildingGuide = false
    var isShowingGuide = false

    /// Costruisce la dima sugli impianti pianificati.
    ///
    /// # Perché pretende una scansione registrata
    ///
    /// Perché una dima appoggia sui **denti**, e sa dove sono solo se la scansione è allineata
    /// alla CBCT. Costruirla su una scansione non registrata darebbe un pezzo geometricamente
    /// corretto e riferito a uno spazio che non è quello del paziente: entrerebbe in bocca in
    /// nessun modo, e non ci sarebbe modo di accorgersene guardandolo.
    ///
    /// Su una registrazione **scarsa** si costruisce, ma il messaggio lo dice: mezzo millimetro
    /// di disallineamento della scansione è mezzo millimetro che l'impianto sbaglia, e la dima
    /// non lo può recuperare.
    func buildGuide(
        footprintRadiusMM: Double,
        sleeveInnerDiameterMM: Double,
        sleeveOuterDiameterMM: Double,
        sleeveHeightMM: Double,
        offsetToPlatformMM: Double,
        configuration: GuideConfiguration
    ) async {
        guard let scan else {
            lastActionMessage = "Serve una scansione intraorale: la dima appoggia sui denti."
            return
        }
        guard scanRegistration != nil else {
            lastActionMessage =
                "La scansione non è registrata. Una dima costruita su una scansione non "
                + "allineata è riferita a uno spazio che non è quello del paziente."
            return
        }
        let visible = implants.filter(\.isVisible)
        guard !visible.isEmpty else {
            lastActionMessage = "Nessun impianto da guidare."
            return
        }

        isBuildingGuide = true
        defer { isBuildingGuide = false }

        // La scansione **registrata**: è in questo spazio che stanno gli impianti.
        let placed = scan.transformed(by: scanTransform)
        let footprint = GuideFootprint.aroundImplants(
            scan: placed, implants: visible, radiusMM: footprintRadiusMM)
        guard footprint.includedCount > 0 else {
            lastActionMessage =
                "Nessun vertice della scansione entro \(Int(footprintRadiusMM)) mm dagli "
                + "impianti. Allarga l'appoggio, o la scansione non copre i siti."
            return
        }

        let sleeves = visible.map {
            GuideSleeve.forImplant(
                $0,
                innerDiameterMM: sleeveInnerDiameterMM,
                outerDiameterMM: sleeveOuterDiameterMM,
                heightMM: sleeveHeightMM,
                offsetToPlatformMM: offsetToPlatformMM)
        }

        let mask = footprint.mask
        let outcome = await Task.detached(priority: .userInitiated) {
            Result {
                try GuideBuilder.build(
                    scan: placed, footprint: mask, sleeves: sleeves,
                    configuration: configuration)
            }
        }.value

        switch outcome {
        case .success(let result):
            guideResult = result
            let quality = scanRegistration?.quality ?? .poor
            let caveat = quality == .good
                ? ""
                : " Attenzione: la registrazione è «\(quality.localizedName.lowercased())», e "
                    + "il disallineamento della scansione la dima non lo recupera."
            lastActionMessage = String(
                format: "Dima costruita: %.1f cm³, %d boccole.%@",
                result.validation.volumeMM3 / 1000, result.sleeves.count, caveat)
        case .failure(let error):
            guideResult = nil
            lastActionMessage =
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Ciò che non torna nel piano, sempre disponibile senza dover esportare.
    ///
    /// Calcolata su richiesta e non memorizzata: dipende da tutto — impianti, canali, misure,
    /// dima — e tenerne una copia significherebbe doverla invalidare da dieci punti diversi.
    /// Dimenticarne uno darebbe una lista vecchia, che è peggio di nessuna lista.
    var planIssues: [PlanIssue] {
        PlanReview.issues(in: reportInput())
    }

    /// I dati del piano nella forma che relazione e revisione si aspettano.
    func reportInput() -> PlanReportInput {
        PlanReportInput(
            studyName: library.selected?.name ?? "Studio",
            volumeProvenance: library.selected.map { entry in
                library.ancestry(of: entry.id).map(\.summary)
            } ?? [],
            densityUnitSymbol: densityUnit.symbol,
            annotations: annotations,
            roiStatistics: roiStatistics,
            implants: implants,
            safetyReports: safetyReports,
            prostheticConstraints: prostheticConstraints,
            prostheticToothCount: teeth.count,
            registrationRMSMM: scanRegistration?.surfaceRMSMM,
            registrationQuality: scanRegistration?.quality.localizedName,
            guideVolumeMM3: guideResult?.validation.volumeMM3,
            guideIsPrintable: guideResult?.validation.isPrintable,
            guideWarnings: guideResult?.validation.warnings ?? [])
    }

    /// Compone la relazione e la salva, poi la apre.
    ///
    /// HTML e non PDF: il PDF si ottiene stampando dal browser, che è un passaggio del sistema.
    /// Generarlo qui vorrebbe dire scrivere un impaginatore e non poterlo verificare — mentre
    /// del testo si prova che ogni avvertimento ci sia.
    func exportReport() {
        let input = reportInput()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "relazione.html"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try PlanReport.html(input).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(url)
            lastActionMessage = "Relazione salvata in \(url.lastPathComponent)."
        } catch {
            lastActionMessage = "Relazione non salvata: \(error.localizedDescription)"
        }
    }

    /// Esporta la dima in STL.
    func exportGuide() {
        guard let result = guideResult else { return }
        do {
            let data = try GuideExport.stl(result)
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "dima.stl"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url)
            lastActionMessage = "Dima esportata in \(url.lastPathComponent)."
        } catch {
            lastActionMessage =
                (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
    }

    /// Se il volume aperto è il fantoccio sintetico di riferimento.
    ///
    /// Serve alla verifica di accuratezza, che confronta con grandezze note: su una CBCT di un
    /// paziente quelle grandezze non esistono, e il confronto sarebbe privo di senso. Dirlo prima
    /// evita di far leggere numeri che non significano nulla.
    var isPhantomOpen: Bool {
        if case .synthetic = library.selectedRootProvenance { return true }
        return false
    }

    /// Finestra della verifica di accuratezza. Vedi `VerificationSheet`.
    var isShowingVerification = false
    /// Finestra della registrazione della scansione. Vedi `ScanRegistrationSheet`.
    var isShowingScanRegistration = false

    /// Come si sta misurando adesso: voxel, spessore attraversato, natura della vista.
    ///
    /// Vedi il Contratto 5. Si fotografa al momento della posa e viaggia con l'annotazione: chi
    /// assottiglia lo slab dopo aver misurato non rende retroattivamente attendibile una misura
    /// presa su venti millimetri di proiezione.
    ///
    /// - Parameter curved: vero per la panorex, dove il punto sta su una superficie ricostruita.
    func acquisitionContext(curved: Bool = false) -> AcquisitionContext? {
        guard let geometry = volume?.geometry else { return nil }
        let isDerived: Bool
        if case .derived = library.selectedRootProvenance { isDerived = true } else { isDerived = false }

        return AcquisitionContext(
            voxelSpacingMM: geometry.spacingMM,
            slabThicknessMM: slabThicknessMM,
            // Solo le proiezioni lasciano indeterminata la profondità di ciò che si vede: una
            // media viene da tutto lo spessore, e il suo centro è dove sembra.
            projectsThroughSlab: projection == .maximum || projection == .minimum,
            isCurvedSurface: curved,
            isDerivedVolume: isDerived)
    }

    /// Un clic su un riquadro qualsiasi, già convertito in millimetri Patient.
    ///
    /// - Parameters:
    ///   - pointMM: il punto cliccato, in millimetri Patient.
    ///   - anchor: il piano del riquadro, quando ne ha uno. Serve a orientare le ellissi e a
    ///     decidere su quali fette la misura resterà visibile. Un riquadro che non ha un piano
    ///     piatto — la panorex, che è una superficie curva — passa `nil`, e la misura vale
    ///     ovunque invece di legarsi a un piano che non esiste.
    func applyToolClick(at pointMM: Vec3, anchor: ToolAnchor? = nil) {
        toolSession.prepare(for: activeToolShape)
        // La panorex passa `nil` come ancoraggio perché non ha un piano: è la stessa condizione
        // che identifica una misura presa su superficie curva.
        let acquisition = acquisitionContext(curved: anchor == nil && activeTool != .navigate)

        switch activeTool {
        case .navigate, .archCurve:
            // Anche con lo strumento arcata in mano, un clic fuori dall'assiale sposta il mirino:
            // è così che si sceglie la fetta su cui posare i punti, guardando la cresta di
            // profilo. La posa dei punti la gestisce il riquadro assiale, prima di arrivare qui.
            moveCrosshair(to: pointMM)

        case .distance:
            guard let points = toolSession.add(pointMM, anchor: anchor) else { return }
            switch toolVariant {
            case "polyline", "perimeter":
                addAnnotation(makePolyline(points, closed: toolVariant == "perimeter"))
            default:
                addAnnotation(
                    .distance(
                        DistanceMeasurement(
                            metadata: AnnotationMetadata(
                                colorHex: "#32B8C6",
                                referencePlane: toolSession.anchor?.planeReference,
                                acquisition: acquisition),
                            startMM: points[0], endMM: points[1])))
            }

        case .angle:
            guard let points = toolSession.add(pointMM, anchor: anchor) else { return }
            let metadata = AnnotationMetadata(
                colorHex: "#FFD426", referencePlane: toolSession.anchor?.planeReference,
                acquisition: acquisition)
            if points.count == 4 {
                addAnnotation(
                    .lineAngle(
                        LineAngleMeasurement(
                            metadata: metadata,
                            firstStartMM: points[0], firstEndMM: points[1],
                            secondStartMM: points[2], secondEndMM: points[3])))
            } else {
                addAnnotation(
                    .angle(
                        AngleMeasurement(
                            metadata: metadata,
                            vertexMM: points[0],
                            firstArmMM: points[1], secondArmMM: points[2])))
            }

        case .ellipseROI:
            guard toolVariant != "polygon" else {
                // Poligonale: si accumula e si chiude col doppio clic, come ogni contorno.
                toolSession.add(pointMM, anchor: anchor)
                return
            }
            guard let points = toolSession.add(pointMM, anchor: anchor) else { return }
            addAnnotation(.ellipseROI(makeEllipse(from: points[0], to: points[1])))

        case .sphereROI:
            guard let points = toolSession.add(pointMM, anchor: anchor) else { return }
            let radius = points[0].distance(to: points[1])
            guard radius > 0 else { return }
            addAnnotation(
                .sphereROI(
                    SphereROI(
                        metadata: AnnotationMetadata(
                            colorHex: "#FFD426", acquisition: acquisition),
                        centerMM: points[0], radiusMM: radius)))

        case .text:
            guard let points = toolSession.add(pointMM, anchor: anchor) else { return }
            let noteMetadata = AnnotationMetadata(
                referencePlane: toolSession.anchor?.planeReference, acquisition: acquisition)
            if toolVariant == "arrow" {
                // Primo clic la coda, secondo la punta: si parte da dove c'è spazio per il testo e
                // si finisce su ciò che si vuole indicare, che è l'ordine in cui si pensa.
                addAnnotation(
                    .arrow(
                        ArrowNote(
                            metadata: noteMetadata,
                            tipMM: points[1], tailMM: points[0], text: "Nota")))
            } else {
                addAnnotation(
                    .text(TextNote(metadata: noteMetadata, anchorMM: points[0], text: "Nota")))
            }

        case .profile:
            guard let points = toolSession.add(pointMM, anchor: anchor) else { return }
            addAnnotation(
                .profileLine(
                    ProfileLine(
                        metadata: AnnotationMetadata(
                            colorHex: "#C77DFF",
                            referencePlane: toolSession.anchor?.planeReference,
                            acquisition: acquisition),
                        startMM: points[0], endMM: points[1])))

        case .freehand:
            // Nulla: la mano libera si disegna **trascinando**, e il punto della pressione lo ha
            // già posato `appendFreehandPoint`. Aggiungerne uno anche qui significherebbe che un
            // clic senza movimento lascia un tracciato di due punti coincidenti, cioè un oggetto
            // lungo zero millimetri che compare nell'elenco e non si vede da nessuna parte.
            break

        case .prostheticTooth:
            toolSession.cancel()
            addProstheticTooth(at: pointMM)

        case .implant:
            // L'asse predefinito è verticale verso il basso. Su una cresta inclinata andrà
            // corretto, ma partire dalla verticale è più prevedibile che indovinare
            // un'inclinazione dalla vista corrente.
            toolSession.cancel()
            addImplant(at: pointMM)

        case .nerve:
            toolSession.cancel()
            if tracingNerveID == nil {
                // Il lato si deduce dal segno di L: destra del paziente è x negativo in LPS.
                beginTracingNerve(side: pointMM.x < 0 ? .right : .left)
            }
            addNerveNode(at: pointMM)
        }
    }

    /// Doppio clic: chiude ciò che non si chiude da sé.
    ///
    /// - Returns: `true` se c'era qualcosa da chiudere. Chi chiama lo usa per **non** interpretare
    ///   lo stesso doppio clic anche come ingrandimento del riquadro.
    @discardableResult
    func closeToolSession() -> Bool {
        // Le forme che si chiudono da sé non hanno nulla da chiudere: se qualcosa è rimasto a
        // metà lo si scarta, perché due punti di un angolo a tre non sono una misura.
        guard activeToolShape == .openPolyline else {
            let hadPoints = !toolSession.isEmpty
            toolSession.cancel()
            return hadPoints
        }

        // Un poligono ha bisogno di tre vertici; una spezzata di due punti. Chiedere tre punti a
        // una spezzata impedirebbe di misurare una cresta in due tratti.
        //
        // Anche la mano libera ne chiede tre: il gesto comincia posando un punto alla pressione,
        // quindi un clic fermo ne lascerebbe uno solo e un tremito due. Sotto i tre punti non
        // c'è un tracciato, c'è un clic andato storto.
        let minimum = activeTool == .ellipseROI || activeTool == .freehand ? 3 : 2
        guard let points = toolSession.close(minimumPoints: minimum) else { return false }

        let plane = toolSession.anchor?.planeReference
        switch activeTool {
        case .ellipseROI:
            let spacing = volume?.geometry.spacingMM ?? Vec3(1, 1, 1)
            addAnnotation(
                .polygonROI(
                    PolygonROI(
                        metadata: AnnotationMetadata(
                            colorHex: "#4FCB6B", referencePlane: plane,
                            acquisition: acquisitionContext()),
                        verticesMM: points,
                        thicknessMM: max(spacing.x, max(spacing.y, spacing.z)))))
        case .freehand:
            addAnnotation(
                .freehand(
                    FreehandPath(
                        metadata: AnnotationMetadata(
                            colorHex: "#FF9F0A", referencePlane: plane,
                            acquisition: acquisitionContext()),
                        pointsMM: points,
                        isClosed: false)))
        default:
            addAnnotation(makePolyline(points, closed: toolVariant == "perimeter"))
        }
        return true
    }

    /// Distanza minima fra due punti consecutivi di un tracciato a mano libera, in millimetri.
    ///
    /// Senza diradamento un trascinamento di due secondi produce un migliaio di punti, che è un
    /// documento più pesante e un disegno più lento senza un pixel di differenza visibile. Tre
    /// decimi di millimetro stanno sotto il voxel di una CBCT dentale, quindi il tracciato non
    /// perde nulla che il dato contenesse.
    private static let freehandMinimumStepMM = 0.3

    /// Aggiunge un punto a un tracciato a mano libera in corso, diradando.
    func appendFreehandPoint(at pointMM: Vec3, anchor: ToolAnchor? = nil) {
        guard activeTool == .freehand else { return }
        toolSession.prepare(for: .openPolyline)
        if let last = toolSession.pointsMM.last,
            last.distance(to: pointMM) < Self.freehandMinimumStepMM
        {
            return
        }
        toolSession.add(pointMM, anchor: anchor)
    }

    /// Esc: annulla la misura in corso senza toccare quelle già poste.
    func cancelToolSession() {
        guard !toolSession.isEmpty else { return }
        toolSession.cancel()
        lastActionMessage = "Misura annullata"
    }

    private func makePolyline(_ pointsMM: [Vec3], closed: Bool) -> Annotation {
        .polyline(
            PolylineMeasurement(
                metadata: AnnotationMetadata(
                    colorHex: "#32B8C6", referencePlane: toolSession.anchor?.planeReference,
                    acquisition: acquisitionContext()),
                pointsMM: pointsMM,
                isClosed: closed))
    }

    /// Ellisse inscritta nel rettangolo definito dai due punti, sul piano dove è cominciata.
    ///
    /// Gli assi vengono dall'ancoraggio del **primo** punto: un'ellisse posata a cavallo di due
    /// riquadri prende l'orientamento da dove è cominciata, non da dove si chiude.
    private func makeEllipse(from start: Vec3, to end: Vec3) -> EllipseROI {
        let right = toolSession.anchor?.rightMM ?? Vec3(1, 0, 0)
        let down = toolSession.anchor?.downMM ?? Vec3(0, 1, 0)
        let diagonal = end - start
        let spacing = volume?.geometry.spacingMM ?? Vec3(1, 1, 1)

        return EllipseROI(
            metadata: AnnotationMetadata(
                colorHex: "#4FCB6B", referencePlane: toolSession.anchor?.planeReference,
                acquisition: acquisitionContext()),
            centerMM: start.lerp(to: end, t: 0.5),
            semiAxisAMM: right * (diagonal.dot(right) * 0.5),
            semiAxisBMM: down * (diagonal.dot(down) * 0.5),
            thicknessMM: max(spacing.x, max(spacing.y, spacing.z)))
    }

    func addAnnotation(_ annotation: Annotation) {
        annotations.append(annotation)
        selectedAnnotationID = annotation.id
        recomputeStatistics(for: annotation)
        syncRegistry()
        recordUndo("Aggiungi \(annotation.kindName.lowercased())")
    }

    func removeSelectedAnnotation() {
        guard let id = selectedAnnotationID else { return }
        annotations.removeAll { $0.id == id }
        roiStatistics.removeValue(forKey: id)
        profileSamples.removeValue(forKey: id)
        selectedAnnotationID = nil
        syncRegistry()
        recordUndo("Cancella misura")
    }

    /// Ricalcola le statistiche di una ROI.
    ///
    /// Il campionamento avviene sugli `Int16` di CPU, come prescrive il Contratto 3: leggere la
    /// texture restituirebbe valori interpolati, con minimi e massimi che nel dato reale non
    /// esistono.
    /// Densità lungo una linea di profilo, indicizzate per annotazione.
    ///
    /// Come le statistiche delle ROI: si calcolano quando l'annotazione cambia, non a ogni
    /// ridisegno. Centoventotto campionamenti trilineari sono poca cosa, ma moltiplicati per
    /// sessanta fotogrammi al secondo diventano lavoro sprecato su un dato immobile.
    private(set) var profileSamples: [UUID: [ProfileSample]] = [:]

    /// Se l'annotazione è una regione di cui ci si aspetta delle statistiche.
    private func isROI(_ annotation: Annotation) -> Bool {
        switch annotation {
        case .ellipseROI, .polygonROI, .sphereROI: return true
        default: return false
        }
    }

    func recomputeStatistics(for annotation: Annotation) {
        if case .profileLine(let line) = annotation, let volume {
            profileSamples[annotation.id] = ROISampler.profile(for: line, in: volume)
        }

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
            // Assegnare **o togliere**: una ROI finita fuori dal volume nuovo non ha più
            // statistiche, e lasciare le vecchie mostrerebbe un numero che non appartiene più a
            // nulla. Prima il valore restava lì, indistinguibile da uno appena calcolato.
            if let stats {
                roiStatistics[annotation.id] = stats
            } else if isROI(annotation) {
                roiStatistics.removeValue(forKey: annotation.id)
            }
        } catch {
            roiStatistics.removeValue(forKey: annotation.id)
        }
    }

    // MARK: Esportazione

    func makePlanDocument() -> PlanDocument {
        // Gli UID veri dello studio aperto, non due segnaposto.
        //
        // Erano murati a «sintetico» e «fantoccio» da quando il fantoccio era l'unica cosa che
        // il programma sapesse aprire, e nessuno li ha più guardati. Un piano salvato su un
        // paziente dichiarava quindi di appartenere al fantoccio, e riaprendolo su un altro
        // studio nessun controllo poteva accorgersi che non c'entrava — perché il riferimento
        // era finto in tutt'e due i casi, e due valori finti coincidono sempre.
        var document = PlanDocument(
            study: StudyReference(
                studyInstanceUID: exam.studyInstanceUID.isEmpty
                    ? "sintetico" : exam.studyInstanceUID,
                seriesInstanceUID: exam.seriesInstanceUID.isEmpty
                    ? "fantoccio" : exam.seriesInstanceUID,
                seriesDescription: exam.displayTitle,
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
