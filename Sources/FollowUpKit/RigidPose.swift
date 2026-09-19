import DICOMCore
import Foundation

// La posa rigida, e la direzione in cui va letta.
//
// # Perché un tipo e non direttamente una `Transform3D`
//
// Una matrice 4×4 rigida sa dire *dove* finisce un punto e non sa dire *da dove* viene: la stessa
// matrice descrive «il paziente ha ruotato la testa di tre gradi» e «ho ruotato la griglia di tre
// gradi», che in un confronto fra due esami sono affermazioni opposte. Qui la direzione è scritta
// una volta sola, nel nome e nella documentazione, e non si ricostruisce leggendo il codice che
// la consuma.
//
// **La convenzione, una volta per tutte: la posa porta un punto dallo spazio Patient dell'esame
// di riferimento a quello dell'esame di confronto.** È la direzione che serve al
// ricampionamento — per ogni voxel della griglia del riferimento si va a cercare il valore
// nell'esame di confronto — ed è la stessa che usa ITK con i nomi `fixed` e `moving`, così chi
// arriva da lì non deve invertire niente a mente.
//
// # Perché rotazione attorno a un centro, e non attorno all'origine
//
// L'origine Patient di una CBCT sta in un angolo del volume, spesso fuori dall'anatomia. Una
// rotazione di due gradi attorno a quel punto sposta la mandibola di parecchi millimetri, quindi
// rotazione e traslazione diventano fortemente accoppiate e qualunque discesa numerica avanza a
// zig-zag. Con il centro nel mezzo del volume — o nel mezzo della regione scelta — i sei
// parametri sono quasi indipendenti, e la discesa ci arriva in un decimo dei passi.

/// Una posa rigida: tre rotazioni attorno a un centro fisso, più una traslazione.
///
/// Porta un punto dallo spazio Patient dell'esame di **riferimento** a quello dell'esame di
/// **confronto**. Non ha scala: due CBCT dello stesso paziente hanno la stessa taglia, e una
/// registrazione che si concede un fattore di scala nasconde gli errori invece di dichiararli.
// non-ancora-collegato: il modulo del confronto nel tempo è verificato, la sua schermata non c'è
// ancora. Vedi docs/follow-up.md e la fase 7 nel README.
public struct RigidPose: Hashable, Sendable, Codable {

    /// Rotazioni in radianti attorno agli assi Patient, applicate nell'ordine `x`, `y`, `z`.
    public var rotationRadians: Vec3
    /// Traslazione in millimetri Patient, applicata dopo la rotazione.
    public var translationMM: Vec3
    /// Centro della rotazione, in millimetri Patient dell'esame di riferimento.
    public var centerMM: Vec3

    public init(
        rotationRadians: Vec3 = .zero,
        translationMM: Vec3 = .zero,
        centerMM: Vec3 = .zero
    ) {
        self.rotationRadians = rotationRadians
        self.translationMM = translationMM
        self.centerMM = centerMM
    }

    /// Nessun movimento. Il punto di partenza di ogni registrazione.
    public static let identity = RigidPose()

    /// La sola parte rotatoria, come matrice `Rz · Ry · Rx` centrata nell'origine.
    public var rotation: Transform3D {
        let cx = Foundation.cos(rotationRadians.x)
        let sx = Foundation.sin(rotationRadians.x)
        let cy = Foundation.cos(rotationRadians.y)
        let sy = Foundation.sin(rotationRadians.y)
        let cz = Foundation.cos(rotationRadians.z)
        let sz = Foundation.sin(rotationRadians.z)
        return Transform3D(
            columnX: Vec3(cy * cz, cy * sz, -sy),
            columnY: Vec3(sx * sy * cz - cx * sz, sx * sy * sz + cx * cz, sx * cy),
            columnZ: Vec3(cx * sy * cz + sx * sz, cx * sy * sz - sx * cz, cx * cy)
        )
    }

    /// La matrice completa: riferimento → confronto, rotazione attorno a `centerMM` inclusa.
    public var transform: Transform3D {
        let r = rotation
        return Transform3D(
            columnX: r.columnX,
            columnY: r.columnY,
            columnZ: r.columnZ,
            origin: centerMM + translationMM - r.apply(toVector: centerMM)
        )
    }

    /// Dove finisce, nell'esame di confronto, un punto indicato sull'esame di riferimento.
    public func apply(toPoint p: Vec3) -> Vec3 {
        transform.apply(toPoint: p)
    }

    /// La matrice inversa: confronto → riferimento.
    ///
    /// È dichiarata opzionale perché lo è `Transform3D.inverse`; per una posa rigida non è mai
    /// `nil`, e fingere il contrario con un `try!` sarebbe l'unico modo di farla fallire davvero.
    public var inverseTransform: Transform3D? {
        transform.inverse
    }

    /// Di quanti millimetri la posa sposta il punto indicato.
    ///
    /// È il numero che dice quanto la registrazione ha lavorato: su due CBCT della stessa arcata
    /// prese a un anno di distanza sono tipicamente pochi millimetri, e uno spostamento di
    /// centinaia significa che i due esami non sono dello stesso paziente o non della stessa
    /// regione.
    public func displacementMM(atPoint p: Vec3) -> Double {
        (apply(toPoint: p) - p).length
    }
}
