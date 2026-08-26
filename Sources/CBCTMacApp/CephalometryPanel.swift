import CephKit
import DICOMCore
import SwiftUI

// Il pannello della cefalometria.
//
// # Perché non è una finestra a parte
//
// Perché i reperi si segnano facendo clic sui riquadri, e una finestra modale li coprirebbe. Sta
// nell'ispettore, accanto alle immagini, e resta aperto mentre si lavora.
//
// # Perché la definizione del repere è grande quanto il suo nome
//
// Un repere segnato nel posto sbagliato non produce un errore: produce un numero, plausibile e
// falso. La definizione accanto — «punto più profondo della concavità del mascellare» — è l'unica
// cosa che impedisce di segnare il punto A un centimetro più in alto e leggere poi un SNA che
// non c'entra niente.

struct CephalometryPanel: View {

    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingLarge) {
            header
            Divider().overlay(Palette.separator)
            currentLandmark
            Divider().overlay(Palette.separator)
            landmarkList
            Divider().overlay(Palette.separator)
            profileSection
            Divider().overlay(Palette.separator)
            measuresSection
        }
    }

    // MARK: Intestazione

    private var placedCount: Int {
        CephLandmark.allCases.filter { model.cephTracing.isComplete($0) }.count
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            HStack {
                Text("CEFALOMETRIA").font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                Text("\(placedCount)/\(CephLandmark.allCases.count)")
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                // # La via d'uscita, che non c'era
                //
                // Il pannello lo accendeva la voce di menu e non lo spegneva nessuno: restava in
                // cima all'ispettore per il resto della sessione. Finché ci stava copriva gli
                // altri contesti, e chi l'aveva aperto per curiosità si ritrovava senza il
                // pannello dell'impianto e senza un modo di riaverlo.
                //
                // Chiudere non cancella: «Cancella il tracciato» è il comando accanto, e sono due
                // gesti diversi. Uno che li facesse insieme non verrebbe premuto mai.
                Button {
                    model.closeCephalometry()
                } label: {
                    Label("Chiudi", systemImage: "xmark.circle")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Chiude la cefalometria. Il tracciato resta dov'è.")
            }
            Text(
                "Gli angoli si calcolano sulla proiezione dei reperi sul piano sagittale mediano. "
                    + "Gli intervalli di riferimento vengono dalle analisi classiche su adulti: "
                    + "su un paziente in crescita dicono poco, e non sono una diagnosi."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            if !model.cephTracing.isEmpty {
                Button("Cancella il tracciato") { model.clearCephTracing() }
                    .font(Typography.label)
            }
        }
    }

    // MARK: Il repere in corso

    @ViewBuilder
    private var currentLandmark: some View {
        if let landmark = model.cephLandmarkToPlace {
            VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
                HStack(spacing: Metrics.spacingSmall) {
                    Text(landmark.abbreviation)
                        .font(Typography.numeric)
                        .foregroundStyle(Palette.accent)
                    Text(landmark.localizedName).font(Typography.body)
                    Spacer()
                    if landmark.isBilateral {
                        Picker("", selection: $model.cephSide) {
                            Text("Destro").tag(CephSide.right)
                            Text("Sinistro").tag(CephSide.left)
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .frame(width: 130)
                    }
                }
                Text(landmark.definition)
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.activeTool != .cephalometry {
                    Button("Prendi lo strumento cefalometria") {
                        model.activeTool = .cephalometry
                    }
                    .font(Typography.label)
                } else {
                    Text("Fai clic dove sta il punto, in qualunque riquadro. ⌥ clic per toglierlo.")
                        .font(Typography.label)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
        } else {
            Text("Tracciato completo. Scegli un repere qui sotto per correggerlo.")
                .font(Typography.label)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    // MARK: Elenco dei reperi

    private var landmarkList: some View {
        VStack(alignment: .leading, spacing: Metrics.spacing) {
            ForEach(CephLandmarkGroup.allCases, id: \.self) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.localizedName.uppercased())
                        .font(Typography.sectionHeader)
                        .foregroundStyle(Palette.textSecondary)
                    ForEach(group.landmarks, id: \.self) { landmark in
                        landmarkRow(landmark)
                    }
                }
            }
        }
    }

    private func landmarkRow(_ landmark: CephLandmark) -> some View {
        let sides = model.cephTracing.sides(of: landmark)
        let complete = model.cephTracing.isComplete(landmark)
        let isNext = landmark == model.cephLandmarkToPlace

        return HStack(spacing: Metrics.spacingSmall) {
            // Un pallino pieno per completo, vuoto per mancante, mezzo per un lato solo di un
            // repere bilaterale: lo stato si legge senza aprire niente.
            Image(
                systemName: complete
                    ? "largecircle.fill.circle"
                    : (sides.isEmpty ? "circle" : "circle.lefthalf.filled")
            )
            .font(.system(size: 10))
            .foregroundStyle(complete ? Palette.safe : Palette.textSecondary)

            Text(landmark.abbreviation)
                .font(Typography.numericSmall)
                .frame(width: 34, alignment: .leading)
                .foregroundStyle(isNext ? Palette.accent : Palette.textPrimary)

            Text(landmark.localizedName)
                .font(Typography.label)
                .foregroundStyle(isNext ? Palette.accent : Palette.textPrimary)
                .lineLimit(1)

            Spacer(minLength: Metrics.spacingSmall)

            if let spread = model.cephTracing.spreadMM(of: landmark) {
                // Quanto distano fra loro i due lati. Un valore inatteso è un lato segnato male,
                // e la media di un punto sbagliato non avverte di nulla da sola.
                Text(String(format: "%.0f mm", spread))
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
            }
            if let offset = model.cephProfileOffsetMM(of: landmark) {
                // Scarto dal profilo del viso: un repere cutaneo che non ci cade sopra è segnato
                // su un'altra struttura.
                Text(String(format: "%+.1f", offset).replacingOccurrences(of: ".", with: ","))
                    .font(Typography.numericSmall)
                    .foregroundStyle(abs(offset) > 3 ? Palette.warning : Palette.textSecondary)
            }
            if !sides.isEmpty {
                Button {
                    model.removeCephLandmark(landmark)
                } label: {
                    Image(systemName: "xmark.circle").font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Palette.textSecondary)
                .help("Togli \(landmark.localizedName.lowercased())")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // Un repere già segnato: portaci il mirino, così lo si controlla. Uno da segnare:
            // diventa il prossimo.
            if sides.isEmpty {
                model.cephLandmarkToPlace = landmark
                model.cephSide = .right
            } else {
                model.focusCephLandmark(landmark)
            }
        }
    }

    // MARK: Profilo del viso

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Metrics.spacingSmall) {
            Text("PROFILO DEL VISO").font(Typography.sectionHeader)
                .foregroundStyle(Palette.textSecondary)

            HStack {
                Button(model.faceProfile == nil ? "Estrai" : "Rifai") {
                    model.extractFaceProfile()
                }
                .font(Typography.label)
                .disabled(model.volume == nil)

                if model.faceProfile != nil {
                    Button("Togli") { model.clearFaceProfile() }.font(Typography.label)
                }
                Spacer()
            }

            HStack {
                Text("Soglia").font(Typography.label).foregroundStyle(Palette.textSecondary)
                Slider(value: $model.faceProfileThresholdGV, in: -900...500, step: 25)
                Text("\(Int(model.faceProfileThresholdGV)) GV")
                    .font(Typography.numericSmall)
                    .frame(width: 66, alignment: .trailing)
            }

            Text(
                "Il profilo è il confine fra aria e pelle sul sagittale che passa per il mirino, "
                    + "e prende qualunque cosa stia davanti alla faccia: un poggiamento, una mano. "
                    + "Si disegna sul riquadro sagittale."
            )
            .font(Typography.label)
            .foregroundStyle(Palette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Misure

    /// Le misure raggruppate, a partire da quelle che il modello tiene già calcolate.
    ///
    /// Non `CephAnalysis.groupedMeasures(for:)`: quella le ricalcola tutte e ventisette, e qui si
    /// è dentro il corpo di una vista, che viene rivalutato a ogni movimento del mirino.
    private var groupedMeasures: [(group: CephMeasureGroup, measures: [CephMeasure])] {
        CephMeasureGroup.allCases.compactMap { group in
            let inGroup = model.cephMeasures.filter { $0.kind.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    @ViewBuilder
    private var measuresSection: some View {
        let grouped = groupedMeasures

        VStack(alignment: .leading, spacing: Metrics.spacing) {
            HStack {
                Text("MISURE").font(Typography.sectionHeader)
                    .foregroundStyle(Palette.textSecondary)
                Spacer()
                if model.cephMeasuresOutOfRange > 0 {
                    Text("\(model.cephMeasuresOutOfRange) fuori intervallo")
                        .font(Typography.label)
                        .foregroundStyle(Palette.warning)
                }
            }

            if grouped.isEmpty {
                Text("Nessuna misura ancora: servono almeno tre reperi che stiano nella stessa.")
                    .font(Typography.label)
                    .foregroundStyle(Palette.textSecondary)
                missingHint
            } else {
                ForEach(grouped, id: \.group) { group, measures in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.localizedName.uppercased())
                            .font(Typography.sectionHeader)
                            .foregroundStyle(Palette.textSecondary)
                        ForEach(measures) { measure in
                            measureRow(measure)
                        }
                    }
                }
                missingHint
            }
        }
    }

    private func measureRow(_ measure: CephMeasure) -> some View {
        HStack(spacing: Metrics.spacingSmall) {
            Text(measure.kind.abbreviation)
                .font(Typography.numericSmall)
                .frame(width: 68, alignment: .leading)
                .foregroundStyle(Palette.textSecondary)
                .help(measure.kind.localizedName)

            Text(measure.formattedValue)
                .font(Typography.numeric)
                .frame(width: 74, alignment: .trailing)
                .foregroundStyle(colour(for: measure.status))

            if let reference = measure.formattedReference {
                Text(reference)
                    .font(Typography.numericSmall)
                    .foregroundStyle(Palette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .help(measure.kind.reference?.note ?? measure.kind.localizedName)
    }

    private func colour(for status: CephStatus) -> Color {
        switch status {
        case .within: return Palette.safe
        case .below, .above: return Palette.warning
        case .unrated: return Palette.textPrimary
        }
    }

    /// Quale repere conviene segnare adesso.
    @ViewBuilder
    private var missingHint: some View {
        let missing = CephAnalysis.mostUsefulMissingLandmarks(for: model.cephTracing).prefix(3)
        if !missing.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(missing), id: \.landmark) { entry in
                    Button {
                        model.cephLandmarkToPlace = entry.landmark
                        model.cephSide = .right
                    } label: {
                        Text(
                            "Segna \(entry.landmark.localizedName.lowercased()) "
                                + "(\(entry.landmark.abbreviation)): "
                                + "\(entry.unlocks) misur\(entry.unlocks == 1 ? "a" : "e") in più"
                        )
                        .font(Typography.label)
                    }
                    .buttonStyle(.link)
                }
            }
        }
    }
}
