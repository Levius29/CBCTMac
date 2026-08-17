import Foundation
import DICOMCore
import Testing
import VolumeKit

@testable import DentalKit

// Navigazione della striscia di sezioni trasversali.
//
// Tutto ciò che si può sbagliare qui è aritmetica di indici, ed è precisamente il genere di cosa
// che dentro una vista SwiftUI nessuno verificherebbe. Le due proprietà che contano: la finestra
// mostra sempre sezioni **vere** e mai celle vuote, e cambiando il passo la selezione resta sul
// dente che si stava guardando invece di saltare a metà arcata.

@Suite("Navigazione delle sezioni trasversali")
struct CrossSectionBrowserTests {

    private func makeCurve() -> ArchCurve {
        ArchCurve(controlPointsMM: [
            Vec3(-25, 10, 5), Vec3(-18, -6, 5), Vec3(0, -14, 5),
            Vec3(18, -6, 5), Vec3(25, 10, 5),
        ])
    }

    private func makeLayout(intervalMM: Double = 1, angle: Double = 0) -> CrossSectionLayout {
        CrossSectionLayout(
            curve: makeCurve(),
            intervalMM: intervalMM,
            widthMM: 30,
            heightMM: 45,
            verticalCentreMM: 5,
            thicknessMM: 1,
            projection: .average,
            angleOffsetRadians: angle)
    }

    private func makeBrowser(intervalMM: Double = 1, visibleCount: Int = 10)
        -> CrossSectionBrowser
    {
        CrossSectionBrowser(
            sections: makeLayout(intervalMM: intervalMM).sections(),
            visibleCount: visibleCount)
    }

    // MARK: Finestra visibile

    @Test("La finestra mostra sempre sezioni vere, anche ai capi")
    func windowNeverShowsEmptyCells() {
        var browser = makeBrowser()
        let expected = min(browser.effectiveVisibleCount, browser.count)

        // Compresi gli estremi e oltre: è quello che produce uno scorrimento continuato.
        for index in [-10, 0, 1, 5, browser.count / 2, browser.count - 1, browser.count + 10] {
            browser.select(index: index)
            let range = browser.visibleRange
            #expect(range.count == expected, "indice \(index): \(range.count) celle")
            #expect(range.lowerBound >= 0)
            #expect(range.upperBound <= browser.count)
            #expect(browser.visibleSections.count == expected)
        }
    }

    @Test("La selezione resta dentro la finestra")
    func selectionStaysVisible() {
        var browser = makeBrowser()
        for index in stride(from: 0, to: browser.count, by: 7) {
            browser.select(index: index)
            #expect(
                browser.visibleRange.contains(browser.selectedIndex),
                "selezione \(browser.selectedIndex) fuori da \(browser.visibleRange)")
        }
    }

    @Test("Con meno sezioni della finestra si mostrano tutte")
    func fewerSectionsThanTheWindow() {
        var browser = CrossSectionBrowser(
            sections: makeLayout(intervalMM: 30).sections(), visibleCount: 10)
        #expect(browser.count < 10)
        #expect(browser.visibleRange.count == browser.count)
        browser.select(index: 0)
        #expect(browser.visibleRange.count == browser.count)
    }

    @Test("Una striscia vuota non manda in errore nulla")
    func emptyBrowserIsSafe() {
        var browser = CrossSectionBrowser()
        #expect(browser.isEmpty)
        #expect(browser.visibleRange.isEmpty)
        #expect(browser.visibleSections.isEmpty)
        #expect(browser.selectedSection == nil)
        browser.select(index: 5)
        browser.step(by: 3)
        browser.scrollWindow(by: -2)
        #expect(browser.selectedIndex == 0)
        #expect(browser.index(nearestToArcLengthMM: 10) == nil)
    }

    // MARK: Ingrandimento

    @Test("Ingrandire riduce quante sezioni ci stanno")
    func zoomReducesTheVisibleCount() {
        var browser = makeBrowser(visibleCount: 12)
        #expect(browser.effectiveVisibleCount == 12)

        browser.zoom = 2
        #expect(browser.effectiveVisibleCount == 6)
        browser.zoom = 4
        #expect(browser.effectiveVisibleCount == 3)
        // Non scende mai sotto una: con zero celle non si mostrerebbe nulla.
        browser.zoom = 8
        #expect(browser.effectiveVisibleCount >= 1)
    }

    @Test("Ingrandire restringe il campo, non stira l'immagine")
    func zoomNarrowsTheFieldOfView() {
        var browser = makeBrowser()
        let base = browser.sectionExtentMM(baseWidthMM: 30, baseHeightMM: 45)
        #expect(abs(base.widthMM - 30) < 1e-12)

        browser.zoom = 3
        let zoomed = browser.sectionExtentMM(baseWidthMM: 30, baseHeightMM: 45)
        // A zoom 3 si vede un terzo di larghezza e un terzo di altezza, alla stessa scala
        // millimetri-per-pixel: stirare renderebbe la barra di scala una bugia.
        #expect(abs(zoomed.widthMM - 10) < 1e-12)
        #expect(abs(zoomed.heightMM - 15) < 1e-12)
    }

    @Test("L'ingrandimento è limitato e ignora i valori assurdi")
    func zoomIsClamped() {
        var browser = makeBrowser()
        browser.zoom = 0.1
        #expect(browser.zoom == CrossSectionBrowser.minimumZoom)
        browser.zoom = 100
        #expect(browser.zoom == CrossSectionBrowser.maximumZoom)
        browser.zoom = .nan
        #expect(browser.zoom == CrossSectionBrowser.minimumZoom)
    }

    // MARK: Scorrimento

    @Test("Scorrere la finestra non sposta il mirino di un'altra vista")
    func scrollingTheWindowIsDistinctFromStepping() {
        var browser = makeBrowser()
        browser.select(index: browser.count / 2)
        let selectedArc = browser.selectedSection?.arcLengthMM

        browser.step(by: 3)
        #expect(browser.selectedSection?.arcLengthMM != selectedArc, "step sposta la selezione")

        // `scrollWindow` cambia cosa si vede. Che sposti anche la selezione è una conseguenza
        // dell'averla come unico stato, ma la finestra deve effettivamente scorrere.
        let before = browser.visibleRange.lowerBound
        browser.scrollWindow(by: 5)
        #expect(browser.visibleRange.lowerBound == before + 5)
    }

    @Test("Lo scorrimento si arresta ai capi senza accumulare debito")
    func scrollingStopsAtTheEnds() {
        var browser = makeBrowser()
        for _ in 0..<50 { browser.scrollWindow(by: 20) }
        let atEnd = browser.visibleRange
        #expect(atEnd.upperBound == browser.count)

        // Tornare indietro di poco deve rispondere subito, non «riavvolgere» i venti passi
        // sprecati: è la stessa disciplina della finestra del panorex.
        browser.scrollWindow(by: -3)
        #expect(browser.visibleRange.lowerBound == atEnd.lowerBound - 3)
    }

    // MARK: Posizione lungo l'arcata

    @Test("La sezione più vicina a una lunghezza d'arco è davvero la più vicina")
    func nearestSectionIsTrulyNearest() {
        let browser = makeBrowser()
        let total = browser.sections.last?.arcLengthMM ?? 0

        for fraction in stride(from: 0.0, through: 1.0, by: 0.05) {
            let target = total * fraction
            guard let index = browser.index(nearestToArcLengthMM: target) else {
                Issue.record("nessuna sezione")
                return
            }
            // Confronto per forza bruta con tutte le altre: è il modo di verificare un «più
            // vicino» senza riscrivere lo stesso calcolo nel test.
            let chosen = abs(browser.sections[index].arcLengthMM - target)
            for section in browser.sections {
                #expect(abs(section.arcLengthMM - target) >= chosen - 1e-9)
            }
        }
    }

    @Test("Cambiando il passo la selezione resta sul dente, non sull'indice")
    func changingTheIntervalKeepsThePosition() {
        var browser = makeBrowser(intervalMM: 1)
        browser.select(index: 20)
        guard let arcBefore = browser.selectedSection?.arcLengthMM else {
            Issue.record("nessuna selezione")
            return
        }

        // Dimezzando il passo gli indici raddoppiano: conservare l'indice farebbe saltare la
        // selezione a metà arcata, ed è l'errore che questo test esiste per impedire.
        browser.replaceSections(makeLayout(intervalMM: 0.5).sections())
        guard let arcAfter = browser.selectedSection?.arcLengthMM else {
            Issue.record("nessuna selezione")
            return
        }

        #expect(abs(arcAfter - arcBefore) <= 0.5, "da \(arcBefore) mm a \(arcAfter) mm")
        #expect(browser.selectedIndex != 20, "l'indice deve essere cambiato, la posizione no")
    }

    // MARK: Inclinazione del taglio

    @Test("Senza inclinazione la sezione è perpendicolare alla curva")
    func zeroAngleIsPerpendicular() {
        let sections = makeLayout(angle: 0).sections()
        let samples = makeCurve().resampled(spacingMM: 1)
        guard let section = sections.dropFirst(5).first,
            let sample = samples.dropFirst(5).first
        else {
            Issue.record("sezioni mancanti")
            return
        }
        // La normale del piano è la tangente alla curva: è la definizione di sezione trasversale.
        #expect(section.plane.normalMM.isApproximatelyEqual(to: sample.tangent, tolerance: 1e-6))
    }

    @Test("L'inclinazione ruota il taglio dell'angolo richiesto, restando verticale")
    func angleOffsetTiltsTheCut() {
        let straight = makeLayout(angle: 0).sections()
        let up = makeCurve().upAxis

        for degrees in [10.0, 30.0, -25.0] {
            let tilted = makeLayout(angle: degrees * .pi / 180).sections()
            guard let a = straight.dropFirst(5).first, let b = tilted.dropFirst(5).first else {
                Issue.record("sezioni mancanti")
                return
            }

            let cosine = min(max(a.plane.rightMM.dot(b.plane.rightMM), -1), 1)
            let measured = Foundation.acos(cosine) * 180 / .pi
            #expect(abs(measured - abs(degrees)) < 1e-6, "\(degrees)°: misurati \(measured)°")

            // Il basso resta il basso: è ciò che rende confrontabili due sezioni prese con
            // angoli diversi. Se si inclinasse anche la verticale, un'altezza misurata su una
            // non sarebbe più la stessa grandezza misurata sull'altra.
            #expect(b.plane.downMM.isApproximatelyEqual(to: up * -1, tolerance: 1e-9))
            #expect(abs(b.plane.rightMM.dot(up)) < 1e-9, "l'asse orizzontale resta orizzontale")
        }
    }

    @Test("Un angolo non finito vale zero")
    func nonFiniteAngleIsIgnored() {
        #expect(makeLayout(angle: .nan).angleOffsetRadians == 0)
        #expect(makeLayout(angle: .infinity).angleOffsetRadians == 0)
    }
}
