import Foundation
import Testing

@testable import ImplantKit

// Importare un catalogo vero.
//
// La prova che conta di più non è che legga: è che **non tenga per buono** quel che non capisce.
// Un catalogo importato a metà è la cosa peggiore che possa uscire di qui — si sceglie
// l'impianto dal menu, si pianifica, si ordina, e la misura che manca era quella che serviva.
// Chi importa deve sapere quante righe sono entrate e quali no.

@Suite("Importazione del catalogo impianti")
struct ImplantCatalogImportTests {

    @Test("Legge un catalogo separato da virgole")
    func readsACommaSeparatedCatalogue() throws {
        let text = """
            produttore,linea,diametro,lunghezza,piattaforma,apice
            Alfa,Conico,3.75,10,3.75,2.4
            Alfa,Conico,4.2,11.5,4.2,2.8
            """
        let result = try ImplantCatalogImport.read(text)
        #expect(result.models.count == 2)
        #expect(result.problems.isEmpty)
        #expect(result.models[0].manufacturer == "Alfa")
        #expect(abs(result.models[0].diameterMM - 3.75) < 1e-9)
        #expect(abs(result.models[1].lengthMM - 11.5) < 1e-9)
        #expect(abs(result.models[1].apexDiameterMM - 2.8) < 1e-9)
    }

    @Test("Legge anche coi tabulatori e con la virgola decimale")
    func readsTabsAndItalianDecimals() throws {
        // Un foglio di calcolo italiano esporta tabulatori e `3,75`: rifiutarlo perché non è
        // `3.75` sarebbe pedanteria che costa un'ora a chi importa.
        let text = "produttore\tlinea\tdiametro\tlunghezza\nAlfa\tConico\t3,75\t10"
        let result = try ImplantCatalogImport.read(text)
        #expect(result.models.count == 1)
        #expect(abs(result.models[0].diameterMM - 3.75) < 1e-9)
    }

    @Test("Le colonne si riconoscono comunque siano scritte")
    func columnNamesAreForgiving() throws {
        let text = """
            Produttore, LINEA ,Diametro,Lunghezza
            Alfa,Conico,4,10
            """
        let result = try ImplantCatalogImport.read(text)
        #expect(result.models.count == 1)
    }

    @Test("Le colonne facoltative mancanti si ricavano invece di far fallire")
    func optionalColumnsAreDerived() throws {
        let text = """
            produttore,linea,diametro,lunghezza
            Alfa,Conico,4,10
            """
        let result = try ImplantCatalogImport.read(text)
        let model = try #require(result.models.first)
        // Piattaforma uguale al corpo, apice dal rapporto tipico: sono valori di partenza
        // dichiarati, non misure inventate del prodotto.
        #expect(abs(model.platformDiameterMM - 4) < 1e-9)
        #expect(abs(model.apexDiameterMM - 4 * ImplantModel.defaultApexRatio) < 1e-9)
    }

    @Test("Una riga che non si capisce viene **riportata**, non saltata in silenzio")
    func badRowsAreReportedNotSkipped() throws {
        let text = """
            produttore,linea,diametro,lunghezza
            Alfa,Conico,3.75,10
            Alfa,Conico,abc,10
            Alfa,Conico,4.2,
            ,Conico,4.2,10
            Alfa,Conico,4.2,11.5
            """
        let result = try ImplantCatalogImport.read(text)
        #expect(result.models.count == 2, "le due righe buone entrano")
        #expect(result.problems.count == 3, "e le tre storte si dicono")
        // Il numero di riga serve a trovarle nel file, quindi dev'essere quello vero.
        #expect(result.problems.map(\.line) == [3, 4, 5])
    }

    @Test("Misure fuori da ogni intervallo plausibile non passano")
    func implausibleSizesAreRejected() throws {
        // Vengono da una colonna scambiata o da un'unità sbagliata, e pianificarci sopra
        // significherebbe misure che non esistono.
        let text = """
            produttore,linea,diametro,lunghezza
            Alfa,Conico,80,10
            Alfa,Conico,4,-3
            Alfa,Conico,4,500
            Alfa,Conico,4,10
            """
        let result = try ImplantCatalogImport.read(text)
        #expect(result.models.count == 1)
        #expect(result.problems.count == 3)
    }

    @Test("Righe vuote e commenti non sono errori")
    func blanksAndCommentsAreNotProblems() throws {
        let text = """
            # Catalogo trascritto dal listino, revisione di agosto
            produttore,linea,diametro,lunghezza

            Alfa,Conico,4,10
            # nota in mezzo
            Alfa,Conico,4.2,11.5
            """
        let result = try ImplantCatalogImport.read(text)
        #expect(result.models.count == 2)
        #expect(result.problems.isEmpty)
    }

    @Test("Un file senza le colonne obbligatorie dice quali mancano")
    func missingColumnsAreNamed() {
        #expect(throws: ImplantCatalogImport.ImportError.self) {
            _ = try ImplantCatalogImport.read("produttore,linea\nAlfa,Conico")
        }
        do {
            _ = try ImplantCatalogImport.read("produttore,linea\nAlfa,Conico")
        } catch let error as ImplantCatalogImport.ImportError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("diametro"))
            #expect(message.contains("lunghezza"))
        } catch {
            Issue.record("errore di tipo inatteso")
        }
    }

    @Test("Un file vuoto è un errore, non un catalogo vuoto")
    func anEmptyFileIsAnError() {
        #expect(throws: ImplantCatalogImport.ImportError.self) {
            _ = try ImplantCatalogImport.read("")
        }
        #expect(throws: ImplantCatalogImport.ImportError.self) {
            _ = try ImplantCatalogImport.read("produttore,linea,diametro,lunghezza\n")
        }
    }

    @Test("Scritto e riletto dà lo stesso catalogo")
    func writingAndReadingRoundTrips() throws {
        let original = [
            ImplantModel(
                manufacturer: "Alfa", line: "Conico", diameterMM: 3.75, lengthMM: 10,
                platformDiameterMM: 3.75, apexDiameterMM: 2.4),
            ImplantModel(
                manufacturer: "Alfa", line: "Cilindrico", diameterMM: 4.2, lengthMM: 11.5,
                platformDiameterMM: 4.2, apexDiameterMM: 4.2),
        ]
        let result = try ImplantCatalogImport.read(ImplantCatalogImport.write(original))
        #expect(result.problems.isEmpty)
        #expect(result.models.count == original.count)
        for (written, read) in zip(original, result.models) {
            #expect(written.manufacturer == read.manufacturer)
            #expect(written.line == read.line)
            #expect(abs(written.diameterMM - read.diameterMM) < 1e-9)
            #expect(abs(written.lengthMM - read.lengthMM) < 1e-9)
            #expect(abs(written.apexDiameterMM - read.apexDiameterMM) < 1e-9)
        }
    }

    @Test("Il modello di file che si offre all'utente è valido")
    func theTemplateItselfImports() throws {
        let result = try ImplantCatalogImport.read(ImplantCatalogImport.templateCSV)
        #expect(result.problems.isEmpty)
        #expect(result.models.count == 2)
    }
}
