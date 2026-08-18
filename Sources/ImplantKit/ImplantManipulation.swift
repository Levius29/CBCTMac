import DICOMCore

// Afferrare e muovere un impianto.
//
// # Il difetto che questo chiude
//
// Un impianto si posava con un clic e da lì restava dov'era: nessun modo di spostarlo, di
// inclinarlo o di affondarlo. Restavano due cursori per diametro e lunghezza. Su un programma di
// pianificazione implantare è l'interazione centrale — si sceglie il punto guardando la cresta e
// **poi** si aggiusta l'asse guardando il canale e la corticale — e non c'era.
//
// # Perché la matematica sta qui e non nella vista
//
// Perché è verificabile, e perché è la stessa in ogni riquadro. Lavora in **millimetri Patient**
// e non in pixel: la presa si decide dalla distanza dall'asse e dalla quota lungo l'asse, che
// sono grandezze dell'impianto e non dello schermo. Ne segue che assiale, coronale, sagittale,
// sezione trasversale e panorex si comportano tutti allo stesso modo senza una riga in più.

/// Parte dell'impianto che si è afferrata.
public enum ImplantGrip: Hashable, Sendable {
    /// La piattaforma protesica. Trascinandola l'impianto **ruota attorno all'apice**.
    case head
    /// Il corpo. Trascinandolo l'impianto **trasla**.
    case body
    /// L'apice. Trascinandolo l'impianto **ruota attorno alla piattaforma**.
    case apex
}

public enum ImplantManipulation {

    /// Frazione della lunghezza occupata da ciascuna maniglia d'estremità.
    ///
    /// Un quarto per parte, metà al corpo. Maniglie più piccole sarebbero difficili da prendere
    /// su un impianto corto — un 6 mm mostrato a schermo intero è comunque lungo poco — e più
    /// grandi non lascerebbero corpo da afferrare per traslare.
    public static let handleFraction = 0.25

    /// Quale parte dell'impianto cade sotto un punto Patient.
    ///
    /// - Parameter toleranceMM: quanto lontano dall'asse si può premere. Va commisurato a quanto
    ///   un pixel vale in millimetri nel riquadro, altrimenti su una vista molto ingrandita
    ///   l'impianto si afferrerebbe da mezzo centimetro di distanza e su una vista d'insieme non
    ///   si afferrerebbe affatto.
    public static func grip(
        at pointMM: Vec3, of implant: ImplantPlacement, toleranceMM: Double
    ) -> ImplantGrip? {
        let length = implant.model.lengthMM
        guard length > 0 else { return nil }

        let relative = pointMM - implant.platformMM
        let z = relative.dot(implant.axis)
        let radial = (relative - implant.axis * z).length

        // Il raggio dell'impianto **più** la tolleranza: si afferra il pezzo, non solo la linea
        // che lo attraversa. Con la sola tolleranza un impianto largo si potrebbe prendere solo
        // dal suo asse, che è l'unico punto in cui non si vede nulla da afferrare.
        let clampedZ = min(max(z, 0), length)
        let reach = implant.model.radius(atZ: clampedZ) + toleranceMM
        guard radial <= reach else { return nil }

        // Fuori dagli estremi si può stare quanto la tolleranza, non di più: sopra la piattaforma
        // c'è la corona da pianificare, e prendere l'impianto da lì sarebbe una sorpresa.
        guard z >= -toleranceMM, z <= length + toleranceMM else { return nil }

        if z <= length * handleFraction { return .head }
        if z >= length * (1 - handleFraction) { return .apex }
        return .body
    }

    /// Trasla l'impianto rigidamente.
    public static func moved(_ implant: ImplantPlacement, byMM offset: Vec3) -> ImplantPlacement {
        guard offset.isFinite else { return implant }
        var moved = implant
        moved.platformMM = implant.platformMM + offset
        return moved
    }

    /// Fa scorrere l'impianto **lungo il proprio asse**: positivo affonda.
    ///
    /// È un movimento distinto dalla traslazione libera perché è la regolazione che si fa più
    /// spesso — la profondità della piattaforma rispetto alla cresta — e farla trascinando in
    /// diagonale costringerebbe a correggere subito dopo la posizione trasversale.
    public static func slid(_ implant: ImplantPlacement, byMM depth: Double) -> ImplantPlacement {
        guard depth.isFinite else { return implant }
        var slid = implant
        slid.platformMM = implant.platformMM + implant.axis * depth
        return slid
    }

    /// Ruota l'impianto attorno alla **piattaforma**, portando l'apice verso un punto.
    ///
    /// La piattaforma resta ferma perché è ciò che si è scelto per primo guardando la cresta: chi
    /// inclina sta cercando un asse migliore dentro l'osso, non un punto d'emergenza diverso.
    public static func tilted(
        _ implant: ImplantPlacement, apexTowards pointMM: Vec3
    ) -> ImplantPlacement {
        guard let direction = (pointMM - implant.platformMM).normalized else { return implant }
        var tilted = implant
        tilted.axis = direction
        return tilted
    }

    /// Ruota l'impianto attorno all'**apice**, portando la piattaforma verso un punto.
    ///
    /// Serve quando è l'apice a essere nel punto giusto — appena sopra il canale — e a dover
    /// cambiare è l'emergenza. Ruotando attorno alla piattaforma l'apice si sposterebbe, ed è
    /// esattamente ciò che non si vuole.
    public static func tilted(
        _ implant: ImplantPlacement, headTowards pointMM: Vec3
    ) -> ImplantPlacement {
        let apex = implant.apexMM
        guard let direction = (apex - pointMM).normalized else { return implant }
        var tilted = implant
        tilted.axis = direction
        // La piattaforma si ricalcola perché l'apice non si muova: è la differenza fra ruotare
        // attorno all'apice e ruotare attorno alla piattaforma cambiandole solo il verso.
        tilted.platformMM = apex - direction * implant.model.lengthMM
        return tilted
    }

    /// Applica il trascinamento di una presa, in millimetri Patient.
    ///
    /// Il punto è quello **corrente** del puntatore e non uno spostamento incrementale: gli
    /// incrementi accumulano l'errore di ogni fotogramma, e su una rotazione l'accumulo si vede
    /// come un impianto che scivola via dal cursore mentre lo si inclina.
    public static func dragged(
        _ implant: ImplantPlacement, grip: ImplantGrip, toMM pointMM: Vec3, fromMM previousMM: Vec3
    ) -> ImplantPlacement {
        guard pointMM.isFinite, previousMM.isFinite else { return implant }
        switch grip {
        case .body:
            return moved(implant, byMM: pointMM - previousMM)
        case .apex:
            return tilted(implant, apexTowards: pointMM)
        case .head:
            return tilted(implant, headTowards: pointMM)
        }
    }
}
