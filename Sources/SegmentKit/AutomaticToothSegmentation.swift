import DICOMCore
import Foundation

// Trovare i denti da soli, separarli e contarli: un comando, nessun marcatore da posare.
//
// # Perché serviva, visto che i pezzi c'erano già
//
// `CompetitiveGrowth` e `GraphCut` separano un dente dall'osso meglio di qualunque soglia, ma
// tutt'e due cominciano con la stessa domanda: **dov'è il dente?** Finché quella risposta la
// deve dare chi guarda, posando un marcatore per ogni radice, il programma non fa la
// segmentazione — la fa l'operatore, e il programma esegue. Su una dentatura intera sono
// trentadue marcatori da posare a mano, uno per uno, sulla fetta giusta.
//
// Qui la risposta la trova il programma, e la trova nel posto dove l'anatomia la scrive: lo
// **smalto**. È il tessuto più denso del corpo, sta molto sopra l'osso in densità, e soprattutto
// le corone di due denti vicini **non si toccano** — fra loro c'è il punto di contatto, che è
// una linea, non una superficie. Le componenti connesse dello smalto sono quindi i denti, uno
// per componente, contati senza che nessuno li indichi.
//
// Da lì in poi il lavoro è già scritto altrove: ogni corona diventa il marcatore del proprio
// dente, l'osso diventa il marcatore dello sfondo, e la crescita competitiva scende lungo le
// radici fermandosi sul legamento parodontale.
//
// # Le due soglie, e perché nessuna delle due è un numero scritto qui
//
// Servono due separazioni: aria e tessuti molli da una parte, osso e denti dall'altra; e poi
// osso da smalto. Sono due applicazioni di Otsu una dentro l'altra: la prima su tutto il volume,
// la seconda **solo sui voxel che la prima ha tenuto**.
//
// Una soglia scritta a mano qui sarebbe sbagliata su metà delle macchine. Su CBCT i valori
// grigi non sono unità Hounsfield — il documento di architettura lo dice, e per questo si
// chiamano GV — e due apparecchi diversi danno allo stesso smalto numeri che differiscono di
// mille. Otsu non sceglie un valore: sceglie il punto in cui le due popolazioni presenti in
// *questo* esame si separano meglio.
//
// # Che cosa questo non fa, e come lo dichiara
//
// **Non riconosce quale dente sia.** Ordinarli lungo l'arcata è geometria e riesce sempre;
// attribuire un numero FDI è un'altra cosa, perché richiede di sapere da che parte è la destra
// del paziente e quale delle due arcate si sta guardando. Su un esame a campo pieno si deducono;
// su un **sezionale** — un solo quadrante, senza linea mediana — non ci sono nel dato, e nessun
// calcolo li fa comparire. In quel caso i denti tornano ordinati e con `fdiNumber` a `nil`,
// perché un numero inventato su un modello dentale è peggio di nessun numero.
//
// E non recupera ciò che non c'è: una corona metallica non ha smalto sotto, ha un artefatto.
// Un dente ricostruito può non comparire fra le componenti, e allora va aggiunto a mano — con
// `GraphCut`, che per quello esiste.
public enum AutomaticToothSegmentation: Sendable {

    /// I pochi limiti che separano un dente da un frammento.
    public struct Settings: Hashable, Sendable {

        /// Il volume minimo di smalto perché una componente sia considerata un dente.
        ///
        /// Una corona di smalto sta fra i 100 e i 500 mm³ secondo il dente; un incisivo
        /// inferiore, il più piccolo, resta sopra i 60. Sotto i venti c'è solo rumore: schegge
        /// di corticale particolarmente densa, granuli di artefatto, cuspidi staccate dal
        /// partizionamento. La soglia è bassa apposta — perdere un dente è peggio che dover
        /// scartare una scheggia, perché la scheggia si vede e il dente mancante no.
        public var minimumCrownVolumeMM3: Double

        /// Il volume minimo perché un dente segmentato sia tenuto nel risultato.
        ///
        /// Vale sul dente intero — corona più radice — e **dopo** il taglio, che è il momento
        /// in cui si sa quanto quel dente misura davvero. Giudicare sul solo smalto non basta:
        /// una cuspide isolata da un solco profondo, o un'isola di corticale particolarmente
        /// densa, può avere lo smalto di un incisivo e non essere un dente.
        ///
        /// Centocinquanta millimetri cubi: un incisivo inferiore, il più piccolo dei
        /// trentadue, ne misura fra i quattrocento e i seicento; nemmeno mezzo incisivo scende
        /// sotto questa soglia. Il prezzo è che un dente tagliato dal campo fin quasi a
        /// sparire viene scartato — e va bene, perché di un frammento simile non ci si fa
        /// niente né per misurare né per stampare.
        public var minimumToothVolumeMM3: Double

        /// Sei vicini o ventisei nel separare le corone.
        ///
        /// Sei, e non è un dettaglio: con ventisei due corone che si sfiorano in un solo punto
        /// di contatto diventano una componente sola, e due denti vicini vengono contati come
        /// uno. È esattamente il caso che questa procedura deve evitare.
        public var connectivity: Connectivity

        /// Quanto si allarga attorno alla corona per cercarne la radice, in millimetri.
        ///
        /// Dodici: un incisivo ha radici da 13 mm e un canino arriva a 17, ma la scatola parte
        /// dal riquadro della corona, che già scende sotto il colletto. Allargare di più costa
        /// tempo e invita il taglio a trovare osso da prendere; allargare di meno taglia la
        /// radice di piatto a metà, e nella mesh si vede.
        public var searchMarginMM: Double

        public init(
            minimumCrownVolumeMM3: Double = 20,
            minimumToothVolumeMM3: Double = 150,
            connectivity: Connectivity = .faces,
            searchMarginMM: Double = 12
        ) {
            self.minimumCrownVolumeMM3 = minimumCrownVolumeMM3
            self.minimumToothVolumeMM3 = minimumToothVolumeMM3
            self.connectivity = connectivity
            self.searchMarginMM = searchMarginMM
        }
    }

    /// Un dente trovato, con quello che di lui si sa per certo.
    public struct DetectedTooth: Hashable, Sendable {
        /// L'etichetta con cui compare nella maschera.
        public let label: SegmentLabel
        /// La posizione lungo l'arcata, da un capo all'altro: 0 è un'estremità.
        ///
        /// È un ordine, non un nome. Dice quale dente viene prima di quale, il che basta per
        /// scorrerli, elencarli e disegnarli; non dice se il primo è un ottavo o un incisivo.
        public let positionAlongArch: Int
        /// Il numero FDI, quando il volume contiene abbastanza per stabilirlo.
        ///
        /// `nil` su un esame sezionale, dove lato e arcata non sono nel dato.
        public let fdiNumber: Int?
        /// Il baricentro del dente in coordinate Patient.
        public let centroidMM: Vec3
        /// Il volume del dente intero, corona più radice.
        public let volumeMM3: Double
        /// Il volume del solo smalto che lo ha fatto trovare.
        public let crownVolumeMM3: Double
        /// Vero se il dente tocca il bordo del campo, e quindi è tagliato dall'acquisizione.
        ///
        /// Non è un difetto della segmentazione: è un fatto dell'esame. Un dente che sporge dal
        /// campo ha un volume più piccolo del suo, e la sua superficie ha una faccia piatta che
        /// non esiste in bocca. Chi lo usa per misurare, o per stamparlo, deve saperlo — e non
        /// lo scoprirebbe guardando il modello, dove il taglio sembra anatomia.
        public let isTruncatedByFieldOfView: Bool
    }

    /// Quel che la procedura ha trovato, e su quali basi.
    public struct Result: Sendable {
        /// La maschera con un'etichetta per dente; lo sfondo è tutto il resto.
        public let mask: VolumeMask
        /// I denti, già ordinati lungo l'arcata.
        public let teeth: [DetectedTooth]
        /// La soglia che ha separato osso e denti dal resto, in GV.
        public let tissueThresholdGV: Double
        /// La soglia che ha separato lo smalto dall'osso, in GV.
        public let enamelThresholdGV: Double
        /// I punti dell'arcata su cui i denti sono stati ordinati, se è stata trovata.
        public let archPointsMM: [Vec3]
        /// Perché ciascuna corona candidata non è diventata un dente.
        public let discarded: [(crownVolumeMM3: Double, reason: String)]
        /// Quante isole di smalto erano candidate prima del taglio.
        ///
        /// Se supera il numero dei denti tornati, qualcuno è stato scartato: serve a
        /// accorgersene, perché un dente mancante dal risultato non si vede guardandolo.
        public let crownsConsidered: Int
    }

    /// Trova, separa e conta i denti presenti nel volume.
    ///
    /// - Returns: la maschera etichettata e l'elenco dei denti, ordinati lungo l'arcata.
    public static func segment(
        in volume: Volume,
        settings: Settings = Settings()
    ) throws -> Result {
        // 1. Le due soglie, ricavate dall'esame e non decise qui.
        let (tissue, enamel) = try thresholds(of: volume)

        // 2. Lo smalto, e le sue isole: una per corona.
        let maximum = volume.densityRange.upperBound
        let enamelMask = try ThresholdSegmentation.segment(
            volume, densityRange: enamel...Swift.max(maximum, enamel),
            label: 1, within: nil)
        let (crownMask, crowns, _) = try ConnectedComponents.label(
            enamelMask, connectivity: settings.connectivity)

        let candidates = crowns
            .filter { $0.volumeMM3 >= settings.minimumCrownVolumeMM3 }
            .sorted { $0.volumeMM3 > $1.volumeMM3 }
        guard !candidates.isEmpty else {
            throw SegmentKitError.noCrownsFound(enamelThresholdGV: enamel)
        }
        let selected = Array(candidates.prefix(Int(SegmentLabel.max) - 1))

        // 3. Un dente per volta, ciascuno chiuso nella propria scatola.
        //
        // Farli crescere tutti insieme su tutto il volume è l'errore che `GrowthRestriction`
        // documenta con i numeri: dove il fronte di un dente trova una via verso l'osso che
        // nessuno presidia, dilaga, e si porta via mezza mandibola. Su questo esame dava denti
        // da novemila millimetri cubi, cinque volte un molare.
        //
        // La scatola è l'unico dei rimedi che dia un **limite superiore**: fuori di lì non si
        // assegna niente qualunque cosa dica il dato. E costa poco, perché una scatola attorno
        // a un dente è un millesimo del volume.
        guard var mask = VolumeMask(geometry: volume.geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }
        let voxelVolume = volume.geometry.columnSpacingMM * volume.geometry.rowSpacingMM
            * volume.geometry.sliceSpacingMM
        var found: [(label: SegmentLabel, crown: ComponentSummary, volumeMM3: Double)] = []
        var discarded: [(crownVolumeMM3: Double, reason: String)] = []

        for (offset, crown) in selected.enumerated() {
            let label = SegmentLabel(offset + 1)
            let box = expanded(crown.boundsMM, byMM: settings.searchMarginMM)

            // I marcatori dell'oggetto sono presi **dentro** la corona, non dal suo baricentro:
            // il baricentro di un dente a cuspidi può cadere nel solco, cioè fuori dallo smalto,
            // e un marcatore fuori dalla fascia di densità è un errore, non un'approssimazione.
            let objectSeeds = sampleSeeds(
                fromLabel: crown.label, in: crownMask, limit: 24)
            guard !objectSeeds.isEmpty else {
                discarded.append((crown.volumeMM3, "nessun marcatore dentro la corona"))
                continue
            }

            // Lo sfondo: le altre corone che cadono nella scatola — sono i denti vicini, ed è
            // fra loro e questo che il taglio deve passare — più l'osso attorno.
            var backgroundSeeds: [Vec3] = []
            for other in selected where other.label != crown.label {
                if box.contains(other.centroidMM) {
                    backgroundSeeds.append(contentsOf:
                        sampleSeeds(fromLabel: other.label, in: crownMask, limit: 6))
                }
            }
            backgroundSeeds.append(contentsOf: boneSeeds(
                in: volume, within: box, tissueThresholdGV: tissue, enamelThresholdGV: enamel,
                awayFrom: crown.boundsMM))
            if backgroundSeeds.isEmpty {
                // Su un campo stretto la scatola sporge, e il guscio cade fuori dal volume dove
                // non c'è densità da campionare. Senza questo ripiego il dente viene saltato in
                // silenzio, che è il modo peggiore di sbagliare: un dente mancante non si vede.
                //
                // Si ripiega sui punti del guscio che stanno dentro il volume, qualunque sia la
                // loro densità. Come marcatori dello sfondo valgono comunque: sono il bordo
                // della scatola, e il dente sta al centro.
                backgroundSeeds = shellPoints(of: box, awayFrom: crown.boundsMM)
                    .filter { volume.densityValue(atPatient: $0) != nil }
            }
            // Rete di sicurezza sopra a tutte le sorgenti di marcatori: il taglio rifiuta
            // chi cade fuori dal riquadro, e ha ragione. Meglio scartarli qui, dove si sa
            // ancora perché, che perdere il dente intero per uno solo fuori posto.
            backgroundSeeds = backgroundSeeds.filter { box.contains($0) }
            guard !backgroundSeeds.isEmpty else {
                discarded.append((crown.volumeMM3, "nessun marcatore di sfondo dentro la scatola"))
                continue
            }

            let cut: VolumeMask
            do {
                cut = try GraphCut.segment(
                    in: volume,
                    objectSeedsMM: objectSeeds,
                    backgroundSeedsMM: backgroundSeeds,
                    densityRange: tissue...Swift.max(maximum, tissue),
                    within: box,
                    label: label)
            } catch {
                // Un dente che non si lascia tagliare non ferma gli altri trentuno: si salta e
                // se ne dice il motivo, invece di far fallire l'intera segmentazione.
                let detail = (error as? SegmentKitError)?.errorDescription ?? "\(error)"
                discarded.append((crown.volumeMM3, "taglio fallito: \(detail)"))
                continue
            }

            var voxels = 0
            for index in cut.labels.indices where cut.labels[index] == label {
                // Chi è già stato assegnato a un dente precedente non cambia padrone: le
                // scatole si sovrappongono, e senza questa regola due denti vicini si
                // contenderebbero lo stesso legamento a ogni giro.
                guard mask.labels[index] == VolumeMask.background else { continue }
                mask.setLabel(label, atIndex: index)
                voxels += 1
            }
            let grownVolume = Double(voxels) * voxelVolume
            guard grownVolume >= settings.minimumToothVolumeMM3 else {
                discarded.append(
                    (crown.volumeMM3, String(format: "solo %.0f mm³ dopo il taglio", grownVolume)))
                continue
            }
            found.append((label, crown, grownVolume))
        }

        guard !found.isEmpty else {
            throw SegmentKitError.noCrownsFound(enamelThresholdGV: enamel)
        }

        let occlusalMM = median(found.map(\.crown.centroidMM.z))
        let archPoints = ArchDetection.suggestArchPoints(
            in: volume, atVerticalMM: occlusalMM, thresholdGV: tissue) ?? []
        let ordered = orderAlongArch(found.map(\.crown.centroidMM), archPointsMM: archPoints)

        var detected: [DetectedTooth] = []
        detected.reserveCapacity(found.count)
        for (position, index) in ordered.enumerated() {
            let entry = found[index]
            detected.append(
                DetectedTooth(
                    label: entry.label,
                    positionAlongArch: position,
                    // Lato e arcata non si deducono da un volume qualunque: finché non c'è modo
                    // di stabilirli dal dato, il numero non si dà. Vedi la nota in testa.
                    fdiNumber: nil,
                    centroidMM: entry.crown.centroidMM,
                    volumeMM3: entry.volumeMM3,
                    crownVolumeMM3: entry.crown.volumeMM3,
                    isTruncatedByFieldOfView: touchesFieldEdge(
                        label: entry.label, in: mask)))
        }

        return Result(
            mask: mask, teeth: detected,
            tissueThresholdGV: tissue, enamelThresholdGV: enamel,
            archPointsMM: archPoints, discarded: discarded, crownsConsidered: selected.count)
    }

    // MARK: - Le soglie

    /// Le due soglie di Otsu, una dentro l'altra.
    private static func thresholds(of volume: Volume) throws -> (tissue: Double, enamel: Double) {
        // Un voxel ogni tanto basta: una soglia si decide sulla forma dell'istogramma, e quella
        // non cambia campionandone un centesimo. Su un volume da quattrocento milioni di voxel
        // guardarli tutti costerebbe più di tutta la segmentazione che segue.
        let stride = Swift.max(volume.samples.count / 2_000_000, 1)
        var densities: [Double] = []
        densities.reserveCapacity(volume.samples.count / stride + 1)
        for index in Swift.stride(from: 0, to: volume.samples.count, by: stride) {
            densities.append(volume.applyRescale(volume.samples[index]))
        }
        // La coda va tagliata prima di guardare l'istogramma, e non è un raffinamento: è la
        // differenza fra funzionare e non funzionare su un esame vero.
        //
        // Una CBCT con un'otturazione metallica contiene voxel saturi — sul CS 8200 arrivano a
        // 31.767 GV, cioè al tetto di `Int16` meno l'intercetta. Otsu cerca il punto che separa
        // meglio due popolazioni, e con una coda che arriva dieci volte oltre lo smalto quel
        // punto si sposta **sopra** lo smalto: la soglia esce a 6.000 GV invece che a 2.800, e
        // l'unica cosa che la supera è il metallo. Il risultato non è una segmentazione
        // imprecisa, è un dente solo grande cinquemila millimetri cubi.
        //
        // Si scarta il mezzo per cento più denso. Lo smalto sta ben dentro quel che resta —
        // occupa qualche punto percentuale del volume, non l'ultimo mezzo — mentre metallo e
        // artefatti stanno quasi tutti fuori.
        let sorted = densities.sorted()
        let ceilingIndex = Swift.min(Int(Double(sorted.count) * 0.995), sorted.count - 1)
        let ceiling = sorted[ceilingIndex]
        let clipped = densities.filter { $0 <= ceiling }
        guard clipped.count > 64, let tissue = ArchDetection.otsuThreshold(clipped) else {
            throw SegmentKitError.thresholdNotFound
        }
        let dense = clipped.filter { $0 >= tissue }
        guard dense.count > 16, let enamel = ArchDetection.otsuThreshold(dense) else {
            throw SegmentKitError.thresholdNotFound
        }
        return (tissue, enamel)
    }

    /// Punti dell'osso da usare come marcatori dello sfondo.
    ///
    /// Si prendono dai voxel che stanno fra le due soglie — osso sì, smalto no — sparsi per
    /// tutto il volume invece che raccolti in un punto. Marcare l'osso in più posti è quel che
    /// impedisce a un dente di dilagare: dove il fronte del dente trova una via verso l'osso,
    /// deve trovarci qualcuno che la presidia. `GrowthRestriction` racconta cosa succede quando
    /// nessuno la presidia, con i numeri.
    /// Il riquadro allargato di un margine uguale su ogni lato.
    ///
    /// Il margine deve bastare a contenere la radice, che è due volte la corona e va in una
    /// direzione che qui non si conosce: senza sapere quale delle due arcate si guarda, si
    /// allarga in tutti i versi e si lascia decidere al taglio.
    private static func expanded(_ box: BoxMM, byMM margin: Double) -> BoxMM {
        BoxMM(
            minMM: Vec3(box.minMM.x - margin, box.minMM.y - margin, box.minMM.z - margin),
            maxMM: Vec3(box.maxMM.x + margin, box.maxMM.y + margin, box.maxMM.z + margin))
    }

    /// Punti presi dentro una componente, sparsi invece che consecutivi.
    private static func sampleSeeds(
        fromLabel label: SegmentLabel, in mask: VolumeMask, limit: Int
    ) -> [Vec3] {
        let geometry = mask.geometry
        let columns = geometry.columnCount
        let plane = columns * geometry.rowCount
        var indices: [Int] = []
        for index in mask.labels.indices where mask.labels[index] == label {
            indices.append(index)
        }
        guard !indices.isEmpty else { return [] }
        let step = Swift.max(indices.count / Swift.max(limit, 1), 1)
        var points: [Vec3] = []
        for position in Swift.stride(from: 0, to: indices.count, by: step) {
            let index = indices[position]
            points.append(
                geometry.patientPoint(
                    i: index % columns, j: (index % plane) / columns, k: index / plane))
            if points.count >= limit { break }
        }
        return points
    }

    /// I punti sul guscio della scatola, esclusi quelli che cadono sulla corona.
    ///
    /// Solo il guscio, e non il volume pieno: il centro della scatola è il dente, e marcarci lo
    /// sfondo vorrebbe dire chiedere al taglio di buttare via ciò che deve tenere.
    private static func shellPoints(of box: BoxMM, awayFrom crown: BoxMM) -> [Vec3] {
        var points: [Vec3] = []
        let steps = 8
        // Il guscio sta appena **dentro** la scatola, non sul suo bordo esatto. Un marcatore
        // sul bordo cade nel voxel più vicino, che può stare un decimo di millimetro fuori: il
        // taglio lo rifiuta — a ragione, perché un marcatore fuori dal riquadro in cui deve
        // lavorare non è un marcatore — e il dente viene perso. Un venticinquesimo di rientro
        // sposta il problema senza spostare il confine.
        let inset = 0.04
        for kStep in 0...steps {
            for jStep in 0...steps {
                for iStep in 0...steps {
                    let onShell = kStep == 0 || kStep == steps || jStep == 0 || jStep == steps
                        || iStep == 0 || iStep == steps
                    guard onShell else { continue }
                    func position(_ step: Int) -> Double {
                        inset + (1 - 2 * inset) * Double(step) / Double(steps)
                    }
                    let point = Vec3(
                        box.minMM.x + (box.maxMM.x - box.minMM.x) * position(iStep),
                        box.minMM.y + (box.maxMM.y - box.minMM.y) * position(jStep),
                        box.minMM.z + (box.maxMM.z - box.minMM.z) * position(kStep))
                    guard !crown.contains(point) else { continue }
                    points.append(point)
                }
            }
        }
        return points
    }

    /// Punti d'osso sul guscio della scatola, lontani dalla corona da estrarre.
    private static func boneSeeds(
        in volume: Volume, within box: BoxMM, tissueThresholdGV: Double,
        enamelThresholdGV: Double, awayFrom crown: BoxMM
    ) -> [Vec3] {
        let middle = (tissueThresholdGV + enamelThresholdGV) / 2
        return shellPoints(of: box, awayFrom: crown).filter { point in
            guard let density = volume.densityValue(atPatient: point) else { return false }
            return density >= tissueThresholdGV && density <= middle
        }
    }

    /// Punti d'osso sparsi per tutto il volume.
    private static func boneSeeds(
        in volume: Volume, tissueThresholdGV: Double, enamelThresholdGV: Double
    ) -> [Vec3] {
        let geometry = volume.geometry
        let middle = (tissueThresholdGV + enamelThresholdGV) / 2
        var points: [Vec3] = []
        let steps = 6
        for kStep in 1..<steps {
            let k = geometry.sliceCount * kStep / steps
            for jStep in 1..<steps {
                let j = geometry.rowCount * jStep / steps
                for iStep in 1..<steps {
                    let i = geometry.columnCount * iStep / steps
                    guard let density = volume.densityValue(i: i, j: j, k: k) else { continue }
                    guard density >= tissueThresholdGV, density <= middle else { continue }
                    points.append(geometry.patientPoint(i: i, j: j, k: k))
                }
            }
        }
        return points
    }

    // MARK: - L'ordine lungo l'arcata

    /// Gli indici dei centroidi ordinati lungo la curva d'arcata.
    ///
    /// Ogni centroide si proietta sulla spezzata dei punti d'arcata e se ne prende l'ascissa
    /// curvilinea; l'ordine è quello. Senza arcata — un esame che non ne contiene una
    /// riconoscibile — si ripiega sull'ordine lungo l'asse maggiore della nuvola dei centroidi,
    /// che su un sezionale è la stessa cosa e su un campo pieno è meglio di niente.
    private static func orderAlongArch(_ centroids: [Vec3], archPointsMM: [Vec3]) -> [Int] {
        guard archPointsMM.count >= 2 else {
            return fallbackOrder(centroids)
        }
        var keys: [(index: Int, distance: Double)] = []
        for (index, centroid) in centroids.enumerated() {
            keys.append((index, arcLength(of: centroid, along: archPointsMM)))
        }
        return keys.sorted { $0.distance < $1.distance }.map(\.index)
    }

    /// L'ascissa curvilinea della proiezione del punto sulla spezzata.
    private static func arcLength(of point: Vec3, along polyline: [Vec3]) -> Double {
        var travelled = 0.0
        var best = Double.infinity
        var bestArc = 0.0
        for index in 0..<(polyline.count - 1) {
            let start = polyline[index]
            let end = polyline[index + 1]
            let segment = end - start
            let length = (segment.x * segment.x + segment.y * segment.y + segment.z * segment.z)
                .squareRoot()
            guard length > 1e-9 else { continue }
            let toPoint = point - start
            var t = (toPoint.x * segment.x + toPoint.y * segment.y + toPoint.z * segment.z)
                / (length * length)
            t = Swift.min(Swift.max(t, 0), 1)
            let projection = Vec3(
                start.x + segment.x * t, start.y + segment.y * t, start.z + segment.z * t)
            let offset = point - projection
            let distance =
                (offset.x * offset.x + offset.y * offset.y + offset.z * offset.z).squareRoot()
            if distance < best {
                best = distance
                bestArc = travelled + length * t
            }
            travelled += length
        }
        return bestArc
    }

    /// L'ordine lungo l'asse maggiore della nuvola, quando l'arcata non si trova.
    private static func fallbackOrder(_ centroids: [Vec3]) -> [Int] {
        guard centroids.count > 1 else { return Array(centroids.indices) }
        let spanX = (centroids.map(\.x).max() ?? 0) - (centroids.map(\.x).min() ?? 0)
        let spanY = (centroids.map(\.y).max() ?? 0) - (centroids.map(\.y).min() ?? 0)
        let alongX = spanX >= spanY
        return centroids.indices.sorted {
            alongX ? centroids[$0].x < centroids[$1].x : centroids[$0].y < centroids[$1].y
        }
    }

    /// Indica se la regione tocca una qualunque faccia del volume.
    ///
    /// Si guardano le sei facce e basta: un dente che arriva al bordo del campo ha per forza
    /// almeno un voxel su una di esse.
    private static func touchesFieldEdge(label: SegmentLabel, in mask: VolumeMask) -> Bool {
        let geometry = mask.geometry
        let lastI = geometry.columnCount - 1
        let lastJ = geometry.rowCount - 1
        let lastK = geometry.sliceCount - 1

        for k in [0, lastK] {
            for j in 0...lastJ {
                for i in 0...lastI where mask.label(i: i, j: j, k: k) == label { return true }
            }
        }
        for k in 0...lastK {
            for j in [0, lastJ] {
                for i in 0...lastI where mask.label(i: i, j: j, k: k) == label { return true }
            }
            for i in [0, lastI] {
                for j in 0...lastJ where mask.label(i: i, j: j, k: k) == label { return true }
            }
        }
        return false
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}
