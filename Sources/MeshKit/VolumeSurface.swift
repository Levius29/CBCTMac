import DICOMCore
import Foundation

// Estrazione di una nuvola di punti dalla superficie di una struttura nel volume.
//
// # A che cosa serve, e perché è il pezzo che decide
//
// Registrare una scansione intraorale su una CBCT significa far coincidere due superfici. Una
// arriva già come superficie — il file STL dello scanner. L'altra **non esiste** finché non la si
// estrae dai voxel, ed è qui che si decide se la registrazione varrà qualcosa: l'ICP allinea la
// nuvola che gli si dà, e se quella nuvola descrive male lo smalto, l'allineamento sarà preciso
// rispetto a una superficie sbagliata.
//
// # Il criterio, e perché non è una soglia
//
// Prendere «tutti i voxel sopra 1500 GV» darebbe una nuvola spessa quanto la zona di transizione
// — due o tre voxel — e con densità di punti che dipende dalla direzione. L'ICP pesa ogni punto
// allo stesso modo, quindi una nuvola più fitta da un lato tira l'allineamento da quella parte.
//
// Si estrae invece il **passaggio al 50 %** lungo raggi paralleli a un asse, con interpolazione
// fra i due campioni che lo attraversano: si ottiene un punto per raggio e per attraversamento,
// sub-voxel, e la densità dei punti la decide il passo dei raggi — cioè chi chiama, non
// l'anatomia. È lo stesso criterio della verifica di accuratezza, e per la stessa ragione: è
// l'unica definizione di bordo che non dipende da una soglia scelta a piacere.
//
// # Che cosa questo **non** risolve
//
// Lo smalto in una CBCT è corrotto dagli artefatti da metallo e dal volume parziale. Su un
// paziente con corone, la superficie estratta attorno a quelle corone non è la superficie del
// dente: è la superficie di un artefatto. La registrazione va quindi fatta su denti **sani e
// senza metallo**, e questo modulo non può saperlo — lo sa chi guarda l'immagine. Per questo la
// regione da usare è un parametro e non una scelta automatica, e per questo il risultato porta
// sempre con sé lo scarto, che è l'unico modo di accorgersi che si è registrato su un artefatto.

/// La regione e i parametri con cui estrarre una superficie dal volume.
public struct SurfaceExtraction: Hashable, Sendable {

    /// Regione da percorrere, in millimetri Patient.
    public var minMM: Vec3
    public var maxMM: Vec3
    /// Densità che separa la struttura dal fondo, nell'unità del volume.
    public var thresholdGV: Double
    /// Passo fra raggi vicini, in millimetri: decide quanto è fitta la nuvola.
    public var raySpacingMM: Double
    /// Passo di campionamento lungo il raggio. Sotto il voxel, per non saltare una parete sottile.
    public var stepMM: Double
    /// Tetto al numero di punti restituiti.
    ///
    /// Non è prudenza: l'ICP costa per punto, e oltre qualche decina di migliaia il guadagno di
    /// precisione è nullo mentre il tempo cresce. Meglio una nuvola rada e ben distribuita che
    /// una fitta e lenta.
    public var maximumPoints: Int

    public init(
        minMM: Vec3,
        maxMM: Vec3,
        thresholdGV: Double,
        raySpacingMM: Double = 0.6,
        stepMM: Double = 0.1,
        maximumPoints: Int = 20_000
    ) {
        self.minMM = minMM
        self.maxMM = maxMM
        self.thresholdGV = thresholdGV
        self.raySpacingMM = max(raySpacingMM, 0.05)
        self.stepMM = max(stepMM, 0.01)
        self.maximumPoints = max(maximumPoints, 1)
    }
}

public enum VolumeSurface {

    /// Estrae i punti di superficie dentro la regione richiesta.
    ///
    /// I raggi corrono lungo **i tre assi**, non uno solo. Con un asse solo una parete parallela a
    /// quell'asse non produrrebbe alcun punto — le pareti vestibolari sparirebbero dalla nuvola
    /// se i raggi corressero in senso vestibolo-linguale — e l'ICP non avrebbe nulla da vincolare
    /// in quella direzione. È il difetto più insidioso possibile: la registrazione converge, il
    /// numero di scarto è piccolo, e la superficie è libera di scivolare lungo l'asse scoperto.
    public static func points(in volume: Volume, extraction: SurfaceExtraction) -> [Vec3] {
        let low = min(extraction.minMM, extraction.maxMM)
        let high = max(extraction.minMM, extraction.maxMM)
        guard low.isFinite, high.isFinite else { return [] }

        let size = high - low
        guard size.x > 0, size.y > 0, size.z > 0 else { return [] }

        // Il passo di campionamento si limita a **metà voxel**, qualunque cosa chieda chi chiama.
        //
        // Non è prudenza: l'interpolazione lineare fra due campioni ritrova il passaggio esatto
        // solo se la densità è lineare **fra quei due campioni**. Su un volume interpolato
        // trilinearmente la transizione è una rampa lunga un voxel, quindi con un passo più largo
        // i due campioni cadono ai lati della rampa e il punto interpolato si sposta — di un
        // decimo abbondante di millimetro su voxel da 0,4. Chi chiede un passo grossolano per
        // andare più veloce otterrebbe una nuvola più rada **e** spostata, senza che nulla glielo
        // dica.
        var refined = extraction
        let spacing = volume.geometry.spacingMM
        let finest = Swift.min(spacing.x, Swift.min(spacing.y, spacing.z))
        if finest > 0 { refined.stepMM = Swift.min(refined.stepMM, finest / 2) }
        let extraction = refined

        var found: [Vec3] = []
        found.reserveCapacity(min(extraction.maximumPoints, 4096))

        for axis in 0..<3 {
            let direction: Vec3 = axis == 0 ? Vec3(1, 0, 0) : (axis == 1 ? Vec3(0, 1, 0) : Vec3(0, 0, 1))
            let lengthMM = component(size, axis)
            let (firstAxis, secondAxis) = otherAxes(axis)

            let firstCount = max(Int(component(size, firstAxis) / extraction.raySpacingMM), 1)
            let secondCount = max(Int(component(size, secondAxis) / extraction.raySpacingMM), 1)

            for i in 0...firstCount {
                for j in 0...secondCount {
                    var origin = low
                    origin = setting(origin, firstAxis,
                        component(low, firstAxis)
                            + Double(i) / Double(firstCount) * component(size, firstAxis))
                    origin = setting(origin, secondAxis,
                        component(low, secondAxis)
                            + Double(j) / Double(secondCount) * component(size, secondAxis))

                    appendCrossings(
                        along: direction, from: origin, lengthMM: lengthMM,
                        in: volume, extraction: extraction, into: &found)

                    if found.count >= extraction.maximumPoints { return found }
                }
            }
        }
        return found
    }

    /// Tutti gli attraversamenti della soglia lungo un raggio, in entrambi i versi.
    ///
    /// Entrambi i versi perché un raggio che attraversa un dente incontra **due** superfici, e
    /// tenerne una sola darebbe una nuvola sistematicamente spostata verso il lato di entrata.
    private static func appendCrossings(
        along direction: Vec3,
        from originMM: Vec3,
        lengthMM: Double,
        in volume: Volume,
        extraction: SurfaceExtraction,
        into found: inout [Vec3]
    ) {
        let steps = Int(lengthMM / extraction.stepMM)
        guard steps > 1 else { return }

        var previousValue: Double?
        var previousPoint = originMM

        for index in 0...steps {
            let point = originMM + direction * (Double(index) * extraction.stepMM)
            guard let value = volume.interpolatedDensityValue(atPatient: point) else {
                previousValue = nil
                previousPoint = point
                continue
            }

            if let previous = previousValue {
                let crossedUp = previous < extraction.thresholdGV && value >= extraction.thresholdGV
                let crossedDown = previous >= extraction.thresholdGV && value < extraction.thresholdGV
                if crossedUp || crossedDown {
                    let span = value - previous
                    let t = abs(span) > 1e-12 ? (extraction.thresholdGV - previous) / span : 0.5
                    found.append(previousPoint.lerp(to: point, t: min(max(t, 0), 1)))
                    if found.count >= extraction.maximumPoints { return }
                }
            }
            previousValue = value
            previousPoint = point
        }
    }

    // MARK: Accesso alle componenti per indice

    private static func component(_ v: Vec3, _ axis: Int) -> Double {
        switch axis {
        case 0: return v.x
        case 1: return v.y
        default: return v.z
        }
    }

    private static func setting(_ v: Vec3, _ axis: Int, _ value: Double) -> Vec3 {
        switch axis {
        case 0: return Vec3(value, v.y, v.z)
        case 1: return Vec3(v.x, value, v.z)
        default: return Vec3(v.x, v.y, value)
        }
    }

    private static func otherAxes(_ axis: Int) -> (Int, Int) {
        switch axis {
        case 0: return (1, 2)
        case 1: return (0, 2)
        default: return (0, 1)
        }
    }
}

private func min(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(Swift.min(a.x, b.x), Swift.min(a.y, b.y), Swift.min(a.z, b.z))
}

private func max(_ a: Vec3, _ b: Vec3) -> Vec3 {
    Vec3(Swift.max(a.x, b.x), Swift.max(a.y, b.y), Swift.max(a.z, b.z))
}
