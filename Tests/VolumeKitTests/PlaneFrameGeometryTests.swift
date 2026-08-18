import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

@Suite("Geometria delle sovraimpressioni 3D")
struct PlaneFrameGeometryTests {
    @Test("Proiezione e inversa rispettano l'aspetto di un riquadro 1280×720")
    func projectionRoundTripOnWideViewport() {
        let camera = VolumeCamera(
            azimuth: 0.63,
            elevation: -0.31,
            halfHeightMM: 70,
            targetMM: Vec3(12, -8, 5)
        )
        let projector = ScreenProjector(camera: camera, pixelWidth: 1280, pixelHeight: 720)
        let aspect = 1280.0 / 720.0
        let rightEdge = camera.targetMM + camera.right * (camera.halfHeightMM * aspect)
        let point = camera.targetMM
            + camera.right * 31
            + camera.down * -19

        let edgeProjection = projector.project(rightEdge)
        let projected = projector.project(point)
        let restored = projector.unproject(x: projected.x, y: projected.y)

        // Il solo round trip non basta: due formule che omettono entrambe l'aspetto si
        // annullerebbero a vicenda. Il bordo destro deve quindi cadere davvero a 1280 px.
        #expect(abs(edgeProjection.x - 1280) < 1e-9)
        #expect(restored.isApproximatelyEqual(to: point, tolerance: 1e-9))
    }

    @Test("Il bersaglio resta al centro con cinque orientamenti della camera")
    func targetProjectsToViewportCentre() throws {
        let geometry = try makeGeometry()
        let orientations: [(Double, Double)] = [
            (0, 0),
            (0.7, 0.2),
            (-1.1, -0.4),
            (2.2, 0.8),
            (-2.7, 1.3),
        ]

        for orientation in orientations {
            let camera = VolumeCamera(
                azimuth: orientation.0,
                elevation: orientation.1,
                halfHeightMM: 50,
                targetMM: geometry.centerMM
            )
            let point = ScreenProjector(
                camera: camera,
                pixelWidth: 1280,
                pixelHeight: 720
            ).project(geometry.centerMM)

            #expect(abs(point.x - 640) < 1e-9)
            #expect(abs(point.y - 360) < 1e-9)
            #expect(abs(point.depthMM) < 1e-9)
        }
    }

    @Test("La cornice più grande viene tagliata contro il volume")
    func oversizedPlaneIsClipped() throws {
        let geometry = try makeGeometry()
        let projector = frontProjector(targetMM: geometry.centerMM)
        let plane = MPRPlane(
            centerMM: .zero,
            rightMM: Vec3(1, 0, 0),
            downMM: Vec3(0, 0, 1),
            widthMM: 80,
            heightMM: 80
        )

        let segments = PlaneFrameGeometry.outline(
            of: plane,
            clippedTo: geometry,
            projector: projector
        )
        let volumeBounds = projectedBounds(
            of: geometry.boundingBoxCornersMM,
            projector: projector
        )
        let fullRectangle = projectedRectangle(of: plane, projector: projector)

        #expect(segments.count == 4)
        for segment in segments {
            #expect(isInside(segment.from, bounds: volumeBounds, tolerance: 1e-9))
            #expect(isInside(segment.to, bounds: volumeBounds, tolerance: 1e-9))
        }
        #expect(perimeter(of: segments) < perimeter(of: fullRectangle))
    }

    @Test("La cornice interna conserva i quattro vertici originali")
    func internalPlaneIsNotClipped() throws {
        let geometry = try makeGeometry()
        let projector = frontProjector(targetMM: geometry.centerMM)
        let plane = MPRPlane(
            centerMM: .zero,
            rightMM: Vec3(1, 0, 0),
            downMM: Vec3(0, 0, 1),
            widthMM: 10,
            heightMM: 12
        )
        let expected = projectedRectangle(of: plane, projector: projector)

        let actual = PlaneFrameGeometry.outline(
            of: plane,
            clippedTo: geometry,
            projector: projector
        )

        #expect(actual.count == 4)
        for expectedSegment in expected {
            #expect(containsPoint(expectedSegment.from, in: actual, tolerance: 1e-9))
        }
    }

    @Test("Un piano esterno al volume non produce segmenti")
    func disjointPlaneProducesNoSegments() throws {
        let geometry = try makeGeometry()
        let plane = MPRPlane(
            centerMM: Vec3(0, 100, 0),
            rightMM: Vec3(1, 0, 0),
            downMM: Vec3(0, 0, 1),
            widthMM: 10,
            heightMM: 10
        )

        let segments = PlaneFrameGeometry.outline(
            of: plane,
            clippedTo: geometry,
            projector: frontProjector(targetMM: geometry.centerMM)
        )

        #expect(segments.isEmpty)
    }

    @Test("Il piano visto di taglio diventa un segmento finito")
    func edgeOnPlaneProducesOneFiniteSegment() throws {
        let geometry = try makeGeometry()
        let projector = frontProjector(targetMM: geometry.centerMM)
        // La normale è +z, perpendicolare al forward +y della camera: il piano è edge-on.
        let plane = MPRPlane(
            centerMM: .zero,
            rightMM: Vec3(1, 0, 0),
            downMM: Vec3(0, 1, 0),
            widthMM: 10,
            heightMM: 10
        )

        let segments = PlaneFrameGeometry.outline(
            of: plane,
            clippedTo: geometry,
            projector: projector
        )

        #expect(segments.count == 1)
        for segment in segments {
            #expect(segment.from.x.isFinite)
            #expect(segment.from.y.isFinite)
            #expect(segment.from.depthMM.isFinite)
            #expect(segment.to.x.isFinite)
            #expect(segment.to.y.isFinite)
            #expect(segment.to.depthMM.isFinite)
        }
    }

    @Test("Il riquadro ha dodici spigoli, e nascosti sono quelli dietro il centro")
    func boundingBoxHasTwelveEdgesAndHidesTheFarOnes() throws {
        let geometry = try makeGeometry()
        let projector = frontProjector(targetMM: geometry.centerMM)
        let segments = PlaneFrameGeometry.boundingBoxEdges(
            of: geometry,
            projector: projector
        )
        let arbitraryBox = PlaneFrameGeometry.boxEdges(
            corners: geometry.boundingBoxCornersMM,
            projector: projector
        )

        #expect(segments.count == 12)
        #expect(arbitraryBox.count == 12)

        // Contare quanti sono nascosti **non basta**, e questa è la ragione per cui il test è
        // scritto così. Un riquadro visto di fronte ha quattro spigoli sulla faccia vicina,
        // quattro su quella lontana e quattro equatoriali: invertendo il confronto di profondità
        // il conteggio resta quattro, e un test sul solo numero passa anche col segno sbagliato.
        // Quello che va verificato è **quali**.
        for segment in segments {
            // La proiezione è affine, quindi la profondità del punto medio è la media delle due.
            let midpointDepth = (segment.from.depthMM + segment.to.depthMM) / 2
            if midpointDepth > 1e-9 {
                #expect(segment.isHidden, "uno spigolo dietro il centro deve essere nascosto")
            } else if midpointDepth < -1e-9 {
                #expect(!segment.isHidden, "uno spigolo davanti al centro deve essere in vista")
            }
        }

        // E almeno uno per parte deve esistere davvero: se tutti gli spigoli cadessero
        // sull'equatore il ciclo qui sopra non verificherebbe nulla e passerebbe comunque.
        let far = segments.filter { (s: ScreenSegment) in (s.from.depthMM + s.to.depthMM) / 2 > 1e-9 }
        let near = segments.filter { (s: ScreenSegment) in (s.from.depthMM + s.to.depthMM) / 2 < -1e-9 }
        #expect(far.count == 4)
        #expect(near.count == 4)
    }

    @Test("La banda ha il contorno atteso e ad altezza zero resta una polilinea")
    func ribbonDegeneratesToPolylineAtZeroHeight() {
        let points = [
            Vec3(-12, 0, 0),
            Vec3(-4, 1, 0),
            Vec3(5, 2, 0),
            Vec3(14, 4, 0),
        ]
        let projector = frontProjector(targetMM: .zero)

        let ribbon = PlaneFrameGeometry.ribbon(
            alongMM: points,
            upAxis: Vec3(0, 0, 1),
            halfHeightMM: 3,
            projector: projector
        )
        let polyline = PlaneFrameGeometry.ribbon(
            alongMM: points,
            upAxis: Vec3(0, 0, 1),
            halfHeightMM: 0,
            projector: projector
        )

        #expect(ribbon.count == 2 * points.count)
        #expect(polyline.count == points.count - 1)
        for segment in polyline {
            #expect(screenLength(of: segment) > 0)
        }
    }

    private func makeGeometry() throws -> VolumeGeometry {
        try VolumeGeometry(
            columnCount: 20,
            rowCount: 30,
            sliceCount: 40,
            columnSpacingMM: 1,
            rowSpacingMM: 1,
            sliceSpacingMM: 1,
            orientation: .standardAxial,
            originMM: Vec3(-9.5, -14.5, -19.5)
        )
    }

    private func frontProjector(targetMM: Vec3) -> ScreenProjector {
        ScreenProjector(
            camera: VolumeCamera(halfHeightMM: 50, targetMM: targetMM),
            pixelWidth: 1000,
            pixelHeight: 800
        )
    }

    private func projectedRectangle(
        of plane: MPRPlane,
        projector: ScreenProjector
    ) -> [ScreenSegment] {
        let topLeft = plane.topLeftMM
        let corners = [
            topLeft,
            topLeft + plane.rightMM * plane.widthMM,
            topLeft + plane.rightMM * plane.widthMM + plane.downMM * plane.heightMM,
            topLeft + plane.downMM * plane.heightMM,
        ]
        var result = [ScreenSegment]()
        for index in corners.indices {
            let next = (index + 1) % corners.count
            result.append(
                ScreenSegment(
                    from: projector.project(corners[index]),
                    to: projector.project(corners[next]),
                    isHidden: false
                )
            )
        }
        return result
    }

    private func projectedBounds(
        of corners: [Vec3],
        projector: ScreenProjector
    ) -> (minimumX: Double, maximumX: Double, minimumY: Double, maximumY: Double) {
        var minimumX = Double.infinity
        var maximumX = -Double.infinity
        var minimumY = Double.infinity
        var maximumY = -Double.infinity
        for corner in corners {
            let point = projector.project(corner)
            minimumX = min(minimumX, point.x)
            maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y)
            maximumY = max(maximumY, point.y)
        }
        return (minimumX, maximumX, minimumY, maximumY)
    }

    private func isInside(
        _ point: ProjectedPoint,
        bounds: (minimumX: Double, maximumX: Double, minimumY: Double, maximumY: Double),
        tolerance: Double
    ) -> Bool {
        point.x >= bounds.minimumX - tolerance
            && point.x <= bounds.maximumX + tolerance
            && point.y >= bounds.minimumY - tolerance
            && point.y <= bounds.maximumY + tolerance
    }

    private func containsPoint(
        _ point: ProjectedPoint,
        in segments: [ScreenSegment],
        tolerance: Double
    ) -> Bool {
        for segment in segments {
            if approximatelyEqual(point, segment.from, tolerance: tolerance)
                || approximatelyEqual(point, segment.to, tolerance: tolerance)
            {
                return true
            }
        }
        return false
    }

    private func approximatelyEqual(
        _ first: ProjectedPoint,
        _ second: ProjectedPoint,
        tolerance: Double
    ) -> Bool {
        abs(first.x - second.x) <= tolerance
            && abs(first.y - second.y) <= tolerance
            && abs(first.depthMM - second.depthMM) <= tolerance
    }

    private func perimeter(of segments: [ScreenSegment]) -> Double {
        var result = 0.0
        for segment in segments {
            result += screenLength(of: segment)
        }
        return result
    }

    private func screenLength(of segment: ScreenSegment) -> Double {
        let dx = segment.to.x - segment.from.x
        let dy = segment.to.y - segment.from.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
