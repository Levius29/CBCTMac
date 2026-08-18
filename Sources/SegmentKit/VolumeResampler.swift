import Foundation
import DICOMCore

/// Richiesta immutabile nei suoi significati fisici per ricampionare un volume.
public struct ResampleRequest: Hashable, Sendable {
    /// Passo isotropo richiesto, in millimetri.
    public var spacingMM: Double
    /// Regione da ricampionare; `nil` indica l'intero volume.
    public var regionMM: BoxMM?
    /// Limite oltre il quale la richiesta viene rifiutata prima dell'allocazione.
    ///
    /// Predefinito uguale a quello delle maschere, e per la stessa ragione: era un numero fisso
    /// che ignorava la macchina, e su una CBCT a campo grande rifiutava un lavoro che la memoria
    /// disponibile avrebbe retto senza sforzo. Vedi `VolumeMask.maximumVoxelCount`.
    public var maximumVoxelCount: Int

    /// Costruisce una richiesta; la validazione avviene prima di calcolare o allocare l'uscita.
    public init(
        spacingMM: Double,
        regionMM: BoxMM? = nil,
        maximumVoxelCount: Int = VolumeMask.maximumVoxelCount
    ) {
        self.spacingMM = spacingMM
        self.regionMM = regionMM
        self.maximumVoxelCount = maximumVoxelCount
    }
}

/// Errori specifici del ricampionamento volumetrico.
public enum ResampleError: Error, Hashable, Sendable, LocalizedError {
    case invalidSpacing(Double)
    case emptyRegion
    case tooManyVoxels(requested: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidSpacing(let spacing):
            return "Il passo di ricampionamento non è valido: \(spacing) mm."
        case .emptyRegion:
            return "La regione richiesta non interseca il volume con un'estensione positiva."
        case .tooManyVoxels(let requested, let limit):
            return "Il ricampionamento richiede \(requested) voxel e supera il limite di \(limit)."
        }
    }
}

/// Ricampionamento CPU portabile che conserva lo spazio Patient del volume.
public enum VolumeResampler: Sendable {
    /// Passi proposti per l'interfaccia, dal più fine al più grossolano.
    public static let spacingPresetsMM: [Double] = [
        0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1.0,
    ]

    /// Produce un nuovo volume isotropo, eventualmente limitato a un riquadro Patient.
    public static func resampled(
        _ volume: Volume,
        request: ResampleRequest
    ) throws -> Volume {
        guard request.spacingMM.isFinite, request.spacingMM > 0 else {
            throw ResampleError.invalidSpacing(request.spacingMM)
        }
        let bounds = try sourceBounds(
            for: request.regionMM,
            geometry: volume.geometry
        )
        let layout = try outputLayout(
            bounds: bounds,
            sourceGeometry: volume.geometry,
            spacingMM: request.spacingMM,
            maximumVoxelCount: request.maximumVoxelCount
        )

        // L'origine nasce da una proiezione voxel→Patient. Sommare spaziature alle coordinate
        // Patient funzionerebbe soltanto con assi standard e traslerebbe silenziosamente gli
        // studi ruotati, pur lasciando l'immagine visivamente plausibile.
        let originMM = volume.geometry.patientPoint(fromVoxel: layout.firstCentreVoxel)
        let geometry = try VolumeGeometry(
            columnCount: layout.columns,
            rowCount: layout.rows,
            sliceCount: layout.slices,
            columnSpacingMM: request.spacingMM,
            rowSpacingMM: request.spacingMM,
            sliceSpacingMM: request.spacingMM,
            orientation: volume.geometry.orientation,
            originMM: originMM
        )

        var samples = [Int16]()
        samples.reserveCapacity(layout.voxelCount)
        for k in 0..<geometry.sliceCount {
            for j in 0..<geometry.rowCount {
                for i in 0..<geometry.columnCount {
                    let point = geometry.patientPoint(i: i, j: j, k: k)
                    let density = averagedDensity(
                        source: volume,
                        atPatient: point,
                        targetSpacingMM: request.spacingMM
                    )
                    samples.append(rawSample(fromDensity: density, volume: volume))
                }
            }
        }
        return try Volume(
            geometry: geometry,
            samples: samples,
            rescaleSlope: volume.rescaleSlope,
            rescaleIntercept: volume.rescaleIntercept,
            densityUnit: volume.densityUnit
        )
    }

    private static func sourceBounds(
        for region: BoxMM?,
        geometry: VolumeGeometry
    ) throws -> VoxelResampleBounds {
        let volumeMinimum = Vec3(-0.5, -0.5, -0.5)
        let volumeMaximum = Vec3(
            Double(geometry.columnCount) - 0.5,
            Double(geometry.rowCount) - 0.5,
            Double(geometry.sliceCount) - 0.5
        )
        guard let region else {
            return VoxelResampleBounds(minimum: volumeMinimum, maximum: volumeMaximum)
        }
        guard region.minMM.isFinite, region.maxMM.isFinite,
              region.minMM.x <= region.maxMM.x,
              region.minMM.y <= region.maxMM.y,
              region.minMM.z <= region.maxMM.z
        else { throw ResampleError.emptyRegion }

        var minimum = Vec3(Double.infinity, Double.infinity, Double.infinity)
        var maximum = Vec3(-Double.infinity, -Double.infinity, -Double.infinity)
        for patient in patientCorners(of: region) {
            let voxel = geometry.voxelPoint(fromPatient: patient)
            guard voxel.isFinite else { throw ResampleError.emptyRegion }
            minimum = Vec3(
                min(minimum.x, voxel.x),
                min(minimum.y, voxel.y),
                min(minimum.z, voxel.z)
            )
            maximum = Vec3(
                max(maximum.x, voxel.x),
                max(maximum.y, voxel.y),
                max(maximum.z, voxel.z)
            )
        }
        minimum = Vec3(
            max(minimum.x, volumeMinimum.x),
            max(minimum.y, volumeMinimum.y),
            max(minimum.z, volumeMinimum.z)
        )
        maximum = Vec3(
            min(maximum.x, volumeMaximum.x),
            min(maximum.y, volumeMaximum.y),
            min(maximum.z, volumeMaximum.z)
        )
        guard maximum.x > minimum.x,
              maximum.y > minimum.y,
              maximum.z > minimum.z
        else { throw ResampleError.emptyRegion }
        return VoxelResampleBounds(minimum: minimum, maximum: maximum)
    }

    private static func outputLayout(
        bounds: VoxelResampleBounds,
        sourceGeometry: VolumeGeometry,
        spacingMM: Double,
        maximumVoxelCount: Int
    ) throws -> ResampleLayout {
        let extentMM = Vec3(
            (bounds.maximum.x - bounds.minimum.x) * sourceGeometry.columnSpacingMM,
            (bounds.maximum.y - bounds.minimum.y) * sourceGeometry.rowSpacingMM,
            (bounds.maximum.z - bounds.minimum.z) * sourceGeometry.sliceSpacingMM
        )
        guard let columns = outputCount(extentMM.x, spacingMM: spacingMM),
              let rows = outputCount(extentMM.y, spacingMM: spacingMM),
              let slices = outputCount(extentMM.z, spacingMM: spacingMM)
        else {
            throw ResampleError.tooManyVoxels(
                requested: Int.max,
                limit: maximumVoxelCount
            )
        }
        guard let voxelCount = checkedProduct(columns, rows, slices) else {
            throw ResampleError.tooManyVoxels(
                requested: Int.max,
                limit: maximumVoxelCount
            )
        }
        guard voxelCount <= maximumVoxelCount else {
            throw ResampleError.tooManyVoxels(
                requested: voxelCount,
                limit: maximumVoxelCount
            )
        }

        // Il surplus di copertura viene diviso sui due lati. Così ogni nuovo centro resta dentro
        // la regione sorgente anche quando la sua estensione non è multipla del nuovo passo.
        let excessX = Double(columns) * spacingMM - extentMM.x
        let excessY = Double(rows) * spacingMM - extentMM.y
        let excessZ = Double(slices) * spacingMM - extentMM.z
        let firstCentre = Vec3(
            bounds.minimum.x + (spacingMM - excessX) / (2 * sourceGeometry.columnSpacingMM),
            bounds.minimum.y + (spacingMM - excessY) / (2 * sourceGeometry.rowSpacingMM),
            bounds.minimum.z + (spacingMM - excessZ) / (2 * sourceGeometry.sliceSpacingMM)
        )
        return ResampleLayout(
            columns: columns,
            rows: rows,
            slices: slices,
            voxelCount: voxelCount,
            firstCentreVoxel: firstCentre
        )
    }

    private static func outputCount(_ extentMM: Double, spacingMM: Double) -> Int? {
        let value = ceil(extentMM / spacingMM)
        guard value.isFinite, value >= 1, value <= Double(Int.max) else { return nil }
        return Int(exactly: value)
    }

    private static func checkedProduct(_ columns: Int, _ rows: Int, _ slices: Int) -> Int? {
        let (plane, planeOverflow) = columns.multipliedReportingOverflow(by: rows)
        guard !planeOverflow else { return nil }
        let (count, countOverflow) = plane.multipliedReportingOverflow(by: slices)
        return countOverflow ? nil : count
    }

    private static func averagedDensity(
        source: Volume,
        atPatient point: Vec3,
        targetSpacingMM: Double
    ) -> Double {
        let geometry = source.geometry
        let centre = geometry.voxelPoint(fromPatient: point)
        let downsamplesColumns = targetSpacingMM > geometry.columnSpacingMM
        let downsamplesRows = targetSpacingMM > geometry.rowSpacingMM
        let downsamplesSlices = targetSpacingMM > geometry.sliceSpacingMM
        if !downsamplesColumns, !downsamplesRows, !downsamplesSlices {
            return densityWithSafeEdgeFallback(source: source, patient: point)
        }
        // Su ogni asse più grossolano la cella ha raggio `targetSpacingMM / 2`. I voxel sorgente
        // sono pesati per la porzione della loro cella che vi ricade: ignorare la sovrapposizione
        // parziale sposterebbe la densità con rapporti non interi. È il filtro box minimo che
        // evita l'aliasing del semplice campionamento puntuale.
        let columns = samplingCoordinates(
            centre: centre.x,
            targetSpacingMM: targetSpacingMM,
            sourceSpacingMM: geometry.columnSpacingMM,
            count: geometry.columnCount
        )
        let rows = samplingCoordinates(
            centre: centre.y,
            targetSpacingMM: targetSpacingMM,
            sourceSpacingMM: geometry.rowSpacingMM,
            count: geometry.rowCount
        )
        let slices = samplingCoordinates(
            centre: centre.z,
            targetSpacingMM: targetSpacingMM,
            sourceSpacingMM: geometry.sliceSpacingMM,
            count: geometry.sliceCount
        )

        var total = 0.0
        var totalWeight = 0.0
        for k in slices {
            for j in rows {
                for i in columns {
                    let patient = geometry.patientPoint(
                        fromVoxel: Vec3(i.coordinate, j.coordinate, k.coordinate)
                    )
                    if let density = source.interpolatedDensityValue(atPatient: patient) {
                        let weight = i.weight * j.weight * k.weight
                        total += density * weight
                        totalWeight += weight
                    }
                }
            }
        }
        guard totalWeight > 0 else {
            return densityWithSafeEdgeFallback(source: source, patient: point)
        }
        return total / totalWeight
    }

    private static func samplingCoordinates(
        centre: Double,
        targetSpacingMM: Double,
        sourceSpacingMM: Double,
        count: Int
    ) -> [WeightedCoordinate] {
        guard targetSpacingMM > sourceSpacingMM else {
            return [WeightedCoordinate(coordinate: centre, weight: 1)]
        }
        let radius = targetSpacingMM / (2 * sourceSpacingMM)
        let cellMinimum = centre - radius
        let cellMaximum = centre + radius
        let lowerDouble = floor(cellMinimum + 0.5)
        let upperDouble = ceil(cellMaximum + 0.5)
        guard lowerDouble.isFinite, upperDouble.isFinite else {
            return [WeightedCoordinate(coordinate: centre, weight: 1)]
        }
        let clampedLower = max(0, min(Double(count), lowerDouble))
        let clampedUpper = max(0, min(Double(count), upperDouble))
        guard let lower = Int(exactly: clampedLower),
              let upper = Int(exactly: clampedUpper),
              lower < upper
        else { return [WeightedCoordinate(coordinate: centre, weight: 1)] }
        var coordinates = [WeightedCoordinate]()
        coordinates.reserveCapacity(upper - lower)
        for index in lower..<upper {
            let voxelMinimum = Double(index) - 0.5
            let voxelMaximum = Double(index) + 0.5
            let overlap = min(cellMaximum, voxelMaximum) - max(cellMinimum, voxelMinimum)
            if overlap > 0 {
                coordinates.append(
                    WeightedCoordinate(coordinate: Double(index), weight: overlap)
                )
            }
        }
        if coordinates.isEmpty {
            return [WeightedCoordinate(coordinate: centre, weight: 1)]
        }
        return coordinates
    }

    private static func densityWithSafeEdgeFallback(
        source: Volume,
        patient: Vec3
    ) -> Double {
        if let density = source.interpolatedDensityValue(atPatient: patient) { return density }
        let voxel = source.geometry.voxelPoint(fromPatient: patient)
        let i = nearestClamped(voxel.x, count: source.geometry.columnCount)
        let j = nearestClamped(voxel.y, count: source.geometry.rowCount)
        let k = nearestClamped(voxel.z, count: source.geometry.sliceCount)
        if let density = source.densityValue(i: i, j: j, k: k) { return density }
        return source.applyRescale(source.samples.first ?? 0)
    }

    private static func nearestClamped(_ value: Double, count: Int) -> Int {
        guard value.isFinite else { return 0 }
        let clamped = min(Double(count - 1), max(0, value.rounded()))
        return Int(exactly: clamped) ?? 0
    }

    private static func rawSample(fromDensity density: Double, volume: Volume) -> Int16 {
        // Il trilineare pubblico restituisce densità già scalate, mentre `Volume.samples` deve
        // restare grezzo: omettere questa inversione applicherebbe slope/intercetta due volte.
        let raw = (density - volume.rescaleIntercept) / volume.rescaleSlope
        guard raw.isFinite else { return 0 }
        let rounded = raw.rounded()
        if rounded <= Double(Int16.min) { return Int16.min }
        if rounded >= Double(Int16.max) { return Int16.max }
        guard let integer = Int(exactly: rounded) else { return 0 }
        return Int16(clamping: integer)
    }

    private static func patientCorners(of box: BoxMM) -> [Vec3] {
        [
            Vec3(box.minMM.x, box.minMM.y, box.minMM.z),
            Vec3(box.maxMM.x, box.minMM.y, box.minMM.z),
            Vec3(box.minMM.x, box.maxMM.y, box.minMM.z),
            Vec3(box.maxMM.x, box.maxMM.y, box.minMM.z),
            Vec3(box.minMM.x, box.minMM.y, box.maxMM.z),
            Vec3(box.maxMM.x, box.minMM.y, box.maxMM.z),
            Vec3(box.minMM.x, box.maxMM.y, box.maxMM.z),
            Vec3(box.maxMM.x, box.maxMM.y, box.maxMM.z),
        ]
    }
}

private struct VoxelResampleBounds: Sendable {
    let minimum: Vec3
    let maximum: Vec3
}

private struct ResampleLayout: Sendable {
    let columns: Int
    let rows: Int
    let slices: Int
    let voxelCount: Int
    let firstCentreVoxel: Vec3
}

private struct WeightedCoordinate: Sendable {
    let coordinate: Double
    let weight: Double
}
