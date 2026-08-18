import DICOMCore
import Foundation
import Testing

@testable import StudyKit

// Test della raccolta dei volumi.
//
// Il difetto che questa raccolta corregge era invisibile durante l'operazione e si manifestava
// dieci minuti dopo: ritagliare **sostituiva** il volume, e l'originale non tornava più. Quasi
// tutti i test qui sotto sono la stessa domanda posta in modi diversi — *l'originale c'è ancora?*

@Suite("Raccolta dei volumi")
struct VolumeLibraryTests {

    /// Un volume minuscolo: qui non si guarda il contenuto, solo la contabilità.
    private func makeVolume(columns: Int = 8) throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: columns, rows: 8, slices: 8, spacingMM: Vec3(0.5, 0.5, 0.5))
    }

    private func makeLibrary() throws -> (VolumeLibrary, UUID) {
        var library = VolumeLibrary()
        let id = library.open(try makeVolume(), named: "Studio", provenance: .imported)
        return (library, id)
    }

    // MARK: Il difetto originario

    @Test("Un derivato si aggiunge, non sostituisce")
    func derivedVolumeDoesNotReplaceTheOriginal() throws {
        var (library, original) = try makeLibrary()
        let crop = library.addDerived(
            try makeVolume(columns: 4), named: "Ritaglio", from: original, operation: "Ritaglio")

        #expect(crop != nil)
        #expect(library.entries.count == 2)
        // L'originale è ancora lì, ed è tutto il punto.
        #expect(library[original] != nil)
        // E si lavora sul nuovo, perché è quello che si è appena creato.
        #expect(library.selectedID == crop)
    }

    @Test("Si torna all'originale scegliendolo")
    func theOriginalIsReachableAgain() throws {
        var (library, original) = try makeLibrary()
        library.addDerived(
            try makeVolume(columns: 4), named: "Ritaglio", from: original, operation: "Ritaglio")

        let selected = library.select(original)
        #expect(selected)
        #expect(library.selected?.id == original)
        #expect(library.selected?.provenance.isImported == true)
    }

    // MARK: Provenienza

    @Test("La catena di provenienza risale fino allo studio letto")
    func ancestryReachesTheImportedVolume() throws {
        var (library, original) = try makeLibrary()
        let crop = try #require(
            library.addDerived(
                try makeVolume(columns: 6), named: "Ritaglio", from: original,
                operation: "Ritaglio"))
        let resampled = try #require(
            library.addDerived(
                try makeVolume(columns: 4), named: "150 µm", from: crop,
                operation: "Ricampionamento"))

        #expect(library.ancestry(of: resampled).map(\.id) == [resampled, crop, original])
        #expect(library.depth(of: resampled) == 2)
        #expect(library.depth(of: original) == 0)
        #expect(library.provenanceDescription(of: resampled) == "Studio → Ritaglio → 150 µm")
    }

    @Test("Un derivato di un genitore inesistente viene rifiutato")
    func derivedWithoutParentIsRejected() throws {
        var (library, _) = try makeLibrary()
        let orphan = library.addDerived(
            try makeVolume(), named: "Orfano", from: UUID(), operation: "Ritaglio")
        #expect(orphan == nil)
        #expect(library.entries.count == 1)
    }

    @Test("I derivati stanno subito sotto il loro genitore")
    func derivedVolumesSitUnderTheirParent() throws {
        var (library, original) = try makeLibrary()
        let first = try #require(
            library.addDerived(
                try makeVolume(columns: 6), named: "A", from: original, operation: "Ritaglio"))
        let second = try #require(
            library.addDerived(
                try makeVolume(columns: 5), named: "B", from: original, operation: "Ritaglio"))
        let nested = try #require(
            library.addDerived(
                try makeVolume(columns: 4), named: "A1", from: first, operation: "Ritaglio"))

        // «A» col suo figlio, poi «B»: l'elenco piatto si legge come un albero.
        #expect(library.entries.map(\.id) == [original, first, nested, second])
    }

    // MARK: Togliere

    @Test("Il volume letto non si può togliere")
    func theImportedVolumeCannotBeRemoved() throws {
        var (library, original) = try makeLibrary()
        let removed = library.remove(original)
        #expect(!removed)
        #expect(library.entries.count == 1)
    }

    @Test("Togliendo un derivato se ne vanno anche i suoi discendenti")
    func removingTakesTheWholeSubtree() throws {
        var (library, original) = try makeLibrary()
        let crop = try #require(
            library.addDerived(
                try makeVolume(columns: 6), named: "Ritaglio", from: original,
                operation: "Ritaglio"))
        library.addDerived(
            try makeVolume(columns: 4), named: "150 µm", from: crop,
            operation: "Ricampionamento")
        #expect(library.entries.count == 3)

        let removed = library.remove(crop)
        #expect(removed)
        #expect(library.entries.map(\.id) == [original])
        // Selezione tornata al genitore, che è da dove si era partiti.
        #expect(library.selectedID == original)
    }

    @Test("Togliendo un derivato la selezione torna al genitore, non al primo dell'elenco")
    func removalFallsBackToTheParent() throws {
        var (library, original) = try makeLibrary()
        let first = try #require(
            library.addDerived(
                try makeVolume(columns: 6), named: "A", from: original, operation: "Ritaglio"))
        let nested = try #require(
            library.addDerived(
                try makeVolume(columns: 4), named: "A1", from: first, operation: "Ritaglio"))

        #expect(library.selectedID == nested)
        let removed = library.remove(nested)
        #expect(removed)
        // Il primo dell'elenco sarebbe l'originale: il genitore è «A», ed è lì che si torna.
        #expect(library.selectedID == first)
    }

    @Test("Togliere un volume che non c'è non fa nulla")
    func removingAnUnknownVolumeIsInert() throws {
        var (library, _) = try makeLibrary()
        let removed = library.remove(UUID())
        #expect(!removed)
        #expect(library.entries.count == 1)
    }

    // MARK: Nomi

    @Test("Due volumi non possono avere lo stesso nome")
    func namesAreMadeUnique() throws {
        var (library, original) = try makeLibrary()
        library.addDerived(
            try makeVolume(columns: 6), named: "Ritaglio", from: original, operation: "Ritaglio")
        library.addDerived(
            try makeVolume(columns: 5), named: "Ritaglio", from: original, operation: "Ritaglio")
        library.addDerived(
            try makeVolume(columns: 4), named: "Ritaglio", from: original, operation: "Ritaglio")

        let names = library.entries.map(\.name)
        #expect(Set(names).count == names.count)
        #expect(names.contains("Ritaglio"))
        #expect(names.contains("Ritaglio 2"))
        #expect(names.contains("Ritaglio 3"))
    }

    @Test("Un nome vuoto prende quello dell'operazione")
    func emptyNameFallsBackToTheOperation() throws {
        var (library, original) = try makeLibrary()
        let id = try #require(
            library.addDerived(
                try makeVolume(columns: 4), named: "   ", from: original,
                operation: "Ricampionamento"))
        #expect(library[id]?.name == "Ricampionamento")
    }

    @Test("Rinominare non crea collisioni")
    func renamingAvoidsCollisions() throws {
        var (library, original) = try makeLibrary()
        let a = try #require(
            library.addDerived(
                try makeVolume(columns: 6), named: "A", from: original, operation: "Ritaglio"))
        let b = try #require(
            library.addDerived(
                try makeVolume(columns: 5), named: "B", from: original, operation: "Ritaglio"))

        library.rename(b, to: "A")
        #expect(library[b]?.name == "A 2")
        #expect(library[a]?.name == "A")

        // Rinominare col nome che già si ha non deve trasformarlo in «A 2».
        library.rename(a, to: "A")
        #expect(library[a]?.name == "A")
    }

    // MARK: Aprire un altro studio

    @Test("Aprire un altro studio svuota la raccolta")
    func openingAnotherStudyClearsEverything() throws {
        var (library, original) = try makeLibrary()
        library.addDerived(
            try makeVolume(columns: 4), named: "Ritaglio", from: original, operation: "Ritaglio")

        let fresh = library.open(try makeVolume(), named: "Altro paziente", provenance: .imported)
        // Nessun residuo dello studio precedente: un derivato di un altro caso accanto a questo
        // sarebbe il modo più diretto di misurare sul paziente sbagliato.
        #expect(library.entries.map(\.id) == [fresh])
        #expect(library.selectedID == fresh)
    }

    @Test("Il riassunto dice dimensioni e passo")
    func summaryReportsTheGrid() throws {
        var library = VolumeLibrary()
        library.open(try makeVolume(), named: "Studio", provenance: .synthetic)
        let summary = try #require(library.selected?.summary)
        #expect(summary.contains("8×8×8"))
        #expect(summary.contains("0,50 mm iso") || summary.contains("0.50 mm iso"))
    }
}

// MARK: - Provenienza della radice

@Suite("Provenienza dello studio in uso")
struct VolumeProvenanceTests {

    private func makeVolume() throws -> Volume {
        try SyntheticVolume.makePhantom(
            columns: 8, rows: 8, slices: 8, spacingMM: Vec3(0.5, 0.5, 0.5))
    }

    @Test("Un derivato del fantoccio resta fantoccio")
    func derivedFromPhantomIsStillSynthetic() throws {
        var library = VolumeLibrary()
        let root = library.open(try makeVolume(), named: "Fantoccio", provenance: .synthetic)
        let crop = try #require(
            library.addDerived(
                try makeVolume(), named: "Ritaglio", from: root, operation: "Ritaglio"))

        // È la proprietà che serve all'etichetta nei riquadri: ritagliare un fantoccio non lo
        // trasforma in uno studio vero, e la scritta deve continuare a dirlo.
        #expect(library.selectedID == crop)
        if case .synthetic = library.selectedRootProvenance {} else {
            Issue.record("la radice dovrebbe essere il fantoccio")
        }
    }

    @Test("Rinominare non cambia la provenienza")
    func renamingDoesNotLaunderTheProvenance() throws {
        var library = VolumeLibrary()
        let root = library.open(try makeVolume(), named: "Fantoccio", provenance: .synthetic)
        library.rename(root, to: "Rossi Mario")
        if case .synthetic = library.selectedRootProvenance {} else {
            Issue.record("un fantoccio rinominato resta un fantoccio")
        }
    }

    @Test("Su uno studio letto la radice è importata")
    func importedStudyReportsImported() throws {
        var library = VolumeLibrary()
        library.open(try makeVolume(), named: "Studio", provenance: .imported)
        #expect(library.selectedRootProvenance?.isImported == true)
    }
}
