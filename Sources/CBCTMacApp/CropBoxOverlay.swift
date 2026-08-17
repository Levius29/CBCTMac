import DICOMCore
import SegmentKit
import SwiftUI
import VolumeKit

// Riquadro di ritaglio sovrapposto a una vista ortogonale.
//
// I lati si trascinano. Le tre viste mostrano lo **stesso** parallelepipedo da tre direzioni: chi
// disegna qui legge e scrive `plan.regionMM`, quindi muovendo un lato in una vista le altre due si
// aggiornano da sole. Tre rettangoli indipendenti sarebbero più semplici da scrivere e
// discorderebbero al primo trascinamento, perché descriverebbero tre scatole diverse.

struct CropBoxOverlay: View {

    @Binding var plan: ReformatPlan
    let anatomical: AnatomicalPlane
    let geometry: VolumeGeometry
    let viewPlane: MPRPlane

    /// Quanto vicino a un lato bisogna premere perché lo si afferri, in punti.
    private let grabPoints: CGFloat = 10

    @State private var draggingEdge: Edge?

    private enum Edge { case left, right, top, bottom }

    var body: some View {
        // `proxy` e non `geometry`: nello stesso ambito c'è già la `VolumeGeometry` del volume,
        // e due cose diverse con lo stesso nome in una vista che converte fra millimetri e pixel
        // sono un incidente in attesa.
        GeometryReader { proxy in
            let size = proxy.size
            let rect = screenRect(in: size)

            ZStack {
                // Ciò che resta fuori è oscurato invece che nascosto: si continua a vedere dove
                // sta il ritaglio rispetto all'anatomia intera, che è l'informazione che serve
                // mentre lo si regola.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: size))
                    path.addRect(rect)
                }
                .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))

                Rectangle()
                    .path(in: rect)
                    .stroke(.white.opacity(0.9), lineWidth: 1.5)

                ForEach(handlePositions(in: rect), id: \.x) { point in
                    Circle()
                        .fill(.white)
                        .frame(width: 7, height: 7)
                        .position(point)
                }
            }
            .contentShape(.rect)
            .gesture(dragGesture(in: size, rect: rect))
        }
    }

    // MARK: Dal riquadro in mm allo schermo

    /// I due assi Patient che questa vista mostra, con il verso dello schermo.
    ///
    /// Si ricavano da `screenRightMM` e `screenDownMM` invece di essere scritti a mano per lo
    /// stesso motivo delle lettere d'orientamento: due dichiarazioni della stessa convenzione
    /// prima o poi divergono, e qui il sintomo sarebbe un riquadro che si allarga dalla parte
    /// sbagliata quando lo si trascina.
    private var axes: (horizontal: BoxAxis, vertical: BoxAxis) {
        (BoxAxis(direction: viewPlane.rightMM), BoxAxis(direction: viewPlane.downMM))
    }

    private struct BoxAxis {
        let component: Int
        let sign: Double

        init(direction: Vec3) {
            let x = abs(direction.x), y = abs(direction.y), z = abs(direction.z)
            if x >= y, x >= z {
                component = 0
                sign = direction.x >= 0 ? 1 : -1
            } else if y >= z {
                component = 1
                sign = direction.y >= 0 ? 1 : -1
            } else {
                component = 2
                sign = direction.z >= 0 ? 1 : -1
            }
        }

        func value(_ v: Vec3) -> Double {
            component == 0 ? v.x : (component == 1 ? v.y : v.z)
        }

        var minimumFace: BoxFace {
            switch (component, sign > 0) {
            case (0, true): return .minX
            case (0, false): return .maxX
            case (1, true): return .minY
            case (1, false): return .maxY
            case (2, true): return .minZ
            default: return .maxZ
            }
        }

        var maximumFace: BoxFace {
            switch (component, sign > 0) {
            case (0, true): return .maxX
            case (0, false): return .minX
            case (1, true): return .maxY
            case (1, false): return .minY
            case (2, true): return .maxZ
            default: return .minZ
            }
        }
    }

    private func screenRect(in size: CGSize) -> CGRect {
        let (h, v) = axes
        let x0 = screenX(axisMM(h, minimum: true), axis: h, size: size)
        let x1 = screenX(axisMM(h, minimum: false), axis: h, size: size)
        let y0 = screenY(axisMM(v, minimum: true), axis: v, size: size)
        let y1 = screenY(axisMM(v, minimum: false), axis: v, size: size)

        return CGRect(
            x: min(x0, x1), y: min(y0, y1),
            width: abs(x1 - x0), height: abs(y1 - y0))
    }

    /// Estremo del riquadro lungo un asse, nel verso dello schermo.
    private func axisMM(_ axis: BoxAxis, minimum: Bool) -> Double {
        let low = axis.value(plan.regionMM.minMM)
        let high = axis.value(plan.regionMM.maxMM)
        if axis.sign > 0 { return minimum ? low : high }
        return minimum ? high : low
    }

    private func screenX(_ valueMM: Double, axis: BoxAxis, size: CGSize) -> CGFloat {
        let origin = axis.value(viewPlane.topLeftMM)
        let span = axis.sign * viewPlane.widthMM
        guard abs(span) > 1e-9 else { return 0 }
        return CGFloat((valueMM - origin) / span) * size.width
    }

    private func screenY(_ valueMM: Double, axis: BoxAxis, size: CGSize) -> CGFloat {
        let origin = axis.value(viewPlane.topLeftMM)
        let span = axis.sign * viewPlane.heightMM
        guard abs(span) > 1e-9 else { return 0 }
        return CGFloat((valueMM - origin) / span) * size.height
    }

    private func millimetresX(_ x: CGFloat, axis: BoxAxis, size: CGSize) -> Double {
        let origin = axis.value(viewPlane.topLeftMM)
        return origin + Double(x / max(size.width, 1)) * axis.sign * viewPlane.widthMM
    }

    private func millimetresY(_ y: CGFloat, axis: BoxAxis, size: CGSize) -> Double {
        let origin = axis.value(viewPlane.topLeftMM)
        return origin + Double(y / max(size.height, 1)) * axis.sign * viewPlane.heightMM
    }

    private func handlePositions(in rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.midX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY),
        ]
    }

    // MARK: Trascinamento

    private func dragGesture(in size: CGSize, rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if draggingEdge == nil {
                    draggingEdge = nearestEdge(to: value.startLocation, rect: rect)
                }
                guard let edge = draggingEdge else { return }

                let (h, v) = axes
                switch edge {
                case .left:
                    plan.moveFace(
                        h.minimumFace,
                        toMM: millimetresX(value.location.x, axis: h, size: size),
                        within: geometry)
                case .right:
                    plan.moveFace(
                        h.maximumFace,
                        toMM: millimetresX(value.location.x, axis: h, size: size),
                        within: geometry)
                case .top:
                    plan.moveFace(
                        v.minimumFace,
                        toMM: millimetresY(value.location.y, axis: v, size: size),
                        within: geometry)
                case .bottom:
                    plan.moveFace(
                        v.maximumFace,
                        toMM: millimetresY(value.location.y, axis: v, size: size),
                        within: geometry)
                }
            }
            .onEnded { _ in draggingEdge = nil }
    }

    /// Lato più vicino al punto premuto, se entro la distanza di presa.
    ///
    /// Si sceglie il più vicino in assoluto e non il primo che rientra nella soglia: su un
    /// riquadro stretto due lati opposti stanno entrambi a portata, e prendere il primo
    /// dell'elenco significherebbe afferrare sempre lo stesso.
    private func nearestEdge(to point: CGPoint, rect: CGRect) -> Edge? {
        let candidates: [(Edge, CGFloat)] = [
            (.left, abs(point.x - rect.minX)),
            (.right, abs(point.x - rect.maxX)),
            (.top, abs(point.y - rect.minY)),
            (.bottom, abs(point.y - rect.maxY)),
        ]
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= grabPoints else {
            return nil
        }
        return best.0
    }
}
