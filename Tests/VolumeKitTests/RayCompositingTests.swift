import DICOMCore
import Foundation
import Testing

@testable import VolumeKit

// Come si compone un raggio, e perché il risultato non deve dipendere da come lo si campiona.
//
// Due correzioni, entrambe nate da un difetto visibile.
//
// L'opacità della tabella vale **per campione**: a passo triplo si prendono un terzo dei
// campioni e il volume risulta più trasparente. Siccome girando il volume si passa a passo
// grosso per restare fluidi, l'immagine cambiava aspetto proprio mentre la si muoveva.
//
// E l'opacità non seguiva il gradiente, quindi contava lo spessore attraversato: l'interno
// spugnoso di un osso, che è spesso, copriva la corticale che lo delimita, che è sottile. Da qui
// il «tutto un po' mischiato».
//
// Le formule stanno in Swift e non nel file `.metal` proprio per poter essere provate: il
// bersaglio Metal fuori da macOS non si compila, e lì nessuna prova le raggiungerebbe.

@Suite("Composizione lungo il raggio")
struct RayCompositingTests {

    @Test("Al passo di riferimento l'opacità non si tocca")
    func theReferenceStepLeavesOpacityAlone() {
        #expect(RayCompositing.opacityStepScale(for: .high) == 1)
        for opacity in [0.0, 0.15, 0.5, 0.9, 1.0] {
            #expect(
                abs(RayCompositing.correctedOpacity(opacity, stepScale: 1) - opacity) < 1e-12)
        }
    }

    @Test("A passo più grosso ogni campione pesa di più, non di meno")
    func acoarserStepMakesEachSampleCountMore() {
        // Interattivo: passo 1,5 voxel contro 0,5 di riferimento, cioè il triplo.
        #expect(abs(RayCompositing.opacityStepScale(for: .interactive) - 3) < 1e-12)
        #expect(abs(RayCompositing.opacityStepScale(for: .standard) - 1.5) < 1e-12)

        let corrected = RayCompositing.correctedOpacity(0.2, stepScale: 3)
        #expect(corrected > 0.2)
        // Tre tratti da 0,2 in fila lasciano passare 0,8³: l'opacità equivalente è il resto.
        #expect(abs(corrected - (1 - 0.8 * 0.8 * 0.8)) < 1e-12)
    }

    @Test("La correzione rende la trasparenza indipendente dal passo")
    func transparencyBecomesStepIndependent() {
        // È il punto di tutta la faccenda: attraversare dieci millimetri di un tessuto deve
        // dare la stessa opacità sia campionandolo trenta volte sia dieci.
        let perSample = 0.08

        func transmittance(samples: Int, stepScale: Double) -> Double {
            let alpha = RayCompositing.correctedOpacity(perSample, stepScale: stepScale)
            return pow(1 - alpha, Double(samples))
        }

        let fine = transmittance(samples: 30, stepScale: 1)
        let coarse = transmittance(samples: 10, stepScale: 3)
        #expect(abs(fine - coarse) < 1e-12)

        // Senza correzione le due divergono, ed è la differenza che si vedeva ruotando: a passo
        // triplo il volume lascia passare **cinque volte** più luce, cioè appare molto più
        // trasparente. Detto come rapporto e non come differenza assoluta, che dipende da dove
        // si è scelto il campione e non dice quanto il difetto si veda.
        let uncorrected = pow(1 - perSample, 10.0)
        #expect(uncorrected > fine * 5)
    }

    @Test("Gli estremi restano estremi")
    func theExtremesAreFixedPoints() {
        for scale in [0.25, 1.0, 3.0, 12.0] {
            #expect(RayCompositing.correctedOpacity(0, stepScale: scale) == 0)
            #expect(RayCompositing.correctedOpacity(1, stepScale: scale) == 1)
        }
        // Un passo nullo non fa dividere per zero né produce valori fuori intervallo.
        let degenerate = RayCompositing.correctedOpacity(0.5, stepScale: 0)
        #expect(degenerate >= 0 && degenerate <= 1)
    }

    @Test("Il riferimento del gradiente è un fronte pieno per millimetro")
    func theGradientReferenceIsAFullFrontPerMillimetre() {
        // Tabella distribuita su tremila GV, pendenza uno, campione unorm su sedici bit.
        let reference = RayCompositing.gradientReference(
            densitySpan: 3000, rescaleSlope: 1, rawScale: 65535)
        #expect(abs(reference - 3000 / 65535) < 1e-12)

        // Un confine osso-aria vero — millecinquecento GV in quattro decimi di millimetro —
        // deve superarlo, così satura e resta pieno.
        let boneEdge = (1500.0 / 65535) / 0.4
        #expect(boneEdge > reference)

        // Il rumore dentro l'osso spugnoso — un centinaio di GV sulla stessa distanza — deve
        // restarne ben sotto: è quello che la modulazione deve spegnere.
        let noise = (100.0 / 65535) / 0.4
        #expect(noise < reference * 0.2)
    }

    @Test("Il riferimento tiene conto della pendenza DICOM e non divide per zero")
    func theReferenceHonoursTheSlope() {
        // Pendenza doppia: lo stesso salto di densità corrisponde a metà salto di valore grezzo.
        let unit = RayCompositing.gradientReference(
            densitySpan: 2000, rescaleSlope: 1, rawScale: 65535)
        let doubled = RayCompositing.gradientReference(
            densitySpan: 2000, rescaleSlope: 2, rawScale: 65535)
        #expect(abs(doubled - unit / 2) < 1e-15)

        // Pendenza nulla o negativa: non deve produrre infiniti né segni.
        #expect(RayCompositing.gradientReference(
            densitySpan: 2000, rescaleSlope: 0, rawScale: 65535).isFinite)
        #expect(RayCompositing.gradientReference(
            densitySpan: 2000, rescaleSlope: -1, rawScale: 65535) > 0)
        #expect(RayCompositing.gradientReference(
            densitySpan: 0, rescaleSlope: 1, rawScale: 0) > 0)
    }

    @Test("La separazione predefinita è accesa ma non al massimo")
    func theDefaultSeparationIsOnButNotMaximal() {
        let standard = LightingParameters.standard
        #expect(standard.boundarySharpness > 0)
        #expect(standard.boundarySharpness < 1)
        // E si lascia regolare fuori intervallo senza uscirne.
        #expect(LightingParameters(boundarySharpness: 3).boundarySharpness == 1)
        #expect(LightingParameters(boundarySharpness: -2).boundarySharpness == 0)
    }

    @Test("Il blocco di uniform ha la dimensione che lo shader si aspetta")
    func theUniformBlockKeepsItsLayout() {
        // Sei `float4` e quattro gruppi da quattro scalari: centosessanta byte.
        //
        // Non è pedanteria. Il layout dev'essere identico byte per byte a quello in
        // `Raycast.metal`, e un campo aggiunto senza il riempimento che completa il gruppo non
        // dà né errore né avviso: dà campi letti dal posto sbagliato, cioè un'immagine sbagliata
        // per una ragione che non si trova guardando il codice che disegna.
        #expect(MemoryLayout<RaycastUniforms>.size == 160)
        #expect(MemoryLayout<RaycastUniforms>.stride == 160)
        #expect(MemoryLayout<RaycastUniforms>.alignment == 16)
    }
}
