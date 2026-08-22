import DICOMCore
import Foundation

// Il riquadro di lettura: si guarda una parte del volume senza toccarlo.
//
// # Perché non è «ritaglia e ricampiona»
//
// Perché sono due cose diverse che si somigliano solo a parole. Ritagliare produce un **volume
// nuovo**: campioni copiati, geometria nuova, e da quel momento è quello il dato su cui si
// lavora. Serve quando si vuole consegnare un settore a un laboratorio, o alleggerire un caso
// enorme, ed è giusto che esista — ma è una modifica, e una modifica di quelle che l'esame se
// lo porta dietro.
//
// Guardare una parte è un'altra faccenda. Si vuole togliere di mezzo la mandibola per vedere il
// seno, o la guancia per arrivare alla cresta, e si vuole che l'esame resti quello che è: chiuso
// il programma, il volume è intero. Nessun campione toccato, niente da annullare, niente che
// finisca in archivio.
//
// Da qui la regola: questo riquadro vive **soltanto nel disegno**. Non entra nell'istantanea del
// piano — non c'è niente da annullare, perché niente è cambiato — e non si salva con l'esame:
// riaprirlo con un ritaglio attivo, e non sapere perché metà cranio non c'è, sarebbe il difetto
// che questa funzione esiste per non avere.
//
// # Come arriva allo shader
//
// Come tre righe di una matrice. Il riquadro è allineato agli assi **Patient**, mentre lo shader
// cammina in coordinate texture, e le due terne coincidono solo se il volume non è ruotato — su
// una CBCT capita quasi sempre, quasi non è mai. Invece di approssimare con il riquadro
// contenitore, che su un volume inclinato lascerebbe dentro una fetta di quel che si voleva
// togliere, si porta ogni campione nelle coordinate del riquadro: tre prodotti scalari, e il
// campione è dentro se tutte e tre stanno fra zero e uno.
//
// Quando non c'è nulla da ritagliare le tre righe valgono «sempre dentro», e lo shader non ha
// bisogno di sapere se il riquadro è attivo: nessun ramo, nessuna uniforme in più, e la strada
// senza ritaglio costa esattamente quanto prima.
public struct ClipBox: Hashable, Sendable, Codable {

    public var minMM: Vec3
    public var maxMM: Vec3
    /// Se il riquadro limita davvero la vista. Spento, il volume si vede intero.
    public var isActive: Bool

    public init(minMM: Vec3, maxMM: Vec3, isActive: Bool = false) {
        self.minMM = Vec3(
            Swift.min(minMM.x, maxMM.x),
            Swift.min(minMM.y, maxMM.y),
            Swift.min(minMM.z, maxMM.z))
        self.maxMM = Vec3(
            Swift.max(minMM.x, maxMM.x),
            Swift.max(minMM.y, maxMM.y),
            Swift.max(minMM.z, maxMM.z))
        self.isActive = isActive
    }

    /// Il riquadro che contiene tutto il volume, spento.
    public static func wholeVolume(_ geometry: VolumeGeometry) -> ClipBox {
        let corners = geometry.boundingBoxCornersMM
        guard let first = corners.first else {
            return ClipBox(minMM: .zero, maxMM: .zero)
        }
        var lowest = first
        var highest = first
        for corner in corners {
            lowest = Vec3(
                Swift.min(lowest.x, corner.x),
                Swift.min(lowest.y, corner.y),
                Swift.min(lowest.z, corner.z))
            highest = Vec3(
                Swift.max(highest.x, corner.x),
                Swift.max(highest.y, corner.y),
                Swift.max(highest.z, corner.z))
        }
        return ClipBox(minMM: lowest, maxMM: highest)
    }

    public var sizeMM: Vec3 { maxMM - minMM }
    public var centerMM: Vec3 { (minMM + maxMM) * 0.5 }

    /// Vero se il riquadro non racchiude niente su almeno un asse.
    public var isEmpty: Bool {
        sizeMM.x <= 0 || sizeMM.y <= 0 || sizeMM.z <= 0
    }

    /// Vero se il punto è dentro il riquadro — o se il riquadro non sta limitando niente.
    public func contains(_ pointMM: Vec3) -> Bool {
        guard isActive, !isEmpty else { return true }
        return pointMM.x >= minMM.x && pointMM.x <= maxMM.x
            && pointMM.y >= minMM.y && pointMM.y <= maxMM.y
            && pointMM.z >= minMM.z && pointMM.z <= maxMM.z
    }

    /// Lo stesso riquadro, ristretto a non uscire dal volume.
    public func clamped(to geometry: VolumeGeometry) -> ClipBox {
        let bounds = Self.wholeVolume(geometry)
        var copy = self
        copy.minMM = Vec3(
            Swift.min(Swift.max(minMM.x, bounds.minMM.x), bounds.maxMM.x),
            Swift.min(Swift.max(minMM.y, bounds.minMM.y), bounds.maxMM.y),
            Swift.min(Swift.max(minMM.z, bounds.minMM.z), bounds.maxMM.z))
        copy.maxMM = Vec3(
            Swift.max(Swift.min(maxMM.x, bounds.maxMM.x), bounds.minMM.x),
            Swift.max(Swift.min(maxMM.y, bounds.maxMM.y), bounds.minMM.y),
            Swift.max(Swift.min(maxMM.z, bounds.maxMM.z), bounds.minMM.z))
        return copy
    }

    /// Le tre righe che portano una coordinata **texture** nelle coordinate del riquadro.
    ///
    /// Il campione è dentro quando tutte e tre le componenti stanno fra zero e uno.
    ///
    /// - Returns: le righe «sempre dentro» — `(0,0,0, 0.5)` — quando il riquadro è spento, vuoto,
    ///   o quando la trasformazione non è invertibile. Chi disegna non deve distinguere il caso:
    ///   un ritaglio che non ritaglia lascia passare tutto, ed è esattamente ciò che serve.
    public func textureRows(patientToTexture: Transform3D) -> [SIMD4<Float>] {
        guard isActive, !isEmpty, let toPatient = patientToTexture.inverse else {
            return Self.passThroughRows
        }

        let span = sizeMM
        let x = toPatient.columnX
        let y = toPatient.columnY
        let z = toPatient.columnZ
        let origin = toPatient.origin

        // Riga i: la componente i del punto Patient, riportata a zero-uno sul lato i del
        // riquadro. Le colonne della trasformazione danno i coefficienti, l'origine il termine
        // noto.
        func row(_ index: Int) -> SIMD4<Float> {
            let axis = Vec3(x[index], y[index], z[index])
            let low = minMM[index]
            let width = span[index]
            guard width > 0 else { return SIMD4<Float>(0, 0, 0, 0.5) }
            return SIMD4<Float>(
                Float(axis.x / width),
                Float(axis.y / width),
                Float(axis.z / width),
                Float((origin[index] - low) / width))
        }
        return [row(0), row(1), row(2)]
    }

    /// Righe che lasciano passare qualunque campione: mezzo, che sta fra zero e uno.
    public static let passThroughRows: [SIMD4<Float>] = [
        SIMD4<Float>(0, 0, 0, 0.5),
        SIMD4<Float>(0, 0, 0, 0.5),
        SIMD4<Float>(0, 0, 0, 0.5),
    ]
}

extension Vec3 {
    /// Componente per indice, per scrivere le tre righe in un ciclo invece che tre volte.
    subscript(index: Int) -> Double {
        switch index {
        case 0: return x
        case 1: return y
        default: return z
        }
    }
}
