import Foundation

// Geometria del volume: conversione voxel ↔ Patient e ordinamento delle slice.
//
// Implementa i Contratti 1 e 2 di docs/architecture.md. È il punto in cui un errore non
// produce un crash né un'immagine visibilmente storta, ma misure sbagliate di pochi punti
// percentuali — cioè il tipo di errore che nessuno nota finché non conta davvero.

// MARK: - Orientamento

/// I due versori di `ImageOrientationPatient (0020,0037)`.
///
/// `columnDirection` sono i primi tre valori: direzione in cui si muove il punto nello spazio
/// Patient quando cresce l'indice di **colonna** `i`. `rowDirection` sono gli ultimi tre:
/// direzione per l'indice di **riga** `j`.
public struct SliceOrientation: Hashable, Sendable, Codable {
    public let columnDirection: Vec3
    public let rowDirection: Vec3

    /// Costruisce normalizzando i due versori.
    /// Restituisce `nil` se un vettore è nullo o se i due sono paralleli (normale indefinita).
    public init?(columnDirection: Vec3, rowDirection: Vec3) {
        guard let c = columnDirection.normalized, let r = rowDirection.normalized else { return nil }
        guard c.cross(r).length > 1e-6 else { return nil }
        self.columnDirection = c
        self.rowDirection = r
    }

    /// Da un array di 6 valori come li fornisce il tag DICOM.
    public init?(dicomValues values: [Double]) {
        guard values.count >= 6,
              let c = Vec3(values, offset: 0),
              let r = Vec3(values, offset: 3)
        else { return nil }
        self.init(columnDirection: c, rowDirection: r)
    }

    /// Orientamento assiale standard `[1,0,0,0,1,0]`, il caso di gran lunga più frequente
    /// sulle CBCT — che comunque non si assume mai: si legge sempre il tag.
    public static let standardAxial = SliceOrientation(
        columnDirection: Vec3(1, 0, 0),
        rowDirection: Vec3(0, 1, 0)
    )!

    /// Normale alla slice, `columnDirection × rowDirection`, versore.
    public var normal: Vec3 {
        // Sicuro: l'init garantisce che il prodotto vettoriale non sia nullo.
        columnDirection.cross(rowDirection).normalized ?? Vec3(0, 0, 1)
    }

    /// Massimo scostamento angolare dai versori di `other`, come lunghezza della differenza.
    /// Serve a verificare che tutte le slice della serie condividano l'orientamento.
    public func maxDeviation(from other: SliceOrientation) -> Double {
        max(
            (columnDirection - other.columnDirection).length,
            (rowDirection - other.rowDirection).length
        )
    }
}

// MARK: - Descrittore di slice

/// Il minimo indispensabile per collocare una slice nello spazio.
///
/// Tipo deliberatamente separato dal parsing DICOM: l'ordinamento e la costruzione della
/// geometria si testano così con dati sintetici, senza bisogno di file veri.
public struct SliceDescriptor: Hashable, Sendable {
    /// `ImagePositionPatient (0020,0032)`: centro del voxel (0,0) della slice, in mm.
    public let positionMM: Vec3
    public let orientation: SliceOrientation
    /// Posizione nell'array d'ingresso, per risalire al file dopo il riordino.
    public let sourceIndex: Int

    public init(positionMM: Vec3, orientation: SliceOrientation, sourceIndex: Int) {
        self.positionMM = positionMM
        self.orientation = orientation
        self.sourceIndex = sourceIndex
    }
}

// MARK: - Anomalie

/// Anomalia geometrica rilevata: non impedisce di costruire il volume, ma va mostrata
/// all'utente. Ignorarla in silenzio è esattamente ciò che il Contratto 2 vieta.
public enum VolumeGeometryIssue: Hashable, Sendable {
    /// Passo fra slice non uniforme. Le misure lungo l'asse `k` sono approssimate.
    case nonUniformSpacing(nominalMM: Double, maxDeviationMM: Double, atOrderedIndex: Int)
    /// Slice con la stessa posizione, scartate.
    case duplicatePositions(discardedSourceIndices: [Int])
    /// Una sola slice: non è un volume, il passo è convenzionale.
    case singleSlice

    public var isSevere: Bool {
        switch self {
        case .nonUniformSpacing(_, let deviation, _): return deviation > 0.1
        case .duplicatePositions: return false
        case .singleSlice: return true
        }
    }

    /// Messaggio pronto per la UI.
    public var localizedDescription: String {
        switch self {
        case .nonUniformSpacing(let nominal, let deviation, let index):
            return String(
                format: "Spaziatura fra slice non uniforme: attesa %.3f mm, scostamento massimo "
                    + "%.3f mm alla slice %d. Le misure lungo l'asse assiale sono approssimate.",
                nominal, deviation, index
            )
        case .duplicatePositions(let indices):
            return "Scartate \(indices.count) slice con posizione duplicata."
        case .singleSlice:
            return "La serie contiene una sola immagine: non è un volume, "
                + "le misure fuori piano non sono disponibili."
        }
    }
}

/// Fallimento che impedisce di costruire una geometria valida.
public enum VolumeGeometryError: Error, Hashable, Sendable {
    case noSlices
    /// Le slice non condividono lo stesso orientamento: non è un volume regolare.
    case inconsistentOrientation(maxDeviation: Double)
    case invalidPixelSpacing(rowMM: Double, columnMM: Double)
    case invalidDimensions(columns: Int, rows: Int)
    /// La matrice risultante non è invertibile (assi collineari o passo nullo).
    case degenerateGeometry

    public var localizedDescription: String {
        switch self {
        case .noSlices:
            return "Nessuna immagine nella serie."
        case .inconsistentOrientation(let d):
            return String(
                format: "Le immagini non condividono lo stesso orientamento (scostamento %.6f). "
                    + "La serie non costituisce un volume regolare.", d)
        case .invalidPixelSpacing(let r, let c):
            return String(format: "Spaziatura pixel non valida: righe %.4f mm, colonne %.4f mm.", r, c)
        case .invalidDimensions(let c, let r):
            return "Dimensioni immagine non valide: \(c)×\(r)."
        case .degenerateGeometry:
            return "Geometria degenere: la matrice del volume non è invertibile."
        }
    }
}

// MARK: - VolumeGeometry

/// Descrive dove sta ogni voxel nello spazio Patient.
///
/// Unico proprietario della conversione fra i tre spazi di coordinate del progetto.
/// Nessun altro tipo costruisce matrici di volume per conto proprio.
public struct VolumeGeometry: Hashable, Sendable {

    // Dimensioni in voxel. `i` colonne, `j` righe, `k` slice.
    public let columnCount: Int
    public let rowCount: Int
    public let sliceCount: Int

    /// Passo fra colonne adiacenti, cioè `PixelSpacing[1]`.
    public let columnSpacingMM: Double
    /// Passo fra righe adiacenti, cioè `PixelSpacing[0]`.
    public let rowSpacingMM: Double
    /// Passo fra slice, ricavato dalle posizioni (mai da `SliceThickness`).
    public let sliceSpacingMM: Double

    public let orientation: SliceOrientation
    /// `ImagePositionPatient` della prima slice **dopo l'ordinamento**.
    public let originMM: Vec3

    /// Voxel `(i, j, k)` → Patient in millimetri.
    public let voxelToPatient: Transform3D
    /// Patient in millimetri → voxel `(i, j, k)`, in generale non interi.
    public let patientToVoxel: Transform3D

    /// Costruttore diretto. Fallisce se le dimensioni o le spaziature sono insensate,
    /// oppure se la matrice risultante non è invertibile.
    ///
    /// La matrice segue DICOM PS3.3 C.7.6.2.1.1 (vedi docs/architecture.md § Contratto 1):
    /// la colonna `i` porta `columnSpacingMM`, la colonna `j` porta `rowSpacingMM`.
    /// L'accoppiamento incrociato è la trappola più insidiosa dell'intero formato, perché su
    /// voxel isotropici — cioè quasi tutte le CBCT — non produce alcun effetto visibile.
    public init(
        columnCount: Int,
        rowCount: Int,
        sliceCount: Int,
        columnSpacingMM: Double,
        rowSpacingMM: Double,
        sliceSpacingMM: Double,
        orientation: SliceOrientation,
        originMM: Vec3
    ) throws {
        guard columnCount > 0, rowCount > 0 else {
            throw VolumeGeometryError.invalidDimensions(columns: columnCount, rows: rowCount)
        }
        guard columnSpacingMM.isFinite, rowSpacingMM.isFinite,
              columnSpacingMM > 0, rowSpacingMM > 0
        else {
            throw VolumeGeometryError.invalidPixelSpacing(rowMM: rowSpacingMM, columnMM: columnSpacingMM)
        }

        let normal = orientation.normal
        // Un volume a una sola slice ha passo convenzionale: qualunque valore positivo va
        // bene, purché la matrice resti invertibile.
        let effectiveSliceSpacing =
            (sliceSpacingMM.isFinite && abs(sliceSpacingMM) > 1e-9) ? sliceSpacingMM : 1.0

        let transform = Transform3D(
            columnX: orientation.columnDirection * columnSpacingMM,
            columnY: orientation.rowDirection * rowSpacingMM,
            columnZ: normal * effectiveSliceSpacing,
            origin: originMM
        )
        guard let inverse = transform.inverse else {
            throw VolumeGeometryError.degenerateGeometry
        }

        self.columnCount = columnCount
        self.rowCount = rowCount
        self.sliceCount = max(sliceCount, 1)
        self.columnSpacingMM = columnSpacingMM
        self.rowSpacingMM = rowSpacingMM
        self.sliceSpacingMM = effectiveSliceSpacing
        self.orientation = orientation
        self.originMM = originMM
        self.voxelToPatient = transform
        self.patientToVoxel = inverse
    }

    // MARK: Conversioni

    /// Indici voxel (anche frazionari) → punto in mm nello spazio Patient.
    public func patientPoint(fromVoxel v: Vec3) -> Vec3 {
        voxelToPatient.apply(toPoint: v)
    }

    /// Comodità per indici interi.
    public func patientPoint(i: Int, j: Int, k: Int) -> Vec3 {
        patientPoint(fromVoxel: Vec3(Double(i), Double(j), Double(k)))
    }

    /// Punto in mm → indici voxel frazionari. Il chiamante decide se arrotondare
    /// (campionamento nearest) o interpolare.
    public func voxelPoint(fromPatient p: Vec3) -> Vec3 {
        patientToVoxel.apply(toPoint: p)
    }

    /// Vero se gli indici cadono dentro il volume, con mezzo voxel di margine sui bordi
    /// come vuole il campionamento ai centri.
    public func containsVoxel(_ v: Vec3) -> Bool {
        v.x >= -0.5 && v.x <= Double(columnCount) - 0.5
            && v.y >= -0.5 && v.y <= Double(rowCount) - 0.5
            && v.z >= -0.5 && v.z <= Double(sliceCount) - 0.5
    }

    public func containsPatientPoint(_ p: Vec3) -> Bool {
        containsVoxel(voxelPoint(fromPatient: p))
    }

    // MARK: Proprietà derivate

    public var voxelCount: Int { columnCount * rowCount * sliceCount }

    public var spacingMM: Vec3 { Vec3(columnSpacingMM, rowSpacingMM, sliceSpacingMM) }

    /// Ingombro fisico del volume in mm lungo i tre assi voxel.
    public var physicalSizeMM: Vec3 {
        Vec3(
            Double(columnCount) * columnSpacingMM,
            Double(rowCount) * rowSpacingMM,
            Double(sliceCount) * sliceSpacingMM
        )
    }

    /// Centro geometrico del volume in coordinate Patient. Punto di partenza naturale
    /// per il mirino all'apertura di uno studio.
    public var centerMM: Vec3 {
        patientPoint(
            fromVoxel: Vec3(
                Double(columnCount - 1) * 0.5,
                Double(rowCount - 1) * 0.5,
                Double(sliceCount - 1) * 0.5
            ))
    }

    /// Voxel isotropici entro `tolerance` (in mm). Le CBCT lo sono quasi sempre, e questo
    /// consente scorciatoie nel rendering.
    public func isIsotropic(tolerance: Double = 1e-3) -> Bool {
        abs(columnSpacingMM - rowSpacingMM) <= tolerance
            && abs(columnSpacingMM - sliceSpacingMM) <= tolerance
    }

    /// Gli otto vertici del volume in coordinate Patient, utili per inquadrature e
    /// intersezione raggio-scatola nel raycasting.
    public var boundingBoxCornersMM: [Vec3] {
        let lo = -0.5
        let hiI = Double(columnCount) - 0.5
        let hiJ = Double(rowCount) - 0.5
        let hiK = Double(sliceCount) - 0.5
        return [
            Vec3(lo, lo, lo), Vec3(hiI, lo, lo), Vec3(lo, hiJ, lo), Vec3(hiI, hiJ, lo),
            Vec3(lo, lo, hiK), Vec3(hiI, lo, hiK), Vec3(lo, hiJ, hiK), Vec3(hiI, hiJ, hiK),
        ].map { patientPoint(fromVoxel: $0) }
    }
}

// MARK: - Ordinamento delle slice

/// Esito dell'ordinamento: geometria, ordine dei file e anomalie riscontrate.
public struct SortedSliceSet: Sendable {
    public let geometry: VolumeGeometry
    /// `sourceIndex` delle slice in ordine geometrico crescente lungo la normale.
    /// È l'ordine in cui vanno letti i pixel per riempire il volume.
    public let order: [Int]
    public let issues: [VolumeGeometryIssue]

    public init(geometry: VolumeGeometry, order: [Int], issues: [VolumeGeometryIssue]) {
        self.geometry = geometry
        self.order = order
        self.issues = issues
    }
}

public enum SliceSorter {

    /// Scostamento massimo tollerato fra gli orientamenti delle slice di una serie.
    public static let orientationTolerance = 1e-4
    /// Oltre questo scostamento dal passo nominale si segnala spaziatura non uniforme.
    public static let spacingToleranceMM = 0.01
    /// Sotto questa distanza due slice sono considerate nella stessa posizione.
    public static let duplicateToleranceMM = 1e-4

    /// Ordina le slice per proiezione sulla normale e costruisce la geometria.
    ///
    /// **Non si usa `InstanceNumber (0020,0013)`.** È incoerente fra produttori e su molte CBCT
    /// manca del tutto; ordinare con quello significa, nei casi peggiori, comporre un volume
    /// con le slice mescolate. L'unica fonte affidabile è la posizione geometrica.
    ///
    /// - Parameters:
    ///   - slices: descrittori in qualunque ordine.
    ///   - columnCount: colonne per slice (`Columns (0028,0011)`).
    ///   - rowCount: righe per slice (`Rows (0028,0010)`).
    ///   - pixelSpacingMM: `PixelSpacing (0028,0030)` nell'ordine DICOM `[righe, colonne]`.
    ///   - fallbackSliceSpacingMM: usato solo con una slice sola (tipicamente
    ///     `SliceThickness`); ignorato quando il passo si può calcolare dalle posizioni.
    public static func sort(
        slices: [SliceDescriptor],
        columnCount: Int,
        rowCount: Int,
        pixelSpacingMM: (row: Double, column: Double),
        fallbackSliceSpacingMM: Double = 1.0
    ) throws -> SortedSliceSet {

        guard let first = slices.first else { throw VolumeGeometryError.noSlices }

        // 1. Orientamento condiviso. Se le slice non concordano non è un volume regolare:
        //    meglio un errore esplicito che un volume distorto in modo plausibile.
        let orientation = first.orientation
        var maxOrientationDeviation = 0.0
        for slice in slices.dropFirst() {
            maxOrientationDeviation = max(
                maxOrientationDeviation, slice.orientation.maxDeviation(from: orientation))
        }
        guard maxOrientationDeviation <= orientationTolerance else {
            throw VolumeGeometryError.inconsistentOrientation(maxDeviation: maxOrientationDeviation)
        }

        // 2. Proiezione sulla normale e ordinamento.
        let normal = orientation.normal
        let projected = slices
            .map { (slice: $0, d: $0.positionMM.dot(normal)) }
            .sorted { $0.d < $1.d }

        // 3. Rimozione dei duplicati, mantenendo il primo di ogni posizione.
        var issues: [VolumeGeometryIssue] = []
        var unique: [(slice: SliceDescriptor, d: Double)] = []
        var discarded: [Int] = []
        for entry in projected {
            if let last = unique.last, abs(entry.d - last.d) < duplicateToleranceMM {
                discarded.append(entry.slice.sourceIndex)
            } else {
                unique.append(entry)
            }
        }
        if !discarded.isEmpty {
            issues.append(.duplicatePositions(discardedSourceIndices: discarded))
        }

        // 4. Passo fra slice: dalla distanza fra la prima e l'ultima, non dalla media delle
        //    differenze locali, che è più sensibile al rumore sulle singole posizioni.
        let sliceSpacingMM: Double
        if unique.count >= 2 {
            let span = unique[unique.count - 1].d - unique[0].d
            sliceSpacingMM = span / Double(unique.count - 1)
        } else {
            sliceSpacingMM = fallbackSliceSpacingMM
            issues.append(.singleSlice)
        }

        // 5. Verifica di uniformità. Va segnalata perché è invisibile sull'immagine e
        //    falsa ogni misura lungo l'asse delle slice.
        if unique.count >= 3 {
            var maxDeviation = 0.0
            var worstIndex = 0
            for n in 0..<(unique.count - 1) {
                let step = unique[n + 1].d - unique[n].d
                let deviation = abs(step - sliceSpacingMM)
                if deviation > maxDeviation {
                    maxDeviation = deviation
                    worstIndex = n + 1
                }
            }
            if maxDeviation > spacingToleranceMM {
                issues.append(
                    .nonUniformSpacing(
                        nominalMM: sliceSpacingMM,
                        maxDeviationMM: maxDeviation,
                        atOrderedIndex: worstIndex))
            }
        }

        // 6. L'origine è la posizione della prima slice *dopo* l'ordinamento, non di quella
        //    che capitava per prima nell'array d'ingresso.
        let geometry = try VolumeGeometry(
            columnCount: columnCount,
            rowCount: rowCount,
            sliceCount: unique.count,
            columnSpacingMM: pixelSpacingMM.column,
            rowSpacingMM: pixelSpacingMM.row,
            sliceSpacingMM: sliceSpacingMM,
            orientation: orientation,
            originMM: unique[0].slice.positionMM
        )

        return SortedSliceSet(
            geometry: geometry,
            order: unique.map(\.slice.sourceIndex),
            issues: issues
        )
    }
}

// MARK: - Piani anatomici

/// I tre piani ortogonali canonici, con gli assi di schermo in convenzione radiologica:
/// la destra del paziente compare a sinistra dello schermo.
///
/// Vedi la tabella in docs/architecture.md § Contratto 1.
public enum AnatomicalPlane: String, CaseIterable, Hashable, Sendable, Codable {
    case axial
    case coronal
    case sagittal

    /// Asse orizzontale dello schermo, verso destra, in coordinate Patient.
    public var screenRightMM: Vec3 {
        switch self {
        case .axial: return Vec3(1, 0, 0)     // +L
        case .coronal: return Vec3(1, 0, 0)   // +L
        case .sagittal: return Vec3(0, 1, 0)  // +P
        }
    }

    /// Asse verticale dello schermo, verso il basso, in coordinate Patient.
    public var screenDownMM: Vec3 {
        switch self {
        case .axial: return Vec3(0, 1, 0)      // +P
        case .coronal: return Vec3(0, 0, -1)   // +I
        case .sagittal: return Vec3(0, 0, -1)  // +I
        }
    }

    /// Normale al piano, cioè la direzione in cui avanza lo scorrimento delle slice.
    public var normalMM: Vec3 {
        // Coerente con screenRight × screenDown, esplicitata per chiarezza.
        switch self {
        case .axial: return Vec3(0, 0, 1)      // +S
        case .coronal: return Vec3(0, 1, 0)    // +P
        case .sagittal: return Vec3(-1, 0, 0)  // +R
        }
    }

    /// Etichetta per la UI, in italiano.
    public var localizedName: String {
        switch self {
        case .axial: return "Assiale"
        case .coronal: return "Coronale"
        case .sagittal: return "Sagittale"
        }
    }

    /// Lettere d'orientamento da mostrare ai quattro bordi del riquadro.
    ///
    /// Sono la difesa contro l'errore peggiore che si possa commettere su un'immagine
    /// radiologica: scambiare destra e sinistra del paziente. La convenzione mette la **destra
    /// del paziente a sinistra dello schermo** — come se lo si guardasse in faccia — cioè il
    /// contrario di quanto suggerisce l'istinto, e senza le lettere nulla lo ricorda.
    ///
    /// Non sono scritte a mano: si **derivano** da `screenRightMM` e `screenDownMM`, gli stessi
    /// vettori che il renderer usa per costruire il piano. Scriverle a parte significherebbe
    /// avere due dichiarazioni della stessa convenzione, e un giorno una delle due cambierebbe
    /// senza l'altra: l'immagine sarebbe specchiata e le lettere direbbero il contrario, che è
    /// peggio di non averle.
    public var edgeLabels: (top: String, bottom: String, left: String, right: String) {
        (
            top: Self.label(for: screenDownMM * -1),
            bottom: Self.label(for: screenDownMM),
            left: Self.label(for: screenRightMM * -1),
            right: Self.label(for: screenRightMM)
        )
    }

    /// Lettera del verso anatomico prevalente di una direzione, in LPS.
    ///
    /// In LPS gli assi crescono verso sinistra del paziente (+L), verso il posteriore (+P) e verso
    /// l'alto (+S); i versi opposti sono destra (R), anteriore (A) e piedi (F). Si usano le
    /// iniziali internazionali e non quelle italiane perché sono quelle che compaiono su ogni
    /// referto e su ogni apparecchio: tradurle renderebbe l'immagine meno leggibile, non di più.
    static func label(for direction: Vec3) -> String {
        let x = abs(direction.x), y = abs(direction.y), z = abs(direction.z)
        if x >= y, x >= z { return direction.x >= 0 ? "L" : "R" }
        if y >= z { return direction.y >= 0 ? "P" : "A" }
        return direction.z >= 0 ? "H" : "F"
    }
}
