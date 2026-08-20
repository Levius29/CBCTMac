import DICOMCore
import Foundation
import Testing

@testable import CephKit

// Cefalometria.
//
// # Come si verifica un angolo che non si può misurare col righello
//
// Il rischio vero non è sbagliare la trigonometria: è scegliere la semiretta sbagliata, che dà
// 155° dove ne servono 25 senza che nulla segnali un errore. Contro questo serve un cranio di
// prova **normale**: un tracciato con coordinate plausibili, su cui tutte le misure devono
// cadere dentro il proprio intervallo di riferimento. Una semiretta invertita ne fa uscire
// almeno una — quasi sempre parecchie — e il test lo dice.
//
// Il secondo controllo è il triangolo di Tweed: FMA, FMIA e IMPA sono i tre angoli di uno stesso
// triangolo e devono sommare a 180. Qui sono calcolati per tre vie indipendenti, quindi la somma
// è una verifica e non un'identità.

@Suite("Cefalometria")
struct CephAnalysisTests {

    /// Le coordinate del cranio di prova, in millimetri sul piano sagittale: anteriore e
    /// superiore, con l'origine sul porion e il piano di Francoforte orizzontale.
    ///
    /// Non sono inventate a mano: sono state cercate numericamente perché ogni misura cadesse
    /// dentro il proprio intervallo. È un cranio adulto normale, non il cranio di nessuno.
    static let normal: [CephLandmark: (anterior: Double, superior: Double)] = [
        .porion: (0.0, 0.0),
        .orbitale: (78.0, 0.0),
        .sella: (19.4, 19.2),
        .nasion: (93.0, 29.7),
        .articulare: (5.5, -9.7),
        .gonion: (13.3, -53.7),
        .menton: (80.3, -84.8),
        .gnathion: (86.0, -82.0),
        .pogonion: (92.0, -77.4),
        .anteriorNasalSpine: (96.0, -21.0),
        .posteriorNasalSpine: (44.0, -21.0),
        .pointA: (93.0, -33.2),
        .pointB: (90.1, -67.1),
        .upperIncisorTip: (97.0, -52.2),
        .upperIncisorApex: (87.7, -29.4),
        .lowerIncisorTip: (94.4, -55.2),
        .lowerIncisorApex: (85.9, -73.5),
        .molarContact: (52.1, -50.6),
        .pronasale: (121.1, -29.8),
        .subnasale: (107.1, -39.7),
        .labraleSuperius: (110.4, -46.5),
        .labraleInferius: (108.4, -57.1),
        .softNasion: (102.2, 25.2),
        .softPogonion: (100.8, -82.3),
    ]

    /// Dal piano sagittale allo spazio Patient: `y` all'indietro, `z` in alto.
    ///
    /// - Parameter lateralMM: scostamento laterale da dare al punto. Serve ai test che verificano
    ///   che la proiezione lo ignori.
    static func patient(
        _ coordinates: (anterior: Double, superior: Double), lateralMM: Double = 0
    ) -> Vec3 {
        Vec3(lateralMM, -coordinates.anterior, coordinates.superior)
    }

    /// Il tracciato di prova.
    ///
    /// - Parameter spreadMM: quanto separare i due lati dei reperi bilaterali. Con zero i due
    ///   punti coincidono; con un valore diverso la media deve comunque cadere sulla mediana.
    static func normalTracing(spreadMM: Double = 60) -> CephTracing {
        var tracing = CephTracing()
        for (landmark, coordinates) in normal {
            if landmark.isBilateral {
                tracing.place(
                    landmark, side: .right, at: patient(coordinates, lateralMM: -spreadMM / 2))
                tracing.place(
                    landmark, side: .left, at: patient(coordinates, lateralMM: spreadMM / 2))
            } else {
                tracing.place(landmark, at: patient(coordinates))
            }
        }
        return tracing
    }

    static func value(_ kind: CephMeasureKind, _ tracing: CephTracing) -> Double? {
        CephAnalysis.measures(for: tracing).first { $0.kind == kind }?.value
    }

    // MARK: La prova principale

    @Test("Su un cranio normale ogni misura cade nel proprio intervallo")
    func everyMeasureIsWithinReferenceOnANormalSkull() throws {
        let measures = CephAnalysis.measures(for: Self.normalTracing())

        // Tutte le misure che l'analisi conosce: il tracciato di prova ha ogni repere che serve.
        #expect(measures.count == CephMeasureKind.allCases.count)

        for measure in measures where measure.kind.reference != nil {
            #expect(
                measure.status == .within,
                """
                \(measure.kind.abbreviation) = \(measure.formattedValue), \
                atteso \(measure.formattedReference ?? "—")
                """)
        }
    }

    @Test("Il triangolo di Tweed somma a 180 gradi")
    func theTweedTriangleClosesAt180() throws {
        // FMA, FMIA e IMPA sono i tre angoli del triangolo formato da piano di Francoforte, piano
        // mandibolare e asse dell'incisivo inferiore. Sono calcolati con tre coppie di semirette
        // scelte a mano e indipendenti fra loro: se una coppia è invertita la somma non fa 180.
        let tracing = Self.normalTracing()
        let fma = try #require(Self.value(.fma, tracing))
        let fmia = try #require(Self.value(.fmia, tracing))
        let impa = try #require(Self.value(.impa, tracing))

        #expect(abs(fma + fmia + impa - 180) < 1e-9)
    }

    @Test("Le altezze facciali sono lunghezze vere, in millimetri")
    func faceHeightsAreRealLengths() throws {
        let tracing = Self.normalTracing()
        let anterior = try #require(Self.value(.anteriorFaceHeight, tracing))
        let posterior = try #require(Self.value(.posteriorFaceHeight, tracing))
        let ratio = try #require(Self.value(.jarabakRatio, tracing))

        // Distanza fra nasion e menton sul piano sagittale, calcolata a parte.
        let n = Self.normal[.nasion]!
        let me = Self.normal[.menton]!
        let expected = ((n.anterior - me.anterior) * (n.anterior - me.anterior)
            + (n.superior - me.superior) * (n.superior - me.superior)).squareRoot()

        #expect(abs(anterior - expected) < 1e-9)
        #expect(abs(ratio - posterior / anterior * 100) < 1e-9)
        // Un'altezza facciale non ha un intervallo di riferimento: dipende da chi.
        #expect(CephMeasureKind.anteriorFaceHeight.reference == nil)
        let measure = CephMeasure(kind: .anteriorFaceHeight, value: anterior)
        #expect(measure.status == .unrated)
    }

    // MARK: La proiezione

    @Test("Lo scostamento laterale dei reperi non cambia nessuna misura")
    func lateralOffsetsDoNotChangeAnyMeasure() throws {
        // Un repere segnato su una sezione parasagittale, o un cranio asimmetrico, spostano i
        // punti fuori dalla mediana. Gli angoli cefalometrici sono definiti sulla proiezione
        // sagittale e non devono accorgersene: se se ne accorgono, la proiezione non c'è.
        let flat = Self.normalTracing(spreadMM: 0)

        var skewed = CephTracing()
        var index = 0
        for landmark in CephLandmark.allCases {
            guard let coordinates = Self.normal[landmark] else { continue }
            index += 1
            // Scostamenti diversi punto per punto, e non tutti dalla stessa parte.
            let offset = Double((index % 7) - 3) * 11.5
            if landmark.isBilateral {
                skewed.place(
                    landmark, side: .right, at: Self.patient(coordinates, lateralMM: offset - 30))
                skewed.place(
                    landmark, side: .left, at: Self.patient(coordinates, lateralMM: offset + 30))
            } else {
                skewed.place(landmark, at: Self.patient(coordinates, lateralMM: offset))
            }
        }

        let before = CephAnalysis.measures(for: flat)
        let after = CephAnalysis.measures(for: skewed)
        #expect(before.count == after.count)
        for (a, b) in zip(before, after) {
            #expect(a.kind == b.kind)
            #expect(abs(a.value - b.value) < 1e-9, "\(a.kind.abbreviation)")
        }
    }

    @Test("Un repere bilaterale vale il punto di mezzo fra i due lati")
    func aBilateralLandmarkIsTheMidpointOfItsTwoSides() throws {
        var tracing = CephTracing()
        tracing.place(.gonion, side: .right, at: Vec3(-45, 10, -50))
        tracing.place(.gonion, side: .left, at: Vec3(41, 14, -54))

        let position = try #require(tracing.positionMM(of: .gonion))
        #expect(position.isApproximatelyEqual(to: Vec3(-2, 12, -52), tolerance: 1e-9))
        let spread = try #require(tracing.spreadMM(of: .gonion))
        #expect(abs(spread - Vec3(-45, 10, -50).distance(to: Vec3(41, 14, -54))) < 1e-9)
    }

    @Test("Un repere bilaterale è completo solo con tutti e due i lati")
    func aBilateralLandmarkNeedsBothSides() {
        var tracing = CephTracing()
        tracing.place(.porion, side: .right, at: Vec3(-60, 0, 0))
        #expect(!tracing.isComplete(.porion))
        #expect(tracing.spreadMM(of: .porion) == nil)

        tracing.place(.porion, side: .left, at: Vec3(60, 0, 0))
        #expect(tracing.isComplete(.porion))

        // Un repere mediano è completo con una segnatura sola, e il lato chiesto viene ignorato.
        tracing.place(.nasion, side: .left, at: Vec3(0, -90, 30))
        #expect(tracing.isComplete(.nasion))
        #expect(tracing.sides(of: .nasion) == [.median])
    }

    @Test("Segnare due volte lo stesso repere lo sposta, non ne fa la media")
    func placingTwiceReplacesInsteadOfAveraging() throws {
        var tracing = CephTracing()
        tracing.place(.sella, at: Vec3(0, 0, 0))
        tracing.place(.sella, at: Vec3(0, -20, 20))

        #expect(tracing.points.count == 1)
        #expect(
            try #require(tracing.positionMM(of: .sella))
                .isApproximatelyEqual(to: Vec3(0, -20, 20), tolerance: 1e-9))
    }

    // MARK: Il contratto fra reperi richiesti e calcolo

    @Test("Ogni misura chiede esattamente i reperi che le servono")
    func requiredLandmarksMatchWhatTheComputationNeeds() throws {
        // Due elenchi che dicono la stessa cosa in due posti divergono, prima o poi: uno serve al
        // calcolo, l'altro all'elenco di ciò che manca. Qui si verifica che tolto un solo repere
        // dichiarato necessario la misura sparisca davvero, e che con tutti ci sia.
        let complete = Self.normalTracing()

        for kind in CephMeasureKind.allCases {
            #expect(Self.value(kind, complete) != nil, "\(kind.abbreviation) non si calcola")

            for landmark in kind.requiredLandmarks {
                var reduced = complete
                reduced.remove(landmark)
                #expect(
                    Self.value(kind, reduced) == nil,
                    "\(kind.abbreviation) si calcola anche senza \(landmark.abbreviation)")
            }
        }
    }

    @Test("Senza reperi non esce nessun numero")
    func anEmptyTracingProducesNothing() {
        #expect(CephAnalysis.measures(for: CephTracing()).isEmpty)
        #expect(CephAnalysis.groupedMeasures(for: CephTracing()).isEmpty)
    }

    @Test("I gruppi contengono tutte le misure e nessuna due volte")
    func groupsPartitionTheMeasures() {
        let tracing = Self.normalTracing()
        let grouped = CephAnalysis.groupedMeasures(for: tracing)
        let flattened = grouped.flatMap(\.measures)

        #expect(flattened.count == CephMeasureKind.allCases.count)
        #expect(Set(flattened.map(\.kind)).count == flattened.count)
        for (group, measures) in grouped {
            #expect(measures.allSatisfy { $0.kind.group == group })
        }
    }

    @Test("I reperi che mancano sono ordinati per quante misure aprono")
    func missingLandmarksAreRankedByWhatTheyUnlock() throws {
        var tracing = Self.normalTracing()
        tracing.remove(.sella)
        tracing.remove(.porion)

        let missing = CephAnalysis.mostUsefulMissingLandmarks(for: tracing)
        #expect(missing.map(\.landmark).contains(.sella))
        #expect(missing.map(\.landmark).contains(.porion))
        // Ordinati per utilità decrescente, e la sella ne apre più del porion.
        let counts = missing.map(\.unlocks)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 >= $1 })
        let sella = try #require(missing.first { $0.landmark == .sella })
        let porion = try #require(missing.first { $0.landmark == .porion })
        #expect(sella.unlocks > porion.unlocks)

        // Con tutto segnato non manca niente.
        #expect(CephAnalysis.mostUsefulMissingLandmarks(for: Self.normalTracing()).isEmpty)
    }

    @Test("Un repere che ne lascia mancare altri non viene suggerito")
    func aLandmarkThatDoesNotCompleteAnythingIsNotSuggested() {
        // Un tracciato vuoto: nessun repere, da solo, completa una misura. Suggerirli tutti
        // sarebbe un elenco, non un suggerimento.
        #expect(CephAnalysis.mostUsefulMissingLandmarks(for: CephTracing()).isEmpty)
    }

    // MARK: I segni

    @Test("In terza classe l'ANB è negativo")
    func anbGoesNegativeInAClassThree() throws {
        var tracing = Self.normalTracing()
        // Mandibola avanti: il punto B passa davanti al punto A.
        tracing.place(.pointB, at: Self.patient((anterior: 101.0, superior: -67.1)))

        let anb = try #require(Self.value(.anb, tracing))
        #expect(anb < 0)
        #expect(CephMeasure(kind: .anb, value: anb).status == .below)
    }

    @Test("Un labbro dietro la linea E dà una distanza negativa, davanti positiva")
    func eLineDistanceIsNegativeBehindTheLine() throws {
        var tracing = Self.normalTracing()
        let behind = try #require(Self.value(.upperLipToELine, tracing))
        #expect(behind < 0)

        // Labbro sporgente: davanti alla linea che unisce punta del naso e mento cutaneo.
        tracing.place(.labraleSuperius, at: Self.patient((anterior: 126.0, superior: -46.5)))
        let ahead = try #require(Self.value(.upperLipToELine, tracing))
        #expect(ahead > 0)
        #expect(CephMeasure(kind: .upperLipToELine, value: ahead).status == .above)
    }

    @Test("Un incisivo superiore proclinato aumenta l'angolo e la distanza da NA")
    func aProclinedUpperIncisorIncreasesBothMeasures() throws {
        let tracing = Self.normalTracing()
        let angleBefore = try #require(Self.value(.upperIncisorToNA, tracing))
        let distanceBefore = try #require(Self.value(.upperIncisorToNADistance, tracing))

        var proclined = tracing
        proclined.place(.upperIncisorTip, at: Self.patient((anterior: 104.0, superior: -52.2)))

        let angleAfter = try #require(Self.value(.upperIncisorToNA, proclined))
        let distanceAfter = try #require(Self.value(.upperIncisorToNADistance, proclined))

        #expect(angleAfter > angleBefore)
        #expect(distanceAfter > distanceBefore)
        #expect(CephMeasure(kind: .upperIncisorToNADistance, value: distanceAfter).status == .above)
    }

    @Test("Il Wits è positivo quando il punto A cade davanti al punto B")
    func witsIsPositiveWhenAIsAheadOfB() throws {
        var tracing = Self.normalTracing()
        tracing.place(.pointA, at: Self.patient((anterior: 101.0, superior: -33.2)))
        let ahead = try #require(Self.value(.wits, tracing))
        #expect(ahead > 0)

        tracing.place(.pointA, at: Self.patient((anterior: 84.0, superior: -33.2)))
        let behind = try #require(Self.value(.wits, tracing))
        #expect(behind < 0)
    }

    @Test("Una faccia iperdivergente alza FMA e abbassa il rapporto di Jarabak")
    func aHighAngleFaceRaisesFMAAndLowersJarabak() throws {
        let tracing = Self.normalTracing()
        var high = tracing
        // Mento più in basso: il piano mandibolare ruota all'indietro.
        high.place(.menton, at: Self.patient((anterior: 80.3, superior: -104.8)))
        high.place(.gnathion, at: Self.patient((anterior: 86.0, superior: -102.0)))

        let fma = try #require(Self.value(.fma, high))
        let fmaBefore = try #require(Self.value(.fma, tracing))
        #expect(fma > fmaBefore)
        #expect(CephMeasure(kind: .fma, value: fma).status == .above)

        let jarabak = try #require(Self.value(.jarabakRatio, high))
        let jarabakBefore = try #require(Self.value(.jarabakRatio, tracing))
        #expect(jarabak < jarabakBefore)
        #expect(CephMeasure(kind: .jarabakRatio, value: jarabak).status == .below)
    }

    // MARK: Presentazione

    @Test("I numeri si scrivono con la virgola e una cifra")
    func valuesAreWrittenWithACommaAndOneDecimal() {
        #expect(CephMeasure(kind: .sna, value: 81.875).formattedValue == "81,9 °")
        #expect(CephMeasure(kind: .wits, value: -1.24).formattedValue == "-1,2 mm")
        #expect(CephMeasure(kind: .jarabakRatio, value: 63.5).formattedValue == "63,5 %")
        #expect(CephMeasure(kind: .sna, value: 82).formattedReference == "80–84 ° (Steiner)")
        #expect(CephMeasure(kind: .anteriorFaceHeight, value: 115).formattedReference == nil)
    }

    @Test("Ogni repere ha sigla, nome e definizione")
    func everyLandmarkIsDescribed() {
        for landmark in CephLandmark.allCases {
            #expect(!landmark.abbreviation.isEmpty)
            #expect(!landmark.localizedName.isEmpty)
            // La definizione è ciò che impedisce di segnare il punto nel posto sbagliato: senza,
            // il repere è solo un nome.
            #expect(landmark.definition.count > 20)
            #expect(landmark.group.landmarks.contains(landmark))
        }
        #expect(
            CephLandmarkGroup.allCases.flatMap(\.landmarks).count == CephLandmark.allCases.count)
    }

    @Test("Le sigle dei reperi non si ripetono")
    func landmarkAbbreviationsAreUnique() {
        let abbreviations = CephLandmark.allCases.map(\.abbreviation)
        #expect(Set(abbreviations).count == abbreviations.count)
    }

    @Test("Le sigle delle misure non si ripetono")
    func measureAbbreviationsAreUnique() {
        let abbreviations = CephMeasureKind.allCases.map(\.abbreviation)
        #expect(Set(abbreviations).count == abbreviations.count)
    }

    @Test("Il tracciato si salva e si rilegge")
    func aTracingSurvivesEncoding() throws {
        let tracing = Self.normalTracing()
        let data = try JSONEncoder().encode(tracing)
        let restored = try JSONDecoder().decode(CephTracing.self, from: data)

        #expect(restored.points.count == tracing.points.count)
        let before = CephAnalysis.measures(for: tracing)
        let after = CephAnalysis.measures(for: restored)
        for (a, b) in zip(before, after) { #expect(abs(a.value - b.value) < 1e-9) }
    }

    @Test("Il nome mostrato dice il lato solo quando il lato esiste")
    func displayNameMentionsTheSideOnlyWhenThereIsOne() {
        #expect(CephPoint(landmark: .nasion, positionMM: .init(0, 0, 0)).displayName == "N")
        #expect(
            CephPoint(landmark: .gonion, side: .right, positionMM: .init(0, 0, 0)).displayName
                == "Go dx")
        #expect(
            CephPoint(landmark: .gonion, side: .left, positionMM: .init(0, 0, 0)).displayName
                == "Go sx")
        // Un repere mediano segnato con un lato per errore non mostra il lato.
        #expect(
            CephPoint(landmark: .sella, side: .left, positionMM: .init(0, 0, 0)).displayName == "S")
    }
}
