import DICOMCore
import Foundation
import Testing

@testable import MeshKit

// L'intersezione di una superficie con un piano.
//
// L'algoritmo è tre righe; le prove servono ai **casi degeneri**, che sono il resto. Un vertice
// esattamente sul piano, uno spigolo che vi giace, un triangolo complanare: su una mesh con
// centomila triangoli capitano sempre, e trattati male producono segmenti di lunghezza nulla,
// punti doppi e anelli che non si chiudono.

@Suite("Sezione di una superficie")
struct MeshSlicerTests {

    /// Un cubo di lato `edge` centrato nell'origine, dodici triangoli.
    private func cube(edge: Double) -> Mesh {
        let h = edge / 2
        let v = [
            Vec3(-h, -h, -h), Vec3(h, -h, -h), Vec3(h, h, -h), Vec3(-h, h, -h),
            Vec3(-h, -h, h), Vec3(h, -h, h), Vec3(h, h, h), Vec3(-h, h, h),
        ]
        let faces = [
            (0, 1, 2), (0, 2, 3),  // z = −h
            (4, 6, 5), (4, 7, 6),  // z = +h
            (0, 4, 5), (0, 5, 1),  // y = −h
            (3, 2, 6), (3, 6, 7),  // y = +h
            (0, 3, 7), (0, 7, 4),  // x = −h
            (1, 5, 6), (1, 6, 2),  // x = +h
        ]
        return Mesh(
            verticesMM: v,
            triangles: faces.map { Triangle(a: $0.0, b: $0.1, c: $0.2) },
            name: "cubo")
    }

    // MARK: Il caso ordinario

    @Test("Un cubo tagliato a metà dà un quadrato del perimetro giusto")
    func cubeThroughTheMiddleGivesASquare() {
        let mesh = cube(edge: 10)
        let contour = MeshSlicer.contour(
            of: mesh, planeOriginMM: .zero, planeNormalMM: Vec3(0, 0, 1))

        #expect(!contour.isEmpty)
        // Quattro facce laterali attraversate, due triangoli ciascuna: otto segmenti.
        #expect(contour.segments.count == 8)
        #expect(abs(contour.lengthMM - 40) < 1e-9, "perimetro \(contour.lengthMM) mm")

        // E tutti i punti stanno sul piano.
        for segment in contour.segments {
            #expect(abs(segment.a.z) < 1e-9)
            #expect(abs(segment.b.z) < 1e-9)
        }
    }

    @Test("Un piano che non tocca la superficie non produce nulla")
    func planeOutsideGivesNothing() {
        let contour = MeshSlicer.contour(
            of: cube(edge: 10), planeOriginMM: Vec3(0, 0, 40), planeNormalMM: Vec3(0, 0, 1))
        #expect(contour.isEmpty)
        #expect(contour.loops.isEmpty)
    }

    @Test("Un piano obliquo taglia lo stesso, e i punti ci restano sopra")
    func obliquePlaneStillCuts() {
        let normal = Vec3(1, 1, 1)
        let contour = MeshSlicer.contour(
            of: cube(edge: 10), planeOriginMM: .zero, planeNormalMM: normal)

        #expect(!contour.isEmpty)
        let unit = normal.normalized!
        for segment in contour.segments {
            #expect(abs(segment.a.dot(unit)) < 1e-9)
            #expect(abs(segment.b.dot(unit)) < 1e-9)
        }
    }

    // MARK: I casi degeneri

    @Test("Un piano che passa esattamente per una faccia non produce una macchia")
    func coplanarFaceIsNotEmittedAsAMess() {
        // Il piano coincide con la faccia superiore del cubo. I due triangoli complanari non
        // devono emettere nulla: emetterli darebbe sei segmenti sovrapposti al posto di un
        // contorno, e gli anelli non si chiuderebbero mai.
        let mesh = cube(edge: 10)
        let contour = MeshSlicer.contour(
            of: mesh, planeOriginMM: Vec3(0, 0, 5), planeNormalMM: Vec3(0, 0, 1))

        // Restano gli spigoli delle quattro facce laterali, che sul piano ci giacciono davvero.
        #expect(contour.segments.count == 4, "\(contour.segments.count) segmenti")
        #expect(abs(contour.lengthMM - 40) < 1e-9)
        for segment in contour.segments {
            #expect(segment.a.distance(to: segment.b) > 1e-6, "nessun segmento di lunghezza nulla")
        }
    }

    @Test("Un piano per un solo vertice non emette nulla, non un segmento inventato")
    func singleTouchingVertexEmitsNothing() {
        // Il piano tocca il cubo **solo** nell'angolo (5,5,5): tutti gli altri vertici stanno
        // dalla stessa parte. Un punto non è un contorno.
        //
        // La prima stesura di questa prova chiedeva soltanto che i segmenti non fossero
        // degeneri, e passava anche togliendo il controllo che la rende vera: senza quel
        // controllo il codice interpola due punti dello **stesso** lato e produce un segmento
        // lungo, fuori dal triangolo, perfettamente non degenere. Una prova che accetta un
        // risultato inventato purché non sia nullo non prova niente.
        let mesh = cube(edge: 10)
        let contour = MeshSlicer.contour(
            of: mesh, planeOriginMM: Vec3(5, 5, 5), planeNormalMM: Vec3(1, 1, 1))
        #expect(contour.segments.isEmpty, "\(contour.segments.count) segmenti da un solo punto")
    }

    @Test("Un piano che sfiora uno spigolo emette quello spigolo e nient'altro")
    func touchingEdgeEmitsExactlyThatEdge() {
        // Il piano contiene lo spigolo x = 5, z = 5 e lascia tutto il resto da una parte. Deve
        // uscire quello spigolo, lungo quanto il cubo, e nessun altro segmento.
        let mesh = cube(edge: 10)
        let normal = Vec3(1, 0, 1)
        let contour = MeshSlicer.contour(
            of: mesh, planeOriginMM: Vec3(5, 0, 5), planeNormalMM: normal)

        #expect(!contour.isEmpty)
        #expect(abs(contour.lengthMM - 10) < 1e-9, "lunghezza \(contour.lengthMM) mm")
        for segment in contour.segments {
            #expect(abs(segment.a.x - 5) < 1e-9 && abs(segment.a.z - 5) < 1e-9)
        }
    }

    @Test("Nessun segmento ha lunghezza nulla, a qualunque quota si tagli")
    func noDegenerateSegmentsAtAnyHeight() {
        // Prova a scorrimento: si taglia a cento quote diverse, comprese quelle che cadono
        // esattamente sui vertici. È il modo in cui i casi degeneri si trovano davvero — a mano
        // se ne prova uno e si crede di averli coperti tutti.
        let mesh = cube(edge: 10)
        for step in 0...100 {
            let z = -6 + Double(step) * 0.12
            let contour = MeshSlicer.contour(
                of: mesh, planeOriginMM: Vec3(0, 0, z), planeNormalMM: Vec3(0, 0, 1))
            for segment in contour.segments {
                #expect(
                    segment.a.distance(to: segment.b) > 1e-9,
                    "quota \(z): segmento di lunghezza nulla")
            }
        }
    }

    // MARK: Gli anelli

    @Test("I segmenti si concatenano in un anello solo, chiuso")
    func segmentsChainIntoOneClosedLoop() {
        let contour = MeshSlicer.contour(
            of: cube(edge: 10), planeOriginMM: .zero, planeNormalMM: Vec3(0, 0, 1))

        #expect(contour.loops.count == 1, "\(contour.loops.count) anelli invece di uno")
        let loop = contour.loops[0]
        #expect(loop.count == 9, "otto segmenti chiusi sono nove punti: \(loop.count)")
        #expect(loop.first!.distance(to: loop.last!) < 1e-9, "l'anello deve chiudersi")
    }

    @Test("Due superfici separate danno due anelli, e contarli è l'informazione utile")
    func twoSurfacesGiveTwoLoops() {
        // Sapere che una fetta della scansione dà due anelli invece di uno dice che taglia due
        // denti. È un'informazione che l'elenco sciolto dei segmenti non contiene.
        var mesh = cube(edge: 6)
        let other = cube(edge: 6)
        let offset = mesh.verticesMM.count
        mesh.verticesMM += other.verticesMM.map { $0 + Vec3(20, 0, 0) }
        mesh.triangles += other.triangles.map {
            Triangle(a: $0.a + offset, b: $0.b + offset, c: $0.c + offset)
        }

        let contour = MeshSlicer.contour(
            of: mesh, planeOriginMM: .zero, planeNormalMM: Vec3(0, 0, 1))
        #expect(contour.loops.count == 2, "\(contour.loops.count) anelli")
    }

    @Test("Estremi vicini a cavallo di una cella della griglia si uniscono lo stesso")
    func chainingLooksAtNeighbouringCells() {
        // Su una mesh vera due triangoli adiacenti producono lo stesso punto con qualche bit di
        // differenza, perché l'interpolazione arriva da spigoli diversi. Se la ricerca guardasse
        // la sola cella propria, due estremi a cavallo di un confine finirebbero separati e
        // l'anello si spezzerebbe: un contorno chiuso disegnato come dieci frammenti.
        //
        // I numeri non sono casuali, e non possono esserlo: la cella vale quattro volte la
        // tolleranza e l'unione due, quindi uno scostamento ammesso non basta **mai** a
        // garantire il salto di cella — dipende da dove cadono i punti. Qui si scelgono due
        // estremi che stanno di certo in celle diverse (0,000 19 e 0,000 21, con la cella a
        // 0,000 4 e il confine a 0,000 2) e più vicini della tolleranza d'unione.
        let tolerance = 1e-4
        let segments: [(a: Vec3, b: Vec3)] = [
            (Vec3(0, 0, 0), Vec3(1.9e-4, 0, 0)),
            (Vec3(2.1e-4, 0, 0), Vec3(1, 0, 0)),
        ]
        #expect(segments[0].b.distance(to: segments[1].a) < tolerance * 2, "sotto l'unione")

        let loops = MeshSlicer.chain(segments, toleranceMM: tolerance)
        #expect(loops.count == 1, "\(loops.count) tratti invece di uno")
        // Tre punti e non quattro: concatenando due segmenti l'''estremo condiviso si scrive una
        // volta sola, come in qualunque spezzata.
        #expect(loops.first?.count == 3)
    }

    @Test("L'ordine in cui arrivano i segmenti non cambia gli anelli")
    func chainingIsOrderIndependent() {
        // I triangoli arrivano nell'ordine del file, che non ha nulla a che vedere con la
        // geometria: se la concatenazione dipendesse da quell'ordine, lo stesso contorno
        // risulterebbe spezzato in file diversi.
        let contour = MeshSlicer.contour(
            of: cube(edge: 10), planeOriginMM: .zero, planeNormalMM: Vec3(0, 0, 1))
        let shuffled = contour.segments.shuffled()
        let loops = MeshSlicer.chain(shuffled, toleranceMM: 1e-6)

        #expect(loops.count == 1, "\(loops.count) anelli con i segmenti mescolati")
        #expect(loops[0].count == 9)
    }
}

// MARK: - Fusione

@Suite("Fusione di mesh")
struct MeshMergeTests {

    private func triangle(at offset: Vec3) -> Mesh {
        Mesh(
            verticesMM: [offset, offset + Vec3(1, 0, 0), offset + Vec3(0, 1, 0)],
            triangles: [Triangle(a: 0, b: 1, c: 2)],
            name: "t")
    }

    @Test("I triangoli si rinumerano e restano sui propri vertici")
    func indicesAreRebased() throws {
        let merged = MeshMerge.combined(
            [triangle(at: .zero), triangle(at: Vec3(10, 0, 0))], name: "Piano")

        #expect(merged.verticesMM.count == 6)
        #expect(merged.triangles.count == 2)
        #expect(merged.name == "Piano")

        // Il secondo triangolo punta ai vertici 3, 4, 5 — non ai primi tre. Senza il
        // rinumeramento sarebbero due copie dello stesso triangolo nello stesso posto.
        #expect(merged.triangles[1] == Triangle(a: 3, b: 4, c: 5))
        #expect(merged.verticesMM[3].x == 10)
    }

    @Test("Un indice fuori intervallo si scarta invece di puntare a un altro oggetto")
    func brokenTrianglesAreDropped() {
        let broken = Mesh(
            verticesMM: [.zero, Vec3(1, 0, 0), Vec3(0, 1, 0)],
            triangles: [Triangle(a: 0, b: 1, c: 2), Triangle(a: 0, b: 1, c: 9)],
            name: "rotta")
        let merged = MeshMerge.combined([broken, triangle(at: Vec3(10, 0, 0))], name: "Piano")

        // Sommando lo scostamento, l'indice 9 sarebbe diventato un indice valido dentro il
        // secondo oggetto: un triangolo che attraversa la scena, senza nessun errore.
        #expect(merged.triangles.count == 2)
        #expect(merged.triangles.allSatisfy {
            $0.a < merged.verticesMM.count && $0.b < merged.verticesMM.count
                && $0.c < merged.verticesMM.count
        })
    }

    @Test("Un elenco vuoto dà una mesh vuota, non un errore")
    func emptyListIsEmptyMesh() {
        let merged = MeshMerge.combined([], name: "Vuoto")
        #expect(merged.verticesMM.isEmpty)
        #expect(merged.triangles.isEmpty)
        #expect(merged.name == "Vuoto")
    }
}
