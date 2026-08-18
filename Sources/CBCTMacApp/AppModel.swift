import ArtifactKit
import DICOMCore
import DentalKit
import ImplantKit
import MeasureKit
import Metal
import StudyKit
import Observation
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

    /// Una riga che dice come si usa. Compare sotto la palette, e vale piu' di un'icona: un
    /// righello che chiede **due** clic non lo dice da se', e chi ne dà uno solo pensa sia rotto.
    var hint: String? {
        switch self {
        case .navigate: return nil
        case .distance: return "Fai clic sui due estremi."
        case .angle: return "Fai clic sui tre punti, il vertice per primo."
        case .ellipseROI: return "Trascina dal centro verso il bordo."
        case .sphereROI: return "Fai clic sul centro, poi sul bordo."
        case .text: return "Fai clic dove vuoi la nota."
        case .implant: return "Fai clic sulla cresta: l'impianto scende da lì."
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
        case .implant: return "i"
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
        case .implant: return "screwdriver"
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

    /// Variante dello strumento attivo, quando ne ha. Vedi `ToolPalette`.
    var toolVariant: String = "distance"

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
        recordUndo("Cambia colore")
    }

    func renameObject(_ name: String, id: UUID) {
        registry.rename(name, id: id)
        if let index = implants.firstIndex(where: { $0.id == id }) {
            implants[index].label = name
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
        implants.removeAll { $0.id == id }
        nerveCanals.removeAll { $0.id == id }
        annotations.removeAll { $0.id == id }
        if selectedImplantID == id { selectedImplantID = nil }
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
        nerveCanals.removeAll { doomed.contains($0.id) }
        annotations.removeAll { doomed.contains($0.id) }
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
    private func archTangent(near pointMM: Vec3) -> Vec3 {
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
        var nerveCanals: [NerveCanal]
        var archCurves: [DentalArch: ArchCurve]
    }

    private var undoHistory = UndoHistory<PlanSnapshot>(initial: PlanSnapshot(
        annotations: [], implants: [], nerveCanals: [], archCurves: [:]))

    /// Vero mentre si sta applicando un annulla: le mutazioni che ne derivano non vanno
    /// registrate, altrimenti annullare creerebbe un passo nuovo e «ripeti» non tornerebbe mai.
    private var isRestoring = false

    var canUndo: Bool { undoHistory.canUndo }
    var canRedo: Bool { undoHistory.canRedo }
    var undoLabel: String? { undoHistory.undoLabel }
    var redoLabel: String? { undoHistory.redoLabel }

    private var planSnapshot: PlanSnapshot {
        PlanSnapshot(
            annotations: annotations, implants: implants,
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
            openStudy(volume: volume, named: name, provenance: .imported)
            // Gli avvisi si impostano **dopo** `openStudy`, che azzera lo stato: altrimenti
            // sparirebbero proprio quando servono.
            loadIssues = messages
            loadingMessage = nil
        }
    }

    private enum StudyOutcome: Sendable {
        case loaded(Volume, [String], String)
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
        windowLevel = DensityWindow.automatic(from: volume)
        camera = VolumeCamera.fitted(to: volume.geometry)
        histogram = volume.rawHistogram(binCount: 256)

        resetPlanes()
        guard !preservingPlan else { return }
        resetArchCurves()
        annotations = []
        implants = []
        nerveCanals = []
        roiStatistics = [:]
        selectedAnnotationID = nil
        selectedImplantID = nil
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
        selectedAnnotationID = nil
        syncRegistry()
        recordUndo("Cancella misura")
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
