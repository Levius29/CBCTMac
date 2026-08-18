import DICOMCore
import MeasureKit
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

    var body: some View {
        Group {
            switch model.layout {
            case .single:
                viewport(model.focusedSlot)

            case .grid2x2:
                VStack(spacing: Metrics.viewportGap) {
                    HStack(spacing: Metrics.viewportGap) {
                        viewport(.axial)
                        viewport(.coronal)
                    }
                    HStack(spacing: Metrics.viewportGap) {
                        viewport(.sagittal)
                        viewport(.volume3D)
                    }
                }

            case .onePlusThree:
                HStack(spacing: Metrics.viewportGap) {
                    viewport(model.focusedSlot)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: Metrics.viewportGap) {
                        ForEach(ViewportSlot.allCases.filter { $0 != model.focusedSlot }) { slot in
                            viewport(slot)
                        }
                    }
                    .frame(width: 260)
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

    /// Primo estremo di una misura in corso.
    @State private var pendingStartMM: Vec3?

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
                        pendingStartMM: pendingStartMM)

                    ImplantOverlay(
                        model: model,
                        slot: slot,
                        plane: model.planes[slot])
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
                    model.layout = model.layout == .single ? .grid2x2 : .single
                },
                onDragBegan: handleDragBegan,
                onDragEnded: {
                    // Le sezioni si ricostruiscono al rilascio e non durante il trascinamento:
                    // ricampionare la spline e rigenerare cento piani a ogni movimento del mouse
                    // renderebbe il gesto viscoso.
                    if archDragIndex != nil { model.rebuildCrossSections() }
                    crosshairDrag = nil
                    archDragIndex = nil
                },
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
            onOrbit: { delta in
                model.focusedSlot = slot
                model.orbit(byPixels: delta)
            },
            onMagnify: { factor in
                model.zoom3D(by: factor)
            },
            onInteractionChanged: { active in
                model.isInteractingWith3D = active
            }
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

        switch model.activeTool {
        case .navigate:
            model.moveCrosshair(to: patient)

        case .archCurve:
            // Sugli altri riquadri il clic sposta il mirino, ed è ciò che serve mentre si
            // disegna: è così che si sceglie la fetta assiale su cui posare i punti, guardando la
            // cresta di profilo. Sull'assiale invece posa o seleziona, sotto.
            model.moveCrosshair(to: patient)

        case .distance:
            if let start = pendingStartMM {
                let measurement = DistanceMeasurement(
                    metadata: AnnotationMetadata(
                        colorHex: "#32B8C6",
                        referencePlane: referencePlane()),
                    startMM: start,
                    endMM: patient)
                model.addAnnotation(.distance(measurement))
                pendingStartMM = nil
            } else {
                pendingStartMM = patient
            }

        case .angle:
            // Richiede tre punti: si aggiungerà con la stessa logica a stati di `.distance`.
            model.moveCrosshair(to: patient)

        case .ellipseROI:
            if let start = pendingStartMM {
                let roi = makeEllipse(from: start, to: patient)
                model.addAnnotation(.ellipseROI(roi))
                pendingStartMM = nil
            } else {
                pendingStartMM = patient
            }

        case .sphereROI:
            if let start = pendingStartMM {
                let radius = start.distance(to: patient)
                guard radius > 0 else { return }
                let roi = SphereROI(
                    metadata: AnnotationMetadata(colorHex: "#FFD426"),
                    centerMM: start,
                    radiusMM: radius)
                model.addAnnotation(.sphereROI(roi))
                pendingStartMM = nil
            } else {
                pendingStartMM = patient
            }

        case .text:
            let note = TextNote(
                metadata: AnnotationMetadata(referencePlane: referencePlane()),
                anchorMM: patient,
                text: "Nota")
            model.addAnnotation(.text(note))

        case .implant:
            // L'asse predefinito è verticale verso il basso. Su una cresta inclinata andrà
            // corretto, ma partire dalla verticale è più prevedibile che indovinare
            // un'inclinazione dalla vista corrente.
            model.addImplant(at: patient)

        case .nerve:
            if model.tracingNerveID == nil {
                // Il lato si deduce dal segno di L: destra del paziente è x negativo in LPS.
                model.beginTracingNerve(side: patient.x < 0 ? .right : .left)
            }
            model.addNerveNode(at: patient)
        }
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
        guard model.workMode.isEditable else { return }

        // La curva viene prima del mirino: quando si sta disegnando l'arcata, i suoi punti sono
        // ciò che si vuole afferrare, e il mirino può aspettare.
        if isEditingArch, let plane = adjustedPlane {
            archDragIndex = ArchCurveOverlay.nearestControl(
                in: model.archCurve, to: pixelPoint, plane: plane,
                width: Int(pixelSize.width), height: Int(pixelSize.height))
            if archDragIndex != nil { return }
        }

        guard model.activeTool == .navigate, let point = overlayPoint(fromPixel: pixelPoint)
        else { return }

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
        // Convenzione radiologica diffusa: orizzontale regola l'ampiezza, verticale il livello.
        var wl = model.windowLevel
        wl.width = max(1, wl.width + Double(delta.width) * 4)
        wl.level += Double(-delta.height) * 4
        model.windowLevel = wl
    }

    private func handleHover(_ point: CGPoint?) {
        guard let point, let patient = patientPoint(atPixel: point) else {
            model.hoverPositionMM = nil
            model.hoverDensity = nil
            return
        }
        model.hoverPositionMM = patient
        // Campionamento nearest sui dati di CPU: il valore mostrato è un valore realmente
        // presente nel volume, non una media fra vicini.
        model.hoverDensity = model.volume?.densityValue(atPatient: patient)
    }

    // MARK: Costruzione delle annotazioni

    private func referencePlane() -> AnnotationPlaneReference? {
        guard let plane = adjustedPlane, let geometry = model.volume?.geometry else { return nil }
        let spacing = geometry.spacingMM
        return AnnotationPlaneReference(
            originMM: plane.centerMM,
            normalMM: plane.normalMM,
            visibilityToleranceMM: max(spacing.x, max(spacing.y, spacing.z)) * 2)
    }

    /// Ellisse inscritta nel rettangolo definito dai due punti, sul piano corrente.
    private func makeEllipse(from start: Vec3, to end: Vec3) -> EllipseROI {
        let plane = adjustedPlane
        let right = plane?.rightMM ?? Vec3(1, 0, 0)
        let down = plane?.downMM ?? Vec3(0, 1, 0)
        let diagonal = end - start
        let center = start.lerp(to: end, t: 0.5)
        let spacing = model.volume?.geometry.spacingMM ?? Vec3(1, 1, 1)

        return EllipseROI(
            metadata: AnnotationMetadata(colorHex: "#4FCB6B", referencePlane: referencePlane()),
            centerMM: center,
            semiAxisAMM: right * (diagonal.dot(right) * 0.5),
            semiAxisBMM: down * (diagonal.dot(down) * 0.5),
            thicknessMM: max(spacing.x, max(spacing.y, spacing.z)))
    }
}

