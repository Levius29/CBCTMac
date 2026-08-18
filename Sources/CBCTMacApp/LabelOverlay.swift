import DICOMCore
import ImplantKit
import MeasureKit
import StudyKit
import SwiftUI
import VolumeKit

// Le etichette degli oggetti, collocate perché non coprano l'anatomia.
//
// # Il problema che risolve
//
// Prima ogni disegno scriveva la propria etichetta dove capitava — sul punto medio di una misura,
// sulla piattaforma di un impianto — e con tre oggetti vicini le tre scritte finivano una sopra
// l'altra, illeggibili tutte. Peggio: la scritta cadeva **sull'anatomia**, cioè sopra la cosa che
// si stava misurando.
//
// Ora le posizioni le decide `LabelLayout`, che le allontana dall'ancora quel tanto che basta,
// evita le sovrapposizioni, e collega ciascuna al proprio punto con una linea di richiamo. Quando
// non c'è posto per tutte, alcune restano fuori invece di ammucchiarsi: sovrapporle sarebbe
// l'esito peggiore, perché diventerebbero illeggibili tutte invece che alcune.
//
// # Perché un solo strato per tutti gli oggetti
//
// Perché la collocazione è un problema **globale**: l'etichetta di un impianto deve evitare
// quella di una misura, e due strati che non si conoscono non possono farlo. Da qui la scelta di
// raccogliere qui le etichette di impianti, canali e misure, invece di lasciarle a chi disegna
// ciascuna forma.

struct LabelOverlay: View {

    let model: AppModel
    let slot: ViewportSlot

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            Canvas { context, _ in
                guard let plane = adjusted(for: size) else { return }
                let requests = collect(plane: plane, size: size)
                guard !requests.isEmpty else { return }

                let placed = LabelLayout.place(
                    requests.map(\.request),
                    inWidth: Double(size.width),
                    height: Double(size.height))
                let sources = Dictionary(
                    uniqueKeysWithValues: requests.map { ($0.request.id, $0) })

                for label in placed where label.isPlaced {
                    guard let source = sources[label.id] else { continue }
                    draw(label, source: source, in: &context)
                }
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: Raccolta

    private struct Item {
        let request: LabelRequest
        let text: String
        let color: Color
        let isSelected: Bool
    }

    private func adjusted(for size: CGSize) -> MPRPlane? {
        guard let plane = model.planes[slot], size.width > 1, size.height > 1 else { return nil }
        return plane.matchingAspect(pixelWidth: Int(size.width), pixelHeight: Int(size.height))
    }

    /// Larghezza stimata del testo, in punti.
    ///
    /// Stimata e non misurata: misurarla richiederebbe un `Text` renderizzato per etichetta a
    /// ogni fotogramma, e la collocazione gira a ogni ridisegno. Sette punti per carattere è la
    /// larghezza media della monospaziata a undici punti, e uno scarto di qualche punto sposta
    /// un'etichetta di qualche punto — non la fa sovrapporre.
    private func width(of text: String) -> Double {
        Double(text.count) * 6.6 + 10
    }

    private func collect(plane: MPRPlane, size: CGSize) -> [Item] {
        let width = Int(size.width)
        let height = Int(size.height)
        var items: [Item] = []

        func anchor(_ pointMM: Vec3) -> (x: Double, y: Double, distanceMM: Double) {
            plane.pixelPosition(ofPatient: pointMM, pixelWidth: width, pixelHeight: height)
        }

        for implant in model.implants where implant.isVisible {
            let point = anchor(implant.platformMM)
            // Fuori dal riquadro non si etichetta: la linea di richiamo punterebbe verso il
            // nulla, e l'etichetta occuperebbe posto tolto a un oggetto che si vede davvero.
            guard point.x > -20, point.x < Double(width) + 20,
                point.y > -20, point.y < Double(height) + 20
            else { continue }

            let name = model.registry[implant.id]?.name ?? implant.label
            let text = String(
                format: "%@ Ø%.1f×%.0f", name, implant.model.diameterMM, implant.model.lengthMM
            ).replacingOccurrences(of: ".", with: ",")
            let isSelected = model.selectedImplantID == implant.id
            items.append(
                Item(
                    request: LabelRequest(
                        id: implant.id, anchorX: point.x, anchorY: point.y,
                        width: width(of: text), height: 17,
                        // L'oggetto selezionato ha priorità massima: se una sola etichetta deve
                        // trovare posto, è quella su cui si sta lavorando.
                        priority: isSelected ? 100 : 50),
                    text: text,
                    color: severityColor(implant) ?? (Color(hexString: implant.colorHex) ?? Palette.textPrimary),
                    isSelected: isSelected))
        }

        for annotation in model.annotations where !annotation.metadata.isHidden {
            guard let first = annotation.handlesMM.first else { continue }
            let centroid = annotation.handlesMM.reduce(Vec3.zero, +)
                / Double(annotation.handlesMM.count)
            let point = anchor(annotation.handlesMM.count > 1 ? centroid : first)
            guard point.x > -20, point.x < Double(width) + 20,
                point.y > -20, point.y < Double(height) + 20
            else { continue }

            let text = model.roiStatistics[annotation.id]?.summary ?? annotation.formattedValue
            guard !text.isEmpty else { continue }
            let isSelected = model.selectedAnnotationID == annotation.id
            items.append(
                Item(
                    request: LabelRequest(
                        id: annotation.id, anchorX: point.x, anchorY: point.y,
                        width: width(of: text), height: 17,
                        priority: isSelected ? 100 : 40),
                    text: text,
                    color: Color(hexString: annotation.metadata.colorHex) ?? Palette.accent,
                    isSelected: isSelected))
        }

        return items
    }

    private func severityColor(_ implant: ImplantPlacement) -> Color? {
        switch model.safetyReports[implant.id]?.worstLevel {
        case .danger: return Palette.danger
        case .caution: return Palette.caution
        default: return nil
        }
    }

    // MARK: Disegno

    private func draw(_ label: PlacedLabel, source: Item, in context: inout GraphicsContext) {
        let request = source.request
        let rect = CGRect(
            x: label.x, y: label.y, width: request.width, height: request.height)

        // Prima il richiamo, poi la pastiglia: la linea deve finire **sotto** l'etichetta, non
        // attraversarla.
        var leader = Path()
        leader.move(to: CGPoint(x: request.anchorX, y: request.anchorY))
        leader.addLine(to: CGPoint(x: label.leaderX, y: label.leaderY))
        context.stroke(
            leader, with: .color(source.color.opacity(0.55)),
            style: StrokeStyle(lineWidth: 1, dash: [2, 2]))

        // Un punto sull'ancora: senza, il richiamo sembra una linea che parte da niente.
        context.fill(
            Path(
                ellipseIn: CGRect(
                    x: request.anchorX - 2, y: request.anchorY - 2, width: 4, height: 4)),
            with: .color(source.color))

        context.fill(
            Path(roundedRect: rect, cornerRadius: 3),
            with: .color(Palette.chrome.opacity(0.88)))
        if source.isSelected {
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 3),
                with: .color(source.color), lineWidth: 1)
        }
        context.draw(
            Text(source.text)
                .font(Typography.numericSmall)
                .foregroundStyle(source.color),
            at: CGPoint(x: rect.midX, y: rect.midY),
            anchor: .center)
    }
}
