import Foundation

/// Identificatore di un attributo DICOM, composto da gruppo ed elemento.
public struct DICOMTag: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let group: UInt16
    public let element: UInt16

    public init(group: UInt16, element: UInt16) {
        self.group = group
        self.element = element
    }

    public static func < (lhs: DICOMTag, rhs: DICOMTag) -> Bool {
        if lhs.group != rhs.group {
            return lhs.group < rhs.group
        }
        return lhs.element < rhs.element
    }

    public var description: String {
        String(format: "(%04X,%04X)", Int(group), Int(element))
    }
}

/// Value Representation DICOM.
///
/// Il VR determina sia l'interpretazione dei byte sia la forma dell'header Explicit VR.
public enum VR: String, Sendable {
    case AE
    case AS
    case AT
    case CS
    case DA
    case DS
    case DT
    case FL
    case FD
    case IS
    case LO
    case LT
    case OB
    case OD
    case OF
    case OL
    case OV
    case OW
    case PN
    case SH
    case SL
    case SQ
    case SS
    case ST
    case SV
    case TM
    case UC
    case UI
    case UL
    case UN
    case UR
    case US
    case UT
    case UV

    /// Vero per i VR il cui header esplicito usa due byte riservati e una lunghezza a 32 bit.
    public var usesLongLength: Bool {
        switch self {
        case .OB, .OD, .OF, .OL, .OV, .OW, .SQ, .UC, .UN, .UR, .UT, .SV, .UV:
            return true
        default:
            return false
        }
    }

    /// Vero per i VR rappresentati come testo nel file.
    public var isStringLike: Bool {
        switch self {
        case .AE, .AS, .CS, .DA, .DS, .DT, .IS, .LO, .LT, .PN, .SH, .ST, .TM, .UC,
             .UI, .UR, .UT:
            return true
        default:
            return false
        }
    }
}

/// Tag usati dal progetto e tabella minima per la lettura Implicit VR.
public enum DICOMTags: Sendable {
    public static let fileMetaGroupLength = DICOMTag(group: 0x0002, element: 0x0000)
    public static let mediaStorageSOPClassUID = DICOMTag(group: 0x0002, element: 0x0002)
    /// UID di istanza **nel gruppo meta**. Da non confondere con `sopInstanceUID`, che è
    /// (0008,0018) e vive nel dataset: scriverne uno al posto dell'altro produce un file che
    /// un parser rigoroso rifiuta, ed è giusto che lo rifiuti.
    public static let mediaStorageSOPInstanceUID = DICOMTag(group: 0x0002, element: 0x0003)
    public static let transferSyntaxUID = DICOMTag(group: 0x0002, element: 0x0010)

    public static let studyDate = DICOMTag(group: 0x0008, element: 0x0020)
    public static let sopClassUID = DICOMTag(group: 0x0008, element: 0x0016)
    public static let sopInstanceUID = DICOMTag(group: 0x0008, element: 0x0018)
    public static let modality = DICOMTag(group: 0x0008, element: 0x0060)
    public static let manufacturer = DICOMTag(group: 0x0008, element: 0x0070)
    public static let manufacturerModelName = DICOMTag(group: 0x0008, element: 0x1090)
    public static let studyDescription = DICOMTag(group: 0x0008, element: 0x1030)
    public static let seriesDescription = DICOMTag(group: 0x0008, element: 0x103E)

    public static let patientName = DICOMTag(group: 0x0010, element: 0x0010)
    public static let patientID = DICOMTag(group: 0x0010, element: 0x0020)
    public static let patientBirthDate = DICOMTag(group: 0x0010, element: 0x0030)

    public static let sliceThickness = DICOMTag(group: 0x0018, element: 0x0050)
    public static let kvp = DICOMTag(group: 0x0018, element: 0x0060)
    public static let spacingBetweenSlices = DICOMTag(group: 0x0018, element: 0x0088)

    public static let studyInstanceUID = DICOMTag(group: 0x0020, element: 0x000D)
    public static let seriesInstanceUID = DICOMTag(group: 0x0020, element: 0x000E)
    public static let seriesNumber = DICOMTag(group: 0x0020, element: 0x0011)
    public static let instanceNumber = DICOMTag(group: 0x0020, element: 0x0013)
    public static let imagePositionPatient = DICOMTag(group: 0x0020, element: 0x0032)
    public static let imageOrientationPatient = DICOMTag(group: 0x0020, element: 0x0037)
    public static let frameOfReferenceUID = DICOMTag(group: 0x0020, element: 0x0052)

    public static let samplesPerPixel = DICOMTag(group: 0x0028, element: 0x0002)
    public static let photometricInterpretation = DICOMTag(group: 0x0028, element: 0x0004)
    public static let numberOfFrames = DICOMTag(group: 0x0028, element: 0x0008)
    public static let rows = DICOMTag(group: 0x0028, element: 0x0010)
    public static let columns = DICOMTag(group: 0x0028, element: 0x0011)
    public static let pixelSpacing = DICOMTag(group: 0x0028, element: 0x0030)
    public static let bitsAllocated = DICOMTag(group: 0x0028, element: 0x0100)
    public static let bitsStored = DICOMTag(group: 0x0028, element: 0x0101)
    public static let highBit = DICOMTag(group: 0x0028, element: 0x0102)
    public static let pixelRepresentation = DICOMTag(group: 0x0028, element: 0x0103)
    public static let windowCenter = DICOMTag(group: 0x0028, element: 0x1050)
    public static let windowWidth = DICOMTag(group: 0x0028, element: 0x1051)
    public static let rescaleIntercept = DICOMTag(group: 0x0028, element: 0x1052)
    public static let rescaleSlope = DICOMTag(group: 0x0028, element: 0x1053)
    public static let rescaleType = DICOMTag(group: 0x0028, element: 0x1054)

    public static let pixelData = DICOMTag(group: 0x7FE0, element: 0x0010)
    public static let item = DICOMTag(group: 0xFFFE, element: 0xE000)
    public static let itemDelimitation = DICOMTag(group: 0xFFFE, element: 0xE00D)
    public static let sequenceDelimitation = DICOMTag(group: 0xFFFE, element: 0xE0DD)

    /// Deduce il VR dei soli tag necessari al progetto.
    ///
    /// In Implicit VR un dizionario completo sarebbe molto più ampio. I tag ignoti restano
    /// `UN`, così i loro byte vengono conservati senza inventare un'interpretazione.
    internal static func inferredVR(for tag: DICOMTag) -> VR {
        switch tag {
        case fileMetaGroupLength:
            return .UL
        case mediaStorageSOPClassUID, transferSyntaxUID, sopClassUID, sopInstanceUID,
             studyInstanceUID, seriesInstanceUID, frameOfReferenceUID:
            return .UI
        case modality, photometricInterpretation:
            return .CS
        case manufacturer, manufacturerModelName, studyDescription, seriesDescription,
             patientID, rescaleType:
            return .LO
        case studyDate, patientBirthDate:
            return .DA
        case patientName:
            return .PN
        case seriesNumber, instanceNumber, numberOfFrames:
            return .IS
        case imagePositionPatient, imageOrientationPatient, pixelSpacing, windowCenter,
             windowWidth, rescaleIntercept, rescaleSlope, sliceThickness,
             spacingBetweenSlices, kvp:
            return .DS
        case samplesPerPixel, rows, columns, bitsAllocated, bitsStored, highBit,
             pixelRepresentation:
            return .US
        case pixelData:
            // Per il dataset implicito il progetto tratta sempre PixelData come Other Word.
            return .OW
        default:
            return .UN
        }
    }
}
