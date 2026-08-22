import DICOMCore
import Foundation
import MeshKit

// La superficie del canale alveolare, come tubo.
//
// # Perché serve una mesh e non basta la polilinea
//
// Perché nel riquadro 3D il nervo non c'era. Impianti, barre, denti, arcata: tutto disegnato,
// il canale no — e uno lo traccia proprio per guardarlo insieme agli impianti, che è la sola
// domanda che il 3D risponde meglio delle sezioni: *l'impianto passa sopra il canale o dentro?*
// Il motore per rispondere c'era da sempre, `SafetyAnalysis` calcolava già le distanze, e la
// vista che le avrebbe mostrate non disegnava l'oggetto di cui parlano.
//
// Il tubo, e non una linea spessa, per la stessa ragione della barra sulla panorex: la domanda è
// quanto osso resta fra impianto e canale, e una linea sottile farebbe sembrare spazio quello
// che è raggio del nervo.
public enum NerveMesh: Sendable {

    /// Passo di ricampionamento del percorso, in millimetri.
    ///
    /// Mezzo millimetro: sotto la dimensione di un voxel di CBCT dentale, quindi il tubo segue
    /// la spline senza inventare curvatura che i nodi non contengono.
    public static let defaultSpacingMM: Double = 0.5

    /// La superficie del canale: un tubo poligonale lungo il percorso campionato.
    ///
    /// Il raggio segue quello dei nodi, che si interpola lungo il percorso: un canale si
    /// restringe verso il foro mentoniero, e disegnarlo di spessore costante direbbe che c'è
    /// meno osso di quanto ce n'è proprio dove l'impianto ci arriva più vicino.
    ///
    /// - Returns: una mesh vuota per un canale con meno di due nodi, che percorso non è.
    public static func surface(
        of canal: NerveCanal,
        segments: Int = 16,
        spacingMM: Double = defaultSpacingMM,
        name: String? = nil
    ) -> Mesh {
        let label = name ?? canal.localizedName
        let samples = canal.resampled(spacingMM: spacingMM)
        guard samples.count >= 2 else {
            return Mesh(verticesMM: [], triangles: [], name: label)
        }

        let sides = Swift.max(segments, 3)

        // Una terna sola per tutto il canale, come per la barra: una per campione resterebbe
        // ruotata a caso da un campione al successivo, e le fasce si torcerebbero. Si prende la
        // direzione complessiva, che su un canale mandibolare — un arco largo, mai un cappio —
        // non è mai parallela alla tangente locale al punto da degenerare.
        let overall =
            (samples[samples.count - 1].positionMM - samples[0].positionMM).normalized
            ?? Vec3(1, 0, 0)
        let frame = perpendicularFrame(to: overall)

        var vertices: [Vec3] = []
        var triangles: [Triangle] = []
        vertices.reserveCapacity(samples.count * sides)
        triangles.reserveCapacity((samples.count - 1) * sides * 2)

        for sample in samples {
            for side in 0..<sides {
                let angle = 2 * Double.pi * Double(side) / Double(sides)
                let offset =
                    frame.right * (Foundation.cos(angle) * sample.radiusMM)
                    + frame.up * (Foundation.sin(angle) * sample.radiusMM)
                vertices.append(sample.positionMM + offset)
            }
        }

        for index in 0..<(samples.count - 1) {
            let ring = index * sides
            let nextRing = (index + 1) * sides
            for side in 0..<sides {
                let next = (side + 1) % sides
                // L'ordine manda la normale **fuori**. La prima stesura era invertita, come già
                // successo su `ImplantMesh`, e il conteggio degli spigoli non se ne accorgeva:
                // un tubo rovesciato è chiuso esattamente quanto uno diritto. Se ne accorge la
                // normale, e a schermo si sarebbe visto un canale nero — l'illuminazione diffusa
                // del riquadro 3D moltiplica per un prodotto scalare negativo.
                triangles.append(
                    Triangle(a: ring + side, b: nextRing + next, c: nextRing + side))
                triangles.append(
                    Triangle(a: ring + side, b: ring + next, c: nextRing + next))
            }
        }

        return Mesh(verticesMM: vertices, triangles: triangles, name: label)
    }

    /// Due versori perpendicolari alla direzione e fra loro.
    ///
    /// Per un tubo la scelta è libera — girando attorno all'asse la superficie è la stessa — e
    /// si prende l'asse coordinato meno allineato, così la differenza non degenera qualunque sia
    /// l'inclinazione del canale.
    private static func perpendicularFrame(to axis: Vec3) -> (right: Vec3, up: Vec3) {
        let candidates = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        var chosen = candidates[0]
        var smallest = Double.infinity
        for candidate in candidates {
            let alignment = Swift.abs(candidate.dot(axis))
            if alignment < smallest {
                smallest = alignment
                chosen = candidate
            }
        }
        let right = (chosen - axis * axis.dot(chosen)).normalized ?? Vec3(1, 0, 0)
        let up = axis.cross(right).normalized ?? Vec3(0, 1, 0)
        return (right, up)
    }
}
