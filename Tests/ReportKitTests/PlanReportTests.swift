import DICOMCore
import Foundation
import ImplantKit
import MeasureKit
import Testing

@testable import ReportKit

// La relazione.
//
// Le prove non guardano l'impaginazione: guardano che **nulla di essenziale sparisca**. Un
// avvertimento che non compare, un'incertezza che si perde, un commento dell'utente che spezza il
// documento a metà — sono tutti modi in cui una relazione mente senza sembrare rotta.

@Suite("Relazione del piano")
struct PlanReportTests {

    private func context(slab: Double = 0, projects: Bool = false) -> AcquisitionContext {
        AcquisitionContext(
            voxelSpacingMM: Vec3(0.2, 0.2, 0.2),
            slabThicknessMM: slab,
            projectsThroughSlab: projects)
    }

    private func distance(_ label: String, context: AcquisitionContext?) -> Annotation {
        .distance(
            DistanceMeasurement(
                metadata: AnnotationMetadata(label: label, acquisition: context),
                startMM: .zero, endMM: Vec3(12.4732, 0, 0)))
    }

    // MARK: L'avvertenza

    @Test("L'avvertenza sta in cima, non in fondo")
    func disclaimerComesFirst() {
        let html = PlanReport.html(PlanReportInput(studyName: "Caso"))
        let warningIndex = try! #require(html.range(of: "Uso non diagnostico")).lowerBound
        let titleIndex = try! #require(html.range(of: "<h1>")).lowerBound
        #expect(warningIndex < titleIndex, "l'avvertenza deve precedere il titolo")
    }

    @Test("L'avvertenza dice che i valori sono GV e non HU")
    func disclaimerNamesTheUnit() {
        // È il Contratto 4 applicato al documento che esce. Una relazione che stampa densità
        // senza dirlo lascia confrontare con soglie di letteratura che non valgono.
        let html = PlanReport.html(PlanReportInput(studyName: "Caso"))
        #expect(html.contains("valori grigi"))
        #expect(html.contains("Hounsfield"))
    }

    // MARK: Le misure e il loro contesto

    @Test("Ogni misura porta la propria incertezza")
    func measurementsCarryTheirUncertainty() {
        let html = PlanReport.html(
            PlanReportInput(studyName: "Caso", annotations: [distance("15-d", context: context())]))
        #expect(html.contains("15-d"))
        #expect(html.contains("± 0,10 mm"), "incertezza assente dal documento")
    }

    @Test("Un avvertimento sullo slab non sparisce nella relazione")
    func slabCaveatSurvivesIntoTheReport() {
        // È il punto in cui una misura smette di essere verificabile: da qui in poi viaggia da
        // sola, e se l'avvertimento resta nel programma la relazione afferma una distanza che è
        // solo un limite inferiore.
        let html = PlanReport.html(
            PlanReportInput(
                studyName: "Caso",
                annotations: [distance("36-m", context: context(slab: 20, projects: true))]))
        #expect(html.contains("proiezione"), "avvertimento sullo slab perso")
    }

    @Test("Una misura senza contesto lo dichiara invece di tacere")
    func missingContextIsDeclared() {
        // Un piano salvato prima che il contratto esistesse non porta il contesto. Tacere
        // lascerebbe credere che quel numero abbia la stessa incertezza degli altri.
        let html = PlanReport.html(
            PlanReportInput(studyName: "Caso", annotations: [distance("vecchia", context: nil)]))
        #expect(html.contains("non registrato"))
    }

    @Test("Senza misure lo dice, invece di lasciare una tabella vuota")
    func emptyPlanSaysSo() {
        let html = PlanReport.html(PlanReportInput(studyName: "Caso"))
        #expect(html.contains("Nessuna misura"))
    }

    // MARK: La provenienza

    @Test("La catena del volume compare per intero")
    func provenanceChainIsComplete() {
        // Una misura presa su un volume con le strie ridotte non è una misura sul dato acquisito,
        // e chi legge la relazione un mese dopo non ha altro modo di saperlo.
        let html = PlanReport.html(
            PlanReportInput(
                studyName: "Caso",
                volumeProvenance: ["Serie CBCT importata", "Riduzione strie", "Ritaglio"]))
        #expect(html.contains("Serie CBCT importata"))
        #expect(html.contains("Riduzione strie"))
        #expect(html.contains("Ritaglio"))
    }

    // MARK: Gli impianti

    @Test("Un riscontro critico si distingue da uno tranquillo")
    func dangerousFindingsAreMarked() {
        let implant = ImplantPlacement(
            model: ImplantModel(manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(0, 0, 10), axis: Vec3(0, 0, -1), label: "36")
        let report = SafetyReport(
            implantID: implant.id,
            findings: [
                ProximityFinding(
                    structureName: "Canale destro", distanceMM: 0.4, level: .danger)
            ],
            density: nil,
            maxParallelismDeviationDegrees: nil,
            angulationDegrees: 0)

        let html = PlanReport.html(
            PlanReportInput(
                studyName: "Caso", implants: [implant],
                safetyReports: [implant.id: report]))

        #expect(html.contains("Canale destro"))
        #expect(html.contains("class=\"danger\""), "il livello critico non si distingue")
    }

    @Test("Si dichiara che l'incertezza del tracciato non è nei numeri")
    func nerveTracingUncertaintyIsDeclared() {
        // È la voce dominante e non compare in nessun numero: il canale è tracciato a mano, e
        // «0,4 mm dal canale» ha la precisione di chi ha posato i nodi.
        let implant = ImplantPlacement(
            model: ImplantModel(manufacturer: "P", line: "R", diameterMM: 4, lengthMM: 10),
            platformMM: Vec3(0, 0, 10), axis: Vec3(0, 0, -1), label: "36")
        let html = PlanReport.html(PlanReportInput(studyName: "Caso", implants: [implant]))
        #expect(html.contains("tracciato a mano"))
    }

    // MARK: La lavorazione

    @Test("Una dima che non supera le verifiche lo dice in grassetto")
    func unprintableGuideIsFlagged() {
        let html = PlanReport.html(
            PlanReportInput(
                studyName: "Caso", guideVolumeMM3: 4200, guideIsPrintable: false,
                guideWarnings: ["Parete sottile in zona 36"]))
        #expect(html.contains("<strong>verifiche non superate</strong>"))
        #expect(html.contains("Parete sottile"))
    }

    // MARK: Il testo dell'utente

    @Test("Un commento con marcatura non spezza il documento")
    func userTextIsEscaped() {
        // Le etichette le scrive l'utente. Un carattere `<` in un'etichetta finirebbe nel
        // documento come marcatura: la relazione si interromperebbe lì, senza che nulla lo
        // segnali, e chi la stampa non se ne accorgerebbe.
        let html = PlanReport.html(
            PlanReportInput(
                studyName: "Caso <b>importante</b>",
                annotations: [distance("36 <script>alert(1)</script>", context: context())]))

        #expect(!html.contains("<script>"), "marcatura dell'utente finita nel documento")
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("Caso &lt;b&gt;importante&lt;/b&gt;"))
    }

    @Test("Ogni carattere si sostituisce una volta sola, senza raddoppi")
    func escapingDoesNotDoubleSubstitute() {
        // Il difetto da cui questa forma protegge è quello della catena di sostituzioni: chi
        // sostituisce `<` prima di `&` ri-sostituisce la `&amp;` appena prodotta, e ottiene
        // `&amp;amp;` — che a schermo si legge come testo invece che come simbolo.
        //
        // Scorrendo i caratteri il problema non può presentarsi, ed è il motivo della forma.
        // Questa prova lo **fissa**: chi un giorno la riscrivesse con `replacingOccurrences`
        // vedrebbe fallire l'ultima riga.
        #expect(PlanReport.escape("a & b") == "a &amp; b")
        #expect(PlanReport.escape("<a>") == "&lt;a&gt;")
        #expect(PlanReport.escape("&lt;") == "&amp;lt;", "una sola passata, nessun raddoppio")
        #expect(PlanReport.escape("&amp;") == "&amp;amp;")
    }

    // MARK: Struttura

    @Test("Il documento è HTML completo e autonomo")
    func documentIsSelfContained() {
        // Autonomo perché deve poter essere aperto e stampato senza il programma: nessun
        // riferimento a file esterni, nessun carattere da scaricare.
        let html = PlanReport.html(PlanReportInput(studyName: "Caso"))
        #expect(html.hasPrefix("<!doctype html>"))
        #expect(html.contains("</html>"))
        #expect(!html.contains("http://"), "nessuna risorsa esterna")
        #expect(!html.contains("https://"))
    }
}
