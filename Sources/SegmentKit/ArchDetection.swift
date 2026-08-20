import DICOMCore
import Foundation

// Proposta automatica della curva d'arcata.
//
// # Il metodo, dichiarato perché è euristico
//
// Alla quota indicata si prende la fetta assiale, si sogliano i voxel ossei, si tiene la
// componente connessa maggiore e si campiona il suo contorno in coordinate polari attorno al
// baricentro: per ogni settore angolare si prende il raggio mediano dei voxel di quel settore, e
// i punti così ottenuti diventano i punti di controllo.
//
// È un'euristica, non una segmentazione anatomica. Funziona perché un'arcata dentale vista da
// sopra è una figura quasi convessa attorno al proprio baricentro, e smette di funzionare quando
// non lo è — su un'arcata gravemente asimmetrica, su una CBCT parziale, su un edentulo.
//
// # Deve poter dire di no, ed è la parte che conta
//
// Questo progetto ha già attraversato una volta la situazione che si crea quando un automatismo
// propone con sicurezza una curva che non somiglia all'anatomia: c'era una curva blu preimpostata
// e non modificabile, e il panorex «andava per cavoli suoi». Una proposta sbagliata è peggio di
// nessuna proposta, perché chi la riceve la corregge invece di rifarla, e finisce con una curva
// né sua né buona.
//
// Da qui tre criteri di rifiuto espliciti, ognuno dei quali restituisce `nil`:
//
// - **pochi voxel oltre soglia**: la fetta non contiene osso sufficiente;
// - **componente troppo piccola** rispetto alla fetta: c'è osso ma sparso, non un'arcata;
// - **troppi settori vuoti**: la figura non circonda il proprio baricentro, quindi non è un arco.

public enum ArchDetection: Sendable {

    /// Frazione minima di settori angolari che devono contenere osso.
    ///
    /// Un'arcata copre circa metà del giro attorno al proprio baricentro — è una U, non un
    /// anello. Sotto il 35% dei settori si sta guardando altro: qualche isola di corticale, o una
    /// CBCT parziale di cui questa euristica non sa fare nulla di buono.
    public static let minimumFilledSectorFraction = 0.35

    /// Frazione minima della fetta che deve essere osso perché ci sia un'arcata da cercare.
    ///
    /// Relativa e non assoluta, e l'ho corretta dopo averla sbagliata: un minimo fisso di
    /// quattrocento punti dipende dal passo di campionamento, che qui segue la spaziatura del
    /// volume. Lo stesso arco, campionato a 0,3 mm o a 1 mm, dà un conteggio dieci volte diverso;
    /// il primo passava e il secondo veniva rifiutato, pur essendo la stessa anatomia.
    ///
    /// Tre per mille è basso di proposito. Un'arcata intera su un FOV pieno sta attorno al due
    /// per cento, ma una CBCT parziale di mezza emiarcata — il caso da cui è nato metà di questo
    /// lavoro — scende molto sotto, e rifiutarla sarebbe rifiutare proprio il caso difficile.
    public static let minimumBoneFraction = 0.003

    /// Sotto questo numero di punti la statistica per settore non regge, comunque vada la
    /// frazione: con centoventi punti su settantadue settori c'è meno di un punto per settore.
    public static let minimumBonePoints = 120

    /// Punti campionati minimi perché la fetta sia dentro il volume.
    public static let minimumSampledPoints = 400

    /// Quanti settori vuoti di fila servono perché l'apertura della U sia un'apertura.
    ///
    /// # Il difetto che questo numero toglie di mezzo
    ///
    /// Bastava **un** settore vuoto. Su una fetta vera i settori sono quasi tutti pieni — c'è
    /// osso tutto intorno al baricentro — e un buco accidentale di cinque gradi veniva preso per
    /// l'apertura dell'arcata: la curva partiva da un lato del buco e girava per trecentocinquanta
    /// gradi attorno al baricentro, cioè faceva un anello attorno alla testa. È la «curva senza
    /// logica» che si vedeva premendo «proponi».
    ///
    /// # Perché otto e non dieci
    ///
    /// Otto settori su settantadue sono quaranta gradi. Dieci sembravano più prudenti e non lo
    /// erano: i settori si contano **dal baricentro dell'osso**, non dal centro dell'arcata, e il
    /// baricentro sta dalla parte opposta all'apertura. Da lì l'apertura si vede più stretta di
    /// quel che è — un'apertura di cinquantasette gradi ne sottende quarantanove — e dieci
    /// settori rifiutavano archi perfettamente buoni.
    ///
    /// Quaranta gradi restano larghissimi rispetto a quel che c'era prima, cioè **un** settore:
    /// bastavano cinque gradi di buco casuale nel rumore perché la figura passasse per un'arcata,
    /// e la curva partiva da un lato del buco girando per trecentocinquanta gradi attorno al
    /// baricentro — un anello attorno alla testa, che è la «curva senza logica» che si vedeva.
    public static let minimumOpeningSectors = 8

    /// Soglia di Otsu: il valore che massimizza la varianza fra le due classi.
    ///
    /// Un percentile fisso sarebbe più corto da scrivere ed è quello che avevo scritto per primo:
    /// sbagliava. Su una fetta in cui l'osso è meno del venti per cento — cioè su qualunque fetta
    /// vera, dove l'arcata è un anello sottile in un riquadro grande — l'ottantesimo percentile
    /// cade nel fondo, la soglia non separa niente e «osso» diventa tutta l'immagine. Otsu invece
    /// cerca il taglio, e su una distribuzione bimodale come questa lo trova dove serve.
    ///
    /// - Returns: `nil` quando i valori sono tutti uguali, cioè non c'è niente da separare.
    public static func otsuThreshold(_ values: [Double], binCount: Int = 256) -> Double? {
        guard let minimum = values.min(), let maximum = values.max(), maximum > minimum else {
            return nil
        }
        let span = maximum - minimum
        var histogram = [Int](repeating: 0, count: binCount)
        for value in values {
            let bin = min(Int((value - minimum) / span * Double(binCount)), binCount - 1)
            histogram[bin] += 1
        }

        let total = Double(values.count)
        var sumAll = 0.0
        for bin in 0..<binCount { sumAll += Double(bin) * Double(histogram[bin]) }

        var weightBelow = 0.0
        var sumBelow = 0.0
        var bestVariance = -1.0
        var bestBin = 0
        for bin in 0..<binCount {
            weightBelow += Double(histogram[bin])
            guard weightBelow > 0 else { continue }
            let weightAbove = total - weightBelow
            guard weightAbove > 0 else { break }

            sumBelow += Double(bin) * Double(histogram[bin])
            let meanBelow = sumBelow / weightBelow
            let meanAbove = (sumAll - sumBelow) / weightAbove
            let difference = meanBelow - meanAbove
            let variance = weightBelow * weightAbove * difference * difference
            if variance > bestVariance {
                bestVariance = variance
                bestBin = bin
            }
        }
        guard bestVariance > 0 else { return nil }
        return minimum + (Double(bestBin) + 1) / Double(binCount) * span
    }

    /// Punti di controllo proposti per la curva d'arcata, ricavati dall'anatomia.
    ///
    /// - Parameters:
    ///   - volume: il volume su cui cercare.
    ///   - verticalMM: quota Patient della fetta assiale su cui lavorare. Si sceglie a metà fra
    ///     cresta e apici; più in alto si prende il palato, più in basso il bordo mandibolare.
    ///   - thresholdGV: soglia dell'osso. `nil` la ricava dall'istogramma della fetta.
    ///   - pointCount: quanti punti di controllo produrre.
    /// - Returns: `nil` quando l'immagine non contiene un'arcata riconoscibile.
    public static func suggestArchPoints(
        in volume: Volume,
        atVerticalMM verticalMM: Double,
        thresholdGV: Double? = nil,
        pointCount: Int = 7
    ) -> [Vec3]? {
        let geometry = volume.geometry
        guard geometry.voxelCount > 0, pointCount >= 3 else { return nil }

        // Campionamento su una griglia regolare nel piano assiale, non sui voxel: il volume può
        // essere orientato comunque, e attraversare gli indici darebbe una fetta obliqua.
        let corners = geometry.boundingBoxCornersMM
        var lower = Vec3(.infinity, .infinity, 0)
        var upper = Vec3(-.infinity, -.infinity, 0)
        for corner in corners {
            lower = Vec3(min(lower.x, corner.x), min(lower.y, corner.y), 0)
            upper = Vec3(max(upper.x, corner.x), max(upper.y, corner.y), 0)
        }
        guard lower.x.isFinite, upper.x > lower.x, upper.y > lower.y else { return nil }

        let spacing = geometry.spacingMM
        let step = max(min(spacing.x, spacing.y), 0.1)
        let columns = Int((upper.x - lower.x) / step) + 1
        let rows = Int((upper.y - lower.y) / step) + 1
        guard columns > 1, rows > 1, columns * rows < 40_000_000 else { return nil }

        // Soglia: quella indicata, oppure quella di Otsu sulla fetta. Non una costante in unità
        // assolute — su CBCT i valori grigi non sono unità Hounsfield, e una soglia fissa
        // funzionerebbe su una macchina e non sull'altra.
        var densities: [Double] = []
        densities.reserveCapacity(columns * rows)
        for j in 0..<rows {
            for i in 0..<columns {
                let point = Vec3(
                    lower.x + Double(i) * step, lower.y + Double(j) * step, verticalMM)
                densities.append(volume.densityValue(atPatient: point) ?? -.infinity)
            }
        }
        let finite = densities.filter { $0.isFinite }
        guard finite.count > minimumSampledPoints else { return nil }

        let threshold: Double
        if let thresholdGV {
            threshold = thresholdGV
        } else if let otsu = otsuThreshold(finite) {
            threshold = otsu
        } else {
            return nil
        }

        // Solo la **componente connessa più grande**, e qui sta la correzione che conta.
        //
        // Su una fetta assiale vera l'osso oltre soglia non è soltanto l'arcata: c'è la colonna
        // cervicale dietro, spesso i rami o i processi stiloidei, a volte lo ioide. Tutto questo
        // entrava nel conto, e due cose andavano storte insieme. Il baricentro veniva tirato
        // all'indietro, verso la colonna, quindi i raggi non partivano più dall'interno della U;
        // e i settori risultavano pieni tutto intorno, quindi l'apertura dell'arcata spariva.
        // Il risultato era una curva che girava attorno alla testa invece di seguire l'arcata.
        //
        // La mandibola, o il mascellare, sono la macchia più grande della fetta e non toccano né
        // la colonna né i rami: tenere la sola componente maggiore le isola senza dover sapere
        // che cosa siano.
        let bone = largestComponent(
            densities: densities, columns: columns, rows: rows, threshold: threshold)
        var boneX: [Double] = []
        var boneY: [Double] = []
        boneX.reserveCapacity(bone.count)
        boneY.reserveCapacity(bone.count)
        for index in bone {
            boneX.append(lower.x + Double(index % columns) * step)
            boneY.append(lower.y + Double(index / columns) * step)
        }
        let required = max(minimumBonePoints, Int(Double(columns * rows) * minimumBoneFraction))
        guard boneX.count >= required else { return nil }

        let centreX = boneX.reduce(0, +) / Double(boneX.count)
        let centreY = boneY.reduce(0, +) / Double(boneY.count)

        // Settori angolari: per ciascuno il raggio **mediano** dei suoi voxel, non il massimo.
        // Il massimo insegue il voxel più esterno, che su una CBCT è spesso rumore o una vertebra
        // entrata nell'inquadratura, e basta uno di quelli per deformare la curva.
        let sectorCount = 72
        var radii = [[Double]](repeating: [], count: sectorCount)
        for index in boneX.indices {
            let dx = boneX[index] - centreX
            let dy = boneY[index] - centreY
            let radius = (dx * dx + dy * dy).squareRoot()
            guard radius > 1e-6 else { continue }
            var angle = Foundation.atan2(dy, dx)
            if angle < 0 { angle += 2 * .pi }
            let sector = min(Int(angle / (2 * .pi) * Double(sectorCount)), sectorCount - 1)
            radii[sector].append(radius)
        }

        let filled = radii.filter { !$0.isEmpty }.count
        guard Double(filled) / Double(sectorCount) >= minimumFilledSectorFraction else {
            return nil
        }

        // Il settore vuoto più lungo è l'apertura della U: la curva parte da un capo
        // dell'apertura e finisce all'altro, invece di chiudersi in un anello.
        var bestGapStart = 0
        var bestGapLength = 0
        var currentStart = 0
        var currentLength = 0
        for offset in 0..<(sectorCount * 2) {
            let sector = offset % sectorCount
            if radii[sector].isEmpty {
                if currentLength == 0 { currentStart = sector }
                currentLength += 1
                if currentLength > bestGapLength {
                    bestGapLength = currentLength
                    bestGapStart = currentStart
                }
            } else {
                currentLength = 0
            }
        }

        // Senza apertura la figura circonda il baricentro: è un anello, non un'arcata. Capita su
        // una fetta presa all'altezza dei condili, dove il cranio si chiude tutto intorno.
        //
        // «Senza» vuol dire meno di cinquanta gradi, non zero: vedi `minimumOpeningSectors`.
        guard bestGapLength >= minimumOpeningSectors else { return nil }

        let firstSector = (bestGapStart + bestGapLength) % sectorCount
        let span = sectorCount - bestGapLength
        guard span >= 3 else { return nil }

        // Raggio mediano per settore, poi lisciato sui vicini: un settore con pochi punti dà un
        // raggio ballerino, e una curva a zigzag si corregge peggio di una curva liscia
        // leggermente fuori posto.
        let medians: [Double?] = radii.map { values in
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        func smoothedRadius(at sector: Int) -> Double? {
            let neighbours = [-1, 0, 1].compactMap { offset -> Double? in
                medians[((sector + offset) % sectorCount + sectorCount) % sectorCount]
            }
            guard !neighbours.isEmpty else { return nil }
            let sorted = neighbours.sorted()
            return sorted[sorted.count / 2]
        }

        var points: [Vec3] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            let position = Double(index) / Double(pointCount - 1) * Double(span - 1)
            let sector = (firstSector + Int(position.rounded())) % sectorCount
            guard let radius = smoothedRadius(at: sector) else { continue }
            let angle = (Double(sector) + 0.5) / Double(sectorCount) * 2 * .pi
            points.append(
                Vec3(
                    centreX + radius * Foundation.cos(angle),
                    centreY + radius * Foundation.sin(angle),
                    verticalMM))
        }

        guard points.count >= 3 else { return nil }
        return points
    }

    /// Gli indici della macchia connessa più grande fra quelle oltre soglia.
    ///
    /// Connessione a quattro vicini e non a otto: a otto, due strutture che si sfiorano in
    /// diagonale — la corticale linguale e la punta di un processo — diventerebbero una sola, ed
    /// è proprio la fusione che questo filtro esiste per evitare.
    ///
    /// Iterativa e non ricorsiva: una fetta di CBCT a campo grande ha qualche milione di
    /// campioni, e una ricorsione così profonda esaurisce lo stack.
    static func largestComponent(
        densities: [Double], columns: Int, rows: Int, threshold: Double
    ) -> [Int] {
        let count = columns * rows
        guard count > 0, densities.count >= count else { return [] }

        var visited = [Bool](repeating: false, count: count)
        var best: [Int] = []
        var stack: [Int] = []

        for start in 0..<count {
            guard !visited[start], densities[start] >= threshold else { continue }
            visited[start] = true
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            var component: [Int] = []

            func push(_ neighbour: Int) {
                guard !visited[neighbour], densities[neighbour] >= threshold else { return }
                visited[neighbour] = true
                stack.append(neighbour)
            }

            while let index = stack.popLast() {
                component.append(index)
                let column = index % columns
                let row = index / columns
                if column > 0 { push(index - 1) }
                if column < columns - 1 { push(index + 1) }
                if row > 0 { push(index - columns) }
                if row < rows - 1 { push(index + columns) }
            }

            if component.count > best.count { best = component }
        }
        return best
    }
}
