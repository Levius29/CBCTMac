import Foundation
import MeasureKit
import Testing

@Suite("Oggetti del piano e migrazione del documento")
struct PlanObjectTests {
    @Test("Il registro modifica e rimuove gli attributi comuni")
    func registryOperations() throws {
        let implantID = UUID()
        let annotationID = UUID()
        var registry = PlanObjectRegistry()
        registry.register(
            PlanObjectInfo(id: implantID, kind: .implant, name: "Impianto 1", order: 0))
        registry.register(
            PlanObjectInfo(
                id: annotationID, kind: .annotation, name: "Annotazione 1", order: 0))

        registry.rename("Impianto centrale", id: implantID)
        registry.setVisible(false, id: implantID)
        registry.setLocked(true, id: implantID)

        let changed = try #require(registry[implantID])
        #expect(changed.name == "Impianto centrale")
        #expect(changed.isVisible == false)
        #expect(changed.isLocked == true)

        registry.remove(id: implantID)
        #expect(registry[implantID] == nil)
        #expect(registry.objects.count == 1)

        registry.removeAll(of: .annotation)
        #expect(registry.objects.isEmpty)
    }

    @Test("Un identificatore sconosciuto resta visibile")
    func unknownObjectIsVisible() {
        let registry = PlanObjectRegistry()
        #expect(registry.isVisible(UUID()))
    }

    @Test("I nomi proposti non riutilizzano un numero cancellato in mezzo")
    func suggestedNamesStayUniqueAfterRemoval() {
        var registry = PlanObjectRegistry()
        var identifiers: [UUID] = []

        for order in 0..<3 {
            let id = UUID()
            identifiers.append(id)
            let name = registry.suggestedName(for: .annotation)
            registry.register(
                PlanObjectInfo(id: id, kind: .annotation, name: name, order: order))
        }

        #expect(registry.objects(of: .annotation).map(\.name) == [
            "Annotazione 1", "Annotazione 2", "Annotazione 3",
        ])
        registry.remove(id: identifiers[1])
        #expect(registry.suggestedName(for: .annotation) == "Annotazione 4")
    }

    @Test("I colori proposti sono deterministici e distinti fino a esaurimento")
    func suggestedColorsUseFixedPalette() {
        var registry = PlanObjectRegistry()
        let first = registry.suggestedColorHex(for: .implant)
        #expect(registry.suggestedColorHex(for: .implant) == first)

        var used: Set<String> = []
        var palette: [String] = []
        for order in 0..<12 {
            let color = registry.suggestedColorHex(for: .implant)
            #expect(!used.contains(color))
            #expect(color.count == 6)
            #expect(!color.contains("#"))
            used.insert(color)
            palette.append(color)

            var info = PlanObjectInfo(
                id: UUID(), kind: .implant, name: "Impianto \(order + 1)", order: order)
            info.colorHex = color
            registry.register(info)
        }

        #expect(used.count == 12)

        // Un piano importato può contenere la stessa tavolozza in un ordine diverso. Dopo
        // l'esaurimento la ripetizione è inevitabile, ma non deve coincidere col vicino.
        var imported = PlanObjectRegistry()
        for order in 0..<palette.count {
            let paletteIndex = (order + 1) % palette.count
            var info = PlanObjectInfo(
                id: UUID(), kind: .implant, name: "Importato \(order + 1)", order: order)
            info.colorHex = palette[paletteIndex]
            imported.register(info)
        }
        let lastColor = palette[0]
        #expect(imported.suggestedColorHex(for: .implant) != lastColor)
    }

    @Test("Lo spostamento mantiene ordini contigui e senza duplicati")
    func movingObjectNormalizesOrders() throws {
        var registry = PlanObjectRegistry()
        var identifiers: [UUID] = []
        for order in 0..<4 {
            let id = UUID()
            identifiers.append(id)
            registry.register(
                PlanObjectInfo(
                    id: id, kind: .nerveCanal, name: "Canale \(order + 1)", order: order))
        }

        registry.move(id: identifiers[3], toOrder: 1)

        let ordered = registry.objects(of: .nerveCanal)
        #expect(ordered.map(\.id) == [
            identifiers[0], identifiers[3], identifiers[1], identifiers[2],
        ])
        #expect(Set(ordered.map(\.order)) == Set(0..<ordered.count))
    }

    @Test("Il documento conserva il registro nell'andata e ritorno JSON")
    func documentRoundTripIncludesRegistry() throws {
        let id = UUID()
        var registry = PlanObjectRegistry()
        var info = PlanObjectInfo(
            id: id, kind: .mesh, name: "Scansione intraorale", order: 0)
        info.colorHex = "E15759"
        info.isLocked = true
        info.note = "Allineata con tre coppie di punti"
        registry.register(info)

        var document = PlanDocument(
            study: StudyReference(studyInstanceUID: "1.2.3", seriesInstanceUID: "4.5.6"),
            annotations: [],
            registry: registry,
            appVersion: "0.1.0-test")
        document.createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        document.modifiedAt = Date(timeIntervalSince1970: 1_700_000_001)

        let data = try PlanDocument.encoder().encode(document)
        let decoded = try PlanDocument.decoded(from: data)

        #expect(decoded == document)
        #expect(decoded.registry[id] == info)
        #expect(decoded.formatVersion == PlanDocument.currentFormatVersion)
    }

    @Test("Un documento precedente ricostruisce il registro dalle annotazioni")
    func previousDocumentMigratesRegistry() throws {
        let annotationID = "11111111-2222-3333-4444-555555555555"
        let json = """
            {
              "formatVersion": 1,
              "study": {
                "studyInstanceUID": "1.2.3",
                "seriesInstanceUID": "4.5.6"
              },
              "annotations": [
                {
                  "distance": {
                    "_0": {
                      "metadata": {
                        "id": "\(annotationID)",
                        "label": "Distanza seno",
                        "colorHex": "#ABCDEF",
                        "createdAt": "2026-01-02T03:04:05Z",
                        "isHidden": true,
                        "comment": "Documento versione uno"
                      },
                      "startMM": { "x": 0, "y": 0, "z": 0 },
                      "endMM": { "x": 10, "y": 0, "z": 0 }
                    }
                  }
                }
              ],
              "auditLog": [],
              "createdAt": "2026-01-02T03:04:05Z",
              "modifiedAt": "2026-01-02T03:04:05Z",
              "appVersion": "0.1.0",
              "disclaimer": "Documento di prova"
            }
            """

        let document = try PlanDocument.decoded(from: Data(json.utf8))
        let migrated = try #require(document.registry.objects.first)

        #expect(document.registry.objects.count == 1)
        #expect(migrated.id.uuidString == annotationID)
        #expect(migrated.kind == .annotation)
        #expect(migrated.name == "Annotazione 1")
        #expect(migrated.order == 0)
        #expect(migrated.isVisible)
        #expect(!migrated.isLocked)
        #expect(migrated.colorHex == "ABCDEF")
        #expect(migrated.note == "Documento versione uno")
    }

    @Test("Una versione futura viene rifiutata nominando entrambe le versioni")
    func futureDocumentIsRejected() {
        let futureVersion = PlanDocument.currentFormatVersion + 1
        let data = Data("{\"formatVersion\":\(futureVersion)}".utf8)

        do {
            _ = try PlanDocument.decoded(from: data)
            Issue.record("La decodifica avrebbe dovuto rifiutare la versione futura")
        } catch let error as PlanDocumentError {
            #expect(
                error == .unsupportedFormatVersion(
                    found: futureVersion, supported: PlanDocument.currentFormatVersion))
            #expect(error.localizedDescription.contains("\(futureVersion)"))
            #expect(
                error.localizedDescription.contains("\(PlanDocument.currentFormatVersion)"))
            let existentialError: any Error = error
            #expect(existentialError.localizedDescription.contains("\(futureVersion)"))
            #expect(
                existentialError.localizedDescription.contains(
                    "\(PlanDocument.currentFormatVersion)"))
        } catch {
            Issue.record("Errore inatteso: \(error)")
        }
    }
}
