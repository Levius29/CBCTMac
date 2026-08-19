import AppKit
import ArchiveKit
import DICOMCore
import StudyKit
import SwiftUI
import VolumeKit

// Struttura della finestra principale.
//
// Disposizione dai mockup in docs/mockups/01-CBCTMac-main-2x2.png: toolbar unificata, banner
// ambra a tutta larghezza, poi barra laterale, griglia dei riquadri e ispettore affiancati, e
// una barra di stato in fondo.

struct ContentView: View {

    @Bindable var model: AppModel

    @State private var showSidebar = true
    @State private var showInspector = true

    /// Larghezze delle due colonne, ricordate fra le sessioni: chi allarga l'ispettore per vedere
    /// i parametri implantari lo vuole largo anche domani.
    @AppStorage("layout.sidebarWidth") private var sidebarWidth = Double(Metrics.sidebarWidth)
    @AppStorage("layout.inspectorWidth") private var inspectorWidth = Double(Metrics.inspectorWidth)

    var body: some View {
        Group {
            if model.volume == nil {
                // Senza uno studio aperto la finestra **è** l'archivio.
                //
                // Prima era la griglia dei riquadri con dentro il fantoccio sintetico, caricato
                // a ogni avvio: la prima cosa che si vedeva era l'unica che non interessa, e il
                // proprio lavoro stava dietro un menu. Adesso la griglia compare quando c'è
                // qualcosa da guardarci dentro.
                VStack(spacing: 0) {
                    DisclaimerBanner()
                    ArchiveHome(model: model, onOpenFolder: openStudyFolder)
                }
            } else {
                workspace
            }
        }
        .background(Palette.chrome)
        .toolbar { toolbarContent }
        .overlay { loadingOverlay }
        .sheet(isPresented: $model.isShowingShortcuts) { ShortcutsSheet() }
        .sheet(isPresented: $model.isShowingReorient) { ReorientSheet(model: model) }
        .sheet(isPresented: $model.isShowingArtifact) { ArtifactSheet(model: model) }
        .sheet(isPresented: $model.isShowingVerification) { VerificationSheet(model: model) }
        .sheet(isPresented: $model.isShowingScanRegistration) {
            ScanRegistrationSheet(model: model)
        }
        .sheet(isPresented: $model.isShowingGuide) { GuideSheet(model: model) }
        .sheet(isPresented: $model.isShowingSegmentation) { SegmentationSheet(model: model) }
        .sheet(isPresented: $model.isShowingArchive) { ArchiveSheet(model: model) }
        .sheet(isPresented: $model.isAskingToArchive) { ArchivePromptSheet(model: model) }
        .navigationTitle(windowTitle)
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            DisclaimerBanner()
            WorkModeBar(model: model)
            Divider().overlay(Palette.separator)

            HStack(spacing: 0) {
                if showSidebar {
                    LeftColumn(model: model)
                        .frame(width: CGFloat(sidebarWidth))
                    DraggableDivider(
                        axis: .vertical, value: $sidebarWidth,
                        // Sotto i 210 punti la palette degli strumenti va a capo male; sopra i
                        // 420 si ruba ai riquadri più di quanto la colonna sappia riempire.
                        range: 210...420, isInverted: true)
                }

                ViewportGrid(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if showInspector {
                    DraggableDivider(
                        axis: .vertical, value: $inspectorWidth, range: 240...460)
                    InspectorPanel(model: model)
                        .frame(width: CGFloat(inspectorWidth))
                }
            }

            Divider().overlay(Palette.separator)
            StatusBar(model: model)
        }
    }

    // MARK: Titolo

    /// Il titolo dice **chi**, non che cosa.
    ///
    /// Prima diceva il nome della serie — «CBCT mascellare» — che è la stessa stringa su ogni
    /// paziente e quindi non identifica niente. Il nome e la data dell'esame invece rispondono
    /// alla sola domanda per cui si guarda una barra del titolo: sto lavorando sulla persona
    /// giusta? Con più finestre aperte è l'unica cosa che le distingue.
    private var windowTitle: String {
        guard model.volume != nil else { return AppIcon.displayName }
        var parts: [String] = []
        if !model.patient.isAnonymous { parts.append(model.patient.displayName) }
        if let date = ArchiveKit.DICOMDate.displayShort(model.exam.studyDate) { parts.append(date) }
        if parts.isEmpty { parts.append(model.studyName) }
        return "\(AppIcon.displayName) — " + parts.joined(separator: " · ")
    }

    /// Sceglie una cartella e ne carica lo studio.
    ///
    /// Si apre una **cartella** e non un file: un CBCT è una serie di centinaia di file, e
    /// chiedere all'utente di selezionarli tutti sarebbe un dispetto.
    private func openStudyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Apri studio"
        panel.message = "Scegli la cartella che contiene le immagini DICOM"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.loadStudy(from: url) }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showSidebar.toggle()
            } label: {
                Label("Pannelli", systemImage: "sidebar.leading")
            }
            .help("Mostra o nasconde la colonna di sinistra")
        }

        // Annulla e ripeti nella barra, non solo da tastiera: l'etichetta dice **che cosa** si
        // sta per disfare, e senza vederla si preme ⌘Z alla cieca sperando di indovinare quante
        // volte.
        ToolbarItem {
            Button { model.undo() } label: {
                Label("Annulla", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .help(model.undoLabel.map { "Annulla: \($0)" } ?? "Niente da annullare")
        }

        ToolbarItem {
            Button { model.redo() } label: {
                Label("Ripeti", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .help(model.redoLabel.map { "Ripeti: \($0)" } ?? "Niente da ripetere")
        }

        // Il nome dello studio al centro della barra. Non è un vezzo preso dai visori
        // commerciali: è ciò che si guarda per essere sicuri di lavorare sul caso giusto, e sta
        // nel punto di massima attenzione dello schermo.
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(model.studyName)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(Palette.textPrimary)
                if let message = model.lastActionMessage {
                    Text(message)
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
            }
        }

        ToolbarItem {
            Button { model.isShowingShortcuts = true } label: {
                Label("Comandi", systemImage: "questionmark.circle")
            }
            .help("Legenda dei comandi da mouse e tastiera")
        }

        ToolbarItem {
            Button {
                openStudyFolder()
            } label: {
                Label("Apri", systemImage: "folder")
            }
            .help("Apri una cartella con uno studio DICOM")
        }

        ToolbarItem {
            Menu {
                ForEach(ViewportLayout.allCases, id: \.self) { layout in
                    Button {
                        model.layout = layout
                    } label: {
                        Label(layout.localizedName, systemImage: layout.systemImageName)
                    }
                }
            } label: {
                Label("Layout", systemImage: model.layout.systemImageName)
            }
            .help("Disposizione dei riquadri")
        }

        // La tendina degli strumenti non c'è più: adesso c'è la palette nella colonna di
        // sinistra, che mostra quale strumento è in mano senza doverla aprire e costa un gesto
        // invece di due. Resta qui il solo indicatore, che riporta lo stato senza duplicare il
        // comando — due posti da cui cambiare la stessa cosa sono due posti che si disallineano.
        ToolbarItem {
            Menu {
                ForEach(Tool.allCases, id: \.self) { tool in
                    Button {
                        model.activeTool = tool
                    } label: {
                        Label(tool.localizedName, systemImage: tool.systemImageName)
                    }
                }
            } label: {
                Label(model.activeTool.localizedName, systemImage: model.activeTool.systemImageName)
            }
            .help("Strumento attivo")
        }

        ToolbarItem {
            Button {
                model.resetPlanes()
            } label: {
                Label("Riorienta", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
            }
            .help("Riporta i riquadri all'inquadratura completa")
        }

        ToolbarItem {
            Button {
                showInspector.toggle()
            } label: {
                Label("Ispettore", systemImage: "sidebar.trailing")
            }
            .help("Mostra o nasconde l'ispettore")
        }
    }

    // MARK: Sovrapposizioni

    @ViewBuilder
    private var loadingOverlay: some View {
        if let message = model.loadingMessage {
            ZStack {
                Color.black.opacity(0.6)
                VStack(spacing: Metrics.spacingLarge) {
                    ProgressView()
                        .controlSize(.large)
                    Text(message)
                        .font(Typography.body)
                        .foregroundStyle(Palette.textPrimary)
                }
                .padding(Metrics.spacingLarge * 2)
                .background(Palette.chromeElevated, in: .rect(cornerRadius: Metrics.cornerRadius))
            }
            .ignoresSafeArea()
        }
    }
}

// MARK: - Banner

/// Striscia di avvertimento permanente.
///
/// Non è chiudibile né comprimibile, di proposito. È l'unico elemento dell'interfaccia che non
/// serve all'utente ma a chi guarda l'immagine dopo: finisce anche negli screenshot esportati,
/// così un'immagine estratta da qui non può essere scambiata per un referto.
struct DisclaimerBanner: View {
    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .bold))
            Text("USO NON DIAGNOSTICO — software non certificato come dispositivo medico")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(.black)
        .frame(maxWidth: .infinity)
        .frame(height: Metrics.bannerHeight)
        .background(Palette.warning)
    }
}

// MARK: - Barra di stato

struct StatusBar: View {

    let model: AppModel

    var body: some View {
        HStack(spacing: Metrics.spacingLarge) {
            Text(positionText)
            separator
            Text(densityText)
            separator
            Text(spacingText)
            Spacer()
            if !model.loadIssues.isEmpty {
                Label("\(model.loadIssues.count)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Palette.warning)
                    .help(model.loadIssues.joined(separator: "\n"))
            }
            Text(AppModel.buildIdentity)
                .foregroundStyle(Palette.textSecondary.opacity(0.7))
                .help(
                    AppModel.isBundled
                        ? "Avviata dal bundle 3DMED.app: identità completa, tipi di documento "
                            + "dichiarati."
                        : "Eseguibile SwiftPM senza bundle: il menu accanto alla mela porta il "
                            + "nome del file eseguibile e le finestre di dialogo dei file sono "
                            + "irregolari. Per un'app vera: ./Tools/make-app-bundle.sh")
        }
        .font(Typography.numericSmall)
        .foregroundStyle(Palette.textSecondary)
        .padding(.horizontal, Metrics.spacingLarge)
        .frame(height: Metrics.statusBarHeight)
        .background(Palette.chrome)
    }

    private var separator: some View {
        Text("│").foregroundStyle(Palette.separator)
    }

    /// Coordinate del mirino in LPS, con le lettere anatomiche invece degli assi x/y/z:
    /// «L 12,4  P −38,1  S 64,7» si legge senza dover ricordare l'orientamento del sistema.
    private var positionText: String {
        let p = model.hoverPositionMM ?? model.crosshairMM
        return String(format: "L %.1f   P %.1f   S %.1f mm", p.x, p.y, p.z)
            .replacingOccurrences(of: ".", with: ",")
            .replacingOccurrences(of: "-", with: "−")
    }

    private var densityText: String {
        guard let density = model.hoverDensity else {
            return "— \(model.densityUnit.symbol)"
        }
        return String(format: "%.0f %@", density, model.densityUnit.symbol)
            .replacingOccurrences(of: "-", with: "−")
    }

    private var spacingText: String {
        guard let geometry = model.volume?.geometry else { return "—" }
        let s = geometry.spacingMM
        if geometry.isIsotropic() {
            return String(format: "%.2f mm iso", s.x).replacingOccurrences(of: ".", with: ",")
        }
        return String(format: "%.2f × %.2f × %.2f mm", s.x, s.y, s.z)
            .replacingOccurrences(of: ".", with: ",")
    }
}
