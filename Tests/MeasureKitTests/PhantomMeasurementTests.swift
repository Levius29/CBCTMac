import DICOMCore
import Testing

@testable import MeasureKit

// Misure sul fantoccio sintetico.
//
// È il test che conta più di tutti gli altri messi insieme. Il fantoccio ha dimensioni e
// densità note per costruzione, quindi qui la verità non è un'opinione: se uno spigolo da
// 20,00 mm non misura 20,00 mm, la catena delle coordinate è rotta da qualche parte.
//
// Gli stessi valori sono già stati verificati indipendentemente dallo script Python
// `Tools/PhantomGenerator/verify_phantom.py` su una serie DICOM equivalente. Due
// implementazioni separate che concordano sono una garanzia ben più solida di una sola che
// concorda con se stessa.

@Suite("Misure sul fantoccio")
struct PhantomMeasurementTests {

    /// Volume di prova: 60 × 60 × 60 mm a 0,5 mm. Contiene tutte le strutture, comprese le
    /// lastrine a −20 mm, e si genera abbastanza in fretta da stare in una suite di test.
    private func makeVolume() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 120, rows: 120, slices: 120, spacingMM: Vec3(0.5, 0.5, 0.5))
    }

    // MARK: Densità

    @Test("La densità al centro del cubo è esattamente quella corticale")
    func cubeDensity() throws {
        let volume = try makeVolume()
        let value = try #require(volume.densityValue(atPatient: .zero))
        #expect(abs(value - SyntheticVolume.corticalBone) < 0.5)
    }

    @Test("Ogni sfera restituisce la propria densità")
    func sphereDensities() throws {
        let volume = try makeVolume()
        for sphere in SyntheticVolume.spheres {
            let value = try #require(volume.densityValue(atPatient: sphere.centerMM))
            #expect(
                abs(value - sphere.density) < 0.5,
                "Sfera Ø\(sphere.diameterMM) mm: atteso \(sphere.density), letto \(value)")
        }
    }

    @Test("Fuori dalle strutture c'è aria")
    func airOutside() throws {
        let volume = try makeVolume()
        let value = try #require(volume.densityValue(atPatient: Vec3(0, 0, 26)))
        #expect(abs(value - SyntheticVolume.air) < 0.5)
    }

    // MARK: Misure lineari

    @Test("Lo spigolo del cubo misura 20,00 mm")
    func cubeEdge() throws {
        // Nessun volume: gli spigoli sono definiti analiticamente, quindi la misura fra due
        // vertici opposti non dipende dal campionamento e deve tornare al millesimo.
        let half = SyntheticVolume.cubeEdgeMM / 2

        // Gli spigoli sono definiti analiticamente, quindi la misura fra due vertici opposti
        // deve tornare al millesimo: qui non c'è campionamento di mezzo.
        let start = Vec3(-half, 0, 0)
        let end = Vec3(half, 0, 0)
        let measurement = DistanceMeasurement(startMM: start, endMM: end)
        #expect(abs(measurement.lengthMM - 20.0) < 1e-9)
        #expect(measurement.formattedValue == "20.00 mm")
    }

    @Test("Il cubo campionato ha il bordo dove lo si attende, entro un voxel")
    func cubeEdgeBySampling() throws {
        let volume = try makeVolume()
        let half = SyntheticVolume.cubeEdgeMM / 2
        let spacing = volume.geometry.spacingMM.x

        // Appena dentro: corticale. Appena fuori: aria. La transizione deve cadere entro un
        // voxel dal bordo teorico, altrimenti la geometria è traslata.
        let inside = try #require(volume.densityValue(atPatient: Vec3(half - spacing, 0, 0)))
        let outside = try #require(volume.densityValue(atPatient: Vec3(half + spacing, 0, 0)))
        #expect(abs(inside - SyntheticVolume.corticalBone) < 0.5)
        #expect(abs(outside - SyntheticVolume.air) < 0.5)
    }

    @Test("L'angolo fra due spigoli del cubo è retto")
    func cubeAngle() throws {
        let half = SyntheticVolume.cubeEdgeMM / 2
        let measurement = AngleMeasurement(
            vertexMM: Vec3(-half, -half, 0),
            firstArmMM: Vec3(half, -half, 0),
            secondArmMM: Vec3(-half, half, 0))
        let degrees = try #require(measurement.angleDegrees)
        #expect(abs(degrees - 90.0) < 1e-9)
    }

    // MARK: Statistiche ROI

    @Test("Una ROI sferica dentro il cubo legge la densità corticale senza dispersione")
    func sphereROIInCube() throws {
        let volume = try makeVolume()
        let roi = SphereROI(centerMM: .zero, radiusMM: 5.0)
        let stats = try ROISampler.statistics(for: roi, in: volume)

        #expect(stats.voxelCount > 1000)
        #expect(abs(stats.mean - SyntheticVolume.corticalBone) < 0.5)
        // Il cubo è omogeneo: la deviazione standard deve essere nulla. Se non lo è, il
        // campionamento sta uscendo dalla struttura o interpolando.
        #expect(stats.standardDeviation < 0.5)
        #expect(abs(stats.minimum - SyntheticVolume.corticalBone) < 0.5)
        #expect(abs(stats.maximum - SyntheticVolume.corticalBone) < 0.5)
    }

    @Test("Una ROI nella sfera di smalto legge il valore dello smalto")
    func sphereROIInEnamel() throws {
        let volume = try makeVolume()
        // Sfera Ø6 mm a (18, −10, 0): il raggio della ROI resta ben dentro.
        let roi = SphereROI(centerMM: Vec3(18, -10, 0), radiusMM: 1.5)
        let stats = try ROISampler.statistics(for: roi, in: volume)
        #expect(abs(stats.mean - SyntheticVolume.enamel) < 0.5)
    }

    @Test("Le statistiche portano l'unità GV, mai HU")
    func statisticsUseGreyValue() throws {
        let volume = try makeVolume()
        let roi = SphereROI(centerMM: .zero, radiusMM: 3.0)
        let stats = try ROISampler.statistics(for: roi, in: volume)

        #expect(stats.unit == .greyValue)
        #expect(stats.unit.symbol == "GV")
        #expect(stats.summary.contains("GV"))
        #expect(!stats.summary.contains("HU"))
    }

    @Test("Il volume campionato corrisponde al conteggio dei voxel")
    func sampledVolumeMatchesVoxelCount() throws {
        let volume = try makeVolume()
        let roi = SphereROI(centerMM: .zero, radiusMM: 4.0)
        let stats = try ROISampler.statistics(for: roi, in: volume)

        let spacing = volume.geometry.spacingMM
        let voxelVolume = spacing.x * spacing.y * spacing.z
        #expect(abs(stats.sampledVolumeMM3 - Double(stats.voxelCount) * voxelVolume) < 1e-6)

        // Il volume campionato si avvicina a quello analitico, senza coincidere: una sfera
        // approssimata a voxel non è una sfera. Uno scarto entro il 10% è quanto ci si aspetta
        // a questa risoluzione, e pretendere di più sarebbe pretendere l'impossibile.
        let analytic = roi.volumeMM3
        #expect(abs(stats.sampledVolumeMM3 - analytic) / analytic < 0.10)
    }

    @Test("Una ROI fuori dal volume non produce statistiche")
    func roiOutsideVolume() throws {
        let volume = try makeVolume()
        let roi = SphereROI(centerMM: Vec3(500, 500, 500), radiusMM: 2.0)
        #expect(throws: ROISamplingError.self) {
            _ = try ROISampler.statistics(for: roi, in: volume)
        }
    }

    // MARK: Profilo

    @Test("Il profilo attraverso il cubo mostra le due transizioni")
    func profileAcrossCube() throws {
        let volume = try makeVolume()
        // Lungo Y e non lungo X: sull'asse X a ±18 mm ci sono le sfere, e il profilo
        // partirebbe dentro la spongiosa invece che in aria.
        let line = ProfileLine(
            startMM: Vec3(0, -25, 0), endMM: Vec3(0, 25, 0), sampleCount: 200)
        let samples = ROISampler.profile(for: line, in: volume)

        #expect(samples.count > 100)
        // Agli estremi aria, al centro corticale.
        #expect(samples.first!.value < SyntheticVolume.air + 100)
        #expect(samples.last!.value < SyntheticVolume.air + 100)
        let middle = samples[samples.count / 2]
        #expect(abs(middle.value - SyntheticVolume.corticalBone) < 50)
    }
}
