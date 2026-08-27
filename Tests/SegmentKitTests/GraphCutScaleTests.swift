import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// Il taglio minimo alla scala vera, che è l'unica in cui i suoi difetti si vedono.
//
// Le prove in `GraphCutTests` lavorano su fantocci da poche migliaia di voxel: bastano a dire se
// l'algoritmo è **giusto**, non se è **utilizzabile**. Un risolutore che copia i suoi array a
// ogni cammino aumentato passa quelle prove senza battere ciglio e poi impiega un quarto d'ora
// su un dente, e la differenza fra le due cose non si scopre guardando il codice.
//
// Qui il fantoccio ha le dimensioni dichiarate in testa a `GraphCut.swift` — un dente in 15 × 15
// × 25 mm a 0,15 mm, cioè un milione e mezzo di voxel — e la prova è che il taglio ci cada dove
// deve. Il tempo non si misura: una soglia sui secondi fallirebbe sulla macchina di qualcun
// altro senza che nulla sia rotto. Ma il costo resta sorvegliato lo stesso, perché una
// regressione che rendesse il risolutore quadratico farebbe scadere l'intera suite invece di
// aggiungere due secondi.
@Suite("Taglio minimo alla scala vera")
struct GraphCutScaleTests {

    private let columns = 100
    private let rows = 100
    private let slices = 167

    /// Il raggio in voxel della dentina, del legamento e dell'osso attorno.
    private let dentineRadius = 18.0
    private let ligamentRadius = 20.0
    private let boneRadius = 45.0

    /// Un dente cilindrico dentro l'osso, separato dal legamento e con rumore addosso.
    ///
    /// Il legamento è spesso due voxel — 0,3 mm, che è la misura vera — e in densità sta sopra
    /// la soglia che comprende la dentina: nessuna soglia lo separa, ed è esattamente la
    /// situazione per cui questo modulo esiste. Il rumore c'è perché una CBCT pulita non esiste,
    /// e un algoritmo che regge solo sul dato liscio non serve a niente.
    private func makeToothInBone() throws -> Volume {
        let geometry = try VolumeGeometry(
            columnCount: columns, rowCount: rows, sliceCount: slices,
            columnSpacingMM: 0.15, rowSpacingMM: 0.15, sliceSpacingMM: 0.15,
            orientation: .standardAxial, originMM: Vec3(0, 0, 0))

        var samples = [Int16](repeating: 0, count: geometry.voxelCount)
        var state: UInt64 = 42
        func noise() -> Int16 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int16((state >> 50) % 60)
        }

        let centreX = Double(columns) / 2, centreY = Double(rows) / 2
        for k in 0..<slices {
            for j in 0..<rows {
                for i in 0..<columns {
                    let dx = Double(i) - centreX, dy = Double(j) - centreY
                    let radius = (dx * dx + dy * dy).squareRoot()
                    let base: Int16
                    switch radius {
                    case ..<dentineRadius: base = 1800
                    case ..<ligamentRadius: base = 1100
                    case ..<boneRadius: base = 1400
                    default: base = 100
                    }
                    samples[i + j * columns + k * columns * rows] = base + noise()
                }
            }
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    @Test("Un dente in osso a grandezza vera finisce nel legamento")
    func separatesAToothFromTheSurroundingBone() throws {
        let volume = try makeToothInBone()
        let geometry = volume.geometry

        let mask = try GraphCut.segment(
            in: volume,
            objectSeedsMM: [geometry.patientPoint(i: columns / 2, j: rows / 2, k: slices / 2)],
            backgroundSeedsMM: [
                geometry.patientPoint(i: columns / 2 + 32, j: rows / 2, k: slices / 2)
            ],
            densityRange: 800...3000)

        // Il cilindro di dentina conta π · 18² · 167 ≈ 170.000 voxel. Si concede il cinque per
        // cento, che è quanto il rumore e la discretizzazione del cerchio spostano il confine;
        // di più vorrebbe dire che il taglio ha mangiato osso o lasciato indietro dentina.
        let expected = Double.pi * dentineRadius * dentineRadius * Double(slices)
        let claimed = Double(mask.voxelCounts()[1] ?? 0)
        #expect(
            claimed > expected * 0.95 && claimed < expected * 1.05,
            "il taglio ha preso \(Int(claimed)) voxel contro i \(Int(expected)) attesi")

        // Il centro è dentina e ci deve stare; l'osso a metà strada fra legamento e bordo non
        // ci deve stare. Sono le due condizioni che il conteggio da solo non garantisce, perché
        // un taglio spostato può sbagliare da una parte e compensare dall'altra.
        #expect(mask.label(i: columns / 2, j: rows / 2, k: slices / 2) == 1)
        #expect(
            mask.label(i: columns / 2 + 32, j: rows / 2, k: slices / 2) == VolumeMask.background)
    }
}
