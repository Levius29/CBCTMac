import DICOMCore
import Foundation

// L'analisi cefalometrica.
//
// # Una regola per ogni angolo, scritta e non lasciata all'intuito
//
// Ogni misura qui sotto dichiara **con quali semirette** si calcola. Sembra pedanteria e non lo
// è: fra l'angolo fra due rette e l'angolo fra due semirette ci sono 180 gradi di differenza, e
// scegliere la coppia sbagliata non produce un errore ma un numero plausibile — 155 al posto di
// 25 — che chi legge non ha modo di riconoscere come sbagliato.
//
// La prova che tiene insieme il tutto è il triangolo di Tweed: FMA, FMIA e IMPA sono i tre
// angoli di un triangolo e devono sommare a 180. Sono calcolati per vie indipendenti, quindi la
// somma è una verifica vera e non un'identità: sbagliando una semiretta, la somma non torna.

public enum CephUnit: String, Hashable, Sendable, Codable {
    case degrees
    case millimetres
    case percent

    public var symbol: String {
        switch self {
        case .degrees: return "°"
        case .millimetres: return "mm"
        case .percent: return "%"
        }
    }
}

/// L'intervallo di riferimento di una misura.
///
/// Un intervallo e non una media con scarto: le norme cefalometriche sono pubblicate come
/// intervalli, e riscriverle come `82 ± 2` dà l'impressione di una distribuzione nota che qui non
/// si ha. Vedi il Contratto 5.
public struct CephReference: Hashable, Sendable, Codable {
    public var low: Double
    public var high: Double
    /// Da quale analisi viene l'intervallo.
    public var source: String
    /// Quando serve dire a chi si applica, e a chi no.
    public var note: String?

    public init(low: Double, high: Double, source: String, note: String? = nil) {
        self.low = low
        self.high = high
        self.source = source
        self.note = note
    }

    public func contains(_ value: Double) -> Bool { value >= low && value <= high }
}

/// Come sta una misura rispetto al suo intervallo.
public enum CephStatus: String, Hashable, Sendable {
    case below
    case within
    case above
    /// Misura senza intervallo di riferimento: una lunghezza assoluta, per esempio.
    case unrated

    public var localizedName: String {
        switch self {
        case .below: return "Sotto"
        case .within: return "Nella norma"
        case .above: return "Sopra"
        case .unrated: return "—"
        }
    }
}

/// Le misure che l'analisi sa calcolare.
public enum CephMeasureKind: String, CaseIterable, Hashable, Sendable, Codable {
    // Rapporti scheletrici sagittali
    case sna
    case snb
    case anb
    case wits
    case convexity

    // Rapporti verticali
    case snToGoGn
    case fma
    case facialAngle
    case yAxis
    case palatalPlaneToSN
    case gonialAngle
    case saddleAngle
    case articularAngle
    case anteriorFaceHeight
    case posteriorFaceHeight
    case jarabakRatio

    // Denti
    case impa
    case fmia
    case interincisal
    case upperIncisorToNA
    case upperIncisorToNADistance
    case lowerIncisorToNB
    case lowerIncisorToNBDistance

    // Tessuti molli
    case nasolabialAngle
    case softConvexity
    case upperLipToELine
    case lowerLipToELine

    public var localizedName: String {
        switch self {
        case .sna: return "Angolo SNA"
        case .snb: return "Angolo SNB"
        case .anb: return "Angolo ANB"
        case .wits: return "Wits"
        case .convexity: return "Angolo di convessità"
        case .snToGoGn: return "SN — piano mandibolare"
        case .fma: return "FMA (Francoforte — piano mandibolare)"
        case .facialAngle: return "Angolo facciale"
        case .yAxis: return "Asse Y"
        case .palatalPlaneToSN: return "Piano palatale — SN"
        case .gonialAngle: return "Angolo goniaco"
        case .saddleAngle: return "Angolo della sella"
        case .articularAngle: return "Angolo articolare"
        case .anteriorFaceHeight: return "Altezza facciale anteriore"
        case .posteriorFaceHeight: return "Altezza facciale posteriore"
        case .jarabakRatio: return "Rapporto di Jarabak"
        case .impa: return "IMPA (incisivo inferiore — piano mandibolare)"
        case .fmia: return "FMIA (incisivo inferiore — Francoforte)"
        case .interincisal: return "Angolo interincisivo"
        case .upperIncisorToNA: return "Incisivo superiore — NA"
        case .upperIncisorToNADistance: return "Incisivo superiore — NA, distanza"
        case .lowerIncisorToNB: return "Incisivo inferiore — NB"
        case .lowerIncisorToNBDistance: return "Incisivo inferiore — NB, distanza"
        case .nasolabialAngle: return "Angolo nasolabiale"
        case .softConvexity: return "Convessità del profilo cutaneo"
        case .upperLipToELine: return "Labbro superiore — linea E"
        case .lowerLipToELine: return "Labbro inferiore — linea E"
        }
    }

    public var abbreviation: String {
        switch self {
        case .sna: return "SNA"
        case .snb: return "SNB"
        case .anb: return "ANB"
        case .wits: return "Wits"
        case .convexity: return "N-A-Pog"
        case .snToGoGn: return "SN-GoGn"
        case .fma: return "FMA"
        case .facialAngle: return "N-Pog/FH"
        case .yAxis: return "S-Gn/FH"
        case .palatalPlaneToSN: return "ANS-PNS/SN"
        case .gonialAngle: return "Ar-Go-Me"
        case .saddleAngle: return "N-S-Ar"
        case .articularAngle: return "S-Ar-Go"
        case .anteriorFaceHeight: return "N-Me"
        case .posteriorFaceHeight: return "S-Go"
        case .jarabakRatio: return "S-Go/N-Me"
        case .impa: return "IMPA"
        case .fmia: return "FMIA"
        case .interincisal: return "U1-L1"
        case .upperIncisorToNA: return "U1/NA"
        case .upperIncisorToNADistance: return "U1-NA"
        case .lowerIncisorToNB: return "L1/NB"
        case .lowerIncisorToNBDistance: return "L1-NB"
        case .nasolabialAngle: return "Prn-Sn-Ls"
        case .softConvexity: return "N'-Sn-Pog'"
        case .upperLipToELine: return "Ls/E"
        case .lowerLipToELine: return "Li/E"
        }
    }

    public var unit: CephUnit {
        switch self {
        case .wits, .upperIncisorToNADistance, .lowerIncisorToNBDistance,
            .anteriorFaceHeight, .posteriorFaceHeight, .upperLipToELine, .lowerLipToELine:
            return .millimetres
        case .jarabakRatio:
            return .percent
        default:
            return .degrees
        }
    }

    /// In che sezione del referto mostrarla.
    public var group: CephMeasureGroup {
        switch self {
        case .sna, .snb, .anb, .wits, .convexity: return .sagittal
        case .snToGoGn, .fma, .facialAngle, .yAxis, .palatalPlaneToSN, .gonialAngle,
            .saddleAngle, .articularAngle, .anteriorFaceHeight, .posteriorFaceHeight,
            .jarabakRatio:
            return .vertical
        case .impa, .fmia, .interincisal, .upperIncisorToNA, .upperIncisorToNADistance,
            .lowerIncisorToNB, .lowerIncisorToNBDistance:
            return .dental
        case .nasolabialAngle, .softConvexity, .upperLipToELine, .lowerLipToELine:
            return .softTissue
        }
    }

    /// I reperi senza i quali la misura non si calcola.
    ///
    /// Dichiarati qui e non solo dentro il calcolo, perché servono anche all'elenco di ciò che
    /// manca: dire «segna il porion e avrai FMA, FMIA e l'asse Y» è più utile che lasciare tre
    /// righe vuote senza spiegazione. Un test verifica che questo elenco e il calcolo dicano la
    /// stessa cosa — che è l'unico modo perché non divergano.
    public var requiredLandmarks: Set<CephLandmark> {
        switch self {
        case .sna: return [.sella, .nasion, .pointA]
        case .snb: return [.sella, .nasion, .pointB]
        case .anb: return [.sella, .nasion, .pointA, .pointB]
        case .wits: return [.pointA, .pointB, .upperIncisorTip, .lowerIncisorTip, .molarContact]
        case .convexity: return [.nasion, .pointA, .pogonion]
        case .snToGoGn: return [.sella, .nasion, .gonion, .gnathion]
        case .fma: return [.porion, .orbitale, .gonion, .menton]
        case .facialAngle: return [.porion, .orbitale, .nasion, .pogonion]
        case .yAxis: return [.porion, .orbitale, .sella, .gnathion]
        case .palatalPlaneToSN: return [.sella, .nasion, .anteriorNasalSpine, .posteriorNasalSpine]
        case .gonialAngle: return [.articulare, .gonion, .menton]
        case .saddleAngle: return [.nasion, .sella, .articulare]
        case .articularAngle: return [.sella, .articulare, .gonion]
        case .anteriorFaceHeight: return [.nasion, .menton]
        case .posteriorFaceHeight: return [.sella, .gonion]
        case .jarabakRatio: return [.sella, .gonion, .nasion, .menton]
        case .impa: return [.gonion, .menton, .lowerIncisorTip, .lowerIncisorApex]
        case .fmia: return [.porion, .orbitale, .lowerIncisorTip, .lowerIncisorApex]
        case .interincisal:
            return [.upperIncisorTip, .upperIncisorApex, .lowerIncisorTip, .lowerIncisorApex]
        case .upperIncisorToNA: return [.nasion, .pointA, .upperIncisorTip, .upperIncisorApex]
        case .upperIncisorToNADistance: return [.nasion, .pointA, .upperIncisorTip]
        case .lowerIncisorToNB: return [.nasion, .pointB, .lowerIncisorTip, .lowerIncisorApex]
        case .lowerIncisorToNBDistance: return [.nasion, .pointB, .lowerIncisorTip]
        case .nasolabialAngle: return [.pronasale, .subnasale, .labraleSuperius]
        case .softConvexity: return [.softNasion, .subnasale, .softPogonion]
        case .upperLipToELine: return [.pronasale, .softPogonion, .labraleSuperius]
        case .lowerLipToELine: return [.pronasale, .softPogonion, .labraleInferius]
        }
    }

    /// L'intervallo di riferimento, quando la misura ne ha uno.
    ///
    /// Le lunghezze assolute non ne hanno: un'altezza facciale anteriore di 120 mm non è né
    /// normale né anormale finché non si sa di chi — età, sesso, statura. Metterci un intervallo
    /// significherebbe inventarlo.
    public var reference: CephReference? {
        switch self {
        case .sna:
            return CephReference(low: 80, high: 84, source: "Steiner")
        case .snb:
            return CephReference(low: 78, high: 82, source: "Steiner")
        case .anb:
            return CephReference(
                low: 0, high: 4, source: "Steiner",
                note: "Sotto lo zero indica una relazione di terza classe scheletrica.")
        case .wits:
            return CephReference(
                low: -2, high: 3, source: "Jacobson",
                note: "Il riferimento pubblicato è 1 mm negli uomini e 0 mm nelle donne, "
                    + "con scarto di circa 2 mm.")
        case .convexity:
            return CephReference(
                low: -5, high: 5, source: "Downs",
                note: "Positivo per un profilo convesso, negativo per uno concavo.")
        case .snToGoGn:
            return CephReference(low: 28, high: 36, source: "Steiner")
        case .fma:
            return CephReference(low: 22, high: 28, source: "Tweed")
        case .facialAngle:
            return CephReference(low: 84, high: 92, source: "Downs")
        case .yAxis:
            return CephReference(low: 53, high: 66, source: "Downs")
        case .palatalPlaneToSN:
            return CephReference(low: 5, high: 11, source: "Steiner")
        case .gonialAngle:
            return CephReference(low: 118, high: 130, source: "Jarabak")
        case .saddleAngle:
            return CephReference(low: 118, high: 128, source: "Jarabak")
        case .articularAngle:
            return CephReference(low: 137, high: 149, source: "Jarabak")
        case .anteriorFaceHeight, .posteriorFaceHeight:
            return nil
        case .jarabakRatio:
            return CephReference(
                low: 62, high: 65, source: "Jarabak",
                note: "Sopra indica una crescita orizzontale, sotto una verticale.")
        case .impa:
            return CephReference(low: 85, high: 95, source: "Tweed")
        case .fmia:
            return CephReference(low: 63, high: 70, source: "Tweed")
        case .interincisal:
            return CephReference(low: 122, high: 140, source: "Downs")
        case .upperIncisorToNA:
            return CephReference(low: 18, high: 26, source: "Steiner")
        case .upperIncisorToNADistance:
            return CephReference(low: 2, high: 6, source: "Steiner")
        case .lowerIncisorToNB:
            return CephReference(low: 21, high: 29, source: "Steiner")
        case .lowerIncisorToNBDistance:
            return CephReference(low: 2, high: 6, source: "Steiner")
        case .nasolabialAngle:
            return CephReference(low: 90, high: 110, source: "Burstone")
        case .softConvexity:
            return CephReference(low: 160, high: 175, source: "Legan e Burstone")
        case .upperLipToELine:
            return CephReference(
                low: -6, high: -2, source: "Ricketts",
                note: "Negativo significa dietro alla linea, che è la posizione attesa.")
        case .lowerLipToELine:
            return CephReference(
                low: -4, high: 0, source: "Ricketts",
                note: "Negativo significa dietro alla linea, che è la posizione attesa.")
        }
    }
}

public enum CephMeasureGroup: String, CaseIterable, Hashable, Sendable, Codable {
    case sagittal
    case vertical
    case dental
    case softTissue

    public var localizedName: String {
        switch self {
        case .sagittal: return "Rapporti sagittali"
        case .vertical: return "Rapporti verticali"
        case .dental: return "Denti"
        case .softTissue: return "Tessuti molli"
        }
    }
}

/// Una misura calcolata.
public struct CephMeasure: Hashable, Sendable, Identifiable {
    public var kind: CephMeasureKind
    public var value: Double

    public var id: CephMeasureKind { kind }

    public init(kind: CephMeasureKind, value: Double) {
        self.kind = kind
        self.value = value
    }

    public var status: CephStatus {
        guard let reference = kind.reference else { return .unrated }
        if value < reference.low { return .below }
        if value > reference.high { return .above }
        return .within
    }

    /// Il valore scritto con una cifra decimale, virgola all'italiana.
    ///
    /// Una cifra e non tre: un decimo di grado su un repere che si segna a mano vale già più
    /// della precisione che si ha. Vedi il Contratto 5.
    public var formattedValue: String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
            + " " + kind.unit.symbol
    }

    public var formattedReference: String? {
        guard let reference = kind.reference else { return nil }
        let low = String(format: "%.0f", reference.low).replacingOccurrences(of: ".", with: ",")
        let high = String(format: "%.0f", reference.high).replacingOccurrences(of: ".", with: ",")
        return "\(low)–\(high) \(kind.unit.symbol) (\(reference.source))"
    }
}

public enum CephAnalysis: Sendable {

    // MARK: Geometria del piano

    /// L'angolo, in gradi, fra due semirette uscenti dallo stesso punto.
    ///
    /// Sempre fra 0 e 180: è l'angolo geometrico fra due direzioni, e non ha un verso.
    static func angleDegrees(
        at vertex: CephPlanePoint, toward a: CephPlanePoint, and b: CephPlanePoint
    ) -> Double? {
        guard let u = (a - vertex).normalized, let v = (b - vertex).normalized else { return nil }
        let cosine = Swift.max(-1, Swift.min(1, u.dot(v)))
        return Foundation.acos(cosine) * 180 / .pi
    }

    /// L'angolo fra due semirette date come coppie di punti: da `a1` verso `a2`, da `b1` verso
    /// `b2`.
    ///
    /// Le semirette non devono incontrarsi: conta solo la loro direzione. È la forma in cui sono
    /// definiti gli angoli fra piani cefalometrici, che quasi mai si intersecano dentro la
    /// figura.
    static func angleBetweenRays(
        _ a1: CephPlanePoint, _ a2: CephPlanePoint, _ b1: CephPlanePoint, _ b2: CephPlanePoint
    ) -> Double? {
        guard let u = (a2 - a1).normalized, let v = (b2 - b1).normalized else { return nil }
        let cosine = Swift.max(-1, Swift.min(1, u.dot(v)))
        return Foundation.acos(cosine) * 180 / .pi
    }

    /// L'angolo **acuto** fra due rette, fra 0 e 90.
    ///
    /// Per le misure che confrontano due assi quasi paralleli — un incisivo e la linea NA — dove
    /// la semiretta da scegliere sarebbe arbitraria e la norma è comunque un numero piccolo.
    static func acuteAngleBetweenLines(
        _ a1: CephPlanePoint, _ a2: CephPlanePoint, _ b1: CephPlanePoint, _ b2: CephPlanePoint
    ) -> Double? {
        guard let angle = angleBetweenRays(a1, a2, b1, b2) else { return nil }
        return angle > 90 ? 180 - angle : angle
    }

    /// Distanza con segno di un punto da una retta, **positiva davanti**.
    ///
    /// La retta viene orientata verso l'alto prima di ricavarne la normale: senza questo passo il
    /// segno dipenderebbe da quale dei due punti chi chiama ha scritto per primo, e una distanza
    /// dalla linea E di −4 mm diventerebbe +4 mm a seconda di come si è digitato — cioè un labbro
    /// dietro il profilo diventerebbe un labbro sporgente.
    static func signedAnteriorDistance(
        of point: CephPlanePoint, fromLineThrough a: CephPlanePoint, and b: CephPlanePoint
    ) -> Double? {
        guard var direction = (b - a).normalized else { return nil }
        if direction.superiorMM < 0 {
            direction = CephPlanePoint(
                anteriorMM: -direction.anteriorMM, superiorMM: -direction.superiorMM)
        }
        // Normale che guarda avanti: ruotando la direzione (che punta in alto) di 90° in senso
        // orario nel piano (anteriore, superiore) si ottiene una direzione anteriore.
        let normal = CephPlanePoint(
            anteriorMM: direction.superiorMM, superiorMM: -direction.anteriorMM)
        return (point - a).dot(normal)
    }

    /// Quanto un punto sta più avanti di un altro **lungo una retta**.
    ///
    /// È la costruzione di Wits: si proiettano A e B sul piano occlusale e si guarda quale dei
    /// due cade più avanti. La retta viene orientata in avanti, per la stessa ragione per cui
    /// sopra viene orientata in alto.
    static func signedDistanceAlongLine(
        from origin: CephPlanePoint, to point: CephPlanePoint,
        alongLineThrough a: CephPlanePoint, and b: CephPlanePoint
    ) -> Double? {
        guard var direction = (b - a).normalized else { return nil }
        if direction.anteriorMM < 0 {
            direction = CephPlanePoint(
                anteriorMM: -direction.anteriorMM, superiorMM: -direction.superiorMM)
        }
        return (point - origin).dot(direction)
    }

    // MARK: Le misure

    /// Tutte le misure che i reperi segnati permettono di calcolare.
    ///
    /// Le altre non compaiono, invece di comparire vuote o a zero: uno zero in una colonna di
    /// gradi si legge come un valore, e un ANB di zero è un dato clinico preciso — non «non lo
    /// so».
    public static func measures(for tracing: CephTracing) -> [CephMeasure] {
        CephMeasureKind.allCases.compactMap { kind in
            value(of: kind, in: tracing).map { CephMeasure(kind: kind, value: $0) }
        }
    }

    /// Le misure raggruppate come vanno mostrate, nell'ordine dei gruppi.
    public static func groupedMeasures(
        for tracing: CephTracing
    ) -> [(group: CephMeasureGroup, measures: [CephMeasure])] {
        let all = measures(for: tracing)
        return CephMeasureGroup.allCases.compactMap { group in
            let inGroup = all.filter { $0.kind.group == group }
            return inGroup.isEmpty ? nil : (group, inGroup)
        }
    }

    /// I reperi non ancora segnati, ordinati per quante misure sbloccherebbero.
    ///
    /// Ordinati così e non alfabeticamente: chi ha segnato dieci punti su venticinque vuole
    /// sapere quale conviene segnare adesso, e la risposta è quello che apre più righe.
    public static func mostUsefulMissingLandmarks(
        for tracing: CephTracing
    ) -> [(landmark: CephLandmark, unlocks: Int)] {
        let placed = tracing.placedLandmarks
        var counts: [CephLandmark: Int] = [:]
        for kind in CephMeasureKind.allCases {
            let missing = kind.requiredLandmarks.subtracting(placed)
            // Solo i reperi che da soli completerebbero la misura: suggerire un punto che ne
            // lascia mancare altri tre non è un suggerimento, è un elenco.
            guard missing.count == 1, let only = missing.first else { continue }
            counts[only, default: 0] += 1
        }
        return counts.map { (landmark: $0.key, unlocks: $0.value) }
            .sorted {
                $0.unlocks != $1.unlocks
                    ? $0.unlocks > $1.unlocks
                    : $0.landmark.abbreviation < $1.landmark.abbreviation
            }
    }

    /// Il valore di una singola misura, o `nil` se mancano i reperi.
    static func value(of kind: CephMeasureKind, in tracing: CephTracing) -> Double? {
        func p(_ landmark: CephLandmark) -> CephPlanePoint? { tracing.planePoint(of: landmark) }

        switch kind {
        // MARK: Sagittali
        case .sna:
            guard let s = p(.sella), let n = p(.nasion), let a = p(.pointA) else { return nil }
            return angleDegrees(at: n, toward: s, and: a)

        case .snb:
            guard let s = p(.sella), let n = p(.nasion), let b = p(.pointB) else { return nil }
            return angleDegrees(at: n, toward: s, and: b)

        case .anb:
            // Differenza e non un angolo a sé: così il segno dice da che parte sta A rispetto a
            // B, che è l'informazione clinica. Un angolo geometrico sarebbe sempre positivo e
            // una terza classe si leggerebbe come una prima.
            guard let sna = value(of: .sna, in: tracing), let snb = value(of: .snb, in: tracing)
            else { return nil }
            return sna - snb

        case .wits:
            guard let a = p(.pointA), let b = p(.pointB), let u1 = p(.upperIncisorTip),
                let l1 = p(.lowerIncisorTip), let molar = p(.molarContact)
            else { return nil }
            let incisalMidpoint = CephPlanePoint(
                anteriorMM: (u1.anteriorMM + l1.anteriorMM) / 2,
                superiorMM: (u1.superiorMM + l1.superiorMM) / 2)
            return signedDistanceAlongLine(
                from: b, to: a, alongLineThrough: molar, and: incisalMidpoint)

        case .convexity:
            guard let n = p(.nasion), let a = p(.pointA), let pog = p(.pogonion) else { return nil }
            guard let interior = angleDegrees(at: a, toward: n, and: pog) else { return nil }
            // Downs misura lo scostamento da una linea dritta, non l'angolo: 0 è un profilo
            // diritto, positivo convesso.
            return 180 - interior

        // MARK: Verticali
        case .snToGoGn:
            guard let s = p(.sella), let n = p(.nasion), let go = p(.gonion), let gn = p(.gnathion)
            else { return nil }
            return angleBetweenRays(n, s, gn, go)

        case .fma:
            guard let po = p(.porion), let or = p(.orbitale), let go = p(.gonion),
                let me = p(.menton)
            else { return nil }
            return angleBetweenRays(po, or, go, me)

        case .facialAngle:
            guard let po = p(.porion), let or = p(.orbitale), let n = p(.nasion),
                let pog = p(.pogonion)
            else { return nil }
            return angleBetweenRays(or, po, n, pog)

        case .yAxis:
            guard let po = p(.porion), let or = p(.orbitale), let s = p(.sella),
                let gn = p(.gnathion)
            else { return nil }
            return angleBetweenRays(po, or, s, gn)

        case .palatalPlaneToSN:
            guard let s = p(.sella), let n = p(.nasion), let ans = p(.anteriorNasalSpine),
                let pns = p(.posteriorNasalSpine)
            else { return nil }
            return acuteAngleBetweenLines(s, n, pns, ans)

        case .gonialAngle:
            guard let ar = p(.articulare), let go = p(.gonion), let me = p(.menton) else {
                return nil
            }
            return angleDegrees(at: go, toward: ar, and: me)

        case .saddleAngle:
            guard let n = p(.nasion), let s = p(.sella), let ar = p(.articulare) else { return nil }
            return angleDegrees(at: s, toward: n, and: ar)

        case .articularAngle:
            guard let s = p(.sella), let ar = p(.articulare), let go = p(.gonion) else {
                return nil
            }
            return angleDegrees(at: ar, toward: s, and: go)

        case .anteriorFaceHeight:
            guard let n = p(.nasion), let me = p(.menton) else { return nil }
            return n.distance(to: me)

        case .posteriorFaceHeight:
            guard let s = p(.sella), let go = p(.gonion) else { return nil }
            return s.distance(to: go)

        case .jarabakRatio:
            guard let posterior = value(of: .posteriorFaceHeight, in: tracing),
                let anterior = value(of: .anteriorFaceHeight, in: tracing), anterior > 0
            else { return nil }
            return posterior / anterior * 100

        // MARK: Denti
        case .impa:
            guard let go = p(.gonion), let me = p(.menton), let tip = p(.lowerIncisorTip),
                let apex = p(.lowerIncisorApex)
            else { return nil }
            return angleBetweenRays(me, go, apex, tip)

        case .fmia:
            guard let po = p(.porion), let or = p(.orbitale), let tip = p(.lowerIncisorTip),
                let apex = p(.lowerIncisorApex)
            else { return nil }
            return angleBetweenRays(or, po, tip, apex)

        case .interincisal:
            guard let upperTip = p(.upperIncisorTip), let upperApex = p(.upperIncisorApex),
                let lowerTip = p(.lowerIncisorTip), let lowerApex = p(.lowerIncisorApex)
            else { return nil }
            return angleBetweenRays(upperApex, upperTip, lowerApex, lowerTip)

        case .upperIncisorToNA:
            guard let n = p(.nasion), let a = p(.pointA), let tip = p(.upperIncisorTip),
                let apex = p(.upperIncisorApex)
            else { return nil }
            return acuteAngleBetweenLines(n, a, apex, tip)

        case .upperIncisorToNADistance:
            guard let n = p(.nasion), let a = p(.pointA), let tip = p(.upperIncisorTip) else {
                return nil
            }
            return signedAnteriorDistance(of: tip, fromLineThrough: n, and: a)

        case .lowerIncisorToNB:
            guard let n = p(.nasion), let b = p(.pointB), let tip = p(.lowerIncisorTip),
                let apex = p(.lowerIncisorApex)
            else { return nil }
            return acuteAngleBetweenLines(n, b, apex, tip)

        case .lowerIncisorToNBDistance:
            guard let n = p(.nasion), let b = p(.pointB), let tip = p(.lowerIncisorTip) else {
                return nil
            }
            return signedAnteriorDistance(of: tip, fromLineThrough: n, and: b)

        // MARK: Tessuti molli
        case .nasolabialAngle:
            guard let prn = p(.pronasale), let sn = p(.subnasale), let ls = p(.labraleSuperius)
            else { return nil }
            return angleDegrees(at: sn, toward: prn, and: ls)

        case .softConvexity:
            guard let n = p(.softNasion), let sn = p(.subnasale), let pog = p(.softPogonion)
            else { return nil }
            return angleDegrees(at: sn, toward: n, and: pog)

        case .upperLipToELine:
            guard let prn = p(.pronasale), let pog = p(.softPogonion), let ls = p(.labraleSuperius)
            else { return nil }
            return signedAnteriorDistance(of: ls, fromLineThrough: pog, and: prn)

        case .lowerLipToELine:
            guard let prn = p(.pronasale), let pog = p(.softPogonion), let li = p(.labraleInferius)
            else { return nil }
            return signedAnteriorDistance(of: li, fromLineThrough: pog, and: prn)
        }
    }
}
