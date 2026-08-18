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

    @Test("Con un canale tracciato e l'impianto lontano non si segnala nulla")
    func tracedAndSafeIsSilent() {
        // È l'altra faccia: se si segnalasse comunque, l'avviso perderebbe significato e la gente
        // imparerebbe a ignorarlo — che è come non averlo.
        let one = implant("36")
        let safe = ProximityFinding(
            structureName: "Canale destro", distanceMM: 4.2, level: .safe)
        let issues = PlanReview.issues(
            in: PlanReportInput(
                studyName: "Caso", implants: [one],
                safetyReports: [one.id: report(one, findings: [safe])]))

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
}
