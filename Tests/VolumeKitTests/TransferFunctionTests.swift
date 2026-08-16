import DICOMCore
import Testing

@testable import VolumeKit

// Test della transfer function e della camera.
//
// Sono la parte del rendering 3D verificabile senza GPU: la rampa è matematica pura, e la
// camera pure. Quello che resta allo shader — comporre i campioni — è meccanico, mentre gli
// errori veri stanno qui: una rampa che non interpola, un colore non premoltiplicato, una
// camera i cui assi degenerano a certe elevazioni.

@Suite("TransferFunction")
struct TransferFunctionTests {

    @Test("Il campionamento interpola fra i punti di controllo")
    func interpolatesBetweenStops() {
        let function = TransferFunction(stops: [
            TransferStop(density: 0, opacity: 0, color: TransferColor(0, 0, 0)),
            TransferStop(density: 100, opacity: 1, color: TransferColor(1, 1, 1)),
        ])

        let middle = function.sample(at: 50)
        #expect(abs(middle.opacity - 0.5) < 1e-9)
        #expect(abs(middle.color.red - 0.5) < 1e-9)
    }

    @Test("Fuori dagli estremi si tiene il punto più vicino, non si estrapola")
    func clampsOutsideRange() {
        // Estrapolare produrrebbe opacità negative o sopra 1, che nel compositing si traducono
        // in pixel neri o saturi in mezzo a un'immagine altrimenti corretta.
        let function = TransferFunction(stops: [
            TransferStop(density: 0, opacity: 0.2, color: TransferColor(1, 0, 0)),
            TransferStop(density: 100, opacity: 0.8, color: TransferColor(0, 1, 0)),
        ])

        #expect(abs(function.sample(at: -500).opacity - 0.2) < 1e-9)
        #expect(abs(function.sample(at: 5000).opacity - 0.8) < 1e-9)
    }

    @Test("I punti non ordinati vengono comunque interpretati correttamente")
    func handlesUnsortedStops() {
        let function = TransferFunction(stops: [
            TransferStop(density: 100, opacity: 1, color: TransferColor(1, 1, 1)),
            TransferStop(density: 0, opacity: 0, color: TransferColor(0, 0, 0)),
        ])
        #expect(abs(function.sample(at: 25).opacity - 0.25) < 1e-9)
    }

    @Test("La tabella è premoltiplicata per l'opacità")
    func tableIsPremultiplied() {
        // Il raycaster compone front-to-back con colori premoltiplicati: se la tabella non lo
        // fosse, le superfici semitrasparenti risulterebbero troppo chiare.
        let function = TransferFunction(stops: [
            TransferStop(density: 0, opacity: 0.5, color: TransferColor(1, 1, 1)),
            TransferStop(density: 100, opacity: 0.5, color: TransferColor(1, 1, 1)),
        ])
        let table = function.bake(entryCount: 8, densityRange: 0...100)

        for index in 0..<8 {
            let red = table[index * 4]
            let alpha = table[index * 4 + 3]
            #expect(abs(alpha - 0.5) < 1e-6)
            #expect(abs(red - 0.5) < 1e-6, "il colore deve essere già moltiplicato per l'alfa")
        }
    }

    @Test("La scala di opacità globale moltiplica l'intera rampa")
    func opacityScale() {
        var function = TransferFunction(stops: [
            TransferStop(density: 0, opacity: 0.4, color: TransferColor(1, 1, 1)),
            TransferStop(density: 100, opacity: 0.4, color: TransferColor(1, 1, 1)),
        ])
        function.opacityScale = 2.0

        let table = function.bake(entryCount: 4, densityRange: 0...100)
        #expect(abs(table[3] - 0.8) < 1e-6)
    }

    @Test("L'opacità resta comunque limitata a 1")
    func opacityNeverExceedsOne() {
        var function = TransferFunction(stops: [
            TransferStop(density: 0, opacity: 0.9, color: TransferColor(1, 1, 1)),
            TransferStop(density: 100, opacity: 0.9, color: TransferColor(1, 1, 1)),
        ])
        function.opacityScale = 5.0

        let table = function.bake(entryCount: 4, densityRange: 0...100)
        for index in 0..<4 {
            #expect(table[index * 4 + 3] <= 1.0 + 1e-6)
        }
    }

    @Test("La dimensione della tabella corrisponde a quanto richiesto")
    func tableSize() {
        let table = TransferFunction.bone.bake(entryCount: 256, densityRange: -1000...3000)
        #expect(table.count == 256 * 4)
    }

    @Test("Il preset osso è trasparente sull'aria e opaco sulla corticale")
    func bonePreset() {
        let function = TransferFunction.bone
        #expect(function.sample(at: -1000).opacity < 0.01)
        #expect(function.sample(at: 0).opacity < 0.01)
        #expect(function.sample(at: 1600).opacity > 0.7)
    }

    @Test("Il preset vie aeree rende visibile l'aria e non l'osso")
    func airwayPresetIsInverted() {
        // È l'unico preset rovesciato: mostra il vuoto invece del tessuto. Se un giorno
        // qualcuno lo «correggesse» per uniformarlo agli altri, questo test lo ferma.
        let function = TransferFunction.airway
        #expect(function.sample(at: -950).opacity > 0.3)
        #expect(function.sample(at: 1200).opacity < 0.01)
    }
}

@Suite("VolumeCamera")
struct VolumeCameraTests {

    @Test("A rotazione ed elevazione nulle si guarda il paziente da davanti")
    func defaultFacesAnterior() {
        let camera = VolumeCamera()
        // La camera sta sull'anteriore e guarda verso il posteriore, cioè verso +P.
        #expect(camera.forward.isApproximatelyEqual(to: Vec3(0, 1, 0), tolerance: 1e-9))
    }

    @Test("I tre assi della camera restano ortonormali a ogni orientamento")
    func axesStayOrthonormal() {
        // Il caso critico è l'elevazione alta, dove la direzione di vista si avvicina all'asse
        // di riferimento verticale e il prodotto vettoriale rischia di degenerare.
        for azimuth in stride(from: 0.0, to: 6.28, by: 0.7) {
            for elevation in [-1.5, -0.8, 0.0, 0.8, 1.5] {
                let camera = VolumeCamera(azimuth: azimuth, elevation: elevation)
                let f = camera.forward
                let r = camera.right
                let d = camera.down

                #expect(abs(f.length - 1) < 1e-9)
                #expect(abs(r.length - 1) < 1e-9)
                #expect(abs(d.length - 1) < 1e-9)
                #expect(abs(f.dot(r)) < 1e-9)
                #expect(abs(f.dot(d)) < 1e-9)
                #expect(abs(r.dot(d)) < 1e-9)
            }
        }
    }

    @Test("L'elevazione è limitata per non ribaltare la vista")
    func elevationIsClamped() {
        let camera = VolumeCamera(elevation: 3.0)
        #expect(camera.elevation <= 1.5)
        let flipped = VolumeCamera(elevation: -3.0)
        #expect(flipped.elevation >= -1.5)
    }

    @Test("L'inquadratura iniziale contiene il volume")
    func fittedContainsVolume() throws {
        let geometry = try VolumeGeometry(
            columnCount: 100, rowCount: 100, sliceCount: 100,
            columnSpacingMM: 0.5, rowSpacingMM: 0.5, sliceSpacingMM: 0.5,
            orientation: .standardAxial, originMM: Vec3(-25, -25, -25))

        let camera = VolumeCamera.fitted(to: geometry)
        var maxDistance = 0.0
        for corner in geometry.boundingBoxCornersMM {
            maxDistance = max(maxDistance, corner.distance(to: camera.targetMM))
        }
        #expect(camera.halfHeightMM >= maxDistance)
        #expect(camera.targetMM.isApproximatelyEqual(to: geometry.centerMM, tolerance: 1e-9))
    }

    @Test("Lo zoom stringe l'inquadratura senza spostare il bersaglio")
    func zooming() {
        let camera = VolumeCamera(halfHeightMM: 100, targetMM: Vec3(1, 2, 3))
        let zoomed = camera.zoomed(by: 2)
        #expect(abs(zoomed.halfHeightMM - 50) < 1e-9)
        #expect(zoomed.targetMM.isApproximatelyEqual(to: camera.targetMM))
    }

    @Test("Le viste predefinite guardano da direzioni distinte")
    func standardViews() {
        let base = VolumeCamera()
        let anterior = base.facingAnterior().forward
        let lateral = base.facingLateral().forward
        let superior = base.facingSuperior().forward

        #expect(abs(anterior.dot(lateral)) < 1e-9)
        #expect(superior.z < -0.9)  // guarda dall'alto verso il basso
    }
}

@Suite("RenderQuality")
struct RenderQualityTests {

    @Test("Il passo resta nell'intervallo utile fra mezzo voxel e un voxel e mezzo")
    func stepStaysUseful() {
        // Sotto mezzo voxel non c'è informazione da guadagnare; molto sopra il voxel si
        // perdono le strutture sottili, e una corticale da 0,5 mm sparirebbe.
        for quality in RenderQuality.allCases {
            #expect(quality.stepInVoxels >= 0.5)
            #expect(quality.stepInVoxels <= 1.5)
        }
    }

    @Test("Solo la qualità interattiva riduce la risoluzione")
    func onlyInteractiveReducesResolution() {
        #expect(RenderQuality.interactive.resolutionDivisor > 1)
        #expect(RenderQuality.standard.resolutionDivisor == 1)
        #expect(RenderQuality.high.resolutionDivisor == 1)
    }
}
