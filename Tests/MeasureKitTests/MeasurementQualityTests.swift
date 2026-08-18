import DICOMCore
import Foundation
import Testing

@testable import MeasureKit

// Contratto 5: nessun numero dichiara più precisione di quanta ne abbia.
//
// Le prove qui non verificano una formula — quella si legge — ma le **conseguenze** che rendono
// il modello utile: che l'incertezza scali col voxel, che i decimali mostrati siano quelli
// giustificati, e soprattutto che lo slab non finisca dentro un ± simmetrico quando il suo
// effetto è un limite inferiore.

@Suite("Incertezza delle misure")
struct MeasurementQualityTests {

    private func context(
        spacing: Double = 0.2, slab: Double = 0, projects: Bool = false,
        curved: Bool = false, derived: Bool = false
    ) -> AcquisitionContext {
        AcquisitionContext(
            voxelSpacingMM: Vec3(spacing, spacing, spacing),
            slabThicknessMM: slab,
            projectsThroughSlab: projects,
            isCurvedSurface: curved,
            isDerivedVolume: derived)
    }

    // MARK: L'incertezza

    @Test("Su voxel da 0,2 mm l'incertezza tipo è di poco più di un decimo di millimetro")
    func uncertaintyMatchesTheLiterature() {
        // σ = s·√(2/12)·√2 = s/√3. A 0,2 mm fa 0,115 mm, che è l'ordine di grandezza riportato
        // per l'accuratezza lineare delle CBCT dentali. Un modello che desse 0,01 o 1 mm sarebbe
        // sbagliato in modo evidente, e questa prova è quella che se ne accorge.
        let uncertainty = MeasurementUncertainty.lengthUncertaintyMM(context: context())
        #expect(abs(uncertainty - 0.2 / 3.0.squareRoot()) < 1e-12)
        #expect(uncertainty > 0.10 && uncertainty < 0.13, "σ = \(uncertainty) mm")
    }

    @Test("L'incertezza scala con il voxel, non con la lunghezza")
    func uncertaintyScalesWithTheVoxel() {
        let fine = MeasurementUncertainty.lengthUncertaintyMM(context: context(spacing: 0.1))
        let coarse = MeasurementUncertainty.lengthUncertaintyMM(context: context(spacing: 0.4))
        #expect(abs(coarse / fine - 4) < 1e-9)

        // E non dipende da quanto è lunga la misura: un errore di posa dell'estremità vale lo
        // stesso su due millimetri e su venti. È il motivo per cui l'incertezza **relativa** di
        // una misura corta è molto peggiore, ed è bene che il numero lo mostri.
        let short = MeasurementUncertainty.quality(ofLengthMM: 2, context: context())
        let long = MeasurementUncertainty.quality(ofLengthMM: 40, context: context())
        #expect(short.standardUncertaintyMM == long.standardUncertaintyMM)
    }

    @Test("Su un volume anisotropo comanda l'asse peggiore")
    func anisotropicVoxelsUseTheWorstAxis() {
        // Una misura obliqua raccoglie il contributo dell'asse più grossolano, e quale direzione
        // avrà non si sa in anticipo: la media sarebbe ottimismo.
        let anisotropic = AcquisitionContext(voxelSpacingMM: Vec3(0.2, 0.2, 0.6))
        #expect(anisotropic.governingSpacingMM == 0.6)
        let uncertainty = MeasurementUncertainty.lengthUncertaintyMM(context: anisotropic)
        #expect(abs(uncertainty - 0.6 / 3.0.squareRoot()) < 1e-12)
    }

    // MARK: I decimali

    @Test("Si mostrano i decimali che l'incertezza giustifica, e non uno di più")
    func decimalsFollowTheUncertainty() {
        #expect(MeasurementUncertainty.decimals(forUncertaintyMM: 0.115) == 1)
        #expect(MeasurementUncertainty.decimals(forUncertaintyMM: 0.058) == 2)
        #expect(MeasurementUncertainty.decimals(forUncertaintyMM: 1.2) == 0)
    }

    @Test("L'incertezza si arrotonda a una cifra significativa")
    func uncertaintyRoundsToOneSignificantFigure() {
        // Niente valori a metà: `0,35` in virgola mobile vale 0,34999…, e pretendere 0,4
        // significherebbe pretendere una convenzione che il tipo non può onorare. I casi a metà
        // non sono ciò che questa funzione deve garantire — lo è che resti **una** cifra
        // significativa e vicina al valore.
        #expect(abs(MeasurementUncertainty.roundedUncertaintyMM(0.115) - 0.1) < 1e-12)
        #expect(abs(MeasurementUncertainty.roundedUncertaintyMM(0.36) - 0.4) < 1e-12)
        #expect(abs(MeasurementUncertainty.roundedUncertaintyMM(0.34) - 0.3) < 1e-12)
        #expect(abs(MeasurementUncertainty.roundedUncertaintyMM(2.7) - 3) < 1e-12)
        #expect(MeasurementUncertainty.roundedUncertaintyMM(0) == 0)

        // La proprietà che conta, su un intervallo: una sola cifra significativa, e mai lontana
        // dall'originale più di mezza unità di quella cifra.
        for step in 1...400 {
            let value = Double(step) * 0.01
            let rounded = MeasurementUncertainty.roundedUncertaintyMM(value)
            let exponent = Foundation.floor(Foundation.log10(rounded))
            let digits = rounded / Foundation.pow(10.0, exponent)
            #expect(abs(digits - digits.rounded()) < 1e-9, "\(value) → \(rounded)")
            #expect(abs(rounded - value) <= Foundation.pow(10.0, exponent) * 0.5 + 1e-9)
        }
    }

    @Test("Il testo formattato porta un decimale su voxel da 0,2 mm, non due")
    func formattedLengthStopsAtTheJustifiedDigit() {
        // È la correzione che ha motivato tutto: `12,47 mm` dichiarava dieci micrometri su un
        // dato che ne ha duecento.
        #expect(MeasurementFormatter.length(12.4732, context: context()) == "12.5 mm")
        #expect(
            MeasurementFormatter.lengthWithUncertainty(12.4732, context: context())
                == "12.5 ± 0.1 mm")

        // Senza contesto si torna al comportamento di prima: i documenti vecchi non portano
        // l'informazione, e inventarla sarebbe peggio che ometterla.
        #expect(MeasurementFormatter.length(12.4732, context: nil) == "12.47 mm")
    }

    @Test("Su voxel grossolani i decimali spariscono")
    func coarseVoxelsDropTheDecimals() {
        let coarse = context(spacing: 2.0)
        #expect(MeasurementFormatter.length(12.4732, context: coarse) == "12 mm")
    }

    // MARK: Gli avvertimenti

    @Test("Lo slab non entra nel ±, entra come limite inferiore")
    func slabIsALowerBoundNotASymmetricError() {
        // È la scelta che distingue un modello onesto da uno comodo. Entrambe le estremità stanno
        // **sul piano** per costruzione, quindi la distanza nel piano è esatta; ciò che lo slab
        // rende ignoto è la profondità delle due strutture, e la distanza vera è √(L² + Δ²) —
        // sempre maggiore o uguale a quella misurata, mai minore. Un ± suggerirebbe simmetria.
        let projected = context(slab: 20, projects: true)
        let quality = MeasurementUncertainty.quality(ofLengthMM: 10, context: projected)

        // L'incertezza simmetrica resta quella del voxel: lo slab non la gonfia.
        #expect(abs(quality.standardUncertaintyMM - 0.2 / 3.0.squareRoot()) < 1e-12)

        guard case .projectedSlab(let thickness, let excess)? = quality.caveats.first else {
            Issue.record("avvertimento sullo slab mancante"); return
        }
        #expect(thickness == 20)
        // √(100 + 400) − 10 = 12,36 mm.
        #expect(abs(excess - ((100.0 + 400.0).squareRoot() - 10)) < 1e-9)
    }

    @Test("L'eccesso si calcola in forma esatta, non asintotica")
    func excessIsExactOnShortMeasurements() {
        // La forma asintotica `t²/2L` sbaglia proprio sulle misure corte, che sono quelle su cui
        // si decide: su 1 mm di misura con 4 mm di slab darebbe 8 mm invece di 3,12.
        let quality = MeasurementUncertainty.quality(
            ofLengthMM: 1, context: context(slab: 4, projects: true))
        guard case .projectedSlab(_, let excess)? = quality.caveats.first else {
            Issue.record("avvertimento mancante"); return
        }
        #expect(abs(excess - ((1.0 + 16.0).squareRoot() - 1)) < 1e-9)
        #expect(excess < 4, "l'eccesso non può superare lo spessore")
    }

    @Test("Uno slab che non proietta non produce avvertimenti")
    func averagedSlabIsNotFlagged() {
        // Mediando, il pixel viene da tutto lo spessore e la profondità di ciò che si vede è il
        // centro con una sfocatura: non c'è una struttura a profondità ignota da segnalare.
        let averaged = context(slab: 20, projects: false)
        #expect(MeasurementUncertainty.quality(ofLengthMM: 10, context: averaged).caveats.isEmpty)
    }

    @Test("La superficie curva e il volume derivato si dichiarano, e pesano diversamente")
    func curvedAndDerivedAreDistinguished() {
        let curved = MeasurementUncertainty.quality(
            ofLengthMM: 10, context: context(curved: true))
        #expect(curved.caveats == [.curvedSurface])
        #expect(curved.caveats[0].invalidatesLength)

        let derived = MeasurementUncertainty.quality(
            ofLengthMM: 10, context: context(derived: true))
        #expect(derived.caveats == [.derivedVolume])
        // Un volume derivato non falsa una **lunghezza**: falsa le densità. Confondere le due
        // cose farebbe scartare misure geometriche valide.
        #expect(!derived.caveats[0].invalidatesLength)
    }

    @Test("Gli avvertimenti si accumulano")
    func caveatsAccumulate() {
        let all = MeasurementUncertainty.quality(
            ofLengthMM: 10, context: context(slab: 8, projects: true, curved: true, derived: true))
        #expect(all.caveats.count == 3)
        #expect(all.hasCaveats)
    }

    // MARK: Compatibilità dei documenti

    @Test("Un'annotazione senza contesto si decodifica ancora")
    func documentsWithoutContextStillDecode() throws {
        // L'aggiunta è opzionale proprio per questo: un piano salvato prima che il contratto
        // esistesse deve continuare ad aprirsi, mostrando il valore senza incertezza — che è
        // quello che faceva comunque.
        let json = """
            {"id":"\(UUID().uuidString)","label":"","colorHex":"#32B8C6",
             "createdAt":0,"isHidden":false,"comment":""}
            """
        let decoded = try JSONDecoder().decode(
            AnnotationMetadata.self, from: Data(json.utf8))
        #expect(decoded.acquisition == nil)
    }
}
