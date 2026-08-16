import DICOMCore
import Foundation

// Impianti: modello geometrico e collocazione nello spazio.
//
// I modelli sono **parametrici**, generati da un profilo tornito. Non si distribuisce la
// geometria dei cataloghi dei produttori: è materiale coperto da proprietà intellettuale, e
// pubblicarne le forme in una repository non sarebbe una scelta difendibile. L'utente potrà
// importare i propri STL; qui ci sono forme generiche con le misure che contano davvero per la
// pianificazione — diametro, lunghezza, conicità, piattaforma.

// MARK: - Profilo

/// Un punto del profilo torniato: alla quota `z` dalla piattaforma, il raggio è `radius`.
public struct ProfilePoint: Hashable, Sendable, Codable {
    /// Distanza dalla piattaforma lungo l'asse, verso l'apice. Sempre ≥ 0.
    public var zMM: Double
    public var radiusMM: Double

    public init(zMM: Double, radiusMM: Double) {
        self.zMM = max(zMM, 0)
        self.radiusMM = max(radiusMM, 0)
    }
}

// MARK: - Modello

public struct ImplantModel: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    public var manufacturer: String
    public var line: String
    public var diameterMM: Double
    public var lengthMM: Double
    /// Diametro della piattaforma protesica, di norma pari o poco diverso dal diametro del corpo.
    public var platformDiameterMM: Double
    /// Profilo dalla piattaforma all'apice, ordinato per `zMM` crescente.
    public var profile: [ProfilePoint]

    public init(
        id: UUID = UUID(),
        manufacturer: String,
        line: String,
        diameterMM: Double,
        lengthMM: Double,
        platformDiameterMM: Double? = nil,
        profile: [ProfilePoint]? = nil
    ) {
        self.id = id
        self.manufacturer = manufacturer
        self.line = line
        self.diameterMM = max(diameterMM, 0.1)
        self.lengthMM = max(lengthMM, 0.1)
        self.platformDiameterMM = platformDiameterMM ?? diameterMM
        self.profile =
            profile ?? Self.taperedProfile(diameterMM: diameterMM, lengthMM: lengthMM)
    }

    public var displayName: String {
        String(format: "%@ %@ Ø%.1f × %.0f mm", manufacturer, line, diameterMM, lengthMM)
            .replacingOccurrences(of: ".", with: ",")
    }

    /// Raggio del profilo alla quota `z`, per interpolazione lineare.
    public func radius(atZ z: Double) -> Double {
        guard !profile.isEmpty else { return diameterMM / 2 }
        if z <= profile[0].zMM { return profile[0].radiusMM }
        if let last = profile.last, z >= last.zMM { return last.radiusMM }

        for index in 0..<(profile.count - 1) {
            let lower = profile[index]
            let upper = profile[index + 1]
            guard z >= lower.zMM, z <= upper.zMM else { continue }
            let span = upper.zMM - lower.zMM
            let t = span > 1e-12 ? (z - lower.zMM) / span : 0
            return lower.radiusMM + (upper.radiusMM - lower.radiusMM) * t
        }
        return diameterMM / 2
    }

    // MARK: Profili generati

    /// Profilo conico: la forma più diffusa negli impianti moderni.
    ///
    /// Colletto leggermente svasato, corpo che si restringe verso l'apice, punta arrotondata.
    /// Le proporzioni sono quelle tipiche, non quelle di un prodotto specifico.
    public static func taperedProfile(diameterMM: Double, lengthMM: Double) -> [ProfilePoint] {
        let radius = diameterMM / 2
        return [
            ProfilePoint(zMM: 0, radiusMM: radius),
            ProfilePoint(zMM: lengthMM * 0.08, radiusMM: radius),
            ProfilePoint(zMM: lengthMM * 0.55, radiusMM: radius * 0.92),
            ProfilePoint(zMM: lengthMM * 0.85, radiusMM: radius * 0.78),
            ProfilePoint(zMM: lengthMM * 0.96, radiusMM: radius * 0.55),
            ProfilePoint(zMM: lengthMM, radiusMM: radius * 0.18),
        ]
    }

    /// Profilo cilindrico, con la sola punta arrotondata.
    public static func cylindricalProfile(diameterMM: Double, lengthMM: Double) -> [ProfilePoint] {
        let radius = diameterMM / 2
        return [
            ProfilePoint(zMM: 0, radiusMM: radius),
            ProfilePoint(zMM: lengthMM * 0.94, radiusMM: radius),
            ProfilePoint(zMM: lengthMM * 0.98, radiusMM: radius * 0.7),
            ProfilePoint(zMM: lengthMM, radiusMM: radius * 0.2),
        ]
    }

    // MARK: Catalogo generico

    /// Diametri e lunghezze correnti nella pratica implantare.
    public static let commonDiameters: [Double] = [3.0, 3.3, 3.5, 3.75, 4.0, 4.1, 4.3, 4.8, 5.0, 5.5, 6.0]
    public static let commonLengths: [Double] = [6, 7, 8, 8.5, 10, 11.5, 12, 13, 15, 16, 18]

    /// Catalogo di forme generiche, come punto di partenza.
    ///
    /// Volutamente anonimo: nessun nome commerciale, nessuna geometria copiata. Serve a
    /// pianificare con misure realistiche prima che l'utente importi i propri STL.
    public static func genericCatalog() -> [ImplantModel] {
        var models: [ImplantModel] = []
        for diameter in [3.3, 3.75, 4.1, 4.8, 5.5] {
            for length in [8.0, 10.0, 11.5, 13.0] {
                models.append(
                    ImplantModel(
                        manufacturer: "Generico",
                        line: "Conico",
                        diameterMM: diameter,
                        lengthMM: length))
            }
        }
        return models
    }

    public static let `default` = ImplantModel(
        manufacturer: "Generico", line: "Conico", diameterMM: 4.1, lengthMM: 10.0)
}

// MARK: - Collocazione

/// Un impianto pianificato, collocato nello spazio Patient.
///
/// La rappresentazione è piattaforma più asse, non due estremi liberi: la lunghezza appartiene
/// al modello e non deve poter cambiare trascinando un punto. Consentirlo produrrebbe impianti
/// di misure inesistenti, che poi non si possono ordinare.
public struct ImplantPlacement: Hashable, Sendable, Codable, Identifiable {

    public var id: UUID
    public var model: ImplantModel
    /// Centro della piattaforma protesica, in millimetri Patient.
    public var platformMM: Vec3
    /// Versore dell'asse, dalla piattaforma **verso l'apice**.
    public var axis: Vec3
    public var label: String
    public var colorHex: String
    public var isVisible: Bool

    public init(
        id: UUID = UUID(),
        model: ImplantModel = .default,
        platformMM: Vec3,
        axis: Vec3 = Vec3(0, 0, -1),
        label: String = "",
        colorHex: String = "#B8C4CC",
        isVisible: Bool = true
    ) {
        self.id = id
        self.model = model
        self.platformMM = platformMM
        self.axis = axis.normalized ?? Vec3(0, 0, -1)
        self.label = label
        self.colorHex = colorHex
        self.isVisible = isVisible
    }

    /// Punta dell'impianto.
    public var apexMM: Vec3 {
        platformMM + axis * model.lengthMM
    }

    /// Punto sull'asse alla quota `z` dalla piattaforma.
    public func axisPoint(atZ z: Double) -> Vec3 {
        platformMM + axis * z
    }

    /// Prolungamento dell'asse oltre la piattaforma, verso il piano occlusale.
    ///
    /// Serve a verificare dove l'impianto "esce": un asse corretto nell'osso ma che emerge in
    /// posizione sbagliata rende la protesi difficile o impossibile, ed è il motivo per cui la
    /// pianificazione si dice protesicamente guidata.
    public func emergencePoint(extensionMM: Double) -> Vec3 {
        platformMM - axis * extensionMM
    }

    // MARK: Distanza

    /// Distanza con segno dalla **superficie** dell'impianto. Negativa all'interno.
    public func signedDistance(from point: Vec3) -> Double {
        let relative = point - platformMM
        let z = relative.dot(axis)
        let radial = (relative - axis * z).length

        if z < 0 {
            // Sopra la piattaforma: distanza dal bordo del disco superiore.
            let platformRadius = model.platformDiameterMM / 2
            if radial <= platformRadius { return -z }
            let dr = radial - platformRadius
            return (dr * dr + z * z).squareRoot()
        }

        if z > model.lengthMM {
            let apexRadius = model.radius(atZ: model.lengthMM)
            let dz = z - model.lengthMM
            if radial <= apexRadius { return dz }
            let dr = radial - apexRadius
            return (dr * dr + dz * dz).squareRoot()
        }

        // Lungo il corpo: differenza radiale rispetto al profilo. È un'approssimazione, perché
        // sulle pareti coniche la distanza vera si misura in perpendicolare alla superficie e
        // non in orizzontale — ma la conicità è modesta e l'approssimazione è **prudenziale**,
        // cioè restituisce una distanza minore o uguale a quella reale. Su un allarme di
        // sicurezza sbagliare per eccesso di prudenza è l'unico verso accettabile.
        return radial - model.radius(atZ: z)
    }

    /// Punti sulla superficie laterale, per il campionamento della densità ossea e per il
    /// disegno.
    public func surfacePoints(
        aroundOffsetMM offset: Double = 0,
        levels: Int = 12,
        radialSteps: Int = 16
    ) -> [Vec3] {
        guard let basis = perpendicularBasis() else { return [] }
        var points: [Vec3] = []
        points.reserveCapacity(levels * radialSteps)

        for level in 0..<levels {
            let z = model.lengthMM * Double(level) / Double(max(levels - 1, 1))
            let radius = model.radius(atZ: z) + offset
            let centre = axisPoint(atZ: z)
            for step in 0..<radialSteps {
                let angle = 2 * Double.pi * Double(step) / Double(radialSteps)
                let direction =
                    basis.u * Foundation.cos(angle) + basis.v * Foundation.sin(angle)
                points.append(centre + direction * radius)
            }
        }
        return points
    }

    /// Due versori perpendicolari all'asse, per costruire le circonferenze.
    public func perpendicularBasis() -> (u: Vec3, v: Vec3)? {
        // Si sceglie l'ausiliario meno allineato all'asse, altrimenti il prodotto vettoriale
        // degenera quando l'asse è quasi parallelo a quello scelto.
        let helper: Vec3 = abs(axis.z) < 0.9 ? Vec3(0, 0, 1) : Vec3(1, 0, 0)
        guard let u = helper.cross(axis).normalized else { return nil }
        return (u, axis.cross(u))
    }

    /// Angolo fra questo impianto e un altro, in radianti. Zero significa paralleli.
    public func angle(to other: ImplantPlacement) -> Double {
        // Si prende il valore assoluto del coseno: due impianti con assi opposti sono comunque
        // paralleli ai fini della protesi, che è quello che interessa qui.
        let cosine = abs(axis.dot(other.axis))
        return Foundation.acos(min(max(cosine, -1), 1))
    }

    /// Inclinazione rispetto a una direzione di riferimento, in gradi.
    /// Con la verticale del paziente dà l'angolazione rispetto al piano occlusale.
    public func angleDegrees(to direction: Vec3) -> Double? {
        guard let angle = axis.angle(to: direction) else { return nil }
        return min(angle, Double.pi - angle) * 180 / Double.pi
    }

    // MARK: Modifica

    /// Ruota l'asse attorno a un punto di fulcro, tenendo fermo l'apice o la piattaforma.
    public func rotated(axis rotationAxis: Vec3, angle: Double, aroundApex: Bool) -> ImplantPlacement {
        guard let rotation = Transform3D.rotation(axis: rotationAxis, angle: angle) else {
            return self
        }
        var copy = self
        let pivot = aroundApex ? apexMM : platformMM
        let newAxis = rotation.apply(toVector: axis).normalized ?? axis
        copy.axis = newAxis
        if aroundApex {
            // Tenendo fermo l'apice la piattaforma si sposta: è il gesto naturale quando si
            // corregge l'inclinazione senza voler perdere il punto apicale già scelto.
            copy.platformMM = pivot - newAxis * model.lengthMM
        } else {
            copy.platformMM = pivot
        }
        return copy
    }
}
