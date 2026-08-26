import Foundation
import Testing

@testable import StudyKit

// Test dell'ispettore.
//
// Due proprietà, e sono le due che l'implementazione a catena di `else` violava:
//
// 1. **Non si resta mai senza i comandi di ciò che si guarda.** Qualunque combinazione di scheda,
//    disposizione e riquadro a fuoco, l'ispettore mostra i comandi di almeno una delle immagini
//    che sono a schermo.
// 2. **Nessun contesto ne copre un altro.** Le schede contestuali attive compaiono tutte.

@Suite("Sezioni dell'ispettore")
struct InspectorSectionsTests {

    /// Tutte le combinazioni possibili, che sono poche abbastanza da provarle per intero.
    private static let combinations: [(WorkMode, ViewportLayout, ViewportSlot)] = {
        var result: [(WorkMode, ViewportLayout, ViewportSlot)] = []
        for mode in WorkMode.allCases {
            for layout in ViewportLayout.allCases {
                for slot in ViewportSlot.allCases {
                    result.append((mode, layout, slot))
                }
            }
        }
        return result
    }()

    @Test("Nessuna combinazione lascia l'ispettore senza i comandi di ciò che si guarda")
    func neverWithoutTheControlsOfWhatIsOnScreen() {
        for (mode, layout, slot) in Self.combinations {
            let sections = InspectorSections.sections(
                mode: mode, layout: layout, focusedSlot: slot)
            #expect(!sections.isEmpty)
            if mode == .review { continue }
            // O le immagini 2D, o il 3D: una delle due è sempre a schermo, quindi i suoi comandi
            // devono esserci.
            #expect(sections.contains(.visualization) || sections.contains(.rendering))
        }
    }

    @Test("Il fuoco sul 3D non porta via finestra e livello alle viste rimaste a schermo")
    func focusingTheVolumeKeepsTheDensityWindow() {
        // Il difetto riferito: in griglia 2×2 si fa clic sul 3D per girare il modello mentre si
        // colloca un impianto, e la sezione VISUALIZZAZIONE spariva — con dentro i comandi delle
        // tre viste 2D che erano rimaste a schermo.
        for layout in [ViewportLayout.grid2x2, .onePlusThree] {
            for slot in ViewportSlot.allCases {
                let sections = InspectorSections.sections(
                    mode: .orthogonal, layout: layout, focusedSlot: slot)
                #expect(sections.contains(.visualization))
            }
        }
    }

    @Test("I comandi del 3D ci sono ogni volta che il 3D è disegnato")
    func renderingFollowsTheDrawnVolume() {
        for (mode, layout, slot) in Self.combinations where mode != .review {
            let sections = InspectorSections.sections(
                mode: mode, layout: layout, focusedSlot: slot)
            let drawsVolume = layout.draws(.volume3D, focused: slot)
            #expect(sections.contains(.rendering) == drawsVolume)
            #expect(sections.contains(.orientation) == drawsVolume)
        }
    }

    @Test("Nella disposizione singola comanda ciò che c'è dentro")
    func singleShowsOnlyItsOwnControls() {
        let volume = InspectorSections.sections(
            mode: .orthogonal, layout: .single, focusedSlot: .volume3D)
        #expect(volume.contains(.rendering))
        #expect(!volume.contains(.visualization))

        let axial = InspectorSections.sections(
            mode: .orthogonal, layout: .single, focusedSlot: .axial)
        #expect(axial.contains(.visualization))
        #expect(!axial.contains(.rendering))
    }

    @Test("La panorex porta la sua sezione e non quella del 3D")
    func panoramicBringsTheArch() {
        for slot in ViewportSlot.allCases {
            let sections = InspectorSections.sections(
                mode: .curved, layout: .panoramic, focusedSlot: slot)
            #expect(sections.contains(.arch))
            // La striscia e le sezioni trasversali sono immagini 2D: la finestra le governa.
            #expect(sections.contains(.visualization))
            #expect(!sections.contains(.rendering))
        }
    }

    @Test("In rilettura c'è il piano e nient'altro")
    func reviewIsThePlanAlone() {
        for layout in ViewportLayout.allCases {
            for slot in ViewportSlot.allCases {
                let sections = InspectorSections.sections(
                    mode: .review, layout: layout, focusedSlot: slot)
                #expect(sections == [.review])
            }
        }
    }

    @Test("Ogni sezione è raggiungibile da almeno una combinazione")
    func noSectionIsUnreachable() {
        var seen = Set<InspectorSection>()
        for (mode, layout, slot) in Self.combinations {
            seen.formUnion(
                InspectorSections.sections(mode: mode, layout: layout, focusedSlot: slot))
        }
        #expect(seen == Set(InspectorSection.allCases))
    }

    @Test("Nessuna sezione compare due volte, e le misure chiudono")
    func sectionsAreDistinctAndMeasurementsClose() {
        for (mode, layout, slot) in Self.combinations {
            let sections = InspectorSections.sections(
                mode: mode, layout: layout, focusedSlot: slot)
            #expect(Set(sections).count == sections.count)
            if mode != .review {
                #expect(sections.last == .measurements)
            }
        }
    }

    @Test("I riquadri disegnati sono quelli che la disposizione mostra davvero")
    func drawnSlotsMatchTheLayout() {
        #expect(ViewportLayout.single.drawnSlots(focused: .sagittal) == [.sagittal])
        #expect(ViewportLayout.grid2x2.drawnSlots(focused: .axial) == ViewportSlot.allCases)
        #expect(ViewportLayout.onePlusThree.drawnSlots(focused: .axial) == ViewportSlot.allCases)
        // La panorex disegna l'assiale — è lì che si posa la curva — e nessuno degli altri tre.
        #expect(ViewportLayout.panoramic.drawnSlots(focused: .axial) == [.axial])
        #expect(!ViewportLayout.panoramic.draws(.volume3D, focused: .axial))

        #expect(!ViewportLayout.single.draws(.axial, focused: .coronal))
        #expect(ViewportLayout.single.draws(.coronal, focused: .coronal))
    }
}

@Suite("Schede contestuali dell'ispettore")
struct InspectorContextTests {

    @Test("Nessun contesto ne copre un altro")
    func everyActiveContextIsShown() {
        // Sedici combinazioni: per ciascuna, tante schede quante sono le condizioni vere. La
        // catena di `else if` ne mostrava sempre una sola, ed era il modo in cui la cefalometria
        // rendeva irraggiungibile il pannello dell'impianto.
        for bits in 0..<16 {
            let occlusal = bits & 1 != 0
            let ceph = bits & 2 != 0
            let tooth = bits & 4 != 0
            let implant = bits & 8 != 0

            let contexts = InspectorSections.contexts(
                mode: .orthogonal, occlusalPlane: occlusal, cephalometry: ceph,
                prostheticTooth: tooth, implant: implant)

            let expected = [occlusal, ceph, tooth, implant].filter { $0 }.count
            #expect(contexts.count == expected)
            #expect(contexts.contains(.occlusalPlane) == occlusal)
            #expect(contexts.contains(.cephalometry) == ceph)
            #expect(contexts.contains(.prostheticTooth) == tooth)
            #expect(contexts.contains(.implant) == implant)
        }
    }

    @Test("L'ordine è sempre lo stesso")
    func theOrderIsStable() {
        let all = InspectorSections.contexts(
            mode: .orthogonal, occlusalPlane: true, cephalometry: true, prostheticTooth: true,
            implant: true)
        #expect(all == [.occlusalPlane, .cephalometry, .prostheticTooth, .implant])
        #expect(all == InspectorContext.allCases)
    }

    @Test("Senza niente in mano non c'è nessuna scheda")
    func nothingActiveMeansNoCards() {
        let none = InspectorSections.contexts(
            mode: .orthogonal, occlusalPlane: false, cephalometry: false, prostheticTooth: false,
            implant: false)
        #expect(none.isEmpty)
    }

    @Test("In rilettura non si modifica niente, quindi non c'è nessuna scheda")
    func reviewShowsNoContext() {
        // Un impianto resta selezionato passando a «Rivedi»: se la sua scheda comparisse lo si
        // potrebbe ridimensionare da una scheda che promette di non toccare niente.
        let contexts = InspectorSections.contexts(
            mode: .review, occlusalPlane: true, cephalometry: true, prostheticTooth: true,
            implant: true)
        #expect(contexts.isEmpty)
    }
}
