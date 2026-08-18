import Foundation
import Testing

@testable import MeasureKit

// Test di annulla e ripeti.
//
// Tre di questi controlli riguardano casi che nell'uso normale non si notano e che, sbagliati,
// corrompono il lavoro invece di limitarsi a irritare: la coda del ripeti che sopravvive a una
// modifica, il limite che scarta dalla parte sbagliata, il raggruppamento che non raggruppa.

@Suite("Annulla e ripeti")
struct UndoHistoryTests {

    @Test("Annulla e ripeti percorrono la cronologia nei due versi")
    func walksBothWays() {
        var history = UndoHistory(initial: "a")
        history.commit("b", label: "seconda")
        history.commit("c", label: "terza")

        #expect(history.current == "c")
        #expect(history.undo() == "b")
        #expect(history.undo() == "a")
        #expect(!history.canUndo)
        #expect(history.undo() == nil)
        #expect(history.current == "a")

        #expect(history.redo() == "b")
        #expect(history.redo() == "c")
        #expect(!history.canRedo)
        #expect(history.redo() == nil)
    }

    @Test("Uno stato uguale al corrente non produce un passo")
    func identicalStateIsNotAStep() {
        var history = UndoHistory(initial: 7)
        history.commit(7, label: "niente")
        #expect(!history.canUndo)

        history.commit(8, label: "qualcosa")
        history.commit(8, label: "ancora niente")
        #expect(history.undoCount == 1)
    }

    @Test("Registrare dopo un annulla cancella la coda del ripeti")
    func committingAfterUndoDropsTheRedoTail() {
        var history = UndoHistory(initial: "a")
        history.commit("b", label: "b")
        history.commit("c", label: "c")
        history.undo()
        #expect(history.canRedo)

        history.commit("d", label: "d")
        // Se «c» restasse raggiungibile, un ripeti dopo questa modifica riporterebbe a uno stato
        // che non discende più da quello corrente.
        #expect(!history.canRedo)
        #expect(history.current == "d")
        #expect(history.undo() == "b")
    }

    @Test("Cento chiamate raggruppate diventano un passo solo")
    func coalescingCollapsesADrag() {
        var history = UndoHistory(initial: 0)
        for value in 1...100 {
            history.coalesce(value, label: "Sposta impianto", within: 60)
        }

        #expect(history.current == 100)
        #expect(history.undoCount == 1)
        // Un trascinamento, una pressione: è tutto il punto del raggruppamento.
        #expect(history.undo() == 0)
    }

    @Test("Etichetta diversa o finestra scaduta creano un passo nuovo")
    func coalescingSplitsOnLabelOrTime() {
        var history = UndoHistory(initial: 0)
        history.coalesce(1, label: "Sposta", within: 60)
        history.coalesce(2, label: "Sposta", within: 60)
        #expect(history.undoCount == 1)

        history.coalesce(3, label: "Ruota", within: 60)
        #expect(history.undoCount == 2)

        // Finestra a zero: l'aggiornamento precedente non è mai «recente» abbastanza.
        history.coalesce(4, label: "Ruota", within: 0)
        #expect(history.undoCount == 3)
        #expect(history.undo() == 3)
        #expect(history.undo() == 2)
    }

    @Test("Anche il raggruppamento taglia la coda del ripeti")
    func coalescingAlsoDropsTheRedoTail() {
        var history = UndoHistory(initial: 0)
        history.commit(1, label: "Sposta")
        history.commit(2, label: "Sposta")
        history.undo()
        #expect(history.canRedo)

        history.coalesce(9, label: "Sposta", within: 60)
        #expect(!history.canRedo)
        #expect(history.current == 9)
    }

    @Test("Superato il limite si scarta il più vecchio, non il più recente")
    func theLimitDropsFromTheOldEnd() {
        var history = UndoHistory(initial: 0, limit: 10)
        for value in 1...20 {
            history.commit(value, label: "passo \(value)")
        }

        #expect(history.current == 20)
        #expect(history.undoCount == 10)

        // Dieci annullamenti riportano al decimo stato, non allo zero: i primi dieci sono stati
        // scartati. Se si scartasse dalla coda, «annulla» non toccherebbe l'ultima cosa fatta —
        // che è l'unica su cui lo si preme davvero.
        for _ in 0..<10 { history.undo() }
        #expect(history.current == 10)
        #expect(!history.canUndo)
    }

    @Test("Le etichette dicono che cosa si sta per disfare e rifare")
    func labelsFollowThePosition() {
        var history = UndoHistory(initial: "a")
        #expect(history.undoLabel == nil)
        #expect(history.redoLabel == nil)

        history.commit("b", label: "Aggiungi impianto")
        history.commit("c", label: "Sposta impianto")
        #expect(history.undoLabel == "Sposta impianto")
        #expect(history.redoLabel == nil)

        history.undo()
        #expect(history.undoLabel == "Aggiungi impianto")
        #expect(history.redoLabel == "Sposta impianto")

        history.undo()
        #expect(history.undoLabel == nil)
        #expect(history.redoLabel == "Aggiungi impianto")
    }

    @Test("Azzerare dimentica la cronologia ma tiene lo stato")
    func resetForgetsThePast() {
        var history = UndoHistory(initial: "a")
        history.commit("b", label: "b")
        history.reset(to: "z")

        #expect(history.current == "z")
        #expect(!history.canUndo)
        #expect(!history.canRedo)
    }
}
