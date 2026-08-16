// swift-tools-version: 6.0
import PackageDescription

// CBCTMac — moduli condivisi.
//
// Tre target, dipendenze solo verso il basso (vedi docs/architecture.md § 2):
//
//   VolumeKit ──┐
//   MeasureKit ─┴── DICOMCore
//
// DICOMCore e MeasureKit sono Swift puro senza dipendenze di piattaforma: niente `simd`,
// niente Metal, niente AppKit. Questo li rende compilabili ed eseguibili anche su Linux,
// così `swift test` gira in CI e in ambienti senza Xcode. La geometria usa i tipi `Vec3` /
// `Mat4` in Double definiti in DICOMCore/Geometry; la conversione a `simd_float4x4` avviene
// solo al confine con Metal, dentro VolumeKit.
//
// VolumeKit contiene codice Metal ed è di fatto Apple-only: tutto il suo contenuto è protetto
// da `#if canImport(Metal)`, quindi su Linux il target compila a vuoto invece di rompere la
// build degli altri.
//
// DCMTK non compare qui. Vedi Sources/DCMTKBridge/README.md: la Fase 1 gestisce in Swift puro
// il DICOM non compresso, che copre la gran parte degli export CBCT, e il decoder è dietro il
// protocollo `PixelDecoder` così DCMTK si innesta più avanti senza toccare altro.

let package = Package(
    name: "CBCTMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "DICOMCore", targets: ["DICOMCore"]),
        .library(name: "MeasureKit", targets: ["MeasureKit"]),
        .library(name: "VolumeKit", targets: ["VolumeKit"]),
        .executable(name: "CBCTMacApp", targets: ["CBCTMacApp"]),
    ],
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
            name: "VolumeKit",
            dependencies: ["DICOMCore"],
            resources: [.process("Shaders")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Applicazione come eseguibile SPM: consente `swift run CBCTMacApp` senza dover
        // generare un progetto Xcode, il che accorcia parecchio il ciclo di prova.
        // Per la distribuzione servira' un vero target app con bundle e Info.plist, da creare
        // in Xcode piu' avanti — vedi README.
        .executableTarget(
            name: "CBCTMacApp",
            dependencies: ["DICOMCore", "MeasureKit", "VolumeKit"],
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
            name: "VolumeKitTests",
            dependencies: ["VolumeKit", "DICOMCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
