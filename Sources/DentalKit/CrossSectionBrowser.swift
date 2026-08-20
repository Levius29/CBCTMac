import DICOMCore
import Foundation
import VolumeKit

// Navigazione della striscia di sezioni trasversali.
//
// Esiste come tipo a sé, e non come stato dentro una vista SwiftUI, per una ragione pratica: qui
// c'è tutta la logica che si può sbagliare — quali sezioni mostrare, quale è selezionata, dove
// cade una sezione lungo l'arcata, quanto ingrandirle — e messa in un tipo puro si verifica con
// `swift test`, mentre dentro una vista non la verificherebbe nessuno finché non si compila
// l'applicazione su macOS.
//
// La vista che ne deriva chiede «cosa metto in questa cella» e disegna. Nient'altro.

/// Finestra scorrevole su una serie di sezioni trasversali.
public struct CrossSectionBrowser: Hashable, Sendable {

    /// Tutte le sezioni generate lungo la curva, in ordine di lunghezza d'arco.
    public private(set) var sections: [CrossSection]

    /// Quante sezioni mostrare per volta. È la disposizione `1×N` dei visori commerciali.
    public var visibleCount: Int {
        didSet { visibleCount = max(1, visibleCount) }
    }

    /// Sezione selezionata, cioè quella che le altre viste seguono.
    public private(set) var selectedIndex: Int

    /// Ingrandimento della striscia.
    ///
    /// Serve perché con dieci sezioni affiancate in una striscia alta duecento pixel non si
    /// distingue niente, ed è il motivo per cui una griglia di anteprime minuscole viene percepita
    /// come inutile. Ingrandire riduce quante ne stanno insieme, ed è il compromesso giusto: si
    /// guardano poche sezioni per volta, ma si vedono.
    public var zoom: Double {
        didSet { zoom = Self.clampZoom(zoom) }
    }

    public static let minimumZoom = 1.0
    public static let maximumZoom = 8.0

    public init(sections: [CrossSection] = [], visibleCount: Int = 10, zoom: Double = 1) {
        self.sections = sections
        self.visibleCount = max(1, visibleCount)
        self.zoom = Self.clampZoom(zoom)
        self.selectedIndex = sections.isEmpty ? 0 : sections.count / 2
    }

    private static func clampZoom(_ value: Double) -> Double {
        guard value.isFinite else { return minimumZoom }
        return min(max(value, minimumZoom), maximumZoom)
    }

    public var isEmpty: Bool { sections.isEmpty }
    public var count: Int { sections.count }

    /// Sostituisce le sezioni conservando **la posizione lungo l'arcata**, non l'indice.
    ///
    /// È la differenza che conta quando si cambia il passo. Passando da 1 mm a 0,5 mm gli indici
    /// raddoppiano, e conservare l'indice farebbe saltare la selezione a metà arcata; conservare
    /// la lunghezza d'arco la lascia sul dente che si stava guardando. L'indice è un dettaglio
    /// della rappresentazione, la posizione è il dato.
    public mutating func replaceSections(_ newSections: [CrossSection]) {
        let previousArcLength = selectedSection?.arcLengthMM
        sections = newSections
        if let previousArcLength, let index = index(nearestToArcLengthMM: previousArcLength) {
            selectedIndex = index
        } else {
            selectedIndex = newSections.isEmpty ? 0 : newSections.count / 2
        }
    }

    // MARK: Selezione

    public var selectedSection: CrossSection? {
        sections.indices.contains(selectedIndex) ? sections[selectedIndex] : nil
    }

    public mutating func select(index: Int) {
        guard !sections.isEmpty else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(index, 0), sections.count - 1)
    }

    /// Sposta la selezione di un numero di sezioni, arrestandosi ai capi.
    public mutating func step(by delta: Int) {
        select(index: selectedIndex + delta)
    }

    /// Indice della sezione più vicina a una lunghezza d'arco.
    ///
    /// Le sezioni sono equidistanti per costruzione, quindi si potrebbe dividere e arrotondare.
    /// Non si fa: il passo effettivo dipende da un arrotondamento dentro `resampled(spacingMM:)`,
    /// e una formula che presuppone il passo nominale sbaglierebbe di una sezione verso la fine
    /// della curva — poco, ma proprio dove si lavora sui molari.
    public func index(nearestToArcLengthMM arcLength: Double) -> Int? {
        guard !sections.isEmpty, arcLength.isFinite else { return nil }
        var best = 0
        var bestDistance = Double.infinity
        for (index, section) in sections.enumerated() {
            let distance = abs(section.arcLengthMM - arcLength)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    public mutating func select(nearestToArcLengthMM arcLength: Double) {
        guard let index = index(nearestToArcLengthMM: arcLength) else { return }
        selectedIndex = index
    }

    // MARK: Finestra visibile

    /// Quante sezioni entrano nella striscia.
    ///
    /// # Due cose che erano una sola
    ///
    /// Era `visibleCount / zoom`: ingrandire riduceva **anche** il numero di sezioni mostrate. Da
    /// fuori si vedeva così — «le sezioni trasversali aumentano e diminuiscono a seconda di
    /// quanto ingrandisco» — ed erano due decisioni diverse legate a un numero solo.
    ///
    /// Sono indipendenti, e vanno tenute indipendenti: *quanta anatomia voglio vedere dentro
    /// ogni sezione* è una domanda su un dente, *quanti denti voglio vedere insieme* è una
    /// domanda sull'arcata. Chi ingrandisce per guardare una corticale non sta chiedendo di
    /// perdere di vista gli altri denti.
    ///
    /// L'ingrandimento resta su `sectionExtentMM`, che è il suo posto. Quante sezioni si vedono
    /// si sceglie a parte, con `visibleCount`.
    public var effectiveVisibleCount: Int {
        max(1, visibleCount)
    }

    /// Intervallo di indici mostrati, centrato sulla selezione e limitato agli estremi.
    ///
    /// La limitazione ai capi è la stessa disciplina della finestra del panorex, e per la stessa
    /// ragione: la striscia mostra sempre `effectiveVisibleCount` sezioni **vere**, non celle vuote
    /// all'inizio e alla fine dell'arcata. Celle vuote suggeriscono che manchino dati, e non è così.
    public var visibleRange: Range<Int> {
        guard !sections.isEmpty else { return 0..<0 }
        let span = min(effectiveVisibleCount, sections.count)
        var start = selectedIndex - span / 2
        start = min(max(start, 0), sections.count - span)
        return start..<(start + span)
    }

    public var visibleSections: [CrossSection] {
        Array(sections[visibleRange])
    }

    /// Scorre la finestra **senza** cambiare la selezione, come si scorre un elenco.
    ///
    /// Distinto da `step(by:)`, che sposta la selezione e con essa le altre viste. Sono due gesti
    /// diversi: guardare avanti nella striscia non deve muovere il mirino, altrimenti scorrere
    /// per cercare qualcosa trascina tutto il resto dell'interfaccia dietro di sé.
    public mutating func scrollWindow(by delta: Int) {
        guard !sections.isEmpty else { return }
        let span = min(effectiveVisibleCount, sections.count)
        let current = visibleRange.lowerBound
        let start = min(max(current + delta, 0), sections.count - span)
        // La finestra si esprime solo attraverso la selezione, quindi si sposta la selezione al
        // centro della finestra voluta. È una scelta: un `windowStart` indipendente sarebbe più
        // diretto e aggiungerebbe uno stato che può discordare dalla selezione.
        selectedIndex = min(max(start + span / 2, 0), sections.count - 1)
    }

    // MARK: Dimensione a schermo

    /// Larghezza e altezza in millimetri di una sezione, dopo l'ingrandimento.
    ///
    /// Ingrandire **restringe il campo**, non stira l'immagine: a zoom 2 si vede metà larghezza e
    /// metà altezza, alla stessa scala millimetri-per-pixel di prima. Stirare mostrerebbe la stessa
    /// anatomia più grande e sfocata, e soprattutto renderebbe la barra di scala una bugia.
    public func sectionExtentMM(baseWidthMM: Double, baseHeightMM: Double)
        -> (widthMM: Double, heightMM: Double)
    {
        let factor = max(zoom, Self.minimumZoom)
        return (max(baseWidthMM / factor, 1), max(baseHeightMM / factor, 1))
    }

    /// Lunghezze d'arco delle sezioni mostrate, per disegnare i segni sull'assiale e sul panorex.
    public var visibleArcLengthsMM: [Double] {
        visibleSections.map(\.arcLengthMM)
    }
}
