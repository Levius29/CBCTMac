// swift-tools-version: 6.0
import PackageDescription

// CBCTMac — moduli condivisi.
//
// Dipendenze solo verso il basso (vedi docs/architecture.md § 2):
//
//   MeasureKit ──┐
//   MeshKit    ──┼── DICOMCore
//   ImplantKit ──┤
//   VolumeKit  ──┘
//   DentalKit  ──── VolumeKit ── DICOMCore
//
// DICOMCore, MeasureKit, MeshKit e ImplantKit sono Swift puro senza dipendenze di piattaforma:
// niente `simd`, niente Metal, niente AppKit. La geometria usa i tipi `Vec3` e `Transform3D` in
// Double definiti in DICOMCore/Geometry; la discesa a `simd_float4x4` avviene solo al confine
// con Metal, dentro VolumeKit.
//
// In VolumeKit e DentalKit i soli file dei renderer sono protetti da `#if canImport(Metal)`,
// mentre la geometria resta portabile. Il risultato è che `swift test` gira anche su Linux e
// copre tutta la matematica che conta.
//
// DCMTK non compare qui: la Fase 1 gestisce in Swift puro il DICOM non compresso, che copre la
// gran parte degli export CBCT, e il decoder sta dietro il protocollo `PixelDecoder` così
// DCMTK si innesta più avanti senza toccare altro.

// MARK: - Applicazione, solo su macOS
//
// L'applicazione importa Metal, AppKit e SwiftUI, quindi esiste soltanto su macOS. Renderla
// condizionale non è un espediente: è ciò che permette di eseguire `swift test` su Linux e in
// CI, dove i moduli condivisi compilano e si verificano per intero mentre l'app semplicemente
// non fa parte del pacchetto. Senza, un solo `import Metal` fa fallire l'intera suite.

#if os(macOS)
    let appProducts: [Product] = [
        .executable(name: "CBCTMacApp", targets: ["CBCTMacApp"])
    ]
    let appTargets: [Target] = [
        // Eseguibile SPM: consente `swift run CBCTMacApp` senza generare un progetto Xcode.
        // Per la distribuzione servirà un vero target app con bundle e Info.plist.
        .executableTarget(
            name: "CBCTMacApp",
            dependencies: [
                "DICOMCore", "MeasureKit", "VolumeKit", "DentalKit", "ImplantKit", "MeshKit",
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
#else
    let appProducts: [Product] = []
    let appTargets: [Target] = []
#endif

// MARK: - Pacchetto

let package = Package(
    name: "CBCTMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DICOMCore", targets: ["DICOMCore"]),
        .library(name: "MeasureKit", targets: ["MeasureKit"]),
        .library(name: "MeshKit", targets: ["MeshKit"]),
        .library(name: "VolumeKit", targets: ["VolumeKit"]),
        .library(name: "DentalKit", targets: ["DentalKit"]),
        .library(name: "ImplantKit", targets: ["ImplantKit"]),
    ] + appProducts,
    targets: [
        .target(
            name: "DICOMCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MeasureKit",
            dependencies: ["DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "MeshKit",
            dependencies: ["DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VolumeKit",
            dependencies: ["DICOMCore"],
            resources: [.process("Shaders")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Curva dell'arcata, panorex e sezioni trasversali. La geometria è Swift puro e si
        // testa ovunque; il solo kernel panoramico è protetto dalla guardia Metal.
        .target(
            name: "DentalKit",
            dependencies: ["DICOMCore", "VolumeKit"],
            resources: [.process("Shaders")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Nervo alveolare, impianti e analisi di sicurezza. Nessuna dipendenza da Metal:
        // è tutta geometria, e si verifica per intero con `swift test`.
        .target(
            name: "ImplantKit",
            dependencies: ["DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DICOMCoreTests",
            dependencies: ["DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeasureKitTests",
            dependencies: ["MeasureKit", "DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeshKitTests",
            dependencies: ["MeshKit", "DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VolumeKitTests",
            dependencies: ["VolumeKit", "DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "DentalKitTests",
            dependencies: ["DentalKit", "DICOMCore", "VolumeKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ImplantKitTests",
            dependencies: ["ImplantKit", "DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ] + appTargets
)
