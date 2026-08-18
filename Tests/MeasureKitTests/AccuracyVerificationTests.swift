import DICOMCore
import Foundation
import Testing

@testable import MeasureKit

// La verifica di accuratezza sul fantoccio.
//
// Questa suite è diversa dalle altre: non prova una funzione, prova la **composizione** di tutta
// la catena — matrice DICOM, spaziatura, campionamento, criterio di bordo. È il genere di
// difetto che nessun test di unità intercetta, perché ogni pezzo è corretto rispetto alla propria
// specifica e a sbagliare è il modo in cui si compongono.

@Suite("Verifica di accuratezza")
struct AccuracyVerificationTests {

    // MARK: Il criterio di bordo

    @Test("Il bordo si trova al passaggio del 50 %, sotto la dimensione del voxel")
    func edgeIsFoundAtHalfHeight() throws {
        // Il cubo va da −10 a +10 mm. Su un fantoccio a 0,25 mm il bordo deve risultare a 10 mm
        // con uno scarto molto minore del voxel: è ciò che distingue un'interpolazione al 50 %
        // da un arrotondamento al campione più vicino, che sbaglierebbe di mezzo voxel.
        let volume = try SyntheticVolume.makePhantom()
        let edge = try #require(
            AccuracyVerification.edgeCrossing(
                in: volume, fromMM: .zero, direction: Vec3(1, 0, 0), lengthMM: 20,
                low: SyntheticVolume.corticalBone, high: SyntheticVolume.water))

        #expect(abs(edge.x - 10) < 0.1, "bordo a \(edge.x) mm invece di 10")
        #expect(abs(edge.y) < 1e-9)
    }

    @Test("Senza attraversamento non si restituisce un bordo")
    func noCrossingGivesNothing() throws {
        // Cercando dentro il cubo, in un tratto che non ne esce, non c'è alcun bordo. Restituire
        // un punto qualsiasi qui darebbe misure inventate su ogni ricerca fallita.
        let volume = try SyntheticVolume.makePhantom()
        let none = AccuracyVerification.edgeCrossing(
            in: volume, fromMM: .zero, direction: Vec3(1, 0, 0), lengthMM: 5,
            low: SyntheticVolume.corticalBone, high: SyntheticVolume.water)
        #expect(none == nil)
    }

    @Test("L'estensione si misura dai due bordi, partendo da dentro")
    func extentUsesBothEdges() throws {
        let volume = try SyntheticVolume.makePhantom()
        let width = try #require(
            AccuracyVerification.extent(
                of: volume, throughMM: .zero, direction: Vec3(1, 0, 0),
                insideValue: SyntheticVolume.corticalBone,
                outsideValue: SyntheticVolume.water,
                searchLengthMM: 20))
        // La soglia è due sigma del Contratto 5, non un numero scelto: su un fantoccio binario
        // il contorno vero sta dentro l'ultimo voxel, e il passaggio al 50 % ne risulta spostato
        // in fuori di una frazione di voxel per lato. È il volume parziale, non un difetto — e
        // il modello lo prevede. Una soglia più stretta dell'incertezza dichiarata accuserebbe
        // il codice di sbagliare ciò che il programma stesso dice di non poter sapere.
        let sigma = MeasurementUncertainty.lengthUncertaintyMM(
            context: AcquisitionContext(voxelSpacingMM: volume.geometry.spacingMM))
        #expect(abs(width - 20) <= 2 * sigma, "spigolo \(width) mm, 2σ = \(2 * sigma) mm")
    }

    // MARK: La catena intera

    @Test("Il fantoccio supera la verifica su tutti e tre gli assi")
    func phantomPassesOnEveryAxis() throws {
        // La prova che vale per tutte: se un asse fosse invertito, una spaziatura letta dal tag
        // sbagliato o una conversione di coordinate storta, l'immagine resterebbe plausibile e
        // **questo** numero no.
        let volume = try SyntheticVolume.makePhantom()
        let results = AccuracyVerification.verifyPhantom(volume)

        #expect(results.count == 6, "tre spigoli e tre densità")
        for result in results {
            #expect(result.passed, "\(result.name): \(result.formattedDeviation)")
        }
    }

    @Test("Su un fantoccio anisotropo la verifica regge ancora")
    func anisotropicPhantomStillPasses() throws {
        // La tolleranza è legata al voxel proprio per questo: fissarla a un numero renderebbe la
        // verifica troppo severa su volumi grossolani e troppo indulgente su quelli fini.
        let volume = try SyntheticVolume.makePhantom(
            columns: 200, rows: 200, slices: 100, spacingMM: Vec3(0.3, 0.3, 0.6))
        for result in AccuracyVerification.verifyPhantom(volume) {
            #expect(result.passed, "\(result.name): \(result.formattedDeviation)")
        }
    }

    @Test("Un volume con la spaziatura sbagliata **non** supera la verifica")
    func wrongSpacingIsCaught() throws {
        // È la prova che rende utile tutto il resto: se la verifica passasse comunque, non
        // starebbe verificando niente. Qui il volume dichiara una spaziatura diversa da quella
        // con cui è stato costruito — esattamente ciò che accade leggendo il tag sbagliato — e
        // la misura dello spigolo deve accorgersene.
        let honest = try SyntheticVolume.makePhantom()
        let source = honest.geometry
        let lying = try VolumeGeometry(
            columnCount: source.columnCount,
            rowCount: source.rowCount,
            sliceCount: source.sliceCount,
            columnSpacingMM: source.columnSpacingMM * 1.1,
            rowSpacingMM: source.rowSpacingMM * 1.1,
            sliceSpacingMM: source.sliceSpacingMM,
            orientation: source.orientation,
            originMM: source.originMM)
        let distorted = try Volume(
            geometry: lying, samples: honest.samples,
            rescaleSlope: honest.rescaleSlope, rescaleIntercept: honest.rescaleIntercept)

        let results = AccuracyVerification.verifyPhantom(distorted)
        let edges = results.filter { $0.name.hasPrefix("Spigolo") }
        #expect(!edges.isEmpty)
        #expect(
            edges.contains { !$0.passed },
            "una spaziatura sbagliata del dieci per cento deve far fallire almeno uno spigolo")
    }

    // MARK: Il rapporto

    @Test("Lo scarto si legge col segno e l'unità giusta")
    func deviationIsReadable() {
        let result = VerificationResult(
            name: "prova", expected: 20, measured: 20.037, toleranceMM: 0.25, unit: "mm")
        #expect(result.passed)
        #expect(result.formattedDeviation == "+0,037 mm")

        let failing = VerificationResult(
            name: "prova", expected: 20, measured: 19.5, toleranceMM: 0.25, unit: "mm")
        #expect(!failing.passed)
        #expect(failing.formattedDeviation == "-0,500 mm")
    }
}
