import Foundation
import DICOMCore

/// Operazioni morfologiche su maschere multietichetta con raggio espresso in millimetri.
///
/// L'implementazione usa tre passate 1D separabili, perciò l'elemento strutturante effettivo è
/// un parallelepipedo anisotropo e non una sfera o un ellissoide. L'approssimazione è adeguata a
/// coprire la penombra attorno al metallo, ma non a definire superfici destinate alla stampa.
public enum Morphology: Sendable {
    /// Dilata ogni etichetta con raggi voxel ricavati separatamente dalle tre spaziature.
    ///
    /// Un voxel già etichettato conserva la propria etichetta. Per i voxel nuovi si seleziona la
    /// provenienza originale fisicamente più vicina; a uguale distanza vince l'etichetta minore e
    /// poi l'indice sorgente minore.
    public static func dilated(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask {
        let radii = try voxelRadii(for: mask.geometry, radiusMM: radius)
        guard radii != .zero else { return mask }

        var provenance = try originalProvenance(for: mask.labels)
        propagateDilation(
            &provenance, originalLabels: mask.labels, geometry: mask.geometry, axis: .x, radius: radii.x
        )
        propagateDilation(
            &provenance, originalLabels: mask.labels, geometry: mask.geometry, axis: .y, radius: radii.y
        )
        propagateDilation(
            &provenance, originalLabels: mask.labels, geometry: mask.geometry, axis: .z, radius: radii.z
        )
        return try makeMask(
            geometry: mask.geometry, labels: labels(from: provenance, originalLabels: mask.labels)
        )
    }

    /// Erode ogni etichetta: il centro resta solo se tutta la finestra appartiene alla stessa etichetta.
    ///
    /// I voxel oltre il bordo del volume sono sfondo, quindi erodono correttamente le strutture che
    /// toccano il margine del volume.
    public static func eroded(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask {
        let radii = try voxelRadii(for: mask.geometry, radiusMM: radius)
        guard radii != .zero else { return mask }

        var result = mask.labels
        result = eroded(result, geometry: mask.geometry, axis: .x, radius: radii.x)
        result = eroded(result, geometry: mask.geometry, axis: .y, radius: radii.y)
        result = eroded(result, geometry: mask.geometry, axis: .z, radius: radii.z)
        return try makeMask(geometry: mask.geometry, labels: result)
    }

    // non-ancora-collegato: la segmentazione offre chiusura e dilatazione, che sono ciò che
    // serve a rimarginare una corticale interrotta. L'apertura toglie i granelli, e i granelli
    // su una CBCT dentale sono quasi sempre osso vero e sottile: toglierli è più spesso un
    // danno che una pulizia, e va offerto quando ci sarà da regolarne il raggio guardando.
    /// Applica erosione e poi dilatazione, rimuovendo i granelli più piccoli del raggio richiesto.
    public static func opened(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask {
        try dilated(eroded(mask, byMM: radius), byMM: radius)
    }

    /// Applica dilatazione e poi erosione, chiudendo piccoli buchi nella stessa etichetta.
    public static func closed(_ mask: VolumeMask, byMM radius: Double) throws -> VolumeMask {
        try eroded(dilated(mask, byMM: radius), byMM: radius)
    }

    private enum Axis: Sendable {
        case x
        case y
        case z
    }

    private struct VoxelRadii: Equatable, Sendable {
        let x: Int
        let y: Int
        let z: Int

        static let zero = VoxelRadii(x: 0, y: 0, z: 0)
    }

    private static func voxelRadii(for geometry: VolumeGeometry, radiusMM: Double) throws -> VoxelRadii {
        guard radiusMM.isFinite, radiusMM >= 0 else {
            throw SegmentKitError.invalidMorphologyRadiusMM(radiusMM)
        }
        return VoxelRadii(
            x: try radiusInVoxels(radiusMM, spacingMM: geometry.columnSpacingMM, dimension: geometry.columnCount),
            y: try radiusInVoxels(radiusMM, spacingMM: geometry.rowSpacingMM, dimension: geometry.rowCount),
            z: try radiusInVoxels(radiusMM, spacingMM: geometry.sliceSpacingMM, dimension: geometry.sliceCount)
        )
    }

    private static func radiusInVoxels(_ radiusMM: Double, spacingMM: Double, dimension: Int) throws -> Int {
        guard spacingMM.isFinite, spacingMM > 0, dimension > 0 else {
            throw SegmentKitError.invalidMorphologyRadiusMM(radiusMM)
        }
        // Un raggio pari alla dimensione è il limite sicuro della finestra. Per l'erosione è
        // importante anche su una dimensione di un solo voxel: il fuori-volume è sfondo.
        let maximumRadius = dimension
        guard maximumRadius > 0, radiusMM > 0 else { return 0 }

        let clampThreshold = Double(maximumRadius) * spacingMM
        if radiusMM >= clampThreshold {
            return maximumRadius
        }
        let voxelRadius = ceil(radiusMM / spacingMM)
        guard voxelRadius.isFinite,
              voxelRadius >= 0,
              voxelRadius <= Double(maximumRadius),
              let converted = Int(exactly: voxelRadius) else {
            throw SegmentKitError.invalidMorphologyRadiusMM(radiusMM)
        }
        return converted
    }

    /// Inizializza una provenienza per ogni voxel non di sfondo. Il limite di `VolumeMask` è molto
    /// sotto `Int32.max`, ma la conversione esplicita impedisce che un futuro aumento del limite
    /// trasformi silenziosamente un indice in una provenienza negativa.
    private static func originalProvenance(for labels: [SegmentLabel]) throws -> [Int32] {
        var provenance = [Int32](repeating: -1, count: labels.count)
        for index in labels.indices where labels[index] != VolumeMask.background {
            guard let sourceIndex = Int32(exactly: index) else {
                throw SegmentKitError.maskAllocationFailed
            }
            provenance[index] = sourceIndex
        }
        return provenance
    }

    /// Propaga indici del voxel originale, non etichette già espanse.
    ///
    /// Ogni linea usa uno snapshot prima degli aggiornamenti in-place. Così la migliore
    /// provenienza resta quella del voxel iniziale e il confronto fisico completo elimina la
    /// dipendenza dall'ordine X/Y/Z senza enumerare cubi di raggio `r³`.
    private static func propagateDilation(
        _ provenance: inout [Int32],
        originalLabels: [SegmentLabel],
        geometry: VolumeGeometry,
        axis: Axis,
        radius: Int
    ) {
        guard radius > 0 else { return }
        forEachLine(in: geometry, axis: axis) { start, stride, length in
            var snapshot = [Int32]()
            snapshot.reserveCapacity(length)
            for position in 0..<length {
                snapshot.append(provenance[start + position * stride])
            }
            for position in 0..<length {
                let destination = start + position * stride
                let lowerPosition = Swift.max(0, position - radius)
                let upperPosition = Swift.min(length - 1, position + radius)
                var selected: Int32 = -1
                for candidatePosition in lowerPosition...upperPosition {
                    let candidate = snapshot[candidatePosition]
                    if isPreferredProvenance(
                        candidate,
                        over: selected,
                        destination: destination,
                        originalLabels: originalLabels,
                        geometry: geometry
                    ) {
                        selected = candidate
                    }
                }
                provenance[destination] = selected
            }
        }
    }

    private static func eroded(
        _ source: [SegmentLabel], geometry: VolumeGeometry, axis: Axis, radius: Int
    ) -> [SegmentLabel] {
        guard radius > 0 else { return source }
        var result = source
        forEachLine(in: geometry, axis: axis) { start, stride, length in
            for position in 0..<length {
                let destination = start + position * stride
                let centerLabel = source[destination]
                guard centerLabel != VolumeMask.background,
                      position >= radius,
                      position + radius < length else {
                    result[destination] = VolumeMask.background
                    continue
                }

                for distance in 1...radius {
                    if source[start + (position - distance) * stride] != centerLabel
                        || source[start + (position + distance) * stride] != centerLabel {
                        result[destination] = VolumeMask.background
                        break
                    }
                }
            }
        }
        return result
    }

    private static func isPreferredProvenance(
        _ candidate: Int32,
        over current: Int32,
        destination: Int,
        originalLabels: [SegmentLabel],
        geometry: VolumeGeometry
    ) -> Bool {
        guard candidate >= 0 else { return false }
        guard current >= 0 else { return true }
        guard let candidateIndex = Int(exactly: candidate), let currentIndex = Int(exactly: current) else {
            return false
        }
        let candidateDistance = squaredPhysicalDistance(
            from: candidateIndex, to: destination, geometry: geometry
        )
        let currentDistance = squaredPhysicalDistance(from: currentIndex, to: destination, geometry: geometry)
        if candidateDistance != currentDistance { return candidateDistance < currentDistance }

        let candidateLabel = originalLabels[candidateIndex]
        let currentLabel = originalLabels[currentIndex]
        if candidateLabel != currentLabel { return candidateLabel < currentLabel }
        return candidateIndex < currentIndex
    }

    private static func squaredPhysicalDistance(
        from origin: Int, to destination: Int, geometry: VolumeGeometry
    ) -> Double {
        let source = voxelCoordinates(index: origin, geometry: geometry)
        let target = voxelCoordinates(index: destination, geometry: geometry)
        let x = Double(target.i - source.i) * geometry.columnSpacingMM
        let y = Double(target.j - source.j) * geometry.rowSpacingMM
        let z = Double(target.k - source.k) * geometry.sliceSpacingMM
        return x * x + y * y + z * z
    }

    private static func labels(from provenance: [Int32], originalLabels: [SegmentLabel]) -> [SegmentLabel] {
        var result = [SegmentLabel](repeating: VolumeMask.background, count: provenance.count)
        for index in result.indices {
            if originalLabels[index] != VolumeMask.background {
                result[index] = originalLabels[index]
            } else if provenance[index] >= 0,
                      let sourceIndex = Int(exactly: provenance[index]),
                      sourceIndex < originalLabels.count {
                result[index] = originalLabels[sourceIndex]
            }
        }
        return result
    }

    private static func forEachLine(
        in geometry: VolumeGeometry,
        axis: Axis,
        _ body: (Int, Int, Int) -> Void
    ) {
        let columns = geometry.columnCount
        let rows = geometry.rowCount
        let slices = geometry.sliceCount
        let planeSize = columns * rows

        switch axis {
        case .x:
            for k in 0..<slices {
                for j in 0..<rows {
                    body((k * rows + j) * columns, 1, columns)
                }
            }
        case .y:
            for k in 0..<slices {
                for i in 0..<columns {
                    body(k * planeSize + i, columns, rows)
                }
            }
        case .z:
            for j in 0..<rows {
                for i in 0..<columns {
                    body(j * columns + i, planeSize, slices)
                }
            }
        }
    }

    private static func makeMask(geometry: VolumeGeometry, labels: [SegmentLabel]) throws -> VolumeMask {
        guard let result = VolumeMask(geometry: geometry, labels: labels) else {
            throw SegmentKitError.maskAllocationFailed
        }
        return result
    }
}
