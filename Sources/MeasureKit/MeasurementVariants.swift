import DICOMCore
import Foundation

// Varianti di misura.
//
// Il righello a due punti e il goniometro a tre bastano finché si misura una distanza fra due
// punti. Non bastano appena si misura qualcosa di reale: la lunghezza di una cresta non è un
// segmento, e l'angolo fra due impianti non ha un vertice comune da cliccare.

// MARK: - Spezzata

/// Spezzata: somma dei segmenti. Chiusa, misura anche l'area del poligono.
public struct PolylineMeasurement: Hashable, Sendable, Codable, Identifiable {

    public var metadata: AnnotationMetadata
    public var pointsMM: [Vec3]
    public var isClosed: Bool

    public var id: UUID { metadata.id }

    /// Tolleranza di complanarità: quanto un punto può scostarsi dal piano medio perché l'area
    /// resti definita. Un decimo di millimetro è sotto la spaziatura di qualunque CBCT dentale,
    /// quindi un poligono tracciato su una fetta lo rispetta sempre e uno tracciato a mano libera
    /// nello spazio no.
    public static let coplanarityToleranceMM = 0.1

    public init(
        metadata: AnnotationMetadata = AnnotationMetadata(),
        pointsMM: [Vec3],
        isClosed: Bool = false
    ) {
        self.metadata = metadata
        self.pointsMM = pointsMM
        self.isClosed = isClosed
    }

    public var lengthMM: Double {
        guard pointsMM.count >= 2 else { return 0 }
        var total = 0.0
        for index in 1..<pointsMM.count {
            total += pointsMM[index].distance(to: pointsMM[index - 1])
        }
        if isClosed, let first = pointsMM.first, let last = pointsMM.last {
            total += last.distance(to: first)
        }
        return total
    }

    /// Area in mm², solo se chiusa e **complanare**.
    ///
    /// La complanarità non è pignoleria. Tre punti sono sempre complanari, quattro quasi mai: la
    /// formula del laccio di scarpe vale nel piano, e applicarla a punti sghembi restituisce un
    /// numero che *sembra* un'area e non lo è. Meglio `nil`: un valore mancante si nota, un valore
    /// plausibile e falso finisce in una relazione.
    ///
    /// Si misura contro il piano ai minimi quadrati dei punti, non contro il piano dei primi tre:
    /// quello dipenderebbe da quali punti l'utente ha cliccato per primi.
    public var areaMM2: Double? {
        guard isClosed, pointsMM.count >= 3 else { return nil }
        guard let normal = bestFitNormal else { return nil }

        let centroid = pointsMM.reduce(Vec3.zero, +) / Double(pointsMM.count)
        for point in pointsMM
        where abs((point - centroid).dot(normal)) > Self.coplanarityToleranceMM {
            return nil
        }

        // Area vettoriale: metà del modulo della somma dei prodotti vettoriali dei lati attorno
        // al centroide. Vale in tre dimensioni senza scegliere un sistema di riferimento nel
        // piano, quindi non dipende da come il poligono è orientato nello spazio.
        var doubled = Vec3.zero
        for index in pointsMM.indices {
            let a = pointsMM[index] - centroid
            let b = pointsMM[(index + 1) % pointsMM.count] - centroid
            doubled += a.cross(b)
        }
        return doubled.length * 0.5
    }

    /// Normale del piano ai minimi quadrati, o `nil` se i punti sono allineati.
    ///
    /// Si ricava dalla somma dei prodotti vettoriali — la stessa quantità dell'area vettoriale —
    /// che per un poligono piano è esattamente due volte l'area per la normale. Su punti quasi
    /// allineati si annulla, ed è giusto che l'area non sia definita.
    private var bestFitNormal: Vec3? {
        let centroid = pointsMM.reduce(Vec3.zero, +) / Double(pointsMM.count)
        var accumulated = Vec3.zero
        for index in pointsMM.indices {
            let a = pointsMM[index] - centroid
            let b = pointsMM[(index + 1) % pointsMM.count] - centroid
            accumulated += a.cross(b)
        }
        return accumulated.normalized
    }

    public var formattedLength: String {
        String(format: "%.2f mm", lengthMM).replacingOccurrences(of: ".", with: ",")
    }

    public var formattedArea: String? {
        guard let areaMM2 else { return nil }
        return String(format: "%.1f mm²", areaMM2).replacingOccurrences(of: ".", with: ",")
    }
}

// MARK: - Angolo fra due rette

/// Angolo fra due rette definite da due punti ciascuna, invece che da un vertice comune.
///
/// È la misura che serve fra due impianti, fra un impianto e il piano occlusale, fra il ramo e il
/// corpo mandibolare: casi in cui le due direzioni non si incontrano in un punto che si possa
/// cliccare, e a volte non si incontrano affatto.
public struct LineAngleMeasurement: Hashable, Sendable, Codable, Identifiable {

    public var metadata: AnnotationMetadata
    public var firstStartMM: Vec3
    public var firstEndMM: Vec3
    public var secondStartMM: Vec3
    public var secondEndMM: Vec3

    public var id: UUID { metadata.id }

    public init(
        metadata: AnnotationMetadata = AnnotationMetadata(),
        firstStartMM: Vec3,
        firstEndMM: Vec3,
        secondStartMM: Vec3,
        secondEndMM: Vec3
    ) {
        self.metadata = metadata
        self.firstStartMM = firstStartMM
        self.firstEndMM = firstEndMM
        self.secondStartMM = secondStartMM
        self.secondEndMM = secondEndMM
    }

    public var firstDirection: Vec3? { (firstEndMM - firstStartMM).normalized }
    public var secondDirection: Vec3? { (secondEndMM - secondStartMM).normalized }

    /// Angolo **acuto** fra le due direzioni, in gradi, in `0...90`.
    ///
    /// Sempre l'acuto, ed è una scelta da dichiarare invece di lasciarla implicita. Due rette
    /// formano due angoli supplementari, e quale dei due esca dal calcolo dipende dal verso in cui
    /// l'utente ha tracciato i segmenti — cioè da nulla di clinicamente significativo. Tracciando
    /// lo stesso angolo due volte, una da sinistra e una da destra, si otterrebbero 30° e 150° e
    /// si penserebbe a un difetto. Il valore assoluto del coseno rende la misura riproducibile.
    public var acuteDegrees: Double {
        guard let a = firstDirection, let b = secondDirection else { return 0 }
        let cosine = min(max(abs(a.dot(b)), 0), 1)
        return Foundation.acos(cosine) * 180 / .pi
    }

    /// Distanza minima fra le due rette. Zero se si intersecano.
    ///
    /// La formula chiusa per rette sghembe degenera quando sono parallele: il prodotto vettoriale
    /// delle direzioni si annulla e la divisione esplode. Il caso parallelo si tratta a parte,
    /// come distanza punto-retta, che è la risposta giusta lì.
    public var minimumDistanceMM: Double {
        guard let a = firstDirection, let b = secondDirection else {
            return firstStartMM.distance(to: secondStartMM)
        }
        let between = secondStartMM - firstStartMM
        let cross = a.cross(b)

        if cross.length < 1e-9 {
            // Parallele: la distanza è la componente di `between` perpendicolare alla direzione.
            let along = between.dot(a)
            return (between - a * along).length
        }
        return abs(between.dot(cross)) / cross.length
    }

    /// Vero quando le due rette si incontrano, entro la tolleranza.
    public var isIntersecting: Bool { minimumDistanceMM < 1e-9 }

    public var formattedAngle: String {
        String(format: "%.1f°", acuteDegrees).replacingOccurrences(of: ".", with: ",")
    }
}
