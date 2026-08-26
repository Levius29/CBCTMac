import Foundation
import Testing

@testable import StudyKit

// Test delle finestre modali.
//
// La proprietà che conta si enuncia in una riga: **nessuna richiesta si perde e nessun comando
// resta acceso a vuoto**. È la forma verificabile del difetto che l'utente descriveva con «se apro
// una cosa, poi non posso più aprirne altre»: nove booleani indipendenti, uno rimasto `true` dopo
// una presentazione che SwiftUI aveva lasciato cadere, e da lì in poi quella voce di menu non
// apriva più niente.

@Suite("Finestre modali")
struct ModalRouterTests {

    @Test("Si parte senza niente aperto")
    func startsEmpty() {
        let router = ModalRouter()
        #expect(router.presented == nil)
        #expect(router.queued == nil)
        for route in SheetRoute.allCases {
            #expect(!router.isPresenting(route))
        }
    }

    @Test("La prima richiesta apre, la seconda aspetta il suo turno")
    func secondRequestWaits() {
        var router = ModalRouter()
        router.request(.archive)
        #expect(router.presented == .archive)
        #expect(router.queued == nil)

        router.request(.archivePrompt)
        // Ne resta aperta una sola: è il punto.
        #expect(router.presented == .archive)
        #expect(router.queued == .archivePrompt)

        router.dismiss()
        #expect(router.presented == nil)
        // La promozione è un gesto a parte: SwiftUI non presenta mentre chiude.
        #expect(router.promoteQueued() == .archivePrompt)
        #expect(router.presented == .archivePrompt)
        #expect(router.queued == nil)
    }

    @Test("Una richiesta a schermo occupato non si perde")
    func nothingIsDropped() {
        // È la sequenza vera: si apre un esame dall'archivio, il pannello si chiude e il modello
        // chiede subito «lo archivio?». Prima quella domanda finiva nel nulla e il suo
        // interruttore restava acceso per sempre.
        var router = ModalRouter()
        router.request(.archive)
        router.request(.archivePrompt)
        router.dismiss()
        router.promoteQueued()
        #expect(router.presented == .archivePrompt)
    }

    @Test("Chiedere quella già aperta non la mette in coda")
    func requestingTheOpenOneIsInert() {
        var router = ModalRouter()
        router.request(.shortcuts)
        router.request(.shortcuts)
        #expect(router.presented == .shortcuts)
        #expect(router.queued == nil)
    }

    @Test("Chiudere per nome non chiude la modale di qualcun altro")
    func dismissingByNameIsScoped() {
        var router = ModalRouter()
        router.request(.segmentation)
        router.dismiss(.archive)
        #expect(router.presented == .segmentation)

        router.dismiss(.segmentation)
        #expect(router.presented == nil)
    }

    @Test("Chiudere per nome toglie anche dalla coda")
    func dismissingByNameClearsTheQueue() {
        var router = ModalRouter()
        router.request(.archive)
        router.request(.guideBuilder)
        router.dismiss(.guideBuilder)
        #expect(router.queued == nil)

        router.dismiss()
        #expect(router.promoteQueued() == nil)
        #expect(router.presented == nil)
    }

    @Test("L'interruttore booleano non lascia mai uno stato acceso a vuoto")
    func theBooleanFacadeNeverSticks() {
        // Il difetto originale, riprodotto sul tipo che lo rende impossibile: due comandi
        // premuti in fila, e poi di nuovo il primo. Con nove booleani il secondo restava `true`
        // e il primo non apriva più; qui ogni richiesta finisce o aperta o in coda, e la
        // domanda «è acceso?» ha sempre la stessa risposta di «è a schermo?».
        var router = ModalRouter()
        router.setPresented(.artifact, true)
        router.setPresented(.verification, true)
        #expect(router.isPresenting(.artifact))
        #expect(!router.isPresenting(.verification))
        #expect(router.isRequested(.verification))

        router.setPresented(.artifact, false)
        router.promoteQueued()
        #expect(router.isPresenting(.verification))

        router.setPresented(.verification, false)
        #expect(router.presented == nil)
        for route in SheetRoute.allCases {
            #expect(!router.isPresenting(route))
            #expect(!router.isRequested(route))
        }
    }

    @Test("La coda tiene un posto solo, e ci sta l'ultima richiesta")
    func theQueueHoldsOne() {
        var router = ModalRouter()
        router.request(.shortcuts)
        router.request(.archive)
        router.request(.segmentation)
        #expect(router.queued == .segmentation)

        router.dismiss()
        router.promoteQueued()
        #expect(router.presented == .segmentation)
        #expect(router.queued == nil)
    }

    @Test("Promuovere a schermo occupato non scavalca nessuno")
    func promotingIsInertWhileBusy() {
        var router = ModalRouter()
        router.request(.archive)
        router.request(.reformat)
        #expect(router.promoteQueued() == nil)
        #expect(router.presented == .archive)
        #expect(router.queued == .reformat)
    }
}
