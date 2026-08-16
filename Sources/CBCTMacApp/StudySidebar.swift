import DICOMCore
import SwiftUI

// Elenco degli studi.
//
// Struttura ad albero paziente → data → serie, con i metadati della serie come **righe figlie**
// e non come sottotitolo: viene dai mockup ed è la scelta giusta, perché il numero di immagini
// e la spaziatura sono le due cose che si controllano prima di aprire una serie, e in un
// sottotitolo grigio si perdono.
//
// Finché non c'è il parser DICOM mostra la sola voce del fantoccio sintetico. La struttura è
// però già quella definitiva, così l'innesto del parser non richiede di rifare la vista.

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
                        phantomTree(volume: volume)
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
    private func phantomTree(volume: Volume) -> some View {
        TreeRow(
            icon: "person.crop.square", title: "FANTOCCIO_SINTETICO", indent: 0,
            isSelected: false, isBold: true)
        TreeRow(icon: "calendar", title: "Generato in memoria", indent: 1, isSelected: false)
        TreeRow(
            icon: "cube", title: "Cubo 20 mm e sfere", indent: 2, isSelected: true,
            tint: Palette.accent)

        let geometry = volume.geometry
        TreeRow(
            icon: "photo.stack",
            title: "\(geometry.sliceCount) img",
            indent: 3,
            isSelected: false,
            isSecondary: true)
        TreeRow(
            icon: "square.stack.3d.up",
            title: spacingLabel(geometry),
            indent: 3,
            isSelected: false,
            isSecondary: true)
        TreeRow(
            icon: "ruler",
            title: dimensionLabel(geometry),
            indent: 3,
            isSelected: false,
            isSecondary: true)
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
