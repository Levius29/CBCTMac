import DICOMCore
import Foundation

// Spostare e ruotare un dente protesico.
//
// # Perché non basta riusare quella dell'impianto
//
// Perché le due cose hanno una geometria diversa e un vincolo diverso. Un impianto è un solido
// di rotazione: gira attorno al proprio asse senza cambiare, e le sue maniglie sono due — testa
// e apice — che lo inclinano tenendo fermo l'altro estremo. Un dente è una scatola: **ha** un
// orientamento attorno al proprio asse, quello lo prende dalla curva d'arcata, e le sue due
// libertà utili sono dove sta e come è inclinato.
//
// # Il verso della rotazione
//
// Trascinando la corona il dente ruota attorno all'**apice**, e non attorno al centro. È il
// gesto che si vuole: si aggiusta l'inclinazione di un elemento guardando dove emerge in bocca,
// e l'apice sta dove l'osso lo permette. Ruotando attorno al centro si sposterebbero
// contemporaneamente corona e radice, e per rimettere a posto la radice servirebbe un secondo
// gesto che disfa metà del primo.

public enum ToothGrip: Hashable, Sendable {
    /// La superficie masticante. Trascinandola il dente **ruota attorno all'apice**.
    case crown
    /// Il corpo. Trascinandolo il dente **trasla**.
    case body
    /// L'estremità apicale. Trascinandola il dente **ruota attorno all'occlusale**.
    case apex
}

public enum ToothManipulation {

    /// Frazione dell'altezza occupata da ciascuna maniglia d'estremità.
    ///
    /// Meno che sull'impianto — un terzo contro un quarto — perché una corona è alta sette
    /// millimetri contro i dieci di un impianto, e sotto i due millimetri una maniglia non si
    /// prende.
    public static let handleFraction = 0.33

    /// Quale parte del dente cade sotto un punto Patient.
    ///
    /// - Parameter toleranceMM: quanto lontano dall'asse si può premere, in millimetri. Va
    ///   commisurato a quanto vale un pixel nel riquadro: altrimenti su una vista ingrandita il
    ///   dente si afferra da mezzo centimetro di distanza, e su una vista d'insieme non si
    ///   afferra affatto.
    public static func grip(
        at pointMM: Vec3, of tooth: ProstheticTooth, toleranceMM: Double
    ) -> ToothGrip? {
        let axis = tooth.axisMM
        let height = tooth.heightMM
        guard height > 0, pointMM.isFinite else { return nil }

        // Coordinate locali: quota lungo l'asse dall'occlusale verso l'apice, e distanza
        // dall'asse. Il centro della corona sta a metà altezza.
        let occlusal = tooth.occlusalCentreMM
        let relative = pointMM - occlusal
        let along = relative.dot(axis)
        let radial = (relative - axis * along).length

        // Il raggio di presa è metà della dimensione **maggiore** in sezione, più la
        // tolleranza: un molare superiore è largo 10,4 mm in un verso e 11 nell'altro, e
        // pretendere il verso giusto senza sapere da che parte lo si guarda renderebbe la presa
        // capricciosa a seconda del riquadro.
        let reach = Swift.max(tooth.widthMM, tooth.depthMM) * 0.5 + toleranceMM
        guard radial <= reach else { return nil }
        guard along >= -toleranceMM, along <= height + toleranceMM else { return nil }

        let handle = height * handleFraction
        if along <= handle { return .crown }
        if along >= height - handle { return .apex }
        return .body
    }

    /// Trasla il dente portando il suo centro nel punto indicato.
    public static func moved(_ tooth: ProstheticTooth, toMM pointMM: Vec3) -> ProstheticTooth {
        guard pointMM.isFinite else { return tooth }
        var moved = tooth
        moved.positionMM = pointMM
        return moved
    }

    /// Trasla il dente di uno scostamento.
    public static func translated(_ tooth: ProstheticTooth, byMM delta: Vec3) -> ProstheticTooth {
        guard delta.isFinite else { return tooth }
        var moved = tooth
        moved.positionMM = tooth.positionMM + delta
        return moved
    }

    /// Inclina il dente puntando la **corona** verso un punto, tenendo fermo l'apice.
    public static func tilted(_ tooth: ProstheticTooth, crownTowards pointMM: Vec3)
        -> ProstheticTooth
    {
        let apex = tooth.positionMM + tooth.axisMM * (tooth.heightMM * 0.5)
        guard let direction = (apex - pointMM).normalized else { return tooth }
        var turned = tooth
        turned.axisMM = direction
        // L'apice resta dov'era: il centro si ricolloca a mezza altezza da lì, lungo l'asse
        // nuovo. Lasciare fermo il centro farebbe scivolare l'apice, che è ciò che questo
        // gesto promette di non fare.
        turned.positionMM = apex - direction * (tooth.heightMM * 0.5)
        return turned
    }

    /// Inclina il dente puntando l'**apice** verso un punto, tenendo ferma la corona.
    public static func tilted(_ tooth: ProstheticTooth, apexTowards pointMM: Vec3)
        -> ProstheticTooth
    {
        let occlusal = tooth.occlusalCentreMM
        guard let direction = (pointMM - occlusal).normalized else { return tooth }
        var turned = tooth
        turned.axisMM = direction
        turned.positionMM = occlusal + direction * (tooth.heightMM * 0.5)
        return turned
    }

    /// Applica il trascinamento che corrisponde alla presa.
    ///
    /// - Parameters:
    ///   - toMM: dove sta il puntatore adesso.
    ///   - fromMM: dov'era all'inizio del passo. Serve alla sola traslazione, che è relativa: le
    ///     rotazioni puntano a un bersaglio assoluto e non hanno bisogno del punto precedente.
    public static func dragged(
        _ tooth: ProstheticTooth, grip: ToothGrip, toMM: Vec3, fromMM: Vec3
    ) -> ProstheticTooth {
        guard toMM.isFinite, fromMM.isFinite else { return tooth }
        switch grip {
        case .body:
            return translated(tooth, byMM: toMM - fromMM)
        case .crown:
            return tilted(tooth, crownTowards: toMM)
        case .apex:
            return tilted(tooth, apexTowards: toMM)
        }
    }
}
