import DICOMCore
import Foundation

// Le copie rimpicciolite su cui la registrazione comincia a cercare.
//
// # Perché non si registra subito alla risoluzione piena
//
// Una discesa numerica segue la pendenza che ha sotto, e su un volume a piena risoluzione la
// pendenza la fanno i dettagli: la trabecolatura, il rumore, il bordo di un'otturazione. Partendo
// da lì la discesa si infila nel primo avvallamento che incontra — tipicamente un dente accanto a
// quello giusto — e ci si ferma, con un valore della metrica ottimo e una registrazione sbagliata
// di sei millimetri. È il difetto peggiore che questo modulo possa avere, perché non si vede: il
// programma dichiara di aver finito.
//
// Rimpicciolendo il volume di quattro volte quei dettagli spariscono e resta la forma
// complessiva — mandibola, mascella, colonna d'aria delle vie aeree. Su quella la discesa trova
// l'unico avvallamento profondo che c'è, cioè la posizione giusta a meno di un millimetro. Da lì
// si raddoppia la risoluzione e si stringe. Tre livelli — 4, 2, 1 — sono quelli che usa
// chiunque faccia questo mestiere, e non è un caso: sotto il quarto la testa non si riconosce
// più, sopra non si guadagna niente.
//
// # Perché la media di blocco e non il sottocampionamento
//
// Prendere un voxel ogni quattro è più veloce e produce aliasing: una corticale sottile compare
// o sparisce a seconda di dove cade la griglia, e la metrica si mette a oscillare per ragioni
// che non hanno niente a che vedere con l'allineamento. La media sul blocco costa un passaggio
// sui dati e toglie il problema alla radice.

/// Le copie a risoluzione ridotta di un volume, per la ricerca a più livelli.
// non-ancora-collegato: serve alla registrazione fra esami, la cui schermata non c'è ancora.
// Vedi docs/follow-up.md e la fase 7 nel README.
public enum VolumePyramid: Sendable {

    /// Fattori di riduzione usati per difetto: grossolano, medio, piena risoluzione.
    public static let defaultShrinkFactors: [Int] = [4, 2, 1]

    /// Copia ridotta di `factor` lungo ogni asse, con media sul blocco.
    ///
    /// La geometria risultante è coerente con l'originale nello spazio Patient: il passo cresce
    /// di `factor`, e l'origine si sposta al **centro del primo blocco**, che è il punto che il
    /// nuovo voxel `(0,0,0)` rappresenta davvero. Sbagliare quest'ultimo mezzo blocco è il modo
    /// classico di introdurre uno scarto sistematico di mezzo voxel per livello, che a quattro
    /// livelli fa più di un millimetro e nessuno sa da dove venga.
    public static func reduced(_ volume: Volume, by factor: Int) throws -> Volume {
        guard factor >= 1 else { throw VolumeRegistrationError.invalidShrinkFactor(factor) }
        guard factor > 1 else { return volume }

        let source = volume.geometry
        let columns = max(source.columnCount / factor, 1)
        let rows = max(source.rowCount / factor, 1)
        let slices = max(source.sliceCount / factor, 1)

        let offset = Double(factor - 1) * 0.5
        let originMM = source.patientPoint(fromVoxel: Vec3(offset, offset, offset))

        let geometry = try VolumeGeometry(
            columnCount: columns,
            rowCount: rows,
            sliceCount: slices,
            columnSpacingMM: source.columnSpacingMM * Double(factor),
            rowSpacingMM: source.rowSpacingMM * Double(factor),
            sliceSpacingMM: source.sliceSpacingMM * Double(factor),
            orientation: source.orientation,
            originMM: originMM
        )

        var samples = [Int16](repeating: 0, count: columns * rows * slices)
        let sourceColumns = source.columnCount
        let sourceRows = source.rowCount
        let sourceSlices = source.sliceCount

        volume.withUnsafeSamples { buffer in
            for k in 0..<slices {
                let k0 = k * factor
                let k1 = min(k0 + factor, sourceSlices)
                for j in 0..<rows {
                    let j0 = j * factor
                    let j1 = min(j0 + factor, sourceRows)
                    let destinationRow = (k * rows + j) * columns
                    for i in 0..<columns {
                        let i0 = i * factor
                        let i1 = min(i0 + factor, sourceColumns)
                        var total = 0
                        var count = 0
                        for kk in k0..<k1 {
                            for jj in j0..<j1 {
                                let base = (kk * sourceRows + jj) * sourceColumns
                                for ii in i0..<i1 {
                                    total += Int(buffer[base + ii])
                                    count += 1
                                }
                            }
                        }
                        guard count > 0 else { continue }
                        let mean = Double(total) / Double(count)
                        samples[destinationRow + i] = Int16(clamping: Int(mean.rounded()))
                    }
                }
            }
        }

        return try Volume(
            geometry: geometry,
            samples: samples,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept,
            densityUnit: volume.densityUnit
        )
    }

    /// I fattori messi in ordine dal più grossolano al più fine, senza ripetizioni.
    ///
    /// Un elenco fuori ordine — `[1, 2, 4]` — non dà errore e produce il difetto che i livelli
    /// esistono per evitare: si parte fini, ci si infila nel minimo sbagliato, e i due livelli
    /// successivi lo confermano con sempre meno dettaglio.
    public static func orderedFactors(_ factors: [Int]) throws -> [Int] {
        guard !factors.isEmpty else { throw VolumeRegistrationError.invalidShrinkFactor(0) }
        for factor in factors where factor < 1 {
            throw VolumeRegistrationError.invalidShrinkFactor(factor)
        }
        return Array(Set(factors)).sorted(by: >)
    }
}
