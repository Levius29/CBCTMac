import DICOMCore
import Testing

@testable import ImplantKit

// Afferrare e muovere un impianto.
//
// Le proprietà che contano sono due, e sono quelle che distinguono un'inclinazione utile da una
// che fa impazzire: ruotando dall'apice la **piattaforma** non si muove, e ruotando dalla testa
// l'**apice** non si muove. Se una delle due non vale, chi corregge l'asse si accorge che il
// punto che aveva già sistemato è scappato.

@Suite("Manipolazione dell'impianto")
struct ImplantManipulationTests {

    private func makeImplant() -> ImplantPlacement {
        ImplantPlacement(
            model: ImplantModel(
                manufacturer: "Prova", line: "Retta",
                diameterMM: 4.0, lengthMM: 10.0, platformDiameterMM: 4.0),
            platformMM: Vec3(0, 0, 10),
            axis: Vec3(0, 0, -1),
            label: "1")
    }

    // MARK: Presa

    @Test("Le tre zone si afferrano dove stanno")
    func gripsFollowTheAxis() {
        let implant = makeImplant()
        // L'asse va verso −z: la piattaforma è a z = 10, l'apice a z = 0.
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, 9.5), of: implant, toleranceMM: 1) == .head)
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, 5), of: implant, toleranceMM: 1) == .body)
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, 0.5), of: implant, toleranceMM: 1) == .apex)
    }

    @Test("Si afferra il pezzo, non solo la linea che lo attraversa")
    func gripReachesTheSurface() {
        // Un impianto da 4 mm ha raggio 2: con un millimetro di tolleranza si prende fino a 3 mm
        // dall'asse. Se contasse la sola tolleranza lo si potrebbe afferrare solo dall'asse, cioè
        // dall'unico punto in cui non si vede nulla da afferrare.
        let implant = makeImplant()
        #expect(ImplantManipulation.grip(at: Vec3(2.5, 0, 5), of: implant, toleranceMM: 1) == .body)
        #expect(ImplantManipulation.grip(at: Vec3(3.5, 0, 5), of: implant, toleranceMM: 1) == nil)
    }

    @Test("Oltre gli estremi si afferra solo entro la tolleranza")
    func gripStopsBeyondTheEnds() {
        let implant = makeImplant()
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, 10.5), of: implant, toleranceMM: 1) == .head)
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, 12), of: implant, toleranceMM: 1) == nil)
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, -0.5), of: implant, toleranceMM: 1) == .apex)
        #expect(ImplantManipulation.grip(at: Vec3(0, 0, -2), of: implant, toleranceMM: 1) == nil)
    }

    // MARK: Traslazione e affondamento

    @Test("Traslando, l'asse non cambia e la lunghezza nemmeno")
    func movingKeepsTheAxis() {
        let implant = makeImplant()
        let moved = ImplantManipulation.moved(implant, byMM: Vec3(3, -2, 1))

        #expect(moved.platformMM == Vec3(3, -2, 11))
        #expect(moved.axis == implant.axis)
        #expect(abs(moved.platformMM.distance(to: moved.apexMM) - 10) < 1e-9)
    }

    @Test("Affondando si scorre lungo l'asse, non lungo la verticale dello schermo")
    func slidingFollowsTheImplantAxis() {
        // Su un impianto inclinato le due cose divergono, ed è proprio sugli inclinati che si
        // regola la profondità: scorrere lungo la verticale sposterebbe anche in trasversale.
        var implant = makeImplant()
        implant.axis = Vec3(0.6, 0, -0.8)
        let deeper = ImplantManipulation.slid(implant, byMM: 2)

        let delta = deeper.platformMM - implant.platformMM
        #expect(abs(delta.length - 2) < 1e-9)
        #expect(delta.distance(to: implant.axis * 2) < 1e-9)
        #expect(deeper.axis == implant.axis)
    }

    // MARK: Inclinazione

    @Test("Ruotando dall'apice, la piattaforma resta ferma")
    func tiltingFromApexKeepsThePlatform() {
        let implant = makeImplant()
        let tilted = ImplantManipulation.tilted(implant, apexTowards: Vec3(4, 0, 2))

        #expect(tilted.platformMM == implant.platformMM)
        #expect(abs(tilted.axis.length - 1) < 1e-9)
        // L'apice guarda verso il punto richiesto.
        let toTarget = (Vec3(4, 0, 2) - implant.platformMM).normalized!
        #expect(tilted.axis.distance(to: toTarget) < 1e-9)
        #expect(abs(tilted.platformMM.distance(to: tilted.apexMM) - 10) < 1e-9)
    }

    @Test("Ruotando dalla testa, l'apice resta fermo")
    func tiltingFromHeadKeepsTheApex() {
        // È la proprietà che rende utile questa presa: l'apice sta appena sopra il canale, e chi
        // corregge l'emergenza non vuole che si muova. Con una rotazione attorno alla
        // piattaforma l'apice si sposterebbe, che è l'errore da non commettere.
        let implant = makeImplant()
        let apexBefore = implant.apexMM
        let tilted = ImplantManipulation.tilted(implant, headTowards: Vec3(5, 0, 8))

        #expect(tilted.apexMM.distance(to: apexBefore) < 1e-9)
        #expect(abs(tilted.platformMM.distance(to: tilted.apexMM) - 10) < 1e-9)
        // La piattaforma è nella direzione richiesta, alla lunghezza dell'impianto dall'apice.
        let toHead = (Vec3(5, 0, 8) - apexBefore).normalized!
        #expect(tilted.platformMM.distance(to: apexBefore + toHead * 10) < 1e-9)
    }

    @Test("Un bersaglio coincidente col perno non produce un asse non definito")
    func degenerateTargetsAreRejected() {
        // Trascinare fin sopra il punto attorno a cui si ruota darebbe una direzione di lunghezza
        // nulla: l'impianto deve restare com'è, non acquisire un asse fatto di NaN che poi
        // propaga in ogni misura di sicurezza.
        let implant = makeImplant()
        let onPlatform = ImplantManipulation.tilted(implant, apexTowards: implant.platformMM)
        #expect(onPlatform == implant)

        let onApex = ImplantManipulation.tilted(implant, headTowards: implant.apexMM)
        #expect(onApex == implant)
    }

    @Test("Un bersaglio quasi coincidente ruota, non viene scartato")
    func nearlyDegenerateTargetsStillRotate() {
        // La prova che conta davvero: un guard che scarta solo il caso **esattamente** degenere
        // sembra corretto e non protegge da nulla, perché il caso esatto non capita mai col
        // mouse. Qui il bersaglio è a un centesimo di millimetro dal perno e deve funzionare.
        let implant = makeImplant()
        let target = implant.platformMM + Vec3(0.01, 0, 0)
        let tilted = ImplantManipulation.tilted(implant, apexTowards: target)

        #expect(tilted != implant)
        #expect(abs(tilted.axis.length - 1) < 1e-9)
        #expect(tilted.axis.distance(to: Vec3(1, 0, 0)) < 1e-9)
    }

    // MARK: Trascinamento

    @Test("Il trascinamento del corpo usa lo spostamento, quello degli estremi il punto assoluto")
    func draggingUsesTheRightReference() {
        // Il corpo trasla dello spostamento del puntatore; gli estremi puntano **dove** sta il
        // puntatore. Usare lo spostamento anche per la rotazione farebbe accumulare l'errore di
        // ogni fotogramma, e l'impianto scivolerebbe via dal cursore mentre lo si inclina.
        let implant = makeImplant()

        let moved = ImplantManipulation.dragged(
            implant, grip: .body, toMM: Vec3(1, 1, 10), fromMM: Vec3(0, 0, 10))
        #expect(moved.platformMM == Vec3(1, 1, 10))

        let tilted = ImplantManipulation.dragged(
            implant, grip: .apex, toMM: Vec3(4, 0, 2), fromMM: Vec3(0, 0, 0))
        #expect(tilted.platformMM == implant.platformMM)
        #expect(tilted.axis != implant.axis)
    }
}
