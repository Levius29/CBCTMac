import AppKit
import MetalKit

// `MTKView` che inoltra gli eventi del mouse.
//
// SwiftUI su macOS non espone la rotella, il trascinamento con il tasto destro né il pinch del
// trackpad su una vista qualunque. Invece di aggirarli con soluzioni tortuose si scende a
// `NSView`, che è il posto giusto per gli eventi.
//
// **Le coordinate sono in pixel della texture, con origine in alto a sinistra.** La conversione
// avviene qui, una volta sola, così chi riceve i callback ragiona nello stesso sistema in cui
// lavora lo shader. Due passaggi facili da sbagliare, entrambi concentrati in questo file:
// `isFlipped` per l'asse verticale, e il fattore di scala del display per i pixel.
//
// # Mappa dei gesti
//
// | Gesto | Effetto |
// |---|---|
// | Rotella | scorre le fette lungo la normale |
// | ⌘ + rotella | zoom **ancorato al puntatore** |
// | Pinch del trackpad | zoom ancorato al puntatore |
// | Clic, senza spostamento | sposta il mirino |
// | Trascinamento sinistro | strumento attivo; con «naviga» sposta l'immagine |
// | ⌥ + trascinamento sinistro | sposta l'immagine, **sempre** |
// | ⇧ + trascinamento sinistro | ruota l'immagine nel piano |
// | Trascinamento centrale | sposta l'immagine, sempre |
// | Trascinamento destro | finestra e livello |
// | Doppio clic | ingrandisce il riquadro |
//
// Due scelte in questa mappa non sono arbitrarie e vale la pena dire perché.
//
// **Il clic non parte alla pressione, ma al rilascio, e solo se il puntatore non si è spostato.**
// Prima il mirino saltava all'inizio di ogni trascinamento: si premeva per spostare l'immagine e
// il mirino si teletrasportava, trascinando con sé anche le altre due viste. Distinguere clic e
// trascinamento con una soglia di pochi punti elimina il problema alla radice.
//
// **La modalità di trascinamento si fissa alla pressione, non a ogni evento.** Leggendo i
// modificatori a ogni `mouseDragged`, rilasciare ⌥ a metà gesto commuterebbe da panoramica a
// strumento nel mezzo del movimento. Si decide una volta e si tiene fino al rilascio.

final class InteractiveMetalView: MTKView {

    // MARK: Callback

    /// Rotella. Il valore è in "passi": positivo scorre in avanti lungo la normale.
    var onScroll: ((Double) -> Void)?
    /// Rotella con ⌥: significato **alternativo**, che decide chi sta sopra.
    ///
    /// Nulla per difetto, e allora ⌥ non cambia nulla: chi non lo assegna si comporta come prima.
    var onAlternateScroll: ((Double) -> Void)?
    /// Rotella con ⇧: lo stesso significato della rotella nuda, a passo **fine**.
    var onFineScroll: ((Double) -> Void)?
    /// Zoom: fattore moltiplicativo e **pixel su cui ancorarlo**.
    ///
    /// L'ancora è ciò che rende lo zoom prevedibile: il punto anatomico sotto quel pixel non si
    /// muove. Chi non ne ha bisogno — il riquadro 3D, che orbita attorno al centro — la ignora.
    var onZoom: ((Double, CGPoint) -> Void)?
    /// Trascinamento con lo strumento attivo: posizione corrente e spostamento, in pixel.
    var onDrag: ((CGPoint, CGSize) -> Void)?
    /// Trascinamento di panoramica, indipendente dallo strumento attivo.
    var onPan: ((CGSize) -> Void)?
    /// Trascinamento di rotazione nel piano.
    var onRotate: ((CGSize) -> Void)?
    /// Trascinamento con il tasto destro: spostamento in pixel. Regola finestra e livello.
    var onWindowLevelDrag: ((CGSize) -> Void)?
    /// Clic singolo, confermato al rilascio senza spostamento apprezzabile.
    var onClick: ((CGPoint) -> Void)?
    /// Movimento del puntatore; `nil` quando esce dalla vista.
    var onHover: ((CGPoint?) -> Void)?
    /// Doppio clic: ingrandisce il riquadro a piena finestra.
    var onDoubleClick: (() -> Void)?

    /// Inizio e fine di un trascinamento.
    ///
    /// Servono al riquadro 3D per abbassare la qualità mentre si ruota e rialzarla al rilascio.
    /// Il segnale deve arrivare dal pulsante del mouse e non da un timer di inattività: con un
    /// timer la prima frazione di secondo di rotazione girerebbe comunque a piena qualità, che
    /// è esattamente il momento in cui la fluidità conta di più.
    /// Inizio di un trascinamento, con il punto premuto in pixel.
    ///
    /// Il punto serve a decidere **che cosa** si è afferrato prima che il trascinamento cominci:
    /// una maniglia del mirino, una linea, o niente. Deciderlo al primo movimento sarebbe già
    /// tardi — il primo movimento è quello che sposta.
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragEnded: (() -> Void)?
    /// Esc: annulla la misura in corso.
    ///
    /// Sta qui e non fra i comandi del menu perché Esc ha già un significato in ogni finestra di
    /// dialogo — «annulla» — e occuparlo globalmente romperebbe la chiusura delle finestre. Il
    /// riquadro è primo responder appena lo si tocca, e riceve il tasto solo mentre è lui a
    /// essere usato, che è esattamente quando la misura in corso è sua.
    var onCancel: (() -> Void)?

    // MARK: Configurazione

    /// Origine in alto a sinistra, come la texture. Senza questo l'asse verticale sarebbe
    /// rovesciato rispetto all'immagine, e ogni misura risulterebbe specchiata.
    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 è Esc. Il confronto sul codice e non sui caratteri: `charactersIgnoringModifiers`
        // per Esc restituisce un carattere di controllo che cambia con la disposizione tastiera.
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        guard handleNavigationKey(event) else {
            super.keyDown(with: event)
            return
        }
    }

    /// Le frecce scorrono, esattamente come la rotella.
    ///
    /// # Perché passano dai richiami della rotella e non da uno loro
    ///
    /// Perché «un passo avanti» significa cose diverse in riquadri diversi — una fetta sulle
    /// ortogonali, un millimetro d'arcata sulla panorex, una sezione nella striscia — e ogni
    /// riquadro l'ha già dichiarato collegando la rotella. Un richiamo separato per la tastiera
    /// vorrebbe dire dichiararlo due volte, e su questo progetto due dichiarazioni della stessa
    /// cosa sono già divergute abbastanza spesso da non volerne altre.
    ///
    /// I modificatori valgono come sulla rotella: ⇧ passo fine, ⌥ significato alternativo. Le
    /// pagine su e giù fanno dieci passi, che è la scala con cui si attraversa un volume
    /// cercando la struttura invece di studiarla.
    private func handleNavigationKey(_ event: NSEvent) -> Bool {
        let steps: Double
        switch event.keyCode {
        case 126, 124: steps = 1     // freccia su, freccia destra
        case 125, 123: steps = -1    // freccia giù, freccia sinistra
        case 116: steps = 10         // pagina su
        case 121: steps = -10        // pagina giù
        default: return false
        }

        // La ripetizione automatica del tasto va bene: tenere premuta la freccia deve scorrere.
        if event.modifierFlags.contains(.option), let onAlternateScroll {
            onAlternateScroll(steps)
            return true
        }
        if event.modifierFlags.contains(.shift), let onFineScroll {
            onFineScroll(steps)
            return true
        }
        guard let onScroll else { return false }
        onScroll(steps)
        return true
    }

    /// Frazione della risoluzione nativa a cui rendere: 1 è piena, 0,5 un quarto dei pixel.
    ///
    /// Serve sui volumi grandi, dove un riquadro a piena risoluzione Retina può non stare nel
    /// budget di un fotogramma. Il ridimensionamento lo fa il compositore, quindi non costa nulla
    /// oltre alla perdita di nitidezza.
    ///
    /// - Important: abbassarla cambia il rapporto fra punti della vista e pixel della texture,
    ///   e quel rapporto è ciò con cui un clic diventa una misura in millimetri. Per questo
    ///   `pixelsPerPoint` lo **misura** su `drawableSize` invece di assumere
    ///   `backingScaleFactor`: con una scala diversa da 1 l'assunzione sarebbe falsa e ogni
    ///   misura risulterebbe scalata dello stesso fattore, in silenzio.
    var renderScale: CGFloat = 1 {
        didSet {
            guard renderScale != oldValue else { return }
            updateDrawableSize()
        }
    }

    private var trackingArea: NSTrackingArea?

    override func layout() {
        super.layout()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        guard !autoResizeDrawable else { return }
        let backing = window?.backingScaleFactor ?? 1
        let scale = max(0.1, min(1, renderScale)) * backing
        let width = (bounds.width * scale).rounded()
        let height = (bounds.height * scale).rounded()
        guard width >= 1, height >= 1 else { return }
        let size = CGSize(width: width, height: height)
        guard size != drawableSize else { return }
        drawableSize = size
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: Stato del gesto in corso

    /// Cosa fa il trascinamento iniziato, deciso alla pressione e non più rinegoziato.
    private enum DragMode {
        case tool
        case pan
        case rotate
    }

    private var dragMode: DragMode = .tool
    private var pressLocation: CGPoint?
    /// Spostamento accumulato **in punti**, non in pixel: la soglia del clic è una grandezza
    /// percepita dal dito, non dipendente dalla densità del display.
    private var accumulatedMovement: CGFloat = 0
    private var exceededClickSlop = false

    /// Oltre questo spostamento il gesto è un trascinamento e non produrrà un clic.
    ///
    /// Tre punti sono abbastanza per assorbire il tremito della mano su un trackpad e abbastanza
    /// pochi perché un trascinamento voluto venga riconosciuto subito.
    /// Movimento oltre il quale una pressione smette di essere un clic e diventa un
    /// trascinamento, in punti di schermo.
    ///
    /// Non è privata perché la stessa soglia serve a chi sta sopra: uno strumento a due punti si
    /// completa col trascinamento, e deve distinguerlo dal clic **con lo stesso metro**. Due
    /// soglie diverse darebbero un intervallo in cui il gesto conta sia come clic sia come
    /// trascinamento, cioè due misure per un gesto solo.
    static let clickSlopPoints: CGFloat = 3

    /// Radianti per punto di trascinamento orizzontale nella rotazione nel piano.
    ///
    /// Circa mezzo giro ogni 400 punti, la stessa sensibilità dell'orbita 3D, così i due gesti
    /// non hanno "peso" diverso.
    static let rotationRadiansPerPoint = Double.pi / 400

    // MARK: Conversione delle coordinate

    /// Pixel della texture per punto della vista, **misurati** e non assunti.
    ///
    /// L'ovvio sarebbe `backingScaleFactor`, e sarebbe giusto solo quando la texture ha
    /// esattamente la dimensione nativa della vista. Con `renderScale` diversa da 1 non è così, e
    /// l'errore non si vedrebbe come un difetto grafico: si vedrebbe come misure scalate di un
    /// fattore costante, che è il modo peggiore di sbagliare, perché sembrano plausibili.
    private var pixelsPerPoint: (x: CGFloat, y: CGFloat) {
        let fallback = window?.backingScaleFactor ?? 1.0
        let x = bounds.width > 0 && drawableSize.width > 0
            ? drawableSize.width / bounds.width
            : fallback
        let y = bounds.height > 0 && drawableSize.height > 0
            ? drawableSize.height / bounds.height
            : fallback
        return (x, y)
    }

    /// Da coordinate finestra a pixel della texture.
    ///
    /// `convert(_:from: nil)` porta nello spazio della vista, che grazie a `isFlipped` ha già
    /// l'origine in alto a sinistra; resta da riportare i punti in pixel della texture.
    private func pixelLocation(of event: NSEvent) -> CGPoint {
        let inView = convert(event.locationInWindow, from: nil)
        let scale = pixelsPerPoint
        return CGPoint(x: inView.x * scale.x, y: inView.y * scale.y)
    }

    /// Spostamento in pixel della texture, **ricavato dalle posizioni** e non da `deltaX`/`deltaY`.
    ///
    /// Qui c'era il difetto per cui l'immagine si spostava correttamente a destra e a sinistra e
    /// al contrario in verticale. La versione precedente usava `event.deltaY` invertendone il
    /// segno, sulla base del fatto che in AppKit l'asse verticale cresce verso l'alto. Per gli
    /// eventi di trascinamento non è così: `deltaY` è già positivo verso il basso, quindi
    /// l'inversione introduceva una negazione di troppo — e solo sulla verticale, perché
    /// l'orizzontale non ne aveva nessuna.
    ///
    /// La correzione non è cambiare quel segno. È **smettere di avere due convenzioni**: lo
    /// spostamento si calcola come differenza fra due `pixelLocation` successive, cioè passando
    /// dallo stesso codice che converte una posizione. Così le due grandezze non possono più
    /// discordare, e nessuno deve ricordarsi da che parte cresce `deltaY`.
    private func pixelDelta(of event: NSEvent) -> CGSize {
        let current = pixelLocation(of: event)
        defer { lastPixelLocation = current }
        guard let last = lastPixelLocation else { return .zero }
        return CGSize(width: current.x - last.x, height: current.y - last.y)
    }

    /// Ultima posizione nota, per calcolare lo spostamento. Va azzerata alla pressione di ogni
    /// pulsante, altrimenti il primo movimento di un gesto riporterebbe il salto dall'ultimo
    /// punto del gesto precedente.
    private var lastPixelLocation: CGPoint?

    /// Spostamento in punti, per le soglie percepite e per la rotazione.
    private func pointDelta(of event: NSEvent) -> CGSize {
        CGSize(width: event.deltaX, height: -event.deltaY)
    }

    // MARK: Eventi

    override func scrollWheel(with event: NSEvent) {
        // I trackpad producono molti eventi piccoli e continui, i mouse a rotella pochi e
        // discreti. Normalizzare a "passi" evita che sul trackpad le slice sfreccino via.
        let raw = event.hasPreciseScrollingDeltas
            ? event.scrollingDeltaY / 8.0
            : event.scrollingDeltaY
        guard abs(raw) > 0.001 else { return }

        if event.modifierFlags.contains(.command) {
            // Zoom con la rotella, ancorato dove sta il puntatore. Il 5% per passo è abbastanza
            // fine da fermarsi sull'ingrandimento che si vuole.
            let factor = 1.0 + Double(raw) * 0.05
            guard factor > 0.05 else { return }
            onZoom?(factor, pixelLocation(of: event))
            return
        }

        if event.modifierFlags.contains(.option), let onAlternateScroll {
            onAlternateScroll(Double(raw))
            return
        }
        if event.modifierFlags.contains(.shift), let onFineScroll {
            onFineScroll(Double(raw))
            return
        }

        onScroll?(Double(raw))
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + Double(event.magnification)
        guard factor > 0 else { return }
        onZoom?(factor, pixelLocation(of: event))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)

        if event.clickCount >= 2 {
            onDoubleClick?()
            // Un doppio clic non è l'inizio di un trascinamento: azzerare lo stato evita che il
            // rilascio successivo produca anche un clic singolo sul riquadro appena ingrandito.
            pressLocation = nil
            return
        }

        let flags = event.modifierFlags
        if flags.contains(.shift) {
            dragMode = .rotate
        } else if flags.contains(.option) {
            dragMode = .pan
        } else {
            dragMode = .tool
        }

        pressLocation = pixelLocation(of: event)
        lastPixelLocation = pressLocation
        accumulatedMovement = 0
        exceededClickSlop = false

        // `onDragBegan` significa «sta cominciando un gesto **dello strumento**», ed è lì che chi
        // sta sopra decide che cosa si è afferrato. Con ⌥ o ⇧ premuti il gesto è dichiaratamente
        // panoramica o rotazione: annunciarlo lo stesso faceva afferrare una maniglia del mirino
        // che poi nessuno muoveva, e con la mano libera posava un punto che il trascinamento non
        // avrebbe mai continuato.
        if dragMode == .tool {
            onDragBegan?(pressLocation ?? .zero)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressLocation != nil else { return }

        let points = pointDelta(of: event)
        accumulatedMovement += abs(points.width) + abs(points.height)
        if accumulatedMovement > Self.clickSlopPoints {
            exceededClickSlop = true
        }

        switch dragMode {
        case .tool:
            onDrag?(pixelLocation(of: event), pixelDelta(of: event))
        case .pan:
            onPan?(pixelDelta(of: event))
        case .rotate:
            onRotate?(points)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let wasToolGesture = dragMode == .tool
        defer {
            pressLocation = nil
            // Simmetrico all'inizio: si chiude solo ciò che si era annunciato aperto.
            if wasToolGesture { onDragEnded?() }
        }
        guard let pressLocation, !exceededClickSlop else { return }
        // Il clic si riferisce al punto della **pressione**, non del rilascio: se la mano ha
        // ceduto di un pixel, il mirino va dove si era mirato.
        onClick?(pressLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPixelLocation = pixelLocation(of: event)
    }

    override func rightMouseDragged(with event: NSEvent) {
        onWindowLevelDrag?(pixelDelta(of: event))
    }

    // Tasto centrale: panoramica, sempre disponibile qualunque sia lo strumento attivo. È la via
    // rapida per chi ha un mouse a tre tasti e non vuole tenere premuto un modificatore.
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        lastPixelLocation = pixelLocation(of: event)
        // Niente `onDragBegan`: il tasto centrale è sempre e solo panoramica, e non c'è nulla da
        // afferrare. Annunciarlo faceva credere a chi sta sopra che stesse cominciando un gesto
        // dello strumento — con la mano libera, un punto posato a ogni panoramica.
    }

    override func otherMouseDragged(with event: NSEvent) {
        onPan?(pixelDelta(of: event))
    }

    override func otherMouseUp(with event: NSEvent) {
        // Nulla da chiudere: il tasto centrale non apre alcun gesto dello strumento.
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(pixelLocation(of: event))
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(nil)
    }
}
