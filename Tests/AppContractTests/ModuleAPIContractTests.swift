import DICOMCore
import DentalKit
import Foundation
import ImplantKit
import MeasureKit
import MeshKit
import SegmentKit
import StudyKit
import Testing
import VolumeKit

// Contratto delle API che l'applicazione usa.
//
// L'app non compila su Linux: importa SwiftUI, AppKit e Metal, che qui non esistono. Le sue
// chiamate **verso i moduli condivisi** però si possono verificare lo stesso, ed è quasi tutto
// ciò che l'app fa di sostanziale.
//
// Questo file ripete quelle chiamate con le stesse firme che compaiono in `Sources/CBCTMacApp`.
// Se compila, ogni punto di chiamata dell'app verso i moduli è corretto per tipo e per firma,
// e sul Mac resteranno da sistemare soltanto gli errori di piattaforma veri e propri.
//
// Non duplica la logica dell'app: ne esercita la **superficie di contatto**. Quando una firma
// cambia, questo file smette di compilare, ed è esattamente il segnale che serve.

@Suite("Contratto delle API usate dall'app")
struct ModuleAPIContractTests {

    private func makeVolume() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 60, rows: 60, slices: 60, spacingMM: Vec3(1, 1, 1))
    }

    // MARK: AppModel: caricamento e stato

    @Test("Le API di caricamento del volume usate da AppModel")
    func volumeLoadingAPI() throws {
        let volume = try makeVolume()

        // `adopt(volume:)`
        let geometry = volume.geometry
        _ = geometry.centerMM
        _ = DensityWindow.automatic(from: volume)
        _ = volume.rawHistogram(binCount: 256)
        _ = VolumeCamera.fitted(to: geometry)
        _ = ArchCurve.defaultArch(for: geometry)

        // `clampCrosshairToVolume()`
        let v = geometry.voxelPoint(fromPatient: geometry.centerMM)
        _ = geometry.patientPoint(fromVoxel: v)
        _ = geometry.columnCount
        _ = geometry.rowCount
        _ = geometry.sliceCount

        // `sliceIndicator(for:)` e la barra di stato
        _ = geometry.spacingMM
        _ = geometry.isIsotropic()
        _ = geometry.physicalSizeMM
        _ = volume.densityUnit
        _ = volume.densityValue(atPatient: .zero)
        _ = volume.densityRange
    }

    @Test("Le API dei piani MPR usate dai riquadri")
    func planeAPI() throws {
        let geometry = try makeVolume().geometry

        // `resetPlanes()`
        var plane = MPRPlane.fitted(plane: .axial, geometry: geometry)
        plane.slabThicknessMM = 1.0
        plane.projection = .maximum

        // `plane(for:pixelWidth:pixelHeight:)`
        let adjusted = plane.matchingAspect(pixelWidth: 800, pixelHeight: 600)

        // `patientPoint(atPixel:)` — la conversione da clic a millimetri
        let patient = adjusted.patientPoint(
            atPixelX: 123.5, y: 456.25, pixelWidth: 800, pixelHeight: 600)

        // `pixelPosition(ofPatient:)` — il disegno delle sovraimpressioni
        let projected = adjusted.pixelPosition(
            ofPatient: patient, pixelWidth: 800, pixelHeight: 600)
        #expect(abs(projected.x - 123.5) < 1e-9)
        #expect(abs(projected.y - 456.25) < 1e-9)

        // `handleDrag`, `scroll`, `zoom`
        _ = adjusted.rightStepMM(pixelWidth: 800)
        _ = adjusted.downStepMM(pixelHeight: 600)
        _ = adjusted.normalMM
        _ = adjusted.zoomed(by: 1.2)
        _ = adjusted.advanced(byMM: 0.5)

        // Navigazione: `AppModel.zoom(slot:factor:atPixel:pixelSize:)`,
        // `rotate(slot:byRadians:)`, `resetView(slot:)` e `resetAllViews()`.
        _ = adjusted.zoomed(
            by: 1.25, aboutPixelX: 640, y: 360, pixelWidth: 1280, pixelHeight: 720)
        _ = adjusted.rotatedInPlane(byRadians: 0.1, aboutMM: Vec3(1, 2, 3))
        _ = adjusted.fitted(to: geometry)
        _ = adjusted.fitted(to: geometry, marginFraction: 0.04)
        _ = geometry.physicalSizeMM
        _ = geometry.boundingBoxCornersMM
        _ = adjusted.widthMM
        _ = adjusted.rightMM
        _ = adjusted.downMM
        _ = adjusted.centerMM
        _ = adjusted.slabSampleCount(geometry: geometry)
        _ = adjusted.slabStepMM(geometry: geometry)

        // Assi anatomici, usati da `MPRPlane(plane:through:)`
        _ = AnatomicalPlane.axial.screenRightMM
        _ = AnatomicalPlane.coronal.screenDownMM
        _ = AnatomicalPlane.sagittal.normalMM
        _ = AnatomicalPlane.axial.localizedName
        // `ViewportChrome`: lettere d'orientamento ai quattro bordi, e quota per riquadro.
        for anatomical in AnatomicalPlane.allCases {
            let edges = anatomical.edgeLabels
            _ = edges.top
            _ = edges.bottom
            _ = edges.left
            _ = edges.right
        }
        // `slabThickness(for:)` e `setSlabThickness(_:for:)` leggono e scrivono nel piano.
        var perViewport = adjusted
        perViewport.slabThicknessMM = 1.1
        perViewport.projection = .maximum
        _ = perViewport.slabThicknessMM
        _ = perViewport.projection
    }

    @Test("Finestra, livello e proiezione dell'ispettore")
    func windowLevelAPI() {
        var wl = DensityWindow.bone
        wl.width = 2400
        wl.level = 600
        _ = wl.lowerBound
        _ = wl.upperBound
        for preset in DensityWindow.presets {
            _ = preset.name
            _ = preset.value
        }
        for projection in SlabProjection.allCases {
            _ = projection.localizedName
            _ = projection.shaderMode
            _ = projection.rawValue
        }
    }

    // MARK: Rendering 3D

    @Test("Le API del rendering 3D e della transfer function")
    func renderingAPI() throws {
        let geometry = try makeVolume().geometry

        var camera = VolumeCamera.fitted(to: geometry)
        camera = camera.orbited(deltaAzimuth: 0.1, deltaElevation: -0.05)
        camera = camera.zoomed(by: 1.1)
        camera = camera.facingAnterior()
        camera = camera.facingLateral()
        camera = camera.facingSuperior()
        _ = camera.forward

        var function = TransferFunction.bone
        function.opacityScale = 1.5
        let sample = function.sample(at: 700)
        _ = sample.color.red
        _ = sample.opacity
        _ = function.bake(entryCount: 512, densityRange: -1200...3600)

        // L'editor trascina i punti di controllo per indice.
        if let index = function.stops.indices.first {
            function.stops[index].density = 500
            function.stops[index].opacity = 0.4
            _ = function.stops[index].id
        }
        for preset in TransferFunction.presets {
            _ = preset.name
            _ = preset.value
        }

        for quality in RenderQuality.allCases {
            _ = quality.localizedName
            _ = quality.stepInVoxels
            _ = quality.resolutionDivisor
        }

        var lighting = LightingParameters.standard
        lighting.diffuse = 0.9
        lighting.ambient = 0.3
    }

    // MARK: Arcata, panorex e sezioni

    @Test("Le API di arcata, panorex e sezioni trasversali")
    func dentalAPI() throws {
        let geometry = try makeVolume().geometry
        var curve = ArchCurve.defaultArch(for: geometry)

        _ = curve.isUsable
        _ = curve.lengthMM
        _ = curve.upAxis
        _ = curve.resampled(count: 160)
        _ = curve.resampled(spacingMM: 1.0)
        _ = curve.nearestControlPoint(to: .zero, toleranceMM: 24)
        _ = curve.arcLength(nearestTo: .zero)

        // L'overlay sposta i punti per indice.
        if let index = curve.controlPointsMM.indices.first {
            curve.controlPointsMM[index] = Vec3(1, 2, 3)
        }

        let panoramic = PanoramicLayout(
            curve: curve,
            heightMM: 70,
            verticalCentreMM: 0,
            slabThicknessMM: 20,
            projection: .maximum)
        _ = panoramic.naturalPixelWidth
        _ = panoramic.naturalPixelHeight
        _ = panoramic.curve.lengthMM
        let columns = panoramic.columnSamples(pixelWidth: 64)
        _ = panoramic.downStepMM(pixelWidth: 64)
        if let first = columns.first {
            _ = panoramic.topOfColumn(first, pixelWidth: 64, pixelHeight: 48)
            // Navigazione: `scrollPanoramic(byArcMM:)`, `zoomPanoramic(by:atPixelX:pixelWidth:)`,
            // `resetPanoramicView()`, e la conversione pixel → lunghezza d'arco usata da
            // `PanoramicViewportView` per hover, clic e righello.
            _ = panoramic.effectiveZoom
            _ = panoramic.clampedArcCentreMM
            _ = panoramic.visibleArcRangeMM
            _ = panoramic.visibleArcHalfLengthMM
            _ = panoramic.arcLengthMM(atPixelX: 12, pixelWidth: 64)
            _ = panoramic.scrolled(byArcMM: 3).clampedArcCentreMM
            _ = panoramic.zoomed(by: 1.5, aboutPixelX: 12, pixelWidth: 64).effectiveZoom
            _ = curve.samples(atArcLengthsMM: [0, 1, 2])
            // Modifica della curva: `addArchPoint`, `moveArchPoint`, `removeArchPoint`,
            // `flattenActiveArchCurve`, `suggestArchCurve`, e il selettore d'arcata.
            _ = curve.closestPointOnControlPolyline(to: .zero)
            _ = curve.averageVerticalMM
            for arch in DentalArch.allCases {
                _ = arch.localizedName
                _ = arch.shortName
                _ = arch.systemImageName
                _ = ArchCurve.suggested(for: geometry, atVerticalMM: 0, arch: arch)
            }
            var editable = curve
            editable.addControlPoint(Vec3(1, 2, 3))
            editable.moveControlPoint(at: 0, to: Vec3(2, 3, 4))
            _ = editable.removeControlPoint(at: 0)
            editable.flatten(toVerticalMM: 1)
            editable.removeAllControlPoints()
            _ = panoramic.millimetresPerPixel(pixelWidth: 64)
            _ = panoramic.visibleHeightMM(pixelWidth: 64, pixelHeight: 48)
            _ = panoramic.normalOffsetMM
            // `CrossSectionBrowser` in AppModel: striscia, selezione, ingrandimento.
            var browser = CrossSectionBrowser(visibleCount: 10)
            browser.replaceSections(
                CrossSectionLayout(curve: curve, angleOffsetRadians: 0.1).sections())
            browser.select(index: 3)
            browser.select(nearestToArcLengthMM: 12)
            browser.step(by: 2)
            browser.scrollWindow(by: -1)
            browser.zoom = 2
            _ = browser.visibleSections
            _ = browser.visibleRange
            _ = browser.selectedSection
            _ = browser.selectedIndex
            _ = browser.effectiveVisibleCount
            _ = browser.count
            _ = browser.isEmpty
            _ = browser.sections
            _ = browser.visibleArcLengthsMM
            _ = browser.index(nearestToArcLengthMM: 5)
            _ = browser.sectionExtentMM(baseWidthMM: 30, baseHeightMM: 45)
            _ = CrossSectionBrowser.minimumZoom
            _ = CrossSectionBrowser.maximumZoom

            // `ReformatSheet` e `CropBoxOverlay`: ritaglio e ricampionamento.
            var reformat = ReformatPlan.full(for: geometry, spacingMM: 0.3)
            reformat.name = "Prova"
            reformat.spacingMM = 0.15
            _ = reformat.estimatedVoxelCount()
            _ = reformat.estimatedBytes()
            _ = reformat.validate(against: geometry)
            _ = reformat.regionMM.sizeMM
            for face in BoxFace.allCases {
                reformat.moveFace(face, toMM: 1, within: geometry)
            }
            _ = VolumeResampler.spacingPresetsMM
            _ = try VolumeResampler.resampled(
                try makeVolume(),
                request: ResampleRequest(spacingMM: 2, regionMM: reformat.regionMM))
            _ = PanoramicLayout.slabThicknessPresetsMM
            _ = panoramic.slabStep(for: first, sampleCount: 8)
            _ = first.positionMM
            _ = first.normal
            _ = first.tangent
            _ = first.arcLengthMM
        }
        _ = panoramic.slabSampleCount(geometry: geometry)

        let crossSections = CrossSectionLayout(
            curve: curve,
            intervalMM: 1.0,
            widthMM: 30,
            heightMM: 45,
            verticalCentreMM: 0,
            thicknessMM: 0)
        let sections = crossSections.sections()
        if let section = sections.first {
            _ = section.plane
            _ = section.label
            _ = section.index
            _ = section.arcLengthMM
            _ = section.originMM
            _ = crossSections.section(nearestToArcLength: 5, in: sections)
        }
    }

    // MARK: Misure e annotazioni

    @Test("Le API di misure, annotazioni e statistiche")
    func measurementAPI() throws {
        let volume = try makeVolume()

        let reference = AnnotationPlaneReference(
            originMM: .zero, normalMM: Vec3(0, 0, 1), visibilityToleranceMM: 2)
        let metadata = AnnotationMetadata(colorHex: "#32B8C6", referencePlane: reference)

        let distance = DistanceMeasurement(
            metadata: metadata, startMM: Vec3(-5, 0, 0), endMM: Vec3(5, 0, 0))
        let angle = AngleMeasurement(
            metadata: metadata, vertexMM: .zero,
            firstArmMM: Vec3(1, 0, 0), secondArmMM: Vec3(0, 1, 0))
        let ellipse = EllipseROI(
            metadata: metadata, centerMM: .zero,
            semiAxisAMM: Vec3(3, 0, 0), semiAxisBMM: Vec3(0, 3, 0), thicknessMM: 1)
        let sphere = SphereROI(metadata: metadata, centerMM: .zero, radiusMM: 3)
        let note = TextNote(metadata: metadata, anchorMM: .zero, text: "Nota")
        let profile = ProfileLine(
            metadata: metadata, startMM: Vec3(0, -20, 0), endMM: Vec3(0, 20, 0),
            sampleCount: 128)

        let annotations: [Annotation] = [
            .distance(distance), .angle(angle), .ellipseROI(ellipse),
            .sphereROI(sphere), .text(note), .profileLine(profile),
        ]
        for annotation in annotations {
            _ = annotation.id
            _ = annotation.metadata
            _ = annotation.handlesMM
            _ = annotation.formattedValue
            _ = annotation.kindName
            _ = annotation.systemImageName
        }

        // `recomputeStatistics(for:)`
        let stats = try ROISampler.statistics(for: sphere, in: volume)
        _ = stats.summary
        _ = stats.detailRows
        _ = stats.unit.symbol
        _ = stats.unit.explanation
        _ = ROISampler.profile(for: profile, in: volume)
        _ = try ROISampler.statistics(for: ellipse, in: volume)

        _ = MeasurementFormatter.length(10)
        _ = MeasurementFormatter.angle(90)
        _ = MeasurementFormatter.density(1200, unit: .greyValue)
        _ = MeasurementFormatter.densityWithDeviation(
            mean: 1200, standardDeviation: 80, unit: .greyValue)
    }

    @Test("Le API del documento di piano")
    func planDocumentAPI() throws {
        let volume = try makeVolume()

        var document = PlanDocument(
            study: StudyReference(
                studyInstanceUID: "s",
                seriesInstanceUID: "e",
                seriesDescription: "prova",
                geometryFingerprint: GeometryFingerprint(volume.geometry)),
            annotations: [],
            viewState: ViewState(
                crosshairMM: .zero,
                windowWidth: 2400,
                windowLevel: 600,
                slabThicknessMM: 1,
                projectionMode: SlabProjection.average.rawValue,
                layout: "grid2x2"),
            appVersion: "0.1.0-dev")

        document.annotations = []
        _ = document.measurementsCSV(unit: .greyValue)
        _ = document.study.geometryFingerprint?.matches(volume.geometry)
        _ = document.viewState?.crosshairVec3
        _ = document.viewState?.windowWidth
        _ = document.viewState?.windowLevel
        _ = document.viewState?.slabThicknessMM

        let data = try document.encoded()
        _ = try PlanDocument.decoded(from: data)
    }

    // MARK: Impianti e nervo

    @Test("Le API di impianti, nervo e sicurezza")
    func implantAPI() throws {
        let volume = try makeVolume()

        var placement = ImplantPlacement(
            model: .default,
            platformMM: Vec3(0, 0, 5),
            axis: Vec3(0, 0, -1),
            label: "Impianto 1")
        placement.model = ImplantModel(
            manufacturer: placement.model.manufacturer,
            line: placement.model.line,
            diameterMM: 4.1,
            lengthMM: 10)
        _ = placement.apexMM
        _ = placement.axisPoint(atZ: 5)
        _ = placement.emergencePoint(extensionMM: 6)
        _ = placement.signedDistance(from: .zero)
        _ = placement.surfacePoints(levels: 8, radialSteps: 8)
        _ = placement.perpendicularBasis()
        _ = placement.angleDegrees(to: Vec3(0, 0, 1))
        _ = placement.model.profile
        _ = placement.model.radius(atZ: 3)
        _ = placement.model.displayName
        _ = placement.isVisible
        _ = placement.colorHex
        _ = ImplantModel.commonDiameters
        _ = ImplantModel.commonLengths
        _ = ImplantModel.genericCatalog()

        var canal = NerveCanal(side: .right)
        canal.addNode(NerveNode(positionMM: Vec3(-10, 0, -15)))
        canal.addNode(NerveNode(positionMM: Vec3(10, 0, -15)))
        _ = canal.isUsable
        _ = canal.localizedName
        _ = canal.side.localizedName
        _ = canal.colorHex
        _ = canal.isVisible
        _ = canal.nodes.count
        _ = canal.resampled(spacingMM: 0.5)
        _ = canal.signedDistance(from: .zero)
        _ = canal.closestPoint(to: .zero)

        let report = SafetyAnalyzer.analyze(
            implant: placement,
            nerves: [canal],
            otherImplants: [],
            volume: volume,
            thresholds: .nerve)
        _ = report.worstLevel
        _ = report.angulationDegrees
        _ = report.maxParallelismDeviationDegrees
        for finding in report.findings {
            _ = finding.id
            _ = finding.structureName
            _ = finding.formattedDistance
            _ = finding.level.colorHex
        }
        if let density = report.density {
            for band in density.bands {
                _ = band.name
                _ = band.summary
            }
            _ = density.overall.unit.explanation
        }

        var thresholds = SafetyThresholds.nerve
        thresholds.dangerMM = 1.0
        thresholds.cautionMM = 2.0
        _ = thresholds.level(for: 1.5)
        _ = MandibularSide.allCases
    }

    // MARK: Mesh, per la Fase 5

    @Test("Le API di MeshKit che l'app userà per la fusione")
    func meshAPI() throws {
        let mesh = Mesh(
            verticesMM: [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0)],
            triangles: [Triangle(a: 0, b: 1, c: 2)],
            name: "prova")
        _ = mesh.boundsMM
        _ = mesh.centroidMM
        _ = mesh.vertexCount
        _ = mesh.triangleCount
        _ = mesh.surfaceAreaMM2()
        _ = mesh.vertexNormals()
        _ = mesh.welded()
        _ = mesh.removingDegenerateTriangles()
        _ = mesh.transformed(by: .identity)
        _ = MeshIO.exportSTLBinary(mesh)

        let source = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        let target = source.map { $0 + Vec3(5, 0, 0) }
        let result = try PointRegistration.align(source: source, target: target)
        _ = result.transform
        _ = result.rmsErrorMM
        _ = result.maxErrorMM
        _ = result.converged
        _ = result.iterations

        var options = ICPOptions()
        options.maxIterations = 10
        options.toleranceMM = 1e-4
        options.maxCorrespondenceDistanceMM = 2.0
        options.trimFraction = 0.8
        options.sampleLimit = 500
        _ = try ICP.refine(
            source: source, target: target, initial: result.transform, options: options)

        var mask = RegionMask(vertexCount: mesh.vertexCount)
        mask.exclude(sphereCentreMM: .zero, radiusMM: 0.5, vertices: mesh.verticesMM)
        mask.include(sphereCentreMM: .zero, radiusMM: 0.5, vertices: mesh.verticesMM)
        _ = mask.isIncluded(0)
        _ = mask.includedCount
        _ = mask.includedPoints(from: mesh.verticesMM)
    }

    // MARK: Esportazione immagini

    @Test("Le API usate da ImageExport e dal ProjectDocument")
    func exportAPI() throws {
        let volume = try makeVolume()
        let plane = MPRPlane.fitted(plane: .axial, geometry: volume.geometry)

        // `ImageExport.drawScaleBar` calcola i millimetri per pixel da qui.
        _ = plane.matchingAspect(pixelWidth: 1600, pixelHeight: 1200).widthMM

        // `ProjectDocument` serializza la curva come array di componenti.
        let curve = ArchCurve.defaultArch(for: volume.geometry)
        let encoded = curve.controlPointsMM.map { [$0.x, $0.y, $0.z] }
        let decoded = encoded.compactMap { values -> Vec3? in
            guard values.count >= 3 else { return nil }
            return Vec3(values[0], values[1], values[2])
        }
        #expect(decoded.count == curve.controlPointsMM.count)

        // `ProjectDocument` è Codable su questi tipi.
        _ = try JSONEncoder().encode(TransferFunction.bone)
        _ = try JSONEncoder().encode(
            [ImplantPlacement(platformMM: .zero)])
        _ = try JSONEncoder().encode([NerveCanal(side: .left)])
    }

    // MARK: CrosshairOverlay: le tracce del mirino

    @Test("Le API della geometria del mirino usate dalla sovraimpressione")
    func crosshairOverlayAPI() throws {
        let volume = try makeVolume()
        let geometry = volume.geometry
        let crosshair = geometry.centerMM

        // `CrosshairOverlay.viewPlane(in:)`
        let view = MPRPlane.fitted(plane: .axial, geometry: geometry)
            .matchingAspect(pixelWidth: 400, pixelHeight: 300)
        let other = MPRPlane.fitted(plane: .sagittal, geometry: geometry)
            .matchingAspect(pixelWidth: 400, pixelHeight: 300)

        // `CrosshairOverlay.traces(in:)`
        let trace = try #require(
            CrosshairGeometry.trace(
                of: other, in: view, through: crosshair,
                pixelWidth: 400, pixelHeight: 300))

        // `CrosshairOverlay.draw(_:in:)`
        _ = trace.start
        _ = trace.end
        _ = trace.pivot
        _ = trace.startHandle
        _ = trace.endHandle
        _ = trace.lengthPixels
        _ = CrosshairGeometry.centreGapPixels
        _ = trace.start.distance(to: trace.pivot)

        // `CrosshairOverlay.grip(at:among:)`
        let probe = PixelPoint(x: trace.pivot.x, y: 40)
        switch trace.grip(at: probe) {
        case .handle(let isStart): _ = isStart
        case .line: break
        case nil: break
        }
        _ = trace.distance(from: probe)

        // `CrosshairOverlay.apply(_:item:to:size:)`
        if let angle = trace.rotation(from: probe, to: PixelPoint(x: probe.x + 10, y: 60)) {
            _ = other.rotated(
                aboutAxis: trace.rotationAxisMM, byRadians: angle, aboutMM: crosshair)
        }
        let movement = trace.slide(
            from: probe, to: PixelPoint(x: probe.x + 10, y: 60),
            in: view, pixelWidth: 400, pixelHeight: 300)
        _ = crosshair + movement
    }

    // MARK: Modi di lavoro e raccolta dei volumi

    @Test("Le API dei modi di lavoro usate da AppModel e WorkModeBar")
    func workModeAPI() {
        // `AppModel.session`, `layout`, `focusedSlot`, `activate(mode:)`
        var session = WorkspaceSession()
        session.layout = .grid2x2
        session.focusedSlot = .axial
        session.activate(.curved)
        _ = session.mode
        _ = session.layout
        _ = session.focusedSlot
        session.reset(.curved)
        _ = session.hasCustomLayout(.orthogonal)

        // `WorkModeBar.tab(_:)`
        for mode in WorkMode.allCases {
            _ = mode.id
            _ = mode.shortName
            _ = mode.localizedName
            _ = mode.systemImageName
            _ = mode.defaultLayout
            _ = mode.defaultFocus
            _ = mode.isEditable
            _ = mode.usesArchCurve
            _ = mode.hint
        }

        // `ViewportGrid` e `ViewportActions`
        for slot in ViewportSlot.allCases {
            _ = slot.id
            _ = slot.localizedName
            if let anatomical = slot.anatomicalPlane {
                _ = anatomical.localizedName
            }
        }
        for layout in ViewportLayout.allCases {
            _ = layout.localizedName
            _ = layout.systemImageName
        }
    }

    @Test("Le API della raccolta dei volumi usate da AppModel e StudySidebar")
    func volumeLibraryAPI() throws {
        let volume = try makeVolume()

        // `AppModel.openStudy(volume:named:provenance:)`
        var library = VolumeLibrary()
        let root = library.open(volume, named: "Studio", provenance: .imported)

        // `AppModel.adopt(volume:named:operation:)`
        let derived = library.addDerived(
            volume, named: "Ritaglio", from: root, operation: "Ritaglio")

        // `AppModel.selectVolume(_:)` e `removeVolume(_:)`
        if let derived {
            _ = library.select(derived)
            _ = library[derived]
            _ = library.remove(derived)
        }

        // `StudySidebar.studyTree(volume:)`
        for entry in library.entries {
            _ = entry.id
            _ = entry.name
            _ = entry.summary
            _ = entry.provenance.parentID
            _ = entry.provenance.isImported
            _ = library.depth(of: entry.id)
            _ = library.provenanceDescription(of: entry.id)
        }
        _ = library.selectedID
        _ = library.selected
        _ = library.isEmpty
        _ = library.entries

        // `AppModel.reconstructionLabel`
        if case .synthetic = library.selectedRootProvenance {}
        library.rename(root, to: "Altro nome")
        _ = library.uniqueName("Ritaglio")
    }

    // MARK: ReviewPanel: la rilettura del piano

    @Test("Le API che la scheda «Rivedi» legge")
    func reviewPanelAPI() throws {
        let volume = try makeVolume()
        var library = VolumeLibrary()
        let root = library.open(volume, named: "Studio", provenance: .imported)
        _ = library.addDerived(volume, named: "Ritaglio", from: root, operation: "Ritaglio")

        // `ReviewPanel.volumeSection`
        if let entry = library.selected {
            _ = entry.name
            _ = entry.summary
            _ = library.depth(of: entry.id)
            _ = library.provenanceDescription(of: entry.id)
        }

        // `ReviewPanel.implantRow(_:)`
        let implant = ImplantPlacement(platformMM: Vec3(0, 0, 0), label: "13")
        _ = implant.label
        _ = implant.colorHex
        _ = implant.model.diameterMM
        _ = implant.model.lengthMM

        let report = SafetyAnalyzer.analyze(
            implant: implant, nerves: [], otherImplants: [], volume: volume,
            thresholds: .nerve)
        if let worst = report.findings.max(by: { $0.level < $1.level }) {
            _ = worst.structureName
            _ = worst.formattedDistance
            switch worst.level {
            case .safe, .caution, .danger: break
            }
        }
        _ = report.angulationDegrees
        _ = report.worstLevel
    }

    // MARK: Comandi delle sezioni trasversali

    @Test("Le API che l'ispettore usa per passo, spessore e disposizione della striscia")
    func crossSectionControlsAPI() throws {
        let volume = try makeVolume()
        let curve = ArchCurve(
            controlPointsMM: stride(from: -20.0, through: 20.0, by: 10.0).map {
                Vec3($0, $0 * $0 / 60 - 15, 0)
            })

        // `AppModel.crossSectionLayout` con i valori scelti dai menu dell'ispettore.
        let layout = CrossSectionLayout(
            curve: curve,
            intervalMM: 0.15,
            widthMM: 30,
            heightMM: 40,
            verticalCentreMM: 0,
            thicknessMM: 0.3,
            angleOffsetRadians: 0)
        let sections = layout.sections()
        #expect(!sections.isEmpty)

        // Lo spessore scelto arriva davvero nelle sezioni: è la ragione per cui il comando
        // esiste, e un parametro che si imposta senza effetto sarebbe peggio della sua assenza.
        #expect(sections.allSatisfy { $0.plane.slabThicknessMM == 0.3 })

        // `AppModel.crossSectionBrowser.visibleCount`, dal menu «Per fila».
        var browser = CrossSectionBrowser(sections: sections, visibleCount: 10)
        browser.visibleCount = 3
        #expect(browser.visibleCount == 3)
        #expect(browser.visibleRange.count <= 3)

        // `AppModel.reconstructionStepLabel`
        _ = volume.geometry.isIsotropic()
        _ = volume.geometry.spacingMM

        // `AppModel.adopt(volume:preservingPlan:)`: il mirino resta dov'è se il nuovo volume lo
        // contiene. Verifico che la domanda si possa porre e che risponda nei due modi, perché
        // una `containsPatientPoint` sempre vera renderebbe il ramo inutile senza segnalarlo.
        let centre = volume.geometry.centerMM
        #expect(volume.geometry.containsPatientPoint(centre))
        let faraway = centre + volume.geometry.physicalSizeMM
        #expect(!volume.geometry.containsPatientPoint(faraway))
    }
}
