import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

            CommandGroup(after: .newItem) {
                Button("Apri piano…") { openPlan() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Button("Salva piano…") { savePlan() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.volume == nil)

                Divider()

                Button("Esporta immagine…") { exportImage() }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.volume == nil)
            }

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

    // MARK: Documenti
    //
    // Esplicitamente `@MainActor`: tutti questi metodi leggono o scrivono `AppModel`, che è
    // isolato al main actor, e presentano pannelli AppKit, che vanno presentati da lì.

    @MainActor
    private func savePlan() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "piano.cbctplan"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try ProjectDocument(from: model).write(to: url)
        } catch {
            report(error, title: "Salvataggio non riuscito")
        }
    }

    @MainActor
    private func openPlan() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try ProjectDocument.read(from: url)
            let warnings = document.apply(to: model)
            if !warnings.isEmpty {
                report(
                    message: warnings.joined(separator: "\n"),
                    title: "Piano aperto con avvisi",
                    style: .warning)
            }
        } catch {
            report(error, title: "Apertura non riuscita")
        }
    }

    @MainActor
    private func exportImage() {
        guard let plane = model.planes[model.focusedSlot] else { return }

        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.focusedSlot.localizedName.lowercased()).png"
        panel.allowedContentTypes = [.png]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            // Risoluzione fissa e generosa, indipendente da quella della finestra: chi esporta
            // vuole un'immagine da guardare altrove, non una copia di quanto sta a schermo.
            try ImageExport.exportPNG(
                plane: plane, model: model, pixelWidth: 1600, pixelHeight: 1200, to: url)
        } catch {
            report(error, title: "Esportazione non riuscita")
        }
    }

    @MainActor
    private func report(_ error: Error, title: String) {
        report(
            message: error.localizedDescription, title: title, style: .warning)
    }

    @MainActor
    private func report(message: String, title: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    private func layoutShortcut(_ layout: ViewportLayout) -> Character {
        switch layout {
        case .single: return "1"
        case .grid2x2: return "2"
        case .onePlusThree: return "3"
        case .panoramic: return "4"
        }
    }
}
