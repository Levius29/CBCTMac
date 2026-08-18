import DICOMCore
import StudyKit
import SwiftUI

// Elenco degli studi.
//
// Struttura ad albero paziente → data → serie, con i metadati della serie come **righe figlie**
// e non come sottotitolo: viene dai mockup ed è la scelta giusta, perché il numero di immagini
// e la spaziatura sono le due cose che si controllano prima di aprire una serie, e in un
// sottotitolo grigio si perdono.
//
// I volumi derivati — ritagli, ricampionamenti — compaiono **annidati sotto quello da cui
// vengono**, non in un elenco piatto. È l'unico posto in cui la catena di provenienza si vede, ed
// è ciò che rende evidente che il ritaglio non ha sostituito l'originale: prima lo sostituiva, e
// non c'era modo di accorgersene se non cercando l'originale e non trovandolo più.

struct StudySidebar: View {

    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STUDI")
                .font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)
                .padding(.horizontal, Metrics.spacingLarge)
                .padding(.vertical, Metrics.spacing + 2)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let volume = model.volume {
                        studyTree(volume: volume)
                    } else {
                        Text("Nessuno studio aperto")
                            .font(Typography.label)
                            .foregroundStyle(Palette.textSecondary)
                            .padding(.horizontal, Metrics.spacingLarge)
                    }
                }
                .padding(.horizontal, Metrics.spacing)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            if !model.loadIssues.isEmpty {
                Divider().overlay(Palette.separator)
                VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                    ForEach(model.loadIssues, id: \.self) { issue in
                        Label(issue, systemImage: "exclamationmark.triangle.fill")
                            .font(Typography.label)
                            .foregroundStyle(Palette.warning)
                    }
                }
                .padding(Metrics.spacing)
            }
        }
        .background(Palette.chrome)
    }

    @ViewBuilder
    private func studyTree(volume: Volume) -> some View {
        TreeRow(
            icon: "person.crop.square", title: "PAZIENTE", indent: 0,
            isSelected: false, isBold: true)
        TreeRow(icon: "calendar", title: "Studio aperto", indent: 1, isSelected: false)

        ForEach(model.library.entries) { entry in
            let isSelected = entry.id == model.library.selectedID
            TreeRow(
                icon: entry.provenance.parentID == nil ? "cube" : "crop",
                title: entry.name,
                // Il rientro viene dalla profondità nella catena: un ritaglio del ritaglio sta
                // due gradini dentro, e si vede a colpo d'occhio da dove viene.
                indent: 2 + model.library.depth(of: entry.id),
                isSelected: isSelected,
                tint: isSelected ? Palette.accent : nil
            )
            .contentShape(.rect)
            .onTapGesture { model.selectVolume(entry.id) }
            .contextMenu {
                Button("Mostra questo volume") { model.selectVolume(entry.id) }
                // Il volume di partenza non si toglie: è l'unica copia dei dati letti, e
                // ricrearlo vuol dire riaprire lo studio.
                Button("Rimuovi", role: .destructive) { model.removeVolume(entry.id) }
                    .disabled(entry.provenance.parentID == nil)
            }
            .help(model.library.provenanceDescription(of: entry.id))

            if isSelected {
                let geometry = volume.geometry
                let indent = 3 + model.library.depth(of: entry.id)
                TreeRow(
                    icon: "photo.stack", title: "\(geometry.sliceCount) img",
                    indent: indent, isSelected: false, isSecondary: true)
                TreeRow(
                    icon: "square.stack.3d.up", title: spacingLabel(geometry),
                    indent: indent, isSelected: false, isSecondary: true)
                TreeRow(
                    icon: "ruler", title: dimensionLabel(geometry),
                    indent: indent, isSelected: false, isSecondary: true)
            }
        }
    }

    private func spacingLabel(_ geometry: VolumeGeometry) -> String {
        let s = geometry.spacingMM
        if geometry.isIsotropic() {
            return String(format: "%.2f mm", s.x).replacingOccurrences(of: ".", with: ",")
        }
        return String(format: "%.2f × %.2f × %.2f mm", s.x, s.y, s.z)
            .replacingOccurrences(of: ".", with: ",")
    }

    private func dimensionLabel(_ geometry: VolumeGeometry) -> String {
        let size = geometry.physicalSizeMM
        return String(format: "%.0f × %.0f × %.0f mm", size.x, size.y, size.z)
    }
}

// MARK: - Riga dell'albero

struct TreeRow: View {

    let icon: String
    let title: String
    let indent: Int
    let isSelected: Bool
    var isBold: Bool = false
    var isSecondary: Bool = false
    var tint: Color?

    var body: some View {
        HStack(spacing: Metrics.spacing) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .frame(width: 16)
            Text(title)
                .font(isBold ? Typography.body.weight(.medium) : Typography.body)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(foreground)
        .padding(.leading, CGFloat(indent) * 14 + Metrics.spacing)
        .padding(.trailing, Metrics.spacing)
        .padding(.vertical, 5)
        .background(
            isSelected ? Palette.accent.opacity(0.18) : .clear,
            in: .rect(cornerRadius: 5)
        )
    }

    private var foreground: Color {
        if let tint { return tint }
        return isSecondary ? Palette.textSecondary : Palette.textPrimary
    }
}
