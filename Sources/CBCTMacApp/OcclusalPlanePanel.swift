import DICOMCore
import SegmentKit
import SwiftUI

// Raddrizzare il volume sul piano occlusale.
//
// # Perché non è più una finestra
//
// Perché era **modale**, e i tre punti del piano occlusale stanno a quote diverse: due cuspidi e
// un incisivo non si vedono mai sulla stessa fetta, e trovarli richiede di navigare fra le viste.
// Con la finestra aperta il mirino non si poteva muovere, quindi «Posa punto» registrava tre
// volte lo stesso punto. Dal di fuori si presentava come un pulsante che fissa un punto a caso,
// ed era esattamente quel che faceva.
//
// Adesso i punti si posano facendo clic, in qualunque riquadro e anche nel 3D, e questo pannello
// sta nell'ispettore accanto alle immagini.
//
// # Perché pesa più di quanto sembri
//
// Nessuno se ne accorge finché non apre una CBCT con la testa inclinata, cioè quasi sempre. Su un
// volume storto ogni misura verticale si legge di traverso: l'altezza di cresta misurata su una
// fetta obliqua non è l'altezza di cresta, e l'errore cresce con l'inclinazione senza che nulla
// lo dichiari.

struct OcclusalPlanePanel: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            header
            Divider().overlay(Palette.separator)
            pointList
            Divider().overlay(Palette.separator)
            pickingSection
            Divider().overlay(Palette.separator)
            verdict
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack {
                Text("PIANO OCCLUSALE").font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(model.occlusalPointsMM.count)/3")
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
            Text(
                "Fai clic su due cuspidi e un incisivo: in qualunque riquadro, e anche nel 3D. "
                    + "⌥ clic su un punto lo toglie."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if model.activeTool != .occlusalPlane {
                Button("Prendi lo strumento piano occlusale") {
                    model.activeTool = .occlusalPlane
                }
                .font(Typography.label)
            }
        }
    }

    private var pointList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(model.occlusalPointsMM.enumerated()), id: \.offset) { index, point in
                HStack(spacing: Metrics.spacingSmall) {
                    Text("\(index + 1)")
                        .font(Typography.numericSmall)
                        .foregroundStyle(Palette.accent)
                        .frame(width: 14, alignment: .leading)
                    Text(
                        String(
                            format: "L %.1f  P %.1f  S %.1f", point.x, point.y, point.z
                        ).replacingOccurrences(of: ".", with: ",")
                    )
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    Spacer(minLength: 0)
                    Button {
                        model.removeOcclusalPoint(at: index)
                    } label: {
                        Image(systemName: "xmark.circle").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Palette.textSecondary)
                    .help("Togli questo punto")
                }
            }
            if model.occlusalPointsMM.count < 3 {
                Text("Mancano \(3 - model.occlusalPointsMM.count) punti.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
            }
            if !model.occlusalPointsMM.isEmpty {
                Button("Azzera i punti") { model.clearOcclusalPoints() }
                    .font(Typography.label)
                    .padding(.top, 2)
            }
        }
    }

    /// La soglia con cui il clic nel 3D decide che cosa ha colpito.
    private var pickingSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text("CLIC NEL 3D").font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)
            HStack {
                Text("Soglia").font(Typography.label).foregroundStyle(Palette.textSecondary)
                Slider(value: $model.occlusalPickThresholdGV, in: -500...3000, step: 50)
                Text("\(Int(model.occlusalPickThresholdGV)) GV")
                    .font(Typography.numericSmall)
                    .frame(width: 70, alignment: .trailing)
            }
            Text(
                "Nel 3D la profondità di un clic non è data: la decide l'anatomia, prendendo la "
                    + "prima superficie che il raggio incontra sopra questa soglia. Troppo bassa "
                    + "e si prende la guancia davanti al dente."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// I passi offerti: quello del volume, poi i più grossolani.
    private var spacingOptions: [Double] {
        guard let geometry = model.volume?.geometry else {
            return VolumeResampler.spacingPresetsMM
        }
        return VolumeResampler.spacingOptionsMM(for: geometry)
    }

    @ViewBuilder
    private var verdict: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            if let tilt = model.occlusalTiltDegrees {
                HStack {
                    Text("Inclinazione")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                    Spacer()
                    Text(
                        String(format: "%.1f°", tilt).replacingOccurrences(of: ".", with: ",")
                    )
                    .font(Typography.numeric)
                    .foregroundStyle(tilt < 2 ? Palette.textSecondary : Palette.textPrimary)
                }
                if tilt < 2 {
                    // Risponde alla domanda che ci si pone davvero: vale la pena ricampionare?
                    Text(
                        "Sotto i due gradi non cambia nulla di leggibile, e ricampionare costa "
                            + "una copia del volume e un po' di nitidezza per interpolazione."
                    )
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach(model.occlusalProblems, id: \.self) { problem in
                Text("• \(problem)")
                    .font(Typography.label)
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("Passo").font(Typography.label).foregroundStyle(Palette.textSecondary)
                Picker("", selection: $model.reorientSpacingMM) {
                    // Il passo del volume in cima, marcato: è il valore predefinito, ed è l'unico
                    // che non butta via risoluzione.
                    ForEach(Array(spacingOptions.enumerated()), id: \.element) { index, value in
                        Text(
                            index == 0
                                ? "\(InspectorPanel.spacingText(value)) — originale"
                                : InspectorPanel.spacingText(value)
                        ).tag(value)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            Label(
                "Raddrizzare **ricostruisce** il volume su una griglia ruotata, quindi un po' di "
                    + "nitidezza si perde comunque: è il prezzo dell'operazione, non un difetto. "
                    + "Un passo più grossolano dell'originale ne toglie dell'altra.",
                systemImage: "exclamationmark.circle"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            Label(
                "Il volume raddrizzato è un volume nuovo, in un riferimento nuovo. Misure, "
                    + "impianti e curve vengono trasformati con la stessa rotazione, quindi "
                    + "continuano a indicare lo stesso tessuto.",
                systemImage: "info.circle"
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if let failure = model.reorientFailure {
                Text(failure)
                    .font(Typography.label)
                    .foregroundStyle(Palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(model.isReorienting ? "Raddrizzamento…" : "Raddrizza") {
                model.applyOcclusalReorientation()
            }
            .disabled(
                model.occlusalPointsMM.count < 3 || model.isReorienting
                    || !model.occlusalProblems.isEmpty)
            .frame(maxWidth: .infinity)
        }
    }
}
