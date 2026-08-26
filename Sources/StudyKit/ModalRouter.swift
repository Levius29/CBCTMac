import Foundation

// Le finestre modali, e la regola che ne tiene aperta una sola.
//
// # Il guasto che ha motivato questo tipo
//
// L'applicazione aveva nove finestre modali e nove interruttori booleani, ciascuno con il proprio
// `.sheet(isPresented:)` impilato sulla stessa vista. SwiftUI però ne presenta **una** per volta:
// se un secondo interruttore va a `true` mentre una modale è già aperta, la richiesta viene
// lasciata cadere e l'interruttore **resta acceso**. Da lì in poi quel comando è morto —
// riportarlo a `true` non cambia un valore che è già `true`, quindi non presenta niente — e la
// voce di menu risponde per sempre con il silenzio.
//
// Non è un caso di laboratorio: `offerToArchive()` accende la domanda «lo archivio?» subito dopo
// l'apertura di un esame, cioè nell'istante in cui il pannello dell'archivio si sta chiudendo. È
// esattamente il difetto che si descrive dicendo «se apro una cosa, poi non posso più aprirne
// altre».
//
// # La correzione, e perché sta qui e non nella vista
//
// Una sola strada: *quale* modale è aperta è un valore, non nove interruttori indipendenti, e uno
// stato illecito — due aperte, o una accesa senza essere visibile — smette di essere
// rappresentabile. La vista ne presenta una sola, `.sheet(item:)`, e il resto è aritmetica su un
// tipo che si può provare senza schermo: vive in StudyKit per la stessa ragione di `ViewportSlot`
// — è **dato**, non interfaccia.
//
// # Perché una richiesta si accoda invece di essere rifiutata
//
// Perché rifiutarla riporta al guasto di prima con altre spoglie: chi chiede di aprire l'archivio
// mentre è aperta la legenda dei comandi non vuole «niente», vuole l'archivio. La richiesta
// aspetta il suo turno e parte alla chiusura. Il posto in attesa è **uno**: se ne arrivano due,
// l'ultima è quella che l'utente ha chiesto per ultima, e le code lunghe di finestre che si
// aprono da sole sono a loro volta un difetto.

/// Le finestre modali dell'applicazione: una per ciascuna, nominate.
///
/// L'elenco è chiuso di proposito. Il controllo degli `switch` esaustivi obbliga chi ne aggiunge
/// una a dire anche **quale vista** presentarla: una modale dichiarata e mai disegnata era
/// l'altra metà del difetto.
public enum SheetRoute: String, CaseIterable, Hashable, Sendable, Identifiable, Codable {
    /// Legenda dei comandi da mouse e tastiera.
    case shortcuts
    /// Ritaglio e ricampionamento in un volume nuovo.
    case reformat
    /// Riduzione delle strie da metallo.
    case artifact
    /// Verifica di accuratezza sul fantoccio.
    case verification
    /// Registrazione della scansione intraorale sul volume.
    case scanRegistration
    /// Costruzione della dima chirurgica.
    case guideBuilder
    /// Segmentazione per soglia.
    case segmentation
    /// L'archivio degli esami.
    case archive
    /// La domanda «lo metto in archivio?» dopo l'apertura di un esame nuovo.
    case archivePrompt

    public var id: String { rawValue }
}

/// Quale modale è aperta, e quale aspetta il suo turno.
public struct ModalRouter: Hashable, Sendable {

    /// La modale visibile adesso. Nessuna quando è `nil`, che è anche lo stato di partenza.
    public private(set) var presented: SheetRoute?

    /// La richiesta arrivata a schermo occupato. Parte alla prima chiusura.
    public private(set) var queued: SheetRoute?

    public init() {}

    public func isPresenting(_ route: SheetRoute) -> Bool { presented == route }

    /// Vero se la modale è aperta **o** in attesa: per chi disegna un comando già premuto.
    public func isRequested(_ route: SheetRoute) -> Bool {
        presented == route || queued == route
    }

    /// Chiede una modale: si apre se il posto è libero, aspetta se è occupato.
    public mutating func request(_ route: SheetRoute) {
        guard presented != route else { return }
        if presented == nil {
            presented = route
            queued = nil
        } else {
            queued = route
        }
    }

    /// Chiude quella aperta, senza promuovere l'attesa.
    ///
    /// La promozione è un gesto a parte — vedi `promoteQueued()` — perché SwiftUI non presenta
    /// una modale nell'istante in cui ne sta chiudendo un'altra: la seconda va chiesta a
    /// chiusura avvenuta, e questo tipo non sa quando sia.
    public mutating func dismiss() {
        presented = nil
    }

    /// Chiude `route` **solo** se è quella aperta, e la toglie comunque dall'attesa.
    ///
    /// Il controllo su quale sia aperta non è pedanteria: un pannello che si spegne da sé
    /// chiuderebbe altrimenti la modale di qualcun altro, che è il difetto di prima al contrario.
    public mutating func dismiss(_ route: SheetRoute) {
        if presented == route { presented = nil }
        if queued == route { queued = nil }
    }

    /// Apre la modale rimasta in attesa, se c'è e se il posto è libero.
    @discardableResult
    public mutating func promoteQueued() -> SheetRoute? {
        guard presented == nil, let next = queued else { return nil }
        queued = nil
        presented = next
        return next
    }

    /// Interruttore per una modale sola, per i comandi che ragionano in booleani.
    ///
    /// Tenere i booleani come *facciata* e non come stato è ciò che permette a una voce di menu
    /// di restare `model.isShowingArchive = true` senza che nessuno possa più lasciarne uno
    /// acceso a vuoto.
    public mutating func setPresented(_ route: SheetRoute, _ isPresented: Bool) {
        if isPresented {
            request(route)
        } else {
            dismiss(route)
        }
    }
}
