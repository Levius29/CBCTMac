import DICOMCore
import Foundation

// Transfer function: da valore di densità a colore e opacità.
//
// È il controllo che realizza il «rendering dei tessuti variabile». Non è un filtro applicato
// a un'immagine già formata: decide, per ogni campione lungo il raggio, quanto contribuisce e
// di che colore. Alzare l'opacità sotto i 500 GV fa comparire i tessuti molli; azzerarla sopra
// i 200 lascia solo osso e smalto.
//
// Il file non dipende da Metal, così le funzioni si testano senza GPU e i preset restano
// serializzabili dentro un `.cbctplan`.

// MARK: - Colore

/// Colore lineare, componenti in [0, 1].
///
/// Tipo proprio invece di `Color` di SwiftUI: VolumeKit non deve dipendere dall'interfaccia, e
/// questi valori vanno in un buffer GPU, non in una vista.
public struct TransferColor: Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(_ red: Double, _ green: Double, _ blue: Double) {
        self.red = min(max(red, 0), 1)
        self.green = min(max(green, 0), 1)
        self.blue = min(max(blue, 0), 1)
    }

    public func lerp(to other: TransferColor, t: Double) -> TransferColor {
        TransferColor(
            red + (other.red - red) * t,
            green + (other.green - green) * t,
            blue + (other.blue - blue) * t)
    }

    // Tinte scelte per somigliare ai tessuti reali, non per essere vivaci: un osso verde
    // acido si legge peggio, e in una discussione con il paziente sembra un videogioco.
    public static let bone = TransferColor(0.93, 0.88, 0.78)
    public static let enamel = TransferColor(1.0, 0.98, 0.94)
    public static let dentin = TransferColor(0.90, 0.82, 0.68)
    public static let softTissue = TransferColor(0.85, 0.55, 0.48)
    public static let skin = TransferColor(0.92, 0.72, 0.62)
    public static let air = TransferColor(0.20, 0.35, 0.55)
}

// MARK: - Punto di controllo

/// Un punto della rampa: a questa densità corrispondono questo colore e questa opacità.
public struct TransferStop: Hashable, Sendable, Codable, Identifiable {
    public var id: UUID
    /// Valore di densità, nell'unità del volume. Su CBCT è un valore grigio, non HU.
    public var density: Double
    public var opacity: Double
    public var color: TransferColor

    public init(
        id: UUID = UUID(), density: Double, opacity: Double, color: TransferColor
    ) {
        self.id = id
        self.density = density
        self.opacity = min(max(opacity, 0), 1)
        self.color = color
    }
}

// MARK: - Transfer function

public struct TransferFunction: Hashable, Sendable, Codable {

    /// Punti di controllo. Non è garantito che siano ordinati: ci pensa `bake`.
    public var stops: [TransferStop]

    /// Moltiplicatore globale dell'opacità, comandato dal cursore «Soglia» dell'ispettore.
    /// Consente di alleggerire o addensare tutto senza rimaneggiare i singoli punti.
    public var opacityScale: Double

    public init(stops: [TransferStop], opacityScale: Double = 1.0) {
        self.stops = stops
        self.opacityScale = max(0, opacityScale)
    }

    // MARK: Campionamento

    /// Colore e opacità a una densità, per interpolazione lineare fra i punti adiacenti.
    /// Fuori dagli estremi si tiene il valore del punto più vicino, senza estrapolare.
    public func sample(at density: Double) -> (color: TransferColor, opacity: Double) {
        let sorted = stops.sorted { $0.density < $1.density }
        guard let first = sorted.first else {
            return (TransferColor(0, 0, 0), 0)
        }
        guard let last = sorted.last else {
            return (first.color, first.opacity)
        }
        if density <= first.density { return (first.color, first.opacity) }
        if density >= last.density { return (last.color, last.opacity) }

        for index in 0..<(sorted.count - 1) {
            let lower = sorted[index]
            let upper = sorted[index + 1]
            guard density >= lower.density, density <= upper.density else { continue }
            let span = upper.density - lower.density
            let t = span > 0 ? (density - lower.density) / span : 0
            return (
                lower.color.lerp(to: upper.color, t: t),
                lower.opacity + (upper.opacity - lower.opacity) * t
            )
        }
        return (last.color, last.opacity)
    }

    /// Cuoce la rampa in una tabella RGBA pronta per la GPU.
    ///
    /// Il colore è **premoltiplicato per l'opacità**, come richiede la composizione
    /// front-to-back del raycaster. Farlo qui, una volta per tabella, evita una moltiplicazione
    /// per ogni campione di ogni raggio — e sono milioni per fotogramma.
    ///
    /// - Parameters:
    ///   - entryCount: voci della tabella. 512 è abbondante: la rampa è liscia per costruzione
    ///     e l'occhio non distingue oltre.
    ///   - densityRange: intervallo di densità su cui si distribuisce la tabella. Deve essere lo
    ///     stesso che il raycaster usa per normalizzare, altrimenti i colori scivolano.
    public func bake(entryCount: Int = 512, densityRange: ClosedRange<Double>) -> [Float] {
        let count = max(2, entryCount)
        var table = [Float](repeating: 0, count: count * 4)

        let low = densityRange.lowerBound
        let span = densityRange.upperBound - low
        guard span > 0 else { return table }

        for index in 0..<count {
            let density = low + span * (Double(index) / Double(count - 1))
            let (color, opacity) = sample(at: density)
            let alpha = min(max(opacity * opacityScale, 0), 1)

            table[index * 4 + 0] = Float(color.red * alpha)
            table[index * 4 + 1] = Float(color.green * alpha)
            table[index * 4 + 2] = Float(color.blue * alpha)
            table[index * 4 + 3] = Float(alpha)
        }
        return table
    }

    // MARK: Preset

    /// Osso: opacità nulla sotto la spongiosa, salita ripida sulla corticale.
    /// È il punto di partenza abituale su una CBCT dentale.
    public static let bone = TransferFunction(stops: [
        TransferStop(density: -1000, opacity: 0.00, color: .air),
        TransferStop(density: 150, opacity: 0.00, color: .bone),
        TransferStop(density: 400, opacity: 0.12, color: .bone),
        TransferStop(density: 900, opacity: 0.55, color: .bone),
        TransferStop(density: 1600, opacity: 0.90, color: .enamel),
        TransferStop(density: 3000, opacity: 1.00, color: .enamel),
    ])

    /// Denti: si apre solo sui valori dello smalto e della dentina, lasciando sparire l'osso.
    public static let teeth = TransferFunction(stops: [
        TransferStop(density: -1000, opacity: 0.00, color: .air),
        TransferStop(density: 900, opacity: 0.00, color: .dentin),
        TransferStop(density: 1300, opacity: 0.20, color: .dentin),
        TransferStop(density: 2000, opacity: 0.80, color: .enamel),
        TransferStop(density: 3200, opacity: 1.00, color: .enamel),
    ])

    /// Tessuti molli con osso in trasparenza dietro.
    public static let softTissue = TransferFunction(stops: [
        TransferStop(density: -1000, opacity: 0.00, color: .air),
        TransferStop(density: -300, opacity: 0.00, color: .softTissue),
        TransferStop(density: -50, opacity: 0.10, color: .softTissue),
        TransferStop(density: 200, opacity: 0.25, color: .softTissue),
        TransferStop(density: 800, opacity: 0.50, color: .bone),
        TransferStop(density: 2000, opacity: 0.85, color: .enamel),
    ])

    /// Pelle: una superficie sola, all'interfaccia con l'aria.
    public static let skin = TransferFunction(stops: [
        TransferStop(density: -1000, opacity: 0.00, color: .air),
        TransferStop(density: -400, opacity: 0.00, color: .skin),
        TransferStop(density: -200, opacity: 0.85, color: .skin),
        TransferStop(density: 100, opacity: 0.90, color: .skin),
        TransferStop(density: 3000, opacity: 0.95, color: .skin),
    ])

    /// Vie aeree: si rende visibile **l'aria**, non il tessuto. Serve per faringe e seni,
    /// e la rampa è quindi rovesciata rispetto a tutte le altre.
    public static let airway = TransferFunction(stops: [
        TransferStop(density: -1100, opacity: 0.00, color: .air),
        TransferStop(density: -950, opacity: 0.55, color: .air),
        TransferStop(density: -600, opacity: 0.25, color: .air),
        TransferStop(density: -400, opacity: 0.00, color: .air),
        TransferStop(density: 3000, opacity: 0.00, color: .bone),
    ])

    public static let presets: [(name: String, value: TransferFunction)] = [
        ("Osso", .bone),
        ("Denti", .teeth),
        ("Tessuti molli", .softTissue),
        ("Pelle", .skin),
        ("Vie aeree", .airway),
    ]
}

// MARK: - Camera

/// Camera in orbita attorno al volume, con proiezione **ortografica**.
///
/// L'ortografica non è una semplificazione per pigrizia: in ambito medico è la proiezione
/// corretta. Con la prospettiva due strutture della stessa dimensione appaiono diverse a
/// seconda della distanza, e su un'immagine da cui si prendono misure è un difetto, non un
/// effetto. Rende anche il raggio uguale per ogni pixel, quindi il kernel resta economico.
public struct VolumeCamera: Hashable, Sendable {

    /// Rotazione attorno all'asse verticale del paziente, in radianti.
    public var azimuth: Double
    /// Elevazione sopra il piano assiale, in radianti, limitata per non ribaltare la vista.
    public var elevation: Double
    /// Semi-altezza dell'inquadratura in millimetri: è lo zoom.
    public var halfHeightMM: Double
    /// Punto verso cui la camera guarda, in millimetri Patient.
    public var targetMM: Vec3

    public init(
        azimuth: Double = 0,
        elevation: Double = 0,
        halfHeightMM: Double = 100,
        targetMM: Vec3 = .zero
    ) {
        self.azimuth = azimuth
        self.elevation = min(max(elevation, -1.5), 1.5)
        self.halfHeightMM = max(halfHeightMM, 1)
        self.targetMM = targetMM
    }

    /// Direzione di vista, dalla camera verso il bersaglio, in coordinate Patient.
    ///
    /// A rotazione ed elevazione nulle si guarda il paziente **da davanti**: la camera sta
    /// sull'anteriore e guarda verso il posteriore, cioè verso `+P`.
    public var forward: Vec3 {
        let ce = Foundation.cos(elevation)
        return Vec3(
            -Foundation.sin(azimuth) * ce,
            Foundation.cos(azimuth) * ce,
            -Foundation.sin(elevation)
        ).normalized ?? Vec3(0, 1, 0)
    }

    /// Destra dello schermo, in coordinate Patient.
    public var right: Vec3 {
        // Il riferimento verticale è l'asse cranio-caudale del paziente. Sopra l'elevazione
        // limite i due diventerebbero paralleli e il prodotto vettoriale degenererebbe: il
        // limite di ±1,5 rad nell'inizializzatore serve esattamente a questo.
        forward.cross(Vec3(0, 0, 1)).normalized ?? Vec3(1, 0, 0)
    }

    /// Basso dello schermo, in coordinate Patient.
    public var down: Vec3 {
        forward.cross(right).normalized ?? Vec3(0, 0, -1)
    }

    /// Inquadratura che contiene tutto il volume, vista da davanti.
    public static func fitted(to geometry: VolumeGeometry, marginFraction: Double = 0.08)
        -> VolumeCamera
    {
        let centre = geometry.centerMM
        var radius = 0.0
        for corner in geometry.boundingBoxCornersMM {
            radius = max(radius, corner.distance(to: centre))
        }
        return VolumeCamera(
            azimuth: 0,
            elevation: 0,
            halfHeightMM: max(radius * (1 + marginFraction), 1),
            targetMM: centre)
    }

    /// Vista frontale, laterale e dall'alto: i tre pulsanti dell'ispettore.
    public func facingAnterior() -> VolumeCamera {
        var copy = self
        copy.azimuth = 0
        copy.elevation = 0
        return copy
    }

    public func facingLateral() -> VolumeCamera {
        var copy = self
        copy.azimuth = Double.pi / 2
        copy.elevation = 0
        return copy
    }

    public func facingSuperior() -> VolumeCamera {
        var copy = self
        copy.azimuth = 0
        copy.elevation = 1.5
        return copy
    }

    public func orbited(deltaAzimuth: Double, deltaElevation: Double) -> VolumeCamera {
        VolumeCamera(
            azimuth: azimuth + deltaAzimuth,
            elevation: elevation + deltaElevation,
            halfHeightMM: halfHeightMM,
            targetMM: targetMM)
    }

    public func zoomed(by factor: Double) -> VolumeCamera {
        guard factor > 0 else { return self }
        var copy = self
        copy.halfHeightMM = max(halfHeightMM / factor, 1)
        return copy
    }
}

// MARK: - Qualità

/// Compromesso fra passo di campionamento e fluidità.
public enum RenderQuality: String, CaseIterable, Hashable, Sendable, Codable {
    case interactive
    case standard
    case high

    /// Passo lungo il raggio, in frazioni di voxel.
    ///
    /// Sotto mezzo voxel non si guadagna informazione, perché fra due voxel adiacenti non ce
    /// n'è: si spende soltanto tempo. Sopra il voxel intero si perdono le strutture sottili, e
    /// su una corticale da 0,5 mm significa non vederla.
    public var stepInVoxels: Double {
        switch self {
        case .interactive: return 1.5
        case .standard: return 0.75
        case .high: return 0.5
        }
    }

    /// Divisore della risoluzione. Durante la rotazione si rende a risoluzione ridotta e si
    /// raffina al rilascio: l'occhio non coglie il dettaglio su un'immagine in movimento.
    public var resolutionDivisor: Int {
        switch self {
        case .interactive: return 2
        case .standard: return 1
        case .high: return 1
        }
    }

    public var localizedName: String {
        switch self {
        case .interactive: return "Rapida"
        case .standard: return "Normale"
        case .high: return "Alta"
        }
    }
}
