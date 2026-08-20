import DICOMCore
import Foundation
import Testing

@testable import CephKit

// Il profilo del viso, verificato sul fantoccio.
//
// Il fantoccio non ha una faccia, e va benissimo: ha un cubo con la faccia anteriore a dieci
// millimetri esatti dal centro. Un profilo estratto sul piano sagittale mediano deve cadere lì,
// e sopra il cubo — dove c'è solo aria — non deve cadere da nessuna parte. Sono due numeri noti
// e un'assenza nota, che è più di quanto si possa pretendere da una testa vera.

@Suite("Profilo del viso")
struct FaceProfileTests {

    static func phantom() throws -> Volume { try SyntheticVolume.makePhantom() }

    @Test("Il profilo cade sulla faccia anteriore del cubo")
    func theProfileLandsOnTheAnteriorFaceOfTheCube() throws {
        let volume = try Self.phantom()
        let center = volume.geometry.centerMM
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 0, stepMM: 1)

        #expect(!profile.isEmpty)
        // Anteriore significa `y` minore: la faccia del cubo sta dieci millimetri davanti al
        // centro.
        let expectedY = center.y - SyntheticVolume.cubeEdgeMM / 2

        var checked = 0
        for point in profile.pointsMM {
            let height = point.z - center.z
            // Solo dentro il cubo, e lontano dagli spigoli dove il passo verticale campiona il
            // bordo invece della faccia.
            guard abs(height) <= 9 else { continue }
            checked += 1
            #expect(
                abs(point.y - expectedY) < 0.2,
                "a z \(height): y \(point.y), atteso \(expectedY)")
        }
        #expect(checked >= 15)
    }

    @Test("Sopra il cubo, dove c'è solo aria, non esce nessun punto")
    func nothingIsInventedWhereThereIsOnlyAir() throws {
        // È il controllo che conta più di tutti: un estrattore che restituisce sempre un punto
        // disegnerebbe un profilo anche su un volume vuoto, e nessuno se ne accorgerebbe finché
        // non lo si confronta con la faccia.
        let volume = try Self.phantom()
        let center = volume.geometry.centerMM
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 0, stepMM: 1)

        for point in profile.pointsMM {
            let height = point.z - center.z
            // Sopra il cubo, e sopra le lastrine di riferimento, non c'è nulla sul sagittale
            // mediano.
            #expect(height < SyntheticVolume.cubeEdgeMM / 2 + 1)
        }
    }

    @Test("Alla quota delle lastrine il profilo si sposta sul loro bordo")
    func atThePlatesTheProfileMovesToTheirEdge() throws {
        // Una seconda geometria nota, a un'altra quota: se l'estrattore restituisse una costante
        // passerebbe il test del cubo e fallirebbe questo.
        let volume = try Self.phantom()
        let center = volume.geometry.centerMM
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 0, stepMM: 0.5)

        // Le lastrine stanno **ai lati** dell'intercapedine, non al suo centro: a
        // `plateCenterZMM` c'è il vuoto di dieci millimetri che serve a misurarne il passo.
        let plateZ = center.z + SyntheticVolume.plateCenterZMM + SyntheticVolume.plateGapMM / 2
        let expectedY = center.y - SyntheticVolume.plateHalfWidthMM

        let atPlate = try #require(
            profile.pointsMM.min { abs($0.z - plateZ) < abs($1.z - plateZ) })
        #expect(abs(atPlate.z - plateZ) < 0.6)
        #expect(abs(atPlate.y - expectedY) < 0.3, "y \(atPlate.y), atteso \(expectedY)")
        // E non è lo stesso bordo del cubo: sono due millimetri più avanti.
        #expect(abs(atPlate.y - (center.y - SyntheticVolume.cubeEdgeMM / 2)) > 1.5)
    }

    @Test("Una soglia più alta di tutto non trova niente")
    func aThresholdAboveEverythingFindsNothing() throws {
        let volume = try Self.phantom()
        // Il cubo è a 1200 GV e le lastrine pure: sopra i 2900 sul sagittale mediano non c'è
        // nulla, perché lo smalto sta nella sfera a x 18.
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 2900, stepMM: 1)
        #expect(profile.isEmpty)
        #expect(profile.anteriorMostPointMM == nil)
    }

    @Test("Il piano sagittale scelto cambia quel che si trova")
    func theChosenSagittalPlaneChangesWhatIsFound() throws {
        let volume = try Self.phantom()
        let center = volume.geometry.centerMM

        // A x 18 c'è la sfera di smalto, che sul sagittale mediano non c'è.
        let lateral = FaceProfileExtractor.extract(
            from: volume, lateralXMM: center.x + 18, thresholdGV: 2000, stepMM: 0.5)
        #expect(!lateral.isEmpty)

        let median = FaceProfileExtractor.extract(from: volume, thresholdGV: 2000, stepMM: 0.5)
        #expect(median.isEmpty)
        #expect(lateral.lateralXMM == center.x + 18)
    }

    @Test("I punti sono ordinati dall'alto verso il basso")
    func pointsRunFromTopToBottom() throws {
        let profile = FaceProfileExtractor.extract(
            from: try Self.phantom(), thresholdGV: 0, stepMM: 1)
        let heights = profile.pointsMM.map(\.z)
        #expect(zip(heights, heights.dropFirst()).allSatisfy { $0 > $1 })
    }

    @Test("Il punto più avanzato è quello con la y minore")
    func theAnteriorMostPointIsTheOneWithTheSmallestY() throws {
        let volume = try Self.phantom()
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 0, stepMM: 1)
        let anterior = try #require(profile.anteriorMostPointMM)
        #expect(profile.pointsMM.allSatisfy { $0.y >= anterior.y })
        // Sul fantoccio è il bordo delle lastrine, che sporge più della faccia del cubo.
        let center = volume.geometry.centerMM
        #expect(abs(anterior.y - (center.y - SyntheticVolume.plateHalfWidthMM)) < 0.3)
    }

    @Test("Lo scarto di un repere dal profilo si misura, e ha il segno giusto")
    func theOffsetOfALandmarkFromTheProfileIsSigned() throws {
        let volume = try Self.phantom()
        let center = volume.geometry.centerMM
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 0, stepMM: 0.5)
        let faceY = center.y - SyntheticVolume.cubeEdgeMM / 2

        // Un punto esattamente sul profilo: scarto quasi zero.
        let onProfile = Vec3(center.x, faceY, center.z)
        #expect(abs(try #require(profile.anteriorOffsetMM(of: onProfile))) < 0.2)

        // Un punto cinque millimetri più avanti del profilo: positivo, come «davanti alla
        // linea E» è positivo. La stessa convenzione in tutto il modulo, così un segno letto in
        // un posto vale anche nell'altro.
        let ahead = Vec3(center.x, faceY - 5, center.z)
        #expect(try #require(profile.anteriorOffsetMM(of: ahead)) > 4.8)

        // Cinque millimetri più indietro, cioè dentro al cubo: negativo.
        let behind = Vec3(center.x, faceY + 5, center.z)
        #expect(try #require(profile.anteriorOffsetMM(of: behind)) < -4.8)

        // Fuori dall'estensione verticale del profilo non si risponde.
        #expect(profile.anteriorOffsetMM(of: Vec3(center.x, faceY, center.z + 200)) == nil)
    }

    @Test("Il profilo si interpola fra due punti, non salta al più vicino")
    func theProfileInterpolatesBetweenPoints() throws {
        let profile = FaceProfile(
            pointsMM: [Vec3(0, -20, 10), Vec3(0, -30, 0)],
            lateralXMM: 0, thresholdGV: 0, stepMM: 10)

        let middle = try #require(profile.interpolatedPointMM(atSuperiorMM: 5))
        #expect(abs(middle.y - (-25)) < 1e-9)
        #expect(profile.interpolatedPointMM(atSuperiorMM: 11) == nil)
        #expect(profile.interpolatedPointMM(atSuperiorMM: -1) == nil)
    }

    @Test("Il profilo si confronta coi reperi cutanei della cefalometria")
    func theProfileCanBeComparedWithSoftTissueLandmarks() throws {
        // I due tipi parlano lo stesso linguaggio: `CephPlanePoint`. Senza questo, il profilo
        // resterebbe un disegno e i reperi dei numeri, senza modo di controllare gli uni con
        // l'altro.
        let volume = try Self.phantom()
        let profile = FaceProfileExtractor.extract(from: volume, thresholdGV: 0, stepMM: 1)
        let planePoints = profile.planePoints

        #expect(planePoints.count == profile.pointsMM.count)
        for (point, plane) in zip(profile.pointsMM, planePoints) {
            #expect(plane.anteriorMM == -point.y)
            #expect(plane.superiorMM == point.z)
        }
    }
}
