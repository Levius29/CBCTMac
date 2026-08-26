import Foundation

// Che cosa mostra l'ispettore, deciso qui e non dentro la vista.
//
// # I due guasti che hanno motivato questo file
//
// **Primo: una sezione che sparisce.** L'ispettore sceglieva i propri controlli con una catena di
// `if`/`else if` sul riquadro a fuoco. In griglia 2×2 sono a schermo tre viste 2D e il 3D: basta
// fare clic sul 3D — cosa che si fa per girare il modello mentre si colloca un impianto — e la
// sezione VISUALIZZAZIONE spariva, con dentro finestra e livello, cioè i comandi con cui si
// giudica la corticale sulle tre viste che sono rimaste a schermo. Non erano coperti: erano
// assenti, e per riaverli bisognava indovinare che il modo era tornare a fare clic su una vista
// 2D.
//
// **Secondo: comandi che agiscono al buio.** Gli stessi controlli — spessore e proiezione —
// parlano al riquadro a fuoco. Nella disposizione panorex quel riquadro **non è disegnato**:
// si muovevano cursori che non cambiavano niente di visibile.
//
// # La regola
//
// Una sezione compare se e solo se governa qualcosa che è a schermo, e questo si decide da
// `layout` e `focusedSlot` — non da quale sezione ha vinto una catena di `else`. Detto così è una
// funzione pura di due enum, e allora sta qui: si prova senza schermo, e i test dicono per
// costruzione che non esiste una combinazione in cui l'ispettore resti senza i comandi di ciò che
// si sta guardando.
//
// È la stessa ragione per cui `ViewportSlot` vive in StudyKit e non nell'applicazione: quali
// riquadri esistono, e quali comandi li governano, è **dato**. Il colore e l'icona sono
// interfaccia e restano di là.

/// Le sezioni dell'ispettore, nell'ordine in cui scendono.
public enum InspectorSection: String, CaseIterable, Hashable, Sendable, Identifiable, Codable {
    /// In rilettura l'ispettore non è un pannello di comandi: è il piano.
    case review
    /// Finestra di densità, spessore dello slab, proiezione: come si guardano le immagini 2D.
    case visualization
    /// Panorex e sezioni trasversali.
    case arch
    /// Transfer function, qualità, illuminazione del riquadro 3D.
    case rendering
    /// Le tre viste canoniche e l'inquadratura del 3D.
    case orientation
    /// Come si comporta la rotella. È una preferenza, non un parametro del caso: sta in fondo.
    case scrolling
    /// L'elenco delle misure poste.
    case measurements

    public var id: String { rawValue }
}

/// Ciò su cui si sta lavorando adesso, in cima all'ispettore.
///
/// # Perché sono un elenco e non una scelta
///
/// Erano una catena di `else if`, e la prima condizione vera copriva le altre. La cefalometria
/// stava prima dell'impianto: aperta una volta dal menu, il pannello dell'impianto non tornava
/// più — non perché fosse spento, ma perché qualcun altro occupava il posto. Chi ci si trovava
/// dentro concludeva, ragionevolmente, che il programma si fosse rotto.
///
/// Due contesti attivi insieme sono uno stato legittimo: si posano i reperi cefalometrici **e**
/// si tiene selezionato un impianto. Mostrarli entrambi costa qualche riga di ispettore;
/// mostrarne uno solo costa l'accesso all'altro.
public enum InspectorContext: String, CaseIterable, Hashable, Sendable, Identifiable, Codable {
    /// I tre punti del piano occlusale.
    case occlusalPlane
    /// Reperi cefalometrici e profilo del viso.
    case cephalometry
    /// La sagoma del dente protesico.
    case prostheticTooth
    /// Impianto, barra protesica e canale alveolare.
    case implant

    public var id: String { rawValue }
}

/// Le due decisioni sull'ispettore, in forma di funzioni pure.
public enum InspectorSections {

    /// Le sezioni da mostrare, date la scheda di lavoro e ciò che la disposizione disegna.
    ///
    /// - Parameters:
    ///   - mode: la scheda di lavoro attiva.
    ///   - layout: la disposizione dei riquadri.
    ///   - focusedSlot: il riquadro a fuoco, che in disposizione «singolo» è anche l'unico
    ///     disegnato.
    public static func sections(
        mode: WorkMode, layout: ViewportLayout, focusedSlot: ViewportSlot
    ) -> [InspectorSection] {
        // In rilettura l'ispettore è il piano, e nient'altro: gli strumenti di modifica non sono
        // in mano, quindi i loro controlli mentirebbero.
        if mode == .review { return [.review] }

        var result: [InspectorSection] = []

        // Finestra e livello governano **tutte** le immagini 2D a schermo, comprese la panorex e
        // le sezioni trasversali. Compaiono quindi anche mentre il fuoco è sul 3D, che è
        // esattamente il caso in cui prima sparivano.
        let showsImages = layout.showsWindowedImages(focused: focusedSlot)
        if showsImages { result.append(.visualization) }

        if layout == .panoramic { result.append(.arch) }

        // I comandi del 3D quando il 3D è disegnato, non quando è a fuoco: in griglia 2×2 il
        // modello è a schermo sempre, e pretendere un clic dentro il riquadro prima di poterne
        // cambiare la resa è un gesto che non serve a nulla.
        if layout.draws(.volume3D, focused: focusedSlot) {
            result.append(.rendering)
            result.append(.orientation)
        }

        if showsImages { result.append(.scrolling) }

        result.append(.measurements)
        return result
    }

    /// Le schede contestuali attive, nell'ordine canonico.
    ///
    /// Tutte quelle vere, non la prima: vedi `InspectorContext`.
    public static func contexts(
        occlusalPlane: Bool, cephalometry: Bool, prostheticTooth: Bool, implant: Bool
    ) -> [InspectorContext] {
        var result: [InspectorContext] = []
        if occlusalPlane { result.append(.occlusalPlane) }
        if cephalometry { result.append(.cephalometry) }
        if prostheticTooth { result.append(.prostheticTooth) }
        if implant { result.append(.implant) }
        return result
    }
}
