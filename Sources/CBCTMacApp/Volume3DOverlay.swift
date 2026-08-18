import DICOMCore
import DentalKit
import ImplantKit
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
                drawImplants(&context, projector: projector)
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
                    faces, with: .color(color.opacity(0.30)),
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
                back, with: .color(color.opacity(0.35)),
                style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
            context.stroke(front, with: .color(color.opacity(0.95)), lineWidth: 1.5)

            // Una velatura appena percettibile dentro la cornice del riquadro attivo, per
            // distinguerlo dagli altri due senza aggiungere un'altra linea a un disegno che di
            // linee ne ha già molte.
            if slot == model.focusedSlot, let filled = filledPolygon(from: segments) {
                context.fill(filled, with: .color(color.opacity(0.07)))
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

    /// Ogni impianto come una silhouette: due fianchi e due estremità.
    ///
    /// Non è un cilindro reso: è la sua sagoma vista da dove sta la camera, che per un corpo di
    /// rivoluzione è esattamente un rettangolo con i lati paralleli all'asse. Costa quattro
    /// segmenti invece di una mesh, e a questa scala non si distingue.
    private func drawImplants(_ context: inout GraphicsContext, projector: ScreenProjector) {
        for implant in model.implants where implant.isVisible {
            guard let axis = implant.axis.normalized else { continue }
            let apex = implant.platformMM + axis * implant.model.lengthMM
            let radius = implant.model.diameterMM * 0.5

            // La direzione che a schermo attraversa l'impianto: perpendicolare sia all'asse sia
            // alla direzione di vista. Con l'impianto visto **di punta** i due sono paralleli e
            // il prodotto vettoriale degenera: allora la sagoma è un cerchio, non un rettangolo,
            // e disegnarne uno storto sarebbe peggio che non disegnare nulla.
            guard let side = axis.cross(model.camera.forward).normalized else {
                let centre = projector.project(implant.platformMM)
                let scale = screenScale(projector: projector, at: implant.platformMM)
                let r = radius * scale
                context.stroke(
                    Path(
                        ellipseIn: CGRect(
                            x: centre.x - r, y: centre.y - r, width: r * 2, height: r * 2)),
                    with: .color(implantColor(implant)), lineWidth: 1.5)
                continue
            }

            var path = Path()
            for sign in [1.0, -1.0] {
                let offset = side * (radius * sign)
                let a = projector.project(implant.platformMM + offset)
                let b = projector.project(apex + offset)
                path.move(to: CGPoint(x: a.x, y: a.y))
                path.addLine(to: CGPoint(x: b.x, y: b.y))
            }
            for point in [implant.platformMM, apex] {
                let a = projector.project(point + side * radius)
                let b = projector.project(point - side * radius)
                path.move(to: CGPoint(x: a.x, y: a.y))
                path.addLine(to: CGPoint(x: b.x, y: b.y))
            }
            context.stroke(path, with: .color(implantColor(implant)), lineWidth: 1.5)
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
