import DICOMCore
import Foundation
import ImplantKit
import MeasureKit
import Testing

@testable import ReportKit

// La revisione del piano.
//
// La prova che conta più di tutte è quella sul **falso rassicurante**: un piano con impianti e
// nessun canale tracciato passa l'analisi di sicurezza senza un avviso, perché non c'era nulla
// con cui confrontare. Distinguere «verificato e va bene» da «non verificato» è tutto il lavoro.

@Suite("Revisione del piano")
struct PlanReviewTests {

    private func implant(_ label: String, axis: Vec3 = Vec3(0, 0, -1)) -> ImplantPlacement {
        ImplantPlacement(
            model: ImplantModel(manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(0, 0, 10), axis: axis, label: label)
    }

    private func report(
        _ implant: ImplantPlacement, findings: [ProximityFinding]
    ) -> SafetyReport {
        SafetyReport(
            implantID: implant.id, findings: findings, density: nil,
            maxParallelismDeviationDegrees: nil, angulationDegrees: nil)
    }

    // MARK: Il falso rassicurante

    @Test("Impianti senza alcun canale tracciato sono un blocco, non un silenzio")
    func implantsWithoutTracedStructuresAreBlocking() {
        // Senza canali l'analisi non segnala nulla, e il piano sembra sicuro. Sembrare sicuro per
        // assenza di verifica è il modo peggiore di sembrarlo.
        let one = implant("36")
        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                safetyReports: [one.id: report(one, findings: [])]))

        let blocking = issues.filter { $0.severity == .blocking }
        #expect(blocking.contains { $0.id == "nerve-not-traced" })
        #expect(blocking.first?.detail.contains("assenza di verifica") == true)
    }

    @Test("Un piano completo e senza problemi non segnala nulla")
    func completePlanIsSilent() {
        // È l'altra faccia: se si segnalasse comunque, l'avviso perderebbe significato e la gente
        // imparerebbe a ignorarlo — che è come non averlo.
        //
        // «Completo» vuol dire che ogni verifica è stata **fatta**, non che il piano ha
        // soltanto un impianto: canale tracciato e impianto lontano, dente posato e impianto
        // allineato sotto di esso. Un piano a cui manchi una delle due parla, ed è giusto.
        let one = implant("36")
        let safe = ProximityFinding(
            structureName: "Canale destro", distanceMM: 4.2, level: .safe)
        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                safetyReports: [one.id: report(one, findings: [safe])],
                prostheticConstraints: [one.id: ProstheticConstraint(tooth: tooth(), implant: one)],
                prostheticToothCount: 1))

        #expect(!issues.contains { $0.id == "nerve-not-traced" })
        #expect(issues.isEmpty, "\(issues.map(\.title))")
    }

    @Test("Senza impianti non si chiede di tracciare canali")
    func noImplantsNoNerveRequirement() {
        let issues = PlanReview.issues(in: PlanReportInput(studyName: "Caso"))
        #expect(!issues.contains { $0.id == "nerve-not-traced" })
    }

    // MARK: Gli impianti

    @Test("Una compenetrazione blocca, una prossimità avverte")
    func dangerBlocksAndCautionWarns() {
        let one = implant("36")
        let danger = ProximityFinding(
            structureName: "Canale destro", distanceMM: 0.4, level: .danger)
        let caution = ProximityFinding(
            structureName: "Corticale", distanceMM: 1.6, level: .caution)

        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                safetyReports: [one.id: report(one, findings: [danger, caution])]))

        #expect(issues.contains { $0.severity == .blocking && $0.title.contains("Canale destro") })
        #expect(issues.contains { $0.severity == .warning && $0.title.contains("Corticale") })
    }

    @Test("Un'inclinazione forte si segnala, una modesta no")
    func strongAngulationIsFlagged() {
        let tilted = implant("36", axis: Vec3(0.6, 0, -0.8).normalized!)
        let upright = implant("46", axis: Vec3(0.1, 0, -0.995).normalized!)
        let safe = ProximityFinding(structureName: "Canale", distanceMM: 5, level: .safe)

        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [tilted, upright],
                safetyReports: [
                    tilted.id: report(tilted, findings: [safe]),
                    upright.id: report(upright, findings: [safe]),
                ]))

        #expect(issues.contains { $0.id == "angulation-\(tilted.id)" })
        #expect(!issues.contains { $0.id == "angulation-\(upright.id)" })
    }

    // MARK: Le misure

    @Test("Le misure prese su una proiezione si contano e si spiegano")
    func projectedMeasurementsAreCounted() {
        let context = AcquisitionContext(
            voxelSpacingMM: Vec3(0.2, 0.2, 0.2), slabThicknessMM: 20, projectsThroughSlab: true)
        let annotations = (0..<3).map { index in
            Annotation.distance(
                DistanceMeasurement(
                    metadata: AnnotationMetadata(label: "m\(index)", acquisition: context),
                    startMM: .zero, endMM: Vec3(10, 0, 0)))
        }

        let issues = PlanReview.issues(
            in: PlanReportInput(studyName: "Caso", annotations: annotations))
        let issue = issues.first { $0.id == "measurements-projected" }
        #expect(issue?.title.contains("3 misure") == true)
        #expect(issue?.detail.contains("supera") == true)
    }

    // MARK: La lavorazione

    @Test("Una dima senza registrazione è un blocco")
    func guideWithoutRegistrationBlocks() {
        let issues = PlanReview.issues(
            in: PlanReportInput(studyName: "Caso", guideVolumeMM3: 4000, guideIsPrintable: true))
        #expect(issues.contains { $0.id == "guide-without-registration" && $0.severity == .blocking })
    }

    @Test("Una dima su una registrazione scarsa è un blocco, non un avviso")
    func guideOnPoorRegistrationBlocks() {
        // Mezzo millimetro di disallineamento della scansione è mezzo millimetro che l'impianto
        // sbaglia, e la dima non lo recupera: non è una cosa da «guardare».
        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", registrationRMSMM: 0.9, guideVolumeMM3: 4000,
                guideIsPrintable: true))
        #expect(issues.contains { $0.id == "guide-poor-registration" && $0.severity == .blocking })
    }

    @Test("Senza dima, la registrazione mancante non è un problema")
    func noGuideNoRegistrationRequirement() {
        // Si può misurare senza registrare nulla. Segnalarlo comunque riempirebbe la lista di
        // cose che non riguardano ciò che si sta facendo.
        let issues = PlanReview.issues(in: PlanReportInput(studyName: "Caso"))
        #expect(!issues.contains { $0.id.hasPrefix("guide-") })
    }

    // MARK: L'ordine

    @Test("I blocchi vengono per primi, e l'ordine è stabile")
    func blockingComesFirstAndOrderIsStable() {
        let one = implant("36")
        let danger = ProximityFinding(structureName: "Canale", distanceMM: 0.3, level: .danger)
        let caution = ProximityFinding(structureName: "Seno", distanceMM: 1.7, level: .caution)
        let input = PlanReportInput(
            studyName: "Caso", implants: [one],
            safetyReports: [one.id: report(one, findings: [danger, caution])])

        let first = PlanReview.issues(in: input)
        #expect(first.first?.severity == .blocking)
        // Stabile: la stessa lista fra due aperture della stessa finestra, altrimenti sembra che
        // qualcosa sia cambiato quando non è cambiato niente.
        #expect(PlanReview.issues(in: input).map(\.id) == first.map(\.id))
    }

    // MARK: La verifica protesica

    /// Un dente sopra la piattaforma dell'impianto d'esempio, che sta in (0, 0, 10) con l'asse
    /// verso il basso. Il centro occlusale del dente cade quindi appena sopra la piattaforma.
    private func tooth(axis: Vec3 = Vec3(0, 0, -1), occlusalAt height: Double = 10)
        -> ProstheticTooth
    {
        // `positionMM` è il centro della corona; l'occlusale sta mezza altezza dalla parte
        // opposta all'apice. Con l'asse verso il basso l'occlusale è **sopra** il centro.
        var built = ProstheticTooth(
            toothNumber: 46, positionMM: .zero, axisMM: axis,
            widthMM: 11, heightMM: 7.5, depthMM: 10.5)
        built.positionMM = Vec3(0, 0, height) + axis * (built.heightMM * 0.5)
        return built
    }

    @Test("Impianti senza alcun dente posato: il piano non è corretto, è non verificato")
    func noToothMeansUnverified() {
        let one = implant("46")
        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                safetyReports: [one.id: report(one, findings: [])],
                prostheticToothCount: 0))

        let issue = issues.first { $0.id == "prosthetic-none" }
        #expect(issue != nil)
        #expect(issue?.severity == .warning)
        // Il punto dell'avviso è proprio questo: dire che il silenzio non è un via libera.
        #expect(issue?.detail.contains("non è stato controllato") == true)
    }

    @Test("Senza impianti non si segnala nulla di protesico")
    func noImplantsMeansNoProstheticIssue() {
        let issues = PlanReview.issues(in: PlanReportInput(studyName: "Caso"))
        #expect(!issues.contains { $0.id.hasPrefix("prosthetic-") })
    }

    @Test("Un impianto allineato sotto il suo dente non produce segnalazioni protesiche")
    func alignedImplantIsQuiet() {
        let one = implant("46")
        let crown = tooth()
        let constraint = ProstheticConstraint(tooth: crown, implant: one)
        #expect(constraint.severity == .acceptable)

        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                safetyReports: [one.id: report(one, findings: [])],
                prostheticConstraints: [one.id: constraint],
                prostheticToothCount: 1))
        #expect(!issues.contains { $0.id.hasPrefix("prosthetic-") })
    }

    @Test("Un'emergenza fuori dalla corona è bloccante, e lo dice con la ragione giusta")
    func emergenceOutsideCrownBlocks() {
        // Impianto molto inclinato: partendo da (0, 0, 10) e scendendo, l'asse prolungato verso
        // l'alto esce lateralmente dal perimetro della corona, larga 11 mm.
        let tilted = ImplantPlacement(
            model: ImplantModel(manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(9, 0, 0), axis: Vec3(0, 0, -1), label: "46")
        let constraint = ProstheticConstraint(tooth: tooth(), implant: tilted)
        #expect(!constraint.emergesWithinCrown)

        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [tilted],
                prostheticConstraints: [tilted.id: constraint],
                prostheticToothCount: 1))

        let issue = issues.first { $0.id.hasPrefix("prosthetic-bad-") }
        #expect(issue?.severity == .blocking)
        // La ragione conta quanto la gravità: «divergenza troppo alta» manderebbe a inclinare
        // l'impianto, che qui non risolve niente.
        #expect(issue?.detail.contains("fuori dal perimetro") == true)
        #expect(issue?.detail.contains("moncone angolato recupera") == true)
    }

    @Test("Un asse parallelo all'occlusale è bloccante, e non un'emergenza lontanissima")
    func parallelAxisBlocks() {
        let sideways = ImplantPlacement(
            model: ImplantModel(manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(0, 0, 10), axis: Vec3(1, 0, 0), label: "46")
        let constraint = ProstheticConstraint(tooth: tooth(), implant: sideways)
        #expect(constraint.emergenceMM == nil)

        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [sideways],
                prostheticConstraints: [sideways.id: constraint],
                prostheticToothCount: 1))
        let issue = issues.first { $0.id.hasPrefix("prosthetic-bad-") }
        #expect(issue?.severity == .blocking)
        #expect(issue?.detail.contains("parallelo al piano occlusale") == true)
    }

    @Test("Con denti posati, un impianto senza dente sopra si segnala a parte")
    func orphanImplantIsItsOwnIssue() {
        let one = implant("46")
        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                prostheticConstraints: [:],
                prostheticToothCount: 2))

        // Non «non verificato»: i denti ci sono, è questo impianto a non averne uno sopra.
        #expect(!issues.contains { $0.id == "prosthetic-none" })
        let issue = issues.first { $0.id.hasPrefix("prosthetic-orphan-") }
        #expect(issue?.severity == .warning)
    }

    @Test("Una divergenza da attenzione è un avviso, non un blocco")
    func cautionDivergenceIsAWarning() {
        let twenty = 20.0 * Double.pi / 180
        let axis = Vec3(Foundation.sin(twenty), 0, -Foundation.cos(twenty))
        let tilted = ImplantPlacement(
            model: ImplantModel(manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(0, 0, 10), axis: axis, label: "46")
        let constraint = ProstheticConstraint(tooth: tooth(), implant: tilted)
        #expect(constraint.severity == .caution)

        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [tilted],
                prostheticConstraints: [tilted.id: constraint],
                prostheticToothCount: 1))
        let issue = issues.first { $0.id.hasPrefix("prosthetic-caution-") }
        #expect(issue?.severity == .warning)
        #expect(!issues.contains { $0.id.hasPrefix("prosthetic-bad-") })
    }

    @Test("La relazione distingue la colonna vuota dal controllo non fatto")
    func reportTellsUnverifiedFromEmpty() {
        let one = implant("46")

        let unverified = PlanReport.html(
            PlanReportInput(studyName: "Caso", implants: [one], prostheticToothCount: 0))
        #expect(unverified.contains("non verificato"))
        #expect(unverified.contains("Nessun dente protesico è stato posato"))

        let withTeeth = PlanReport.html(
            PlanReportInput(
                studyName: "Caso", implants: [one],
                prostheticConstraints: [one.id: ProstheticConstraint(tooth: tooth(), implant: one)],
                prostheticToothCount: 1))
        #expect(!withTeeth.contains("non verificato"))
        #expect(withTeeth.contains("Divergenza"))
    }
}
