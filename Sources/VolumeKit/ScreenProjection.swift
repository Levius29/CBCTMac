import DICOMCore

/// Punto proiettato: pixel nel riquadro più profondità con segno lungo la vista.
public struct ProjectedPoint: Hashable, Sendable {
    public let x: Double
    public let y: Double
    /// Distanza con segno lungo `forward`. Serve a decidere cosa sta davanti a cosa.
    public let depthMM: Double
}

/// Segmento proiettato con l'indicazione approssimata della sua visibilità.
public struct ScreenSegment: Hashable, Sendable {
    public let from: ProjectedPoint
    public let to: ProjectedPoint
    public let isHidden: Bool
}

/// Proiezione ortografica fra coordinate Patient e pixel del riquadro 3D.
public struct ScreenProjector: Hashable, Sendable {
    private let camera: VolumeCamera
    private let pixelWidth: Int
    private let pixelHeight: Int

    /// Costruisce una proiezione; dimensioni non positive vengono ridotte a un pixel.
    public init(camera: VolumeCamera, pixelWidth: Int, pixelHeight: Int) {
        self.camera = camera
        self.pixelWidth = max(pixelWidth, 1)
        self.pixelHeight = max(pixelHeight, 1)
    }

    /// Proietta un punto Patient senza divisione per la profondità.
    public func project(_ pointMM: Vec3) -> ProjectedPoint {
        let relative = pointMM - camera.targetMM
        let halfHeight = validHalfHeight
        let halfWidth = halfHeight * aspectRatio
        let u = relative.dot(camera.right) / halfWidth
        let v = relative.dot(camera.down) / halfHeight
        return ProjectedPoint(
            x: (u + 1) * 0.5 * Double(pixelWidth),
            y: (v + 1) * 0.5 * Double(pixelHeight),
            depthMM: relative.dot(camera.forward)
        )
    }

    /// Riproietta sul piano perpendicolare alla vista che passa per il bersaglio.
    public func unproject(x: Double, y: Double) -> Vec3 {
        let u = x / Double(pixelWidth) * 2 - 1
        let v = y / Double(pixelHeight) * 2 - 1
        let halfHeight = validHalfHeight
        let halfWidth = halfHeight * aspectRatio
        return camera.targetMM
            + camera.right * (u * halfWidth)
            + camera.down * (v * halfHeight)
    }

    private var aspectRatio: Double {
        Double(pixelWidth) / Double(pixelHeight)
    }

    private var validHalfHeight: Double {
        camera.halfHeightMM.isFinite && camera.halfHeightMM > 0
            ? camera.halfHeightMM
            : 1
    }
}
