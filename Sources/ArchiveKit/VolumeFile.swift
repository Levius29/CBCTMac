import DICOMCore
import Foundation

// Il volume su disco.
//
// # Perché un formato proprio invece di ricopiare il DICOM
//
// Perché riaprire deve essere immediato. Rileggere una cartella di cinquecento file DICOM
// significa cinquecento aperture, cinquecento parse di header e un riordinamento: sono secondi,
// ogni volta, per ricostruire un volume che era già stato ricostruito. Qui i campioni sono già
// nell'ordine in cui la texture li vuole, e riaprire è una lettura sola.
//
// La contropartita è dichiarata e non si nasconde: **l'archivio non conserva i file DICOM
// originali**. Conserva il volume ricostruito e i metadati che contano. Chi deve consegnare i
// DICOM a un laboratorio deve tenersi la cartella originale — e l'archivio ne registra il
// percorso proprio per poterla ritrovare.
//
// # Perché non compresso
//
// Un volume da 512³ occupa 268 MB. Comprimere ne toglierebbe forse la metà, al prezzo di una
// dipendenza da `Compression`, che è di Apple e non si può provare in questo ambiente. Un
// formato che non si può verificare non è un risparmio: è un rischio su dei dati che l'utente
// crede al sicuro. Le cartelle DICOM da cui questi volumi vengono pesano già altrettanto.
//
// # L'ordine dei byte
//
// Little-endian, sempre e dichiarato nell'intestazione. Su Apple non esistono macchine
// big-endian da anni e sarebbe stato comodo assumerlo; ma un formato che assume tace, e un file
// letto sulla macchina sbagliata darebbe un volume di rumore invece di un errore.

public enum VolumeFileError: Error, Sendable, LocalizedError {
    case unsupportedVersion(Int)
    case unsupportedByteOrder(String)
    case sampleCountMismatch(expected: Int, found: Int)
    case malformedHeader(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Il volume archiviato è in formato versione \(version), che questa versione "
                + "del programma non sa leggere."
        case .unsupportedByteOrder(let order):
            return "Il volume archiviato dichiara ordine dei byte «\(order)», non gestito."
        case .sampleCountMismatch(let expected, let found):
            return "Il volume archiviato è incompleto: attesi \(expected) campioni, trovati "
                + "\(found). Il file è probabilmente troncato."
        case .malformedHeader(let detail):
            return "Intestazione del volume archiviato illeggibile: \(detail)."
        }
    }
}

/// L'intestazione che accompagna i campioni.
public struct VolumeFileHeader: Hashable, Sendable, Codable {

    public static let currentVersion = 1

    public var version: Int
    public var byteOrder: String

    public var columnCount: Int
    public var rowCount: Int
    public var sliceCount: Int
    public var columnSpacingMM: Double
    public var rowSpacingMM: Double
    public var sliceSpacingMM: Double
    /// Sei valori, come `ImageOrientationPatient`.
    public var orientation: [Double]
    /// Tre valori, come `ImagePositionPatient` della prima slice dopo l'ordinamento.
    public var originMM: [Double]

    public var rescaleSlope: Double
    public var rescaleIntercept: Double
    /// `GV` o `HU`, con la stessa convenzione di `DensityUnit`.
    public var densityUnit: String

    public init(volume: Volume) {
        let g = volume.geometry
        self.version = Self.currentVersion
        self.byteOrder = "little"
        self.columnCount = g.columnCount
        self.rowCount = g.rowCount
        self.sliceCount = g.sliceCount
        self.columnSpacingMM = g.columnSpacingMM
        self.rowSpacingMM = g.rowSpacingMM
        self.sliceSpacingMM = g.sliceSpacingMM
        self.orientation = [
            g.orientation.columnDirection.x, g.orientation.columnDirection.y,
            g.orientation.columnDirection.z,
            g.orientation.rowDirection.x, g.orientation.rowDirection.y,
            g.orientation.rowDirection.z,
        ]
        self.originMM = [g.originMM.x, g.originMM.y, g.originMM.z]
        self.rescaleSlope = volume.rescaleSlope
        self.rescaleIntercept = volume.rescaleIntercept
        self.densityUnit = volume.densityUnit.symbol
    }

    /// Numero di campioni che il file dei dati deve contenere.
    public var voxelCount: Int { columnCount * rowCount * sliceCount }

    /// Ricostruisce la geometria.
    public func makeGeometry() throws -> VolumeGeometry {
        guard let slice = SliceOrientation(dicomValues: orientation) else {
            throw VolumeFileError.malformedHeader("orientamento non valido")
        }
        guard originMM.count >= 3, let origin = Vec3(originMM, offset: 0) else {
            throw VolumeFileError.malformedHeader("origine non valida")
        }
        return try VolumeGeometry(
            columnCount: columnCount,
            rowCount: rowCount,
            sliceCount: sliceCount,
            columnSpacingMM: columnSpacingMM,
            rowSpacingMM: rowSpacingMM,
            sliceSpacingMM: sliceSpacingMM,
            orientation: slice,
            originMM: origin)
    }
}

public enum VolumeFile: Sendable {

    public static let headerName = "volume.json"
    public static let samplesName = "volume.bin"

    /// Scrive intestazione e campioni nella cartella indicata, che deve esistere.
    ///
    /// I campioni **prima** dell'intestazione: se il programma muore fra le due scritture resta
    /// una cartella senza `volume.json`, e `read` la rifiuta subito. Nell'ordine inverso
    /// resterebbe un'intestazione valida davanti a dei dati mancanti, cioè un esame che
    /// l'archivio elenca e non sa aprire.
    public static func write(_ volume: Volume, to directory: URL) throws {
        try writeSamples(volume.samples, to: directory.appendingPathComponent(samplesName))

        let header = VolumeFileHeader(volume: volume)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(header).write(
            to: directory.appendingPathComponent(headerName), options: .atomic)
    }

    /// Rilegge il volume da una cartella scritta da `write`.
    public static func read(from directory: URL) throws -> Volume {
        let headerData = try Data(contentsOf: directory.appendingPathComponent(headerName))
        let header = try JSONDecoder().decode(VolumeFileHeader.self, from: headerData)

        guard header.version <= VolumeFileHeader.currentVersion else {
            throw VolumeFileError.unsupportedVersion(header.version)
        }
        guard header.byteOrder == "little" else {
            throw VolumeFileError.unsupportedByteOrder(header.byteOrder)
        }

        let raw = try Data(contentsOf: directory.appendingPathComponent(samplesName))
        let found = raw.count / MemoryLayout<Int16>.size
        guard found == header.voxelCount else {
            throw VolumeFileError.sampleCountMismatch(expected: header.voxelCount, found: found)
        }

        return try Volume(
            geometry: header.makeGeometry(),
            samples: readSamples(raw, count: header.voxelCount),
            rescaleSlope: header.rescaleSlope,
            rescaleIntercept: header.rescaleIntercept,
            densityUnit: DensityUnit(symbol: header.densityUnit))
    }

    /// Byte che occuperà il file dei campioni.
    public static func byteCount(of volume: Volume) -> Int {
        volume.samples.count * MemoryLayout<Int16>.size
    }

    // MARK: Campioni

    /// Vero se questa macchina ha già i byte nell'ordine del formato.
    ///
    /// Su ogni Mac degli ultimi vent'anni è vero, e resta una **verifica** e non un'assunzione:
    /// il ramo lento esiste, è corretto, e su una macchina big-endian scriverebbe lo stesso file.
    private static var isNativelyLittleEndian: Bool { UInt16(1).littleEndian == 1 }

    /// Little-endian esplicito, indipendente dall'ordine nativo della macchina.
    ///
    /// # Perché la via veloce non è un'ottimizzazione prematura
    ///
    /// Un volume da 512³ ha 134 milioni di campioni. Costruendo un `[UInt8]` a byte a byte si
    /// allocano 268 MB di array **più** i 268 MB del `Data` che lo copia: mezzo gigabyte di
    /// picco per scriverne un quarto, e 268 milioni di `append`. Quando l'ordine dei byte è già
    /// quello giusto — su Apple, sempre — i campioni si consegnano al sistema così come stanno,
    /// senza copie intermedie e senza cicli.
    private static func writeSamples(_ samples: [Int16], to url: URL) throws {
        if isNativelyLittleEndian {
            try samples.withUnsafeBufferPointer { buffer in
                try Data(buffer: buffer).write(to: url, options: .atomic)
            }
            return
        }
        try portableBytes(of: samples).write(to: url, options: .atomic)
    }

    /// I byte little-endian costruiti a mano, senza dipendere dall'ordine della macchina.
    ///
    /// Interno e non privato perché è la via che su Apple non viene mai percorsa, e una via che
    /// non si percorre non si sa se funziona. Un test la confronta con quella veloce: è l'unico
    /// modo di verificare qui il ramo big-endian, e verificare che i due **coincidano** è
    /// esattamente ciò che serve.
    static func portableBytes(of samples: [Int16]) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(samples.count * 2)
        for sample in samples {
            let unsigned = UInt16(bitPattern: sample)
            bytes.append(UInt8(unsigned & 0xFF))
            bytes.append(UInt8((unsigned >> 8) & 0xFF))
        }
        return Data(bytes)
    }

    private static func readSamples(_ data: Data, count: Int) -> [Int16] {
        // `withUnsafeBytes` invece dell'indicizzazione: un `Data` ottenuto da una sotto-sequenza
        // non parte dall'indice zero, e indicizzarlo da zero leggerebbe fuori posto.
        //
        // `copyBytes` e non un ciclo: leggere un volume grande campione per campione sono
        // centotrenta milioni di iterazioni, e si sentono all'apertura di ogni esame.
        // L'allineamento non si assume — un `Data` mappato può cominciare a un indirizzo
        // dispari — quindi si copiano byte, non `Int16`.
        guard isNativelyLittleEndian else { return portableSamples(from: data, count: count) }
        return [Int16](unsafeUninitializedCapacity: count) { destination, initialized in
            data.withUnsafeBytes { source in
                let raw = UnsafeMutableRawBufferPointer(destination)
                raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: source[0..<(count * 2)]))
            }
            initialized = count
        }
    }

    /// I campioni ricostruiti byte a byte, senza dipendere dall'ordine della macchina.
    ///
    /// Come `portableBytes`, e per la stessa ragione: su Apple non viene mai eseguita, quindi
    /// senza un test che la confronti con la via veloce non si saprebbe se funziona. Il primo
    /// tentativo di provarla con una mutazione infatti non falliva — il ramo non veniva
    /// percorso, e la mutazione era inerte.
    static func portableSamples(from data: Data, count: Int) -> [Int16] {
        var samples = [Int16]()
        samples.reserveCapacity(count)
        data.withUnsafeBytes { source in
            var index = 0
            while index < count {
                let low = UInt16(source[index * 2])
                let high = UInt16(source[index * 2 + 1])
                samples.append(Int16(bitPattern: low | (high << 8)))
                index += 1
            }
        }
        return samples
    }
}
