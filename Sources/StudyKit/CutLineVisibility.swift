import Foundation

/// Quanto si vedono le tracce del mirino e le cornici dei piani.
///
/// # Perché è una regola e non un numero sparso nel disegno
///
/// Perché la stessa decisione vale in cinque posti — le tracce sui tre riquadri ortogonali, le
/// cornici dei piani dentro il rendering 3D — e cinque copie della stessa condizione divergono
/// alla prima modifica: una resterebbe piena mentre le altre sbiadiscono, e chi guarda
/// concluderebbe che il programma è incoerente.
///
/// # Le tre condizioni, e perché sono tre
///
/// **Nascoste.** Le linee attraversano l'immagine da parte a parte, ed è precisamente ciò che le
/// rende utili e ciò che le rende invadenti. Giudicando una corticale o la nitidezza di un
/// contorno, una riga colorata sopra il punto che si sta guardando è rumore.
///
/// **A riposo.** Sbiadite, non spente: dicono ancora dove sta tagliando ogni piano, che è
/// l'informazione per cui esistono, senza competere con l'anatomia.
///
/// **Mentre si punta.** Piene. Spostare il mirino è una manovra di precisione: si sta cercando
/// un punto, e una traccia al venti per cento non si segue.
public struct CutLineVisibility: Hashable, Sendable {

    /// L'opacità a riposo.
    ///
    /// Poco più di un quinto: abbastanza da seguire una linea sapendo che c'è, troppo poco per
    /// attirare l'occhio da sola.
    public static let restingOpacity: Double = 0.22

    /// Se le linee si disegnano affatto.
    public var isVisible: Bool
    /// Se in questo momento si sta spostando il mirino.
    public var isPointing: Bool

    public init(isVisible: Bool = true, isPointing: Bool = false) {
        self.isVisible = isVisible
        self.isPointing = isPointing
    }

    /// L'opacità da usare. Zero quando non si disegna niente.
    ///
    /// Nascoste **vince** su «si sta puntando»: chi ha premuto il pulsante per toglierle di mezzo
    /// non vuole vederle riapparire al primo trascinamento. Se le rivuole, le riaccende.
    public var opacity: Double {
        guard isVisible else { return 0 }
        return isPointing ? 1 : Self.restingOpacity
    }

    /// Se c'è qualcosa da disegnare. Le sovraimpressioni escono subito quando è falso, invece di
    /// calcolare geometrie che finirebbero moltiplicate per zero.
    public var drawsAnything: Bool { opacity > 0 }
}
