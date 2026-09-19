import DICOMCore
import Foundation
import SegmentKit

// La registrazione fra due esami dello stesso paziente presi in date diverse.
//
// # A che serve, in una riga
//
// A rispondere alla domanda che nessuna vista singola risponde: *questo è cambiato, o l'ho solo
// guardato da un'altra angolazione?* Un rialzo di seno a sei mesi, l'osso attorno a un impianto a
// un anno, una lesione periapicale dopo la terapia: senza allineamento si confrontano due teste
// posate diversamente sul poggiamento, e ogni differenza di posa somiglia a una differenza
// clinica.
//
// # Perché non riusiamo l'ICP di MeshKit
//
// Perché l'ICP registra **superfici**, e per averne una servirebbe segmentare l'osso in entrambi
// gli esami: una soglia in più fra il dato e il risultato, per giunta scelta a mano, che sposta
// la superficie di mezzo millimetro a ogni cambio. Qui si registrano direttamente i volumi, cioè
// il dato com'è. Nessuna soglia, nessun repere da posare, nessuna segmentazione.
//
// I due meccanismi restano distinti e complementari: `ScanRegistration` porta una scansione
// intraorale sulla CBCT, e ha il suo scarto misurato sulle superfici; questo porta una CBCT su
// un'altra CBCT. Il primo ha punti corrispondenti perché la scansione è un altro mondo; il
// secondo non ne ha bisogno, perché i due mondi sono lo stesso apparecchio a distanza di mesi.
//
// # Che cosa questa registrazione **non** promette
//
// È **rigida**: sei parametri, tre rotazioni e tre traslazioni. Il cranio è un corpo rigido e
// due esami lo ritraggono uguale, quindi per il massiccio facciale è il modello giusto, ed è
// l'unico che non possa deformare via una differenza vera — il che è precisamente il rischio da
// evitare, dato che le differenze vere sono l'oggetto dell'esame.
//
// **La mandibola non è parte di quel corpo rigido.** Fra un esame e l'altro si apre, si chiude e
// scivola. Una registrazione unica per tutta la testa allinea bene il massiccio e male la
// mandibola, o viceversa, a seconda di dove cadono i campioni — e non lo dice. È la ragione per
// cui `RegistrationSettings.regionMM` esiste e per cui merita di essere usata: si registra la
// mandibola sulla mandibola, e il massiccio sul massiccio, con due pose distinte. OpenMRI, da cui
// viene l'idea del confronto nel tempo, non ha questo problema perché guarda teste in risonanza;
// noi guardiamo arcate, e da noi è la differenza fra un confronto e un artefatto.

/// Come condurre la registrazione. I valori predefiniti sono quelli buoni per due CBCT dentali.
public struct RegistrationSettings: Hashable, Sendable {

    /// Quale somiglianza si massimizza.
    public var metric: RegistrationMetricKind
    /// Riduzioni successive, dal grossolano al fine.
    public var shrinkFactors: [Int]
    /// Campioni estratti a ogni livello.
    public var samplesPerLevel: Int
    /// Tetto ai passi di discesa per livello.
    public var maximumIterationsPerLevel: Int
    /// Lunghezza del primo passo, in millimetri.
    public var initialStepMM: Double
    /// Sotto questo passo la discesa si dichiara arrivata.
    public var minimumStepMM: Double
    /// Di quanto si accorcia il passo quando la discesa inverte la direzione.
    public var relaxationFactor: Double
    /// Seme del generatore dei campioni: due esecuzioni sugli stessi esami danno lo stesso esito.
    public var seed: UInt64
    /// La parte di anatomia su cui registrare. `nil` significa tutto il volume.
    ///
    /// Su una CBCT dentale non è un raffinamento: mandibola e massiccio facciale sono **due**
    /// corpi rigidi, e una posa sola non può allinearli entrambi.
    public var regionMM: BoxMM?

    public init(
        metric: RegistrationMetricKind = .mutualInformation,
        shrinkFactors: [Int] = VolumePyramid.defaultShrinkFactors,
        samplesPerLevel: Int = 12_000,
        maximumIterationsPerLevel: Int = 120,
        initialStepMM: Double = 4.0,
        minimumStepMM: Double = 0.05,
        relaxationFactor: Double = 0.5,
        seed: UInt64 = 42,
        regionMM: BoxMM? = nil
    ) {
        self.metric = metric
        self.shrinkFactors = shrinkFactors
        self.samplesPerLevel = samplesPerLevel
        self.maximumIterationsPerLevel = maximumIterationsPerLevel
        self.initialStepMM = initialStepMM
        self.minimumStepMM = minimumStepMM
        self.relaxationFactor = relaxationFactor
        self.seed = seed
        self.regionMM = regionMM
    }
}

/// A che punto è la registrazione, per chi la guarda mentre gira.
public struct RegistrationProgress: Hashable, Sendable {
    /// Che cosa sta facendo, in una riga da mostrare.
    public let stage: String
    /// Frazione fatta, fra `0` e `1`. È una stima sui livelli, non una promessa sul tempo.
    public let fraction: Double

    public init(stage: String, fraction: Double) {
        self.stage = stage
        self.fraction = fraction
    }
}

/// Com'è andata una registrazione fra due esami, con tutto ciò che serve a giudicarla.
public struct VolumeRegistrationOutcome: Hashable, Sendable, Codable {

    /// La posa trovata: riferimento → confronto.
    public let pose: RigidPose
    /// Quale metrica l'ha guidata.
    public let metric: RegistrationMetricKind
    /// Valore finale del costo. Serve a confrontare due tentativi sulla **stessa** coppia di
    /// esami, non a giudicare una registrazione in assoluto: non è una distanza in millimetri.
    public let metricValue: Double
    /// Frazione della griglia del riferimento che ha davvero un dato sotto, nell'esame di confronto.
    ///
    /// **Descrive il campo acquisito, non l'accuratezza.** Due esami possono sovrapporsi per
    /// intero ed essere allineati male; un esame a FOV piccolo dentro uno a FOV grande dà una
    /// copertura bassa ed è perfettamente allineato. È la ragione per cui qui non c'è nessuna
    /// soglia di copertura che dichiari «riuscito».
    public let coverage: Double
    /// Passi di discesa spesi, su tutti i livelli.
    public let iterations: Int
    /// Vero se la discesa si è fermata da sé, falso se ha esaurito i passi concessi.
    public let converged: Bool
    /// Il massimo spostamento imposto ai vertici del volume di riferimento, in millimetri.
    public let maximumDisplacementMM: Double

    public init(
        pose: RigidPose,
        metric: RegistrationMetricKind,
        metricValue: Double,
        coverage: Double,
        iterations: Int,
        converged: Bool,
        maximumDisplacementMM: Double
    ) {
        self.pose = pose
        self.metric = metric
        self.metricValue = metricValue
        self.coverage = coverage
        self.iterations = iterations
        self.converged = converged
        self.maximumDisplacementMM = maximumDisplacementMM
    }

    /// La matrice da dare a chi ricampiona o a chi porta un punto da un esame all'altro.
    public var referenceToFollowUp: Transform3D { pose.transform }

    /// Rotazione complessiva, in gradi: l'angolo della rotazione equivalente attorno a un asse solo.
    ///
    /// I tre angoli di Eulero presi singolarmente non dicono quanto la testa abbia ruotato — due
    /// rotazioni di venti gradi possono comporne una di cinque. Questo lo dice.
    public var rotationDegrees: Double {
        let r = pose.rotation
        let trace = r.columnX.x + r.columnY.y + r.columnZ.z
        let cosine = Swift.min(Swift.max((trace - 1) * 0.5, -1), 1)
        return Foundation.acos(cosine) * 180 / Double.pi
    }
}

/// Perché una registrazione non si può nemmeno tentare.
public enum VolumeRegistrationError: Error, Hashable, Sendable, LocalizedError {
    case invalidShrinkFactor(Int)
    case volumeTooSmall(minimumVoxelsPerAxis: Int)
    case constantVolume
    case regionTooSmall(samples: Int)
    case noOverlap(coverage: Double)

    public var errorDescription: String? {
        switch self {
        case .invalidShrinkFactor(let factor):
            return "La riduzione \(factor) non è un fattore valido: serve un intero positivo."
        case .volumeTooSmall(let minimum):
            return
                "La registrazione richiede almeno \(minimum) voxel per asse in entrambi gli esami."
        case .constantVolume:
            return "Uno dei due esami ha un solo valore in tutto il volume: non c'è niente da allineare."
        case .regionTooSmall(let samples):
            return
                "La regione scelta raccoglie solo \(samples) campioni: allargala o toglila del tutto."
        case .noOverlap(let coverage):
            return String(
                format:
                    "I due esami non si sovrappongono (%.1f%% del riferimento): controlla che siano dello stesso paziente e della stessa regione.",
                coverage * 100)
        }
    }
}

/// Allinea due esami dello stesso paziente presi in date diverse.
// non-ancora-collegato: il modulo è verificato, la schermata del confronto nel tempo non c'è
// ancora. Vedi docs/follow-up.md e la fase 7 nel README.
public enum VolumeRegistration: Sendable {

    /// Voxel minimi per asse. Sotto, la piramide non ha su cosa costruirsi e la registrazione
    /// diventa un esercizio su quattro voxel.
    public static let minimumVoxelsPerAxis = 12

    /// Sotto questa copertura i due esami non si toccano abbastanza perché la posa significhi
    /// qualcosa.
    ///
    /// È molto più bassa del quarto che usa OpenMRI, e di proposito: là si confrontano teste
    /// intere in risonanza, qui una CBCT a campo piccolo di un solo settore può stare legittimamente
    /// dentro un esame a campo grande e coprirne il cinque per cento. Rifiutarla sarebbe rifiutare
    /// il caso più utile che c'è — il controllo mirato su un impianto.
    public static let minimumCoverage = 0.02

    /// Registra `followUp` sul volume di riferimento e restituisce la posa trovata.
    ///
    /// Il volume di riferimento non viene toccato: è il ricampionamento, semmai, a produrre un
    /// volume nuovo — vedi `FollowUpResampler`. Qui si calcola soltanto la posa, perché una posa
    /// costa sei numeri e un volume ricampionato mezzo gigabyte, e chi vuole solo portare un
    /// punto da un esame all'altro non deve pagare il secondo.
    public static func align(
        followUp: Volume,
        to reference: Volume,
        settings: RegistrationSettings = RegistrationSettings(),
        progress: (@Sendable (RegistrationProgress) -> Void)? = nil
    ) throws -> VolumeRegistrationOutcome {

        let factors = try VolumePyramid.orderedFactors(settings.shrinkFactors)
        try validate(reference)
        try validate(followUp)

        let centerMM = settings.regionMM?.centerMM ?? reference.geometry.centerMM
        let radiusMM = rotationRadiusMM(of: reference.geometry, regionMM: settings.regionMM)

        var pose = RigidPose(centerMM: centerMM)
        var cost = Double.infinity
        var iterations = 0
        var converged = false
        var step = settings.initialStepMM

        for (index, factor) in factors.enumerated() {
            progress?(
                RegistrationProgress(
                    stage: "Allineamento, livello \(index + 1) di \(factors.count)",
                    fraction: Double(index) / Double(factors.count)
                ))

            let referenceLevel = try VolumePyramid.reduced(reference, by: factor)
            let followUpLevel = try VolumePyramid.reduced(followUp, by: factor)
            let function = try RegistrationCostFunction(
                kind: settings.metric,
                reference: referenceLevel,
                followUp: followUpLevel,
                sampleCount: settings.samplesPerLevel,
                regionMM: settings.regionMM,
                seed: settings.seed &+ UInt64(index)
            )

            let level = descend(
                from: pose,
                using: function,
                radiusMM: radiusMM,
                step: step,
                settings: settings
            )
            pose = level.pose
            cost = level.cost
            iterations += level.iterations
            converged = level.converged
            // Il livello successivo ha voxel grandi la metà: partire con il passo di prima
            // significherebbe rifare da capo la ricerca grossolana che si è appena conclusa.
            step = Swift.max(settings.minimumStepMM, step * 0.5)
        }

        let coverage = Self.coverage(of: followUp, over: reference.geometry, pose: pose)
        guard coverage >= minimumCoverage else {
            throw VolumeRegistrationError.noOverlap(coverage: coverage)
        }

        let displacement =
            reference.geometry.boundingBoxCornersMM
            .map { pose.displacementMM(atPoint: $0) }
            .max() ?? 0

        progress?(RegistrationProgress(stage: "Allineamento concluso", fraction: 1))

        return VolumeRegistrationOutcome(
            pose: pose,
            metric: settings.metric,
            metricValue: cost,
            coverage: coverage,
            iterations: iterations,
            converged: converged,
            maximumDisplacementMM: displacement
        )
    }

    /// Quanta parte della griglia del riferimento trova un dato nell'esame di confronto.
    ///
    /// Si misura su un reticolo regolare e non su tutti i voxel: la frazione è la stessa a meno
    /// di una parte su mille, e costa un millesimo del tempo.
    public static func coverage(of followUp: Volume, over grid: VolumeGeometry, pose: RigidPose)
        -> Double
    {
        let steps = 24
        let transform = pose.transform
        var inside = 0
        var total = 0
        for a in 0..<steps {
            for b in 0..<steps {
                for c in 0..<steps {
                    let voxel = Vec3(
                        Double(grid.columnCount - 1) * Double(a) / Double(steps - 1),
                        Double(grid.rowCount - 1) * Double(b) / Double(steps - 1),
                        Double(grid.sliceCount - 1) * Double(c) / Double(steps - 1)
                    )
                    let point = transform.apply(toPoint: grid.patientPoint(fromVoxel: voxel))
                    total += 1
                    if followUp.geometry.containsPatientPoint(point) { inside += 1 }
                }
            }
        }
        guard total > 0 else { return 0 }
        return Double(inside) / Double(total)
    }

    // MARK: Discesa

    /// Un livello della piramide, percorso fino a dove il passo si fa più corto del minimo.
    ///
    /// # Perché la discesa a passo regolato e non un metodo più moderno
    ///
    /// Perché il gradiente qui si stima alle differenze finite — l'informazione mutua con
    /// ripartizione lineare non ha una derivata che valga la pena di scrivere a mano — e in quella
    /// condizione i metodi che si fidano della **lunghezza** del gradiente (Adam, BFGS) inseguono
    /// il rumore della stima. Questo si fida solo della sua **direzione**, e accorcia il passo
    /// quando la direzione si inverte: è il comportamento che ITK adotta da vent'anni per la
    /// stessa ragione.
    private static func descend(
        from start: RigidPose,
        using function: RegistrationCostFunction,
        radiusMM: Double,
        step initialStep: Double,
        settings: RegistrationSettings
    ) -> (pose: RigidPose, cost: Double, iterations: Int, converged: Bool) {

        // I sei parametri vivono tutti in millimetri: le rotazioni entrano moltiplicate per il
        // raggio del volume, cioè per lo spostamento che producono al bordo. Senza questa scala
        // un passo di un'unità varrebbe un millimetro di traslazione e cinquantasette gradi di
        // rotazione, e la discesa userebbe di fatto le sole traslazioni.
        func pose(_ q: [Double]) -> RigidPose {
            RigidPose(
                rotationRadians: Vec3(q[0] / radiusMM, q[1] / radiusMM, q[2] / radiusMM),
                translationMM: Vec3(q[3], q[4], q[5]),
                centerMM: start.centerMM
            )
        }

        var q = [
            start.rotationRadians.x * radiusMM,
            start.rotationRadians.y * radiusMM,
            start.rotationRadians.z * radiusMM,
            start.translationMM.x,
            start.translationMM.y,
            start.translationMM.z,
        ]
        var best = function.cost(of: pose(q))
        var bestQ = q
        var step = initialStep
        var previousDirection: [Double]?
        var converged = false
        var used = 0

        for _ in 0..<settings.maximumIterationsPerLevel {
            used += 1
            let h = Swift.max(step * 0.5, settings.minimumStepMM)
            var gradient = [Double](repeating: 0, count: 6)
            for axis in 0..<6 {
                var forward = q
                var backward = q
                forward[axis] += h
                backward[axis] -= h
                gradient[axis] = (function.cost(of: pose(forward)) - function.cost(of: pose(backward))) / (2 * h)
            }

            let norm = gradient.reduce(0.0) { $0 + $1 * $1 }.squareRoot()
            guard norm.isFinite, norm > 1e-12 else {
                converged = true
                break
            }
            let direction = gradient.map { -$0 / norm }

            if let previousDirection {
                let alignment = zip(direction, previousDirection).reduce(0.0) { $0 + $1.0 * $1.1 }
                if alignment < 0 { step *= settings.relaxationFactor }
            }
            if step < settings.minimumStepMM {
                converged = true
                break
            }

            for axis in 0..<6 { q[axis] += step * direction[axis] }
            let cost = function.cost(of: pose(q))
            if cost < best {
                best = cost
                bestQ = q
            }
            previousDirection = direction
        }

        return (pose(bestQ), best, used, converged)
    }

    // MARK: Controlli d'ingresso

    private static func validate(_ volume: Volume) throws {
        let geometry = volume.geometry
        guard geometry.columnCount >= minimumVoxelsPerAxis,
            geometry.rowCount >= minimumVoxelsPerAxis,
            geometry.sliceCount >= minimumVoxelsPerAxis
        else {
            throw VolumeRegistrationError.volumeTooSmall(minimumVoxelsPerAxis: minimumVoxelsPerAxis)
        }
        guard volume.rawValueRange.lowerBound < volume.rawValueRange.upperBound else {
            throw VolumeRegistrationError.constantVolume
        }
    }

    /// Il braccio con cui una rotazione si converte in millimetri: mezza diagonale della regione
    /// su cui si registra, o del volume intero se la regione non c'è.
    private static func rotationRadiusMM(of geometry: VolumeGeometry, regionMM: BoxMM?) -> Double {
        let size = regionMM?.sizeMM ?? geometry.physicalSizeMM
        let radius = size.length * 0.5
        return radius.isFinite && radius > 1 ? radius : 1
    }
}
