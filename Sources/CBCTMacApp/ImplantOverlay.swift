import DICOMCore
import ImplantKit
import StudyKit
import SwiftUI
import VolumeKit

// Impianti e canale alveolare disegnati sopra le viste 2D.
//
// Come le annotazioni, sono elementi di interfaccia disegnati in SwiftUI sopra la texture, non
// dentro lo shader: si modificano senza ricompilare Metal e il testo resta nitido.
//
// Il criterio di visibilità è **quanto il corpo dista dal piano**, non quanto ne distano i suoi
// estremi: zero finché il piano lo attraversa, e solo da lì in poi la distanza dell'estremo più
// vicino. La regola sta in `PlaneProximity`, dove si può provare; qui c'era, sbagliata, e nessun
// test poteva raggiungerla. Un impianto che sta dieci millimetri più in là non si nasconde di
// colpo — sfuma — perché sparire di netto renderebbe difficile ritrovarlo, mentre mostrarlo
// pieno farebbe credere che intersechi la slice corrente.

struct ImplantOverlay: View {

    let model: AppModel
    /// Il piano su cui proiettare. È l'**unico** ingresso geometrico: la sovraimpressione non
    /// sa in quale riquadro sta, e per questo funziona anche sulle sezioni trasversali, che un
    /// riquadro della griglia non sono.
    let plane: MPRPlane?

    var body: some View {
        Canvas { context, size in
            guard let plane = adjusted(for: size) else { return }
            let width = Int(size.width)
            let height = Int(size.height)

            // Prima il nervo, poi gli impianti: se si sovrappongono conta di più vedere dove
            // finisce l'impianto rispetto al canale.
            for canal in model.nerveCanals where canal.isVisible {
                drawNerve(canal, in: &context, plane: plane, width: width, height: height)
            }
            // La barra sotto gli impianti: passa sopra le piattaforme e li tocca, e disegnata
            // sopra coprirebbe proprio le teste che si sta cercando di allineare.
            for bar in model.bars where bar.isVisible {
                drawBar(bar, in: &context, plane: plane, width: width, height: height)
            }
            for implant in model.implants where implant.isVisible {
                drawImplant(
                    implant, in: &context, plane: plane, width: width, height: height,
                    isSelected: implant.id == model.selectedImplantID)
            }
        }
        .allowsHitTesting(false)
    }

    private func adjusted(for size: CGSize) -> MPRPlane? {
        guard let plane, size.width > 0, size.height > 0 else { return nil }
        return plane.matchingAspect(pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    private func pointsPerMM(_ plane: MPRPlane, width: Int) -> Double {
        guard plane.widthMM > 0 else { return 1 }
        return Double(width) / plane.widthMM
    }

    // MARK: Impianto

    private func drawImplant(
        _ implant: ImplantPlacement,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int,
        isSelected: Bool
    ) {
        let profile = implant.model.profile
        guard profile.count >= 2 else { return }

        let platformProjection = plane.pixelPosition(
            ofPatient: implant.platformMM, pixelWidth: width, pixelHeight: height)
        let apexProjection = plane.pixelPosition(
            ofPatient: implant.apexMM, pixelWidth: width, pixelHeight: height)

        // # Quanto dista l'impianto dal piano, e perché non è la media dei due estremi
        //
        // Era la media, e rendeva invisibile il caso più comune di tutti. Si posa un impianto
        // cliccando sull'assiale: la piattaforma finisce **sul** piano, distanza zero, e l'apice
        // dieci millimetri sotto. La media faceva cinque, contro una sfumatura di un diametro —
        // quattro virgola uno — quindi opacità negativa e `guard` che scartava il disegno.
        // L'impianto c'era, era nell'elenco, ed era invisibile in tutte e tre le viste: da qui
        // l'impressione che il clic non facesse niente.
        //
        // La grandezza giusta è la **distanza minima del corpo dal piano**: zero finché il piano
        // lo attraversa, e solo dopo la distanza dell'estremo più vicino. È lo stesso criterio
        // dei denti — sfumare quando il piano passa fuori dall'oggetto, non lontano dal suo
        // centro.
        let platformDistance = platformProjection.distanceMM
        let apexDistance = apexProjection.distanceMM
        let nearestDistanceMM = PlaneProximity.distanceMM(
            from: platformDistance, to: apexDistance)

        // Quota lungo l'asse, dalla piattaforma, in cui l'impianto incontra il piano. Quando non
        // lo incontra è l'estremo più vicino: è lì che si guarda la sezione appena prima che
        // sparisca.
        let lengthMM = implant.model.lengthMM
        let crossingZMM =
            lengthMM
            * PlaneProximity.crossingFraction(from: platformDistance, to: apexDistance)

        // Oltre un diametro dal corpo l'impianto è lontano dalla slice: si sfuma invece di
        // sparire di netto, così resta ritrovabile senza sembrare presente nel taglio.
        let opacity = PlaneProximity.fadeOpacity(
            distanceMM: nearestDistanceMM, fadeOverMM: implant.model.diameterMM)
        guard opacity > 0.03 else { return }

        // Il colore segue il livello di sicurezza: un impianto troppo vicino al nervo si
        // riconosce senza dover leggere l'ispettore.
        let level = model.safetyReports[implant.id]?.worstLevel
        let strokeColor: Color =
            switch level {
            case .danger: Palette.danger
            case .caution: Palette.caution
            default: Color(hexString: implant.colorHex) ?? Palette.textPrimary
            }

        let scale = pointsPerMM(plane, width: width)

        // # Silhouette o sezione, secondo come l'impianto sta rispetto al piano
        //
        // Un impianto **disteso** nel piano si disegna come sagoma: due lati a ±raggio lungo la
        // perpendicolare all'asse proiettato. È il caso della coronale e della sagittale per un
        // impianto verticale, ed è la figura che si riconosce in radiologia.
        //
        // Un impianto che invece **buca** il piano quasi perpendicolarmente non ha sagoma: la
        // proiezione dell'asse è un punto, e i due lati collassano su una scheggia larga zero.
        // Il disegno corretto in quel caso è la **sezione**, cioè il cerchio del raggio che
        // l'impianto ha a quella quota — che è ciò che si vede in un assiale, ed è la figura su
        // cui si giudica quanto osso resta fra l'impianto e le corticali.
        //
        // La soglia non è un angolo scelto a mano: è la lunghezza proiettata contro il diametro.
        // Quando la sagoma è più corta che larga, non è più una sagoma.
        let inPlaneLengthMM = PlaneProximity.inPlaneLengthMM(
            lengthMM: lengthMM, tilt: implant.axis.dot(plane.normalMM))

        if inPlaneLengthMM < implant.model.diameterMM {
            drawImplantSection(
                implant, in: &context, plane: plane, width: width, height: height,
                atZ: crossingZMM, scale: scale, color: strokeColor, opacity: opacity,
                isSelected: isSelected)
            return
        }

        // Silhouette: per ogni quota del profilo, due punti a ±raggio lungo la perpendicolare
        // all'asse proiettato. È la sagoma che si vede in radiologia.
        let axisInPlane = projectedAxisDirection(implant, plane: plane)
        let perpendicular = CGPoint(x: -axisInPlane.y, y: axisInPlane.x)

        var leftSide: [CGPoint] = []
        var rightSide: [CGPoint] = []

        for point in profile {
            let centre = implant.axisPoint(atZ: point.zMM)
            let projected = plane.pixelPosition(
                ofPatient: centre, pixelWidth: width, pixelHeight: height)
            let origin = CGPoint(x: projected.x, y: projected.y)
            let offset = CGFloat(point.radiusMM * scale)

            leftSide.append(
                CGPoint(
                    x: origin.x + perpendicular.x * offset,
                    y: origin.y + perpendicular.y * offset))
            rightSide.append(
                CGPoint(
                    x: origin.x - perpendicular.x * offset,
                    y: origin.y - perpendicular.y * offset))
        }

        var outline = Path()
        outline.move(to: leftSide[0])
        for point in leftSide.dropFirst() { outline.addLine(to: point) }
        for point in rightSide.reversed() { outline.addLine(to: point) }
        outline.closeSubpath()

        context.fill(outline, with: .color(strokeColor.opacity(0.18 * opacity)))
        context.stroke(
            outline, with: .color(strokeColor.opacity(0.95 * opacity)),
            lineWidth: isSelected ? 2 : 1.4)

        // Asse prolungato oltre la piattaforma: mostra dove l'impianto emergerebbe, che è la
        // verifica protesica che conta quanto la posizione nell'osso.
        let emergence = implant.emergencePoint(extensionMM: 6)
        let emergenceProjection = plane.pixelPosition(
            ofPatient: emergence, pixelWidth: width, pixelHeight: height)
        var axisPath = Path()
        axisPath.move(to: CGPoint(x: platformProjection.x, y: platformProjection.y))
        axisPath.addLine(to: CGPoint(x: emergenceProjection.x, y: emergenceProjection.y))
        context.stroke(
            axisPath,
            with: .color(strokeColor.opacity(0.6 * opacity)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

        guard isSelected else { return }
        drawLabel(
            sizeLabel(implant), at: CGPoint(x: platformProjection.x, y: platformProjection.y),
            in: &context, color: strokeColor, opacity: opacity)
    }

    /// La sezione dell'impianto sul piano: il cerchio del raggio che ha a quella quota.
    ///
    /// Con il centro segnato, perché è il centro che si allinea al dente e alla cresta, e un
    /// cerchio vuoto non dice dove sia il suo.
    private func drawImplantSection(
        _ implant: ImplantPlacement,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int,
        atZ zMM: Double,
        scale: Double,
        color: Color,
        opacity: Double,
        isSelected: Bool
    ) {
        let centre = implant.axisPoint(atZ: zMM)
        let projected = plane.pixelPosition(
            ofPatient: centre, pixelWidth: width, pixelHeight: height)
        let radius = CGFloat(implant.model.radius(atZ: zMM) * scale)
        guard radius > 0.5 else { return }

        let origin = CGPoint(x: projected.x, y: projected.y)
        let circle = Path(
            ellipseIn: CGRect(
                x: origin.x - radius, y: origin.y - radius,
                width: radius * 2, height: radius * 2))

        context.fill(circle, with: .color(color.opacity(0.18 * opacity)))
        context.stroke(
            circle, with: .color(color.opacity(0.95 * opacity)),
            lineWidth: isSelected ? 2 : 1.4)

        var centreMark = Path()
        centreMark.move(to: CGPoint(x: origin.x - 3, y: origin.y))
        centreMark.addLine(to: CGPoint(x: origin.x + 3, y: origin.y))
        centreMark.move(to: CGPoint(x: origin.x, y: origin.y - 3))
        centreMark.addLine(to: CGPoint(x: origin.x, y: origin.y + 3))
        context.stroke(centreMark, with: .color(color.opacity(0.9 * opacity)), lineWidth: 1)

        guard isSelected else { return }
        drawLabel(
            sizeLabel(implant), at: CGPoint(x: origin.x, y: origin.y - radius),
            in: &context, color: color, opacity: opacity)
    }

    /// Diametro e lunghezza, con la virgola decimale italiana.
    private func sizeLabel(_ implant: ImplantPlacement) -> String {
        String(
            format: "Ø%.1f × %.0f", implant.model.diameterMM, implant.model.lengthMM
        ).replacingOccurrences(of: ".", with: ",")
    }

    /// La barra come tubo proiettato: una polilinea spessa quanto il suo diametro.
    ///
    /// Con il diametro vero e non con una linea sottile, per la stessa ragione del canale sulla
    /// panorex: la domanda è quanto spazio resta sopra, e una linea di un pixel farebbe sembrare
    /// spazio ciò che è raggio della barra.
    private func drawBar(
        _ bar: ProstheticBar,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int
    ) {
        let nodes = bar.nodesMM(in: model.implants)
        guard nodes.count >= 2 else { return }
        let scale = pointsPerMM(plane, width: width)

        var path = Path()
        var opacity = 1.0
        for (index, node) in nodes.enumerated() {
            let projected = plane.pixelPosition(
                ofPatient: node, pixelWidth: width, pixelHeight: height)
            let point = CGPoint(x: projected.x, y: projected.y)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            // Sfuma come un impianto: oltre il raggio dal piano la barra non lo interseca più.
            let fade = PlaneProximity.fadeOpacity(
                distanceMM: abs(projected.distanceMM), fadeOverMM: bar.diameterMM)
            opacity = min(opacity, fade)
        }
        guard opacity > 0.03 else { return }

        let colour = Color(hexString: bar.colorHex) ?? Palette.textPrimary
        context.stroke(
            path, with: .color(colour.opacity(0.9 * opacity)),
            style: StrokeStyle(
                lineWidth: max(bar.diameterMM * scale, 1.5), lineCap: .round, lineJoin: .round))
    }

    /// Direzione dell'asse proiettata sul piano, normalizzata in coordinate pixel.
    private func projectedAxisDirection(_ implant: ImplantPlacement, plane: MPRPlane) -> CGPoint {
        let along = implant.axis
        let x = along.dot(plane.rightMM)
        let y = along.dot(plane.downMM)
        let length = (x * x + y * y).squareRoot()
        guard length > 1e-9 else { return CGPoint(x: 0, y: 1) }
        return CGPoint(x: x / length, y: y / length)
    }

    // MARK: Nervo

    private func drawNerve(
        _ canal: NerveCanal,
        in context: inout GraphicsContext,
        plane: MPRPlane,
        width: Int,
        height: Int
    ) {
        guard canal.isUsable else { return }
        let colour = Color(hexString: canal.colorHex) ?? Palette.danger
        let scale = pointsPerMM(plane, width: width)
        let samples = canal.resampled(spacingMM: 0.5)

        // Tracciato completo, sfumato con la distanza: dà il senso del percorso anche quando il
        // canale non attraversa questa slice.
        var path = Path()
        var started = false
        for sample in samples {
            let projected = plane.pixelPosition(
                ofPatient: sample.positionMM, pixelWidth: width, pixelHeight: height)
            let point = CGPoint(x: projected.x, y: projected.y)
            if started { path.addLine(to: point) } else {
                path.move(to: point)
                started = true
            }
        }
        context.stroke(path, with: .color(colour.opacity(0.35)), lineWidth: 1)

        // Sezione del canale dove interseca davvero il piano: è l'informazione che serve
        // guardando una sezione trasversale, dove il canale compare come un cerchio scuro.
        for sample in samples {
            let projected = plane.pixelPosition(
                ofPatient: sample.positionMM, pixelWidth: width, pixelHeight: height)
            let distance = abs(projected.distanceMM)
            guard distance < sample.radiusMM else { continue }

            // Raggio apparente della circonferenza di intersezione fra il tubo e il piano.
            let apparent = (sample.radiusMM * sample.radiusMM - distance * distance).squareRoot()
            let radius = CGFloat(apparent * scale)
            guard radius > 0.5 else { continue }

            let rect = CGRect(
                x: projected.x - radius, y: projected.y - radius,
                width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: rect), with: .color(colour.opacity(0.9)), lineWidth: 1.5)
        }

        // Nodi tracciati: **sempre**, non solo mentre si traccia.
        //
        // Prima comparivano solo durante il tracciamento e sparivano appena finito. Adesso un
        // nodo si può trascinare per correggerlo e togliere con ⌥ clic, e un punto afferrabile
        // che non si vede è una funzione che non esiste — è già successo tre volte su questo
        // progetto. Finito il tracciamento restano più piccoli e più discreti: servono a essere
        // trovati quando li si cerca, non a coprire l'anatomia mentre si guarda altro.
        let isTracing = model.tracingNerveID == canal.id
        let size: CGFloat = isTracing ? 8 : 5
        for node in canal.nodes {
            let projected = plane.pixelPosition(
                ofPatient: node.positionMM, pixelWidth: width, pixelHeight: height)
            guard abs(projected.distanceMM) < 3 else { continue }
            let rect = CGRect(
                x: projected.x - size / 2, y: projected.y - size / 2, width: size, height: size)
            context.fill(
                Path(ellipseIn: rect), with: .color(colour.opacity(isTracing ? 1 : 0.75)))
            context.stroke(Path(ellipseIn: rect), with: .color(.white), lineWidth: 1)
        }
    }

    // MARK: Etichette

    private func drawLabel(
        _ text: String,
        at point: CGPoint,
        in context: inout GraphicsContext,
        color: Color,
        opacity: Double
    ) {
        let resolved = context.resolve(
            Text(text).font(Typography.numericSmall).foregroundStyle(color.opacity(opacity)))
        let size = resolved.measure(in: CGSize(width: 300, height: 60))
        let origin = CGPoint(x: point.x + 10, y: point.y - size.height / 2)

        let background = CGRect(
            x: origin.x - 3, y: origin.y - 2, width: size.width + 6, height: size.height + 4)
        context.fill(
            Path(roundedRect: background, cornerRadius: 3),
            with: .color(.black.opacity(0.55 * opacity)))
        context.draw(resolved, at: origin, anchor: .topLeading)
    }
}

// MARK: - Semaforo di sicurezza

/// Riepilogo delle distanze dalle strutture da rispettare.
///
/// Sta nell'ispettore con i pallini colorati perché è l'informazione che si controlla di
/// continuo mentre si sposta un impianto: doverla cercare in un pannello separato la
/// renderebbe una verifica finale invece che una guida durante il gesto.
struct SafetyPanel: View {

    let report: SafetyReport?
    let implant: ImplantPlacement?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            SectionHeader("SICUREZZA")

            if let report, !report.findings.isEmpty {
                ForEach(report.findings) { finding in
                    HStack(spacing: Metrics.spacing) {
                        Circle()
                            .fill(Color(hexString: finding.level.colorHex) ?? Palette.textSecondary)
                            .frame(width: 9, height: 9)
                        Text(finding.structureName)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: Metrics.spacing)
                        Text(finding.formattedDistance)
                            .font(Typography.numeric)
                            .foregroundStyle(
                                finding.level == .safe
                                    ? Palette.textSecondary
                                    : Color(hexString: finding.level.colorHex) ?? Palette.textPrimary
                            )
                    }
                }
            } else {
                Text("Nessuna struttura tracciata da controllare. Traccia il canale alveolare "
                    + "per attivare gli allarmi di prossimità.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let angulation = report?.angulationDegrees {
                HStack {
                    Text("Angolazione")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Text(
                        String(format: "%.1f°", angulation)
                            .replacingOccurrences(of: ".", with: ",")
                    )
                    .font(Typography.numeric)
                    .foregroundStyle(Palette.textSecondary)
                }
            }

            if let deviation = report?.maxParallelismDeviationDegrees {
                HStack {
                    Text("Parallelismo")
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                    Spacer()
                    Text(
                        String(format: "±%.1f°", deviation)
                            .replacingOccurrences(of: ".", with: ",")
                    )
                    .font(Typography.numeric)
                    .foregroundStyle(deviation > 15 ? Palette.caution : Palette.textSecondary)
                }
            }

            if let density = report?.density {
                Divider().overlay(Palette.separator)
                SectionHeader("DENSITÀ OSSEA")
                ForEach(density.bands, id: \.name) { band in
                    HStack {
                        Text(band.name)
                            .font(Typography.body)
                            .foregroundStyle(Palette.textPrimary)
                        Spacer()
                        Text(band.summary)
                            .font(Typography.numeric)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }
                Text(density.overall.unit.explanation)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
