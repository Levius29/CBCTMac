import DICOMCore
import Foundation
import Testing

@testable import ImplantKit

// Test della pianificazione guidata dalla protesi.
//
// Il controllo che conta di più è il quinto: **l'emergenza pesa più della divergenza**. È una
// decisione clinica tradotta in codice, non una formula, e un'implementazione che giudicasse sul
// solo angolo passerebbe tutti gli altri test di questo file.

@Suite("Denti protesici e vincolo con l'impianto")
struct ProstheticPlanningTests {

    // MARK: Numerazione

    @Test("La numerazione FDI accetta i quattro quadranti e rifiuta il resto")
    func fdiValidation() {
        for number in [11, 18, 21, 28, 31, 38, 41, 48, 36, 24] {
            #expect(ProstheticTooth.isValidFDI(number), "\(number) è un dente reale")
        }
        // Zero non esiste, 19/29/49 sono posizioni oltre l'ottavo, 50 è un quadrante che non c'è.
        for number in [0, 9, 10, 19, 29, 39, 49, 50, 51, -11, 100] {
            #expect(!ProstheticTooth.isValidFDI(number), "\(number) non è un dente")
            #expect(ProstheticTooth.standard(forToothNumber: number) == nil)
        }
    }

    // MARK: Misure

    @Test("Le misure standard distinguono incisivo, canino, premolare e molare")
    func standardSizesDifferByType() throws {
        let incisor = try #require(ProstheticTooth.standard(forToothNumber: 11))
        let canine = try #require(ProstheticTooth.standard(forToothNumber: 13))
        let premolar = try #require(ProstheticTooth.standard(forToothNumber: 14))
        let molar = try #require(ProstheticTooth.standard(forToothNumber: 16))

        // L'incisivo è più stretto e più alto del molare: è la differenza di forma che rende
        // utile avere misure per tipo invece di un blocco unico.
        #expect(incisor.widthMM < molar.widthMM)
        #expect(incisor.heightMM > molar.heightMM)
        // Il canino è il più alto di tutti.
        #expect(canine.heightMM >= incisor.heightMM)
        // Il molare è il più profondo in vestibolo-linguale.
        #expect(molar.depthMM > premolar.depthMM)
        #expect(premolar.depthMM > incisor.depthMM)
    }

    @Test("L'asse punta verso l'apice, cioè in versi opposti fra arcata superiore e inferiore")
    func axisPointsTowardsTheApex() throws {
        let upper = try #require(ProstheticTooth.standard(forToothNumber: 16))
        let lower = try #require(ProstheticTooth.standard(forToothNumber: 46))
        // In LPS z cresce verso la testa: l'apice di un superiore sta sopra, quello di un
        // inferiore sotto. Con lo stesso verso per entrambi, metà dei denti avrebbe divergenza
        // 180° rispetto a un impianto corretto.
        #expect(upper.axisMM.z > 0)
        #expect(lower.axisMM.z < 0)
    }

    // MARK: Divergenza

    @Test("Assi paralleli danno divergenza nulla, e angoli costruiti danno il loro valore")
    func divergenceMatchesConstruction() {
        func constraint(implantAxis: Vec3) -> ProstheticConstraint {
            ProstheticConstraint(
                toothAxisMM: Vec3(0, 0, -1),
                implantAxisMM: implantAxis,
                occlusalCentreMM: Vec3(0, 0, 0),
                crownHalfWidthMM: 5,
                implantPlatformMM: Vec3(0, 0, -10))
        }

        #expect(abs(constraint(implantAxis: Vec3(0, 0, -1)).divergenceDegrees) < 1e-9)

        for degrees in [10.0, 20.0, 30.0, 45.0] {
            let radians = degrees * .pi / 180
            let tilted = Vec3(Foundation.sin(radians), 0, -Foundation.cos(radians))
            #expect(abs(constraint(implantAxis: tilted).divergenceDegrees - degrees) < 1e-9)
        }

        // Asse invertito: l'angolo è acuto, quindi zero e non 180.
        #expect(abs(constraint(implantAxis: Vec3(0, 0, 1)).divergenceDegrees) < 1e-9)
    }

    // MARK: Emergenza

    @Test("Un impianto allineato emerge nel centro della corona")
    func alignedImplantEmergesAtTheCentre() throws {
        let tooth = try #require(
            ProstheticTooth.standard(forToothNumber: 36, at: Vec3(20, -30, -8)))
        let implant = ImplantPlacement(
            platformMM: tooth.occlusalCentreMM + tooth.axisMM * 12,
            axis: tooth.axisMM,
            label: "36")
        let constraint = ProstheticConstraint(tooth: tooth, implant: implant)

        let emergence = try #require(constraint.emergenceMM)
        #expect(emergence.distance(to: tooth.occlusalCentreMM) < 1e-9)
        #expect(try #require(constraint.emergenceOffsetMM) < 1e-9)
        #expect(constraint.emergesWithinCrown)
        #expect(constraint.severity == .acceptable)
    }

    @Test("Un asse parallelo al piano occlusale non ha emergenza, e non un punto lontanissimo")
    func parallelAxisHasNoEmergence() {
        let constraint = ProstheticConstraint(
            toothAxisMM: Vec3(0, 0, -1),
            // Perpendicolare all'asse del dente, quindi giacente nel piano occlusale.
            implantAxisMM: Vec3(1, 0, 0),
            occlusalCentreMM: Vec3(0, 0, 0),
            crownHalfWidthMM: 5,
            implantPlatformMM: Vec3(0, 0, -10))

        #expect(constraint.emergenceMM == nil)
        #expect(constraint.emergenceOffsetMM == nil)
        #expect(!constraint.emergesWithinCrown)
        // Senza emergenza non si può dire che vada bene.
        #expect(constraint.severity == .unacceptable)
        #expect(constraint.summary.contains("parallelo"))

        // **Quasi** parallelo, che è il caso per cui la soglia esiste. Perfettamente parallelo il
        // denominatore vale zero esatto e qualunque guardia lo intercetta, anche `> 0`; a un
        // centomilionesimo dal parallelo la divisione riesce e produce un punto a centinaia di
        // metri, presentato come una misura in millimetri. L'ho scoperto mutando la soglia a
        // zero e vedendo la suite passare lo stesso.
        let almost = ProstheticConstraint(
            toothAxisMM: Vec3(0, 0, -1),
            implantAxisMM: Vec3(1, 0, -1e-8),
            occlusalCentreMM: Vec3(0, 0, 0),
            crownHalfWidthMM: 5,
            implantPlatformMM: Vec3(0, 0, -10))
        #expect(almost.emergenceMM == nil)
    }

    @Test("Il piano occlusale sta sulla superficie masticante, non al centro della corona")
    func occlusalCentreSitsOnTheChewingSurface() throws {
        let lower = try #require(ProstheticTooth.standard(forToothNumber: 46, at: Vec3(18, -25, -6)))

        // È lì che l'impianto deve emergere. Con il piano al centro della corona l'emergenza si
        // calcolerebbe a metà dentro il dente, e lo scostamento risulterebbe sistematicamente
        // sbagliato di mezza altezza — un errore di quattro millimetri su un molare.
        let offset = lower.occlusalCentreMM - lower.positionMM
        #expect(abs(offset.length - lower.heightMM / 2) < 1e-9)
        // Dalla parte opposta all'apice.
        #expect(offset.dot(lower.axisMM) < 0)

        // Su un superiore l'apice sta sopra, quindi la superficie masticante sta sotto.
        let upper = try #require(ProstheticTooth.standard(forToothNumber: 16, at: Vec3(18, -25, 12)))
        #expect(upper.occlusalCentreMM.z < upper.positionMM.z)
        #expect(lower.occlusalCentreMM.z > lower.positionMM.z)
    }

    @Test("Inclinando l'impianto lo scostamento cresce come la tangente dell'angolo")
    func emergenceOffsetGrowsWithTilt() throws {
        // Piattaforma dieci millimetri sotto il piano occlusale: inclinando di θ, l'emergenza si
        // sposta di 10·tan(θ). È il conto che chi pianifica fa a mente, e deve tornare.
        let depth = 10.0
        for degrees in [5.0, 10.0, 20.0] {
            let radians = degrees * .pi / 180
            let constraint = ProstheticConstraint(
                toothAxisMM: Vec3(0, 0, -1),
                implantAxisMM: Vec3(Foundation.sin(radians), 0, -Foundation.cos(radians)),
                occlusalCentreMM: Vec3(0, 0, 0),
                crownHalfWidthMM: 5,
                implantPlatformMM: Vec3(0, 0, -depth))

            let offset = try #require(constraint.emergenceOffsetMM)
            #expect(abs(offset - depth * Foundation.tan(radians)) < 1e-9)
        }
    }

    // MARK: Le soglie, e la decisione che le governa

    @Test("Le soglie di divergenza scattano appena sopra e non appena sotto")
    func severityThresholdsAreSharp() {
        /// Impianto che emerge **esattamente** al centro comunque sia inclinato: ruotandolo
        /// attorno al punto di emergenza si isola l'effetto dell'angolo da quello dello
        /// scostamento, che è ciò che questo test vuole misurare.
        func constraint(degrees: Double) -> ProstheticConstraint {
            let radians = degrees * .pi / 180
            let axis = Vec3(Foundation.sin(radians), 0, -Foundation.cos(radians))
            return ProstheticConstraint(
                toothAxisMM: Vec3(0, 0, -1),
                implantAxisMM: axis,
                occlusalCentreMM: Vec3(0, 0, 0),
                crownHalfWidthMM: 5,
                implantPlatformMM: Vec3(0, 0, 0) + axis * 10)
        }

        #expect(constraint(degrees: 14.9).severity == .acceptable)
        #expect(constraint(degrees: 15.1).severity == .caution)
        #expect(constraint(degrees: 24.9).severity == .caution)
        #expect(constraint(degrees: 25.1).severity == .unacceptable)
    }

    @Test("L'emergenza pesa più della divergenza")
    func emergenceOutweighsDivergence() {
        // Molto divergente — venti gradi — ma emerge esattamente al centro della corona: si
        // compensa con un moncone angolato, che è routine. Attenzione, non rifiuto.
        let twenty = 20.0 * .pi / 180
        let tiltedAxis = Vec3(Foundation.sin(twenty), 0, -Foundation.cos(twenty))
        let divergentButCentred = ProstheticConstraint(
            toothAxisMM: Vec3(0, 0, -1),
            implantAxisMM: tiltedAxis,
            occlusalCentreMM: Vec3(0, 0, 0),
            crownHalfWidthMM: 5,
            implantPlatformMM: tiltedAxis * 10)
        #expect(abs(divergentButCentred.divergenceDegrees - 20) < 1e-9)
        #expect(divergentButCentred.emergesWithinCrown)
        #expect(divergentButCentred.severity == .caution)

        // Quasi parallelo — due gradi — ma la piattaforma è spostata lateralmente e l'emergenza
        // cade fuori dalla corona: non si compensa con nulla. Un giudizio basato sul solo angolo
        // direbbe «accettabile» qui e «attenzione» sopra, cioè il contrario del vero.
        let two = 2.0 * .pi / 180
        let alignedButOutside = ProstheticConstraint(
            toothAxisMM: Vec3(0, 0, -1),
            implantAxisMM: Vec3(Foundation.sin(two), 0, -Foundation.cos(two)),
            occlusalCentreMM: Vec3(0, 0, 0),
            crownHalfWidthMM: 5,
            implantPlatformMM: Vec3(9, 0, -10))
        #expect(alignedButOutside.divergenceDegrees < 3)
        #expect(!alignedButOutside.emergesWithinCrown)
        #expect(alignedButOutside.severity == .unacceptable)
    }

    @Test("Le soglie sono parametri, non costanti murate nel codice")
    func thresholdsAreConfigurable() {
        let strict = ProstheticThresholds(cautionDegrees: 5, unacceptableDegrees: 10)
        let eight = 8.0 * .pi / 180
        let axis = Vec3(Foundation.sin(eight), 0, -Foundation.cos(eight))
        let constraint = ProstheticConstraint(
            toothAxisMM: Vec3(0, 0, -1),
            implantAxisMM: axis,
            occlusalCentreMM: Vec3(0, 0, 0),
            crownHalfWidthMM: 5,
            implantPlatformMM: axis * 10,
            thresholds: strict)

        // Otto gradi: accettabile con le soglie predefinite, attenzione con quelle strette. Le
        // soglie sono orientative e chi le usa deve poterle cambiare.
        #expect(constraint.severity == .caution)
    }
}
