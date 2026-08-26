import Foundation
import Testing

@testable import StudyKit

// Test dei modi di lavoro.
//
// La proprietà che conta è una sola e si enuncia in una riga: **ciò che si regola in un modo lo
// si ritrova tornandoci**. Sembra scontata e non lo è — l'implementazione ovvia, un solo campo
// `layout` riassegnato al cambio di scheda, la viola senza che nulla se ne accorga, e il sintomo
// arriva solo quando l'utente torna su una scheda e trova la disposizione di fabbrica.

@Suite("Modi di lavoro")
struct WorkspaceSessionTests {

    @Test("Ogni modo parte dalla propria disposizione di fabbrica")
    func defaultsPerMode() {
        var session = WorkspaceSession()
        #expect(session.mode == .orthogonal)
        #expect(session.layout == .grid2x2)

        session.activate(.curved)
        #expect(session.layout == .panoramic)

        session.activate(.review)
        #expect(session.layout == .grid2x2)
        #expect(session.focusedSlot == .volume3D)
    }

    @Test("Quello che si regola in un modo si ritrova tornandoci")
    func layoutSurvivesTheRoundTrip() {
        var session = WorkspaceSession()
        session.layout = .single
        session.focusedSlot = .sagittal

        session.activate(.curved)
        // La scheda curva ha la **sua** disposizione, non quella appena scelta altrove.
        #expect(session.layout == .panoramic)
        session.layout = .onePlusThree

        session.activate(.orthogonal)
        #expect(session.layout == .single)
        #expect(session.focusedSlot == .sagittal)

        session.activate(.curved)
        #expect(session.layout == .onePlusThree)
    }

    @Test("Il riquadro a fuoco è sempre uno che la disposizione disegna")
    func theFocusIsAlwaysDrawn() {
        // Il fuoco e la disposizione si scelgono per vie diverse e sopravvivono l'uno all'altra:
        // chi lavorava sul sagittale e passa alla panorex si portava dietro un fuoco che lì non
        // è disegnato, e da quel momento l'istantanea, la stampa e l'esportazione riguardavano
        // una vista che non si vedeva.
        for mode in WorkMode.allCases {
            for layout in ViewportLayout.allCases {
                for slot in ViewportSlot.allCases {
                    var session = WorkspaceSession(mode: mode)
                    session.layout = layout
                    session.focusedSlot = slot
                    let focus = session.focusedSlot
                    #expect(layout.drawnSlots(focused: focus).contains(focus))
                }
            }
        }
    }

    @Test("La panorex mette a fuoco l'assiale, e restituisce il resto uscendo")
    func panoramicFocusesTheAxialAndGivesItBack() {
        var session = WorkspaceSession()
        session.layout = .grid2x2
        session.focusedSlot = .sagittal

        session.layout = .panoramic
        #expect(session.focusedSlot == .axial)

        // La preferenza non è stata riscritta: si corregge in lettura, quindi tornando indietro
        // si ritrova il riquadro su cui si stava lavorando.
        session.layout = .grid2x2
        #expect(session.focusedSlot == .sagittal)
    }

    @Test("Attivare il modo già attivo non tocca nulla")
    func activatingTheCurrentModeIsInert() {
        var session = WorkspaceSession()
        session.layout = .single
        session.activate(.orthogonal)
        #expect(session.layout == .single)
    }

    @Test("Si azzera un modo per volta")
    func resetIsPerMode() {
        var session = WorkspaceSession()
        session.layout = .single
        session.activate(.curved)
        session.layout = .grid2x2

        #expect(session.hasCustomLayout(.orthogonal))
        #expect(session.hasCustomLayout(.curved))

        session.reset(.curved)
        #expect(!session.hasCustomLayout(.curved))
        #expect(session.layout == .panoramic)

        // L'altro modo non è stato toccato: è la differenza fra «rimetti a posto questa scheda» e
        // «rimetti a posto tutto», e sono due comandi diversi.
        #expect(session.hasCustomLayout(.orthogonal))
        session.activate(.orthogonal)
        #expect(session.layout == .single)
    }

    @Test("La sessione si serializza e si rilegge identica")
    func sessionRoundTripsThroughCoding() throws {
        var session = WorkspaceSession()
        session.layout = .single
        session.activate(.oblique)
        session.focusedSlot = .axial

        let data = try JSONEncoder().encode(session)
        let restored = try JSONDecoder().decode(WorkspaceSession.self, from: data)

        #expect(restored == session)
        #expect(restored.mode == .oblique)
        #expect(restored.focusedSlot == .axial)
        var back = restored
        back.activate(.orthogonal)
        #expect(back.layout == .single)
    }

    @Test("Rivedi è l'unico modo di sola lettura")
    func onlyReviewIsReadOnly() {
        let readOnly = WorkMode.allCases.filter { !$0.isEditable }
        #expect(readOnly == [.review])
        #expect(WorkMode.allCases.filter(\.usesArchCurve) == [.curved])
    }

    @Test("Nomi, icone e spiegazioni ci sono per tutti i modi, e sono distinti")
    func everyModeIsPresentable() {
        let names = WorkMode.allCases.map(\.shortName)
        let icons = WorkMode.allCases.map(\.systemImageName)
        let hints = WorkMode.allCases.map(\.hint)
        #expect(names.count == 5)
        #expect(Set(names).count == 5)
        #expect(Set(icons).count == 5)
        #expect(!names.contains { $0.isEmpty })
        // Le spiegazioni devono essere distinte in particolare fra «personalizzato» e «obliquo»,
        // che condividono la disposizione: se dicessero la stessa cosa le due schede sarebbero
        // indistinguibili, che è il difetto che la spiegazione esiste per evitare.
        #expect(Set(hints).count == 5)
        #expect(!hints.contains { $0.isEmpty })
    }
}
