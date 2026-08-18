import DICOMCore
import Foundation
import Testing

@testable import MeshKit

// Dalla CBCT alla scansione intraorale, e ritorno.
//
// Questa suite prova la **catena intera**, non un pezzo: estrazione della superficie dai voxel,
// allineamento grezzo da coppie di punti, affinamento ICP, e lo scarto che ne esce. È il tipo di
// prova che nessun test di unità sostituisce, perché ogni pezzo può essere corretto e la loro
// composizione no — un asse scoperto nella nuvola bersaglio, per esempio, fa convergere l'ICP con
// uno scarto piccolo e convincente su una superficie libera di scivolare.

@Suite("Registrazione della scansione")
struct ScanRegistrationTests {

    private func phantom() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 160, rows: 160, slices: 160, spacingMM: Vec3(0.4, 0.4, 0.4))
    }

    /// La superficie del cubo del fantoccio: è la struttura di geometria nota su cui misurare.
    private func cubeSurface(_ volume: Volume) -> [Vec3] {
        VolumeSurface.points(
            in: volume,
            extraction: SurfaceExtraction(
                // ±12 e non di più: il fantoccio ha anche due piattelli corticali, il più vicino
                // dei quali comincia a z = −13. Allargando la regione l'estrazione li trova — ed
                // è giusto che li trovi, sono struttura vera — ma allora la nuvola non descrive
                // più il solo cubo, e la prova sotto verificherebbe un'altra cosa.
                minMM: Vec3(-12, -12, -12),
                maxMM: Vec3(12, 12, 12),
                // A metà fra acqua e osso corticale: è il passaggio al 50 % del contorno del cubo.
                thresholdGV: 600,
                raySpacingMM: 1.2,
                stepMM: 0.1,
                maximumPoints: 40_000))
    }

    // MARK: L'estrazione

    @Test("I punti estratti stanno sulle facce del cubo, non nella zona di transizione")
    func extractedPointsLieOnTheSurface() throws {
        let volume = try phantom()
        let points = cubeSurface(volume)
        #expect(points.count > 500, "solo \(points.count) punti")

        // Ogni punto deve avere **almeno una** coordinata a ±10 mm: è una faccia del cubo.
        // Una soglia grezza darebbe punti sparsi nei due o tre voxel di transizione, e qui si
        // pretende il sub-voxel.
        for point in points {
            let onFace = [point.x, point.y, point.z].contains { abs(abs($0) - 10) < 0.25 }
            #expect(onFace, "punto fuori dalle facce: \(point)")
        }
    }

    @Test("La posizione non dipende dal passo di ricerca: è l'interpolazione a decidere")
    func crossingIsInterpolatedNotSnapped() throws {
        // Prova isolante, e formulata su ciò che l'interpolazione **può** garantire.
        //
        // Non l'accuratezza assoluta: quella la limita il voxel, e su un fantoccio binario a
        // 0,4 mm il passaggio al 50 % cade circa due decimi fuori dalla faccia vera — è il volume
        // parziale, ed è la stessa quantità che il Contratto 5 dichiara. Ciò che l'interpolazione
        // garantisce è che il risultato **non dipenda dal passo con cui lo si cerca**: cinque
        // volte più fitto deve dare lo stesso punto.
        //
        // Senza questa prova l'interpolazione non era protetta da nulla — sostituendola col
        // campione precedente, tutte le altre prove continuavano a passare.
        let volume = try phantom()

        func facePoints(step: Double) -> [Double] {
            VolumeSurface.points(
                in: volume,
                extraction: SurfaceExtraction(
                    minMM: Vec3(-12, -1, -1), maxMM: Vec3(12, 1, 1),
                    thresholdGV: 600, raySpacingMM: 1.0, stepMM: step, maximumPoints: 5_000))
                .filter { abs(abs($0.x) - 10) < 0.8 }
                .map(\.x)
                .sorted()
        }

        // Anche un passo assurdo dà lo stesso risultato, perché il codice lo limita a mezzo
        // voxel: l'interpolazione lineare ritrova il passaggio esatto solo se i due campioni
        // stanno sulla **stessa rampa**, e su un volume trilineare la rampa è lunga un voxel.
        // Senza quel limite, chiedere un passo grossolano per andare più veloce darebbe una
        // nuvola più rada e **spostata**, senza che nulla lo dichiari.
        let coarse = facePoints(step: 2.0)
        let fine = facePoints(step: 0.05)
        #expect(coarse.count > 4, "solo \(coarse.count) punti")
        #expect(coarse.count == fine.count, "il passo non deve cambiare quanti bordi si trovano")

        for (a, b) in zip(coarse, fine) {
            #expect(
                abs(a - b) < 0.02,
                "col passo grossolano il bordo cade a \(a), con quello fine a \(b)")
        }
    }

    @Test("Tutte e sei le facce sono rappresentate")
    func everyFaceIsCovered() throws {
        // È la prova contro il difetto più insidioso: percorrendo i raggi lungo un asse solo, le
        // due facce parallele a quell'asse non producono alcun punto. L'ICP converge lo stesso,
        // con uno scarto piccolo, e la superficie resta libera di scivolare nella direzione
        // scoperta — un errore che non si vede né nel numero né nell'immagine.
        let volume = try phantom()
        let points = cubeSurface(volume)

        for axis in 0..<3 {
            for sign in [-1.0, 1.0] {
                let onThisFace = points.filter { point in
                    let value = axis == 0 ? point.x : (axis == 1 ? point.y : point.z)
                    return abs(value - sign * 10) < 0.25
                }
                #expect(
                    onThisFace.count > 40,
                    "asse \(axis) verso \(sign): solo \(onThisFace.count) punti")
            }
        }
    }

    @Test("Fuori dalla regione non si estrae nulla, e una regione degenere non produce punti")
    func emptyRegionsGiveNothing() throws {
        let volume = try phantom()
        let outside = VolumeSurface.points(
            in: volume,
            extraction: SurfaceExtraction(
                minMM: Vec3(40, 40, 40), maxMM: Vec3(45, 45, 45), thresholdGV: 600))
        #expect(outside.isEmpty)

        let degenerate = VolumeSurface.points(
            in: volume,
            extraction: SurfaceExtraction(
                minMM: Vec3(0, 0, 0), maxMM: Vec3(0, 5, 5), thresholdGV: 600))
        #expect(degenerate.isEmpty)
    }

    // MARK: La catena intera

    @Test("Una scansione spostata di una trasformazione nota torna al suo posto")
    func registrationRecoversAKnownTransform() throws {
        // La prova che vale per tutte. Si prende la superficie vera del cubo, la si sposta di una
        // rototraslazione **nota**, e si chiede alla registrazione di ritrovarla. Se la catena
        // sbaglia da qualche parte — un verso, un ordine di composizione, un asse — il cubo non
        // torna al suo posto e lo scarto lo dice.
        let volume = try phantom()
        let target = cubeSurface(volume)
        #expect(target.count > 500)

        let rotation = try #require(
            Transform3D.rotation(axis: Vec3(0.3, 0.8, 0.5), angle: 0.14))
        let displacement = Transform3D.translation(Vec3(3.5, -2.0, 1.5))

        // La «scansione»: gli stessi punti, portati altrove. Senza triangoli, perché la
        // registrazione lavora sui vertici — e usarne una vera qui aggiungerebbe un formato di
        // file fra ciò che si prova e ciò che si vuole provare.
        let displaced = target.map { displacement.apply(toPoint: rotation.apply(toPoint: $0)) }
        let scan = Mesh(verticesMM: displaced, triangles: [], name: "scansione")

        // Quattro coppie non complanari: tre lascerebbero una rotazione libera attorno alla retta
        // che li contiene se cadessero allineati, e su un cubo è facile che accada.
        let landmarkIndices = [0, target.count / 4, target.count / 2, target.count * 3 / 4]
        let landmarks = landmarkIndices.map {
            LandmarkPair(scanMM: displaced[$0], volumeMM: target[$0])
        }

        let outcome = try ScanRegistration.register(
            scan: scan, landmarks: landmarks, targetPoints: target)

        #expect(outcome.landmarkRMSMM < 0.01, "le coppie sono esatte: RMS \(outcome.landmarkRMSMM)")
        #expect(outcome.surfaceRMSMM < 0.1, "RMS di superficie \(outcome.surfaceRMSMM) mm")
        #expect(outcome.quality == .good)

        // E il controllo diretto: i vertici riportati indietro coincidono con gli originali.
        let restored = displaced.map { outcome.transform.apply(toPoint: $0) }
        for (index, point) in restored.enumerated() {
            #expect(point.distance(to: target[index]) < 0.15, "vertice \(index)")
        }
    }

    @Test("Con meno di tre coppie non si registra")
    func tooFewLandmarksAreRejected() throws {
        let volume = try phantom()
        let target = cubeSurface(volume)
        let scan = Mesh(verticesMM: target, triangles: [], name: "s")

        #expect(throws: RegistrationError.self) {
            _ = try ScanRegistration.register(
                scan: scan,
                landmarks: [LandmarkPair(scanMM: .zero, volumeMM: .zero)],
                targetPoints: target)
        }
    }

    // MARK: Il giudizio

    @Test("La qualità si legge dalle soglie dichiarate, non a occhio")
    func qualityFollowsTheDeclaredThresholds() {
        func outcome(rms: Double) -> ScanRegistrationOutcome {
            ScanRegistrationOutcome(
                transform: .identity, landmarkRMSMM: 0, surfaceRMSMM: rms,
                surfaceMaxMM: rms * 3, surfacePointCount: 1000, converged: true)
        }
        #expect(outcome(rms: 0.18).quality == .good)
        #expect(outcome(rms: 0.42).quality == .acceptable)
        #expect(outcome(rms: 0.80).quality == .poor)
    }

    @Test("Lo scarto punto per punto trova il settore allineato male")
    func deviationsExposeALocalMisalignment() throws {
        // Un RMS accettabile può nascondere un settore fuori posto, ed è precisamente il settore
        // in cui si sta per mettere l'impianto. Qui metà dei vertici è spostata di due millimetri:
        // lo scarto complessivo resterebbe modesto, quello punto per punto no.
        let volume = try phantom()
        let target = cubeSurface(volume)
        var vertices = target
        for index in 0..<(vertices.count / 2) {
            vertices[index] = vertices[index] + Vec3(2, 0, 0)
        }
        let scan = Mesh(verticesMM: vertices, triangles: [], name: "s")

        let deviations = ScanRegistration.deviations(
            of: scan, transformedBy: .identity, against: target)
        #expect(deviations.count == vertices.count)

        let moved = deviations[0..<(vertices.count / 2)].max() ?? 0
        let still = deviations[(vertices.count / 2)...].max() ?? 0
        #expect(moved > 0.5, "il settore spostato deve emergere: \(moved) mm")
        #expect(still < 0.05, "il resto deve restare a posto: \(still) mm")
    }
}
