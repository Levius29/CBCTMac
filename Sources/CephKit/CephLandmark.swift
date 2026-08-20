import DICOMCore
import Foundation

// Cefalometria su CBCT.
//
// # Perché non si copia la teleradiografia
//
// L'analisi cefalometrica nasce su una lastra: una proiezione, con la sua magnificazione, le sue
// strutture bilaterali sovrapposte e la sua ambiguità su quale dei due gonion si stia indicando.
// Su una CBCT quei limiti non ci sono, e riprodurli sarebbe una scelta strana.
//
// Qui i punti si segnano **nello spazio**, in millimetri Patient, dentro qualunque riquadro. I
// punti bilaterali — porion, orbitale, gonion, articulare — si segnano due volte, a destra e a
// sinistra, e l'analisi usa il punto di mezzo: è la stessa costruzione che sulla lastra fa
// l'occhio quando media due contorni sovrapposti, ma qui è esatta e si sa quanto i due lati
// distano fra loro.
//
// # E gli angoli classici, allora?
//
// Restano quelli, e restano definiti su un piano: SNA è un angolo sagittale, e misurarlo in tre
// dimensioni su un cranio asimmetrico darebbe un numero che non si può confrontare con nessuna
// norma pubblicata. Quindi i punti vivono in 3D e gli angoli si calcolano sulla loro
// **proiezione sul piano sagittale mediano**. Vedi `CephAnalysis`.
//
// # Che cosa questi numeri non sono
//
// Non sono una diagnosi. I valori di riferimento riportati vengono dalle analisi classiche
// (Steiner, Tweed, Downs, Ricketts, Jarabak) su popolazioni adulte, e su un bambino, su un
// paziente non caucasico o su un cranio operato dicono poco. Il programma li mostra per dare
// una scala di lettura, non per dire che cosa fare.

/// Un punto di repere cefalometrico.
public enum CephLandmark: String, CaseIterable, Hashable, Sendable, Codable {
    // Base cranica
    case sella
    case nasion
    case porion
    case orbitale
    case basion
    case articulare

    // Mascellare
    case anteriorNasalSpine
    case posteriorNasalSpine
    case pointA

    // Mandibola
    case pointB
    case pogonion
    case gnathion
    case menton
    case gonion

    // Denti
    case upperIncisorTip
    case upperIncisorApex
    case lowerIncisorTip
    case lowerIncisorApex
    case molarContact

    // Tessuti molli
    case softNasion
    case pronasale
    case subnasale
    case labraleSuperius
    case labraleInferius
    case softPogonion

    /// La sigla con cui il punto compare in letteratura e nei referti.
    public var abbreviation: String {
        switch self {
        case .sella: return "S"
        case .nasion: return "N"
        case .porion: return "Po"
        case .orbitale: return "Or"
        case .basion: return "Ba"
        case .articulare: return "Ar"
        case .anteriorNasalSpine: return "ANS"
        case .posteriorNasalSpine: return "PNS"
        case .pointA: return "A"
        case .pointB: return "B"
        case .pogonion: return "Pog"
        case .gnathion: return "Gn"
        case .menton: return "Me"
        case .gonion: return "Go"
        case .upperIncisorTip: return "U1"
        case .upperIncisorApex: return "U1a"
        case .lowerIncisorTip: return "L1"
        case .lowerIncisorApex: return "L1a"
        case .molarContact: return "M"
        case .softNasion: return "N'"
        case .pronasale: return "Prn"
        case .subnasale: return "Sn"
        case .labraleSuperius: return "Ls"
        case .labraleInferius: return "Li"
        case .softPogonion: return "Pog'"
        }
    }

    public var localizedName: String {
        switch self {
        case .sella: return "Sella"
        case .nasion: return "Nasion"
        case .porion: return "Porion"
        case .orbitale: return "Orbitale"
        case .basion: return "Basion"
        case .articulare: return "Articulare"
        case .anteriorNasalSpine: return "Spina nasale anteriore"
        case .posteriorNasalSpine: return "Spina nasale posteriore"
        case .pointA: return "Punto A"
        case .pointB: return "Punto B"
        case .pogonion: return "Pogonion"
        case .gnathion: return "Gnathion"
        case .menton: return "Menton"
        case .gonion: return "Gonion"
        case .upperIncisorTip: return "Margine incisivo superiore"
        case .upperIncisorApex: return "Apice incisivo superiore"
        case .lowerIncisorTip: return "Margine incisivo inferiore"
        case .lowerIncisorApex: return "Apice incisivo inferiore"
        case .molarContact: return "Contatto dei primi molari"
        case .softNasion: return "Nasion cutaneo"
        case .pronasale: return "Pronasale"
        case .subnasale: return "Subnasale"
        case .labraleSuperius: return "Labiale superiore"
        case .labraleInferius: return "Labiale inferiore"
        case .softPogonion: return "Pogonion cutaneo"
        }
    }

    /// Dove sta il punto, detto in modo che si possa cercarlo.
    ///
    /// Non è decorazione: un repere segnato nel posto sbagliato non produce un errore, produce un
    /// numero. La definizione accanto al nome è l'unica difesa contro un'analisi intera storta
    /// per un punto messo un centimetro più in là.
    public var definition: String {
        switch self {
        case .sella:
            return "Centro geometrico della sella turcica, sul piano sagittale mediano."
        case .nasion:
            return "Punto più anteriore della sutura fronto-nasale."
        case .porion:
            return "Punto più alto del meato acustico esterno osseo. Bilaterale."
        case .orbitale:
            return "Punto più basso del margine infraorbitario. Bilaterale."
        case .basion:
            return "Punto più anteriore e inferiore del grande forame occipitale."
        case .articulare:
            return "Incrocio fra il margine posteriore del collo del condilo e la base cranica. "
                + "Bilaterale."
        case .anteriorNasalSpine:
            return "Apice della spina nasale anteriore."
        case .posteriorNasalSpine:
            return "Apice della spina nasale posteriore, sul palato duro."
        case .pointA:
            return "Punto più profondo della concavità del mascellare, fra spina nasale anteriore "
                + "e cresta alveolare."
        case .pointB:
            return "Punto più profondo della concavità della sinfisi, fra cresta alveolare e "
                + "pogonion."
        case .pogonion:
            return "Punto più anteriore della sinfisi mentoniera."
        case .gnathion:
            return "Punto più anteriore e inferiore della sinfisi, fra pogonion e menton."
        case .menton:
            return "Punto più basso della sinfisi mentoniera."
        case .gonion:
            return "Punto dell'angolo mandibolare più distante dal centro del ramo. Bilaterale."
        case .upperIncisorTip:
            return "Margine incisale dell'incisivo centrale superiore."
        case .upperIncisorApex:
            return "Apice radicolare dell'incisivo centrale superiore."
        case .lowerIncisorTip:
            return "Margine incisale dell'incisivo centrale inferiore."
        case .lowerIncisorApex:
            return "Apice radicolare dell'incisivo centrale inferiore."
        case .molarContact:
            return "Punto di contatto occlusale dei primi molari permanenti."
        case .softNasion:
            return "Punto più concavo del profilo cutaneo alla radice del naso."
        case .pronasale:
            return "Punto più anteriore della punta del naso."
        case .subnasale:
            return "Punto in cui il setto nasale incontra il labbro superiore."
        case .labraleSuperius:
            return "Punto più anteriore del labbro superiore."
        case .labraleInferius:
            return "Punto più anteriore del labbro inferiore."
        case .softPogonion:
            return "Punto più anteriore del mento cutaneo."
        }
    }

    /// Vero per i punti che esistono in doppia copia, uno per lato.
    ///
    /// Su una lastra i due si sovrappongono e chi traccia ne segna uno solo, scegliendo a occhio
    /// una via di mezzo. Qui si segnano tutti e due e la media la fa il programma — e la distanza
    /// fra i due lati diventa un'informazione invece di un'approssimazione nascosta.
    public var isBilateral: Bool {
        switch self {
        case .porion, .orbitale, .gonion, .articulare: return true
        default: return false
        }
    }

    /// Se il punto sta su un tessuto molle, e quindi si segna su una finestra diversa.
    public var isSoftTissue: Bool {
        switch self {
        case .softNasion, .pronasale, .subnasale, .labraleSuperius, .labraleInferius,
            .softPogonion:
            return true
        default:
            return false
        }
    }

    /// In che gruppo mostrarlo nell'elenco.
    public var group: CephLandmarkGroup {
        switch self {
        case .sella, .nasion, .porion, .orbitale, .basion, .articulare: return .cranialBase
        case .anteriorNasalSpine, .posteriorNasalSpine, .pointA: return .maxilla
        case .pointB, .pogonion, .gnathion, .menton, .gonion: return .mandible
        case .upperIncisorTip, .upperIncisorApex, .lowerIncisorTip, .lowerIncisorApex,
            .molarContact:
            return .teeth
        case .softNasion, .pronasale, .subnasale, .labraleSuperius, .labraleInferius,
            .softPogonion:
            return .softTissue
        }
    }
}

public enum CephLandmarkGroup: String, CaseIterable, Hashable, Sendable, Codable {
    case cranialBase
    case maxilla
    case mandible
    case teeth
    case softTissue

    public var localizedName: String {
        switch self {
        case .cranialBase: return "Base cranica"
        case .maxilla: return "Mascellare"
        case .mandible: return "Mandibola"
        case .teeth: return "Denti"
        case .softTissue: return "Tessuti molli"
        }
    }

    /// I reperi del gruppo, nell'ordine in cui conviene segnarli.
    public var landmarks: [CephLandmark] {
        CephLandmark.allCases.filter { $0.group == self }
    }
}

/// Il lato di un repere bilaterale.
public enum CephSide: String, Hashable, Sendable, Codable, CaseIterable {
    /// Punto unico, sul piano sagittale mediano.
    case median
    case right
    case left

    public var localizedName: String {
        switch self {
        case .median: return "Mediano"
        case .right: return "Destro"
        case .left: return "Sinistro"
        }
    }
}
