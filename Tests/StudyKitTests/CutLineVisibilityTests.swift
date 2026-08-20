import Testing

@testable import StudyKit

// Quanto si vedono le tracce del mirino.
//
// Tre condizioni e una precedenza: nascoste vince su «si sta puntando». Sembra ovvio finché non
// lo si scrive al contrario — e al contrario le linee riapparirebbero al primo trascinamento
// proprio a chi ha premuto il pulsante per toglierle di mezzo.

@Suite("Visibilità delle linee di taglio")
struct CutLineVisibilityTests {

    @Test("A riposo sono sbiadite, non spente")
    func atRestTheyFadeWithoutDisappearing() {
        let visibility = CutLineVisibility()
        #expect(visibility.opacity == CutLineVisibility.restingOpacity)
        #expect(visibility.drawsAnything)
        // Sbiadite vuol dire visibili: un'opacità nulla sarebbe «nascoste», che è un altro stato.
        #expect(visibility.opacity > 0)
        #expect(visibility.opacity < 0.3)
    }

    @Test("Mentre si punta tornano piene")
    func whilePointingTheyGoFull() {
        #expect(CutLineVisibility(isVisible: true, isPointing: true).opacity == 1)
    }

    @Test("Nascoste restano nascoste anche mentre si punta")
    func hiddenBeatsPointing() {
        // La precedenza che conta: chi le ha tolte di mezzo non vuole vederle riapparire appena
        // tocca il mirino.
        let hidden = CutLineVisibility(isVisible: false, isPointing: true)
        #expect(hidden.opacity == 0)
        #expect(!hidden.drawsAnything)
        #expect(!CutLineVisibility(isVisible: false).drawsAnything)
    }

    @Test("L'opacità non esce mai dall'intervallo")
    func opacityStaysInRange() {
        for visible in [true, false] {
            for pointing in [true, false] {
                let opacity = CutLineVisibility(isVisible: visible, isPointing: pointing).opacity
                #expect(opacity >= 0 && opacity <= 1)
            }
        }
    }
}
