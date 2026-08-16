import Foundation

/// Sintassi di trasferimento DICOM: come sono codificati i byte del dataset e dei pixel.
///
/// Determina tre cose che il parser deve sapere prima di leggere qualunque altra cosa:
/// se i VR sono espliciti, l'ordine dei byte, e se i pixel sono incapsulati (compressi).
public enum TransferSyntax: Hashable, Sendable {

    // Non compresse (native)
    case implicitVRLittleEndian
    case explicitVRLittleEndian
    case explicitVRBigEndian  // ritirata dallo standard, ancora presente in archivi datati
    case deflatedExplicitVRLittleEndian

    // Incapsulate (compresse)
    case rleLossless
    case jpegBaseline8Bit
    case jpegExtended12Bit
    case jpegLosslessNonHierarchical      // processo 14
    case jpegLosslessNonHierarchicalSV1   // processo 14, selection value 1 — il più diffuso
    case jpegLSLossless
    case jpegLSNearLossless
    case jpeg2000Lossless
    case jpeg2000
    case jpeg2000MultiComponentLossless
    case jpeg2000MultiComponent

    /// Sintassi non prevista dalla tabella. Si conserva l'UID per poterlo mostrare all'utente
    /// e per non far fallire il parsing dei soli metadati.
    case unknown(uid: String)

    public init(uid: String) {
        let trimmed = uid.trimmingCharacters(in: CharacterSet(charactersIn: "\0 "))
        switch trimmed {
        case "1.2.840.10008.1.2": self = .implicitVRLittleEndian
        case "1.2.840.10008.1.2.1": self = .explicitVRLittleEndian
        case "1.2.840.10008.1.2.1.99": self = .deflatedExplicitVRLittleEndian
        case "1.2.840.10008.1.2.2": self = .explicitVRBigEndian
        case "1.2.840.10008.1.2.5": self = .rleLossless
        case "1.2.840.10008.1.2.4.50": self = .jpegBaseline8Bit
        case "1.2.840.10008.1.2.4.51": self = .jpegExtended12Bit
        case "1.2.840.10008.1.2.4.57": self = .jpegLosslessNonHierarchical
        case "1.2.840.10008.1.2.4.70": self = .jpegLosslessNonHierarchicalSV1
        case "1.2.840.10008.1.2.4.80": self = .jpegLSLossless
        case "1.2.840.10008.1.2.4.81": self = .jpegLSNearLossless
        case "1.2.840.10008.1.2.4.90": self = .jpeg2000Lossless
        case "1.2.840.10008.1.2.4.91": self = .jpeg2000
        case "1.2.840.10008.1.2.4.92": self = .jpeg2000MultiComponentLossless
        case "1.2.840.10008.1.2.4.93": self = .jpeg2000MultiComponent
        default: self = .unknown(uid: trimmed)
        }
    }

    public var uid: String {
        switch self {
        case .implicitVRLittleEndian: return "1.2.840.10008.1.2"
        case .explicitVRLittleEndian: return "1.2.840.10008.1.2.1"
        case .deflatedExplicitVRLittleEndian: return "1.2.840.10008.1.2.1.99"
        case .explicitVRBigEndian: return "1.2.840.10008.1.2.2"
        case .rleLossless: return "1.2.840.10008.1.2.5"
        case .jpegBaseline8Bit: return "1.2.840.10008.1.2.4.50"
        case .jpegExtended12Bit: return "1.2.840.10008.1.2.4.51"
        case .jpegLosslessNonHierarchical: return "1.2.840.10008.1.2.4.57"
        case .jpegLosslessNonHierarchicalSV1: return "1.2.840.10008.1.2.4.70"
        case .jpegLSLossless: return "1.2.840.10008.1.2.4.80"
        case .jpegLSNearLossless: return "1.2.840.10008.1.2.4.81"
        case .jpeg2000Lossless: return "1.2.840.10008.1.2.4.90"
        case .jpeg2000: return "1.2.840.10008.1.2.4.91"
        case .jpeg2000MultiComponentLossless: return "1.2.840.10008.1.2.4.92"
        case .jpeg2000MultiComponent: return "1.2.840.10008.1.2.4.93"
        case .unknown(let uid): return uid
        }
    }

    /// I VR sono scritti nel dataset. Falso solo per `implicitVRLittleEndian`, dove il VR va
    /// dedotto dal dizionario dei tag.
    public var isExplicitVR: Bool {
        if case .implicitVRLittleEndian = self { return false }
        return true
    }

    public var isBigEndian: Bool {
        if case .explicitVRBigEndian = self { return true }
        return false
    }

    /// Il dataset è compresso con deflate a partire dal gruppo 0008.
    public var isDeflated: Bool {
        if case .deflatedExplicitVRLittleEndian = self { return true }
        return false
    }

    /// I pixel sono in frammenti incapsulati con lunghezza indefinita, non un blocco unico.
    /// Se è vero servirà un `PixelDecoder` dedicato.
    public var isEncapsulated: Bool {
        switch self {
        case .implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian,
            .deflatedExplicitVRLittleEndian:
            return false
        case .unknown:
            // Prudenza: una sintassi ignota si tratta come compressa e si rifiuta il decoding
            // dei pixel, invece di interpretare byte compressi come campioni.
            return true
        default:
            return true
        }
    }

    /// Gestibile in Swift puro, senza DCMTK: pixel in chiaro, blocco contiguo.
    /// È l'insieme che copre la Fase 1.
    public var isNativelySupported: Bool {
        switch self {
        case .implicitVRLittleEndian, .explicitVRLittleEndian, .explicitVRBigEndian:
            return true
        default:
            return false
        }
    }

    /// Nome leggibile per messaggi d'errore e ispettore dei tag.
    public var displayName: String {
        switch self {
        case .implicitVRLittleEndian: return "Implicit VR Little Endian"
        case .explicitVRLittleEndian: return "Explicit VR Little Endian"
        case .deflatedExplicitVRLittleEndian: return "Deflated Explicit VR Little Endian"
        case .explicitVRBigEndian: return "Explicit VR Big Endian (ritirata)"
        case .rleLossless: return "RLE Lossless"
        case .jpegBaseline8Bit: return "JPEG Baseline 8 bit"
        case .jpegExtended12Bit: return "JPEG Extended 12 bit"
        case .jpegLosslessNonHierarchical: return "JPEG Lossless (processo 14)"
        case .jpegLosslessNonHierarchicalSV1: return "JPEG Lossless SV1"
        case .jpegLSLossless: return "JPEG-LS Lossless"
        case .jpegLSNearLossless: return "JPEG-LS Near-Lossless"
        case .jpeg2000Lossless: return "JPEG 2000 Lossless"
        case .jpeg2000: return "JPEG 2000"
        case .jpeg2000MultiComponentLossless: return "JPEG 2000 multicomponente lossless"
        case .jpeg2000MultiComponent: return "JPEG 2000 multicomponente"
        case .unknown(let uid): return "Sintassi non riconosciuta (\(uid))"
        }
    }
}
