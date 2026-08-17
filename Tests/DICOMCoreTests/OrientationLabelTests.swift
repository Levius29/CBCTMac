import Testing

@testable import DICOMCore

// Lettere d'orientamento ai bordi dei riquadri.
//
// È il test più importante della suite in rapporto alla sua semplicità. La convenzione radiologica
// mette la **destra del paziente a sinistra dello schermo**, come se lo si guardasse in faccia, ed
// è il contrario di quanto suggerisce l'istinto. Sbagliarla significa pianificare un impianto dal
// lato sbagliato della bocca, e l'immagine non dà nessun segnale — è perfettamente plausibile.
//
// Le lettere si derivano dagli stessi vettori che il renderer usa per costruire il piano, quindi
// questi test verificano insieme le lettere **e** la convenzione di visualizzazione: se un giorno
// qualcuno specchiasse un piano, fallirebbero.

@Suite("Lettere d'orientamento")
struct OrientationLabelTests {

    @Test("Sull'assiale la destra del paziente sta a sinistra dello schermo")
    func axialFollowsRadiologicalConvention() {
        let edges = AnatomicalPlane.axial.edgeLabels
        #expect(edges.left == "R", "la destra del paziente va a sinistra dello schermo")
        #expect(edges.right == "L")
        #expect(edges.top == "A", "l'anteriore in alto: si guarda dai piedi verso la testa")
        #expect(edges.bottom == "P")
    }

    @Test("Sulla coronale destra e sinistra seguono la stessa convenzione")
    func coronalFollowsRadiologicalConvention() {
        let edges = AnatomicalPlane.coronal.edgeLabels
        #expect(edges.left == "R")
        #expect(edges.right == "L")
        #expect(edges.top == "H", "la testa in alto")
        #expect(edges.bottom == "F")
    }

    @Test("Sulla sagittale si guarda il paziente di profilo")
    func sagittalShowsProfile() {
        let edges = AnatomicalPlane.sagittal.edgeLabels
        #expect(edges.left == "A", "l'anteriore a sinistra dello schermo")
        #expect(edges.right == "P")
        #expect(edges.top == "H")
        #expect(edges.bottom == "F")
    }

    @Test("Le lettere sono coerenti con gli assi usati dal renderer")
    func labelsAgreeWithScreenAxes() {
        // La verifica che rende inutile duplicare la convenzione: qualunque piano, la lettera di
        // destra deve corrispondere al verso di `screenRightMM`, e quella opposta al suo negativo.
        for plane in AnatomicalPlane.allCases {
            let edges = plane.edgeLabels
            #expect(edges.right == AnatomicalPlane.label(for: plane.screenRightMM))
            #expect(edges.left == AnatomicalPlane.label(for: plane.screenRightMM * -1))
            #expect(edges.bottom == AnatomicalPlane.label(for: plane.screenDownMM))
            #expect(edges.top == AnatomicalPlane.label(for: plane.screenDownMM * -1))

            // I quattro bordi non possono ripetersi: due lettere uguali su bordi opposti
            // significherebbe un asse degenere.
            let all = [edges.top, edges.bottom, edges.left, edges.right]
            #expect(Set(all).count == 4, "\(plane.localizedName): \(all)")
        }
    }

    @Test("Ogni verso anatomico ha la sua lettera")
    func everyDirectionHasALetter() {
        #expect(AnatomicalPlane.label(for: Vec3(1, 0, 0)) == "L")
        #expect(AnatomicalPlane.label(for: Vec3(-1, 0, 0)) == "R")
        #expect(AnatomicalPlane.label(for: Vec3(0, 1, 0)) == "P")
        #expect(AnatomicalPlane.label(for: Vec3(0, -1, 0)) == "A")
        #expect(AnatomicalPlane.label(for: Vec3(0, 0, 1)) == "H")
        #expect(AnatomicalPlane.label(for: Vec3(0, 0, -1)) == "F")
    }

    @Test("Una direzione obliqua prende il verso prevalente")
    func obliqueDirectionsTakeTheDominantAxis() {
        // Su un volume ruotato gli assi dello schermo non sono più allineati a quelli del
        // paziente, e la lettera deve indicare il verso prevalente invece di tacere.
        #expect(AnatomicalPlane.label(for: Vec3(0.9, 0.4, 0.1)) == "L")
        #expect(AnatomicalPlane.label(for: Vec3(0.3, -0.95, 0.1)) == "A")
        #expect(AnatomicalPlane.label(for: Vec3(0.2, 0.3, -0.93)) == "F")
    }
}
