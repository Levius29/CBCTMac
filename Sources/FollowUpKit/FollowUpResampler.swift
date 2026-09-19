import DICOMCore
import Foundation

// Portare l'esame di confronto sulla griglia del riferimento, e farlo una volta sola.
//
// # Perché una volta sola, e perché conta
//
// Ogni ricampionamento è un'interpolazione, e un'interpolazione è una perdita: i bordi si
// ammorbidiscono e il rumore si correla. Ricampionare a ogni cambio di vista — una volta per
// l'assiale, una per il coronale, una per ogni fotogramma del lampeggio — significa accumulare
// perdite diverse in riquadri che si stanno confrontando, cioè introdurre differenze prodotte
// dal programma proprio dove si cercano differenze prodotte dal paziente.
//
// Si ricampiona una volta, sulla griglia del riferimento, e da lì in poi i due volumi si
// scorrono con le stesse coordinate. È anche la ragione per cui il risultato è un `Volume`
// normale: da quel momento MPR, panorex, misure e istantanee funzionano su di lui senza sapere
// niente di registrazioni.
//
// # Il valore che si scrive dove non c'è dato
//
// Fuori dal campo acquisito il volume di confronto non ha nessun valore, e bisogna scriverci
// qualcosa. Scriverci «aria» sarebbe comodo e sarebbe una bugia sottile: in una vista affiancata
// l'assenza di dato diventerebbe indistinguibile dall'assenza di osso, cioè dal riassorbimento
// che si sta cercando. Qui si scrive il minimo dell'esame — che è aria, quindi la vista resta
// leggibile — e si dichiara **quanto** del volume sia stato riempito così, perché quella è
// l'informazione che permette di non confondere le due cose.

/// L'esame di confronto portato sulla griglia del riferimento, e quanto ne è rimasto fuori.
public struct AlignedFollowUp: Sendable {

    /// L'esame di confronto ricampionato **una volta sola** sulla griglia del riferimento.
    ///
    /// Conserva `rescaleSlope`, `rescaleIntercept` e l'unità del volume d'origine: i valori
    /// restano quelli del suo apparecchio, e non diventano confrontabili con quelli del
    /// riferimento per il solo fatto di stare sulla stessa griglia (Contratto 4).
    public let volume: Volume
    /// La posa usata per portarcelo.
    public let pose: RigidPose
    /// Frazione dei voxel che ha davvero un dato sotto.
    public let coverage: Double
    /// Il valore grezzo scritto dove il dato non c'è.
    public let missingRawValue: Int16

    public init(volume: Volume, pose: RigidPose, coverage: Double, missingRawValue: Int16) {
        self.volume = volume
        self.pose = pose
        self.coverage = coverage
        self.missingRawValue = missingRawValue
    }
}

/// Il ricampionamento dell'esame di confronto sulla griglia del riferimento.
// non-ancora-collegato: il modulo del confronto nel tempo è verificato, la sua schermata non c'è
// ancora. Vedi docs/follow-up.md e la fase 7 nel README.
public enum FollowUpResampler: Sendable {

    /// Ricampiona `followUp` sulla griglia indicata, secondo la posa trovata dalla registrazione.
    ///
    /// L'interpolazione è trilineare. Non è la scelta giusta per **misurare** — una statistica
    /// letta su valori interpolati è una media plausibile e falsa, Contratto 3 — ed è la scelta
    /// giusta per **guardare**, che è ciò a cui questo volume serve. Le misure si prendono
    /// sull'esame originale, portandoci il punto con la posa: è un giro in più e non perde niente.
    public static func aligned(_ followUp: Volume, onto grid: VolumeGeometry, pose: RigidPose)
        throws -> AlignedFollowUp
    {
        let source = followUp.geometry
        let toVoxel = source.patientToVoxel.concatenating(pose.transform)
        let columns = source.columnCount
        let rows = source.rowCount
        let slices = source.sliceCount
        let maxI = Double(columns - 1)
        let maxJ = Double(rows - 1)
        let maxK = Double(slices - 1)
        let missing = followUp.rawValueRange.lowerBound

        var samples = [Int16](repeating: missing, count: grid.voxelCount)
        var covered = 0

        followUp.withUnsafeSamples { buffer in
            for k in 0..<grid.sliceCount {
                for j in 0..<grid.rowCount {
                    let destinationRow = (k * grid.rowCount + j) * grid.columnCount
                    for i in 0..<grid.columnCount {
                        let point = grid.patientPoint(i: i, j: j, k: k)
                        let v = toVoxel.apply(toPoint: point)
                        guard v.isFinite,
                            v.x >= 0, v.y >= 0, v.z >= 0,
                            v.x <= maxI, v.y <= maxJ, v.z <= maxK
                        else { continue }

                        let fi = v.x.rounded(.down)
                        let fj = v.y.rounded(.down)
                        let fk = v.z.rounded(.down)
                        let i0 = Int(fi)
                        let j0 = Int(fj)
                        let k0 = Int(fk)
                        let i1 = min(i0 + 1, columns - 1)
                        let j1 = min(j0 + 1, rows - 1)
                        let k1 = min(k0 + 1, slices - 1)
                        let tx = v.x - fi
                        let ty = v.y - fj
                        let tz = v.z - fk

                        func at(_ a: Int, _ b: Int, _ c: Int) -> Double {
                            Double(buffer[(c * rows + b) * columns + a])
                        }

                        let c00 = at(i0, j0, k0) * (1 - tx) + at(i1, j0, k0) * tx
                        let c10 = at(i0, j1, k0) * (1 - tx) + at(i1, j1, k0) * tx
                        let c01 = at(i0, j0, k1) * (1 - tx) + at(i1, j0, k1) * tx
                        let c11 = at(i0, j1, k1) * (1 - tx) + at(i1, j1, k1) * tx
                        let c0 = c00 * (1 - ty) + c10 * ty
                        let c1 = c01 * (1 - ty) + c11 * ty
                        let value = c0 * (1 - tz) + c1 * tz

                        samples[destinationRow + i] = Int16(clamping: Int(value.rounded()))
                        covered += 1
                    }
                }
            }
        }

        let volume = try Volume(
            geometry: grid,
            samples: samples,
            rescaleSlope: followUp.rescaleSlope,
            rescaleIntercept: followUp.rescaleIntercept,
            densityUnit: followUp.densityUnit
        )
        let coverage = grid.voxelCount > 0 ? Double(covered) / Double(grid.voxelCount) : 0
        return AlignedFollowUp(
            volume: volume,
            pose: pose,
            coverage: coverage,
            missingRawValue: missing
        )
    }
}
