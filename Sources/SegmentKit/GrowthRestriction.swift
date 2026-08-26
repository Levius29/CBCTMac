import DICOMCore
import Foundation

// Il confine dentro cui una crescita può assegnare voxel.
//
// # Perché serve, con i numeri
//
// La crescita competitiva separa due regioni facendole incontrare dove il dato è più debole, e
// su un dente questo funziona **finché i due fronti si incontrano davvero**. Se il fronte del
// dente trova una via verso l'osso che il fronte dell'osso non presidia — l'apice della radice
// che tocca la corticale, un ponte di dentina sclerotica, una zona bruciata da un'otturazione —
// non incontra nessuno, e da lì dilaga.
//
// Non è un'ipotesi. Sul fantoccio dente-in-osso della suite, con un marcatore per parte, il
// dente si prende **78.123 voxel** contro i circa 7.400 che gli spettano: si è preso quasi tutta
// la mandibola. Marcare l'osso in quattro punti invece che in uno scende a 41.006 — meglio, e
// ancora sei volte troppo. Confinare la crescita a una scatola attorno al dente porta a 10.618,
// che è il dente più il legamento attorno.
//
// Da qui la scatola: è **l'unico dei tre rimedi che dà un limite superiore**. Gli altri due
// spostano il confine e sperano; questa lo garantisce, perché fuori dalla scatola non si assegna
// niente qualunque cosa faccia il dato.
//
// # E il secondo motivo, che vale quanto il primo
//
// Il costo della crescita è nel numero di voxel che tocca. Un dente sta in una scatola da 15 mm
// di lato: a 0,15 mm sono 10⁶ voxel, contro i 10⁹ di un FOV da 16 cm. Confinare non è solo più
// corretto, è **mille volte più rapido** — la differenza fra un'attesa e un risultato immediato.
//
// # Che cosa la scatola non è
//
// Non è un ritaglio del volume: il volume non si tocca e la maschera resta allineata a tutti i
// suoi voxel. Ed è un taglio **netto**, non un contorno: ciò che sporge dalla scatola viene
// tagliato di piatto sulla sua faccia, e nella mesh si vede come una superficie piana. Chi
// disegna la scatola la disegna larga, e questo va detto dove la si disegna.
struct GrowthRestriction: Sendable {

    /// Estremi in indici, già intersecati col volume.
    let minimumI: Int, maximumI: Int
    let minimumJ: Int, maximumJ: Int
    let minimumK: Int, maximumK: Int

    private let box: BoxMM
    private let geometry: VolumeGeometry

    /// Costruisce la restrizione, o fallisce se il riquadro non tocca alcun voxel.
    ///
    /// Gli estremi in indici si ricavano dagli **otto vertici** del riquadro portati in spazio
    /// voxel, non dai due estremi: con una CBCT acquisita di sbieco la matrice DICOM ruota, e i
    /// due estremi in millimetri non sono i due estremi in indici. Prendere solo quelli
    /// taglierebbe via metà della regione, e lo farebbe in silenzio.
    ///
    /// Quel che se ne ottiene è una scatola di indici che **contiene** la regione richiesta e in
    /// generale è più larga. È voluto: serve a scartare in fretta i voxel lontani, mentre chi
    /// decide davvero è `allows(i:j:k:)`, che rimette il punto in millimetri e lo confronta col
    /// riquadro vero.
    init?(box: BoxMM, geometry: VolumeGeometry) {
        guard box.minMM.isFinite, box.maxMM.isFinite else { return nil }
        guard box.minMM.x <= box.maxMM.x, box.minMM.y <= box.maxMM.y, box.minMM.z <= box.maxMM.z
        else { return nil }

        var lowest = Vec3(.infinity, .infinity, .infinity)
        var highest = Vec3(-.infinity, -.infinity, -.infinity)
        for x in [box.minMM.x, box.maxMM.x] {
            for y in [box.minMM.y, box.maxMM.y] {
                for z in [box.minMM.z, box.maxMM.z] {
                    let voxel = geometry.voxelPoint(fromPatient: Vec3(x, y, z))
                    guard voxel.isFinite else { return nil }
                    lowest = Vec3(
                        Swift.min(lowest.x, voxel.x), Swift.min(lowest.y, voxel.y),
                        Swift.min(lowest.z, voxel.z))
                    highest = Vec3(
                        Swift.max(highest.x, voxel.x), Swift.max(highest.y, voxel.y),
                        Swift.max(highest.z, voxel.z))
                }
            }
        }

        // Un voxel a cavallo della faccia va tenuto: il suo centro può stare dentro anche quando
        // l'estremo continuo cade appena fuori. Da qui `floor` sotto e `ceil` sopra, e non
        // l'arrotondamento al più vicino.
        guard
            let lowI = GrowthRestriction.index(lowest.x, rounding: .down),
            let lowJ = GrowthRestriction.index(lowest.y, rounding: .down),
            let lowK = GrowthRestriction.index(lowest.z, rounding: .down),
            let highI = GrowthRestriction.index(highest.x, rounding: .up),
            let highJ = GrowthRestriction.index(highest.y, rounding: .up),
            let highK = GrowthRestriction.index(highest.z, rounding: .up)
        else { return nil }

        minimumI = Swift.max(lowI, 0)
        minimumJ = Swift.max(lowJ, 0)
        minimumK = Swift.max(lowK, 0)
        maximumI = Swift.min(highI, geometry.columnCount - 1)
        maximumJ = Swift.min(highJ, geometry.rowCount - 1)
        maximumK = Swift.min(highK, geometry.sliceCount - 1)
        guard minimumI <= maximumI, minimumJ <= maximumJ, minimumK <= maximumK else { return nil }

        self.box = box
        self.geometry = geometry
    }

    /// Indica se il voxel può essere assegnato.
    ///
    /// Due controlli e non uno: gli indici scartano in poche istruzioni la stragrande maggioranza
    /// dei voxel, e solo per i pochi rimasti si paga la trasformazione in millimetri. Fare solo
    /// il secondo costerebbe nove moltiplicazioni per ogni vicino di ogni voxel assegnato; fare
    /// solo il primo assegnerebbe, su un volume ruotato, voxel fuori dal riquadro disegnato.
    func allows(i: Int, j: Int, k: Int) -> Bool {
        guard i >= minimumI, i <= maximumI,
            j >= minimumJ, j <= maximumJ,
            k >= minimumK, k <= maximumK
        else { return false }
        return box.contains(geometry.patientPoint(i: i, j: j, k: k))
    }

    /// Quanti voxel la scatola di indici racchiude: serve a stimare il costo prima di partire.
    var enclosedVoxelCount: Int {
        (maximumI - minimumI + 1) * (maximumJ - minimumJ + 1) * (maximumK - minimumK + 1)
    }

    private static func index(_ value: Double, rounding rule: FloatingPointRoundingRule) -> Int? {
        guard value.isFinite else { return nil }
        let rounded = value.rounded(rule)
        // Un riquadro lontanissimo dal volume produce un indice che `Int` non rappresenta, e
        // convertirlo sarebbe un trap: si limita prima, poi si converte.
        guard rounded >= -1e15, rounded <= 1e15 else { return nil }
        return Int(rounded)
    }
}
