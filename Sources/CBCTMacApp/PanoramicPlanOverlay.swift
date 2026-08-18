import DICOMCore
import DentalKit
import ImplantKit
import SwiftUI

// Impianti, canale e denti sopra la panorex.
//
// # Perché mancavano, e perché è grave
//
// La panorex è la vista d'insieme della pianificazione dentale: è lì che si guarda se gli
// impianti sono paralleli fra loro, se stanno alla stessa altezza, e se il canale passa dove
// ci si aspetta. Finora mostrava le misure e nient'altro — il piano intero era invisibile
// proprio nella vista che serve a giudicarlo nel suo insieme.
//
// # La regola della profondità, e in che cosa differisce da quella delle misure
//
// Le misure si disegnano «tutto o niente»: se anche un solo estremo cade fuori dallo spessore
// campionato, la misura sparisce, perché mezza misura disegnata sembra una misura intera più
// corta. Un impianto no: è un oggetto, non un numero, e mostrarne una parte non fa leggere
// male niente. Sfuma invece con la profondità, come sulle viste ortogonali, così si distingue
// «sta in questa ricostruzione» da «sta dall'altra parte della mandibola».
//
// La soglia è metà spessore dello slab, perché è esattamente ciò che la ricostruzione
// contiene; oltre, si sfuma su un margine pari al diametro dell'impianto invece di sparire di
// colpo — un impianto che scompare mentre si regola lo spessore sembra cancellato.

struct PanoramicPlanOverlay: View {

    let model: AppModel

    var body: some View {
        Canvas { context, size in
            let width = Int(size.width)
            let height = Int(size.height)
            guard width > 1, height > 1, model.archCurve.isUsable else { return }

            let layout = model.panoramicLayout
            let scale = 1.0 / max(layout.millimetresPerPixel(pixelWidth: width), 1e-9)
            let halfSlab = max(layout.slabThicknessMM * 0.5, 0.5)

            /// Proietta un punto, con l'opacità che gli spetta per la sua profondità.
            func project(_ pointMM: Vec3, fadeOverMM: Double) -> (point: CGPoint, opacity: Double)? {
                guard
                    let projected = layout.projection(
                        ofPatient: pointMM, pixelWidth: width, pixelHeight: height)
                else { return nil }
                let beyond = max(abs(projected.depthMM) - halfSlab, 0)
                let opacity = max(0, 1 - beyond / max(fadeOverMM, 1e-9))
                return (CGPoint(x: projected.x, y: projected.y), opacity)
            }

            // Prima il nervo, poi impianti, poi denti: l'ordine è quello dei riquadri
            // ortogonali, e vale la stessa ragione — conta di più vedere dove finisce
            // l'impianto rispetto al canale che il contrario.
            for canal in model.nerveCanals where canal.isVisible {
                drawNerve(canal, in: &context, scale: scale, project: project)
            }
            for implant in model.implants where implant.isVisible {
                drawImplant(
                    implant, in: &context, scale: scale,
                    isSelected: implant.id == model.selectedImplantID, project: project)
            }
            for tooth in model.teeth where tooth.isVisible {
                drawTooth(
                    tooth, in: &context,
                    mesial: model.mesialDirection(for: tooth),
                    isSelected: tooth.id == model.selectedToothID, project: project)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Impianto

    private func drawImplant(
        _ implant: ImplantPlacement,
        in context: inout GraphicsContext,
        scale: Double,
        isSelected: Bool,
        project: (Vec3, Double) -> (point: CGPoint, opacity: Double)?
    ) {
        let profile = implant.model.profile
        guard profile.count >= 2 else { return }
        let fade = implant.model.diameterMM

        // Ogni quota del profilo si proietta per conto suo: è ciò che rende corretta la
        // silhouette su una superficie curva. Un rettangolo disegnato fra i due estremi
        // ignorerebbe la curvatura dell'arcata lungo la lunghezza dell'impianto.
        var centres: [CGPoint] = []
        var radii: [CGFloat] = []
        var opacity = 1.0
        for level in profile {
            guard let projected = project(implant.axisPoint(atZ: level.zMM), fade) else { return }
            centres.append(projected.point)
            radii.append(CGFloat(level.radiusMM * scale))
            opacity = min(opacity, projected.opacity)
        }
        guard opacity > 0.03, centres.count >= 2 else { return }

        var leftSide: [CGPoint] = []
        var rightSide: [CGPoint] = []
        for index in centres.indices {
            let direction = tangent(of: centres, at: index)
            let perpendicular = CGPoint(x: -direction.y, y: direction.x)
            leftSide.append(
                CGPoint(
                    x: centres[index].x + perpendicular.x * radii[index],
                    y: centres[index].y + perpendicular.y * radii[index]))
            rightSide.append(
                CGPoint(
                    x: centres[index].x - perpendicular.x * radii[index],
                    y: centres[index].y - perpendicular.y * radii[index]))
        }

        var outline = Path()
        outline.move(to: leftSide[0])
        for point in leftSide.dropFirst() { outline.addLine(to: point) }
        for point in rightSide.reversed() { outline.addLine(to: point) }
        outline.closeSubpath()

        let level = model.safetyReports[implant.id]?.worstLevel
        let colour: Color =
            switch level {
            case .danger: Palette.danger
            case .caution: Palette.caution
            default: Color(hexString: implant.colorHex) ?? Palette.textPrimary
            }

        context.fill(outline, with: .color(colour.opacity(0.18 * opacity)))
        context.stroke(
            outline, with: .color(colour.opacity(0.95 * opacity)),
            lineWidth: isSelected ? 2 : 1.4)
    }

    /// Direzione della polilinea nel punto indicato, normalizzata.
    ///
    /// Si usa la differenza fra il precedente e il successivo, non fra il punto e il successivo:
    /// centrata, la direzione non salta all'ultimo campione e la silhouette non si strozza in
    /// punta, che è dove si guarda per giudicare la distanza dal canale.
    private func tangent(of points: [CGPoint], at index: Int) -> CGPoint {
        guard points.count >= 2 else { return CGPoint(x: 0, y: 1) }
        let before = points[max(index - 1, 0)]
        let after = points[min(index + 1, points.count - 1)]
        let dx = after.x - before.x
        let dy = after.y - before.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 1e-9 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: dx / length, y: dy / length)
    }

    // MARK: Canale

    private func drawNerve(
        _ canal: NerveCanal,
        in context: inout GraphicsContext,
        scale: Double,
        project: (Vec3, Double) -> (point: CGPoint, opacity: Double)?
    ) {
        guard canal.isUsable else { return }
        let colour = Color(hexString: canal.colorHex) ?? Palette.danger
        let samples = canal.resampled(spacingMM: 0.5)

        // Il canale si spezza in tratti: sulla panorex esce e rientra dallo spessore, e un
        // tratto solo lo costringerebbe a un'unica opacità — o tutto pieno, mostrando come
        // presente ciò che sta fuori, o tutto sbiadito dove invece è nel piano.
        //
        // Si disegna con lo **spessore vero** del canale, non con una linea sottile: sulla
        // panorex la domanda è quanto margine resta fra apice e canale, e una linea di un
        // pixel farebbe sembrare margine ciò che è raggio del canale.
        var run: [(point: CGPoint, width: CGFloat, opacity: Double)] = []

        func flush() {
            defer { run = [] }
            guard run.count >= 2 else { return }
            var path = Path()
            path.move(to: run[0].point)
            for entry in run.dropFirst() { path.addLine(to: entry.point) }
            let opacity = run.map(\.opacity).reduce(1.0, Swift.min)
            let thickness = run.map(\.width).reduce(0, Swift.max)
            context.stroke(
                path, with: .color(colour.opacity(0.75 * opacity)),
                style: StrokeStyle(
                    lineWidth: Swift.max(thickness, 1.5), lineCap: .round, lineJoin: .round))
        }

        for sample in samples {
            guard
                let projected = project(sample.positionMM, sample.radiusMM * 2),
                projected.opacity > 0.03
            else {
                flush()
                continue
            }
            run.append((projected.point, CGFloat(sample.radiusMM * 2 * scale), projected.opacity))
        }
        flush()

        // I nodi tracciati: si afferrano e si spostano anche da qui, e un punto afferrabile che
        // non si vede è una funzione che non esiste — su questo progetto è già successo quattro
        // volte.
        let isTracing = model.tracingNerveID == canal.id
        let size: CGFloat = isTracing ? 8 : 5
        for node in canal.nodes {
            guard let projected = project(node.positionMM, 3), projected.opacity > 0.03 else {
                continue
            }
            let rect = CGRect(
                x: projected.point.x - size / 2, y: projected.point.y - size / 2,
                width: size, height: size)
            context.fill(
                Path(ellipseIn: rect),
                with: .color(colour.opacity((isTracing ? 1 : 0.75) * projected.opacity)))
            context.stroke(
                Path(ellipseIn: rect), with: .color(.white.opacity(projected.opacity)),
                lineWidth: 1)
        }
    }

    // MARK: Dente

    private func drawTooth(
        _ tooth: ProstheticTooth,
        in context: inout GraphicsContext,
        mesial: Vec3?,
        isSelected: Bool,
        project: (Vec3, Double) -> (point: CGPoint, opacity: Double)?
    ) {
        let corners = tooth.corners(mesialDirectionMM: mesial)
        guard corners.count == 8 else { return }

        var projected: [CGPoint] = []
        var opacity = 1.0
        for corner in corners {
            guard let mapped = project(corner, tooth.depthMM) else { return }
            projected.append(mapped.point)
            opacity = Swift.min(opacity, mapped.opacity)
        }
        guard opacity > 0.03 else { return }

        let hull = convexHull(of: projected)
        guard hull.count >= 3 else { return }

        var outline = Path()
        outline.move(to: hull[0])
        for point in hull.dropFirst() { outline.addLine(to: point) }
        outline.closeSubpath()

        let colour = Color(hexString: tooth.colorHex) ?? Palette.textPrimary
        context.fill(outline, with: .color(colour.opacity(0.10 * opacity)))
        context.stroke(
            outline, with: .color(colour.opacity(0.7 * opacity)),
            style: StrokeStyle(lineWidth: isSelected ? 1.8 : 1.2, dash: [4, 3]))
    }
}
