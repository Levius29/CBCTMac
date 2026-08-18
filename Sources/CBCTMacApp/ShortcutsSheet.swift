import StudyKit
import SwiftUI

// La legenda dei comandi.
//
// # Perché serve, e perché non basta scriverli nei menu
//
// I comandi che contano qui non sono voci di menu: sono **gesti del mouse con modificatori** —
// ⇧ per inclinare il taglio, ⌥ per la panoramica, ⌥ clic per cancellare un punto — e quelli non
// compaiono da nessuna parte. Un gesto che nessuno documenta è un gesto che non esiste: chi non
// lo scopre per caso non lo userà mai, e chi lo scopre lo dimentica fino alla sessione dopo.
//
// # Perché una finestra e non un pannello sempre visibile
//
// Perché si consulta due volte e poi si sa. Una tabella sempre a schermo ruberebbe spazio
// all'immagine per il resto della vita del programma, per un'informazione che serve la prima
// settimana. `?` la apre, Esc la chiude.

struct ShortcutsSheet: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            HStack {
                Text("Comandi")
                    .font(Typography.sectionHeader)
                Spacer()
                Text("? per riaprire questa finestra")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
            }

            ScrollView {
                HStack(alignment: .top, spacing: Metrics.spacingLarge * 2) {
                    VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
                        group("Nei riquadri", mouse)
                        group("Mirino", crosshair)
                    }
                    VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
                        group("Strumenti", tools)
                        group("Modi di lavoro", modes)
                        group("Generali", general)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Chiudi") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Metrics.spacingLarge)
        .frame(width: 720, height: 520)
        .background(Palette.chrome)
    }

    // MARK: Le voci

    private typealias Entry = (keys: String, what: String)

    private var mouse: [Entry] {
        [
            ("Trascina", "Sposta l'immagine"),
            ("Rotella", "Scorre le fette"),
            ("⌘ Rotella / pinch", "Zoom ancorato al puntatore"),
            ("Clic", "Porta il mirino sul punto"),
            ("Doppio clic", "Ingrandisce il riquadro a tutta finestra"),
            ("⌥ Trascina", "Panoramica, anche con uno strumento in mano"),
            ("⇧ Trascina ↔", "Inclina il taglio: ruota gli altri due piani"),
            ("⇧ Trascina ↕", "Raddrizza l'immagine nel suo piano"),
            ("Tasto destro", "Finestra e livello"),
        ]
    }

    private var crosshair: [Entry] {
        [
            ("Trascina una linea", "Sposta la fetta che quella linea rappresenta"),
            ("Trascina una maniglia", "Ruota il taglio, entrambe le linee insieme"),
            ("⌥ Trascina maniglia", "Ruota solo quella linea"),
        ]
    }

    private var tools: [Entry] {
        Tool.allCases.map { (String($0.shortcut).uppercased(), $0.localizedName) }
            + [("Tieni premuta l'icona", "Varianti dello strumento")]
    }

    private var modes: [Entry] {
        WorkMode.allCases.enumerated().map { index, mode in
            ("⌃\(index + 1)", mode.localizedName)
        }
    }

    private var general: [Entry] {
        [
            ("⌘Z / ⇧⌘Z", "Annulla e ripeti"),
            ("⌘0", "Adatta le viste alla finestra"),
            ("⌘S", "Salva il piano"),
            ("⌘E", "Esporta l'immagine del riquadro attivo"),
            ("⇧⌘R", "Ritaglia e ricampiona il volume"),
            ("⌫", "Cancella la misura selezionata"),
        ]
    }

    @ViewBuilder
    private func group(_ title: String, _ entries: [Entry]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)
            ForEach(entries, id: \.keys) { entry in
                HStack(alignment: .firstTextBaseline, spacing: Metrics.spacing) {
                    Text(entry.keys)
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.accent)
                        // Larghezza fissa: le combinazioni incolonnate si scorrono con l'occhio,
                        // sparse no. È tutto il motivo per cui una legenda è una tabella.
                        .frame(width: 132, alignment: .leading)
                    Text(entry.what)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
        }
    }
}
