import DICOMCore
import Foundation
import VolumeKit

// Geometria del panorex e delle sezioni trasversali.
//
// Le due viste nascono dalla stessa curva e dalla stessa macchina di ricampionamento, per cui
// arrivano insieme: il panorex è uno slab **lungo** la curva, le sezioni trasversali sono piani
// **perpendicolari** a essa. Cambia l'orientamento del taglio, non il modo di ricavarlo.
//
// Le sezioni trasversali non richiedono alcun codice di rendering nuovo: sono `MPRPlane`, e le
// disegna il kernel MPR che esiste già. È il motivo per cui quel kernel è stato scritto attorno
// a un piano arbitrario invece che ai tre assi anatomici.
//
// Swift puro: la geometria si verifica senza GPU.

// MARK: - Panorex

/// Impostazioni della ricostruzione panoramica.
public struct PanoramicLayout: Hashable, Sendable {

    public var curve: ArchCurve

    /// Estensione verticale dell'immagine, in millimetri.
    public var heightMM: Double
    /// Quota del centro dell'immagine lungo l'asse verticale del paziente.
    public var verticalCentreMM: Double
    /// Spessore campionato attorno alla curva, lungo la normale vestibolo-linguale.
    ///
    /// Su un panorex questo parametro conta più che altrove: sotto i 10 mm si vede una fetta
    /// sola e i denti fuori dalla curva spariscono; sopra i 30 tutto si sovrappone e l'immagine
    /// diventa una nebbia. Venti millimetri è il valore che assomiglia di più a una
    /// panoramica vera.
    public var slabThicknessMM: Double
    public var projection: SlabProjection

    /// Risoluzione dell'immagine ricostruita.
    public var millimetresPerPixel: Double

    public init(
        curve: ArchCurve,
        heightMM: Double = 70,
        verticalCentreMM: Double = 0,
        slabThicknessMM: Double = 20,
        projection: SlabProjection = .maximum,
        millimetresPerPixel: Double = 0.2,
        zoom: Double = 1,
        arcCentreMM: Double? = nil
    ) {
        self.curve = curve
        self.heightMM = max(heightMM, 1)
        self.verticalCentreMM = verticalCentreMM
        self.slabThicknessMM = max(slabThicknessMM, 0)
        self.projection = projection
        self.millimetresPerPixel = max(millimetresPerPixel, 0.01)
        self.zoom = zoom
        self.arcCentreMM = arcCentreMM
    }

    /// Larghezza naturale in pixel, pari alla lunghezza della curva alla risoluzione scelta.
    public var naturalPixelWidth: Int {
        max(1, Int((curve.lengthMM / millimetresPerPixel).rounded()))
    }

    public var naturalPixelHeight: Int {
        max(1, Int((heightMM / millimetresPerPixel).rounded()))
    }

    /// Campioni della curva, uno per colonna di pixel.
    ///
    /// Un campione per colonna esatto, così lo shader indicizza direttamente il buffer senza
    /// interpolare: tutta la matematica della spline resta sulla CPU e in Double.
    public func columnSamples(pixelWidth: Int) -> [ArchSample] {
        let count = max(pixelWidth, 2)

        // A ingrandimento 1 la finestra è l'intera curva: si usa il ricampionamento uniforme, che
        // fa cadere il primo campione esattamente su 0 e l'ultimo su `lengthMM`. Passando dalle
        // lunghezze d'arco si perderebbero mezzo pixel per lato senza alcun vantaggio.
        guard effectiveZoom > 1 else {
            return curve.resampled(count: count)
        }

        let range = visibleArcRangeMM
        let step = (range.upperBound - range.lowerBound) / Double(count)
        // Centro del pixel, come altrove: il campione sta a metà della colonna che rappresenta.
        let lengths = (0..<count).map { range.lowerBound + (Double($0) + 0.5) * step }
        return curve.samples(atArcLengthsMM: lengths)
    }

    /// Lunghezza d'arco corrispondente a una colonna di pixel.
    ///
    /// È la conversione che serve all'interazione: sapere su che punto dell'arcata sta il cursore
    /// per ancorarci lo zoom, e per portare le altre viste al punto cliccato.
    public func arcLengthMM(atPixelX x: Double, pixelWidth: Int) -> Double {
        guard pixelWidth > 0 else { return clampedArcCentreMM }
        let range = visibleArcRangeMM
        let fraction = (x + 0.5) / Double(pixelWidth)
        return range.lowerBound + fraction * (range.upperBound - range.lowerBound)
    }

    /// Ingrandisce mantenendo fermo il punto dell'arcata sotto un pixel.
    ///
    /// Stessa ragione dello zoom ancorato dei riquadri MPR: ingrandendo attorno al centro, il dente
    /// che si sta guardando scappa dal cursore e va rincorso scorrendo.
    public func zoomed(by factor: Double, aboutPixelX x: Double, pixelWidth: Int) -> PanoramicLayout {
        guard factor > 0, factor.isFinite, pixelWidth > 0 else { return self }

        let anchor = arcLengthMM(atPixelX: x, pixelWidth: pixelWidth)
        var copy = self
        copy.zoom = max(1, effectiveZoom * factor)

        // Il punto d'ancoraggio deve ricadere sulla stessa frazione di larghezza dopo lo zoom.
        let fraction = (x + 0.5) / Double(pixelWidth)
        let newHalf = copy.visibleArcHalfLengthMM
        copy.arcCentreMM = anchor - (fraction - 0.5) * newHalf * 2
        return copy
    }

    /// Scorre la finestra lungo l'arcata di un numero di millimetri d'arco.
    public func scrolled(byArcMM delta: Double) -> PanoramicLayout {
        guard delta.isFinite else { return self }
        var copy = self
        copy.arcCentreMM = clampedArcCentreMM + delta
        return copy
    }

    /// Ingrandimento orizzontale. A 1 l'arcata intera riempie la larghezza del riquadro.
    ///
    /// È ciò che rende possibile scorrere: senza ingrandimento la finestra visibile *è* l'intera
    /// curva, e non c'è niente in cui scorrere. Con `zoom = 2` si vede metà arcata alla volta e la
    /// si percorre trascinando, come una finestra su un'immagine più lunga.
    public var zoom: Double = 1

    /// Lunghezza d'arco al centro dell'immagine. `nil` significa il centro della curva.
    ///
    /// Viene sempre limitata perché la finestra resti dentro la curva: scorrendo oltre un capo
    /// dell'arcata si ferma contro il capo invece di mostrare colonne vuote. È il comportamento di
    /// una finestra su un contenuto finito, e ha il vantaggio di non richiedere colonne "cieche"
    /// nello shader.
    public var arcCentreMM: Double?

    /// Ingrandimento efficace, non inferiore a 1.
    ///
    /// Sotto 1 l'arcata occuperebbe meno della larghezza disponibile, lasciando bande vuote ai
    /// lati: si può fare, ma non serve a nulla e complica la geometria per niente.
    public var effectiveZoom: Double {
        guard zoom.isFinite else { return 1 }
        return max(1, zoom)
    }

    /// Semiampiezza della finestra visibile, in lunghezza d'arco.
    public var visibleArcHalfLengthMM: Double {
        curve.lengthMM / (2 * effectiveZoom)
    }

    /// Centro della finestra visibile, limitato perché la finestra resti dentro la curva.
    public var clampedArcCentreMM: Double {
        let half = visibleArcHalfLengthMM
        let requested = arcCentreMM ?? curve.lengthMM / 2
        guard requested.isFinite else { return curve.lengthMM / 2 }
        // A zoom 1 gli estremi coincidono e il centro è forzato a metà curva, che è giusto.
        return min(max(requested, half), curve.lengthMM - half)
    }

    /// Intervallo di lunghezza d'arco inquadrato.
    public var visibleArcRangeMM: ClosedRange<Double> {
        let centre = clampedArcCentreMM
        let half = visibleArcHalfLengthMM
        return (centre - half)...(centre + half)
    }

    /// Millimetri per pixel effettivi, **uguali sui due assi**.
    ///
    /// Qui c'era il difetto che rendeva il panorex inservibile, e vale la pena scriverlo per
    /// intero perché è istruttivo. La scala orizzontale non è mai stata una scelta: il renderer
    /// ricampiona tutta la curva su `pixelWidth` colonne, quindi vale per costruzione
    /// `lunghezzaCurva / larghezza`. La verticale invece usava `millimetresPerPixel`, un valore
    /// fisso di 0,2 mm.
    ///
    /// Le due non coincidono quasi mai, e le conseguenze erano tre in una: l'immagine risultava
    /// schiacciata in altezza, perché ogni pixel verticale copriva più millimetri di uno
    /// orizzontale; copriva solo `altezzaPannello × 0,2` mm invece dei 70 richiesti; e partendo
    /// dal bordo alto di quella finestra da 70 mm era tutta sbilanciata verso l'alto.
    ///
    /// L'aspetto era il sintomo meno grave. Con due scale diverse **una misura verticale sul
    /// panorex non è confrontabile con una orizzontale**, ed è precisamente ciò per cui un
    /// panorex ricostruito viene usato.
    ///
    /// Ora la scala è una sola e la ricava la larghezza: la curva riempie sempre il riquadro in
    /// orizzontale, e l'estensione verticale visibile segue da lì. Un riquadro più alto mostra
    /// più anatomia, non la stessa anatomia più stirata.
    public func millimetresPerPixel(pixelWidth: Int) -> Double {
        guard pixelWidth > 0, curve.lengthMM > 0 else { return millimetresPerPixel }
        return curve.lengthMM / (effectiveZoom * Double(pixelWidth))
    }

    /// Estensione verticale effettivamente inquadrata, in millimetri.
    ///
    /// Non è `heightMM`: quella resta la dimensione *richiesta*, usata per la risoluzione
    /// naturale. Quella mostrata dipende dall'altezza del riquadro, perché la scala è isotropa.
    public func visibleHeightMM(pixelWidth: Int, pixelHeight: Int) -> Double {
        millimetresPerPixel(pixelWidth: pixelWidth) * Double(max(pixelHeight, 1))
    }

    /// Passo verticale in millimetri per pixel, verso il basso dello schermo.
    ///
    /// Negativo lungo l'asse verticale del paziente perché sullo schermo il basso corrisponde
    /// ai piedi, come nelle viste coronale e sagittale.
    public func downStepMM(pixelWidth: Int) -> Vec3 {
        (curve.upAxis * -1.0) * millimetresPerPixel(pixelWidth: pixelWidth)
    }

    /// Punto Patient del centro del pixel `(0, 0)` per una data colonna.
    ///
    /// L'immagine è centrata su `verticalCentreMM`: il primo pixel sta `(altezza − 1)/2` passi
    /// più in alto. Con `(altezza − 1)/2` e non `altezza/2` la simmetria è esatta — la quota
    /// richiesta cade sul centro del pixel di mezzo quando le righe sono in numero dispari, e
    /// fra i due centrali quando è pari — e non serve alcuna correzione di mezzo pixel.
    public func topOfColumn(_ sample: ArchSample, pixelWidth: Int, pixelHeight: Int) -> Vec3 {
        let up = curve.upAxis
        let columnCentre =
            sample.positionMM
            - up * sample.positionMM.dot(up)
            + up * verticalCentreMM
        let scale = millimetresPerPixel(pixelWidth: pixelWidth)
        return columnCentre + up * (scale * Double(max(pixelHeight, 1) - 1) * 0.5)
    }

    /// Passo dello slab lungo la normale vestibolo-linguale, per una colonna.
    public func slabStep(for sample: ArchSample, sampleCount: Int) -> Vec3 {
        guard sampleCount > 1, slabThicknessMM > 0 else { return .zero }
        return sample.normal * (slabThicknessMM / Double(sampleCount - 1))
    }

    /// Numero di campioni dello slab, al passo del voxel più fine.
    public func slabSampleCount(geometry: VolumeGeometry) -> Int {
        guard slabThicknessMM > 0 else { return 1 }
        let spacing = geometry.spacingMM
        let step = min(spacing.x, min(spacing.y, spacing.z))
        guard step > 0 else { return 1 }
        // Limite superiore prudenziale: uno slab da 30 mm su voxel da 0,15 mm chiederebbe
        // duecento campioni per pixel, e con due milioni di pixel diventa mezzo miliardo di
        // letture. Oltre i 96 campioni il guadagno visivo è nullo e il costo no.
        return min(max(1, Int((slabThicknessMM / step).rounded()) + 1), 96)
    }

    /// Estremi in millimetri dell'immagine, per la barra di scala.
    public var extentMM: (width: Double, height: Double) {
        (curve.lengthMM, heightMM)
    }
}

// MARK: - Sezioni trasversali

/// Una sezione perpendicolare alla curva.
public struct CrossSection: Hashable, Sendable, Identifiable {
    public var id: Int { index }
    /// Posizione nella sequenza, da 0.
    public let index: Int
    /// Distanza dall'inizio della curva, in millimetri.
    public let arcLengthMM: Double
    /// Piano di taglio, pronto per il kernel MPR esistente.
    public let plane: MPRPlane
    /// Punto sulla curva da cui la sezione è generata.
    public let originMM: Vec3

    public init(index: Int, arcLengthMM: Double, plane: MPRPlane, originMM: Vec3) {
        self.index = index
        self.arcLengthMM = arcLengthMM
        self.plane = plane
        self.originMM = originMM
    }

    /// Etichetta per la UI, per esempio `12 · 24,0 mm`.
    public var label: String {
        String(format: "%d · %.1f mm", index + 1, arcLengthMM)
            .replacingOccurrences(of: ".", with: ",")
    }
}

/// Impostazioni della griglia di sezioni trasversali.
///
/// È la vista che si usa davvero per valutare cresta ossea e pianificare un impianto: mostra
/// altezza e spessore dell'osso nel punto esatto, cosa che né il panorex né le viste ortogonali
/// riescono a dare.
public struct CrossSectionLayout: Hashable, Sendable {

    public var curve: ArchCurve
    /// Distanza fra due sezioni consecutive.
    public var intervalMM: Double
    /// Larghezza di ciascuna sezione, in direzione vestibolo-linguale.
    public var widthMM: Double
    /// Altezza di ciascuna sezione.
    public var heightMM: Double
    public var verticalCentreMM: Double
    /// Spessore campionato, lungo la tangente alla curva.
    public var thicknessMM: Double
    public var projection: SlabProjection

    public init(
        curve: ArchCurve,
        intervalMM: Double = 1.0,
        widthMM: Double = 30,
        heightMM: Double = 45,
        verticalCentreMM: Double = 0,
        thicknessMM: Double = 0,
        projection: SlabProjection = .average
    ) {
        self.curve = curve
        self.intervalMM = max(intervalMM, 0.1)
        self.widthMM = max(widthMM, 1)
        self.heightMM = max(heightMM, 1)
        self.verticalCentreMM = verticalCentreMM
        self.thicknessMM = max(thicknessMM, 0)
        self.projection = projection
    }

    /// Genera tutte le sezioni lungo la curva.
    ///
    /// Ciascuna è una `MPRPlane` con l'asse orizzontale lungo la normale vestibolo-linguale e
    /// il verticale verso i piedi. La normale del piano risulta quindi la tangente alla curva,
    /// che è esattamente la definizione di sezione perpendicolare.
    public func sections() -> [CrossSection] {
        let samples = curve.resampled(spacingMM: intervalMM)
        let up = curve.upAxis

        return samples.enumerated().map { index, sample in
            // Si ricolloca il centro alla quota richiesta, conservando la posizione orizzontale
            // che viene dalla curva.
            let centre =
                sample.positionMM
                - up * sample.positionMM.dot(up)
                + up * verticalCentreMM

            let plane = MPRPlane(
                centerMM: centre,
                rightMM: sample.normal,
                downMM: up * -1.0,
                widthMM: widthMM,
                heightMM: heightMM,
                slabThicknessMM: thicknessMM,
                projection: projection)

            return CrossSection(
                index: index,
                arcLengthMM: sample.arcLengthMM,
                plane: plane,
                originMM: centre)
        }
    }

    /// Sezione più vicina a una data distanza d'arco.
    /// Serve a sincronizzare la griglia con un clic sul panorex.
    public func section(nearestToArcLength arcLength: Double, in sections: [CrossSection])
        -> CrossSection?
    {
        sections.min { a, b in
            abs(a.arcLengthMM - arcLength) < abs(b.arcLengthMM - arcLength)
        }
    }
}
