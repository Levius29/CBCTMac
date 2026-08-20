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

    /// Riproietta sul piano perpendicolare alla vista che passa per un punto scelto.
    ///
    /// # Perché non basta `unproject(x:y:)`
    ///
    /// Quella cade sul piano che passa per il **bersaglio della telecamera**. Va bene per posare
    /// qualcosa di nuovo al centro della scena, e non va bene per trascinare: afferrando un
    /// impianto che sta dieci millimetri più avanti, il primo movimento del mouse lo
    /// scaraventerebbe sul piano del bersaglio — un salto in profondità che l'utente non ha
    /// chiesto e che, guardando da quella direzione, non si vede nemmeno.
    ///
    /// La telecamera è **ortografica** — `project` non divide per la profondità — quindi la
    /// riproiezione su un piano parallelo è una semplice traslazione lungo l'asse di vista. Con
    /// una prospettiva servirebbe intersecare un raggio, e questa formula sarebbe sbagliata.
    public func unproject(x: Double, y: Double, onPlaneThrough anchorMM: Vec3) -> Vec3 {
        let base = unproject(x: x, y: y)
        let depth = (anchorMM - camera.targetMM).dot(camera.forward)
        guard depth.isFinite else { return base }
        return base + camera.forward * depth
    }

    /// Il primo punto di superficie che il raggio passante per un pixel incontra.
    ///
    /// # A che serve
    ///
    /// A poter **indicare qualcosa nel 3D**. Fino a qui il riquadro tridimensionale sapeva
    /// riproiettare un pixel soltanto su un piano di cui si conoscesse già la profondità: va bene
    /// per trascinare un impianto che è già lì, e non basta per posare un punto nuovo, perché la
    /// profondità è precisamente ciò che non si sa.
    ///
    /// Qui la profondità la decide l'anatomia: si avanza lungo il raggio e si prende il primo
    /// campione che supera la soglia. È lo stesso criterio con cui il raycaster decide che cosa
    /// disegnare, quindi il punto che si ottiene è quello che si stava guardando.
    ///
    /// # I due modi in cui sbaglia
    ///
    /// Prende qualunque cosa superi la soglia, compreso quel che sta **davanti** a ciò che si
    /// voleva: con una soglia da tessuto molle si prende la guancia invece del dente. E su una
    /// superficie molto obliqua rispetto al raggio il punto cade dove il raggio entra, che può
    /// essere qualche decimo di millimetro più in qua del punto che si intendeva.
    ///
    /// - Parameters:
    ///   - x: pixel orizzontale nel riquadro.
    ///   - y: pixel verticale nel riquadro.
    ///   - volume: il volume da attraversare.
    ///   - thresholdGV: sopra questo valore comincia la superficie.
    ///   - stepMM: passo di avanzamento. `nil` prende mezzo voxel, che è il passo più lungo che
    ///     non può saltare una struttura sottile.
    /// - Returns: il punto in millimetri Patient, o `nil` se il raggio non incontra niente.
    public func pickSurfacePointMM(
        x: Double, y: Double, in volume: Volume, thresholdGV: Double, stepMM: Double? = nil
    ) -> Vec3? {
        let geometry = volume.geometry
        let corners = geometry.boundingBoxCornersMM
        guard !corners.isEmpty else { return nil }

        // Da dove a dove avanzare: la fetta di profondità che il volume occupa lungo la vista.
        // Partire da più lontano sarebbe tempo speso a campionare il nulla.
        let depths = corners.map { ($0 - camera.targetMM).dot(camera.forward) }
        guard let nearest = depths.min(), let farthest = depths.max() else { return nil }

        let spacing = geometry.spacingMM
        let step = stepMM ?? Swift.max(
            0.05, Swift.min(spacing.x, Swift.min(spacing.y, spacing.z)) / 2)

        let origin = unproject(x: x, y: y)
        var travelled = nearest
        var previousValue: Double?
        var previousPoint = origin + camera.forward * travelled

        while travelled <= farthest {
            let point = origin + camera.forward * travelled
            let value = volume.interpolatedDensityValue(atPatient: point)
            if let value, value >= thresholdGV {
                // Il bordo non sta al centro di un voxel: si interpola fra l'ultimo campione
                // sotto soglia e il primo sopra, come per il profilo del viso.
                guard let previousValue, previousValue < thresholdGV, value > previousValue else {
                    return point
                }
                let fraction = (thresholdGV - previousValue) / (value - previousValue)
                return previousPoint.lerp(to: point, t: fraction)
            }
            // Fuori dal volume non c'è aria, non c'è niente: interpolare da lì inventerebbe un
            // bordo mezzo passo più avanti di dove comincia il dato.
            previousValue = value
            previousPoint = point
            travelled += step
        }
        return nil
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
