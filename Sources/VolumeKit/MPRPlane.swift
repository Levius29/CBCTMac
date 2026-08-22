import DICOMCore
import Foundation

// Descrizione di un piano di taglio, in millimetri Patient.
//
// Deliberatamente priva di dipendenze da Metal: questo file compila anche su Linux, quindi la
// matematica di proiezione — che è quella che traduce un clic del mouse in un punto anatomico,
// e quindi in una misura — si può testare senza Xcode e senza una GPU.
//
// È anche la struttura su cui poggeranno il panorex e le sezioni trasversali della Fase 2:
// cambiano solo l'origine e gli assi, ricavati dalla spline dell'arcata invece che dagli assi
// anatomici. Il resto della catena resta identico.

/// Come combinare i campioni lungo lo spessore dello slab.
public enum SlabProjection: String, CaseIterable, Hashable, Sendable, Codable {
    /// Media dei campioni: riduce il rumore, l'aspetto resta quello di una TC.
    case average
    /// Massima intensità. Su una CBCT esalta smalto e corticali, ed è la modalità che rende
    /// leggibile un panorex ricostruito.
    case maximum
    /// Minima intensità. Utile per vie aeree, seni e canali, dove interessa l'aria.
    case minimum

    /// Costante attesa dallo shader.
    public var shaderMode: Int32 {
        switch self {
        case .average: return 0
        case .maximum: return 1
        case .minimum: return 2
        }
    }

    public var localizedName: String {
        switch self {
        case .average: return "Media"
        case .maximum: return "MIP"
        case .minimum: return "MinIP"
        }
    }
}

/// Un piano di taglio con la sua finestra visibile.
public struct MPRPlane: Hashable, Sendable {

    /// Centro della finestra visibile, in mm Patient.
    public var centerMM: Vec3
    /// Versore dell'asse orizzontale dello schermo, verso destra.
    public var rightMM: Vec3
    /// Versore dell'asse verticale dello schermo, verso il basso.
    public var downMM: Vec3
    /// Larghezza della finestra visibile in mm. Determina lo zoom.
    public var widthMM: Double
    /// Altezza della finestra visibile in mm.
    public var heightMM: Double
    /// Spessore campionato attorno al piano. Zero o negativo significa slice singola.
    public var slabThicknessMM: Double
    public var projection: SlabProjection

    public init(
        centerMM: Vec3,
        rightMM: Vec3,
        downMM: Vec3,
        widthMM: Double,
        heightMM: Double,
        slabThicknessMM: Double = 0,
        projection: SlabProjection = .average
    ) {
        self.centerMM = centerMM
        self.rightMM = rightMM.normalized ?? Vec3(1, 0, 0)
        self.downMM = downMM.normalized ?? Vec3(0, 1, 0)
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.slabThicknessMM = slabThicknessMM
        self.projection = projection
    }

    /// Piano anatomico canonico passante per un punto.
    ///
    /// Gli assi vengono dalla tabella di convenzione radiologica in
    /// docs/architecture.md § Contratto 1: la destra del paziente compare a sinistra dello
    /// schermo. È l'unico posto in cui quella convenzione entra nel codice di rendering.
    public init(
        plane: AnatomicalPlane,
        through pointMM: Vec3,
        widthMM: Double,
        heightMM: Double,
        slabThicknessMM: Double = 0,
        projection: SlabProjection = .average
    ) {
        self.init(
            centerMM: pointMM,
            rightMM: plane.screenRightMM,
            downMM: plane.screenDownMM,
            widthMM: widthMM,
            heightMM: heightMM,
            slabThicknessMM: slabThicknessMM,
            projection: projection)
    }

    // MARK: Geometria

    /// Normale al piano, orientata secondo `rightMM × downMM`.
    public var normalMM: Vec3 {
        rightMM.cross(downMM).normalized ?? Vec3(0, 0, 1)
    }

    /// Angolo alto-sinistro della finestra visibile.
    public var topLeftMM: Vec3 {
        centerMM - rightMM * (widthMM * 0.5) - downMM * (heightMM * 0.5)
    }

    /// Sposta il piano lungo la propria normale, in millimetri.
    /// È lo scorrimento delle slice con la rotella.
    public func advanced(byMM distance: Double) -> MPRPlane {
        var copy = self
        copy.centerMM = centerMM + normalMM * distance
        return copy
    }

    /// Zoom attorno al centro. Fattori maggiori di 1 ingrandiscono.
    public func zoomed(by factor: Double) -> MPRPlane {
        guard factor > 0 else { return self }
        var copy = self
        copy.widthMM = widthMM / factor
        copy.heightMM = heightMM / factor
        return copy
    }

    /// Zoom **ancorato a un pixel**: il punto anatomico sotto quel pixel non si muove.
    ///
    /// È la differenza fra un visore usabile e uno da rincorrere. Con lo zoom centrato sul
    /// riquadro, ingrandire allontana dal cursore ciò che si stava guardando, e ogni ingrandimento
    /// va corretto a mano con una panoramica; ancorandolo al puntatore il dente sotto il cursore
    /// resta dov'è e lo zoom diventa un gesto solo.
    ///
    /// La correzione è esatta e si ricava in due righe. Con `u` e `v` le coordinate del pixel
    /// riportate in frazione di finestra e centrate — `u = (x + ½)/larghezza − ½`, e così `v` —
    /// il punto inquadrato vale `centro + destra·L·u + giù·A·v`. Imporre che resti fermo dopo aver
    /// scalato `L` e `A` dà direttamente lo spostamento del centro.
    public func zoomed(
        by factor: Double,
        aboutPixelX x: Double,
        y: Double,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> MPRPlane {
        guard factor > 0, pixelWidth > 0, pixelHeight > 0 else { return self }

        let u = (x + 0.5) / Double(pixelWidth) - 0.5
        let v = (y + 0.5) / Double(pixelHeight) - 0.5

        var copy = self
        copy.widthMM = widthMM / factor
        copy.heightMM = heightMM / factor
        copy.centerMM = centerMM
            + rightMM * (u * (widthMM - copy.widthMM))
            + downMM * (v * (heightMM - copy.heightMM))
        return copy
    }

    /// Ruota l'inquadratura nel proprio piano, attorno a un punto anatomico.
    ///
    /// Serve a raddrizzare: una CBCT arriva quasi sempre con la testa inclinata, e allineare il
    /// piano occlusale all'orizzontale rende leggibili misure che altrimenti vanno lette di
    /// traverso. La rotazione è **nel piano**, cioè attorno alla normale: non cambia quale fetta
    /// si sta guardando, solo il suo orientamento a schermo. Per inclinare il piano fuori dal
    /// proprio asse — la ricostruzione obliqua vera — servirebbe ruotare anche la normale.
    ///
    /// Il perno è un punto Patient qualunque: passando il mirino, l'immagine gira attorno al punto
    /// che interessa invece che attorno al centro del riquadro, che di solito non è dove si guarda.
    public func rotatedInPlane(byRadians angle: Double, aboutMM pivot: Vec3) -> MPRPlane {
        guard angle.isFinite, pivot.isFinite,
              let rotation = Transform3D.rotation(axis: normalMM, angle: angle)
        else { return self }

        var copy = self
        copy.rightMM = rotation.apply(toVector: rightMM).normalized ?? rightMM
        copy.downMM = rotation.apply(toVector: downMM).normalized ?? downMM
        // Il centro ruota attorno al perno con la stessa rotazione, altrimenti l'immagine
        // girerebbe restando inquadrata sul vecchio centro e il perno scorrerebbe via.
        copy.centerMM = pivot + rotation.apply(toVector: centerMM - pivot)
        return copy
    }

    /// Ruota il piano **attorno a un asse qualunque**, cambiandone la normale.
    ///
    /// È la ricostruzione obliqua: `rotatedInPlane` gira l'immagine lasciando invariata la fetta
    /// che si guarda, questa cambia proprio *come il piano taglia il volume*. Serve perché
    /// l'anatomia non è allineata agli assi della macchina — un ramo mandibolare, l'asse di un
    /// dente incluso, un condilo si guardano bene solo di sbieco.
    ///
    /// L'uso tipico è il trascinamento di una linea del mirino: ruotando la linea coronale sulla
    /// vista assiale, l'asse di rotazione è la **normale dell'assiale** e il piano che si inclina è
    /// il coronale. Il perno è il mirino, così il punto che si sta guardando resta inquadrato.
    ///
    /// - Note: il piano resta ortonormale per costruzione, perché una rotazione conserva angoli e
    ///   lunghezze. Rinormalizzare comunque i due assi difende dall'accumulo di errore su decine di
    ///   rotazioni consecutive, che è esattamente ciò che produce un trascinamento continuo.
    public func rotated(aboutAxis axis: Vec3, byRadians angle: Double, aboutMM pivot: Vec3)
        -> MPRPlane
    {
        guard angle.isFinite, pivot.isFinite,
              let rotation = Transform3D.rotation(axis: axis, angle: angle)
        else { return self }

        var copy = self
        copy.rightMM = rotation.apply(toVector: rightMM).normalized ?? rightMM
        copy.downMM = rotation.apply(toVector: downMM).normalized ?? downMM
        copy.centerMM = pivot + rotation.apply(toVector: centerMM - pivot)
        return copy
    }

    /// Riporta l'inquadratura a contenere l'intero volume, mantenendo orientamento e centro fetta.
    ///
    /// È la via di ritorno dopo essersi persi ingrandendo, e va sempre offerta: senza, l'unico
    /// modo di ritrovare l'anatomia è riaprire lo studio.
    /// Lo stesso piano, centrato **sul volume dentro il piano**, con la fetta dov'era.
    ///
    /// # Perché serve, e perché non basta `fitted`
    ///
    /// `fitted` misura le distanze degli spigoli **dal centro del piano**, e tiene la maggiore.
    /// Con il centro sul mirino, e il mirino di lato, la maggiore è la distanza dal bordo
    /// lontano: il campo diventa il doppio di quel che serve e l'anatomia ci sta dentro
    /// spostata da una parte. Su un volume largo cento millimetri, col mirino a quaranta dal
    /// centro, il campo esce quasi centottanta — l'anatomia occupa poco più di metà larghezza e
    /// non è al centro. È il «rimpicciolisce e decentra» di «rimetti a posto le viste».
    ///
    /// Centrare prima toglie il problema alla radice: da un centro simmetrico le due distanze
    /// sono uguali, e `fitted` dà esattamente l'ingombro del volume.
    ///
    /// **Fuori dal piano non si muove niente.** La componente lungo la normale resta quella di
    /// prima, cioè la fetta che si sta guardando: rimettere a posto l'inquadratura non deve
    /// cambiare *che cosa* si sta guardando.
    public func centred(onVolume geometry: VolumeGeometry) -> MPRPlane {
        let normal = normalMM
        let centre = geometry.centerMM
        let depth = (centerMM - centre).dot(normal)
        var copy = self
        copy.centerMM = centre + normal * depth
        return copy
    }

    public func fitted(to geometry: VolumeGeometry, marginFraction: Double = 0.04) -> MPRPlane {
        let corners = geometry.boundingBoxCornersMM
        guard !corners.isEmpty else { return self }

        var halfWidth = 0.0
        var halfHeight = 0.0
        for corner in corners {
            let relative = corner - centerMM
            halfWidth = max(halfWidth, abs(relative.dot(rightMM)))
            halfHeight = max(halfHeight, abs(relative.dot(downMM)))
        }

        let margin = 1 + max(0, marginFraction)
        var copy = self
        copy.widthMM = max(1, halfWidth * 2 * margin)
        copy.heightMM = max(1, halfHeight * 2 * margin)
        return copy
    }

    // MARK: Proiezione pixel ↔ millimetri

    /// Spostamento in mm corrispondente a un pixel verso destra.
    public func rightStepMM(pixelWidth: Int) -> Vec3 {
        guard pixelWidth > 0 else { return .zero }
        return rightMM * (widthMM / Double(pixelWidth))
    }

    /// Spostamento in mm corrispondente a un pixel verso il basso.
    public func downStepMM(pixelHeight: Int) -> Vec3 {
        guard pixelHeight > 0 else { return .zero }
        return downMM * (heightMM / Double(pixelHeight))
    }

    /// Punto Patient del **centro** del pixel `(0,0)`.
    ///
    /// Il mezzo pixel di scarto non è pedanteria: senza di esso l'immagine risulta traslata di
    /// mezzo pixel rispetto alle annotazioni disegnate sopra, e su misure ravvicinate lo
    /// scarto si vede.
    public func originMM(pixelWidth: Int, pixelHeight: Int) -> Vec3 {
        topLeftMM
            + rightStepMM(pixelWidth: pixelWidth) * 0.5
            + downStepMM(pixelHeight: pixelHeight) * 0.5
    }

    /// Pixel → punto Patient in mm.
    ///
    /// È la funzione che trasforma un clic in una misura. Le coordinate possono essere
    /// frazionarie: il puntatore non si allinea ai pixel e non c'è ragione di arrotondarlo.
    public func patientPoint(atPixelX x: Double, y: Double, pixelWidth: Int, pixelHeight: Int)
        -> Vec3
    {
        originMM(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
            + rightStepMM(pixelWidth: pixelWidth) * x
            + downStepMM(pixelHeight: pixelHeight) * y
    }

    /// Punto Patient → pixel, più la distanza con segno dal piano.
    ///
    /// La distanza serve a decidere se e quanto disegnare un'annotazione: una misura tracciata
    /// su un'altra slice non va nascosta di colpo né mostrata a piena opacità, va sfumata.
    public func pixelPosition(ofPatient p: Vec3, pixelWidth: Int, pixelHeight: Int)
        -> (x: Double, y: Double, distanceMM: Double)
    {
        let origin = originMM(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        let d = p - origin

        let horizontalStep = widthMM / Double(max(pixelWidth, 1))
        let verticalStep = heightMM / Double(max(pixelHeight, 1))

        let x = horizontalStep > 0 ? d.dot(rightMM) / horizontalStep : 0
        let y = verticalStep > 0 ? d.dot(downMM) / verticalStep : 0
        let distance = (p - centerMM).dot(normalMM)

        return (x, y, distance)
    }

    // MARK: Slab

    /// Numero di campioni da prendere lungo la normale.
    ///
    /// Si campiona a passo pari alla spaziatura minima dei voxel: più fitto sarebbe spreco,
    /// perché non c'è informazione fra due voxel adiacenti; più rado perderebbe strutture
    /// sottili, e su una corticale di 0,5 mm significa non vederla.
    public func slabSampleCount(geometry: VolumeGeometry) -> Int {
        guard slabThicknessMM > 0 else { return 1 }
        let spacing = geometry.spacingMM
        let step = min(spacing.x, min(spacing.y, spacing.z))
        guard step > 0 else { return 1 }
        return max(1, Int((slabThicknessMM / step).rounded()) + 1)
    }

    /// Passo fra due campioni consecutivi dello slab, in mm lungo la normale.
    public func slabStepMM(geometry: VolumeGeometry) -> Vec3 {
        let count = slabSampleCount(geometry: geometry)
        guard count > 1, slabThicknessMM > 0 else { return .zero }
        return normalMM * (slabThicknessMM / Double(count - 1))
    }

    // MARK: Inquadratura

    /// Piano centrato sul volume, con la finestra dimensionata per contenerlo tutto.
    /// È l'inquadratura all'apertura di uno studio.
    public static func fitted(
        plane: AnatomicalPlane,
        geometry: VolumeGeometry,
        marginFraction: Double = 0.05
    ) -> MPRPlane {
        let corners = geometry.boundingBoxCornersMM
        let center = geometry.centerMM
        let right = plane.screenRightMM
        let down = plane.screenDownMM

        var halfWidth = 0.0
        var halfHeight = 0.0
        for corner in corners {
            let d = corner - center
            halfWidth = max(halfWidth, abs(d.dot(right)))
            halfHeight = max(halfHeight, abs(d.dot(down)))
        }

        let scale = 2.0 * (1.0 + marginFraction)
        return MPRPlane(
            plane: plane,
            through: center,
            widthMM: max(halfWidth * scale, 1.0),
            heightMM: max(halfHeight * scale, 1.0))
    }

    /// Adegua le proporzioni della finestra a quelle del riquadro sullo schermo, allargando il
    /// lato che serve. Si allarga e non si stringe, così l'anatomia inquadrata non sparisce
    /// quando l'utente ridimensiona la finestra.
    public func matchingAspect(pixelWidth: Int, pixelHeight: Int) -> MPRPlane {
        guard pixelWidth > 0, pixelHeight > 0, widthMM > 0, heightMM > 0 else { return self }
        let target = Double(pixelWidth) / Double(pixelHeight)
        let current = widthMM / heightMM
        var copy = self
        if current < target {
            copy.widthMM = heightMM * target
        } else if current > target {
            copy.heightMM = widthMM / target
        }
        return copy
    }
}

// MARK: - Finestra e livello

/// Finestra e livello, in unità di densità.
///
/// I valori si esprimono in densità e non in valori grezzi perché è così che li ragiona chi
/// legge le immagini; la conversione a grezzo avviene una volta sola, entrando nello shader.
///
/// - Important: il nome **non** è `WindowLevel`, che sarebbe quello ovvio. SwiftUI dichiara un
///   proprio tipo `WindowLevel` (il livello di sovrapposizione di una finestra sullo schermo,
///   cosa del tutto diversa), e in ogni file che importa sia SwiftUI sia VolumeKit il nome
///   diventerebbe ambiguo. Il guasto non si ferma lì: `AppModel` tiene una proprietà di questo
///   tipo, quindi l'ambiguità impedisce l'espansione della macro `@Observable`, `AppModel`
///   perde la conformità a `Observable`, e ogni `@Bindable var model` dell'applicazione
///   diventa illegale. Novantuno errori di compilazione da un nome. Non rinominarlo indietro.
public struct DensityWindow: Hashable, Sendable, Codable {
    public var width: Double
    public var level: Double

    public init(width: Double, level: Double) {
        self.width = max(width, 1)
        self.level = level
    }

    public var lowerBound: Double { level - width * 0.5 }
    public var upperBound: Double { level + width * 0.5 }

    /// Preset ampi per l'osso: è il punto di partenza abituale su una CBCT dentale.
    public static let bone = DensityWindow(width: 2400, level: 600)
    /// Denti e smalto, dove servono i valori più alti della scala.
    public static let teeth = DensityWindow(width: 3200, level: 1400)
    public static let softTissue = DensityWindow(width: 500, level: 60)
    /// Articolazione temporo-mandibolare: contrasto stretto sulla corticale del condilo.
    public static let tmj = DensityWindow(width: 3000, level: 900)
    /// Vie aeree: si guarda l'aria, quindi livelli molto bassi.
    public static let airway = DensityWindow(width: 1200, level: -400)

    public static let presets: [(name: String, value: DensityWindow)] = [
        ("Osso", .bone),
        ("Denti", .teeth),
        ("Tessuti molli", .softTissue),
        ("ATM", .tmj),
        ("Vie aeree", .airway),
    ]

    /// Finestra ricavata dall'intervallo effettivo dei dati.
    ///
    /// Si scartano le code perché su CBCT gli estremi sono quasi sempre artefatti — metallo da
    /// un lato, aria e rumore dall'altro — e lasciarli dentro comprime tutto il tessuto utile
    /// in una manciata di livelli di grigio, rendendo l'immagine piatta.
    public static func automatic(from volume: Volume, tailFraction: Double = 0.005) -> DensityWindow
    {
        let histogram = volume.rawHistogram(binCount: 512)
        let total = histogram.reduce(0, +)
        guard total > 0 else { return .bone }

        let cutoff = Int(Double(total) * tailFraction)
        let lowRaw = Double(volume.rawValueRange.lowerBound)
        let highRaw = Double(volume.rawValueRange.upperBound)
        let binWidth = (highRaw - lowRaw) / Double(histogram.count)

        var accumulated = 0
        var lowBin = 0
        for (index, count) in histogram.enumerated() {
            accumulated += count
            if accumulated >= cutoff {
                lowBin = index
                break
            }
        }

        accumulated = 0
        var highBin = histogram.count - 1
        for index in stride(from: histogram.count - 1, through: 0, by: -1) {
            accumulated += histogram[index]
            if accumulated >= cutoff {
                highBin = index
                break
            }
        }

        guard highBin > lowBin else { return .bone }

        let lowDensity = volume.applyRescale(
            Int16(clamping: Int(lowRaw + Double(lowBin) * binWidth)))
        let highDensity = volume.applyRescale(
            Int16(clamping: Int(lowRaw + Double(highBin) * binWidth)))

        return DensityWindow(
            width: abs(highDensity - lowDensity),
            level: (highDensity + lowDensity) * 0.5)
    }
}
