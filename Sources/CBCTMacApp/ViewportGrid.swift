import CephKit
import DICOMCore
import MeasureKit
import SegmentKit
import StudyKit
import SwiftUI
import VolumeKit

// Griglia dei riquadri e interazione.
//
// Qui vive la conversione fra clic e millimetri, che è il punto in cui un errore smette di
// essere estetico e diventa una misura sbagliata. Tutte le conversioni passano da
// `MPRPlane.patientPoint(atPixelX:y:...)` e dalla sua inversa `pixelPosition(ofPatient:...)`:
// non se ne scrivono altre, nemmeno per comodità locale.

struct ViewportGrid: View {

    @Bindable var model: AppModel

    /// Dove cadono i divisori della griglia, in frazione della finestra, ricordati fra le
    /// sessioni. Frazioni e non punti: ridimensionando la finestra le proporzioni si conservano,
    /// mentre misure fisse lascerebbero un riquadro schiacciato e uno enorme.
    @AppStorage("grid.splitX") private var gridSplitX = 0.5
    @AppStorage("grid.splitY") private var gridSplitY = 0.5
    @AppStorage("grid.sideWidth") private var sideWidth = 260.0

    var body: some View {
        Group {
            switch model.layout {
            case .single:
                viewport(model.focusedSlot)

            case .grid2x2:
                GeometryReader { geometry in
                    let width = Double(geometry.size.width)
                    let height = Double(geometry.size.height)
                    let left = max(width * gridSplitX, 120)
                    let top = max(height * gridSplitY, 120)

                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            viewport(.axial).frame(width: CGFloat(left))
                            columnDivider(width: width)
                            viewport(.coronal)
                        }
                        .frame(height: CGFloat(top))

                        rowDivider(height: height)

                        HStack(spacing: 0) {
                            viewport(.sagittal).frame(width: CGFloat(left))
                            columnDivider(width: width)
                            viewport(.volume3D)
                        }
                    }
                }

            case .onePlusThree:
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        viewport(model.focusedSlot)
                            .frame(maxWidth: .infinity)
                        DraggableDivider(
                            axis: .vertical, value: $sideWidth,
                            range: 160...max(Double(geometry.size.width) * 0.6, 200))
                        VStack(spacing: Metrics.viewportGap) {
                            ForEach(ViewportSlot.allCases.filter { $0 != model.focusedSlot }) {
                                slot in
                                viewport(slot)
                            }
                        }
                        .frame(width: CGFloat(sideWidth))
                    }
                }

            case .panoramic:
                // Ha una disposizione tutta sua, con il proprio riempimento.
                PanoramicWorkspace(model: model)
            }
        }
        .padding(model.layout == .panoramic ? 0 : Metrics.viewportGap)
        .background(Palette.viewportBackground)
    }

    private func viewport(_ slot: ViewportSlot) -> some View {
        ViewportContainer(model: model, slot: slot)
    }

    /// Divisore verticale della griglia. Ne compaiono due, uno per riga, e muovono **la stessa**
    /// frazione: due colonne non allineate fra la riga di sopra e quella di sotto renderebbero
    /// impossibile confrontare due viste incolonnate, che è metà del motivo per cui si guarda una
    /// griglia invece di quattro finestre.
    private func columnDivider(width: Double) -> some View {
        DraggableDivider(
            axis: .vertical,
            value: Binding(
                get: { gridSplitX * width },
                set: { gridSplitX = min(max($0 / max(width, 1), 0.15), 0.85) }),
            range: 0...max(width, 1),
            isInverted: true)
    }

    private func rowDivider(height: Double) -> some View {
        DraggableDivider(
            axis: .horizontal,
            value: Binding(
                get: { gridSplitY * height },
                set: { gridSplitY = min(max($0 / max(height, 1), 0.15), 0.85) }),
            range: 0...max(height, 1),
            isInverted: true)
    }
}

// MARK: - Un riquadro

struct ViewportContainer: View {

    @Bindable var model: AppModel
    let slot: ViewportSlot

    /// Dimensione del drawable in pixel, riportata dal coordinatore Metal.
    ///
    /// Serve a rendere esatta la conversione fra clic e millimetri. Usare le dimensioni in punti
    /// funzionerebbe quasi, perché il rapporto è lo stesso, ma lo scarto di mezzo campione fra
    /// punti e pixel sposterebbe le sovraimpressioni rispetto all'immagine.
    @State private var pixelSize: CGSize = .zero

    /// Dimensione del riquadro in punti. Serve a convertire i pixel degli eventi nello spazio in
    /// cui le sovraimpressioni disegnano, così ciò che si vede e ciò che si afferra coincidono.
    @State private var pointSize: CGSize = .zero

    /// Presa sul mirino in corso, decisa alla pressione.
    ///
    /// # Perché l'interazione del mirino sta **qui** e non nella sua sovraimpressione
    ///
    /// Ci stava, con un `Color.clear` e un `DragGesture` di SwiftUI, e non funzionava: le
    /// maniglie si disegnavano e non rispondevano. La ragione è che sotto c'è un `MTKView`, cioè
    /// una `NSView` vera, e AppKit consegna il mouse alla vista più profonda sotto il puntatore.
    /// Una sovraimpressione SwiftUI disegnata sopra non è un'altra `NSView`: è un livello della
    /// stessa, e il gesto non riceve mai niente.
    ///
    /// Da qui la regola per tutto ciò che sta dentro un riquadro: **un solo percorso di eventi**,
    /// quello di `InteractiveMetalView`, che è anche l'unico provato dall'uso. Un secondo percorso
    /// che sembra funzionare e non funziona costa più di quanto risparmi.
    @State private var crosshairDrag: CrosshairDrag?

    /// Pressione e ultimo punto di un trascinamento in corso, in pixel del drawable.
    ///
    /// Servono a far funzionare **col trascinamento** gli strumenti a due punti — distanza, ROI
    /// ellittica, sferica, profilo, freccia. Il suggerimento della ROI ellittica prometteva già
    /// «trascina dal centro verso il bordo» e il codice chiedeva due clic: la promessa era
    /// giusta, mancava l'attuazione. Adesso valgono entrambe le vie, che è la convenzione di
    /// qualunque visore: chi trascina ottiene la forma, chi preferisce mirare due volte pure.
    @State private var twoPointDrag: (start: CGPoint, last: CGPoint)?

    /// Lato del riquadro di lettura afferrato in questo riquadro.
    @State private var clipEdge: CropBoxEdge?

    private struct CrosshairDrag {
        let represented: ViewportSlot
        let grip: CrosshairGrip
        var lastPoint: PixelPoint
        let isIndependent: Bool
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                metalContent
                    .onAppear { pointSize = geometry.size }
                    .onChange(of: geometry.size) { _, new in pointSize = new }

                // La curva dell'arcata si vede e si disegna sull'assiale, dove il suo andamento
                // corrisponde a quello che si ha davanti agli occhi.
                //
                // La condizione comprende il caso in cui la curva **non** esiste ancora, e prima
                // no: era `model.archCurve.isUsable`, quindi senza curva l'overlay non compariva e
                // non c'era nulla su cui cliccare per crearne una. Combinato con la curva imposta
                // all'apertura, l'unica azione possibile era spostare i punti di quella — da cui
                // l'impressione di non poter intervenire.
                if slot == .axial,
                    model.archCurve.isUsable || model.isEditingArch
                        || model.activeTool == .archCurve
                {
                    ArchCurveOverlay(
                        model: model,
                        plane: model.planes[slot],
                        pixelSize: pixelSize)
                }

                // Il riquadro di lettura, sopra l'immagine e sotto tutto il resto: è una
                // cornice, non un oggetto del piano, e non deve coprire ciò su cui si lavora.
                if model.clipBox.isActive, let plane = adjustedPlane,
                    slot.anatomicalPlane != nil
                {
                    CropBoxOverlay(
                        regionMM: BoxMM(
                            minMM: model.clipBox.minMM, maxMM: model.clipBox.maxMM),
                        viewPlane: plane,
                        grabbedEdge: clipEdge)
                }

                if slot.anatomicalPlane != nil {
                    // Niente `pixelSize` qui: la sovraimpressione lavora nello spazio in punti
                    // del riquadro, e dichiarare la stessa griglia sia per proiettare sia per
                    // ricevere i clic è ciò che la rende esatta. Passarle i pixel del drawable
                    // introdurrebbe un fattore di scala fra ciò che disegna e ciò che tocca.
                    CrosshairOverlay(model: model, slot: slot)

                    AnnotationOverlay(
                        model: model,
                        slot: slot,
                        pointSize: geometry.size,
                        pixelSize: pixelSize,
                        pendingPointsMM: model.toolSession.pointsMM)

                    // I marcatori di tessuto sotto gli oggetti del piano: sono punti di lavoro,
                    // non parti del progetto, e non devono coprire un impianto.
                    if !model.tissueSeeds.isEmpty {
                        TissueSeedOverlay(model: model, plane: model.planes[slot])
                    }

                    ImplantOverlay(model: model, plane: model.planes[slot])

                    // I denti sopra gli impianti: la sagoma è tratteggiata e leggera, e sotto
                    // la silhouette piena di un impianto sparirebbe proprio dove serve
                    // guardarli insieme.
                    ProstheticToothOverlay(model: model, plane: model.planes[slot])

                    // Il contorno della scansione sopra l'anatomia: è così che si giudica una
                    // registrazione, guardando se segue lo smalto.
                    if model.isScanVisible, model.scan != nil {
                        MeshContourOverlay(model: model, slot: slot)
                    }

                    // Il contorno della segmentazione, con il suo colore: quello predefinito
                    // dice la qualità della registrazione, che per una segmentazione non
                    // significa niente — non è registrata a nulla, viene dai voxel di questo
                    // stesso volume.
                    if let loops = model.segmentationContours[slot] {
                        MeshContourOverlay(
                            model: model,
                            explicitLoops: loops,
                            explicitPlane: model.planes[slot],
                            colourOverride: Palette.segmentation)
                    }

                    // I reperi cefalometrici e il profilo del viso, sopra i contorni: sono
                    // punti da centrare, e un contorno che ci passa sopra nasconde proprio ciò
                    // che si sta cercando di collocare.
                    if model.activeTool == .cephalometry || !model.cephTracing.isEmpty
                        || model.faceProfile != nil
                    {
                        CephOverlay(model: model, plane: model.planes[slot], slot: slot)
                    }

                    // I tre punti del piano occlusale, che stanno a quote diverse: senza vedere
                    // dove sono i primi due non si può giudicare dove mettere il terzo.
                    if model.activeTool == .occlusalPlane || !model.occlusalPointsMM.isEmpty {
                        OcclusalPlaneOverlay(model: model, plane: model.planes[slot])
                    }

                    // Le etichette per ultime, sopra tutti i disegni: sono ciò che si legge, e
                    // una linea che ci passa sopra le rende illeggibili. Vedi `LabelOverlay` per
                    // il motivo per cui stanno tutte in un solo strato.
                    LabelOverlay(model: model, slot: slot)
                }

                ViewportChrome(model: model, slot: slot, pointSize: geometry.size)

                // I pulsanti stanno **sopra** la sovraimpressione, non dentro: quella non riceve
                // i clic per lasciarli passare all'immagine, questi devono riceverli.
                VStack {
                    HStack {
                        Spacer()
                        ViewportActions(model: model, slot: slot)
                    }
                    Spacer()
                }
            }
            .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
            .overlay(alignment: .top) {
                // Il bordo colorato in alto identifica il piano a colpo d'occhio, come nei
                // mockup e con la stessa convenzione cromatica del mirino.
                Rectangle()
                    .fill(slot.accentColor)
                    .frame(height: Metrics.viewportBorderWidth)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                    .stroke(
                        model.focusedSlot == slot ? slot.accentColor.opacity(0.5) : .clear,
                        lineWidth: 1)
            }
            .onTapGesture { model.focusedSlot = slot }
        }
    }

    // MARK: Contenuto

    @ViewBuilder
    private var metalContent: some View {
        if slot.anatomicalPlane != nil {
            MPRViewportView(
                plane: model.planes[slot],
                volumeTexture: model.volumeTexture,
                renderer: model.mprRenderer,
                windowLevel: model.windowLevel,
                clip: model.activeClipBox,
                renderScale: model.mprResolution.scale,
                onScroll: { steps in
                    model.focusedSlot = slot
                    model.scroll(slot: slot, steps: steps)
                },
                onZoom: { factor, anchor in
                    model.focusedSlot = slot
                    model.zoom(
                        slot: slot, factor: factor, atPixel: anchor, pixelSize: pixelSize)
                },
                onDrag: handleDrag,
                onPan: handlePan,
                onRotate: handleRotate,
                onWindowLevelDrag: handleWindowLevelDrag,
                onClick: handleClick,
                onHover: handleHover,
                onDoubleClick: {
                    model.focusedSlot = slot
                    // Con una misura a più punti in corso il doppio clic la **chiude**, e non
                    // ingrandisce il riquadro: sono due significati per lo stesso gesto, e quello
                    // che conta è quello che l'utente sta facendo adesso.
                    if model.closeToolSession() { return }
                    model.layout = model.layout == .single ? .grid2x2 : .single
                },
                onDragBegan: handleDragBegan,
                onDragEnded: {
                    model.endHandleDrag()
                    model.endObjectDrag()
                    finishTwoPointDrag()

                    // Un tracciato a mano libera si chiude alzando il dito: è il gesto con cui
                    // chiunque smette di disegnare, e chiedere in più un doppio clic sarebbe un
                    // passo che nessuno si aspetta.
                    if model.activeTool == .freehand {
                        model.closeToolSession()
                    }
                    // Le sezioni si ricostruiscono al rilascio e non durante il trascinamento:
                    // ricampionare la spline e rigenerare cento piani a ogni movimento del mouse
                    // renderebbe il gesto viscoso.
                    if archDragIndex != nil { model.rebuildCrossSections() }
                    crosshairDrag = nil
                    archDragIndex = nil
                    clipEdge = nil
                    model.setDraggingCutLines(false)
                },
                onCancel: { model.cancelToolSession() },
                onDrawableSize: { pixelSize = $0 }
            )
        } else {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    volume3D

                    // Le cornici dei piani disegnate dentro il volume: è ciò che lega il 3D
                    // alle altre tre viste. Vedi `Volume3DOverlay`.
                    Volume3DOverlay(model: model)

                    OrientationCube(camera: model.camera)
                        .padding(Metrics.spacing)
                        .padding(.top, Metrics.viewportBorderWidth)
                }
                // L'editor della transfer function sta sotto il rendering, non in una finestra
                // separata: si regola guardando il risultato cambiare.
                TransferFunctionEditor(model: model)
            }
        }
    }

    private var volume3D: some View {
        Volume3DViewportView(
            camera: model.camera,
            volumeTexture: model.volumeTexture,
            raycaster: model.raycaster,
            transferFunction: model.transferFunction,
            quality: model.effectiveQuality,
            lighting: model.lighting,
            clip: model.activeClipBox,
            onOrbit: { delta in
                model.focusedSlot = slot
                model.orbit(byPixels: delta)
            },
            onMagnify: { factor in
                model.zoom3D(by: factor)
            },
            onInteractionChanged: { active in
                model.isInteractingWith3D = active
                // Il gesto è finito: si chiude anche il trascinamento dell'oggetto, se ce n'era
                // uno. Senza, l'impianto resterebbe agganciato al puntatore fino alla pressione
                // successiva.
                if !active { model.endVolume3DDrag() }
            },
            onGrab: { point in
                model.focusedSlot = slot
                return model.beginVolume3DDrag(atPixel: point, pixelSize: pixelSize)
            },
            onGrabbedDrag: { point in
                model.dragVolume3D(toPixel: point, pixelSize: pixelSize)
            },
            // Un clic nel 3D posa un punto del piano occlusale, e soltanto quello.
            //
            // È l'unica vista che non ha un piano, quindi la profondità di un clic non è data:
            // la decide l'anatomia, avanzando lungo il raggio fino alla prima superficie. Per
            // gli altri strumenti non si fa, e non è una dimenticanza — una misura presa su
            // «la prima cosa che il raggio incontra» dipenderebbe dalla soglia e dall'angolo di
            // vista, cioè non sarebbe una misura.
            onClick: { point in
                model.focusedSlot = slot
                guard model.activeTool == .occlusalPlane else {
                    // Un'uscita muta era già di per sé il difetto: chi prende l'impianto, clicca
                    // sul volume e non vede niente conclude che lo strumento è rotto, non che
                    // quella vista non è il posto giusto. Costa una riga dirlo.
                    if model.activeTool != .navigate {
                        model.lastActionMessage =
                            "\(model.activeTool.localizedName): nel riquadro 3D un clic non ha "
                            + "una profondità: il raggio attraversa mezzo cranio. Usa "
                            + "l'assiale, la coronale, la sagittale o una sezione."
                    }
                    return
                }
                model.placeOcclusalPointFrom3D(atPixel: point, pixelSize: pixelSize)
            },
            onDrawableSize: { pixelSize = $0 }
        )
    }

    // MARK: Conversioni

    /// Piano corrente con proporzioni adattate ai pixel reali.
    private var adjustedPlane: MPRPlane? {
        guard let plane = model.planes[slot], pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }
        var configured = plane
        configured.slabThicknessMM = model.slabThicknessMM
        configured.projection = model.projection
        return configured.matchingAspect(
            pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    private func patientPoint(atPixel point: CGPoint) -> Vec3? {
        guard let plane = adjustedPlane else { return nil }
        return plane.patientPoint(
            atPixelX: Double(point.x),
            y: Double(point.y),
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height))
    }

    // MARK: Gesti

    private func handleClick(_ point: CGPoint) {
        model.focusedSlot = slot
        // Una pressione su una maniglia che non si è mossa non è un clic sull'immagine: senza
        // questo, sfiorare una maniglia sposterebbe il mirino invece di non fare nulla.
        guard crosshairDrag == nil else { return }

        // Stessa ragione per un impianto o un dente afferrato, e qui il difetto era peggio.
        //
        // `mouseUp` emette il clic **prima** di chiudere il trascinamento, quindi un clic senza
        // movimento su un impianto arrivava fin qui. Con lo strumento impianto in mano lo
        // afferrava *e* ne posava uno nuovo nello stesso punto: due impianti sovrapposti, di cui
        // il secondo invisibile perché coperto dal primo. Con lo strumento dente lo stesso, e da
        // oggi che i denti si afferrano sarebbe stato il doppio dei casi.
        guard clipEdge == nil else { return }
        guard !model.isDraggingObject else { return }
        guard model.annotationDrag == nil, model.nerveDrag == nil else { return }

        guard let patient = patientPoint(atPixel: point) else { return }

        // Disegno dell'arcata: un solo gesto per tre azioni, distinte da ciò che l'utente fa e
        // non da modalità da scegliere prima — clic su un punto lo seleziona, ⌥ clic lo cancella,
        // clic nel vuoto ne posa uno nuovo nella posizione giusta dell'ordine di percorrenza.
        if isEditingArch, let plane = adjustedPlane {
            let index = ArchCurveOverlay.nearestControl(
                in: model.archCurve, to: point, plane: plane,
                width: Int(pixelSize.width), height: Int(pixelSize.height))
            let optionHeld = NSEvent.modifierFlags.contains(.option)
            if let index {
                if optionHeld {
                    model.removeArchPoint(at: index)
                } else {
                    model.selectedArchPointIndex = index
                }
                return
            }
            // ⌥ nel vuoto non fa nulla: cancellare è un'azione che deve colpire un bersaglio.
            guard !optionHeld else { return }
            model.addArchPoint(at: patient)
            return
        }

        // ⌥ clic su un nodo del nervo lo toglie: lo stesso gesto della curva d'arcata, perché è
        // la stessa operazione — togliere un punto da una polilinea tracciata a mano — e due
        // gesti diversi per la stessa cosa sono uno da ricordare in più.
        if NSEvent.modifierFlags.contains(.option),
            model.removeNerveNode(near: patient, toleranceMM: grabToleranceMM)
        {
            return
        }

        // E ⌥ clic su un repere cefalometrico lo toglie, per la stessa ragione: nell'intero
        // programma ⌥ vuol dire togliere, e uno strumento che facesse eccezione costringerebbe
        // a ricordare dove vale la regola.
        //
        // La ricerca è in **pixel** e non in millimetri, come per la curva d'arcata: un repere a
        // quindici millimetri dal piano è disegnato — sbiadito, ma lì — e con una tolleranza nello
        // spazio un ⌥ clic proprio sopra di esso non lo troverebbe.
        // ⌥ clic su un punto del piano occlusale lo toglie: la regola di tutto il programma.
        if model.activeTool == .occlusalPlane, NSEvent.modifierFlags.contains(.option) {
            if let plane = adjustedPlane,
                let index = OcclusalPlaneOverlay.nearest(
                    in: model.occlusalPointsMM, to: point, plane: plane,
                    width: Int(pixelSize.width), height: Int(pixelSize.height))
            {
                model.removeOcclusalPoint(at: index)
            }
            return
        }

        if model.activeTool == .cephalometry, NSEvent.modifierFlags.contains(.option) {
            if let plane = adjustedPlane {
                let hit = CephOverlay.nearest(
                    in: model.cephTracing, to: point, plane: plane,
                    width: Int(pixelSize.width), height: Int(pixelSize.height))
                if let hit { model.removeCephPoint(hit) }
            }
            // Si esce comunque: ⌥ non segna. Cancellare deve colpire un bersaglio, e un ⌥ clic a
            // vuoto che posasse un repere sarebbe l'opposto di quel che si voleva.
            return
        }

        // Da qui in poi lo strumento è dell'applicazione, non del riquadro: la conversione in
        // millimetri l'ha fatta questa vista, che è l'unica a conoscere il proprio piano, e il
        // resto vale identico ovunque. Vedi `AppModel.applyToolClick`.
        model.applyToolClick(at: patient, anchor: toolAnchor())
    }

    /// Chiude un trascinamento a due punti, se c'è stato movimento a sufficienza.
    ///
    /// La soglia è la stessa che distingue un clic da un trascinamento in `InteractiveMetalView`:
    /// sotto quella il rilascio è già arrivato come clic, e trattarlo anche come trascinamento
    /// creerebbe due misure per un gesto solo.
    private func finishTwoPointDrag() {
        guard let drag = twoPointDrag else { return }
        twoPointDrag = nil

        let moved = abs(drag.last.x - drag.start.x) + abs(drag.last.y - drag.start.y)
        let scale = pointSize.width > 0 ? pixelSize.width / pointSize.width : 1
        guard moved > InteractiveMetalView.clickSlopPoints * max(scale, 1) else { return }

        guard let start = patientPoint(atPixel: drag.start),
            let end = patientPoint(atPixel: drag.last)
        else { return }

        let anchor = toolAnchor()
        model.applyToolClick(at: start, anchor: anchor)
        model.applyToolClick(at: end, anchor: anchor)
    }

    /// Quanto lontano dalla superficie di un impianto si può premere per afferrarlo.
    ///
    /// In millimetri, ma **derivata dai pixel**: sei pixel di schermo, convertiti alla scala
    /// corrente del riquadro. Una tolleranza fissa in millimetri sarebbe impossibile da centrare
    /// su una vista d'insieme — dove sei millimetri sono pochi pixel — e prenderebbe mezzo
    /// riquadro su una vista molto ingrandita.
    private var grabToleranceMM: Double {
        guard let plane = adjustedPlane, pixelSize.width > 0 else { return 1 }
        return plane.widthMM / Double(pixelSize.width) * 6
    }

    /// Il piano di questo riquadro, per ancorarci la misura che comincia qui.
    private func toolAnchor() -> ToolAnchor? {
        guard let plane = adjustedPlane, let geometry = model.volume?.geometry else { return nil }
        let spacing = geometry.spacingMM
        return ToolAnchor(
            originMM: plane.centerMM,
            normalMM: plane.normalMM,
            rightMM: plane.rightMM,
            downMM: plane.downMM,
            visibilityToleranceMM: max(spacing.x, max(spacing.y, spacing.z)) * 2)
    }

    // MARK: Mirino

    /// Piano del riquadro nello **spazio in punti**, che è quello in cui le sovraimpressioni
    /// disegnano. Le tracce del mirino si calcolano qui perché ciò che si vede e ciò che si
    /// afferra devono essere la stessa geometria.
    private var overlayPlane: MPRPlane? {
        guard let plane = model.planes[slot], pointSize.width > 1, pointSize.height > 1 else {
            return nil
        }
        return plane.matchingAspect(
            pixelWidth: Int(pointSize.width), pixelHeight: Int(pointSize.height))
    }

    /// Dal punto di un evento, che è in pixel del drawable, al punto in unità di riquadro.
    private func overlayPoint(fromPixel point: CGPoint) -> PixelPoint? {
        guard pixelSize.width > 0, pointSize.width > 0 else { return nil }
        let scale = pixelSize.width / pointSize.width
        guard scale > 0 else { return nil }
        return PixelPoint(x: Double(point.x / scale), y: Double(point.y / scale))
    }

    private func crosshairTraces() -> [(slot: ViewportSlot, trace: CrosshairTrace)] {
        guard let view = overlayPlane, slot.anatomicalPlane != nil else { return [] }
        return ViewportSlot.allCases.compactMap { other in
            guard other != slot, other.anatomicalPlane != nil,
                let plane = model.planes[other],
                let trace = CrosshairGeometry.trace(
                    of: plane, in: view, through: model.crosshairMM,
                    pixelWidth: Int(pointSize.width), pixelHeight: Int(pointSize.height))
            else { return nil }
            return (other, trace)
        }
    }

    /// Punto di controllo dell'arcata afferrato, se c'è.
    @State private var archDragIndex: Int?

    /// Decide alla pressione se si è afferrata una linea del mirino, e quale parte.
    private func handleDragBegan(_ pixelPoint: CGPoint) {
        crosshairDrag = nil
        archDragIndex = nil
        twoPointDrag = nil

        // # Che cosa vale in sola lettura
        //
        // Il guard sul modo modificabile stava **qui in cima** e comprendeva tutto, mirino
        // incluso: in «Rivedi» non si poteva nemmeno cambiare fetta trascinando una linea.
        // Navigare non è modificare. Da qui in giù stanno le prese che toccano il piano, e
        // quelle sì valgono solo dove si può modificarlo; il mirino sta in fondo e vale sempre.
        if model.workMode.isEditable {
            if beginPlanDrag(at: pixelPoint) { return }
        }

        // Mirino, in qualunque modo di lavoro.
        guard model.activeTool == .navigate, let point = overlayPoint(fromPixel: pixelPoint)
        else { return }
        beginCrosshairDrag(at: point)
    }

    /// Prova ad afferrare un lato del riquadro di lettura.
    ///
    /// Prima di tutto il resto: è una cornice, ci si preme sopra apposta, e se la contendesse a
    /// un impianto che le sta accanto vincerebbe l'impianto — che è il contrario di quel che si
    /// sta chiedendo. Fuori dai lati non afferra niente e lascia passare il gesto.
    private func beginClipDrag(at pixelPoint: CGPoint) -> Bool {
        clipEdge = nil
        guard model.clipBox.isActive, let plane = adjustedPlane,
            pixelSize.width > 1, pixelSize.height > 1
        else { return false }

        let frame = CropBoxOverlay.frame(of: plane, size: pixelSize)
        let rect = CropBoxGeometry.rect(
            of: BoxMM(minMM: model.clipBox.minMM, maxMM: model.clipBox.maxMM),
            in: frame,
            width: Double(pixelSize.width), height: Double(pixelSize.height))
        let slop = Double(max(pixelSize.width, pixelSize.height)) * 0.02

        clipEdge = CropBoxGeometry.edge(
            nearX: Double(pixelPoint.x), y: Double(pixelPoint.y), of: rect, slop: slop)
        if clipEdge != nil { model.focusedSlot = slot }
        return clipEdge != nil
    }

    /// Continua il trascinamento di un lato del riquadro di lettura.
    private func dragClip(to pixelPoint: CGPoint) {
        guard let edge = clipEdge, let plane = adjustedPlane,
            pixelSize.width > 1, pixelSize.height > 1
        else { return }
        let frame = CropBoxOverlay.frame(of: plane, size: pixelSize)
        let valueMM = CropBoxGeometry.millimetres(
            atX: Double(pixelPoint.x), y: Double(pixelPoint.y), for: edge, in: frame,
            width: Double(pixelSize.width), height: Double(pixelSize.height))
        model.moveClipFace(CropBoxGeometry.face(for: edge, in: frame), toMM: valueMM)
    }

    /// Prova ad afferrare qualcosa che appartiene al piano. Restituisce vero se ci riesce.
    private func beginPlanDrag(at pixelPoint: CGPoint) -> Bool {
        if beginClipDrag(at: pixelPoint) { return true }

        // # ⌥ non afferra
        //
        // In tutto il programma ⌥ clic significa **togli**: un punto d'arcata, un nodo del
        // nervo. Afferrare l'oggetto alla pressione impedirebbe al clic di arrivare a chi lo
        // cancella, e il gesto smetterebbe di funzionare — cosa che sarebbe successa appena
        // aggiunta la guardia contro il clic fantasma, senza che nessun test se ne accorgesse.
        //
        // Il modificatore si legge una volta alla pressione, come ovunque qui: rilasciarlo a
        // metà gesto non deve cambiare il significato di ciò che si è cominciato.
        guard !NSEvent.modifierFlags.contains(.option) else { return false }

        // Le maniglie delle misure e i nodi dei nervi vengono per primi: sono più piccoli di un
        // impianto e stanno spesso sopra di esso, quindi dando la precedenza all'impianto
        // resterebbero irraggiungibili. Valgono con qualunque strumento in mano, perché
        // correggere è un'operazione che non appartiene a uno strumento in particolare.
        if let patient = patientPoint(atPixel: pixelPoint),
            model.beginHandleDrag(at: patient, toleranceMM: grabToleranceMM)
        {
            model.focusedSlot = slot
            return true
        }

        // Un oggetto del piano afferrato viene prima di tutto il resto: chi preme sul corpo di
        // un impianto o di un dente sta spostando quello, non misurando né spostando il mirino.
        // Solo con la navigazione o con uno strumento di posa in mano, però — con un righello in
        // mano il gesto appartiene al righello, e afferrare l'impianto lo renderebbe impossibile
        // da misurare.
        if model.activeTool == .navigate || model.activeTool == .implant
            || model.activeTool == .prostheticTooth,
            let patient = patientPoint(atPixel: pixelPoint),
            model.beginObjectDrag(at: patient, toleranceMM: grabToleranceMM)
        {
            model.focusedSlot = slot
            return true
        }

        // La mano libera: mentre si disegna un contorno il trascinamento **è** il disegno, e non
        // deve significare anche pan o presa del mirino.
        if model.activeTool == .freehand {
            model.focusedSlot = slot
            if let patient = patientPoint(atPixel: pixelPoint) {
                model.appendFreehandPoint(at: patient, anchor: toolAnchor())
            }
            return true
        }

        // La curva prima della misura: un punto d'arcata afferrato è ciò che si vuole spostare,
        // e con un righello in mano il trascinamento a due punti gli passava davanti — si posava
        // una misura invece di muovere il punto.
        if isEditingArch, let plane = adjustedPlane {
            archDragIndex = ArchCurveOverlay.nearestControl(
                in: model.archCurve, to: pixelPoint, plane: plane,
                width: Int(pixelSize.width), height: Int(pixelSize.height))
            if archDragIndex != nil { return true }
        }

        // Uno strumento a due punti con la sessione vuota: si annota la pressione e **non** si
        // posa nulla. Posare qui il primo punto significherebbe che un clic fermo ne produce due
        // coincidenti, cioè una misura lunga zero — il rilascio senza movimento passa da
        // `onClick`, che è la via giusta per chi mira invece di trascinare.
        if model.activeToolShape == .twoPoints, model.toolSession.isEmpty {
            twoPointDrag = (pixelPoint, pixelPoint)
            return true
        }

        return false
    }

    /// Decide quale linea del mirino si è afferrata, e come.
    private func beginCrosshairDrag(at point: PixelPoint) {
        // Nascoste vuol dire anche non afferrabili. Vedi `AppModel.areCutLinesGrabbable`.
        guard model.areCutLinesGrabbable else { return }

        // La più vicina fra tutte, non la prima che risponde: vicino all'incrocio le due linee
        // sono entrambe a portata, e prendere la prima dell'elenco significherebbe afferrare
        // sempre la stessa qualunque cosa si stia indicando.
        var best: (ViewportSlot, CrosshairGrip, Double)?
        for item in crosshairTraces() {
            guard let grip = item.trace.grip(at: point) else { continue }
            let distance: Double
            switch grip {
            case .handle(let isStart):
                let handle = isStart ? item.trace.startHandle : item.trace.endHandle
                distance = handle.map { point.distance(to: $0) } ?? .greatestFiniteMagnitude
            case .line:
                distance = item.trace.distance(from: point)
            }
            if best == nil || distance < best!.2 { best = (item.slot, grip, distance) }
        }
        guard let best else { return }

        crosshairDrag = CrosshairDrag(
            represented: best.0, grip: best.1, lastPoint: point,
            isIndependent: NSEvent.modifierFlags.contains(.option))
        // Afferrata una linea, tutte tornano piene: si sta puntando, e una traccia al venti per
        // cento non si segue. Vale anche per le altre viste, dove si guarda dove si sta finendo.
        model.setDraggingCutLines(true)
    }

    /// Applica il trascinamento a una linea del mirino. Restituisce falso se non c'è presa.
    private func dragCrosshair(to pixelPoint: CGPoint) -> Bool {
        guard var active = crosshairDrag,
            let point = overlayPoint(fromPixel: pixelPoint),
            let item = crosshairTraces().first(where: { $0.slot == active.represented })
        else { return false }

        switch active.grip {
        case .handle:
            if let angle = item.trace.rotation(from: active.lastPoint, to: point) {
                if active.isIndependent {
                    model.rotatePlane(
                        active.represented, aboutAxis: item.trace.rotationAxisMM, byRadians: angle)
                } else {
                    // Difetto: ruotano entrambi i piani perpendicolari a questo, dello stesso
                    // angolo, quindi restano perpendicolari fra loro e le sezioni trasversali
                    // continuano ad avere senso. ⌥ scollega la linea afferrata dall'altra.
                    model.tiltPlanes(perpendicularTo: slot, byRadians: angle)
                }
            }
        case .line:
            guard let view = overlayPlane else { return true }
            let movement = item.trace.slide(
                from: active.lastPoint, to: point, in: view,
                pixelWidth: Int(pointSize.width), pixelHeight: Int(pointSize.height))
            model.moveCrosshair(to: model.crosshairMM + movement)
        }

        active.lastPoint = point
        crosshairDrag = active
        return true
    }

    /// Vero quando questo riquadro è quello su cui si disegna l'arcata.
    private var isEditingArch: Bool {
        slot == .axial && (model.isEditingArch || model.activeTool == .archCurve)
    }

    private func handleDrag(_ point: CGPoint, _ delta: CGSize) {
        // Il lato del riquadro di lettura afferrato viene prima di tutto: chi l'ha preso alla
        // pressione sta muovendo quello, e nient'altro.
        if clipEdge != nil {
            dragClip(to: point)
            return
        }

        // La mano libera: il trascinamento **è** il disegno, e viene prima di ogni altra
        // interpretazione del gesto.
        if model.activeTool == .freehand {
            if let patient = patientPoint(atPixel: point) {
                model.appendFreehandPoint(at: patient, anchor: toolAnchor())
            }
            return
        }

        if model.annotationDrag != nil || model.nerveDrag != nil {
            if let patient = patientPoint(atPixel: point) { model.dragHandle(toMM: patient) }
            return
        }

        if model.isDraggingObject {
            if let patient = patientPoint(atPixel: point) { model.dragObject(toMM: patient) }
            return
        }

        if twoPointDrag != nil {
            twoPointDrag?.last = point
            return
        }

        // Un punto dell'arcata afferrato ha la precedenza su tutto.
        if let index = archDragIndex, let patient = patientPoint(atPixel: point) {
            model.moveArchPoint(at: index, to: patient)
            return
        }
        // Poi il mirino: se si è afferrata una linea, trascinare deve ruotare o spostare quella,
        // non l'immagine sotto.
        if dragCrosshair(to: point) { return }

        // Con uno strumento di misura attivo il trascinamento appartiene allo strumento. La
        // panoramica resta comunque raggiungibile con ⌥ o col tasto centrale, che passano da
        // `handlePan` e non guardano lo strumento: un'immagine inchiodata mentre si misura era
        // la seconda causa di frustrazione dopo lo zoom non ancorato.
        guard model.activeTool == .navigate else { return }
        handlePan(delta)
    }

    /// Panoramica, sempre disponibile: ⌥ + trascinamento, o tasto centrale.
    private func handlePan(_ delta: CGSize) {
        guard let plane = adjustedPlane else { return }
        // Il pan si esprime in millimetri, non in pixel: si moltiplica lo spostamento per il
        // passo del pixel, così la panoramica resta coerente a qualunque zoom.
        let rightStep = plane.rightStepMM(pixelWidth: Int(pixelSize.width))
        let downStep = plane.downStepMM(pixelHeight: Int(pixelSize.height))
        let offset = rightStep * Double(-delta.width) + downStep * Double(-delta.height)
        model.pan(slot: slot, byMM: offset)
    }

    /// ⇧ + trascinamento: **inclina il taglio**, cioè ruota le linee del mirino.
    ///
    /// Dalle maniglie del mirino si ottiene la stessa inclinazione afferrando direttamente la
    /// linea, ed è la via che si scopre da sé. Questa resta perché è l'unica che funziona quando
    /// la linea è fuori dal riquadro — ingranditi su un molare, il mirino è spesso oltre il
    /// bordo, e allora non c'è nessuna maniglia da afferrare.
    ///
    /// Trascinando in orizzontale si ruotano i due piani perpendicolari a questo attorno alla sua
    /// normale: sull'assiale significa inclinare coronale e sagittale, che è il gesto con cui si
    /// va a guardare un ramo o l'asse di un dente incluso invece di accontentarsi di una fetta
    /// ortogonale che li taglia di sbieco.
    ///
    /// Il trascinamento **verticale** gira invece l'immagine nel proprio piano, senza cambiare
    /// fetta: serve a raddrizzare una testa inclinata. Due assi del gesto per due rotazioni
    /// diverse, e la distinzione è quella che conta — orizzontale cambia *cosa* si taglia,
    /// verticale cambia *come lo si guarda*.
    ///
    /// L'angolo viene dallo spostamento e non dall'angolo sotteso attorno al perno. Il gesto
    /// "afferra e gira" sarebbe più naturale ma ha una singolarità: col puntatore sopra il perno,
    /// uno spostamento di un pixel produce una rotazione arbitraria.
    private func handleRotate(_ delta: CGSize) {
        let horizontal = Double(delta.width) * InteractiveMetalView.rotationRadiansPerPoint
        let vertical = Double(delta.height) * InteractiveMetalView.rotationRadiansPerPoint

        if abs(delta.width) >= abs(delta.height) {
            model.tiltPlanes(perpendicularTo: slot, byRadians: horizontal)
        } else {
            model.rotate(slot: slot, byRadians: vertical)
        }
    }

    private func handleWindowLevelDrag(_ delta: CGSize) {
        model.adjustWindowLevel(byDelta: delta)
    }

    private func handleHover(_ point: CGPoint?) {
        model.updateHover(atPatient: point.flatMap { patientPoint(atPixel: $0) })
    }
}
