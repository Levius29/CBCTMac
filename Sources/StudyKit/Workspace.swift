import DICOMCore
import Foundation

// I modi di lavoro, i riquadri e la loro disposizione.
//
// # Perché un modo di lavoro e non un layout
//
// Finora c'era un selettore di disposizione: 2×2, uno grande e tre, panorex. Sceglie *come sono
// messe le finestre*. Un modo di lavoro sceglie invece *che cosa si sta facendo*, e la
// disposizione ne è una conseguenza fra le altre — assieme a quali strumenti hanno senso, quale
// riquadro riceve il fuoco all'ingresso, se la curva dell'arcata è in gioco.
//
// La differenza si vede nel gesto che si risparmia. Con i layout, passare dall'esame ortogonale
// alla valutazione della cresta significa: cambiare disposizione, cambiare riquadro attivo,
// prendere lo strumento arcata, ricordarsi di accendere il panorex. Con i modi è un clic, e i
// tre aggiustamenti che si sarebbero fatti a mano sono la definizione del modo.
//
// # Che cosa si porta dietro e che cosa no
//
// Il punto delicato è la memoria. Se cambiare modo azzerasse tutto, i modi sarebbero una
// scomodità; se conservasse tutto, non sarebbero modi. La regola qui è:
//
// - **Comune a tutti**: il mirino, la finestra di densità, le annotazioni, la curva, gli
//   impianti. Sono proprietà del *caso*, non del modo in cui lo si guarda, e ritrovarle spostate
//   dopo un giro fra le schede sarebbe un difetto grave — si perderebbe il punto che si stava
//   esaminando.
// - **Propria di ogni modo**: la disposizione e il riquadro attivo. Si regolano *per* quel
//   compito, e ritrovarle come le si era lasciate è tutto il vantaggio delle schede.
//
// Detta così sembra ovvia. Non lo è: l'implementazione ingenua — un solo `layout` nel modello,
// riassegnato al cambio di modo — soddisfa la prima metà e non la seconda, e il sintomo è che
// tornando su una scheda si ritrova la disposizione di fabbrica invece della propria.

// MARK: - Riquadri

/// Uno dei riquadri della scrivania.
///
/// Vive qui e non nell'applicazione perché è **dato**, non interfaccia: quali riquadri esistono e
/// come si dispongono è una decisione che si può verificare, e lì dentro non si potrebbe.
/// L'applicazione vi aggiunge un'estensione con il colore e l'icona, che invece sono interfaccia.
public enum ViewportSlot: String, CaseIterable, Hashable, Sendable, Identifiable, Codable {
    case axial
    case coronal
    case sagittal
    case volume3D

    public var id: String { rawValue }

    /// Piano anatomico corrispondente, `nil` per il riquadro 3D.
    public var anatomicalPlane: AnatomicalPlane? {
        switch self {
        case .axial: return .axial
        case .coronal: return .coronal
        case .sagittal: return .sagittal
        case .volume3D: return nil
        }
    }

    public var localizedName: String {
        switch self {
        case .axial: return "Assiale"
        case .coronal: return "Coronale"
        case .sagittal: return "Sagittale"
        case .volume3D: return "3D"
        }
    }
}

/// Come sono disposti i riquadri.
public enum ViewportLayout: String, CaseIterable, Hashable, Sendable, Codable {
    case single
    case grid2x2
    case onePlusThree
    /// Panorex in alto e griglia di sezioni trasversali sotto. È la disposizione con cui si
    /// valuta la cresta e si pianifica un impianto.
    case panoramic

    public var localizedName: String {
        switch self {
        case .single: return "Singolo"
        case .grid2x2: return "Griglia 2×2"
        case .onePlusThree: return "Uno grande e tre"
        case .panoramic: return "Panorex e sezioni"
        }
    }

    public var systemImageName: String {
        switch self {
        case .single: return "square"
        case .grid2x2: return "square.grid.2x2"
        case .onePlusThree: return "rectangle.split.2x2"
        case .panoramic: return "rectangle.grid.1x2"
        }
    }

    /// I riquadri che questa disposizione disegna davvero.
    ///
    /// # Perché una disposizione deve saperlo dire
    ///
    /// Perché metà dei comandi dell'ispettore parlano a **un** riquadro — lo spessore dello slab,
    /// la proiezione, l'inclinazione del taglio — e li prendono dal riquadro a fuoco. Il fuoco
    /// però sopravvive al cambio di disposizione: si lavora sul sagittale, si passa alla panorex,
    /// e da lì in poi quei comandi agiscono su un riquadro che non è più a schermo. Non danno
    /// errore: danno il silenzio, che è peggio, perché si prova a muovere un cursore e non
    /// succede niente di visibile.
    ///
    /// - Parameter focused: il riquadro a fuoco, che in «singolo» è anche l'unico disegnato.
    public func drawnSlots(focused: ViewportSlot) -> [ViewportSlot] {
        switch self {
        case .single: return [focused]
        case .grid2x2, .onePlusThree: return ViewportSlot.allCases
        // La panorex ha una scrivania tutta sua — assiale con la curva, striscia panoramica,
        // sezioni trasversali — e nessuno dei quattro riquadri canonici.
        case .panoramic: return []
        }
    }

    public func draws(_ slot: ViewportSlot, focused: ViewportSlot) -> Bool {
        drawnSlots(focused: focused).contains(slot)
    }

    /// Vero se a schermo c'è almeno un'immagine governata dalla finestra di densità.
    ///
    /// Vale anche per la panorex: la striscia e le sezioni trasversali sono immagini 2D, e la
    /// finestra le governa come governa le tre viste ortogonali. L'unico caso in cui non c'è
    /// niente da governare è la disposizione «singolo» con il 3D dentro, dove al posto della
    /// finestra conta la transfer function.
    public func showsWindowedImages(focused: ViewportSlot) -> Bool {
        if self == .panoramic { return true }
        return drawnSlots(focused: focused).contains { $0.anatomicalPlane != nil }
    }
}

// MARK: - Modi

/// I cinque modi di lavoro.
///
/// Sono gli stessi cinque di CS 3D Imaging, e non per imitazione: coprono i cinque modi in cui si
/// guarda davvero una CBCT dentale — per piani della macchina, lungo l'arcata, su un piano scelto
/// a mano, su un piano inclinato attorno a un asse, e in rilettura. Ne mancasse uno, il lavoro
/// che gli corrisponde si farebbe a fatica dentro un altro.
public enum WorkMode: String, CaseIterable, Hashable, Sendable, Codable, Identifiable {
    /// I tre piani della macchina più il 3D. È il modo in cui si apre uno studio.
    case orthogonal
    /// Arcata, panorex e sezioni trasversali: la valutazione della cresta.
    case curved
    /// Piano scelto a mano, per guardare una struttura come sta davvero.
    case custom
    /// Piano inclinato attorno a un asse: condilo, ramo, dente incluso.
    case oblique
    /// Rilettura del piano finito, senza strumenti di modifica.
    case review

    public var id: String { rawValue }

    public var localizedName: String {
        switch self {
        case .orthogonal: return "Sezionamento ortogonale"
        case .curved: return "Sezionamento curvo"
        case .custom: return "Sezionamento personalizzato"
        case .oblique: return "Sezionamento obliquo"
        case .review: return "Rivedi"
        }
    }

    /// Nome corto per la barra delle schede, dove cinque nomi interi non stanno.
    public var shortName: String {
        switch self {
        case .orthogonal: return "Ortogonale"
        case .curved: return "Curvo"
        case .custom: return "Personalizzato"
        case .oblique: return "Obliquo"
        case .review: return "Rivedi"
        }
    }

    public var systemImageName: String {
        switch self {
        case .orthogonal: return "square.grid.2x2"
        case .curved: return "waveform.path"
        case .custom: return "slider.horizontal.below.rectangle"
        case .oblique: return "rotate.3d"
        case .review: return "doc.text.magnifyingglass"
        }
    }

    /// Disposizione con cui il modo si presenta la prima volta.
    public var defaultLayout: ViewportLayout {
        switch self {
        case .orthogonal: return .grid2x2
        case .curved: return .panoramic
        case .custom: return .onePlusThree
        case .oblique: return .onePlusThree
        case .review: return .grid2x2
        }
    }

    /// Riquadro che riceve il fuoco entrando nel modo la prima volta.
    public var defaultFocus: ViewportSlot {
        switch self {
        case .orthogonal: return .axial
        // Sull'assiale si disegna la curva, ed è da lì che si comincia in modo curvo.
        case .curved: return .axial
        case .custom: return .axial
        // In obliquo si lavora quasi sempre inclinando attorno all'asse del coronale.
        case .oblique: return .coronal
        case .review: return .volume3D
        }
    }

    /// Una riga che dice a che serve il modo e con che gesto ci si lavora.
    ///
    /// Serve perché due modi possono avere la stessa disposizione — «personalizzato» e «obliquo»
    /// sono entrambi uno grande e tre — e senza una parola che li distingua sembrerebbero due
    /// schede identiche. Dire a che servono costa una riga; lasciar credere che siano doppioni
    /// costa la fiducia in tutte e cinque.
    public var hint: String {
        switch self {
        case .orthogonal:
            return "I tre piani della macchina. Trascina le linee del mirino per spostare i tagli."
        case .curved:
            return "Disegna la curva sull'assiale, poi naviga le sezioni lungo l'arcata."
        case .custom:
            return "Inquadra la struttura nel riquadro grande e ruotala fino a vederla per il verso giusto."
        case .oblique:
            return "Afferra le maniglie del mirino per inclinare il taglio attorno al mirino."
        case .review:
            return "Rilettura del piano. Nessuno strumento di modifica è attivo."
        }
    }

    /// Se il modo prevede di **modificare** il piano, o solo di leggerlo.
    ///
    /// «Rivedi» è di sola lettura per progetto: una rilettura in cui si può spostare un impianto
    /// senza accorgersene non è una rilettura, è una seconda sessione di pianificazione con le
    /// stesse conseguenze e meno attenzione.
    public var isEditable: Bool { self != .review }

    /// Se la curva dell'arcata è parte del lavoro in questo modo.
    public var usesArchCurve: Bool { self == .curved }
}

// MARK: - Sessione

/// Lo stato che appartiene ai modi, e la regola con cui sopravvive al passaggio fra loro.
///
/// Non contiene il mirino, la finestra di densità, le annotazioni: quelli sono del caso, restano
/// dove sono nel modello dell'applicazione, e proprio per questo attraversano i modi intatti.
/// Qui c'è **solo** ciò che è lecito che cambi cambiando scheda.
public struct WorkspaceSession: Hashable, Sendable, Codable {

    public private(set) var mode: WorkMode

    /// Stato per modo, riempito pigramente: un modo mai visitato non ha una voce, e la prima
    /// volta che lo si apre prende i valori di fabbrica.
    private var layouts: [WorkMode: ViewportLayout]
    private var focuses: [WorkMode: ViewportSlot]

    public init(mode: WorkMode = .orthogonal) {
        self.mode = mode
        self.layouts = [:]
        self.focuses = [:]
    }

    public var layout: ViewportLayout {
        get { layouts[mode] ?? mode.defaultLayout }
        set { layouts[mode] = newValue }
    }

    public var focusedSlot: ViewportSlot {
        get { focuses[mode] ?? mode.defaultFocus }
        set { focuses[mode] = newValue }
    }

    /// Passa a un altro modo conservando ciò che si era regolato in questo.
    public mutating func activate(_ newMode: WorkMode) {
        guard newMode != mode else { return }
        mode = newMode
    }

    /// Riporta **un solo** modo ai valori di fabbrica, lasciando intatti gli altri.
    ///
    /// Uno solo e non tutti: chi vuole rimettere a posto la scheda su cui sta lavorando non vuole
    /// perdere anche le altre quattro, e un comando che facesse le due cose insieme sarebbe usato
    /// una volta e poi evitato.
    public mutating func reset(_ target: WorkMode) {
        layouts[target] = nil
        focuses[target] = nil
    }

    /// Se il modo ha una disposizione scelta dall'utente, o sta ancora su quella di fabbrica.
    public func hasCustomLayout(_ target: WorkMode) -> Bool {
        layouts[target] != nil
    }
}
