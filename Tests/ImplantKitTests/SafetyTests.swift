import DICOMCore
import Testing

@testable import ImplantKit

// Test della pianificazione implantare.
//
// Qui il criterio non è «il numero è plausibile» ma «il numero è giusto o prudenziale». Un
// allarme di prossimità che sbaglia per eccesso di sicurezza è tollerabile; uno che sbaglia
// nell'altro verso dichiara sicuro un impianto che tocca il nervo. Diversi test verificano
// esattamente il **verso** dell'errore, non solo la sua entità.

@Suite("Distanza dalla superficie implantare")
struct ImplantDistanceTests {

    private func makeImplant() -> ImplantPlacement {
        // Cilindrico: il profilo è costante, quindi le distanze attese si calcolano a mano.
        let model = ImplantModel(
            manufacturer: "Prova", line: "Cilindrico",
            diameterMM: 4.0, lengthMM: 10.0,
            profile: [
                ProfilePoint(zMM: 0, radiusMM: 2.0),
                ProfilePoint(zMM: 10, radiusMM: 2.0),
            ])
        return ImplantPlacement(
            model: model, platformMM: Vec3(0, 0, 0), axis: Vec3(0, 0, -1))
    }

    @Test("L'apice sta a una lunghezza dalla piattaforma, lungo l'asse")
    func apexPosition() {
        let implant = makeImplant()
        #expect(implant.apexMM.isApproximatelyEqual(to: Vec3(0, 0, -10), tolerance: 1e-12))
    }

    @Test("La distanza laterale è quella radiale meno il raggio")
    func lateralDistance() {
        let implant = makeImplant()
        // A metà corpo, cinque millimetri dall'asse: cinque meno il raggio di due fa tre.
        let point = Vec3(5, 0, -5)
        #expect(abs(implant.signedDistance(from: point) - 3.0) < 1e-9)
    }

    @Test("Un punto dentro l'impianto ha distanza negativa")
    func insideIsNegative() {
        let implant = makeImplant()
        #expect(implant.signedDistance(from: Vec3(1, 0, -5)) < 0)
        #expect(implant.signedDistance(from: Vec3(0, 0, -5)) < 0)
    }

    @Test("Oltre l'apice la distanza è assiale")
    func beyondApex() {
        let implant = makeImplant()
        // Tre millimetri sotto l'apice, sull'asse.
        #expect(abs(implant.signedDistance(from: Vec3(0, 0, -13)) - 3.0) < 1e-9)
    }

    @Test("In diagonale oltre l'apice si compone la distanza dallo spigolo")
    func diagonalBeyondApex() {
        let implant = makeImplant()
        // Quattro millimetri di lato, dodici in profondità: rispetto allo spigolo apicale, che
        // sta a raggio 2 e quota −10, restano 2 di lato e 2 in basso → √8.
        let point = Vec3(4, 0, -12)
        let expected = (2.0 * 2.0 + 2.0 * 2.0).squareRoot()
        #expect(abs(implant.signedDistance(from: point) - expected) < 1e-9)
    }

    @Test("La misura si prende dalla superficie, non dall'asse")
    func distanceIsFromSurfaceNotAxis() {
        // È l'errore che regalerebbe un raggio intero di margine: su un impianto da 4 mm sono
        // due millimetri, cioè l'intera soglia di sicurezza dal canale alveolare.
        let implant = makeImplant()
        let point = Vec3(5, 0, -5)
        let fromAxis = point.distance(to: implant.axisPoint(atZ: 5))
        let fromSurface = implant.signedDistance(from: point)
        #expect(abs(fromAxis - fromSurface - 2.0) < 1e-9)
    }

    @Test("La distanza su un profilo conico non sovrastima mai")
    func taperedIsConservative() {
        // Sul cono la distanza vera si misura perpendicolare alla parete, mentre qui si misura
        // in orizzontale: l'approssimazione deve restare minore o uguale a quella reale.
        let model = ImplantModel(
            manufacturer: "Prova", line: "Conico", diameterMM: 4.0, lengthMM: 10.0)
        let implant = ImplantPlacement(
            model: model, platformMM: .zero, axis: Vec3(0, 0, -1))

        for z in stride(from: 0.0, through: 10.0, by: 0.5) {
            let radius = model.radius(atZ: z)
            let point = implant.axisPoint(atZ: z) + Vec3(radius + 3.0, 0, 0)
            let reported = implant.signedDistance(from: point)
            #expect(reported <= 3.0 + 1e-9, "a z=\(z) riportata \(reported), reale ≥ 3")
        }
    }

    @Test("L'angolo fra impianti paralleli è nullo, anche con assi opposti")
    func parallelism() {
        let a = ImplantPlacement(platformMM: .zero, axis: Vec3(0, 0, -1))
        let b = ImplantPlacement(platformMM: Vec3(8, 0, 0), axis: Vec3(0, 0, -1))
        #expect(a.angle(to: b) < 1e-9)

        // Assi opposti: ai fini protesici sono comunque paralleli.
        let c = ImplantPlacement(platformMM: Vec3(8, 0, 0), axis: Vec3(0, 0, 1))
        #expect(a.angle(to: c) < 1e-9)

        let tilted = ImplantPlacement(
            platformMM: Vec3(8, 0, 0), axis: Vec3(0, 0.5, -0.866))
        let degrees = a.angle(to: tilted) * 180 / Double.pi
        #expect(abs(degrees - 30) < 0.5)
    }

    @Test("Ruotando attorno all'apice l'apice resta fermo")
    func rotatingAroundApex() {
        let implant = makeImplant()
        let apexBefore = implant.apexMM
        let rotated = implant.rotated(
            axis: Vec3(0, 1, 0), angle: 0.2, aroundApex: true)
        #expect(rotated.apexMM.isApproximatelyEqual(to: apexBefore, tolerance: 1e-9))
        #expect(!rotated.platformMM.isApproximatelyEqual(to: implant.platformMM, tolerance: 1e-6))
    }
}

// MARK: - Canale

@Suite("Canale alveolare")
struct NerveCanalTests {

    /// Canale rettilineo lungo l'asse X, raggio uniforme di 1,5 mm.
    private func straightCanal(radius: Double = 1.5) -> NerveCanal {
        NerveCanal(
            side: .right,
            nodes: (0...4).map { index in
                NerveNode(
                    positionMM: Vec3(Double(index) * 10 - 20, 0, 0), radiusMM: radius)
            })
    }

    @Test("La distanza è dalla superficie del canale, non dall'asse")
    func distanceIsFromSurface() throws {
        let canal = straightCanal(radius: 1.5)
        // Cinque millimetri sopra l'asse: meno il raggio fanno 3,5.
        let distance = try #require(canal.signedDistance(from: Vec3(0, 0, 5)))
        #expect(abs(distance - 3.5) < 0.05)
    }

    @Test("Dentro il canale la distanza è negativa")
    func insideIsNegative() throws {
        let canal = straightCanal(radius: 1.5)
        let distance = try #require(canal.signedDistance(from: Vec3(0, 0, 0.5)))
        #expect(distance < 0)
    }

    @Test("Il raggio si interpola fra nodi di calibro diverso")
    func radiusInterpolates() throws {
        // Il calibro cambia lungo il percorso: più ampio verso la spina di Spix, più stretto
        // verso il forame mentoniero. Un raggio costante sbaglierebbe in entrambi i tratti.
        let canal = NerveCanal(
            side: .left,
            nodes: [
                NerveNode(positionMM: Vec3(0, 0, 0), radiusMM: 1.0),
                NerveNode(positionMM: Vec3(10, 0, 0), radiusMM: 2.0),
            ])
        let midpoint = try #require(canal.sample(atParameter: 0.5))
        #expect(abs(midpoint.radius - 1.5) < 1e-9)
    }

    @Test("Il raggio interpolato non diventa mai negativo")
    func radiusStaysPositive() throws {
        // Interpolare il raggio con la spline invece che linearmente potrebbe farlo scendere
        // sotto zero fra nodi molto diversi, e un raggio negativo falserebbe la distanza
        // proprio dove serve massima affidabilità.
        let canal = NerveCanal(
            side: .left,
            nodes: [
                NerveNode(positionMM: Vec3(0, 0, 0), radiusMM: 3.0),
                NerveNode(positionMM: Vec3(5, 0, 0), radiusMM: 0.2),
                NerveNode(positionMM: Vec3(10, 0, 0), radiusMM: 3.0),
            ])
        for step in 0...50 {
            let t = Double(step) / 50.0
            let sample = try #require(canal.sample(atParameter: t))
            #expect(sample.radius > 0, "raggio \(sample.radius) al parametro \(t)")
        }
    }

    @Test("La proiezione sul segmento è limitata agli estremi")
    func segmentProjectionIsClamped() {
        // Senza il clamp la proiezione cadrebbe fuori dal segmento e restituirebbe una
        // distanza minore di quella reale, cioè farebbe sembrare sicuro ciò che non lo è.
        let (distance, t) = distanceToSegment(
            point: Vec3(20, 0, 0), a: Vec3(0, 0, 0), b: Vec3(10, 0, 0))
        #expect(abs(t - 1.0) < 1e-12)
        #expect(abs(distance - 10.0) < 1e-12)
    }

    @Test("Un canale con meno di due nodi non è utilizzabile")
    func needsTwoNodes() {
        #expect(!NerveCanal(side: .right, nodes: []).isUsable)
        #expect(
            !NerveCanal(side: .right, nodes: [NerveNode(positionMM: .zero)]).isUsable)
    }
}

// MARK: - Analisi

@Suite("Analisi di sicurezza")
struct SafetyAnalysisTests {

    private func canal() -> NerveCanal {
        NerveCanal(
            side: .right,
            nodes: (0...4).map {
                NerveNode(positionMM: Vec3(Double($0) * 10 - 20, 0, -18), radiusMM: 1.5)
            })
    }

    private func implant(atHeight z: Double) -> ImplantPlacement {
        let model = ImplantModel(
            manufacturer: "Prova", line: "Cilindrico", diameterMM: 4.0, lengthMM: 10.0,
            profile: [
                ProfilePoint(zMM: 0, radiusMM: 2.0),
                ProfilePoint(zMM: 10, radiusMM: 2.0),
            ])
        return ImplantPlacement(
            model: model, platformMM: Vec3(0, 0, z), axis: Vec3(0, 0, -1), label: "Impianto 1")
    }

    @Test("Un impianto lontano dal canale risulta sicuro")
    func safeWhenFar() {
        // Apice a −5, canale a −18 con raggio 1,5: restano 11,5 mm.
        let report = SafetyAnalyzer.analyze(
            implant: implant(atHeight: 5),
            nerves: [canal()],
            otherImplants: [],
            volume: nil)

        #expect(report.worstLevel == .safe)
        let nerveFinding = report.findings.first { $0.structureName.contains("mandibolare") }
        #expect(nerveFinding != nil)
        #expect((nerveFinding?.distanceMM ?? 0) > 10)
    }

    @Test("Un impianto vicino al canale entra in attenzione")
    func cautionWhenClose() {
        // Apice a −15, canale a −18 con raggio 1,5: restano 1,5 mm, fra 1 e 2.
        let report = SafetyAnalyzer.analyze(
            implant: implant(atHeight: -5),
            nerves: [canal()],
            otherImplants: [],
            volume: nil)
        #expect(report.worstLevel == .caution)
    }

    @Test("Un impianto che invade il canale è critico")
    func dangerWhenOverlapping() {
        // Apice a −18, dentro il canale.
        let report = SafetyAnalyzer.analyze(
            implant: implant(atHeight: -8),
            nerves: [canal()],
            otherImplants: [],
            volume: nil)
        #expect(report.worstLevel == .danger)
    }

    @Test("Le soglie ordinano i livelli correttamente")
    func thresholdLevels() {
        let thresholds = SafetyThresholds.nerve
        #expect(thresholds.level(for: 0.5) == .danger)
        #expect(thresholds.level(for: 1.5) == .caution)
        #expect(thresholds.level(for: 3.0) == .safe)
        #expect(SafetyLevel.danger > SafetyLevel.caution)
        #expect(SafetyLevel.caution > SafetyLevel.safe)
    }

    @Test("Fra impianti adiacenti si misura la distanza fra le superfici")
    func adjacentImplants() {
        let first = implant(atHeight: 0)
        var second = implant(atHeight: 0)
        second = ImplantPlacement(
            model: second.model, platformMM: Vec3(7, 0, 0), axis: Vec3(0, 0, -1),
            label: "Impianto 2")

        let report = SafetyAnalyzer.analyze(
            implant: first, nerves: [], otherImplants: [second], volume: nil)

        // Sette millimetri fra gli assi, meno due raggi da 2: restano 3 mm di osso.
        let finding = report.findings.first { $0.structureName == "Impianto 2" }
        #expect(finding != nil)
        #expect(abs((finding?.distanceMM ?? 0) - 3.0) < 0.2)
    }

    @Test("Il parallelismo riporta lo scostamento massimo")
    func parallelismDeviation() {
        let first = implant(atHeight: 0)
        let tilted = ImplantPlacement(
            model: first.model, platformMM: Vec3(8, 0, 0),
            axis: Vec3(0, 0.5, -0.866), label: "Inclinato")

        let report = SafetyAnalyzer.analyze(
            implant: first, nerves: [], otherImplants: [tilted], volume: nil)

        let deviation = report.maxParallelismDeviationDegrees ?? 0
        #expect(abs(deviation - 30) < 1.0)
    }

    @Test("La densità ossea nel cubo del fantoccio è quella corticale")
    func boneDensityOnPhantom() throws {
        let volume = try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5))

        // Impianto interamente dentro il cubo da 20 mm centrato nell'origine.
        let model = ImplantModel(
            manufacturer: "Prova", line: "Cilindrico", diameterMM: 3.0, lengthMM: 8.0,
            profile: [
                ProfilePoint(zMM: 0, radiusMM: 1.5),
                ProfilePoint(zMM: 8, radiusMM: 1.5),
            ])
        let placement = ImplantPlacement(
            model: model, platformMM: Vec3(0, 0, 4), axis: Vec3(0, 0, -1))

        let profile = try #require(
            SafetyAnalyzer.boneDensity(around: placement, in: volume))

        for band in profile.bands {
            #expect(
                abs(band.mean - SyntheticVolume.corticalBone) < 1.0,
                "\(band.name): \(band.mean)")
            // Il cubo è omogeneo: nessuna dispersione attesa.
            #expect(band.standardDeviation < 1.0)
        }
        #expect(profile.overall.unit == .greyValue)
        #expect(profile.overall.summary.contains("GV"))
    }

    @Test("Un impianto collocato nell'aria legge aria")
    func densityInAir() throws {
        // Verifica che il campionamento segua davvero la posizione dell'impianto e non si
        // limiti a leggere il centro del volume. Quota 17–25 mm: sopra il cubo, che arriva a
        // 10, e lontano dalle sfere, che stanno attorno all'origine.
        let volume = try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5))

        let model = ImplantModel(
            manufacturer: "Prova", line: "Cilindrico", diameterMM: 4.0, lengthMM: 8.0,
            profile: [
                ProfilePoint(zMM: 0, radiusMM: 2.0),
                ProfilePoint(zMM: 8, radiusMM: 2.0),
            ])
        let placement = ImplantPlacement(
            model: model, platformMM: Vec3(0, 0, 25), axis: Vec3(0, 0, -1))

        let profile = try #require(
            SafetyAnalyzer.boneDensity(around: placement, in: volume))
        #expect(
            abs(profile.overall.mean - SyntheticVolume.air) < 1.0,
            "fuori dalle strutture si deve leggere aria, letto \(profile.overall.mean)")
    }
}
