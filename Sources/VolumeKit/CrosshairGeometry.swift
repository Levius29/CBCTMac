import DICOMCore
import Foundation

// Geometria delle linee del mirino, e delle maniglie con cui si ruotano.
//
// # Perché questo file esiste
//
// Fino a qui le due linee del mirino erano disegnate come una verticale e una orizzontale a
// metà riquadro. È giusto **solo** finché i tre piani restano allineati agli assi della
// macchina: dal primo taglio obliquo in poi la linea disegnata e il piano che dovrebbe
// rappresentare divergono, e l'immagine mente su dove sta tagliando.
//
// La verità è che una linea del mirino non è una decorazione a croce: è la **traccia** di un
// altro piano su questo, cioè l'intersezione fra due piani. Calcolarla costa dieci righe e
// resta corretta comunque siano orientati; disegnarla a croce costa due righe e resta corretta
// finché nessuno tocca nulla.
//
// # Perché le maniglie, e non il trascinamento con modificatore
//
// L'inclinazione del taglio esisteva già, con ⇧ + trascinamento. Funzionava e non si vedeva:
// nessun segno sullo schermo diceva che quel gesto esistesse, né su quale piano agisse.
//
// C'è anche una ragione numerica, e non è secondaria. Il gesto naturale — «afferra la linea e
// giracela» — ha una singolarità sul perno: col puntatore a un pixel dal mirino, uno
// spostamento di un pixel produce una rotazione arbitraria. È il motivo per cui il vecchio
// codice derivava l'angolo dallo spostamento invece che dalla posizione. Una maniglia elimina
// il problema alla radice invece di aggirarlo: sta **lontana** dal perno per costruzione, e a
// quella distanza l'angolo sotteso è una funzione ben condizionata della posizione del dito.
// Si può quindi tornare al gesto diretto, che è anche quello che si capisce senza spiegazioni.

// MARK: - Punto in pixel

/// Punto in coordinate pixel del riquadro.
///
/// Un tipo proprio invece di `CGPoint` perché questo modulo deve compilare anche dove
/// CoreGraphics non c'è — è la condizione che permette di provare questa geometria qui invece
/// che sul Mac, ed è il motivo per cui è provata.
public struct PixelPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to o: PixelPoint) -> Double {
        let dx = x - o.x, dy = y - o.y
        return (dx * dx + dy * dy).squareRoot()
    }
}

// MARK: - Che cosa si è afferrato

/// Parte di una traccia sotto il puntatore.
public enum CrosshairGrip: Hashable, Sendable {
    /// Il corpo della linea: trascinandolo si sposta il piano che essa rappresenta.
    case line
    /// Una delle due maniglie: trascinandola si ruota.
    ///
    /// `isStart` distingue i due capi. Serve perché ruotando si segue il capo afferrato, e
    /// scambiare i due farebbe girare la linea di 180° al primo movimento.
    case handle(isStart: Bool)
}

// MARK: - La traccia

/// L'intersezione di un piano con la vista di un altro, già in pixel e già tagliata al riquadro.
public struct CrosshairTrace: Hashable, Sendable {

    /// I due estremi visibili, sui bordi del riquadro.
    public var start: PixelPoint
    public var end: PixelPoint

    /// Le due maniglie di rotazione, o `nil` se il tratto visibile è troppo corto per grattarle.
    public var startHandle: PixelPoint?
    public var endHandle: PixelPoint?

    /// Il mirino proiettato: è il perno della rotazione, e sta sulla retta per costruzione.
    public var pivot: PixelPoint

    /// Direzione della retta nello spazio Patient, unitaria. Serve a chi vuole ragionare in
    /// millimetri senza rifare la proiezione.
    public var directionMM: Vec3

    /// Normale del piano rappresentato, unitaria: è la direzione in cui trascinando lo si sposta.
    public var normalMM: Vec3

    /// Asse attorno a cui la maniglia ruota: la normale della vista che ospita la traccia.
    public var rotationAxisMM: Vec3

    /// Lunghezza del tratto visibile, in pixel.
    public var lengthPixels: Double { start.distance(to: end) }
}

// MARK: - Costruzione

public enum CrosshairGeometry {

    /// Quanto lontano dai capi stanno le maniglie, in frazione del tratto visibile.
    public static let handleFraction = 0.12

    /// Sotto questa lunghezza visibile le maniglie non compaiono.
    ///
    /// Non è una soglia estetica. Su un tratto di venti pixel le due maniglie e il vuoto centrale
    /// si sovrappongono, e ogni pressione ne prende una a caso: meglio nessuna maniglia che una
    /// maniglia che fa una cosa diversa ogni volta.
    public static let minimumLengthForHandles = 64.0

    /// Raggio del vuoto centrale, in pixel: lì il clic sposta il mirino e non afferra le linee.
    public static let centreGapPixels = 12.0

    /// Traccia del piano `other` nella vista `view`, passando per `pointMM`.
    ///
    /// - Parameter pointMM: il mirino. Sta su entrambi i piani per costruzione — `AppModel` lo
    ///   garantisce riallineando i piani a ogni suo spostamento — quindi è un punto della retta
    ///   d'intersezione e non c'è alcun sistema da risolvere. Se un domani quell'invariante
    ///   cadesse, il sintomo sarebbe una linea parallela a quella giusta ma spostata: da qui la
    ///   verifica esplicita più sotto.
    /// - Returns: `nil` se i due piani sono paralleli, se il mirino non giace sulla vista, o se
    ///   la retta non attraversa il riquadro.
    public static func trace(
        of other: MPRPlane,
        in view: MPRPlane,
        through pointMM: Vec3,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CrosshairTrace? {
        guard pixelWidth > 0, pixelHeight > 0, pointMM.isFinite else { return nil }

        let viewNormal = view.normalMM
        let otherNormal = other.normalMM

        // Piani paralleli: nessuna intersezione, e il prodotto vettoriale degenere darebbe una
        // direzione arbitraria invece di un errore. La soglia è sul seno dell'angolo: 1e-6 sono
        // circa sei millesimi di grado, ben sotto qualunque obliquità che si possa impostare.
        let axis = viewNormal.cross(otherNormal)
        guard axis.length > 1e-6, let direction = axis.normalized else { return nil }

        // Il mirino deve stare sulla vista, altrimenti la retta disegnata non sarebbe quella che
        // si vede. La tolleranza è larga perché il riallineamento passa da somme in virgola
        // mobile, non perché ci si aspetti uno scarto vero.
        guard abs((pointMM - view.centerMM).dot(viewNormal)) < 1e-3 else { return nil }

        let pivotProjection = view.pixelPosition(
            ofPatient: pointMM, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let pivot = PixelPoint(x: pivotProjection.x, y: pivotProjection.y)

        // La direzione in pixel si ottiene proiettando un secondo punto e sottraendo, invece di
        // rifare a mano la divisione per il passo del pixel. La proiezione è affine, quindi il
        // risultato è esatto per qualunque passo — e soprattutto resta l'**unica** conversione
        // fra millimetri e pixel del programma. Due conversioni scritte in due posti diversi
        // sono due conversioni che prima o poi divergono.
        let ahead = view.pixelPosition(
            ofPatient: pointMM + direction, pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let ux = ahead.x - pivot.x
        let uy = ahead.y - pivot.y
        guard ux.isFinite, uy.isFinite, (ux * ux + uy * uy) > 1e-12 else { return nil }

        // Il rettangolo visibile va da −½ a larghezza−½, non da 0 a larghezza. Non è pignoleria:
        // `pixelPosition` restituisce l'indice del **centro** del pixel, quindi il centro del
        // riquadro cade a (larghezza−1)/2 e l'area davvero coperta dai pixel comincia mezzo pixel
        // prima del primo centro. Con gli estremi a 0 e larghezza il tratto risulta spostato di
        // mezzo pixel verso l'alto a sinistra, e le due maniglie finiscono a distanze diverse dal
        // perno anche quando il mirino è esattamente al centro — che è come me ne sono accorto.
        guard
            let span = clipToRect(
                originX: pivot.x, originY: pivot.y,
                dx: ux, dy: uy,
                minX: -0.5, minY: -0.5,
                maxX: Double(pixelWidth) - 0.5, maxY: Double(pixelHeight) - 0.5)
        else { return nil }

        let start = PixelPoint(x: pivot.x + ux * span.lower, y: pivot.y + uy * span.lower)
        let end = PixelPoint(x: pivot.x + ux * span.upper, y: pivot.y + uy * span.upper)

        var startHandle: PixelPoint?
        var endHandle: PixelPoint?
        if start.distance(to: end) >= minimumLengthForHandles {
            startHandle = PixelPoint(
                x: start.x + (end.x - start.x) * handleFraction,
                y: start.y + (end.y - start.y) * handleFraction)
            endHandle = PixelPoint(
                x: end.x - (end.x - start.x) * handleFraction,
                y: end.y - (end.y - start.y) * handleFraction)
        }

        return CrosshairTrace(
            start: start,
            end: end,
            startHandle: startHandle,
            endHandle: endHandle,
            pivot: pivot,
            directionMM: direction,
            normalMM: otherNormal,
            rotationAxisMM: viewNormal)
    }

    /// Ritaglio parametrico di una retta contro un rettangolo (Liang–Barsky).
    ///
    /// Restituisce l'intervallo di `s` per cui `origine + s·direzione` sta dentro, o `nil` se la
    /// retta lo manca del tutto — cosa che succede davvero: ingrandendo e spostando l'immagine il
    /// mirino esce dal riquadro, e allora non c'è nessuna linea da disegnare.
    static func clipToRect(
        originX: Double, originY: Double,
        dx: Double, dy: Double,
        minX: Double, minY: Double,
        maxX: Double, maxY: Double
    ) -> (lower: Double, upper: Double)? {
        var lower = -Double.greatestFiniteMagnitude
        var upper = Double.greatestFiniteMagnitude

        // Ogni bordo dà una disuguaglianza `p·s ≤ q`. Con `p == 0` la retta è parallela a quel
        // bordo: allora o è dentro per sempre o fuori per sempre, e il segno di `q` lo dice.
        func clip(_ p: Double, _ q: Double) -> Bool {
            if abs(p) < 1e-12 { return q >= 0 }
            let r = q / p
            if p < 0 {
                if r > upper { return false }
                if r > lower { lower = r }
            } else {
                if r < lower { return false }
                if r < upper { upper = r }
            }
            return true
        }

        guard clip(-dx, originX - minX),
            clip(dx, maxX - originX),
            clip(-dy, originY - minY),
            clip(dy, maxY - originY)
        else { return nil }

        guard upper > lower else { return nil }
        return (lower, upper)
    }
}

// MARK: - Interrogazione

extension CrosshairTrace {

    /// Che cosa sta sotto il puntatore, se qualcosa.
    ///
    /// Le maniglie vincono sul corpo della linea anche se la linea è più vicina: sono lì apposta,
    /// e sono l'unico modo di ruotare. Il vuoto attorno al perno non risponde, perché lì il clic
    /// serve a spostare il mirino e le due tracce si incrociano — qualunque cosa si scegliesse
    /// sarebbe quella sbagliata metà delle volte.
    public func grip(at point: PixelPoint, slopPixels: Double = 9) -> CrosshairGrip? {
        // Le maniglie hanno un'area di presa più generosa della linea: sono piccole, si mirano, e
        // mancarle di due pixel significa spostare la fetta invece di ruotarla.
        let handleSlop = slopPixels + 3
        if let startHandle, point.distance(to: startHandle) <= handleSlop {
            return .handle(isStart: true)
        }
        if let endHandle, point.distance(to: endHandle) <= handleSlop {
            return .handle(isStart: false)
        }
        guard point.distance(to: pivot) > CrosshairGeometry.centreGapPixels else { return nil }
        return distance(from: point) <= slopPixels ? .line : nil
    }

    /// Distanza dal segmento visibile, in pixel.
    public func distance(from point: PixelPoint) -> Double {
        let vx = end.x - start.x, vy = end.y - start.y
        let lengthSquared = vx * vx + vy * vy
        guard lengthSquared > 1e-12 else { return point.distance(to: start) }
        let t = ((point.x - start.x) * vx + (point.y - start.y) * vy) / lengthSquared
        let clamped = min(max(t, 0), 1)
        return point.distance(to: PixelPoint(x: start.x + vx * clamped, y: start.y + vy * clamped))
    }

    /// Angolo di rotazione fra due posizioni del puntatore, attorno al perno.
    ///
    /// Il segno è già quello giusto per `MPRPlane.rotated(aboutAxis: rotationAxisMM, ...)`, e non
    /// è un caso fortunato: la normale della vista vale `destra × giù`, quindi una rotazione
    /// positiva attorno a essa porta `destra` verso `giù`, cioè +x verso +y. A schermo l'asse y
    /// punta in basso, quindi anche `atan2(Δy, Δx)` cresce nello stesso verso. Le due convenzioni
    /// coincidono, e il test lo verifica invece di fidarsi di questo ragionamento.
    ///
    /// - Returns: l'angolo in radianti in `(−π, π]`, o `nil` se una delle due posizioni è troppo
    ///   vicina al perno perché l'angolo significhi qualcosa.
    public func rotation(from previous: PixelPoint, to current: PixelPoint) -> Double? {
        let minimumRadius = 6.0
        guard previous.distance(to: pivot) > minimumRadius,
            current.distance(to: pivot) > minimumRadius
        else { return nil }

        let before = Foundation.atan2(previous.y - pivot.y, previous.x - pivot.x)
        let after = Foundation.atan2(current.y - pivot.y, current.x - pivot.x)
        var delta = after - before
        while delta > .pi { delta -= 2 * .pi }
        while delta <= -.pi { delta += 2 * .pi }
        return delta
    }

    /// Di quanto spostare **il mirino** per un trascinamento del corpo della linea.
    ///
    /// Si restituisce lo spostamento del mirino e non quello del piano perché è il mirino il
    /// punto che i tre piani hanno in comune: muovere il solo piano rappresentato lo lascerebbe
    /// fuori da esso, e da lì in poi la traccia non passerebbe più per il perno che disegna.
    ///
    /// Solo la componente lungo la normale del piano rappresentato conta. Scorrere *lungo* la
    /// linea non cambia quale fetta essa mostra, e recepire anche quella componente farebbe
    /// scorrere la fetta in risposta a un movimento che visibilmente non la tocca.
    public func slide(
        from previous: PixelPoint,
        to current: PixelPoint,
        in view: MPRPlane,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Vec3 {
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }
        let before = view.patientPoint(
            atPixelX: previous.x, y: previous.y,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let after = view.patientPoint(
            atPixelX: current.x, y: current.y,
            pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let movement = after - before
        return normalMM * movement.dot(normalMM)
    }
}
