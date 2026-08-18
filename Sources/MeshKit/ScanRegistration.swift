import DICOMCore
import Foundation

// Registrazione di una scansione intraorale sulla CBCT.
//
// # Perché serve, in una riga
//
// Senza, la posizione protesica si stima sull'osso invece che sui denti, e una dima appoggiata
// sui denti non si può nemmeno progettare. È il divario più grande fra questo programma e
// coDiagnostiX, DTX Studio o SMOP, e non è un divario di rifinitura.
//
// # Perché in due tempi, e non solo ICP
//
// L'ICP converge verso il minimo locale **più vicino**: se le due superfici partono lontane,
// converge sul dente sbagliato, e lo fa con uno scarto piccolo e convincente. Serve un allineamento
// iniziale che venga da fuori dell'algoritmo — punti corrispondenti indicati a mano, tre o più,
// sulle cuspidi che si riconoscono in entrambe le superfici. Horn li risolve in forma chiusa,
// senza iterazioni e senza minimi locali; l'ICP parte da lì e stringe.
//
// # Che cosa dichiara il risultato, e perché
//
// Lo **scarto**, sempre. Una registrazione senza scarto dichiarato è un'affermazione senza prova:
// l'ICP restituisce comunque una trasformazione, anche quando ha allineato lo smalto vero della
// scansione con l'alone metallico di una corona. Su questo si decide una dima chirurgica, quindi
// il numero che conta non è che l'algoritmo abbia finito, è di quanto le due superfici distano
// dopo — e su quanti punti.

/// Una coppia di punti corrispondenti, indicati a mano sulle due superfici.
public struct LandmarkPair: Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Punto sulla scansione, nel suo sistema di riferimento.
    public var scanMM: Vec3
    /// Punto corrispondente sulla CBCT, in millimetri Patient.
    public var volumeMM: Vec3

    public init(id: UUID = UUID(), scanMM: Vec3, volumeMM: Vec3) {
        self.id = id
        self.scanMM = scanMM
        self.volumeMM = volumeMM
    }
}

/// Come è andata una registrazione, con tutto ciò che serve a giudicarla.
public struct ScanRegistrationOutcome: Sendable {

    /// Trasformazione che porta la scansione nello spazio Patient.
    public let transform: Transform3D
    /// Scarto dopo l'allineamento **a coppie di punti**, prima dell'affinamento.
    public let landmarkRMSMM: Double
    /// Scarto dopo l'ICP, e su quanti punti.
    public let surfaceRMSMM: Double
    public let surfaceMaxMM: Double
    public let surfacePointCount: Int
    public let converged: Bool

    /// Giudizio esplicito, con la soglia dichiarata.
    ///
    /// Mezzo millimetro non è una convenzione arbitraria: è l'ordine di grandezza dell'accuratezza
    /// che la letteratura riporta per le dime su appoggio dentale, e registrare peggio di così
    /// rende la dima il pezzo meno preciso della catena. Sopra il millimetro non è una
    /// registrazione, è una coincidenza.
    public var quality: RegistrationQuality {
        if surfaceRMSMM <= 0.3 { return .good }
        if surfaceRMSMM <= 0.5 { return .acceptable }
        return .poor
    }
}

public enum RegistrationQuality: Hashable, Sendable {
    case good
    case acceptable
    case poor

    public var localizedName: String {
        switch self {
        case .good: return "Buona"
        case .acceptable: return "Accettabile"
        case .poor: return "Non utilizzabile"
        }
    }

    public var explanation: String {
        switch self {
        case .good:
            return "Sotto tre decimi di millimetro: la registrazione non è il pezzo meno preciso "
                + "della catena."
        case .acceptable:
            return "Fra tre e cinque decimi. Utilizzabile, ma è il termine che limita "
                + "l'accuratezza di tutto ciò che ne discende."
        case .poor:
            return "Oltre mezzo millimetro. Non fidartene: verifica che i denti usati siano sani "
                + "e senza metallo, e che i punti corrispondenti indichino le stesse cuspidi."
        }
    }
}

public enum ScanRegistration {

    /// Registra una scansione sulla CBCT: prima le coppie di punti, poi l'affinamento.
    ///
    /// - Parameters:
    ///   - scan: la superficie importata, nel proprio sistema di riferimento.
    ///   - landmarks: almeno tre coppie, e non complanari — tre punti allineati o su una retta
    ///     lasciano una rotazione libera, e la scansione ruoterebbe attorno a essa senza che
    ///     nulla lo impedisca.
    ///   - targetPoints: la nuvola estratta dal volume. Vedi `VolumeSurface`.
    public static func register(
        scan: Mesh,
        landmarks: [LandmarkPair],
        targetPoints: [Vec3],
        options: ICPOptions = ICPOptions()
    ) throws -> ScanRegistrationOutcome {

        guard landmarks.count >= 3 else {
            throw RegistrationError.tooFewPoints(count: landmarks.count, required: 3)
        }
        guard !targetPoints.isEmpty else { throw RegistrationError.emptyMesh }
        guard !scan.verticesMM.isEmpty else { throw RegistrationError.emptyMesh }

        let coarse = try PointRegistration.align(
            source: landmarks.map(\.scanMM),
            target: landmarks.map(\.volumeMM))

        let refined = try ICP.refine(
            source: scan.verticesMM,
            target: targetPoints,
            initial: coarse.transform,
            options: options)

        return ScanRegistrationOutcome(
            transform: refined.transform,
            landmarkRMSMM: coarse.rmsErrorMM,
            surfaceRMSMM: refined.rmsErrorMM,
            surfaceMaxMM: refined.maxErrorMM,
            surfacePointCount: refined.pointCount,
            converged: refined.converged)
    }

    /// Scarto punto per punto fra la scansione registrata e la nuvola del volume.
    ///
    /// Serve a **vedere dove** la registrazione è buona e dove no, invece di leggere un numero
    /// solo: un RMS accettabile può nascondere un settore allineato male, ed è precisamente il
    /// settore in cui si sta per mettere l'impianto.
    public static func deviations(
        of scan: Mesh, transformedBy transform: Transform3D, against targetPoints: [Vec3]
    ) -> [Double] {
        guard !targetPoints.isEmpty else { return [] }
        return scan.verticesMM.map { vertex in
            let moved = transform.apply(toPoint: vertex)
            var best = Double.infinity
            for target in targetPoints {
                let distance = (moved - target).lengthSquared
                if distance < best { best = distance }
            }
            return best.squareRoot()
        }
    }
}
