import DICOMCore
import MeasureKit
import SwiftUI
import VolumeKit

// Griglia dei riquadri e interazione.
//
// Qui vive la conversione fra clic e millimetri, che è il punto in cui un errore smette di
// essere estetico e diventa una misura sbagliata. Tutte le conversioni passano da
// `MPRPlane.patientPoint(atPixelX:y:...)` e dalla sua inversa `pixelPosition(ofPatient:...)`:
// non se ne scrivono altre, nemmeno per comodità locale.

struct ViewportGrid: View {

    @Bindable var model: AppModel

    var body: some View {
        Group {
            switch model.layout {
            case .single:
                viewport(model.focusedSlot)

            case .grid2x2:
                VStack(spacing: Metrics.viewportGap) {
                    HStack(spacing: Metrics.viewportGap) {
                        viewport(.axial)
                        viewport(.coronal)
                    }
                    HStack(spacing: Metrics.viewportGap) {
                        viewport(.sagittal)
                        viewport(.volume3D)
                    }
                }

            case .onePlusThree:
                HStack(spacing: Metrics.viewportGap) {
                    viewport(model.focusedSlot)
                        .frame(maxWidth: .infinity)
                    VStack(spacing: Metrics.viewportGap) {
                        ForEach(ViewportSlot.allCases.filter { $0 != model.focusedSlot }) { slot in
                            viewport(slot)
                        }
                    }
                    .frame(width: 260)
                }

            case .panoramic:
                // Ha una disposizione tutta sua, con il proprio riempimento.
                PanoramicWorkspace(model: model)
            }
        }
        .padding(model.layout == .panoramic ? 0 : Metrics.viewportGap)
        .background(Palette.viewportBackground)
    }

    private func viewport(_ slot: ViewportSlot) -> some View {
        ViewportContainer(model: model, slot: slot)
    }
}

// MARK: - Un riquadro

struct ViewportContainer: View {

    @Bindable var model: AppModel
    let slot: ViewportSlot

    /// Dimensione del drawable in pixel, riportata dal coordinatore Metal.
    ///
    /// Serve a rendere esatta la conversione fra clic e millimetri. Usare le dimensioni in punti
    /// funzionerebbe quasi, perché il rapporto è lo stesso, ma lo scarto di mezzo campione fra
    /// punti e pixel sposterebbe le sovraimpressioni rispetto all'immagine.
    @State private var pixelSize: CGSize = .zero

    /// Primo estremo di una misura in corso.
    @State private var pendingStartMM: Vec3?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                metalContent

                // La curva dell'arcata si vede e si corregge sull'assiale, dove il suo
                // andamento corrisponde a quello che si ha davanti agli occhi.
                if slot == .axial, model.archCurve.isUsable {
                    ArchCurveOverlay(
                        model: model,
                        plane: model.planes[slot],
                        pixelSize: pixelSize)
                }

                if slot.anatomicalPlane != nil {
                    CrosshairOverlay(
                        model: model,
                        slot: slot,
                        pointSize: geometry.size,
                        pixelSize: pixelSize)

                    AnnotationOverlay(
                        model: model,
                        slot: slot,
                        pointSize: geometry.size,
                        pixelSize: pixelSize,
                        pendingStartMM: pendingStartMM)
                }

                ViewportChrome(model: model, slot: slot, pointSize: geometry.size)
            }
            .clipShape(.rect(cornerRadius: Metrics.cornerRadius))
            .overlay(alignment: .top) {
                // Il bordo colorato in alto identifica il piano a colpo d'occhio, come nei
                // mockup e con la stessa convenzione cromatica del mirino.
                Rectangle()
                    .fill(slot.accentColor)
                    .frame(height: Metrics.viewportBorderWidth)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.cornerRadius)
                    .stroke(
                        model.focusedSlot == slot ? slot.accentColor.opacity(0.5) : .clear,
                        lineWidth: 1)
            }
            .onTapGesture { model.focusedSlot = slot }
        }
    }

    // MARK: Contenuto

    @ViewBuilder
    private var metalContent: some View {
        if slot.anatomicalPlane != nil {
            MPRViewportView(
                plane: model.planes[slot],
                volumeTexture: model.volumeTexture,
                renderer: model.mprRenderer,
                windowLevel: model.windowLevel,
                onScroll: { steps in
                    model.focusedSlot = slot
                    model.scroll(slot: slot, steps: steps)
                },
                onMagnify: { factor in
                    model.zoom(slot: slot, factor: factor)
                },
                onDrag: handleDrag,
                onWindowLevelDrag: handleWindowLevelDrag,
                onClick: handleClick,
                onHover: handleHover,
                onDoubleClick: {
                    model.focusedSlot = slot
                    model.layout = model.layout == .single ? .grid2x2 : .single
                },
                onDrawableSize: { pixelSize = $0 }
            )
        } else {
            VStack(spacing: 0) {
                ZStack(alignment: .topTrailing) {
                    volume3D
                    OrientationCube(camera: model.camera)
                        .padding(Metrics.spacing)
                        .padding(.top, Metrics.viewportBorderWidth)
                }
                // L'editor della transfer function sta sotto il rendering, non in una finestra
                // separata: si regola guardando il risultato cambiare.
                TransferFunctionEditor(model: model)
            }
        }
    }

    private var volume3D: some View {
        Volume3DViewportView(
            camera: model.camera,
            volumeTexture: model.volumeTexture,
            raycaster: model.raycaster,
            transferFunction: model.transferFunction,
            quality: model.effectiveQuality,
            lighting: model.lighting,
            onOrbit: { delta in
                model.focusedSlot = slot
                model.orbit(byPixels: delta)
            },
            onMagnify: { factor in
                model.zoom3D(by: factor)
            },
            onInteractionChanged: { active in
                model.isInteractingWith3D = active
            }
        )
    }

    // MARK: Conversioni

    /// Piano corrente con proporzioni adattate ai pixel reali.
    private var adjustedPlane: MPRPlane? {
        guard let plane = model.planes[slot], pixelSize.width > 0, pixelSize.height > 0 else {
            return nil
        }
        var configured = plane
        configured.slabThicknessMM = model.slabThicknessMM
        configured.projection = model.projection
        return configured.matchingAspect(
            pixelWidth: Int(pixelSize.width), pixelHeight: Int(pixelSize.height))
    }

    private func patientPoint(atPixel point: CGPoint) -> Vec3? {
        guard let plane = adjustedPlane else { return nil }
        return plane.patientPoint(
            atPixelX: Double(point.x),
            y: Double(point.y),
            pixelWidth: Int(pixelSize.width),
            pixelHeight: Int(pixelSize.height))
    }

    // MARK: Gesti

    private func handleClick(_ point: CGPoint) {
        model.focusedSlot = slot
        guard let patient = patientPoint(atPixel: point) else { return }

        switch model.activeTool {
        case .navigate:
            model.moveCrosshair(to: patient)

        case .distance:
            if let start = pendingStartMM {
                let measurement = DistanceMeasurement(
                    metadata: AnnotationMetadata(
                        colorHex: "#32B8C6",
                        referencePlane: referencePlane()),
                    startMM: start,
                    endMM: patient)
                model.addAnnotation(.distance(measurement))
                pendingStartMM = nil
            } else {
                pendingStartMM = patient
            }

        case .angle:
            // Richiede tre punti: si aggiungerà con la stessa logica a stati di `.distance`.
            model.moveCrosshair(to: patient)

        case .ellipseROI:
            if let start = pendingStartMM {
                let roi = makeEllipse(from: start, to: patient)
                model.addAnnotation(.ellipseROI(roi))
                pendingStartMM = nil
            } else {
                pendingStartMM = patient
            }

        case .sphereROI:
            if let start = pendingStartMM {
                let radius = start.distance(to: patient)
                guard radius > 0 else { return }
                let roi = SphereROI(
                    metadata: AnnotationMetadata(colorHex: "#FFD426"),
                    centerMM: start,
                    radiusMM: radius)
                model.addAnnotation(.sphereROI(roi))
                pendingStartMM = nil
            } else {
                pendingStartMM = patient
            }

        case .text:
            let note = TextNote(
                metadata: AnnotationMetadata(referencePlane: referencePlane()),
                anchorMM: patient,
                text: "Nota")
            model.addAnnotation(.text(note))
        }
    }

    private func handleDrag(_ point: CGPoint, _ delta: CGSize) {
        guard model.activeTool == .navigate, let plane = adjustedPlane else { return }
        // Il pan si esprime in millimetri, non in pixel: si moltiplica lo spostamento per il
        // passo del pixel, così la panoramica resta coerente a qualunque zoom.
        let rightStep = plane.rightStepMM(pixelWidth: Int(pixelSize.width))
        let downStep = plane.downStepMM(pixelHeight: Int(pixelSize.height))
        let offset = rightStep * Double(-delta.width) + downStep * Double(-delta.height)
        model.pan(slot: slot, byMM: offset)
    }

    private func handleWindowLevelDrag(_ delta: CGSize) {
        // Convenzione radiologica diffusa: orizzontale regola l'ampiezza, verticale il livello.
        var wl = model.windowLevel
        wl.width = max(1, wl.width + Double(delta.width) * 4)
        wl.level += Double(-delta.height) * 4
        model.windowLevel = wl
    }

    private func handleHover(_ point: CGPoint?) {
        guard let point, let patient = patientPoint(atPixel: point) else {
            model.hoverPositionMM = nil
            model.hoverDensity = nil
            return
        }
        model.hoverPositionMM = patient
        // Campionamento nearest sui dati di CPU: il valore mostrato è un valore realmente
        // presente nel volume, non una media fra vicini.
        model.hoverDensity = model.volume?.densityValue(atPatient: patient)
    }

    // MARK: Costruzione delle annotazioni

    private func referencePlane() -> AnnotationPlaneReference? {
        guard let plane = adjustedPlane, let geometry = model.volume?.geometry else { return nil }
        let spacing = geometry.spacingMM
        return AnnotationPlaneReference(
            originMM: plane.centerMM,
            normalMM: plane.normalMM,
            visibilityToleranceMM: max(spacing.x, max(spacing.y, spacing.z)) * 2)
    }

    /// Ellisse inscritta nel rettangolo definito dai due punti, sul piano corrente.
    private func makeEllipse(from start: Vec3, to end: Vec3) -> EllipseROI {
        let plane = adjustedPlane
        let right = plane?.rightMM ?? Vec3(1, 0, 0)
        let down = plane?.downMM ?? Vec3(0, 1, 0)
        let diagonal = end - start
        let center = start.lerp(to: end, t: 0.5)
        let spacing = model.volume?.geometry.spacingMM ?? Vec3(1, 1, 1)

        return EllipseROI(
            metadata: AnnotationMetadata(colorHex: "#4FCB6B", referencePlane: referencePlane()),
            centerMM: center,
            semiAxisAMM: right * (diagonal.dot(right) * 0.5),
            semiAxisBMM: down * (diagonal.dot(down) * 0.5),
            thicknessMM: max(spacing.x, max(spacing.y, spacing.z)))
    }
}

