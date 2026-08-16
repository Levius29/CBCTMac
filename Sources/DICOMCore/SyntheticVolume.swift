import Foundation

// Fantoccio sintetico generato in memoria.
//
// Riproduce esattamente il fantoccio di `Tools/PhantomGenerator/make_phantom.py`: stesse
// strutture, stesse quote, stesse densità. La corrispondenza è deliberata e va mantenuta, perché
// è ciò che rende confrontabili i due mondi — se l'applicazione misura sul fantoccio Swift un
// numero diverso da quello che lo script Python misura sul fantoccio DICOM, la differenza sta
// nel codice e non nei dati.
//
// Serve a tre cose:
//
//  1. Avere qualcosa da disegnare prima che il parser DICOM esista.
//  2. Provare l'interfaccia senza mai aprire dati di pazienti.
//  3. Fornire ai test un volume con misure note, senza file su disco.

public enum SyntheticVolume {

    // MARK: Densità di riferimento

    public static let air: Double = -1000
    public static let water: Double = 0
    public static let softTissue: Double = 60
    public static let cancellousBone: Double = 400
    public static let corticalBone: Double = 1200
    public static let enamel: Double = 2800

    // MARK: Quote del fantoccio, in millimetri

    /// Spigolo del cubo centrale. È la misura di riferimento principale.
    public static let cubeEdgeMM: Double = 20.0

    /// Sfere: diametro, densità, centro.
    public static let spheres: [(diameterMM: Double, density: Double, centerMM: Vec3)] = [
        (10.0, cancellousBone, Vec3(-18, 0, 0)),
        (6.0, enamel, Vec3(18, -10, 0)),
        (4.0, softTissue, Vec3(18, 10, 0)),
    ]

    public static let plateGapMM: Double = 10.0
    public static let plateThicknessMM: Double = 2.0
    public static let plateHalfWidthMM: Double = 12.0
    public static let plateCenterZMM: Double = -20.0

    // MARK: Generazione

    /// Costruisce il fantoccio.
    ///
    /// I valori predefiniti danno un volume di 60 × 60 × 60 mm a 0,25 mm isotropi, cioè un FOV
    /// plausibile per una CBCT dentale di piccolo campo, abbastanza alto da contenere anche le
    /// lastrine di riferimento a −20 mm.
    ///
    /// - Parameters:
    ///   - columns: voxel lungo l'asse `i`.
    ///   - rows: voxel lungo l'asse `j`.
    ///   - slices: voxel lungo l'asse `k`.
    ///   - spacingMM: passo dei voxel. Valori diversi fra loro producono un volume
    ///     anisotropico, utile a scoprire gli scambi fra spaziatura di righe e colonne, che su
    ///     voxel isotropici non danno alcun sintomo.
    public static func makePhantom(
        columns: Int = 240,
        rows: Int = 240,
        slices: Int = 240,
        spacingMM: Vec3 = Vec3(0.25, 0.25, 0.25)
    ) throws -> Volume {

        let rescaleIntercept = -1000.0
        let rescaleSlope = 1.0

        // Origine tale che il centro del volume cada in (0,0,0): il fantoccio è definito
        // attorno all'origine e così resta centrato.
        let origin = Vec3(
            -Double(columns - 1) * spacingMM.x / 2.0,
            -Double(rows - 1) * spacingMM.y / 2.0,
            -Double(slices - 1) * spacingMM.z / 2.0
        )

        let geometry = try VolumeGeometry(
            columnCount: columns,
            rowCount: rows,
            sliceCount: slices,
            columnSpacingMM: spacingMM.x,
            rowSpacingMM: spacingMM.y,
            sliceSpacingMM: spacingMM.z,
            orientation: .standardAxial,
            originMM: origin
        )

        var samples = [Int16](repeating: 0, count: columns * rows * slices)

        // Lo sfondo è aria ovunque; si riempie in blocco e poi si sovrascrivono solo le
        // strutture. Scorrere tutti i voxel chiamando `density(at:)` costerebbe una decina di
        // milioni di valutazioni, e all'apertura dell'applicazione si noterebbe.
        let airStored = Int16(clamping: Int(((air - rescaleIntercept) / rescaleSlope).rounded()))
        for index in samples.indices { samples[index] = airStored }

        for box in boundingBoxesMM() {
            let i0 = max(0, Int(((box.minMM.x - origin.x) / spacingMM.x).rounded(.down)))
            let i1 = min(columns - 1, Int(((box.maxMM.x - origin.x) / spacingMM.x).rounded(.up)))
            let j0 = max(0, Int(((box.minMM.y - origin.y) / spacingMM.y).rounded(.down)))
            let j1 = min(rows - 1, Int(((box.maxMM.y - origin.y) / spacingMM.y).rounded(.up)))
            let k0 = max(0, Int(((box.minMM.z - origin.z) / spacingMM.z).rounded(.down)))
            let k1 = min(slices - 1, Int(((box.maxMM.z - origin.z) / spacingMM.z).rounded(.up)))

            guard i0 <= i1, j0 <= j1, k0 <= k1 else { continue }

            for k in k0...k1 {
                let z = origin.z + Double(k) * spacingMM.z
                for j in j0...j1 {
                    let y = origin.y + Double(j) * spacingMM.y
                    let rowBase = (k * rows + j) * columns
                    for i in i0...i1 {
                        let x = origin.x + Double(i) * spacingMM.x
                        let value = density(atMM: Vec3(x, y, z))
                        guard value != air else { continue }
                        let stored = ((value - rescaleIntercept) / rescaleSlope).rounded()
                        samples[rowBase + i] = Int16(clamping: Int(stored))
                    }
                }
            }
        }

        return try Volume(
            geometry: geometry,
            samples: samples,
            rescaleSlope: rescaleSlope,
            rescaleIntercept: rescaleIntercept,
            densityUnit: .greyValue
        )
    }

    // MARK: Definizione analitica

    /// Densità nel punto indicato, in millimetri dal centro del volume.
    public static func density(atMM p: Vec3) -> Double {
        let half = cubeEdgeMM / 2.0
        if abs(p.x) <= half && abs(p.y) <= half && abs(p.z) <= half {
            return corticalBone
        }

        for sphere in spheres {
            let r = sphere.diameterMM / 2.0
            if (p - sphere.centerMM).lengthSquared <= r * r {
                return sphere.density
            }
        }

        if abs(p.x) <= plateHalfWidthMM && abs(p.y) <= plateHalfWidthMM {
            let halfGap = plateGapMM / 2.0
            for sign in [-1.0, 1.0] {
                let near = plateCenterZMM + sign * halfGap
                let far = near + sign * plateThicknessMM
                if p.z >= min(near, far) && p.z <= max(near, far) {
                    return corticalBone
                }
            }
        }

        return air
    }

    private struct BoundingBox {
        let minMM: Vec3
        let maxMM: Vec3
    }

    private static func boundingBoxesMM() -> [BoundingBox] {
        var boxes: [BoundingBox] = []

        let half = cubeEdgeMM / 2.0
        boxes.append(
            BoundingBox(minMM: Vec3(-half, -half, -half), maxMM: Vec3(half, half, half)))

        for sphere in spheres {
            let r = sphere.diameterMM / 2.0
            boxes.append(
                BoundingBox(
                    minMM: sphere.centerMM - Vec3(r, r, r),
                    maxMM: sphere.centerMM + Vec3(r, r, r)))
        }

        let halfGap = plateGapMM / 2.0
        let w = plateHalfWidthMM
        boxes.append(
            BoundingBox(
                minMM: Vec3(-w, -w, plateCenterZMM - halfGap - plateThicknessMM),
                maxMM: Vec3(w, w, plateCenterZMM + halfGap + plateThicknessMM)))

        return boxes
    }

    // MARK: Misure attese

    /// Le misure che l'applicazione deve restituire su questo fantoccio.
    ///
    /// Sono gli stessi valori che `verify_phantom.py` stampa sulla serie DICOM equivalente, e
    /// sono già stati verificati con quello script. Servono da specifica per i test e da lista
    /// di controllo per la verifica manuale sul Mac.
    public static let expectedMeasurements: [(label: String, value: String)] = [
        ("Spigolo del cubo", "20,00 mm"),
        ("Diagonale di faccia", "28,28 mm"),
        ("Diagonale del cubo", "34,64 mm"),
        ("Intercapedine fra lastrine", "10,00 mm"),
        ("Spessore lastrina", "2,00 mm"),
        ("Densità del cubo", "1200 GV"),
        ("Sfera Ø10 mm, spongiosa", "400 GV"),
        ("Sfera Ø6 mm, smalto", "2800 GV"),
        ("Sfera Ø4 mm, tessuto molle", "60 GV"),
        ("Aria", "−1000 GV"),
    ]
}
