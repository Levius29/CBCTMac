import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

// La prova su un esame vero, che è l'unica che dice se la cosa funziona.
//
// I fantocci servono a sapere se un algoritmo è giusto; non dicono se **regge il dato reale**,
// dove le densità non sono quelle di manuale, il rumore c'è, gli artefatti pure, e il campo
// inquadra quel che il tecnico ha inquadrato invece di quel che farebbe comodo. Un modulo che
// passa venti prove sintetiche e non trova un dente su una CBCT non funziona, e nessuna di
// quelle venti prove lo dice.
//
// L'esame non sta nel repository e non ci deve stare: sono dati di una persona. Il percorso
// arriva dalla variabile d'ambiente `CBCT_DIRECTORY`, e senza quella la prova si salta invece di
// fallire, così su qualunque altra macchina la suite resta verde.
//
//     CBCT_DIRECTORY=/percorso/della/cartella swift test --filter AutomaticSegmentation
@Suite("Segmentazione automatica su esame vero")
struct AutomaticSegmentationOnRealExamTests {

    private static var examDirectory: URL? {
        guard let path = ProcessInfo.processInfo.environment["CBCT_DIRECTORY"] else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    @Test(
        "Trova i denti da sola, senza che nessuno li indichi",
        .enabled(if: AutomaticSegmentationOnRealExamTests.examDirectory != nil))
    func findsTeethWithoutSeeds() throws {
        let directory = try #require(Self.examDirectory)

        let scan = try DICOMScanner.scan(directory: directory, progress: nil)
        let series = scan.patients
            .flatMap(\.studies)
            .flatMap(\.series)
            .max { $0.instances.count < $1.instances.count }
        let chosen = try #require(series, "nessuna serie DICOM nella cartella indicata")

        let loaded = try VolumeBuilder.build(series: chosen)
        let volume = loaded.volume
        let geometry = volume.geometry

        // Nessun dato anagrafico esce di qui: solo la forma del volume.
        print(
            """

            ── ESAME ─────────────────────────────────────────────
            matrice        \(geometry.columnCount) × \(geometry.rowCount) × \(geometry.sliceCount)
            voxel          \(String(format: "%.3f", geometry.columnSpacingMM)) × \
            \(String(format: "%.3f", geometry.rowSpacingMM)) × \
            \(String(format: "%.3f", geometry.sliceSpacingMM)) mm
            densità        \(String(format: "%.0f", volume.densityRange.lowerBound)) … \
            \(String(format: "%.0f", volume.densityRange.upperBound)) GV
            anomalie       \(loaded.geometryIssues.count) geometriche, \
            \(loaded.warnings.count) avvisi
            """)

        let start = Date()
        let result = try AutomaticToothSegmentation.segment(in: volume)
        let elapsed = Date().timeIntervalSince(start)

        print(
            """

            ── SEGMENTAZIONE AUTOMATICA ──────────────────────────
            soglia tessuti \(String(format: "%.0f", result.tissueThresholdGV)) GV
            soglia smalto  \(String(format: "%.0f", result.enamelThresholdGV)) GV
            arcata         \(result.archPointsMM.count) punti
            corone viste   \(result.crownsConsidered)
            denti trovati  \(result.teeth.count)
            tempo          \(String(format: "%.1f", elapsed)) s

            pos  etichetta   volume mm³   smalto mm³   campo
            """)
        for tooth in result.teeth {
            print(
                String(
                    format: "%3d  %8d   %10.1f   %10.1f   %@",
                    tooth.positionAlongArch, Int(tooth.label), tooth.volumeMM3,
                    tooth.crownVolumeMM3,
                    tooth.isTruncatedByFieldOfView ? "tagliato" : "intero"))
        }

        if !result.discarded.isEmpty {
            print("\nscartate \(result.discarded.count) corone:")
            for item in result.discarded {
                print(String(format: "     smalto %7.1f mm³  →  %@", item.crownVolumeMM3, item.reason))
            }
        }

        // Quel che si pretende è modesto e non negoziabile: che abbia trovato qualcosa, che
        // quel qualcosa abbia le dimensioni di un dente, e che i denti siano separati fra loro
        // invece di essere un blocco solo.
        #expect(!result.teeth.isEmpty, "non ha trovato nessun dente")
        // Il limite inferiore vale solo sui denti interi: uno tagliato dal campo è piccolo
        // per costruzione, e pretendere che non lo sia vorrebbe dire pretendere un altro esame.
        // Il limite superiore vale per tutti, perché nessun taglio del campo fa **crescere** un
        // dente: se supera i tremila millimetri cubi si è preso dell'osso, e quello è un difetto
        // in qualunque campo.
        for tooth in result.teeth {
            #expect(
                tooth.volumeMM3 < 3000,
                "posizione \(tooth.positionAlongArch): \(tooth.volumeMM3) mm³, ha preso osso")
            if !tooth.isTruncatedByFieldOfView {
                #expect(
                    tooth.volumeMM3 > 150,
                    "posizione \(tooth.positionAlongArch): \(tooth.volumeMM3) mm³, troppo poco")
            }
        }
        let labels = Set(result.teeth.map(\.label))
        #expect(labels.count == result.teeth.count, "due denti condividono la stessa etichetta")
    }
}
