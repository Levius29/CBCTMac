import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Il piano di taglio arbitrario.
//
// La proprietà che lo definisce è una sola, e i test la verificano da tre angolazioni: il piano
// **contiene** la linea disegnata ed è **perpendicolare** alla vista da cui la si è disegnata.
// Un piano che contenesse la linea senza essere perpendicolare taglierebbe di sbieco e
// mostrerebbe la struttura più larga di quanto sia — che è l'errore per cui le sezioni
// trasversali della panorex esistono.

@Suite("Piano di taglio arbitrario")
struct FreePlaneTests {

    @Test("Il piano contiene la linea ed è perpendicolare alla vista")
    func planeContainsTheLineAndStandsUpright() throws {
        // Linea disegnata sull'assiale, la cui normale è z.
        let from = Vec3(-5, 2, 3)
        let to = Vec3(7, 9, 3)
        let sourceNormal = Vec3(0, 0, 1)

        let plane = try #require(
            FreePlane.plane(
                fromMM: from, toMM: to, sourceNormalMM: sourceNormal,
                widthMM: 40, heightMM: 40))

        // Contiene: entrambi gli estremi stanno sul piano, cioè a distanza nulla dalla normale.
        let normal = plane.normalMM
        #expect(abs((from - plane.centerMM).dot(normal)) < 1e-9)
        #expect(abs((to - plane.centerMM).dot(normal)) < 1e-9)

        // Perpendicolare: la normale della vista d'origine giace **nel** piano nuovo, cioè è
        // perpendicolare alla sua normale.
        #expect(abs(normal.dot(sourceNormal)) < 1e-9)

        // Il centro è a metà del segmento: è dove si stava guardando.
        #expect(plane.centerMM.distance(to: (from + to) * 0.5) < 1e-9)
    }

    @Test("L'orizzontale del riquadro è la direzione disegnata")
    func rightFollowsTheDrawnDirection() throws {
        let from = Vec3(0, 0, 0)
        let to = Vec3(10, 10, 0)
        let plane = try #require(
            FreePlane.plane(
                fromMM: from, toMM: to, sourceNormalMM: Vec3(0, 0, 1),
                widthMM: 30, heightMM: 30))

        let direction = try #require((to - from).normalized)
        #expect((plane.rightMM - direction).length < 1e-9)
        // E la terna resta ortonormale: un riquadro con assi non perpendicolari deformerebbe
        // ogni misura presa su di esso.
        #expect(abs(plane.rightMM.dot(plane.downMM)) < 1e-9)
        #expect(abs(plane.rightMM.length - 1) < 1e-12)
        #expect(abs(plane.downMM.length - 1) < 1e-12)
    }

    @Test("Una componente fuori piano viene tolta invece di inclinare il taglio")
    func outOfPlaneComponentIsProjectedAway() throws {
        // Lo stesso segmento, una volta pulito e una volta con un residuo lungo la normale.
        let clean = try #require(
            FreePlane.plane(
                fromMM: Vec3(0, 0, 0), toMM: Vec3(10, 0, 0), sourceNormalMM: Vec3(0, 0, 1),
                widthMM: 30, heightMM: 30))
        let dirty = try #require(
            FreePlane.plane(
                fromMM: Vec3(0, 0, 0), toMM: Vec3(10, 0, 4), sourceNormalMM: Vec3(0, 0, 1),
                widthMM: 30, heightMM: 30))

        // La normale del taglio è la stessa: il residuo fuori piano non deve inclinarlo.
        #expect(abs(abs(clean.normalMM.dot(dirty.normalMM)) - 1) < 1e-9)
    }

    @Test("Un segmento troppo corto non produce un piano")
    func shortSegmentsAreRefused() {
        // Sotto il millimetro la direzione è dominata dall'imprecisione del clic, e il piano
        // ruoterebbe di decine di gradi fra due tentativi identici. Meglio non farne nessuno.
        #expect(
            FreePlane.plane(
                fromMM: Vec3(0, 0, 0), toMM: Vec3(0.4, 0.2, 0), sourceNormalMM: Vec3(0, 0, 1),
                widthMM: 30, heightMM: 30) == nil)
        #expect(
            FreePlane.plane(
                fromMM: Vec3(0, 0, 0), toMM: Vec3(0, 0, 0), sourceNormalMM: Vec3(0, 0, 1),
                widthMM: 30, heightMM: 30) == nil)
    }

    @Test("Un segmento lungo la normale della vista non definisce niente")
    func segmentAlongTheNormalIsRefused() {
        // Proiettandolo sul piano d'origine resta il vettore nullo: non c'è nessuna direzione
        // disegnata, e restituire un piano qualunque darebbe una sezione che nessuno ha chiesto.
        #expect(
            FreePlane.plane(
                fromMM: Vec3(0, 0, 0), toMM: Vec3(0, 0, 20), sourceNormalMM: Vec3(0, 0, 1),
                widthMM: 30, heightMM: 30) == nil)
    }

    @Test("Valori non finiti non producono un piano di NaN")
    func nonFiniteInputIsRefused() {
        #expect(
            FreePlane.plane(
                fromMM: Vec3(Double.nan, 0, 0), toMM: Vec3(10, 0, 0),
                sourceNormalMM: Vec3(0, 0, 1), widthMM: 30, heightMM: 30) == nil)
        #expect(
            FreePlane.plane(
                fromMM: .zero, toMM: Vec3(10, 0, 0), sourceNormalMM: .zero,
                widthMM: 30, heightMM: 30) == nil)
    }

    @Test("Il riquadro scelto è quello che somiglia già di più al taglio nuovo")
    func targetIsTheClosestExistingPlane() throws {
        let axial = MPRPlane(
            centerMM: .zero, rightMM: Vec3(-1, 0, 0), downMM: Vec3(0, 1, 0),
            widthMM: 50, heightMM: 50)
        let coronal = MPRPlane(
            centerMM: .zero, rightMM: Vec3(-1, 0, 0), downMM: Vec3(0, 0, -1),
            widthMM: 50, heightMM: 50)
        let sagittal = MPRPlane(
            centerMM: .zero, rightMM: Vec3(0, 1, 0), downMM: Vec3(0, 0, -1),
            widthMM: 50, heightMM: 50)
        let planes = ["assiale": axial, "coronale": coronal, "sagittale": sagittal]

        // Una normale quasi sagittale sceglie il sagittale.
        #expect(FreePlane.closest(to: Vec3(0.98, 0.2, 0), among: planes) == "sagittale")
        // Escludendolo, sceglie il secondo più simile fra i rimanenti.
        let other = FreePlane.closest(
            to: Vec3(0.98, 0.2, 0), among: planes, excluding: ["sagittale"])
        #expect(other == "coronale")
        // Un elenco vuoto non dà nessun riquadro invece di darne uno a caso.
        #expect(FreePlane.closest(to: Vec3(1, 0, 0), among: [String: MPRPlane]()) == nil)
    }
}
