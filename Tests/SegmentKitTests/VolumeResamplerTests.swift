import DICOMCore
import Foundation
import Testing

@testable import SegmentKit

@Suite("Ricampionamento del volume")
struct VolumeResamplerTests {
    @Test("I preset comprendono tutti i passi richiesti")
    func spacingPresetsCoverRequiredValues() {
        for spacing in [0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0] {
            #expect(VolumeResampler.spacingPresetsMM.contains(spacing))
        }
    }

    @Test("La densità resta nello stesso punto Patient ai tre passi")
    func patientGeometryDoesNotMove() throws {
        let source = try makeLinearDensityVolume()
        let point = source.geometry.patientPoint(fromVoxel: Vec3(8.3, 7.4, 6.2))
        let expected = try #require(source.interpolatedDensityValue(atPatient: point))

        for spacing in [0.15, 0.3, 0.5] {
            let result = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: spacing)
            )
            let actual = try #require(result.interpolatedDensityValue(atPatient: point))
            #expect(abs(actual - expected) <= 1.0)
        }
    }

    @Test("La geometria Patient resta corretta con assi realmente ruotati")
    func rotatedPatientGeometryDoesNotMove() throws {
        let source = try makeLinearDensityVolume(rotated: true)
        let point = source.geometry.patientPoint(fromVoxel: Vec3(8.3, 7.4, 6.2))
        let expected = try #require(source.interpolatedDensityValue(atPatient: point))

        for spacing in [0.15, 0.3, 0.5] {
            let result = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: spacing)
            )
            let actual = try #require(result.interpolatedDensityValue(atPatient: point))
            #expect(abs(actual - expected) <= 1.0)
            #expect(result.geometry.orientation == source.geometry.orientation)
        }
    }

    @Test("Il cubo resta venti millimetri e 1200 GV")
    func phantomCubeKeepsSizeAndDensity() throws {
        let source = try SyntheticVolume.makePhantom(
            columns: 220,
            rows: 220,
            slices: 220,
            spacingMM: Vec3(0.1, 0.1, 0.1)
        )

        for spacing in [0.15, 0.3, 0.5] {
            let result = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: spacing)
            )
            let edge = try #require(foregroundExtentX(result, densityRange: 1100...1300))
            let centreDensity = try #require(result.interpolatedDensityValue(atPatient: .zero))
            #expect(abs(edge - 20.0) <= spacing)
            #expect(abs(centreDensity - 1200) <= 0.5)
            #expect(result.geometry.columnSpacingMM == spacing)
            #expect(result.geometry.rowSpacingMM == spacing)
            #expect(result.geometry.sliceSpacingMM == spacing)
            #expect(result.rescaleSlope == source.rescaleSlope)
            #expect(result.rescaleIntercept == source.rescaleIntercept)
            #expect(result.densityUnit == source.densityUnit)
        }
    }

    @Test("I conteggi coprono il box richiesto")
    func requestedSpacingCoversRegion() throws {
        let source = try makeLinearDensityVolume()
        let minimum = source.geometry.patientPoint(fromVoxel: Vec3(2.0, 3.0, 4.0))
        let maximum = source.geometry.patientPoint(fromVoxel: Vec3(12.0, 11.0, 10.0))
        let box = BoxMM(minMM: minimum, maxMM: maximum)
        let result = try VolumeResampler.resampled(
            source,
            request: ResampleRequest(spacingMM: 0.5, regionMM: box)
        )

        #expect(result.geometry.columnCount == 8)
        #expect(result.geometry.rowCount == 8)
        #expect(result.geometry.sliceCount == 8)
        #expect(result.geometry.physicalSizeMM.x >= 4.0)
        #expect(result.geometry.physicalSizeMM.y >= 4.0)
        #expect(result.geometry.physicalSizeMM.z >= 3.6)
    }

    @Test("Il downsampling media la struttura periodica invece di invertirne il contrasto")
    func downsamplingUsesCellAverage() throws {
        let orientation = try #require(SliceOrientation(
            columnDirection: Vec3(1, 0, 0),
            rowDirection: Vec3(0, 1, 0)
        ))
        let geometry = try VolumeGeometry(
            columnCount: 9,
            rowCount: 1,
            sliceCount: 1,
            columnSpacingMM: 1,
            rowSpacingMM: 1,
            sliceSpacingMM: 1,
            orientation: orientation,
            originMM: .zero
        )
        let source = try Volume(
            geometry: geometry,
            samples: [0, 1000, 0, 1000, 0, 1000, 0, 1000, 0]
        )
        // Il ritaglio colloca i nuovi centri sugli indici dispari 1, 3, 5 e 7. Un semplice
        // campionamento puntuale vede quindi sempre 1000, mentre ogni cella contiene anche 0.
        let region = BoxMM(
            minMM: Vec3(0.5, -0.5, -0.5),
            maxMM: Vec3(7.5, 0.5, 0.5)
        )
        let result = try VolumeResampler.resampled(
            source,
            request: ResampleRequest(spacingMM: 2, regionMM: region)
        )
        var pointSamples = [Int16]()
        for i in 0..<result.geometry.columnCount {
            let point = result.geometry.patientPoint(i: i, j: 0, k: 0)
            let density = source.densityValue(atPatient: point) ?? 0
            pointSamples.append(Int16(clamping: Int(density.rounded())))
        }

        #expect(result.samples == [500, 500, 500, 500])
        #expect(pointSamples == [1000, 1000, 1000, 1000])
    }

    @Test("Gli input invalidi falliscono prima dell'allocazione")
    func invalidRequestsThrowNamedErrors() throws {
        let source = try makeLinearDensityVolume()
        for spacing in [0.0, -0.1, Double.nan, Double.infinity] {
            var caught: ResampleError?
            do {
                _ = try VolumeResampler.resampled(
                    source,
                    request: ResampleRequest(spacingMM: spacing)
                )
            } catch let error as ResampleError {
                caught = error
            } catch {
            }
            guard let caught else {
                Issue.record("Era atteso invalidSpacing per \(spacing).")
                continue
            }
            guard case .invalidSpacing = caught else {
                Issue.record("Era atteso invalidSpacing per \(spacing).")
                continue
            }
        }

        let outside = BoxMM(minMM: Vec3(1000, 1000, 1000), maxMM: Vec3(1001, 1001, 1001))
        var empty: ResampleError?
        do {
            _ = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: 0.2, regionMM: outside)
            )
        } catch let error as ResampleError {
            empty = error
        } catch {
        }
        #expect(empty == .emptyRegion)

        var excessive: ResampleError?
        do {
            _ = try VolumeResampler.resampled(
                source,
                request: ResampleRequest(spacingMM: 1, maximumVoxelCount: 7)
            )
        } catch let error as ResampleError {
            excessive = error
        } catch {
        }
        #expect(excessive == .tooManyVoxels(requested: 990, limit: 7))
    }
}

// MARK: - Il ritaglio non tocca un voxel

@Suite("Ritaglio senza perdita")
struct LosslessCropTests {

    /// Anisotropo e non assiale: è la trappola del Contratto 1, e un ritaglio che sbaglia asse
    /// su un volume isotropo e assiale non dà alcun sintomo.
    func awkwardVolume() throws -> Volume {
        let orientation = try #require(
            SliceOrientation(
                columnDirection: Vec3(0.6, 0.8, 0), rowDirection: Vec3(-0.8, 0.6, 0)))
        let geometry = try VolumeGeometry(
            columnCount: 24, rowCount: 18, sliceCount: 12,
            columnSpacingMM: 0.3, rowSpacingMM: 0.3, sliceSpacingMM: 0.3,
            orientation: orientation, originMM: Vec3(-11.5, 7.25, -3.125))
        var samples: [Int16] = []
        for index in 0..<geometry.voxelCount {
            samples.append(Int16(truncatingIfNeeded: index &* 271 &- 3000))
        }
        return try Volume(geometry: geometry, samples: samples)
    }

    @Test("Allo stesso passo i campioni escono identici, non interpolati")
    func sameSpacingCopiesTheSamplesExactly() throws {
        // È la prova che conta. Prima ogni voxel usciva come media trilineare di otto vicini,
        // perché la griglia nuova nasceva sfalsata di una frazione di voxel: un ritaglio
        // restituiva un volume sfocato su tutta la sua estensione.
        let volume = try awkwardVolume()
        let geometry = volume.geometry

        // Una regione presa fra due centri di voxel, cioè **non** allineata alla griglia: è il
        // caso che prima costringeva a interpolare.
        let low = geometry.patientPoint(i: 5, j: 4, k: 3)
        let high = geometry.patientPoint(i: 17, j: 13, k: 9)
        let region = BoxMM(
            minMM: Vec3(
                Swift.min(low.x, high.x), Swift.min(low.y, high.y), Swift.min(low.z, high.z)),
            maxMM: Vec3(
                Swift.max(low.x, high.x), Swift.max(low.y, high.y), Swift.max(low.z, high.z)))

        let cropped = try VolumeResampler.resampled(
            volume,
            request: ResampleRequest(spacingMM: geometry.columnSpacingMM, regionMM: region))

        // Il passo non cambia, e nemmeno l'orientamento.
        #expect(cropped.geometry.columnSpacingMM == geometry.columnSpacingMM)
        #expect(cropped.geometry.orientation == geometry.orientation)

        // Ogni voxel del ritaglio deve essere **esattamente** un voxel del volume di partenza:
        // stesso valore, allo stesso posto nello spazio Patient.
        var checked = 0
        for k in 0..<cropped.geometry.sliceCount {
            for j in 0..<cropped.geometry.rowCount {
                for i in 0..<cropped.geometry.columnCount {
                    let point = cropped.geometry.patientPoint(i: i, j: j, k: k)
                    let sourceVoxel = geometry.voxelPoint(fromPatient: point)
                    // Il centro cade su un voxel intero del sorgente, non fra due.
                    #expect(abs(sourceVoxel.x - sourceVoxel.x.rounded()) < 1e-6)
                    #expect(abs(sourceVoxel.y - sourceVoxel.y.rounded()) < 1e-6)
                    #expect(abs(sourceVoxel.z - sourceVoxel.z.rounded()) < 1e-6)

                    let expected = try #require(
                        volume.densityValue(
                            i: Int(sourceVoxel.x.rounded()),
                            j: Int(sourceVoxel.y.rounded()),
                            k: Int(sourceVoxel.z.rounded())))
                    let found = try #require(cropped.densityValue(i: i, j: j, k: k))
                    #expect(found == expected)
                    checked += 1
                }
            }
        }
        #expect(checked > 500)
    }

    @Test("Un passo diverso ricampiona davvero, e lo si vede")
    func aDifferentSpacingStillResamples() throws {
        // La strada del ritaglio non deve rubare il lavoro al ricampionamento: chiedendo un passo
        // più grossolano i valori devono cambiare, perché è quello che si è chiesto.
        let volume = try awkwardVolume()
        let coarse = try VolumeResampler.resampled(
            volume, request: ResampleRequest(spacingMM: volume.geometry.columnSpacingMM * 2))

        #expect(coarse.geometry.columnSpacingMM == volume.geometry.columnSpacingMM * 2)
        #expect(coarse.geometry.columnCount < volume.geometry.columnCount)
    }

    @Test("Su un volume anisotropo si ricampiona, perché è quel che serve")
    func anAnisotropicVolumeIsResampled() throws {
        // Il passo isotropo richiesto ne pareggia due assi su tre: lungo il terzo il volume va
        // davvero ricostruito, e prendere la strada della copia darebbe fette alla quota
        // sbagliata.
        let orientation = try #require(SliceOrientation.standardAxial)
        let geometry = try VolumeGeometry(
            columnCount: 16, rowCount: 16, sliceCount: 8,
            columnSpacingMM: 0.25, rowSpacingMM: 0.25, sliceSpacingMM: 0.5,
            orientation: orientation, originMM: .zero)
        let volume = try Volume(
            geometry: geometry,
            samples: (0..<geometry.voxelCount).map { Int16(truncatingIfNeeded: $0) })

        let resampled = try VolumeResampler.resampled(
            volume, request: ResampleRequest(spacingMM: 0.25))
        #expect(resampled.geometry.sliceSpacingMM == 0.25)
        // Il numero di fette raddoppia: se avesse copiato, sarebbe rimasto otto.
        #expect(resampled.geometry.sliceCount > geometry.sliceCount)
    }

    @Test("Senza regione il ritaglio è il volume intero, identico")
    func withoutARegionTheWholeVolumeComesBackUnchanged() throws {
        let volume = try awkwardVolume()
        let same = try VolumeResampler.resampled(
            volume, request: ResampleRequest(spacingMM: volume.geometry.columnSpacingMM))

        #expect(same.geometry.columnCount == volume.geometry.columnCount)
        #expect(same.geometry.rowCount == volume.geometry.rowCount)
        #expect(same.geometry.sliceCount == volume.geometry.sliceCount)
        #expect(same.samples == volume.samples)
        #expect(
            same.geometry.originMM.isApproximatelyEqual(
                to: volume.geometry.originMM, tolerance: 1e-9))
    }
}
