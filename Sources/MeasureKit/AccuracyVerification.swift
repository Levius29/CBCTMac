import DICOMCore
import Foundation

// Verifica di accuratezza su un fantoccio di geometria nota.
//
// # Perché un programma di misura deve saper verificare sé stesso
//
// Perché un numero che nessuno ha mai confrontato con una lunghezza nota è un'opinione. Tutta la
// catena — matrice DICOM, orientamento, piano di taglio, conversione clic-millimetri,
// formattazione — può sbagliare in silenzio: un asse invertito o una spaziatura letta dal tag
// sbagliato producono immagini perfettamente plausibili e misure sbagliate del dieci per cento.
// Nessun test di unità sui singoli pezzi lo intercetta, perché ogni pezzo è corretto rispetto
// alla propria specifica; a sbagliare è la loro composizione.
//
// Su un fantoccio sintetico la verifica non è circolare come sembra. Il volume lo genera un
// codice che conosce le densità e le posizioni; la misura le ricava **dai voxel**, attraversando
// geometria, campionamento e criterio di bordo. Se le due non coincidono, la composizione ha un
// difetto. Su un fantoccio **acquisito davvero** la stessa procedura diventa il controllo di
// qualità dell'apparecchio, ed è la ragione per cui l'interfaccia è la stessa.
//
// # Il criterio di bordo, che è la parte che conta
//
// Dove finisce un oggetto in un'immagine campionata non è ovvio: il volume parziale sfuma il
// contorno su due o tre voxel. Il criterio adottato è quello standard in metrologia per
// immagini: il **passaggio al 50 %** fra il livello di fondo e quello dell'oggetto, individuato
// per interpolazione lineare fra i due campioni che lo attraversano. Prendere invece il primo
// voxel sopra una soglia fissa darebbe una misura che dipende dalla soglia scelta, cioè un
// risultato che si può aggiustare finché non piace.

/// Un confronto fra un valore atteso e uno misurato.
public struct VerificationResult: Hashable, Sendable, Identifiable {

    public var id: String { name }

    public let name: String
    public let expected: Double
    public let measured: Double
    /// Tolleranza entro cui l'esito si considera superato, nella stessa unità.
    public let toleranceMM: Double
    public let unit: String

    public var deviation: Double { measured - expected }
    public var passed: Bool { abs(deviation) <= toleranceMM }

    public var formattedDeviation: String {
        String(format: "%+.3f %@", deviation, unit).replacingOccurrences(of: ".", with: ",")
    }
}

public enum AccuracyVerification {

    /// Posizione sub-voxel del passaggio al 50 % lungo una retta, in millimetri Patient.
    ///
    /// Si campiona a passo fine lungo la direzione e si cerca l'attraversamento del livello
    /// intermedio fra `low` e `high`, interpolando linearmente fra i due campioni che lo
    /// contengono. È l'unico modo di ottenere una posizione più fine del voxel senza inventarla.
    ///
    /// - Parameter searchFromMM: punto di partenza, **dentro** la regione a livello `low`.
    /// - Returns: la posizione del bordo, o `nil` se lungo il percorso non c'è alcun
    ///   attraversamento — che va distinto da un bordo trovato a distanza zero.
    public static func edgeCrossing(
        in volume: Volume,
        fromMM searchFromMM: Vec3,
        direction: Vec3,
        lengthMM: Double,
        low: Double,
        high: Double,
        stepMM: Double = 0.05
    ) -> Vec3? {
        guard let unit = direction.normalized, lengthMM > 0, stepMM > 0 else { return nil }
        let level = (low + high) / 2
        let rising = high > low
        let steps = Int(lengthMM / stepMM)
        guard steps > 1 else { return nil }

        var previousValue: Double?
        var previousPoint = searchFromMM

        for index in 0...steps {
            let point = searchFromMM + unit * (Double(index) * stepMM)
            guard let value = volume.interpolatedDensityValue(atPatient: point) else {
                previousValue = nil
                previousPoint = point
                continue
            }

            if let previous = previousValue {
                let crossed = rising ? (previous < level && value >= level)
                    : (previous > level && value <= level)
                if crossed {
                    // Interpolazione lineare fra i due campioni: è ciò che rende la posizione
                    // sub-voxel invece che arrotondata al passo di ricerca.
                    let span = value - previous
                    let t = abs(span) > 1e-12 ? (level - previous) / span : 0.5
                    return previousPoint.lerp(to: point, t: min(max(t, 0), 1))
                }
            }
            previousValue = value
            previousPoint = point
        }
        return nil
    }

    /// Misura l'estensione di un oggetto lungo una direzione, dai due passaggi al 50 %.
    ///
    /// Si parte dal centro, che è dentro l'oggetto, e si cercano i due bordi in verso opposto:
    /// partendo da fuori si troverebbe il primo ostacolo incontrato, che su un fantoccio con più
    /// oggetti non è detto sia quello che si voleva misurare.
    public static func extent(
        of volume: Volume,
        throughMM centreMM: Vec3,
        direction: Vec3,
        insideValue: Double,
        outsideValue: Double,
        searchLengthMM: Double
    ) -> Double? {
        guard let unit = direction.normalized else { return nil }
        guard
            let positive = edgeCrossing(
                in: volume, fromMM: centreMM, direction: unit, lengthMM: searchLengthMM,
                low: insideValue, high: outsideValue),
            let negative = edgeCrossing(
                in: volume, fromMM: centreMM, direction: unit * -1.0, lengthMM: searchLengthMM,
                low: insideValue, high: outsideValue)
        else { return nil }
        return positive.distance(to: negative)
    }

    /// Verifica il fantoccio sintetico: spigolo del cubo sui tre assi e densità delle regioni.
    ///
    /// La tolleranza è **due volte l'incertezza tipo del Contratto 5**, non un valore scelto a
    /// piacere.
    ///
    /// Legarla al modello d'incertezza invece che a un numero fa due cose. Rende la verifica
    /// valida a ogni risoluzione, perché segue il voxel. E soprattutto la rende **coerente con
    /// ciò che il programma dichiara**: se una misura cadesse fuori da due sigma, o è sbagliata
    /// la catena di coordinate o è sbagliato il modello d'incertezza — in entrambi i casi c'è
    /// qualcosa da guardare, e in nessuno dei due il numero mostrato all'utente sarebbe onesto.
    ///
    /// Su un fantoccio binario, campionato ai centri dei voxel, il contorno vero cade dentro
    /// l'ultimo voxel: il passaggio al 50 % ne risulta spostato in fuori di una frazione di
    /// voxel per lato. È esattamente il volume parziale che il modello quantifica in `s·√(2/12)`
    /// per estremità, e per questo la verifica lo assorbe invece di chiamarlo difetto.
    public static func verifyPhantom(_ volume: Volume) -> [VerificationResult] {
        let context = AcquisitionContext(voxelSpacingMM: volume.geometry.spacingMM)
        let tolerance = 2 * MeasurementUncertainty.lengthUncertaintyMM(context: context)
        // Il cubo è centrato nell'''origine Patient del fantoccio, come lo genera
        // `SyntheticVolume`: le sfere hanno un centro proprio, il cubo no.
        let centre = Vec3.zero
        var results: [VerificationResult] = []

        let axes: [(String, Vec3)] = [
            ("Spigolo del cubo · L–R", Vec3(1, 0, 0)),
            ("Spigolo del cubo · A–P", Vec3(0, 1, 0)),
            ("Spigolo del cubo · S–I", Vec3(0, 0, 1)),
        ]

        for (name, direction) in axes {
            guard
                let measured = extent(
                    of: volume, throughMM: centre, direction: direction,
                    insideValue: SyntheticVolume.corticalBone,
                    outsideValue: SyntheticVolume.water,
                    searchLengthMM: SyntheticVolume.cubeEdgeMM)
            else { continue }
            results.append(
                VerificationResult(
                    name: name,
                    expected: SyntheticVolume.cubeEdgeMM,
                    measured: measured,
                    toleranceMM: tolerance,
                    unit: "mm"))
        }

        for sphere in SyntheticVolume.spheres {
            guard let value = volume.interpolatedDensityValue(atPatient: sphere.centerMM) else {
                continue
            }
            results.append(
                VerificationResult(
                    name: String(format: "Sfera Ø%.0f mm · densità", sphere.diameterMM),
                    expected: sphere.density,
                    measured: value,
                    // Sulla densità la tolleranza è il rumore di quantizzazione del rescale, non
                    // il voxel: al centro di una sfera il volume parziale non entra.
                    toleranceMM: 1.0,
                    unit: "GV"))
        }

        return results
    }
}
