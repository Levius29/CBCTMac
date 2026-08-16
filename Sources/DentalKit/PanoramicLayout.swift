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
        millimetresPerPixel: Double = 0.2
    ) {
        self.curve = curve
        self.heightMM = max(heightMM, 1)
        self.verticalCentreMM = verticalCentreMM
        self.slabThicknessMM = max(slabThicknessMM, 0)
        self.projection = projection
        self.millimetresPerPixel = max(millimetresPerPixel, 0.01)
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
        curve.resampled(count: max(pixelWidth, 2))
    }

    /// Passo verticale in millimetri per pixel, verso il basso dello schermo.
    ///
    /// Negativo lungo l'asse verticale del paziente perché sullo schermo il basso corrisponde
    /// ai piedi, come nelle viste coronale e sagittale.
    public func downStepMM() -> Vec3 {
        (curve.upAxis * -1.0) * millimetresPerPixel
    }

    /// Punto Patient del centro del pixel `(0, 0)` per una data colonna.
    public func topOfColumn(_ sample: ArchSample) -> Vec3 {
        // Il centro verticale dell'immagine sta a `verticalCentreMM`; il bordo alto sta mezza
        // altezza più su, e il primo campione mezzo pixel più in basso del bordo.
        let up = curve.upAxis
        let columnCentre =
            sample.positionMM
            - up * sample.positionMM.dot(up)
            + up * verticalCentreMM
        return columnCentre
            + up * (heightMM * 0.5)
            + downStepMM() * 0.5
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
