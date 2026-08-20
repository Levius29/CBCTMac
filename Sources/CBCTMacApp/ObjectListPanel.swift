import DICOMCore
import DentalKit
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
        [.implant, .prostheticTooth, .prostheticBar, .nerveCanal, .annotation, .archCurve]
    }

    private func icon(for kind: PlanObjectKind) -> String {
        switch kind {
        case .implant: return "screwdriver"
        case .prostheticTooth: return "mouth"
        case .prostheticBar: return "minus.rectangle"
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
        case .prostheticTooth: return "Denti protesici"
        case .prostheticBar: return "Barre"
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
        case .prostheticTooth:
            return "Nessun dente. Posa prima il dente dove lo vuole la protesi, poi l'impianto sotto."
        case .prostheticBar:
            return "Nessuna barra. Servono almeno due impianti; la barra li unisce nell'ordine dell'arcata."
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
    @State private var draftNote = ""
    @State private var draftName = ""
    @State private var isManuallyExpanded = false

    /// Se l'oggetto è **quello selezionato**, per il tipo che ha.
    ///
    /// Guardava solo impianti e misure, e non c'era modo di accorgersene: un dente protesico
    /// selezionato risultava non selezionato, quindi i suoi tre passi — larghezza, altezza,
    /// spessore — non comparivano mai in questo elenco.
    private var isSelected: Bool {
        switch object.kind {
        case .implant: return model.selectedImplantID == object.id
        case .prostheticTooth: return model.selectedToothID == object.id
        case .prostheticBar: return model.selectedBarID == object.id
        case .annotation: return model.selectedAnnotationID == object.id
        case .nerveCanal, .archCurve, .mesh, .guideDesign: return false
        }
    }

    /// Se la riga mostra i suoi dettagli: parametri, anteprima della curva, nota.
    ///
    /// # Perché non basta «selezionato»
    ///
    /// Perché non tutti i tipi si selezionano. Un canale nervoso e una curva d'arcata non hanno
    /// un identificatore di selezione, e legando i dettagli alla selezione la loro **nota** non
    /// si sarebbe potuta scrivere da nessuna parte — un campo che attraversa il formato del
    /// piano per non contenere mai niente, che è il difetto per cui la nota era stata aggiunta.
    ///
    /// Selezionare apre lo stesso, perché su un impianto i due numeri che si toccano di continuo
    /// devono essere lì appena lo si prende, senza un clic in più.
    private var isExpanded: Bool { isManuallyExpanded || isSelected }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            // I parametri **in linea**, solo sull'oggetto selezionato: sono i due numeri che si
            // toccano di continuo mentre si pianifica, e mandare l'occhio a cercarli in un
            // pannello dall'altra parte della finestra a ogni ritocco è il genere di attrito che
            // non si nota una volta e pesa dopo venti.
            if isExpanded, object.kind == .implant,
                let implant = model.implants.first(where: { $0.id == object.id })
            {
                implantParameters(implant)
            }

            if isExpanded, object.kind == .prostheticTooth,
                let tooth = model.teeth.first(where: { $0.id == object.id })
            {
                toothParameters(tooth)
            }

            if isExpanded, object.kind == .archCurve {
                ArchCurveThumbnail(curve: model.archCurve)
                    .frame(height: 44)
                    .padding(.leading, 22)
                    .padding(.trailing, 6)
            }

            if isExpanded {
                noteField
            }
        }
    }

    /// La nota libera sull'oggetto.
    ///
    /// `PlanObjectInfo.note` esisteva dall'inizio, veniva salvata nel piano e non era
    /// scrivibile da nessuna parte: un campo che attraversava il formato per non contenere mai
    /// niente. Serve a quello per cui una nota serve — «attendere guarigione», «il paziente non
    /// vuole estrarre il 47» — cioè a ricordare fra due settimane perché quell'impianto sta lì.
    @ViewBuilder
    private var noteField: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble")
                .font(.system(size: 9))
                .foregroundStyle(Palette.textSecondary)
            TextField("Nota", text: $draftNote)
                .textFieldStyle(.plain)
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textPrimary)
                .onSubmit { model.setObjectNote(draftNote, id: object.id) }
        }
        .padding(.leading, 22)
        .padding(.bottom, 2)
        .onChange(of: object.id, initial: true) { draftNote = object.note }
        // Perdendo il fuoco la nota si scrive lo stesso: pretendere Invio farebbe perdere ciò
        // che si è appena battuto a chi clicca altrove, che è come la maggior parte delle
        // persone smette di scrivere in un campo.
        .onDisappear { model.setObjectNote(draftNote, id: object.id) }
    }

    /// Le misure della corona.
    ///
    /// Modificabili, e non solo leggibili: le misure standard sono medie di popolazione, e
    /// l'anatomia di questo paziente non le rispetta. Un dente della larghezza sbagliata dice
    /// che l'impianto emerge dentro la corona quando non ci sta, o il contrario — cioè fa
    /// sbagliare proprio la verifica per cui la sagoma esiste.
    @ViewBuilder
    private func toothParameters(_ tooth: ProstheticTooth) -> some View {
        HStack(spacing: 10) {
            SteppedValue(
                label: "Largh.", value: tooth.widthMM, step: 0.2, format: "%.1f"
            ) { newValue in
                model.updateTooth(id: object.id) { $0.widthMM = max(newValue, 0.5) }
            }
            SteppedValue(
                label: "Alt.", value: tooth.heightMM, step: 0.2, format: "%.1f"
            ) { newValue in
                model.updateTooth(id: object.id) { $0.heightMM = max(newValue, 0.5) }
            }
            SteppedValue(
                label: "Spess.", value: tooth.depthMM, step: 0.2, format: "%.1f"
            ) { newValue in
                model.updateTooth(id: object.id) { $0.depthMM = max(newValue, 0.5) }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 22)

        HStack(spacing: 10) {
            Text("Numero")
                .font(Typography.numericSmall)
                .foregroundStyle(Palette.textSecondary)
            Menu("\(tooth.toothNumber)") {
                ForEach(Self.fdiQuadrants, id: \.name) { quadrant in
                    Menu(quadrant.name) {
                        ForEach(quadrant.numbers, id: \.self) { number in
                            Button("\(number)") { renumber(to: number) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .controlSize(.mini)
        .padding(.leading, 22)
        .padding(.bottom, 2)
    }

    /// Cambia il numero FDI, e con esso le misure standard.
    ///
    /// Posizione e asse **restano**: si corregge un numero sbagliato su un dente già posato nel
    /// punto giusto, e rimetterlo al centro del volume vorrebbe dire riposarlo da capo.
    private func renumber(to number: Int) {
        guard let standard = ProstheticTooth.standard(forToothNumber: number) else { return }
        model.updateTooth(id: object.id) { tooth in
            tooth.toothNumber = number
            tooth.widthMM = standard.widthMM
            tooth.heightMM = standard.heightMM
            tooth.depthMM = standard.depthMM
            // L'asse si ribalta passando da un'arcata all'altra: un dente superiore ha l'apice
            // sopra la corona, uno inferiore sotto. Tenere il verso vecchio metterebbe la
            // radice in bocca.
            if (tooth.axisMM.dot(standard.axisMM)) < 0 {
                tooth.axisMM = tooth.axisMM * -1
            }
            if tooth.label.isEmpty || Int(tooth.label) != nil {
                tooth.label = "\(number)"
            }
        }
    }

    private static let fdiQuadrants: [(name: String, numbers: [Int])] = [
        ("Superiore destro (1×)", Array(11...18)),
        ("Superiore sinistro (2×)", Array(21...28)),
        ("Inferiore sinistro (3×)", Array(31...38)),
        ("Inferiore destro (4×)", Array(41...48)),
    ]

    @ViewBuilder
    private func implantParameters(_ implant: ImplantPlacement) -> some View {
        // Tutte e tre passano da `resize`, che rigenera il profilo.
        //
        // Assegnare `model.diameterMM` direttamente — com'era — cambiava il numero e lasciava
        // il profilo vecchio: la cifra nell'elenco diceva 4,8 e la sagoma disegnata restava
        // quella da 4,1. Due valori per la stessa cosa, in disaccordo, senza un errore.
        HStack(spacing: 10) {
            SteppedValue(
                label: "Testa", value: implant.model.platformDiameterMM, step: 0.1, format: "%.1f"
            ) { newValue in
                model.updateImplant(id: object.id) { $0.model.resize(platformDiameterMM: newValue) }
            }
            SteppedValue(
                label: "Apice", value: implant.model.apexDiameterMM, step: 0.1, format: "%.1f"
            ) { newValue in
                model.updateImplant(id: object.id) { $0.model.resize(apexDiameterMM: newValue) }
            }
            SteppedValue(
                label: "L", value: implant.model.lengthMM, step: 0.5, format: "%.1f"
            ) { newValue in
                model.updateImplant(id: object.id) { $0.model.resize(lengthMM: newValue) }
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

            Button {
                model.selectedImplantID = object.id
                model.suggestAxisForSelectedImplant()
            } label: {
                Image(systemName: "wand.and.stars")
            }
            .help(
                "Cerca l'inclinazione più lontana dal canale e in osso migliore, entro venti "
                + "gradi. Propone: la scelta resta tua, e ⌘Z la annulla.")

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
            // La freccetta apre la riga. Serve ai tipi che non si selezionano — un canale, una
            // curva — perché anche loro hanno una nota da scrivere, e serve a tenere aperta una
            // riga mentre se ne guarda un'altra.
            Button {
                isManuallyExpanded.toggle()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                    .foregroundStyle(Palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Chiudi i dettagli" : "Mostra i dettagli")

            // L'occhio poi: è l'azione più frequente dell'elenco, e sta dove
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
        // Un clic seleziona **e** porta le viste sull'oggetto: `centreOnObject` fa tutt'e due.
        // C'erano due gesti, uno per il clic e uno per il doppio, e chiamavano la stessa
        // funzione: il commento prometteva una distinzione che il codice non faceva.
        .onTapGesture { model.centreOnObject(id: object.id) }
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
/// Un valore con due frecce per cambiarlo a passi esatti.
///
/// Non più privato di questo file: la finestra di registrazione ha lo stesso bisogno — un raggio
/// e una soglia da regolare con precisione — e riscriverlo lì sarebbe la stessa cosa con un nome
/// diverso, cioè due comportamenti destinati a divergere.
struct SteppedValue: View {

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

// MARK: - Anteprima della curva

/// La curva d'arcata disegnata in piccolo, vista dall'alto.
///
/// # A che cosa serve un disegno di quattro centimetri
///
/// A dire se la curva è quella giusta senza tornare sull'assiale. Una curva tracciata male —
/// troppo corta da un lato, con un punto fuori posto che la fa piegare — produce una panorex
/// storta, e il difetto si vede molto meglio nella forma d'insieme che scorrendo la striscia.
/// L'elenco degli oggetti è il posto in cui si guarda «che cosa c'è nel piano», e una curva è
/// l'unico oggetto la cui identità **è** la sua forma.
struct ArchCurveThumbnail: View {

    let curve: ArchCurve

    var body: some View {
        Canvas { context, size in
            let samples = curve.isUsable ? curve.resampled(count: 80) : []
            guard samples.count >= 2 else { return }

            // Proiezione sul piano assiale: la curva è per costruzione una funzione di x e y, e
            // la componente z non aggiunge niente a una vista dall'alto.
            // `CGFloat.` scritto per esteso: su macOS `CGFloat` è `Double`, e il nome da solo
            // lascia al compilatore due candidati fra cui non può scegliere.
            var minimum = CGPoint(
                x: CGFloat.greatestFiniteMagnitude, y: CGFloat.greatestFiniteMagnitude)
            var maximum = CGPoint(
                x: -CGFloat.greatestFiniteMagnitude, y: -CGFloat.greatestFiniteMagnitude)
            for sample in samples {
                minimum.x = min(minimum.x, sample.positionMM.x)
                minimum.y = min(minimum.y, sample.positionMM.y)
                maximum.x = max(maximum.x, sample.positionMM.x)
                maximum.y = max(maximum.y, sample.positionMM.y)
            }

            let span = max(maximum.x - minimum.x, maximum.y - minimum.y)
            guard span > 1e-6 else { return }
            // Isotropa e centrata: una curva schiacciata per riempire il riquadro direbbe che
            // l'arcata ha una forma che non ha, che è l'unica cosa che questa anteprima deve
            // dire bene.
            let inset: CGFloat = 4
            let scale = min(size.width - inset * 2, size.height - inset * 2) / span
            let centre = CGPoint(
                x: (minimum.x + maximum.x) / 2, y: (minimum.y + maximum.y) / 2)

            func point(_ mm: Vec3) -> CGPoint {
                CGPoint(
                    x: size.width / 2 + (CGFloat(mm.x) - centre.x) * scale,
                    // La y del paziente cresce verso il dorso; a schermo l'anteriore va in alto.
                    y: size.height / 2 - (CGFloat(mm.y) - centre.y) * scale)
            }

            var path = Path()
            path.move(to: point(samples[0].positionMM))
            for sample in samples.dropFirst() { path.addLine(to: point(sample.positionMM)) }
            context.stroke(path, with: .color(Palette.accent), lineWidth: 1.5)

            // I punti di controllo: sono ciò che si trascina, e vederne uno fuori posto è il
            // motivo per cui questa anteprima esiste.
            for control in curve.controlPointsMM {
                let position = point(control)
                context.fill(
                    Path(
                        ellipseIn: CGRect(
                            x: position.x - 2, y: position.y - 2, width: 4, height: 4)),
                    with: .color(Palette.textPrimary.opacity(0.8)))
            }
        }
        .background(Palette.viewportBackground.opacity(0.6))
        .clipShape(.rect(cornerRadius: 3))
    }
}
