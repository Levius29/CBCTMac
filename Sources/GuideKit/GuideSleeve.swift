import Foundation
import MeshKit
import DICOMCore
import ImplantKit

/// Boccola cilindrica per guidare una fresa lungo un asse pianificato.
public struct GuideSleeve: Hashable, Sendable, Codable {
    /// Asse dal lato occlusale verso l'apice.
    public var axis: Vec3
    /// Punto sul bordo inferiore, cioè quello più vicino al sito operativo.
    public var bottomMM: Vec3
    public var innerDiameterMM: Double
    public var outerDiameterMM: Double
    public var heightMM: Double
    public var offsetToPlatformMM: Double

    public init(
        axis: Vec3,
        bottomMM: Vec3,
        innerDiameterMM: Double,
        outerDiameterMM: Double,
        heightMM: Double,
        offsetToPlatformMM: Double
    ) {
        self.axis = axis
        self.bottomMM = bottomMM
        self.innerDiameterMM = innerDiameterMM
        self.outerDiameterMM = outerDiameterMM
        self.heightMM = heightMM
        self.offsetToPlatformMM = offsetToPlatformMM
    }

    /// Costruisce una boccola coassiale a un impianto pianificato.
    public static func forImplant(
        _ implant: ImplantPlacement,
        innerDiameterMM: Double,
        outerDiameterMM: Double,
        heightMM: Double,
        offsetToPlatformMM: Double
    ) -> GuideSleeve {
        let axis = implant.axis.normalized ?? .zero
        return GuideSleeve(
            axis: axis,
            bottomMM: implant.platformMM - axis * offsetToPlatformMM,
            innerDiameterMM: innerDiameterMM,
            outerDiameterMM: outerDiameterMM,
            heightMM: heightMM,
            offsetToPlatformMM: offsetToPlatformMM)
    }

    // non-ancora-collegato: aspetta la guida endodontica, che non esiste come funzione.
    // Costruire la boccola è il pezzo facile; il difficile è il percorso accesso-apice, che
    // va tracciato su un canale, e per tracciarlo serve una vista dedicata che non c'è.
    /// Costruisce una boccola endodontica lungo il percorso accesso-apice.
    public static func forCanal(
        accessMM: Vec3,
        apexMM: Vec3,
        burDiameterMM: Double,
        outerDiameterMM: Double,
        heightMM: Double
    ) -> GuideSleeve {
        let direction = (apexMM - accessMM).normalized ?? .zero
        return GuideSleeve(
            axis: direction,
            bottomMM: accessMM,
            innerDiameterMM: burDiameterMM,
            outerDiameterMM: outerDiameterMM,
            heightMM: heightMM,
            offsetToPlatformMM: 0)
    }

    /// Campo del cilindro esterno, negativo dentro il volume della boccola.
    public func housingField(grid: FieldGrid) -> ScalarField {
        cylinderField(
            grid: grid,
            radiusMM: outerDiameterMM / 2,
            halfHeightMM: heightMM / 2)
    }

    /// Campo del foro interno, negativo dentro.
    ///
    /// Il foro è un cilindro infinito rispetto alla griglia. Un'estensione basata sulle sole
    /// dimensioni della boccola può essere insufficiente quando la parete della dima è spessa e
    /// lasciare una membrana che a video quasi non si vede ma impedisce il passaggio della fresa.
    public func boreField(grid: FieldGrid) -> ScalarField {
        var field = ScalarField(grid: grid, initialValue: .infinity)
        let direction = axis.normalized ?? Vec3(0, 0, -1)
        for z in 0..<grid.countZ {
            for y in 0..<grid.countY {
                for x in 0..<grid.countX {
                    let relative = grid.position(x: x, y: y, z: z) - bottomMM
                    let axial = relative.dot(direction)
                    let radial = (relative - direction * axial).length
                    field.setValue(radial - innerDiameterMM / 2, x: x, y: y, z: z)
                }
            }
        }
        return field
    }

    private func cylinderField(
        grid: FieldGrid,
        radiusMM: Double,
        halfHeightMM: Double
    ) -> ScalarField {
        var field = ScalarField(grid: grid, initialValue: .infinity)
        let direction = axis.normalized ?? Vec3(0, 0, -1)
        // La boccola si estende dal bordo inferiore in direzione occlusale, opposta all'asse.
        let centre = bottomMM - direction * (heightMM / 2)
        for z in 0..<grid.countZ {
            for y in 0..<grid.countY {
                for x in 0..<grid.countX {
                    let point = grid.position(x: x, y: y, z: z)
                    let relative = point - centre
                    let axial = relative.dot(direction)
                    let radialVector = relative - direction * axial
                    let radial = radialVector.length
                    let radialOutside = radial - radiusMM
                    let axialOutside = abs(axial) - halfHeightMM
                    let outsideRadial = max(radialOutside, 0)
                    let outsideAxial = max(axialOutside, 0)
                    let outside = Foundation.sqrt(
                        outsideRadial * outsideRadial + outsideAxial * outsideAxial)
                    let inside = min(max(radialOutside, axialOutside), 0)
                    field.setValue(outside + inside, x: x, y: y, z: z)
                }
            }
        }
        return field
    }
}
