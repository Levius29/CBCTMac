import SwiftUI

@main
struct CBCTMacApp: App {

    @State private var model = AppModel()

    var body: some Scene {
        Window("CBCTMac", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .task {
                    // Senza parser DICOM l'applicazione non aprirebbe nulla. Il fantoccio
                    // sintetico le dà qualcosa di reale da disegnare fin dal primo avvio, con
                    // misure note contro cui verificare — e senza toccare dati di pazienti.
                    await model.loadSyntheticPhantom()
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandMenu("Vista") {
                ForEach(ViewportLayout.allCases, id: \.self) { layout in
                    Button(layout.localizedName) { model.layout = layout }
                        .keyboardShortcut(
                            KeyEquivalent(layoutShortcut(layout)), modifiers: .command)
                }
                Divider()
                Button("Adatta alla finestra") { model.resetPlanes() }
                    .keyboardShortcut("0", modifiers: .command)
            }

            CommandMenu("Strumenti") {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Button(tool.localizedName) { model.activeTool = tool }
                }
                Divider()
                Button("Elimina misura selezionata") { model.removeSelectedAnnotation() }
                    .keyboardShortcut(.delete, modifiers: [])
                    .disabled(model.selectedAnnotationID == nil)
            }
        }
    }

    private func layoutShortcut(_ layout: ViewportLayout) -> Character {
        switch layout {
        case .single: return "1"
        case .grid2x2: return "2"
        case .onePlusThree: return "3"
        }
    }
}
