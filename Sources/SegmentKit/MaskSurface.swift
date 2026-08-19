import DICOMCore
import Foundation
import MeshKit

// Dalla maschera alla superficie.
//
// # Perché passare da una mesh invece di colorare i voxel
//
// La via ovvia per mostrare una segmentazione è dipingere i voxel selezionati sopra le fette,
// e richiede una texture di maschera dentro lo shader MPR. È la via giusta a lungo termine, ed
// è anche l'unica che in questo ambiente non si può verificare in alcun modo: il codice Metal
// qui non compila e non gira.
//
// La superficie invece si costruisce e si prova con `swift test`, e arriva sullo schermo per
// una strada che nel programma **funziona già**: `MeshSlicer` interseca una mesh con un piano
// e ne disegna il contorno, che è come compare la scansione intraorale. Una segmentazione
// mostrata come contorno dice le stesse cose che direbbe una colorazione — dove passa il
// confine, se ha buchi, se ha isole — ed è per giunta più leggibile sopra l'anatomia, perché
// non la copre.
//
// # Il campionamento, e perché non si usa la griglia del volume
//
// Marching cubes su un volume CBCT intero produrrebbe milioni di triangoli e minuti di attesa.
// Si lavora quindi sulla sola **scatola dei voxel selezionati**, con un passo scelto da chi
// chiama; il valore predefinito è il passo del volume, ma su una segmentazione ampia
// raddoppiarlo divide per otto il costo e toglie dettaglio che a schermo non si vedrebbe.

public enum MaskSurface: Sendable {

    /// Passo di campionamento oltre il quale non si scende, in millimetri.
    ///
    /// Sotto il decimo di millimetro non c'è informazione: la CBCT più fine ha voxel di 0,075 mm,
    /// e un passo più fitto interpolerebbe soltanto sé stesso a un costo che cresce col cubo.
    public static let minimumSpacingMM: Double = 0.1

    /// Estrae la superficie che separa i voxel etichettati dal resto.
    ///
    /// - Parameters:
    ///   - mask: la maschera da cui estrarre.
    ///   - label: l'etichetta da isolare, o `nil` per «qualunque cosa non sia sfondo».
    ///   - spacingMM: passo della griglia di campionamento. `nil` prende il lato più piccolo del
    ///     voxel, che è la scelta che non perde nulla.
    ///   - name: il nome che la mesh porterà nell'elenco degli oggetti.
    ///
    /// - Returns: `nil` quando la maschera è vuota per quell'etichetta, o quando la regione
    ///   richiederebbe una griglia oltre `FieldGrid.maximumCellCount`. Sono due «no» diversi e
    ///   il chiamante li distingue guardando `isEmpty(mask, label:)`: restituire una mesh vuota
    ///   in entrambi i casi farebbe passare per «niente da mostrare» un rifiuto per dimensione.
    public static func mesh(
        of mask: VolumeMask,
        label: SegmentLabel? = nil,
        spacingMM: Double? = nil,
        name: String = "Segmentazione"
    ) -> Mesh? {
        guard let bounds = mask.voxelBounds(label: label) else { return nil }

        let geometry = mask.geometry
        let voxel = geometry.spacingMM
        let requested = spacingMM ?? Swift.min(voxel.x, Swift.min(voxel.y, voxel.z))
        guard requested.isFinite else { return nil }
        let step = Swift.max(requested, minimumSpacingMM)

        // La scatola in millimetri Patient si ricava dagli **otto vertici** della scatola di
        // voxel, non dai due estremi: la matrice DICOM ruota e riflette, e con un volume non
        // assiale i due estremi in indici non sono i due estremi in millimetri. Prendere solo
        // quelli taglierebbe via mezza segmentazione su una CBCT acquisita di sbieco.
        var minimum = Vec3(.infinity, .infinity, .infinity)
        var maximum = Vec3(-.infinity, -.infinity, -.infinity)
        for i in [bounds.min.0, bounds.max.0] {
            for j in [bounds.min.1, bounds.max.1] {
                for k in [bounds.min.2, bounds.max.2] {
                    let corner = geometry.patientPoint(i: i, j: j, k: k)
                    guard corner.isFinite else { return nil }
                    minimum = Vec3(
                        Swift.min(minimum.x, corner.x),
                        Swift.min(minimum.y, corner.y),
                        Swift.min(minimum.z, corner.z))
                    maximum = Vec3(
                        Swift.max(maximum.x, corner.x),
                        Swift.max(maximum.y, corner.y),
                        Swift.max(maximum.z, corner.z))
                }
            }
        }
        guard minimum.isFinite, maximum.isFinite else { return nil }

        // Mezzo voxel di margine per lato, perché la scatola degli indici arriva ai **centri**
        // dei voxel estremi mentre l'oggetto arriva alle loro facce.
        //
        // Non serve a chiudere la superficie: quello lo fa già `paddingCells` di `FieldGrid`,
        // che aggiunge comunque una corona di campioni esterni. Una mutazione che toglie questo
        // margine infatti non fa fallire i test, e vale la pena scriverlo invece di lasciar
        // credere il contrario — è un affinamento sotto il voxel, non una garanzia.
        let margin = Vec3(voxel.x, voxel.y, voxel.z) * 0.5
        guard
            let grid = FieldGrid(
                boundsMinMM: minimum - margin,
                boundsMaxMM: maximum + margin,
                spacingMM: step)
        else { return nil }

        // Convenzione di `MarchingCubes`: dentro è **minore** dell'isolivello. Si campiona
        // −1 dentro e +1 fuori, con isolivello 0, così il cambio di segno cade a metà fra un
        // voxel selezionato e il suo vicino che non lo è.
        var field = ScalarField(grid: grid, initialValue: 1)
        var z = 0
        while z < grid.countZ {
            var y = 0
            while y < grid.countY {
                var x = 0
                while x < grid.countX {
                    let pointMM = Vec3(
                        grid.originMM.x + Double(x) * grid.spacingMM,
                        grid.originMM.y + Double(y) * grid.spacingMM,
                        grid.originMM.z + Double(z) * grid.spacingMM)
                    if contains(mask, pointMM: pointMM, label: label) {
                        field.setValue(-1, x: x, y: y, z: z)
                    }
                    x += 1
                }
                y += 1
            }
            z += 1
        }

        let mesh = MarchingCubes.surface(from: field, isoLevel: 0, name: name)
        return mesh.triangles.isEmpty ? nil : mesh
    }

    /// Vero quando la maschera non seleziona nemmeno un voxel per quell'etichetta.
    ///
    /// Serve a chi riceve `nil` da `mesh(of:...)` per sapere quale dei due «no» ha ricevuto.
    public static func isEmpty(_ mask: VolumeMask, label: SegmentLabel? = nil) -> Bool {
        mask.voxelBounds(label: label) == nil
    }

    /// Vero se il voxel **più vicino** al punto è selezionato.
    ///
    /// Al vicino più prossimo e non interpolando: le etichette sono nomi, non quantità, e la
    /// media fra l'etichetta 1 e l'etichetta 3 non è l'etichetta 2 — sarebbe un terzo oggetto
    /// inventato dall'aritmetica.
    private static func contains(
        _ mask: VolumeMask, pointMM: Vec3, label: SegmentLabel?
    ) -> Bool {
        let voxel = mask.geometry.voxelPoint(fromPatient: pointMM)
        guard voxel.isFinite else { return false }
        let i = Int(voxel.x.rounded())
        let j = Int(voxel.y.rounded())
        let k = Int(voxel.z.rounded())
        let found = mask.label(i: i, j: j, k: k)
        guard found != VolumeMask.background else { return false }
        guard let label else { return true }
        return found == label
    }
}
