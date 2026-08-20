import AppKit
import SwiftUI

// La galleria delle istantanee.
//
// # Perché tenerle nel caso invece di esportarle e basta
//
// Perché esportare produce un file e finisce lì: per confrontare due inquadrature bisogna
// salvarle entrambe e aprirle fuori dal programma. Tenute nel caso restano accanto al piano, si
// rinominano, e la relazione le usa al posto di quelle automatiche — così le figure del
// documento sono quelle scelte guardando, non quelle che capitavano quando si è premuto
// esporta.

struct SnapshotGallery: View {

    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 6)]

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Button {
                    model.captureSnapshot()
                } label: {
                    Label("Scatta il riquadro attivo", systemImage: "camera")
                        .font(Typography.label)
                }
                .disabled(model.volume == nil)
                Spacer(minLength: 0)
            }

            if model.snapshots.isEmpty {
                Text(
                    "Nessuna istantanea. Inquadra ciò che vuoi mostrare e scatta: le immagini "
                    + "finiscono nella relazione al posto di quelle automatiche."
                )
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(model.snapshots) { snapshot in
                        SnapshotThumbnail(model: model, snapshot: snapshot)
                    }
                }

                if model.archivedExamID == nil {
                    // Le immagini vivono nella cartella dell'esame archiviato. Senza archivio
                    // restano in memoria e si perdono chiudendo: dirlo prima è meglio che
                    // lasciarlo scoprire riaprendo.
                    Label(
                        "Questo esame non è in archivio: le istantanee si perdono chiudendolo.",
                        systemImage: "exclamationmark.triangle")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct SnapshotThumbnail: View {

    let model: AppModel
    let snapshot: AppModel.Snapshot

    @State private var isRenaming = false
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let data = model.snapshotImages[snapshot.id],
                    let image = NSImage(data: data)
                {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Rectangle().fill(Palette.chromeElevated)
                }
            }
            .frame(height: 68)
            .clipShape(.rect(cornerRadius: 3))
            .overlay(
                RoundedRectangle(cornerRadius: 3).stroke(Palette.separator, lineWidth: 1))

            if isRenaming {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(Typography.numericSmall)
                    .onSubmit {
                        model.renameSnapshot(draft, id: snapshot.id)
                        isRenaming = false
                    }
            } else {
                Text(snapshot.title)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) {
            draft = snapshot.title
            isRenaming = true
        }
        .contextMenu {
            Button("Rinomina") {
                draft = snapshot.title
                isRenaming = true
            }
            Button("Esporta…") { export() }
            Divider()
            Button("Elimina", role: .destructive) { model.removeSnapshot(id: snapshot.id) }
        }
        .help(snapshot.caption)
    }

    private func export() {
        guard let data = model.snapshotImages[snapshot.id] else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = snapshot.title + ".png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}
