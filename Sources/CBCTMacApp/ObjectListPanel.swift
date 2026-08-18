import DICOMCore
import ImplantKit
import MeasureKit
import StudyKit
import SwiftUI

// L'elenco degli oggetti del piano.
//
// # Il pezzo che mancava di più
//
// Finora gli oggetti pianificati esistevano solo dentro le immagini: un impianto si poteva
// aggiungere e selezionare cliccandolo, e basta. Non c'era modo di sapere quanti ce n'erano, di
// spegnerne uno per guardare sotto, di ridargli un nome, di tornarci sopra mezz'ora dopo senza
// cercarlo scorrendo le fette.
//
// Un elenco risolve tutte queste in un posto solo, ed è il motivo per cui ogni visore ne ha uno.
// Le sei azioni che offre — accendi, colora, rinomina, centra, duplica, cancella — sono le sei
// che si fanno di continuo.
//
// # Contestuale
//
// Mostra il tipo di oggetto su cui si sta lavorando: impianti se c'è un impianto selezionato o lo
// strumento implantare in mano, curve in modo curvo, misure altrimenti. Un elenco unico con tutto
// dentro sarebbe più semplice da scrivere e costringerebbe a scorrere fra cose che in quel momento
// non c'entrano.

struct ObjectListPanel: View {

    @Bindable var model: AppModel

    /// Tipo mostrato adesso. `nil` segue il contesto; scegliendo una scheda si fissa.
    @State private var pinnedKind: PlanObjectKind?

    private var kind: PlanObjectKind { pinnedKind ?? contextualKind }

    private var contextualKind: PlanObjectKind {
        if model.selectedImplantID != nil || model.activeTool == .implant { return .implant }
        if model.activeTool == .nerve { return .nerveCanal }
        if model.workMode.usesArchCurve || model.activeTool == .archCurve { return .archCurve }
        return .annotation
    }

    private var objects: [PlanObjectInfo] { model.registry.objects(of: kind) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            kindPicker

            if objects.isEmpty {
                Text(emptyMessage)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 2)
            } else {
                ForEach(objects) { object in
                    ObjectRow(model: model, object: object)
                }

                Button(role: .destructive) {
                    model.deleteObjects(of: kind)
                } label: {
                    Label("Cancella tutti", systemImage: "trash")
                        .font(Typography.label)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.danger)
                .padding(.top, 2)
            }
        }
    }

    /// Le quattro schede dei tipi, con il conteggio.
    ///
    /// Il conteggio accanto al nome non è ornamento: dice se c'è qualcosa da guardare in un tipo
    /// che non si sta mostrando, e senza di esso bisogna aprirli tutti per scoprirlo.
    private var kindPicker: some View {
        HStack(spacing: 3) {
            ForEach(shownKinds, id: \.self) { candidate in
                let count = model.registry.objects(of: candidate).count
                Button {
                    pinnedKind = candidate
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: icon(for: candidate)).font(.system(size: 10))
                        if count > 0 {
                            Text("\(count)").font(Typography.numericSmall)
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        candidate == kind ? Palette.accent.opacity(0.22) : Palette.chromeElevated,
                        in: .rect(cornerRadius: 4))
                    .foregroundStyle(
                        candidate == kind ? Palette.accent : Palette.textSecondary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(name(for: candidate))
            }
            Spacer(minLength: 0)
        }
    }

    private var shownKinds: [PlanObjectKind] {
        [.implant, .nerveCanal, .annotation, .archCurve]
    }

    private func icon(for kind: PlanObjectKind) -> String {
        switch kind {
        case .implant: return "screwdriver"
        case .nerveCanal: return "point.topleft.down.curvedto.point.bottomright.up"
        case .archCurve: return "waveform.path"
        case .annotation: return "ruler"
        case .mesh: return "cube.transparent"
        case .guideDesign: return "square.stack.3d.down.right"
        }
    }

    private func name(for kind: PlanObjectKind) -> String {
        switch kind {
        case .implant: return "Impianti"
        case .nerveCanal: return "Canali nervosi"
        case .archCurve: return "Curve d'arcata"
        case .annotation: return "Misure e note"
        case .mesh: return "Superfici"
        case .guideDesign: return "Dime"
        }
    }

    private var emptyMessage: String {
        switch kind {
        case .implant: return "Nessun impianto. Prendi lo strumento impianto e fai clic sulla cresta."
        case .nerveCanal: return "Nessun canale tracciato."
        case .archCurve: return "Nessuna curva. Prendi lo strumento arcata e posa i punti sull'assiale."
        case .annotation: return "Nessuna misura."
        case .mesh: return "Nessuna superficie."
        case .guideDesign: return "Nessuna dima."
        }
    }
}

// MARK: - Riga

private struct ObjectRow: View {

    @Bindable var model: AppModel
    let object: PlanObjectInfo

    @State private var isRenaming = false
    @State private var draftName = ""

    private var isSelected: Bool {
        model.selectedImplantID == object.id || model.selectedAnnotationID == object.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            // I parametri **in linea**, solo sull'oggetto selezionato: sono i due numeri che si
            // toccano di continuo mentre si pianifica, e mandare l'occhio a cercarli in un
            // pannello dall'altra parte della finestra a ogni ritocco è il genere di attrito che
            // non si nota una volta e pesa dopo venti.
            if isSelected, object.kind == .implant,
                let implant = model.implants.first(where: { $0.id == object.id })
            {
                implantParameters(implant)
            }
        }
    }

    @ViewBuilder
    private func implantParameters(_ implant: ImplantPlacement) -> some View {
        HStack(spacing: 10) {
            SteppedValue(
                label: "Ø", value: implant.model.diameterMM, step: 0.1, format: "%.1f"
            ) { newValue in
                model.updateImplant(id: object.id) { $0.model.diameterMM = newValue }
            }
            SteppedValue(
                label: "L", value: implant.model.lengthMM, step: 0.5, format: "%.1f"
            ) { newValue in
                model.updateImplant(id: object.id) { $0.model.lengthMM = newValue }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)

        // Profondità e inclinazione: gli stessi due movimenti che si fanno trascinando
        // l'impianto nei riquadri, dichiarati anche qui.
        //
        // Non è una ripetizione inutile. Il trascinamento è il gesto giusto ma è invisibile —
        // nulla, guardando l'immagine, dice che un impianto si possa afferrare — e su questo
        // progetto una funzione che non si vede è già equivalsa tre volte a una funzione che non
        // c'è. In più questi comandi fanno una cosa che il mouse non fa: passi **esatti**, e per
        // la profondità di una piattaforma un decimo di millimetro conta.
        HStack(spacing: 10) {
            Text("Profondità")
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            Button { slide(-0.5) } label: { Image(systemName: "arrow.up") }
                .help("Solleva l'impianto di mezzo millimetro lungo il suo asse")
            Button { slide(0.5) } label: { Image(systemName: "arrow.down") }
                .help("Affonda l'impianto di mezzo millimetro lungo il suo asse")

            Text(angleLabel(implant))
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            Spacer(minLength: 0)
        }
        .controlSize(.mini)
        .padding(.leading, 22)
        .padding(.bottom, 2)
    }

    private func slide(_ millimetres: Double) {
        model.selectedImplantID = object.id
        model.slideSelectedImplant(byMM: millimetres)
    }

    /// Inclinazione rispetto alla verticale del paziente.
    ///
    /// Si mostra perché è il numero che dice se un impianto è protesicamente ragionevole, e
    /// perché è l'unico riscontro di un'inclinazione fatta trascinando: trascinando si vede la
    /// forma muoversi, non di quanti gradi.
    private func angleLabel(_ implant: ImplantPlacement) -> String {
        guard let degrees = implant.angleDegrees(to: Vec3(0, 0, 1)) else { return "" }
        return String(format: "· %.0f° dalla verticale", degrees)
    }

    private var row: some View {
        HStack(spacing: 6) {
            // L'occhio per primo, a sinistra: è l'azione più frequente dell'elenco, e sta dove
            // l'occhio arriva per primo scorrendo una colonna.
            Button {
                model.setObjectVisible(!object.isVisible, id: object.id)
            } label: {
                Image(systemName: object.isVisible ? "eye" : "eye.slash")
                    .font(.system(size: 10))
                    .frame(width: 16)
                    .foregroundStyle(
                        object.isVisible ? Palette.textSecondary : Palette.textSecondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help(object.isVisible ? "Nascondi" : "Mostra")

            ColorDot(hex: object.colorHex) { model.setObjectColor($0, id: object.id) }

            if isRenaming {
                TextField("", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .onSubmit {
                        model.renameObject(draftName, id: object.id)
                        isRenaming = false
                    }
            } else {
                Text(object.name)
                    .font(Typography.body)
                    .foregroundStyle(
                        object.isVisible ? Palette.textPrimary : Palette.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let badge = severityBadge {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(badge)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            isSelected ? Palette.accent.opacity(0.16) : Palette.chromeElevated,
            in: .rect(cornerRadius: 4))
        .contentShape(.rect)
        // Un clic seleziona, due portano le viste sull'oggetto. È la coppia attesa ovunque, e
        // separa «voglio vederne i parametri» da «voglio andarci sopra».
        .onTapGesture(count: 2) { model.centreOnObject(id: object.id) }
        .onTapGesture { model.centreOnObject(id: object.id) }
        .overlay(alignment: .bottom) { Color.clear.frame(height: 0) }
        .contextMenu {
            Button("Porta al centro") { model.centreOnObject(id: object.id) }
            Button("Rinomina…") {
                draftName = object.name
                isRenaming = true
            }
            if object.kind == .implant {
                Divider()
                Button("Duplica") { model.duplicateImplant(id: object.id) }
                Button("Specchia sul lato opposto") { model.mirrorImplant(id: object.id) }
            }
            Divider()
            Button(object.isLocked ? "Sblocca" : "Blocca") {
                model.setObjectLocked(!object.isLocked, id: object.id)
            }
            Button("Cancella", role: .destructive) { model.deleteObject(id: object.id) }
        }
    }

    /// Colore dell'allarme peggiore, per gli impianti. Un impianto che sfiora il nervo deve
    /// dirlo anche nell'elenco, non solo aprendo il pannello di sicurezza.
    private var severityBadge: Color? {
        guard object.kind == .implant,
            let report = model.safetyReports[object.id]
        else { return nil }
        switch report.worstLevel {
        case .danger: return Palette.danger
        case .caution: return Palette.caution
        case .safe: return nil
        }
    }
}

// MARK: - Pallino del colore

private struct ColorDot: View {

    let hex: String
    let onPick: (String) -> Void

    /// Otto colori, non un selettore di sistema. Servono colori **distinguibili fra loro** su
    /// fondo nero, e una ruota completa invita a scegliere sfumature che poi non si distinguono.
    private static let choices = [
        "32B8C6", "E15759", "F28E2B", "59A14F", "B07AA1", "EDC948", "4E79A7", "76B7B2",
    ]

    @State private var isPicking = false

    var body: some View {
        Button { isPicking = true } label: {
            Circle()
                .fill(Color(hexString: hex) ?? Palette.accent)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Colore")
        .popover(isPresented: $isPicking, arrowEdge: .trailing) {
            HStack(spacing: 6) {
                ForEach(Self.choices, id: \.self) { choice in
                    Button {
                        onPick(choice)
                        isPicking = false
                    } label: {
                        Circle()
                            .fill(Color(hexString: choice) ?? Palette.accent)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().stroke(.white.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
        }
    }
}

// MARK: - Valore con passo

/// Un numero con due frecce, in linea.
///
/// Un campo di testo sarebbe più flessibile e qui sarebbe peggio: i diametri implantari esistono
/// a passi di un decimo e le lunghezze a mezzo millimetro, e un campo libero invita a scrivere
/// misure che nessun produttore fabbrica. Le frecce muovono sulla griglia giusta; il valore resta
/// selezionabile per chi vuole leggerlo, non per chi vuole inventarlo.
private struct SteppedValue: View {

    let label: String
    let value: Double
    let step: Double
    let format: String
    let onChange: (Double) -> Void

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
            Text(String(format: format, value).replacingOccurrences(of: ".", with: ","))
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
                .frame(minWidth: 30, alignment: .trailing)
            Stepper("") { onChange(value + step) } onDecrement: {
                // Mai sotto zero: un impianto di diametro negativo non è un caso limite da
                // gestire a valle, è un valore che non deve poter esistere.
                onChange(max(value - step, step))
            }
            .labelsHidden()
            .controlSize(.mini)
        }
    }
}
