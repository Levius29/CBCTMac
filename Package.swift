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
//
// Nessun target dichiara `swiftSettings: [.swiftLanguageMode(.v6)]`. Sarebbe ridondante, perché
// con `swift-tools-version: 6.0` la modalità Swift 6 è già il default ovunque, e non è
// innocuo: quell'API non esiste nel PackageDescription dei Command Line Tools più datati, dove
// il manifest smette di compilare. Ripeterla su ogni target appesantiva anche l'inferenza al
// punto da mandare in timeout il type-check dell'intera espressione `Package(...)`.

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
            ]
        )
    ]
#else
    let appProducts: [Product] = []
    let appTargets: [Target] = []
#endif

// MARK: - Moduli
//
// Estratti in una costante con tipo esplicito, e non scritti dentro `Package(...)`: annotare il
// tipo toglie al compilatore un'inferenza costosa su un array lungo concatenato, che è ciò che
// gli faceva superare il limite di tempo del type-check.

let libraryProducts: [Product] = [
    .library(name: "DICOMCore", targets: ["DICOMCore"]),
    .library(name: "MeasureKit", targets: ["MeasureKit"]),
    .library(name: "MeshKit", targets: ["MeshKit"]),
    .library(name: "VolumeKit", targets: ["VolumeKit"]),
    .library(name: "DentalKit", targets: ["DentalKit"]),
    .library(name: "ImplantKit", targets: ["ImplantKit"]),
]

let moduleTargets: [Target] = [
    .target(name: "DICOMCore"),
    .target(name: "MeasureKit", dependencies: ["DICOMCore"]),
    .target(name: "MeshKit", dependencies: ["DICOMCore"]),
    .target(
        name: "VolumeKit",
        dependencies: ["DICOMCore"],
        resources: [.process("Shaders")]
    ),
    // Curva dell'arcata, panorex e sezioni trasversali. La geometria è Swift puro e si testa
    // ovunque; il solo kernel panoramico è protetto dalla guardia Metal.
    .target(
        name: "DentalKit",
        dependencies: ["DICOMCore", "VolumeKit"],
        resources: [.process("Shaders")]
    ),
    // Nervo alveolare, impianti e analisi di sicurezza. Nessuna dipendenza da Metal:
    // è tutta geometria, e si verifica per intero con `swift test`.
    .target(name: "ImplantKit", dependencies: ["DICOMCore"]),
]

let testTargets: [Target] = [
    .testTarget(name: "DICOMCoreTests", dependencies: ["DICOMCore"]),
    .testTarget(name: "MeasureKitTests", dependencies: ["MeasureKit", "DICOMCore"]),
    .testTarget(name: "MeshKitTests", dependencies: ["MeshKit", "DICOMCore"]),
    .testTarget(name: "VolumeKitTests", dependencies: ["VolumeKit", "DICOMCore"]),
    .testTarget(name: "DentalKitTests", dependencies: ["DentalKit", "DICOMCore", "VolumeKit"]),
    .testTarget(name: "ImplantKitTests", dependencies: ["ImplantKit", "DICOMCore"]),
    // Contratto delle API usate dall'applicazione.
    //
    // L'app non compila su Linux, perché importa SwiftUI, AppKit e Metal. Le sue chiamate verso
    // i moduli condivisi però si possono verificare lo stesso: questo target le ripete con le
    // stesse firme, quindi se compila ogni punto di chiamata dell'app verso i moduli è corretto.
    // Resta fuori solo il codice di piattaforma vero e proprio.
    .testTarget(
        name: "AppContractTests",
        dependencies: [
            "DICOMCore", "MeasureKit", "VolumeKit", "DentalKit", "ImplantKit", "MeshKit",
        ]
    ),
]

// MARK: - Pacchetto

let package = Package(
    name: "CBCTMac",
    platforms: [.macOS(.v14)],
    products: libraryProducts + appProducts,
    targets: moduleTargets + testTargets + appTargets
)
