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

            if let hint = model.activeTool.hint {
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
            ToolEntry(tool: .ellipseROI),
            ToolEntry(tool: .sphereROI),
            ToolEntry(tool: .text),
        ]

        if model.workMode.usesArchCurve {
            // In testa, non in fondo: in modo curvo è la prima cosa che si fa.
            result.insert(ToolEntry(tool: .archCurve), at: 1)
        } else {
            result.append(ToolEntry(tool: .archCurve))
        }
        result.append(ToolEntry(tool: .implant))
        result.append(ToolEntry(tool: .nerve))
        return result
    }
}

private struct ToolButton: View {

    @Bindable var model: AppModel
    let entry: ToolEntry

    @State private var isShowingVariants = false

    private var isActive: Bool { model.activeTool == entry.tool }

    var body: some View {
        Button {
            model.activeTool = entry.tool
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
        }
        .buttonStyle(.plain)
        .help(helpText)
        // Pressione prolungata per le varianti, come nelle palette a cui somiglia. Il clic
        // normale resta immediato: chi vuole la variante sa aspettare, chi vuole lo strumento
        // non deve.
        .onLongPressGesture(minimumDuration: 0.35) {
            guard !entry.variants.isEmpty else { return }
            isShowingVariants = true
        }
        .popover(isPresented: $isShowingVariants, arrowEdge: .trailing) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entry.variants) { variant in
                    Button {
                        model.activeTool = entry.tool
                        model.toolVariant = variant.id
                        isShowingVariants = false
                    } label: {
                        Label(variant.name, systemImage: variant.systemImage)
                            .font(Typography.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(
                                model.toolVariant == variant.id
                                    ? Palette.accent.opacity(0.2) : .clear,
                                in: .rect(cornerRadius: 4))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(width: 240)
        }
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
