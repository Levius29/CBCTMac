import Foundation

// Quanto un oggetto sta vicino al piano di taglio, e quanto va sfumato di conseguenza.
//
// # Perché è un tipo e non tre righe dentro un disegno
//
// Perché scritte dentro un disegno erano sbagliate e nessuno poteva accorgersene. La regola
// stava in un `Canvas` di SwiftUI, cioè nel bersaglio dell'applicazione, che qui non si compila
// e non si prova: un test non poteva raggiungerla nemmeno volendo. E infatti sbagliava il caso
// più comune di tutti.
//
// L'errore era prendere la **media** delle distanze dei due estremi di un impianto. Si posa un
// impianto cliccando sull'assiale: la piattaforma finisce sul piano — distanza zero — e l'apice
// dieci millimetri sotto. Media cinque millimetri, contro una sfumatura di un diametro, quattro
// virgola uno: opacità negativa, disegno scartato. L'impianto era nell'elenco, era nel piano
// salvato, ed era invisibile in tutte e tre le viste. Da fuori si vedeva una cosa sola — clicco
// e non succede niente.
//
// La grandezza giusta non è una media: è la **distanza minima del corpo dal piano**, che vale
// zero finché il piano lo attraversa. Vale per un impianto, per la sagoma di un dente, per una
// barra: tutti corpi convessi, e per un corpo convesso il piano lo taglia esattamente quando i
// suoi punti stanno da entrambe le parti.
//
// Le distanze in ingresso sono **con segno**, come le restituisce `MPRPlane.pixelPosition`. È
// il segno a portare l'informazione che serve; prendere il valore assoluto troppo presto è
// precisamente il modo in cui la si perde.
public enum PlaneProximity {

    /// Distanza minima di un segmento dal piano, dai valori con segno dei suoi estremi.
    ///
    /// - Returns: zero se il segmento attraversa il piano o lo tocca, altrimenti la distanza
    ///   dell'estremo più vicino.
    public static func distanceMM(from first: Double, to second: Double) -> Double {
        crosses(first, second) ? 0 : Swift.min(abs(first), abs(second))
    }

    /// Distanza minima di un corpo **convesso** dal piano, dai valori con segno dei suoi vertici.
    ///
    /// Convesso è un requisito, non un dettaglio: per una scatola o un cilindro basta guardare i
    /// vertici, per una forma a ferro di cavallo no — il piano potrebbe passare nel vuoto in
    /// mezzo. Gli oggetti del piano implantare sono tutti convessi.
    ///
    /// - Returns: zero per l'insieme vuoto, che non ha una posizione da dichiarare.
    public static func distanceMM(ofConvexBody distances: [Double]) -> Double {
        guard let lowest = distances.min(), let highest = distances.max() else { return 0 }
        return distanceMM(from: lowest, to: highest)
    }

    /// Dove il segmento incontra il piano, come frazione da 0 (primo estremo) a 1 (secondo).
    ///
    /// Quando non lo incontra restituisce l'estremo **più vicino**, cioè 0 o 1: è la quota a cui
    /// guardare la sezione un istante prima che sparisca, e non un valore fuori intervallo che
    /// chi chiama dovrebbe poi ritagliare.
    public static func crossingFraction(from first: Double, to second: Double) -> Double {
        let span = first - second
        guard crosses(first, second), abs(span) > 1e-9 else {
            return abs(first) <= abs(second) ? 0 : 1
        }
        return Swift.min(Swift.max(first / span, 0), 1)
    }

    /// Opacità di sfumatura: piena quando il piano taglia l'oggetto, nulla oltre `fadeOverMM`.
    ///
    /// Si sfuma invece di sparire di netto perché un oggetto che scompare di colpo diventa
    /// difficile da ritrovare, mentre uno disegnato pieno farebbe credere che intersechi la
    /// fetta corrente.
    public static func fadeOpacity(distanceMM: Double, fadeOverMM: Double) -> Double {
        let scale = Swift.max(fadeOverMM, 1e-3)
        return Swift.min(Swift.max(1 - Swift.max(distanceMM, 0) / scale, 0), 1)
    }

    /// Lunghezza di un segmento **proiettata sul piano**, dalla sua lunghezza e dall'inclinazione.
    ///
    /// - Parameter tilt: il coseno dell'angolo fra il segmento e la normale al piano, cioè
    ///   `abs(asse · normale)`. Uno vuol dire perpendicolare al piano, zero disteso dentro.
    ///
    /// Serve a decidere **come** disegnare, non se: un corpo allungato disteso nel piano si
    /// disegna come sagoma, uno che lo buca quasi perpendicolarmente come sezione. Un impianto
    /// visto dall'assiale è un cerchio, e la sagoma di un cilindro visto da un capo degenera in
    /// una scheggia larga zero — che è ciò che si disegnava.
    public static func inPlaneLengthMM(lengthMM: Double, tilt: Double) -> Double {
        let clamped = Swift.min(Swift.max(abs(tilt), 0), 1)
        return lengthMM * (1 - clamped * clamped).squareRoot()
    }

    private static func crosses(_ first: Double, _ second: Double) -> Bool {
        Swift.min(first, second) <= 0 && Swift.max(first, second) >= 0
    }
}
