import StudyKit
import SwiftUI

// La palette degli strumenti.
//
// # Perché una griglia di icone e non un menu a tendina
//
// Il menu nella barra in alto c'era già, e ha due difetti che si sommano. Non dice **quale**
// strumento è attivo se non aprendolo, quindi si clicca sull'immagine senza sapere che cosa
// succederà; e costa due gesti — apri, scegli — per una cosa che si cambia venti volte in una
// sessione. Una griglia mostra lo stato e costa un gesto.
//
// # Le varianti, e il triangolino
//
// Righello e goniometro hanno varianti — distanza, spezzata, perimetro; angolo a tre punti, fra
// due rette — e nei visori commerciali si raggiungono da un triangolino nell'angolo dell'icona.
// È la collocazione giusta: la variante sta **sullo strumento** che modifica, non in un menu
// lontano dove bisogna ricordarsi che esiste.

/// Uno strumento della palette, con le sue eventuali varianti.
struct ToolEntry: Identifiable {
    let tool: Tool
    var variants: [ToolVariant] = []
    var id: String { tool.rawValue }
}

/// Variante di uno strumento: cambia che cosa produce, non come si usa.
struct ToolVariant: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String
}

struct ToolPalette: View {

    @Bindable var model: AppModel

    /// Quattro per riga: con icone da 30 punti sta in una colonna da 260 senza stringersi, ed è
    /// il numero che tiene gli strumenti di misura su una riga sola.
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(entries) { entry in
                    ToolButton(model: model, entry: entry)
                }
            }

            // La curva proposta sta accanto allo strumento arcata, non in un menu: è
            // un'alternativa al disegnarla a mano, e va offerta nel momento in cui si sta per
            // farlo a mano.
            if model.activeTool == .archCurve || model.workMode.usesArchCurve {
                Button {
                    model.suggestArchCurve()
                } label: {
                    Label("Proponi la curva dall'anatomia", systemImage: "wand.and.stars")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.accent)
                .disabled(model.volume == nil)
                .help("Cerca l'arcata alla quota del mirino. Se non la trova, lo dice.")

                // ⌥ clic cancella un punto, e nessuno lo scopre da solo. Il pulsante fa la stessa
                // cosa sul punto scelto, e sta acceso solo quando c'è un punto scelto — così dice
                // anche *che* un punto si può scegliere.
                Button {
                    model.removeSelectedArchPoint()
                } label: {
                    Label("Togli il punto scelto", systemImage: "minus.circle")
                        .font(Typography.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(
                    model.selectedArchPointIndex == nil ? Palette.textSecondary : Palette.danger)
                .disabled(model.selectedArchPointIndex == nil)
                .help("Fai prima clic sul punto da togliere. Equivale a ⌥ clic sul punto.")
            }

            if let hint = model.activeToolHint {
                Text(hint)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Gli strumenti che hanno senso nel modo di lavoro corrente.
    ///
    /// **Contestuali e non tutti sempre**: in «Rivedi» non si modifica nulla, e in modo curvo lo
    /// strumento arcata è il primo che serve. Una palette che mostra sempre tutto costringe a
    /// cercare, e mostra comandi che in quel momento non fanno niente.
    private var entries: [ToolEntry] {
        guard model.workMode.isEditable else {
            return [ToolEntry(tool: .navigate)]
        }

        var result: [ToolEntry] = [
            ToolEntry(tool: .navigate),
            ToolEntry(
                tool: .distance,
                variants: [
                    ToolVariant(id: "distance", name: "Distanza fra due punti", systemImage: "ruler"),
                    ToolVariant(id: "polyline", name: "Spezzata", systemImage: "scribble"),
                    ToolVariant(id: "perimeter", name: "Perimetro chiuso", systemImage: "hexagon"),
                ]),
            ToolEntry(
                tool: .angle,
                variants: [
                    ToolVariant(id: "three", name: "Angolo a tre punti", systemImage: "angle"),
                    ToolVariant(
                        id: "lines", name: "Angolo fra due rette",
                        systemImage: "line.diagonal.arrow"),
                ]),
            ToolEntry(
                tool: .ellipseROI,
                variants: [
                    ToolVariant(id: "ellipse", name: "ROI ellittica", systemImage: "oval"),
                    ToolVariant(
                        id: "polygon", name: "ROI poligonale", systemImage: "pentagon"),
                ]),
            ToolEntry(tool: .sphereROI),
            ToolEntry(
                tool: .text,
                variants: [
                    ToolVariant(id: "note", name: "Nota di testo", systemImage: "textformat"),
                    ToolVariant(
                        id: "arrow", name: "Freccia con nota",
                        systemImage: "arrow.up.left"),
                ]),
            ToolEntry(tool: .profile),
            ToolEntry(tool: .freehand),
        ]

        if model.workMode.usesArchCurve {
            // In testa, non in fondo: in modo curvo è la prima cosa che si fa.
            result.insert(ToolEntry(tool: .archCurve), at: 1)
        } else {
            result.append(ToolEntry(tool: .archCurve))
        }
        // Il dente **prima** dell'impianto, e non è un dettaglio d'ordine: la palette
        // suggerisce la sequenza, e la sequenza corretta è protesi prima, impianto sotto.
        result.append(ToolEntry(tool: .prostheticTooth))
        result.append(ToolEntry(tool: .implant))
        result.append(ToolEntry(tool: .nerve))
        return result
    }
}

private struct ToolButton: View {

    @Bindable var model: AppModel
    let entry: ToolEntry

    private var isActive: Bool { model.activeTool == entry.tool }

    // # Perché `Menu` con azione primaria e non una pressione prolungata
    //
    // Prima erano un `Button` con `.onLongPressGesture` e un `.popover`, e non succedeva niente:
    // il gesto del bottone e quello di pressione prolungata si contendono lo stesso evento, e
    // vince il bottone. Il rimedio non è insistere con i gesti — è usare il controllo che AppKit
    // ha già per questo: un menu con un'azione primaria fa la cosa ovvia al clic e apre l'elenco
    // se si tiene premuto, esattamente come le palette a cui somiglia.
    var body: some View {
        Menu {
            ForEach(entry.variants) { variant in
                Button {
                    model.activeTool = entry.tool
                    model.toolVariant = variant.id
                } label: {
                    Label(variant.name, systemImage: variant.systemImage)
                }
            }
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 13))
                .frame(width: 30, height: 28)
                .background(
                    isActive ? Palette.accent.opacity(0.22) : Palette.chromeElevated,
                    in: .rect(cornerRadius: 5)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(isActive ? Palette.accent : .clear, lineWidth: 1)
                )
                // Il triangolino in basso a destra: dice che lo strumento ha varianti, senza
                // occupare un'altra casella della griglia.
                .overlay(alignment: .bottomTrailing) {
                    if !entry.variants.isEmpty {
                        Path { path in
                            path.move(to: CGPoint(x: 6, y: 6))
                            path.addLine(to: CGPoint(x: 6, y: 0))
                            path.addLine(to: CGPoint(x: 0, y: 6))
                            path.closeSubpath()
                        }
                        .fill(isActive ? Palette.accent : Palette.textSecondary)
                        .frame(width: 6, height: 6)
                        .padding(2)
                    }
                }
                .foregroundStyle(isActive ? Palette.accent : Palette.textPrimary)
                .contentShape(.rect)
        } primaryAction: {
            model.activeTool = entry.tool
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(helpText)
    }

    private var iconName: String {
        // Con una variante scelta l'icona la segue: è il modo più diretto di dire quale delle
        // varianti è in mano, senza scriverlo da qualche parte.
        if isActive, let variant = entry.variants.first(where: { $0.id == model.toolVariant }) {
            return variant.systemImage
        }
        return entry.tool.systemImageName
    }

    private var helpText: String {
        entry.variants.isEmpty
            ? entry.tool.localizedName
            : "\(entry.tool.localizedName) — tieni premuto per le varianti"
    }
}
