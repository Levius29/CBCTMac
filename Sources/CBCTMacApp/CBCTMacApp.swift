import AppKit
import MeshKit
import StudyKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct CBCTMacApp: App {

    @State private var model = AppModel()

    init() {
        Self.exportIconAndExitIfRequested()
    }

    /// `--export-icon <cartella>` scrive l'iconset ed esce, senza aprire nulla.
    ///
    /// Nell'`init` e non in un `.task`: da lì la scena esisterebbe già, e chi costruisce il
    /// pacchetto si vedrebbe lampeggiare una finestra per poi trovarla chiusa da sola.
    ///
    /// Sta dentro l'applicazione e non in uno strumento a parte perché il disegno è SwiftUI e va
    /// reso da AppKit: un eseguibile separato dovrebbe duplicare la sorgente dell'icona, e due
    /// copie della stessa forma divergono alla prima correzione.
    @MainActor
    private static func exportIconAndExitIfRequested() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--export-icon"),
            flag + 1 < arguments.count
        else { return }

        // Inizializza AppKit senza avviarne il ciclo: `ImageRenderer` ne ha bisogno, il ciclo no.
        _ = NSApplication.shared

        let directory = URL(fileURLWithPath: arguments[flag + 1])
        do {
            let count = try AppIcon.exportIconset(to: directory)
            print("Scritti \(count) file in \(directory.path)")
            exit(count == AppIcon.iconsetSizes.count ? 0 : 1)
        } catch {
            print("Esportazione non riuscita: \(error)")
            exit(1)
        }
    }

    var body: some Scene {
        Window(AppIcon.displayName, id: "main") {
            ContentView(model: model)
                .sheet(isPresented: $model.isShowingReformat) {
                    ReformatSheet(model: model)
                }
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.dark)
                .task {
                    // L'eseguibile SPM non è un bundle e il Dock mostrerebbe l'icona generica
                    // del terminale. Vedi `AppIcon`.
                    AppIcon.install()

                    // Nessuno studio all'avvio: la finestra apre l'archivio, e da lì si sceglie
                    // che cosa guardare. Il fantoccio si carica dal menu quando serve.
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}

            CommandGroup(after: .newItem) {
                // Il ritaglio sta nel menu **e** nella barra degli strumenti. Il motore esisteva
                // da tempo senza un solo comando che lo raggiungesse, e una funzione che non si
                // trova equivale a una funzione che non c'è.
                Button("Ritaglia e ricampiona…") { model.isShowingReformat = true }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Button("Raddrizza sul piano occlusale…") { model.isShowingReorient = true }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Button("Riduci le strie da metallo…") { model.isShowingArtifact = true }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Button("Verifica di accuratezza…") { model.isShowingVerification = true }
                    .keyboardShortcut("v", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Button("Archivio…") { model.isShowingArchive = true }
                    .keyboardShortcut("a", modifiers: [.command, .shift])

                // Il fantoccio: non più all'avvio, ma raggiungibile. È il metro contro cui si
                // prova la catena di misura, ed è quello su cui lavora la verifica ⇧⌘V.
                Button("Carica il fantoccio di prova") {
                    Task { await model.loadSyntheticPhantom() }
                }

                Divider()

                Button("Segmentazione per soglia…") { model.isShowingSegmentation = true }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Divider()

                Button("Importa scansione intraorale…") { importScan() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Button("Registra la scansione…") { model.isShowingScanRegistration = true }
                    .disabled(model.scan == nil)

                Button("Costruisci la dima…") { model.isShowingGuide = true }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.scan == nil)

                Divider()

                Picker("Formato immagine", selection: Binding(
                    get: { model.imageExportFormat },
                    set: { model.imageExportFormat = $0 }
                )) {
                    ForEach(ImageExport.Format.allCases) { format in
                        Text(format.localizedName).tag(format)
                    }
                }

                Button("Stampa il riquadro…") { model.printFocusedViewport() }
                    .keyboardShortcut("p", modifiers: .command)
                    .disabled(model.volume == nil)

                Button("Esporta impianti e denti in STL…") { model.exportPlanGeometry() }
                    .disabled(model.implants.isEmpty && model.teeth.isEmpty)

                Button("Esporta la relazione…") { model.exportReport() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.volume == nil)

                Divider()

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

            // Annulla e ripeti nel loro posto di sistema, con le scorciatoie che tutti
            // conoscono. `replacing: .undoRedo` e non un menu nuovo: macOS ha già una voce per
            // questo, e metterne una seconda accanto significa che metà delle volte si prova
            // quella sbagliata.
            CommandGroup(replacing: .undoRedo) {
                Button(model.undoLabel.map { "Annulla \($0.lowercased())" } ?? "Annulla") {
                    model.undo()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!model.canUndo)

                Button(model.redoLabel.map { "Ripeti \($0.lowercased())" } ?? "Ripeti") {
                    model.redo()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!model.canRedo)
            }

            CommandGroup(replacing: .help) {
                Button("Comandi di CBCTMac") { model.isShowingShortcuts = true }
                    .keyboardShortcut("?", modifiers: [])
            }

            CommandMenu("Modo") {
                // Le cinque schede anche da tastiera: ⌃1…⌃5. Non ⌘ perché quelle sono già le
                // disposizioni, e due significati per la stessa combinazione sono un errore in
                // attesa.
                ForEach(Array(WorkMode.allCases.enumerated()), id: \.element) { index, mode in
                    Button(mode.localizedName) { model.activate(mode: mode) }
                        .keyboardShortcut(
                            KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                }
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
                // Le prime nove lettere della fila di casa non servono a nulla di mnemonico, e i
                // numeri sono presi: si usano le iniziali dove non collidono, che è la
                // convenzione dei visori — N per navigare, D per distanza, A per arcata.
                ForEach(Array(Tool.allCases.enumerated()), id: \.element) { _, tool in
                    Button(tool.localizedName) { model.activeTool = tool }
                        .keyboardShortcut(KeyEquivalent(tool.shortcut), modifiers: [])
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
    /// Importa una superficie da file. STL, PLY e OBJ, riconosciuti dal contenuto.
    ///
    /// La lettura sta fuori dal thread dell'interfaccia: un STL di uno scanner intraorale ha
    /// centinaia di migliaia di triangoli, e leggerlo sul main actor congelerebbe la finestra
    /// per il tempo che ci vuole.
    private func importScan() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Scegli la scansione intraorale (STL, PLY o OBJ)."
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Result { try MeshIO.load(url: url) }
            }.value

            switch outcome {
            case .success(let mesh):
                model.adoptScan(mesh)
            case .failure(let error):
                model.lastActionMessage =
                    (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
        }
    }

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
