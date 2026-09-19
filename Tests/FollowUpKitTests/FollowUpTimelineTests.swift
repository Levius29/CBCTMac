import DICOMCore
import Foundation
import Testing

@testable import FollowUpKit

// La regola che queste prove sorvegliano è una sola, ed è quella che decide se il confronto dice
// la verità: **una data si mostra solo se è pronta**. Tutto il resto — ordine, intervalli, coda —
// è contorno di quella.

@Suite("Storia delle date")
struct FollowUpTimelineTests {

    private func day(_ offset: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(Double(offset) * 86_400)
    }

    /// Tre date dello stesso paziente. Le prove di questa suite girano su copie indipendenti,
    /// quindi gli identificatori possono stare qui e valere per tutte.
    private let ids = [UUID(), UUID(), UUID()]

    private func makeTimeline() -> FollowUpTimeline {
        var timeline = FollowUpTimeline()
        // Aggiunte fuori ordine di proposito: l'ordine lo fa la data, non la sequenza di arrivo.
        timeline.add(FollowUpStudy(id: ids[1], label: "sei mesi", acquiredOn: day(180)))
        timeline.add(FollowUpStudy(id: ids[0], label: "prima", acquiredOn: day(0)))
        timeline.add(FollowUpStudy(id: ids[2], label: "un anno", acquiredOn: day(365)))
        return timeline
    }

    @Test("Le date stanno in ordine di acquisizione, non di arrivo")
    func studiesAreSortedByDate() {
        let timeline = makeTimeline()
        #expect(timeline.studies.map(\.id) == [ids[0], ids[1], ids[2]])
    }

    @Test("La prima data aggiunta diventa il riferimento")
    func firstStudyBecomesReference() {
        var timeline = FollowUpTimeline()
        let first = FollowUpStudy(label: "prima", acquiredOn: day(0))
        timeline.add(first)
        timeline.add(FollowUpStudy(label: "dopo", acquiredOn: day(90)))
        #expect(timeline.referenceID == first.id)
    }

    @Test("Gli intervalli sono i giorni veri fra un esame e l'altro")
    func gapsAreRealDays() {
        let timeline = makeTimeline()
        #expect(timeline.daysBetween(ids[0], and: ids[1]) == 180)
        #expect(timeline.daysBetween(ids[1], and: ids[2]) == 185)
        #expect(timeline.daysBetween(ids[2], and: ids[0]) == -365)
        #expect(timeline.daysFromReference(ids[2]) == 365)
    }

    @Test("Una data non pronta non si mostra, in nessuno dei modi in cui può non esserlo")
    func onlyReadyStudiesAreDisplayed() {
        var timeline = makeTimeline()
        #expect(!timeline.canDisplay(ids[1]))

        timeline.setState(.queued, forStudy: ids[1])
        #expect(!timeline.canDisplay(ids[1]))

        timeline.setState(.running(stage: "Allineamento, livello 1 di 3"), forStudy: ids[1])
        #expect(!timeline.canDisplay(ids[1]))

        timeline.setState(.failed(reason: "gli esami non si sovrappongono"), forStudy: ids[1])
        #expect(!timeline.canDisplay(ids[1]))

        timeline.setState(.ready(coverage: 0.88), forStudy: ids[1])
        #expect(timeline.canDisplay(ids[1]))
        #expect(timeline.displayable.map(\.id) == [ids[1]])
    }

    @Test("Lo scorrimento salta le date non pronte invece di mostrare la precedente")
    func playbackSkipsUnreadyStudies() {
        var timeline = makeTimeline()
        timeline.setState(.ready(coverage: 0.9), forStudy: ids[2])
        // ids[1] resta da allineare: la storia va dal riferimento direttamente all'anno.
        #expect(timeline.playbackOrder == [ids[0], ids[2]])
        #expect(timeline.studyAfter(ids[0]) == ids[2])
        #expect(timeline.studyAfter(ids[2]) == nil)
        #expect(timeline.studyBefore(ids[2]) == ids[0])
        #expect(timeline.studyBefore(ids[0]) == nil)
    }

    @Test("La coda prende tutte le date non pronte, e non il riferimento")
    func queueTakesEverythingPending() {
        var timeline = makeTimeline()
        timeline.setState(.ready(coverage: 0.9), forStudy: ids[2])

        #expect(timeline.queueAllPending() == 1)
        #expect(timeline.nextQueued?.id == ids[1])
        #expect(timeline.study(ids[0])?.state == .notPrepared)
        #expect(timeline.study(ids[2])?.state == .ready(coverage: 0.9))

        // Rilanciarla non accoda niente due volte.
        #expect(timeline.queueAllPending() == 0)

        timeline.cancelQueue()
        #expect(timeline.nextQueued == nil)
        #expect(timeline.study(ids[1])?.state == .notPrepared)
    }

    @Test("Annullare la coda non tocca ciò che sta già girando")
    func cancellingLeavesRunningAlone() {
        var timeline = makeTimeline()
        timeline.setState(.running(stage: "in corso"), forStudy: ids[1])
        timeline.setState(.queued, forStudy: ids[2])

        timeline.cancelQueue()
        #expect(timeline.study(ids[1])?.state == .running(stage: "in corso"))
        #expect(timeline.study(ids[2])?.state == .notPrepared)
    }

    @Test("Cambiare riferimento fa decadere gli allineamenti verso quello vecchio")
    func changingReferenceInvalidatesAlignments() {
        var timeline = makeTimeline()
        timeline.setState(.ready(coverage: 0.9), forStudy: ids[1])
        timeline.setState(.ready(coverage: 0.8), forStudy: ids[2])

        timeline.setReference(ids[2])
        #expect(timeline.referenceID == ids[2])
        #expect(timeline.displayable.isEmpty)
        #expect(timeline.studies.allSatisfy { $0.state == .notPrepared })
    }

    @Test("Togliere il riferimento ne sceglie un altro invece di lasciare il vuoto")
    func removingTheReferencePicksAnother() {
        var timeline = makeTimeline()
        timeline.remove(studyID: ids[0])
        #expect(timeline.referenceID == ids[1])
        #expect(timeline.studies.count == 2)
    }
}
