import DICOMCore
import Foundation

// Quanto vale davvero un numero misurato.
//
// # Contratto 5: nessun numero dichiara più precisione di quanta ne abbia
//
// Il programma scriveva `12,47 mm`. Due decimali sono dieci micrometri, su un volume campionato
// a duecento. È una precisione inventata di un fattore venti, e non è un dettaglio estetico: chi
// legge `12,47` e `12,49` conclude che sono due misure diverse, mentre sono la stessa misura
// ripetuta. Su una decisione implantare — «restano 1,8 mm sopra il canale» — la differenza fra un
// numero e un numero **con la sua incertezza** è la differenza fra un dato e un'impressione.
//
// # Il modello, e da dove viene
//
// Per un'estremità posata a mano su una vista MPR concorrono due contributi indipendenti:
//
// 1. **Campionamento e volume parziale.** Il contorno vero sta da qualche parte dentro il voxel
//    che lo contiene. Distribuzione uniforme sulla dimensione del voxel: scarto tipo `s/√12`.
// 2. **Localizzazione dell'operatore.** Anche su un contorno osseo netto, due posature dello
//    stesso punto differiscono dell'ordine di un voxel. Si modella con la stessa distribuzione
//    uniforme di larghezza `s`, indipendente dalla prima: `s/√12`.
//
// Per estremità: `σₚ = s·√(2/12)`. Per una lunghezza fra due estremità indipendenti, lungo la
// direzione della misura: `σ_L = √2·σₚ = s/√3 ≈ 0,58·s`. A 0,2 mm di voxel fa **0,12 mm**, che è
// l'ordine di grandezza riportato dalla letteratura sull'accuratezza lineare delle CBCT dentali.
//
// # Perché lo slab non entra nel ±
//
// Sarebbe la cosa comoda da fare e sarebbe sbagliata. Entrambe le estremità stanno **sul piano**
// per costruzione — `patientPoint` restituisce un punto del piano — quindi la distanza misurata è
// una distanza *nel piano*, ed è esatta come tale. Ciò che lo slab rende incerto è **dove stiano
// davvero** le due strutture lungo la normale: con una proiezione a massima intensità ciascuna
// può trovarsi ovunque nello spessore.
//
// L'effetto non è un errore simmetrico: la distanza vera è `√(L² + Δ²)` con Δ la differenza di
// profondità, quindi è sempre **maggiore o uguale** a quella misurata. È un limite inferiore, e
// va detto come tale invece di essere sciolto in un ± che suggerirebbe simmetria.

/// Come è stata acquisita una misura. Si registra al momento della posa e non cambia più.
///
/// Deve viaggiare con l'annotazione e non essere ricalcolata dallo stato corrente: chi assottiglia
/// lo slab dopo aver misurato non rende retroattivamente attendibile una misura presa su venti
/// millimetri di proiezione.
public struct AcquisitionContext: Hashable, Sendable, Codable {

    /// Spaziatura del volume su cui la misura è stata presa, in millimetri.
    public var voxelSpacingMM: Vec3
    /// Spessore attraversato dalla vista, in millimetri. Zero per una fetta singola.
    public var slabThicknessMM: Double
    /// Se la vista **proietta** attraverso lo spessore invece di mediarlo.
    ///
    /// Distingue una proiezione a massima o minima intensità, in cui il pixel viene da un punto
    /// ignoto dello spessore, da una media, in cui viene da tutto lo spessore. Nella prima la
    /// profondità di ciò che si vede è indeterminata; nella seconda è il centro, con una
    /// sfocatura.
    public var projectsThroughSlab: Bool
    /// Se la misura è presa su una **ricostruzione curva**, cioè sulla panorex.
    public var isCurvedSurface: Bool
    /// Se il volume non è quello acquisito ma un suo derivato.
    public var isDerivedVolume: Bool

    public init(
        voxelSpacingMM: Vec3,
        slabThicknessMM: Double = 0,
        projectsThroughSlab: Bool = false,
        isCurvedSurface: Bool = false,
        isDerivedVolume: Bool = false
    ) {
        self.voxelSpacingMM = voxelSpacingMM
        self.slabThicknessMM = max(slabThicknessMM, 0)
        self.projectsThroughSlab = projectsThroughSlab
        self.isCurvedSurface = isCurvedSurface
        self.isDerivedVolume = isDerivedVolume
    }

    /// La dimensione di voxel che governa l'incertezza.
    ///
    /// La **maggiore** delle tre e non la media: su un volume anisotropo l'incertezza la detta
    /// l'asse peggiore, perché una misura obliqua ne raccoglie il contributo e non si sa in
    /// anticipo quale direzione avrà.
    public var governingSpacingMM: Double {
        max(voxelSpacingMM.x, max(voxelSpacingMM.y, voxelSpacingMM.z))
    }
}

/// Un avvertimento sul contesto in cui una misura è stata presa.
public enum MeasurementCaveat: Hashable, Sendable {

    /// La vista proietta attraverso uno spessore: la lunghezza misurata è un **limite inferiore**.
    case projectedSlab(thicknessMM: Double, possibleExcessMM: Double)
    /// Misura presa sulla superficie ricostruita di una panorex, non su un piano.
    case curvedSurface
    /// Volume derivato: i valori di densità non sono quelli acquisiti.
    case derivedVolume

    public var localizedDescription: String {
        switch self {
        case .projectedSlab(let thickness, let excess):
            return String(
                format:
                    "Presa su una proiezione di %.0f mm: le due strutture possono stare a "
                    + "profondità diverse, e la distanza vera può superare la misurata fino a "
                    + "%.1f mm.",
                thickness, excess
            ).replacingOccurrences(of: ".", with: ",")
        case .curvedSurface:
            return
                "Presa su una ricostruzione curva: è una distanza fra due punti della superficie "
                + "ricostruita, non fra due strutture anatomiche."
        case .derivedVolume:
            return
                "Volume derivato: le densità non sono quelle acquisite e non si confrontano con "
                + "quelle dell'originale."
        }
    }

    /// Se l'avvertimento riguarda la **validità** della misura o solo la sua interpretazione.
    public var invalidatesLength: Bool {
        switch self {
        case .projectedSlab, .curvedSurface: return true
        case .derivedVolume: return false
        }
    }
}

/// Incertezza e avvertimenti di una misura.
public struct MeasurementQuality: Hashable, Sendable {

    /// Incertezza tipo (1σ) della lunghezza, in millimetri.
    public let standardUncertaintyMM: Double
    public let caveats: [MeasurementCaveat]

    public var hasCaveats: Bool { !caveats.isEmpty }
}

public enum MeasurementUncertainty {

    /// Contributo per estremità: campionamento e localizzazione, indipendenti e uniformi.
    static func endpointUncertaintyMM(spacingMM: Double) -> Double {
        spacingMM * (2.0 / 12.0).squareRoot()
    }

    /// Incertezza tipo di una lunghezza fra due estremità posate a mano.
    public static func lengthUncertaintyMM(context: AcquisitionContext) -> Double {
        // Due estremità indipendenti lungo la direzione della misura.
        2.0.squareRoot() * endpointUncertaintyMM(spacingMM: context.governingSpacingMM)
    }

    /// Qualità completa di una misura di lunghezza.
    public static func quality(ofLengthMM lengthMM: Double, context: AcquisitionContext)
        -> MeasurementQuality
    {
        var caveats: [MeasurementCaveat] = []

        if context.projectsThroughSlab, context.slabThicknessMM > 0 {
            // Eccesso massimo: le due strutture agli estremi opposti dello spessore.
            // `√(L² + t²) − L`, che per L grande rispetto a t tende a `t²/2L` e per L piccolo
            // tende a t. Si calcola la forma esatta perché la forma asintotica sbaglia proprio
            // sulle misure corte, che sono quelle su cui si decide.
            let t = context.slabThicknessMM
            let length = max(abs(lengthMM), 1e-6)
            let excess = (length * length + t * t).squareRoot() - length
            caveats.append(.projectedSlab(thicknessMM: t, possibleExcessMM: excess))
        }

        if context.isCurvedSurface { caveats.append(.curvedSurface) }
        if context.isDerivedVolume { caveats.append(.derivedVolume) }

        return MeasurementQuality(
            standardUncertaintyMM: lengthUncertaintyMM(context: context),
            caveats: caveats)
    }

    /// Quanti decimali sono giustificati da un'incertezza.
    ///
    /// La regola è quella metrologica: si arrotonda l'incertezza a **una cifra significativa** e
    /// si riporta il valore alla stessa posizione decimale. Scrivere più cifre di così non
    /// aggiunge informazione: aggiunge rumore che il lettore scambia per segnale.
    public static func decimals(forUncertaintyMM uncertainty: Double) -> Int {
        guard uncertainty.isFinite, uncertainty > 0 else { return 2 }
        // Posizione della prima cifra significativa: 0,12 → −1 → un decimale; 0,012 → −2 → due.
        let exponent = Foundation.floor(Foundation.log10(uncertainty))
        return min(max(Int(-exponent), 0), 3)
    }

    /// L'incertezza arrotondata a una cifra significativa, come si scrive.
    public static func roundedUncertaintyMM(_ uncertainty: Double) -> Double {
        guard uncertainty.isFinite, uncertainty > 0 else { return 0 }
        let exponent = Foundation.floor(Foundation.log10(uncertainty))
        let scale = Foundation.pow(10.0, exponent)
        return (uncertainty / scale).rounded() * scale
    }
}
