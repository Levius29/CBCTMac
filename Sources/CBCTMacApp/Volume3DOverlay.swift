import DICOMCore
import DentalKit
import ImplantKit
import MeshKit
import StudyKit
import SwiftUI
import VolumeKit

// Le cornici disegnate dentro il rendering tridimensionale.
//
// # A che serve
//
// Il riquadro 3D mostrava un volume che galleggiava da solo, senza alcun legame visibile con le
// tre viste accanto. Guardandolo non si poteva dire *dove* stessero tagliando: si intuiva dal
// contenuto delle altre viste, cioè si ricostruiva a mente ciò che il programma già sapeva.
//
// Disegnare i tre piani dentro il volume chiude l'anello. Il rettangolo rosso è la fetta assiale
// che si sta guardando, il verde la coronale, il giallo la sagittale — gli stessi tre colori dei
// bordi dei riquadri e delle linee del mirino. Muovendo una linea nell'assiale si vede il
// rettangolo corrispondente scorrere nel 3D, ed è quello il momento in cui le quattro viste
// diventano una cosa sola invece di quattro.
//
// # Perché sopra il Metal e non dentro
//
// Il raycaster compone volume e trasparenze in un solo passaggio di compute; infilarci dentro
// del disegno vettoriale significherebbe rasterizzare linee in un kernel che non è fatto per
// quello, oppure aggiungere un secondo passo di rendering con il suo depth buffer. Un `Canvas`
// sopra costa quattro righe e si prova; l'unica cosa che perde è l'occlusione esatta, che qui
// si approssima con la profondità del punto medio.
//
// # La cosa che deve essere esatta
//
// La proiezione dell'overlay e quella del raycaster devono coincidere, altrimenti le cornici
// galleggiano rispetto all'anatomia. Usano infatti la stessa base — `camera.right`, `down`,
// `forward` — e la stessa semilarghezza `halfHeight · larghezza/altezza`.
//
// Resta una differenza dichiarata: il raycaster punta al **centro** del pixel (`+ passo/2`
// nell'origine del raggio), `ScreenProjector` al suo bordo. È mezzo pixel del drawable, cioè un
// quarto di punto su uno schermo Retina. Non la correggo qui apposta: introdurrebbe una seconda
// convenzione accanto a quella di `ScreenProjector`, la cui `unproject` è oggi l'inversa esatta
// della sua `project`, e due convenzioni che differiscono per un quarto di punto sono il tipo di
// cosa che qualcuno «sistema» fra sei mesi rompendo l'altra.

struct Volume3DOverlay: View {

    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                guard size.width > 1, size.height > 1,
                    let volume = model.volume
                else { return }

                let projector = ScreenProjector(
                    camera: model.camera,
                    pixelWidth: Int(size.width),
                    pixelHeight: Int(size.height))

                // L'ordine è quello della profondità percepita: prima la gabbia, che è lo
                // sfondo, poi ciò che sta dentro. Disegnare la gabbia per ultima la farebbe
                // sembrare davanti all'anatomia.
                drawBoundingBox(&context, geometry: volume.geometry, projector: projector)
                drawArchBand(&context, projector: projector)
                drawPlanes(&context, geometry: volume.geometry, projector: projector)
                drawCurrentSection(&context, geometry: volume.geometry, projector: projector)
                drawNerves(&context, projector: projector)
                drawBars(&context, projector: projector)
                drawImplants(&context, projector: projector)
                drawTeeth(&context, projector: projector)
                // Le etichette per ultime, sopra ogni disegno: sono ciò che si legge, e una
                // linea che ci passa sopra le rende illeggibili. Stessa regola di `LabelOverlay`.
                drawLabels(&context, projector: projector)
            }
            // Sotto c'è il gesto di orbita, e questa sovraimpressione non deve rubarglielo.
            .allowsHitTesting(false)
        }
    }

    // MARK: La gabbia del volume

    private func drawBoundingBox(
        _ context: inout GraphicsContext, geometry: VolumeGeometry, projector: ScreenProjector
    ) {
        let edges = PlaneFrameGeometry.boundingBoxEdges(of: geometry, projector: projector)
        var visible = Path()
        var hidden = Path()
        for edge in edges {
            // Un `if` e non un ternario: `&hidden : &visible` non compila, perché un `inout` non
            // si può scegliere dentro un'espressione — Swift deve sapere staticamente quale
            // variabile si sta prendendo in prestito.
            if edge.isHidden {
                append(edge, to: &hidden)
            } else {
                append(edge, to: &visible)
            }
        }
        // Gli spigoli dietro sono tratteggiati e più deboli. È la convenzione del disegno
        // tecnico, e senza di essa una gabbia in fil di ferro è ambigua: lo stesso disegno si
        // legge come vista da sopra o da sotto, e l'occhio continua a ribaltarla.
        context.stroke(
            hidden, with: .color(Palette.textSecondary.opacity(0.30)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
        context.stroke(visible, with: .color(Palette.textSecondary.opacity(0.55)), lineWidth: 1)
    }

    // MARK: I tre piani

    private func drawPlanes(
        _ context: inout GraphicsContext, geometry: VolumeGeometry, projector: ScreenProjector
    ) {
        // Le cornici dei piani sono le linee di taglio viste da qui: seguono la stessa regola
        // delle tracce sui riquadri, perché sono la stessa informazione. Nasconderle di là e
        // lasciarle di qua vorrebbe dire che il pulsante nasconde metà di quel che promette.
        let visibility = model.cutLineVisibility
        guard visibility.drawsAnything else { return }
        let fade = visibility.opacity

        for slot in ViewportSlot.allCases {
            guard slot.anatomicalPlane != nil, let plane = model.planes[slot] else { continue }
            let segments = PlaneFrameGeometry.outline(
                of: plane, clippedTo: geometry, projector: projector)
            guard !segments.isEmpty else { continue }

            let color = slot.accentColor

            // Con uno slab spesso il piano non è una superficie ma una lastra, e disegnare una
            // sola cornice direbbe una cosa falsa: nel riquadro non si sta guardando quella
            // fetta, si sta guardando la media di venti millimetri attorno a essa. Le due facce
            // lo dicono, e a spessore nullo coincidono e non compare nulla di nuovo.
            if plane.slabThicknessMM > 0.01 {
                var faces = Path()
                for side in [0.5, -0.5] {
                    let face = plane.advanced(byMM: plane.slabThicknessMM * side)
                    for segment in PlaneFrameGeometry.outline(
                        of: face, clippedTo: geometry, projector: projector)
                    {
                        append(segment, to: &faces)
                    }
                }
                context.stroke(
                    faces, with: .color(color.opacity(0.30 * fade)),
                    style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
            var front = Path()
            var back = Path()
            for segment in segments {
                if segment.isHidden {
                    append(segment, to: &back)
                } else {
                    append(segment, to: &front)
                }
            }
            context.stroke(
                back, with: .color(color.opacity(0.35 * fade)),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            context.stroke(front, with: .color(color.opacity(0.95 * fade)), lineWidth: 1.5)

            // Una velatura appena percettibile dentro la cornice del riquadro attivo, per
            // distinguerlo dagli altri due senza aggiungere un'altra linea a un disegno che di
            // linee ne ha già molte.
            if slot == model.focusedSlot, let filled = filledPolygon(from: segments) {
                context.fill(filled, with: .color(color.opacity(0.07 * fade)))
            }
        }
    }

    /// Poligono chiuso dai segmenti, se formano davvero un contorno.
    ///
    /// Restituisce `nil` sul piano visto di taglio, che è un segmento solo: riempirlo non
    /// significherebbe nulla e produrrebbe una sottile riga colorata di traverso.
    private func filledPolygon(from segments: [ScreenSegment]) -> Path? {
        guard segments.count >= 3 else { return nil }
        var path = Path()
        path.move(to: CGPoint(x: segments[0].from.x, y: segments[0].from.y))
        for segment in segments {
            path.addLine(to: CGPoint(x: segment.to.x, y: segment.to.y))
        }
        path.closeSubpath()
        return path
    }

    // MARK: La banda dell'arcata

    private func drawArchBand(_ context: inout GraphicsContext, projector: ScreenProjector) {
        let curve = model.archCurve
        guard curve.isUsable else { return }

        // Sessanta campioni: la curva è una spline dolce e a questa scala la spezzata non si
        // distingue dalla curva, mentre il costo resta trascurabile a ogni fotogramma.
        let samples = curve.resampled(count: 60).map(\.positionMM)
        let segments = PlaneFrameGeometry.ribbon(
            alongMM: samples,
            upAxis: Vec3(0, 0, 1),
            halfHeightMM: max(model.panoramicHeightMM * 0.5, 1),
            projector: projector)

        var path = Path()
        for segment in segments { append(segment, to: &path) }
        context.stroke(path, with: .color(Palette.accent.opacity(0.7)), lineWidth: 1)
    }

    // MARK: La sezione trasversale in corso

    private func drawCurrentSection(
        _ context: inout GraphicsContext, geometry: VolumeGeometry, projector: ScreenProjector
    ) {
        guard let section = model.crossSectionBrowser.selectedSection else { return }
        let segments = PlaneFrameGeometry.outline(
            of: section.plane, clippedTo: geometry, projector: projector)
        var path = Path()
        for segment in segments { append(segment, to: &path) }
        // Bianca e non di un colore dei piani: non *è* uno dei tre piani, è la fetta che si sta
        // sfogliando nella striscia sotto la panorex, e darle uno di quei tre colori la farebbe
        // scambiare per essi.
        context.stroke(path, with: .color(.white.opacity(0.85)), lineWidth: 1.5)
    }

    // MARK: Gli impianti

    /// Ogni impianto come un solido ombreggiato.
    ///
    /// # Perché una mesh e non più la silhouette
    ///
    /// La silhouette dice dove sta l'impianto e non come è girato: da qualunque direzione la si
    /// guardi ha lo stesso aspetto, e in una vista che ruota è proprio l'orientamento la cosa
    /// che si sta cercando di capire. Con i triangoli veri l'ombreggiatura racconta la
    /// rastremazione, e girando la scena l'impianto gira con essa.
    ///
    /// I triangoli si disegnano ordinati per profondità, dal più lontano al più vicino — il
    /// pittore, non un buffer di profondità, che in una `Canvas` non c'è. Su un corpo convesso
    /// come questo il risultato è esatto: due triangoli non si compenetrano mai, quindi
    /// l'ordine per profondità del baricentro è l'ordine giusto. Su due impianti che si
    /// incrociassero non lo sarebbe, e si vedrebbe — ma due impianti che si incrociano sono già
    /// un errore che l'analisi di sicurezza segnala.
    private func drawImplants(_ context: inout GraphicsContext, projector: ScreenProjector) {
        for implant in model.implants where implant.isVisible {
            if model.isInteractingWith3D {
                drawProxy(
                    through: [implant.platformMM, implant.apexMM],
                    diameterMM: implant.model.diameterMM,
                    in: &context, projector: projector, colour: implantColor(implant))
                if implant.id == model.selectedImplantID {
                    drawImplantHandles(implant, in: &context, projector: projector)
                }
                continue
            }
            // Filettato, e alla tassellatura da schermo: un impianto liscio non si riconosce, e
            // uno filettato alla risoluzione dell'esportazione moltiplicherebbe i triangoli per
            // dieci proprio nel disegno che gira sulla CPU. `threadedScreenSurface` tiene il
            // passo leggibile e la griglia stretta — è la stessa scelta della risoluzione
            // ridotta nel raycaster, applicata all'altro disegno.
            let mesh = model.solidMeshes.mesh(id: implant.id, key: implant.hashValue) {
                ImplantMesh.threadedScreenSurface(of: implant, segments: Self.solidSegments)
            }
            guard !mesh.triangles.isEmpty else { continue }
            draw(
                mesh, in: &context, projector: projector,
                colour: implantColor(implant),
                isSelected: implant.id == model.selectedImplantID)
            if implant.id == model.selectedImplantID {
                drawImplantHandles(implant, in: &context, projector: projector)
            }
        }
    }

    /// Prese proiettate di testa e apice: sono gli stessi due bersagli che
    /// `beginVolume3DDrag` classifica come rotazione, resi visibili nella vista che li riceve.
    private func drawImplantHandles(
        _ implant: ImplantPlacement,
        in context: inout GraphicsContext,
        projector: ScreenProjector
    ) {
        let colour = implantColor(implant)
        for position in [implant.platformMM, implant.apexMM] {
            let projected = projector.project(position)
            let point = CGPoint(x: projected.x, y: projected.y)
            let outer = CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10)
            let inner = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
            context.fill(Path(ellipseIn: outer), with: .color(.black.opacity(0.7)))
            context.stroke(Path(ellipseIn: outer), with: .color(colour), lineWidth: 1.5)
            context.fill(Path(ellipseIn: inner), with: .color(colour))
        }
    }

    /// Il canale alveolare, come il tubo che è.
    ///
    /// Mancava, ed è l'oggetto per cui il riquadro 3D serve più di ogni altra vista: la domanda
    /// «l'impianto passa sopra il canale o dentro?» si legge a colpo d'occhio qui e va ricostruita
    /// sezione per sezione altrove. Il canale si tracciava, `SafetyAnalysis` ne calcolava già le
    /// distanze, l'ispettore le mostrava — e la vista che avrebbe dovuto renderle evidenti non
    /// disegnava l'oggetto di cui parlavano.
    ///
    /// **Prima degli impianti**, e non è indifferente: il pittore disegna in ordine, e un
    /// impianto che entra nel canale deve comparire sopra di esso. Al contrario si vedrebbe il
    /// canale integro davanti all'impianto che lo attraversa, cioè l'immagine rassicurante del
    /// caso che va fermato.
    private func drawNerves(_ context: inout GraphicsContext, projector: ScreenProjector) {
        for canal in model.nerveCanals where canal.isVisible {
            let colour = Color(hexString: canal.colorHex) ?? Palette.warning
            if model.isInteractingWith3D {
                // Mentre si gira: la polilinea dei nodi, spessa quanto il canale. Un tratto
                // solo invece di seicento triangoli proiettati e ordinati.
                drawProxy(
                    through: canal.nodes.map(\.positionMM),
                    diameterMM: (canal.nodes.map(\.radiusMM).max() ?? 1) * 2,
                    in: &context, projector: projector, colour: colour)
                continue
            }
            let mesh = model.solidMeshes.mesh(id: canal.id, key: canal.hashValue) {
                NerveMesh.surface(
                    of: canal, segments: Self.solidSegments,
                    spacingMM: Self.nerveDisplaySpacingMM)
            }
            guard !mesh.triangles.isEmpty else { continue }
            draw(
                mesh, in: &context, projector: projector,
                colour: colour,
                isSelected: canal.id == model.tracingNerveID)
        }
    }

    /// Le barre, come i tubi che sono.
    private func drawBars(_ context: inout GraphicsContext, projector: ScreenProjector) {
        for bar in model.bars where bar.isVisible {
            if model.isInteractingWith3D {
                drawProxy(
                    through: bar.nodesMM(in: model.implants), diameterMM: bar.diameterMM,
                    in: &context, projector: projector,
                    colour: Color(hexString: bar.colorHex) ?? Palette.textPrimary)
                continue
            }
            // La barra dipende **anche** dagli impianti, che le danno i nodi: la chiave li
            // comprende, altrimenti spostando un impianto la barra resterebbe dov'era.
            var hasher = Hasher()
            hasher.combine(bar)
            for implant in model.implants { hasher.combine(implant) }
            let mesh = model.solidMeshes.mesh(id: bar.id, key: hasher.finalize()) {
                ProstheticBarBuilder.surface(
                    of: bar, implants: model.implants, segments: Self.solidSegments)
            }
            guard !mesh.triangles.isEmpty else { continue }
            draw(
                mesh, in: &context, projector: projector,
                colour: Color(hexString: bar.colorHex) ?? Palette.textPrimary,
                isSelected: bar.id == model.selectedBarID)
        }
    }

    /// Lati con cui si approssima il cilindro **a schermo**.
    ///
    /// Meno dei trentadue dell'esportazione: a schermo un impianto occupa qualche decina di
    /// pixel, e sedici lati sono già indistinguibili da un cerchio. Il numero che conta per la
    /// stampa resta quello di `ImplantMesh.defaultSegments`, e sono due cose diverse — qui
    /// governa la fluidità, là la fedeltà del pezzo.
    private static let solidSegments = 16

    /// La sagoma povera di un oggetto allungato: la sua linea, spessa quanto lui.
    ///
    /// # Perché mentre si gira si disegna un'altra cosa
    ///
    /// Perché il volume lo disegna Metal e la sovraimpressione la disegna SwiftUI, e i due non
    /// hanno lo stesso costo. Proiettare, ordinare e riempire qualche migliaio di triangoli a
    /// ogni fotogramma la `Canvas` non ce la fa, quindi restava indietro — e un canale che
    /// insegue il volume con un fotogramma di ritardo si vede eccome: il piano sembra staccarsi
    /// dall'anatomia mentre lo si gira.
    ///
    /// Un tratto spesso quanto l'oggetto ne dà l'ingombro e la posizione, che è tutto quello che
    /// serve **mentre si gira**: la forma la si guarda da fermi, e da fermi torna il solido. È
    /// la stessa scelta che il raycaster fa già con la risoluzione, applicata all'altro disegno.
    private func drawProxy(
        through pointsMM: [Vec3],
        diameterMM: Double,
        in context: inout GraphicsContext,
        projector: ScreenProjector,
        colour: Color
    ) {
        guard pointsMM.count >= 2 else { return }
        var path = Path()
        for (index, point) in pointsMM.enumerated() {
            let projected = projector.project(point)
            let screen = CGPoint(x: projected.x, y: projected.y)
            if index == 0 { path.move(to: screen) } else { path.addLine(to: screen) }
        }
        context.stroke(
            path, with: .color(colour.opacity(0.85)),
            style: StrokeStyle(
                lineWidth: max(diameterMM * projector.pointsPerMM, 1.5),
                lineCap: .round, lineJoin: .round))
    }

    /// Livelli di ombreggiatura in cui si arrotonda il Lambert.
    ///
    /// Sedici: su un tubo la banda fra un livello e il successivo è più stretta di un pixel e
    /// non si distingue da una sfumatura continua, mentre accorpare per livelli riduce i
    /// riempimenti di un ordine di grandezza.
    private static let shadeLevels = 16

    /// Passo con cui si campiona il canale **per disegnarlo**, in millimetri.
    ///
    /// Due millimetri, non il mezzo millimetro con cui lo si misura. Un canale mandibolare è
    /// lungo una sessantina di millimetri: a mezzo millimetro sono centotrenta anelli, cioè
    /// oltre quattromila triangoli per canale — e sono due. A due millimetri sono seicento, e a
    /// schermo un tubo di un millimetro e mezzo di raggio non mostra la differenza.
    ///
    /// Il numero che conta per la geometria resta `NerveMesh.defaultSpacingMM`: sono due cose
    /// diverse, qui governa la fluidità, là la fedeltà.
    private static let nerveDisplaySpacingMM = 2.0

    /// Disegna una mesh col pittore e un'illuminazione diffusa.
    private func draw(
        _ mesh: Mesh,
        in context: inout GraphicsContext,
        projector: ScreenProjector,
        colour: Color,
        isSelected: Bool
    ) {
        // La luce viene da dietro l'osservatore, leggermente in alto a sinistra: è la
        // convenzione con cui il cervello legge una forma come convessa invece che concava.
        let light = (model.camera.forward * -1 + model.camera.right * -0.35
            + model.camera.down * -0.5).normalized ?? Vec3(0, 0, 1)

        struct Face {
            var path: Path
            var depth: Double
            var shade: Double
        }

        var faces: [Face] = []
        faces.reserveCapacity(mesh.triangles.count)

        for triangle in mesh.triangles {
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            guard let normal = (b - a).cross(c - a).normalized else { continue }

            // Le facce che guardano via dall'osservatore stanno dietro il solido e sono coperte:
            // scartarle dimezza il lavoro e toglie i bordi scuri che comparirebbero sui lati.
            let facing = normal.dot(model.camera.forward)
            guard facing < 0 else { continue }

            let pa = projector.project(a)
            let pb = projector.project(b)
            let pc = projector.project(c)

            var path = Path()
            path.move(to: CGPoint(x: pa.x, y: pa.y))
            path.addLine(to: CGPoint(x: pb.x, y: pb.y))
            path.addLine(to: CGPoint(x: pc.x, y: pc.y))
            path.closeSubpath()

            // Lambert, con un fondo ambientale che impedisce alle facce di bordo di diventare
            // nere: su fondo nero una faccia nera è un buco nell'oggetto.
            let lambert = Swift.max(normal.dot(light), 0)
            faces.append(
                Face(
                    path: path,
                    depth: (pa.depthMM + pb.depthMM + pc.depthMM) / 3,
                    shade: 0.35 + 0.65 * lambert))
        }

        // Dal più lontano al più vicino.
        faces.sort { $0.depth > $1.depth }

        // # Un riempimento per **tratto**, non per triangolo
        //
        // Erano migliaia di `fill` per fotogramma, uno per faccia, ed è la seconda metà del
        // costo dopo la costruzione della mesh. Le facce contigue in profondità di una
        // superficie liscia hanno quasi sempre la stessa ombreggiatura, quindi arrotondandola a
        // pochi livelli si formano tratti lunghi che si possono riempire in un colpo solo.
        //
        // Si accorpa **solo dentro un tratto consecutivo**, mai raggruppando per ombreggiatura
        // in giro per l'elenco: l'ordine di profondità è ciò che rende corretto il disegno del
        // pittore, e riordinare per colore metterebbe davanti facce che stanno dietro.
        var run = Path()
        var runShade = -1.0
        for face in faces {
            let quantised = (face.shade * Double(Self.shadeLevels)).rounded()
                / Double(Self.shadeLevels)
            if quantised != runShade {
                if runShade >= 0 {
                    context.fill(run, with: .color(colour.opacity(runShade)))
                }
                run = Path()
                runShade = quantised
            }
            run.addPath(face.path)
        }
        if runShade >= 0 {
            context.fill(run, with: .color(colour.opacity(runShade)))
        }

        guard isSelected, let outline = faces.last?.path else { return }
        // Il selezionato si distingue con un contorno sulla faccia più vicina: un alone
        // attorno all'intera silhouette richiederebbe l'inviluppo, e a questa scala non
        // aggiungerebbe niente.
        context.stroke(outline, with: .color(colour), lineWidth: 1.5)
    }

    /// Le etichette degli oggetti nel 3D.
    ///
    /// # Perché non passano da `LabelOverlay`
    ///
    /// Quella dispone le etichette evitando che si sovrappongano, e per farlo ha bisogno di un
    /// piano: `slot` e `MPRPlane`. Il 3D non ha un piano, ha una telecamera. Qui l'etichetta si
    /// posa accanto alla piattaforma proiettata, senza risoluzione delle collisioni — su una
    /// scena che ruota due etichette si separano girando di poco, mentre in una vista fissa
    /// resterebbero sovrapposte per sempre.
    ///
    /// Il 3D era l'unica vista in cui gli oggetti non avevano nome: si vedevano le forme e non
    /// si sapeva quale fosse l'impianto 46.
    private func drawLabels(_ context: inout GraphicsContext, projector: ScreenProjector) {
        for implant in model.implants where implant.isVisible {
            let projected = projector.project(implant.platformMM)
            let name = model.registry[implant.id]?.name ?? implant.label
            guard !name.isEmpty else { continue }
            draw(
                name, at: CGPoint(x: projected.x, y: projected.y), in: &context,
                color: implantColor(implant),
                isSelected: implant.id == model.selectedImplantID)
        }

        for tooth in model.teeth where tooth.isVisible {
            let projected = projector.project(tooth.occlusalCentreMM)
            draw(
                "\(tooth.toothNumber)", at: CGPoint(x: projected.x, y: projected.y),
                in: &context,
                color: Color(hexString: tooth.colorHex) ?? Palette.textPrimary,
                isSelected: tooth.id == model.selectedToothID)
        }
    }

    private func draw(
        _ text: String,
        at point: CGPoint,
        in context: inout GraphicsContext,
        color: Color,
        isSelected: Bool
    ) {
        let resolved = context.resolve(
            Text(text).font(Typography.numericSmall).foregroundStyle(color))
        let size = resolved.measure(in: CGSize(width: 220, height: 40))
        let origin = CGPoint(x: point.x + 9, y: point.y - size.height / 2)
        let background = CGRect(
            x: origin.x - 3, y: origin.y - 2, width: size.width + 6, height: size.height + 4)
        context.fill(
            Path(roundedRect: background, cornerRadius: 3),
            with: .color(.black.opacity(isSelected ? 0.7 : 0.5)))
        context.draw(resolved, at: origin, anchor: .topLeading)
    }

    /// I denti protesici, come gabbie tratteggiate.
    ///
    /// La gabbia e non la silhouette, al contrario del 2D: nel 3D si gira attorno alla scena, e
    /// i dodici spigoli dicono **come è orientato** il dente attorno al proprio asse — che è
    /// l'informazione per cui la sagoma esiste. L'inviluppo convesso, che in una vista fissa
    /// basta, in una vista che ruota sembrerebbe una macchia che cambia forma da sola.
    private func drawTeeth(_ context: inout GraphicsContext, projector: ScreenProjector) {
        for tooth in model.teeth where tooth.isVisible {
            let corners = tooth.corners(mesialDirectionMM: model.mesialDirection(for: tooth))
            guard corners.count == 8 else { continue }

            let projected = corners.map { corner -> CGPoint in
                let point = projector.project(corner)
                return CGPoint(x: point.x, y: point.y)
            }

            var path = Path()
            for (a, b) in ProstheticTooth.cornerEdges {
                path.move(to: projected[a])
                path.addLine(to: projected[b])
            }

            let colour = Color(hexString: tooth.colorHex) ?? Palette.textPrimary
            context.stroke(
                path, with: .color(colour.opacity(0.85)),
                style: StrokeStyle(
                    lineWidth: tooth.id == model.selectedToothID ? 1.8 : 1.1, dash: [4, 3]))
        }
    }

    /// Colore dell'impianto: quello del suo allarme di prossimità se ce n'è uno, altrimenti il
    /// suo. Un impianto che sfiora il nervo deve dirlo anche qui, non solo nel pannello.
    private func implantColor(_ implant: ImplantPlacement) -> Color {
        switch model.safetyReports[implant.id]?.worstLevel {
        case .danger: return Palette.danger
        case .caution: return Palette.caution
        case .safe, nil: return Color(hexString: implant.colorHex) ?? Palette.textPrimary
        }
    }

    /// Pixel per millimetro nel punto indicato. La proiezione è ortografica, quindi il fattore è
    /// costante su tutto il riquadro e il punto serve solo a leggerlo.
    private func screenScale(projector: ScreenProjector, at pointMM: Vec3) -> Double {
        let origin = projector.project(pointMM)
        let shifted = projector.project(pointMM + model.camera.right)
        return abs(shifted.x - origin.x)
    }

    private func append(_ segment: ScreenSegment, to path: inout Path) {
        path.move(to: CGPoint(x: segment.from.x, y: segment.from.y))
        path.addLine(to: CGPoint(x: segment.to.x, y: segment.to.y))
    }
}
