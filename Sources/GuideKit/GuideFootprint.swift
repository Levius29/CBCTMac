import DICOMCore
import ImplantKit
import MeshKit

// Quale parte della scansione la dima appoggia.
//
// # Perché è una decisione e non un dettaglio
//
// Una dima che appoggia su poco non sta ferma; una che appoggia su tutta l'arcata non entra, o
// entra in un modo solo se il paziente ha sottosquadri. L'appoggio decide la stabilità, ed è la
// cosa che distingue una dima usabile da un pezzo di plastica.
//
// Qui l'appoggio si costruisce **attorno agli impianti pianificati**, che è la regola più semplice
// difendibile: la dima copre i siti e i denti che li fiancheggiano. Non è la scelta di un
// laboratorio — quella la fa una persona guardando i sottosquadri — ed è il motivo per cui il
// raggio è un parametro e non una costante.

public enum GuideFootprint {

    /// Vertici della scansione entro un raggio dagli impianti, come appoggio della dima.
    ///
    /// - Parameter radiusMM: quanto la dima si estende attorno a ciascun sito. Sotto gli otto
    ///   millimetri copre appena il sito e non trova appoggio dentale; sopra i venti arriva a
    ///   denti che potrebbero avere sottosquadri, e la dima non entra.
    /// - Returns: la maschera, e quanti vertici comprende — che è il numero da guardare per
    ///   sapere se l'appoggio esiste davvero prima di provare a costruire.
    public static func aroundImplants(
        scan: Mesh,
        implants: [ImplantPlacement],
        radiusMM: Double
    ) -> (mask: RegionMask, includedCount: Int) {
        var mask = RegionMask(vertexCount: scan.verticesMM.count)
        mask.excludeAll()
        guard !implants.isEmpty, radiusMM > 0 else { return (mask, 0) }

        for implant in implants {
            // Attorno alla **piattaforma** e non all'apice: la dima appoggia sulla superficie
            // occlusale, e l'apice sta dentro l'osso a dieci millimetri da lì.
            mask.include(
                sphereCentreMM: implant.platformMM,
                radiusMM: radiusMM,
                vertices: scan.verticesMM)
        }

        var count = 0
        for index in scan.verticesMM.indices where mask.isIncluded(index) { count += 1 }
        return (mask, count)
    }
}
