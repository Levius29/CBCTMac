import DICOMCore
import Foundation

// Il piano di taglio arbitrario, definito tracciando una linea.
//
// # Che cosa significa «tagliare lungo una linea»
//
// Si disegna un segmento su una vista — sull'assiale, lungo l'asse di un dente o lungo una
// cresta — e si vuole vedere la sezione **lungo** quel segmento. Il piano che serve è quello
// che contiene la linea ed è perpendicolare alla vista da cui la si è disegnata: perpendicolare
// perché altrimenti la sezione taglierebbe di sbieco e mostrerebbe una struttura più larga di
// quanto sia, che è l'errore che le sezioni trasversali della panorex esistono per evitare.
//
// # Perché non basta ruotare le maniglie del mirino
//
// Perché le maniglie ruotano **a sentimento**: si trascina finché l'immagine sembra giusta.
// Disegnando una linea si dichiara l'asse guardandolo, e la differenza si sente su un dente
// inclinato di dieci gradi, dove la rotazione a mano sbaglia sempre di qualche grado e la
// misura che ne esce è più corta del vero.

public enum FreePlane: Sendable {

    /// Costruisce il piano che contiene il segmento ed è perpendicolare al piano d'origine.
    ///
    /// - Parameters:
    ///   - fromMM: primo estremo del segmento, in millimetri Patient.
    ///   - toMM: secondo estremo.
    ///   - sourceNormalMM: normale della vista su cui il segmento è stato disegnato.
    ///   - widthMM: larghezza della finestra da mostrare.
    ///   - heightMM: altezza della finestra.
    ///
    /// - Returns: `nil` quando il segmento è troppo corto per definire una direzione, o quando
    ///   giace lungo la normale della vista — casi in cui il piano non esiste, e restituirne uno
    ///   qualunque darebbe una sezione che l'utente non ha chiesto e non riconosce.
    public static func plane(
        fromMM: Vec3,
        toMM: Vec3,
        sourceNormalMM: Vec3,
        widthMM: Double,
        heightMM: Double
    ) -> MPRPlane? {
        guard fromMM.isFinite, toMM.isFinite, sourceNormalMM.isFinite else { return nil }
        guard let normal = sourceNormalMM.normalized else { return nil }

        // La direzione **proiettata** sul piano d'origine: un segmento disegnato su una vista
        // giace già in quella vista, ma il punto che ne deriva può portarsi dietro un residuo
        // fuori piano quando la conversione clic-millimetri passa da uno slab spesso.
        let raw = toMM - fromMM
        let flattened = raw - normal * raw.dot(normal)
        // Un millimetro: sotto, la direzione è dominata dall'imprecisione del clic, e il piano
        // che ne uscirebbe ruoterebbe di decine di gradi fra due tentativi identici.
        guard flattened.length >= 1.0, let direction = flattened.normalized else { return nil }

        // Il nuovo piano contiene `direction` e `normal`: la sua normale è il loro prodotto
        // vettoriale, che è perpendicolare a entrambi per costruzione.
        guard let newNormal = direction.cross(normal).normalized else { return nil }

        // Orizzontale del nuovo riquadro: la direzione disegnata, così la struttura che si è
        // indicata compare distesa da sinistra a destra invece che di sbieco.
        let down = newNormal.cross(direction).normalized ?? normal
        return MPRPlane(
            centerMM: (fromMM + toMM) * 0.5,
            rightMM: direction,
            downMM: down,
            widthMM: widthMM,
            heightMM: heightMM)
    }

    /// Fra più piani esistenti, quello la cui normale somiglia di più a quella data.
    ///
    /// Serve a decidere **quale riquadro** debba mostrare il taglio nuovo. Sostituire quello
    /// più simile è la scelta che disturba meno: il riquadro cambia di poco, gli altri due
    /// restano i riferimenti, e chi guarda non perde l'orientamento. Sostituire il riquadro da
    /// cui si è disegnato lo farebbe sparire proprio mentre lo si sta usando.
    ///
    /// - Returns: `nil` se l'elenco è vuoto.
    public static func closest<Key: Hashable>(
        to normalMM: Vec3, among planes: [Key: MPRPlane], excluding excluded: Set<Key> = []
    ) -> Key? {
        var best: (key: Key, alignment: Double)?
        for (key, plane) in planes where !excluded.contains(key) {
            let alignment = Swift.abs(plane.normalMM.dot(normalMM))
            guard alignment.isFinite else { continue }
            if best == nil || alignment > best!.alignment {
                best = (key, alignment)
            }
        }
        return best?.key
    }
}
