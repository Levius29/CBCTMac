import DICOMCore
import Foundation

/// Geometria CPU delle cornici sovrapposte alla vista tridimensionale.
public enum PlaneFrameGeometry: Sendable {
    /// Cornice di un piano MPR tagliata contro i sei semispazi del volume.
    public static func outline(
        of plane: MPRPlane,
        clippedTo geometry: VolumeGeometry,
        projector: ScreenProjector
    ) -> [ScreenSegment] {
        guard plane.centerMM.isFinite,
              plane.rightMM.isFinite,
              plane.downMM.isFinite,
              plane.widthMM.isFinite,
              plane.heightMM.isFinite,
              plane.widthMM > 0,
              plane.heightMM > 0
        else { return [] }

        let topLeft = plane.topLeftMM
        let patientCorners = [
            topLeft,
            topLeft + plane.rightMM * plane.widthMM,
            topLeft + plane.rightMM * plane.widthMM + plane.downMM * plane.heightMM,
            topLeft + plane.downMM * plane.heightMM,
        ]
        var voxelPolygon = [Vec3]()
        voxelPolygon.reserveCapacity(patientCorners.count)
        for corner in patientCorners {
            let voxel = geometry.voxelPoint(fromPatient: corner)
            guard voxel.isFinite else { return [] }
            voxelPolygon.append(voxel)
        }

        let minimum = Vec3(-0.5, -0.5, -0.5)
        let maximum = Vec3(
            Double(geometry.columnCount) - 0.5,
            Double(geometry.rowCount) - 0.5,
            Double(geometry.sliceCount) - 0.5
        )
        for axis in 0..<3 {
            voxelPolygon = clipped(
                voxelPolygon,
                axis: axis,
                boundary: component(of: minimum, axis: axis),
                keepsGreaterValues: true
            )
            if voxelPolygon.isEmpty { return [] }
            voxelPolygon = clipped(
                voxelPolygon,
                axis: axis,
                boundary: component(of: maximum, axis: axis),
                keepsGreaterValues: false
            )
            if voxelPolygon.isEmpty { return [] }
        }

        voxelPolygon = removingAdjacentDuplicates(voxelPolygon)
        guard voxelPolygon.count >= 2 else { return [] }
        var patientPolygon = [Vec3]()
        patientPolygon.reserveCapacity(voxelPolygon.count)
        for voxel in voxelPolygon {
            patientPolygon.append(geometry.patientPoint(fromVoxel: voxel))
        }
        let referenceDepth = projector.project(geometry.centerMM).depthMM
        return outlineSegments(
            patientPolygon,
            projector: projector,
            hiddenReferenceDepth: referenceDepth
        )
    }

    /// Restituisce i dodici spigoli del riquadro contenitore del volume.
    public static func boundingBoxEdges(
        of geometry: VolumeGeometry,
        projector: ScreenProjector
    ) -> [ScreenSegment] {
        boxEdges(
            corners: geometry.boundingBoxCornersMM,
            hiddenReferenceDepth: projector.project(geometry.centerMM).depthMM,
            projector: projector
        )
    }

    /// Restituisce gli spigoli di un riquadro descritto dagli otto vertici ordinati per bit XYZ.
    public static func boxEdges(
        corners: [Vec3],
        projector: ScreenProjector
    ) -> [ScreenSegment] {
        guard corners.count == 8,
              corners.allSatisfy({ (point: Vec3) in point.isFinite })
        else { return [] }
        // Senza una `VolumeGeometry` il miglior riferimento disponibile è il piano del bersaglio,
        // a profondità zero. La camera fitted punta al centro del volume, che è il caso d'uso.
        return boxEdges(corners: corners, hiddenReferenceDepth: 0, projector: projector)
    }

    /// Costruisce il contorno della banda estrusa lungo la polilinea campionata.
    public static func ribbon(
        alongMM points: [Vec3],
        upAxis: Vec3,
        halfHeightMM: Double,
        projector: ScreenProjector
    ) -> [ScreenSegment] {
        guard points.count >= 2,
              points.allSatisfy({ (point: Vec3) in point.isFinite })
        else { return [] }
        // Anche qui l'API non riceve il volume: il bersaglio della camera ne rappresenta il
        // centro e quindi il suo piano, a profondità zero, è il riferimento coerente.
        let referenceDepth = 0.0
        guard halfHeightMM.isFinite,
              halfHeightMM > 0,
              let up = upAxis.normalized
        else {
            return polylineSegments(
                points,
                projector: projector,
                hiddenReferenceDepth: referenceDepth
            )
        }

        let offset = up * halfHeightMM
        var upper = [Vec3]()
        var lower = [Vec3]()
        upper.reserveCapacity(points.count)
        lower.reserveCapacity(points.count)
        for point in points {
            upper.append(point + offset)
            lower.append(point - offset)
        }

        var result = polylineSegments(
            upper,
            projector: projector,
            hiddenReferenceDepth: referenceDepth
        )
        result.append(contentsOf: polylineSegments(
            lower,
            projector: projector,
            hiddenReferenceDepth: referenceDepth
        ))
        result.append(segment(
            from: upper[0],
            to: lower[0],
            projector: projector,
            hiddenReferenceDepth: referenceDepth
        ))
        let last = points.count - 1
        result.append(segment(
            from: upper[last],
            to: lower[last],
            projector: projector,
            hiddenReferenceDepth: referenceDepth
        ))
        return result
    }

    private static let edgeIndices: [(Int, Int)] = [
        (0, 1), (0, 2), (0, 4),
        (1, 3), (1, 5),
        (2, 3), (2, 6),
        (3, 7),
        (4, 5), (4, 6),
        (5, 7),
        (6, 7),
    ]

    private static func boxEdges(
        corners: [Vec3],
        hiddenReferenceDepth: Double,
        projector: ScreenProjector
    ) -> [ScreenSegment] {
        guard corners.count == 8,
              hiddenReferenceDepth.isFinite,
              corners.allSatisfy({ (point: Vec3) in point.isFinite })
        else { return [] }
        var result = [ScreenSegment]()
        result.reserveCapacity(edgeIndices.count)
        for edge in edgeIndices {
            result.append(segment(
                from: corners[edge.0],
                to: corners[edge.1],
                projector: projector,
                hiddenReferenceDepth: hiddenReferenceDepth
            ))
        }
        return result
    }

    private static func outlineSegments(
        _ points: [Vec3],
        projector: ScreenProjector,
        hiddenReferenceDepth: Double
    ) -> [ScreenSegment] {
        var projected = [ProjectedPoint]()
        projected.reserveCapacity(points.count)
        for point in points { projected.append(projector.project(point)) }
        guard projected.allSatisfy({ (point: ProjectedPoint) in isFinite(point) }) else {
            return []
        }

        let farthest = farthestPair(in: projected)
        guard farthest.distanceSquared > 1e-18 else { return [] }
        if isCollinear(projected, along: farthest) {
            return [segment(
                from: points[farthest.first],
                to: points[farthest.second],
                projector: projector,
                hiddenReferenceDepth: hiddenReferenceDepth
            )]
        }

        var result = [ScreenSegment]()
        result.reserveCapacity(points.count)
        for index in points.indices {
            let next = (index + 1) % points.count
            if screenDistanceSquared(projected[index], projected[next]) <= 1e-18 { continue }
            result.append(segment(
                from: points[index],
                to: points[next],
                projector: projector,
                hiddenReferenceDepth: hiddenReferenceDepth
            ))
        }
        return result
    }

    private static func polylineSegments(
        _ points: [Vec3],
        projector: ScreenProjector,
        hiddenReferenceDepth: Double
    ) -> [ScreenSegment] {
        guard points.count >= 2 else { return [] }
        var result = [ScreenSegment]()
        result.reserveCapacity(points.count - 1)
        for index in 0..<(points.count - 1) {
            result.append(segment(
                from: points[index],
                to: points[index + 1],
                projector: projector,
                hiddenReferenceDepth: hiddenReferenceDepth
            ))
        }
        return result
    }

    private static func segment(
        from: Vec3,
        to: Vec3,
        projector: ScreenProjector,
        hiddenReferenceDepth: Double
    ) -> ScreenSegment {
        let midpoint = (from + to) * 0.5
        let midpointDepth = projector.project(midpoint).depthMM
        // È un'approssimazione deliberata: senza il depth buffer CPU si confronta il punto
        // medio con il centro del volume. Per cornici sottili basta a distinguere il lato
        // posteriore, mentre l'occlusione esatta resta responsabilità del renderer.
        let hidden = midpointDepth > hiddenReferenceDepth + 1e-9
        return ScreenSegment(
            from: projector.project(from),
            to: projector.project(to),
            isHidden: hidden
        )
    }

    private static func clipped(
        _ polygon: [Vec3],
        axis: Int,
        boundary: Double,
        keepsGreaterValues: Bool
    ) -> [Vec3] {
        guard !polygon.isEmpty else { return [] }
        var result = [Vec3]()
        result.reserveCapacity(polygon.count + 1)
        var previous = polygon[polygon.count - 1]
        var previousInside = isInside(
            previous,
            axis: axis,
            boundary: boundary,
            keepsGreaterValues: keepsGreaterValues
        )
        for current in polygon {
            let currentInside = isInside(
                current,
                axis: axis,
                boundary: boundary,
                keepsGreaterValues: keepsGreaterValues
            )
            if currentInside != previousInside,
               let intersection = intersection(
                   from: previous,
                   to: current,
                   axis: axis,
                   boundary: boundary
               )
            {
                result.append(intersection)
            }
            if currentInside { result.append(current) }
            previous = current
            previousInside = currentInside
        }
        return result
    }

    private static func isInside(
        _ point: Vec3,
        axis: Int,
        boundary: Double,
        keepsGreaterValues: Bool
    ) -> Bool {
        let value = component(of: point, axis: axis)
        return keepsGreaterValues ? value >= boundary - 1e-9 : value <= boundary + 1e-9
    }

    private static func intersection(
        from: Vec3,
        to: Vec3,
        axis: Int,
        boundary: Double
    ) -> Vec3? {
        let start = component(of: from, axis: axis)
        let difference = component(of: to, axis: axis) - start
        guard difference.isFinite, abs(difference) > 1e-15 else { return nil }
        let t = (boundary - start) / difference
        guard t.isFinite else { return nil }
        return from.lerp(to: to, t: min(max(t, 0), 1))
    }

    private static func component(of point: Vec3, axis: Int) -> Double {
        switch axis {
        case 0: return point.x
        case 1: return point.y
        default: return point.z
        }
    }

    private static func removingAdjacentDuplicates(_ points: [Vec3]) -> [Vec3] {
        var result = [Vec3]()
        for point in points {
            if let last = result.last,
               last.isApproximatelyEqual(to: point, tolerance: 1e-9)
            {
                continue
            }
            result.append(point)
        }
        if result.count > 1,
           let first = result.first,
           let last = result.last,
           first.isApproximatelyEqual(to: last, tolerance: 1e-9)
        {
            result.removeLast()
        }
        return result
    }

    private static func farthestPair(
        in points: [ProjectedPoint]
    ) -> (first: Int, second: Int, distanceSquared: Double) {
        var first = 0
        var second = 0
        var maximum = 0.0
        if points.count < 2 { return (first, second, maximum) }
        for i in 0..<(points.count - 1) {
            for j in (i + 1)..<points.count {
                let distance = screenDistanceSquared(points[i], points[j])
                if distance > maximum {
                    first = i
                    second = j
                    maximum = distance
                }
            }
        }
        return (first, second, maximum)
    }

    private static func isCollinear(
        _ points: [ProjectedPoint],
        along pair: (first: Int, second: Int, distanceSquared: Double)
    ) -> Bool {
        let start = points[pair.first]
        let end = points[pair.second]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = pair.distanceSquared.squareRoot()
        guard length > 0 else { return true }
        for point in points {
            let cross = (point.x - start.x) * dy - (point.y - start.y) * dx
            if abs(cross) / length > 1e-7 { return false }
        }
        return true
    }

    private static func screenDistanceSquared(
        _ first: ProjectedPoint,
        _ second: ProjectedPoint
    ) -> Double {
        let dx = second.x - first.x
        let dy = second.y - first.y
        return dx * dx + dy * dy
    }

    private static func isFinite(_ point: ProjectedPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.depthMM.isFinite
    }
}
