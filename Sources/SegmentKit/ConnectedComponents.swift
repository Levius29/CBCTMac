import Foundation
import DICOMCore

/// Riassunto geometrico di una componente connessa rietichettata.
public struct ComponentSummary: Hashable, Sendable {
    /// Etichetta assegnata alla componente nel risultato.
    public let label: SegmentLabel
    /// Numero di voxel che appartengono alla componente.
    public let voxelCount: Int
    /// Volume fisico occupato dalla componente, in millimetri cubi.
    public let volumeMM3: Double
    /// Baricentro dei centri voxel in coordinate Patient.
    public let centroidMM: Vec3
    /// Riquadro allineato agli assi Patient dei centri voxel della componente.
    public let boundsMM: BoxMM

    /// Crea un riassunto completo per una componente già analizzata.
    public init(
        label: SegmentLabel,
        voxelCount: Int,
        volumeMM3: Double,
        centroidMM: Vec3,
        boundsMM: BoxMM
    ) {
        self.label = label
        self.voxelCount = voxelCount
        self.volumeMM3 = volumeMM3
        self.centroidMM = centroidMM
        self.boundsMM = boundsMM
    }
}

/// Operazioni iterative sulle isole di voxel non di sfondo.
public enum ConnectedComponents: Sendable {
    /// Rietichetta ogni isola con un'etichetta distinta in ordine di volume decrescente.
    ///
    /// Le componenti ignorano la label originale: qualunque valore non zero è primo piano.
    /// La scoperta usa un bitset e una pila esplicita per non consumare lo stack di chiamata su
    /// volumi grandi; le sole prime 255 isole restano rappresentabili da `SegmentLabel`.
    public static func label(
        _ mask: VolumeMask, connectivity: Connectivity = .faces
    ) throws -> (mask: VolumeMask, components: [ComponentSummary], discarded: Int) {
        var bestComponents = ComponentMinHeap(capacity: Int(SegmentLabel.max))
        let componentCount = try visitComponents(in: mask, connectivity: connectivity) { component in
            bestComponents.insert(component)
        }
        let kept = bestComponents.elements.sorted { isBetter($0, than: $1) }
        var relabeled = try emptyMask(geometry: mask.geometry)
        var summaries = [ComponentSummary]()
        summaries.reserveCapacity(kept.count)

        for (offset, component) in kept.enumerated() {
            let componentLabel = SegmentLabel(offset + 1)
            try paint(
                componentStartingAt: component.seedIndex,
                source: mask,
                into: &relabeled,
                replacementLabel: componentLabel,
                connectivity: connectivity
            )
            summaries.append(ComponentSummary(
                label: componentLabel,
                voxelCount: component.voxelCount,
                volumeMM3: component.volumeMM3,
                centroidMM: component.centroidMM,
                boundsMM: component.boundsMM
            ))
        }
        return (relabeled, summaries, componentCount - kept.count)
    }

    /// Conserva le `count` componenti maggiori mantenendo le etichette originali dei voxel.
    ///
    /// La capacità delle label limita soltanto `label`: qui un heap conserva al massimo i `count`
    /// candidati migliori, perciò anche maschere con più di 255 isole vengono considerate interamente.
    public static func keepingLargest(
        _ mask: VolumeMask, count: Int, connectivity: Connectivity = .faces
    ) throws -> VolumeMask {
        guard count >= 0 else { throw SegmentKitError.invalidComponentCount(count) }
        guard count > 0 else { return try emptyMask(geometry: mask.geometry) }

        let foregroundVoxelCount = mask.labels.reduce(into: 0) { count, label in
            if label != VolumeMask.background { count += 1 }
        }
        guard count < foregroundVoxelCount else { return mask }

        var bestComponents = ComponentMinHeap(capacity: count)
        let componentCount = try visitComponents(in: mask, connectivity: connectivity) { component in
            bestComponents.insert(component)
        }
        guard count < componentCount else { return mask }

        var filtered = try emptyMask(geometry: mask.geometry)
        for component in bestComponents.elements {
            try paint(
                componentStartingAt: component.seedIndex,
                source: mask,
                into: &filtered,
                replacementLabel: nil,
                connectivity: connectivity
            )
        }
        return filtered
    }

    /// Rimuove le componenti il cui volume fisico è inferiore alla soglia inclusa.
    ///
    /// Ogni isola viene misurata una volta e, se supera la soglia, dipinta dal solo seme con una
    /// seconda visita. Non si conservano tutti i suoi indici e le label originali restano intatte.
    public static func removingSmaller(
        than volumeMM3: Double, from mask: VolumeMask, connectivity: Connectivity = .faces
    ) throws -> VolumeMask {
        guard volumeMM3.isFinite, volumeMM3 >= 0 else {
            throw SegmentKitError.invalidMinimumComponentVolumeMM3(volumeMM3)
        }
        guard volumeMM3 > 0 else { return mask }

        var filtered = try emptyMask(geometry: mask.geometry)
        _ = try visitComponents(in: mask, connectivity: connectivity) { component in
            guard component.volumeMM3 >= volumeMM3 else { return }
            try paint(
                componentStartingAt: component.seedIndex,
                source: mask,
                into: &filtered,
                replacementLabel: nil,
                connectivity: connectivity
            )
        }
        return filtered
    }

    /// Visita tutte le isole e conserva soltanto il bitset globale e la pila della visita corrente.
    private static func visitComponents(
        in mask: VolumeMask,
        connectivity: Connectivity,
        body: (DiscoveredComponent) throws -> Void
    ) throws -> Int {
        let geometry = mask.geometry
        let totalVoxelCount = mask.labels.count
        var visited = [UInt64](repeating: 0, count: (totalVoxelCount + 63) / 64)
        var stack = [Int32]()
        stack.reserveCapacity(Swift.min(totalVoxelCount, 65_536))
        let offsets = connectivity == .faces ? regionFaceOffsets : regionFullOffsets
        let voxelVolume = geometry.columnSpacingMM * geometry.rowSpacingMM * geometry.sliceSpacingMM
        var componentCount = 0

        for seedIndex in mask.labels.indices where mask.labels[seedIndex] != VolumeMask.background {
            guard !isMarked(seedIndex, in: visited) else { continue }
            stack.removeAll(keepingCapacity: true)
            try push(seedIndex, onto: &stack, marking: &visited)

            var voxelCount = 0
            var sum = Vec3.zero
            var minimum: Vec3?
            var maximum: Vec3?
            while let current32 = stack.popLast() {
                let current = Int(current32)
                let voxel = voxelCoordinates(index: current, geometry: geometry)
                let point = geometry.patientPoint(i: voxel.i, j: voxel.j, k: voxel.k)
                voxelCount += 1
                sum += point
                minimum = componentMinimum(minimum, point)
                maximum = componentMaximum(maximum, point)
                try appendUnvisitedForegroundNeighbors(
                    of: voxel,
                    source: mask,
                    offsets: offsets,
                    visited: &visited,
                    stack: &stack
                )
            }

            guard let minimum, let maximum else { throw SegmentKitError.maskAllocationFailed }
            componentCount += 1
            try body(DiscoveredComponent(
                seedIndex: seedIndex,
                voxelCount: voxelCount,
                volumeMM3: Double(voxelCount) * voxelVolume,
                centroidMM: sum / Double(voxelCount),
                boundsMM: BoxMM(minMM: minimum, maxMM: maximum)
            ))
        }
        return componentCount
    }

    /// Dipinge una componente marcando la destinazione al push, così ogni voxel entra una sola volta.
    private static func paint(
        componentStartingAt seedIndex: Int,
        source: VolumeMask,
        into destination: inout VolumeMask,
        replacementLabel: SegmentLabel?,
        connectivity: Connectivity
    ) throws {
        let geometry = source.geometry
        let offsets = connectivity == .faces ? regionFaceOffsets : regionFullOffsets
        var stack = [Int32]()
        stack.reserveCapacity(Swift.min(source.labels.count, 65_536))
        guard let seed32 = Int32(exactly: seedIndex) else {
            throw SegmentKitError.maskAllocationFailed
        }
        let seed = voxelCoordinates(index: seedIndex, geometry: geometry)
        destination.setLabel(replacementLabel ?? source.labels[seedIndex], i: seed.i, j: seed.j, k: seed.k)
        stack.append(seed32)

        while let current32 = stack.popLast() {
            let current = Int(current32)
            let voxel = voxelCoordinates(index: current, geometry: geometry)
            for offset in offsets {
                let i = voxel.i + offset.i
                let j = voxel.j + offset.j
                let k = voxel.k + offset.k
                guard i >= 0, i < geometry.columnCount,
                      j >= 0, j < geometry.rowCount,
                      k >= 0, k < geometry.sliceCount
                else { continue }
                let neighbor = (k * geometry.rowCount + j) * geometry.columnCount + i
                guard source.labels[neighbor] != VolumeMask.background,
                      destination.labels[neighbor] == VolumeMask.background,
                      let neighbor32 = Int32(exactly: neighbor)
                else { continue }
                destination.setLabel(
                    replacementLabel ?? source.labels[neighbor], i: i, j: j, k: k
                )
                stack.append(neighbor32)
            }
        }
    }

    private static func appendUnvisitedForegroundNeighbors(
        of voxel: (i: Int, j: Int, k: Int),
        source: VolumeMask,
        offsets: [RegionOffset],
        visited: inout [UInt64],
        stack: inout [Int32]
    ) throws {
        let geometry = source.geometry
        for offset in offsets {
            let i = voxel.i + offset.i
            let j = voxel.j + offset.j
            let k = voxel.k + offset.k
            guard i >= 0, i < geometry.columnCount,
                  j >= 0, j < geometry.rowCount,
                  k >= 0, k < geometry.sliceCount
            else { continue }
            let neighbor = (k * geometry.rowCount + j) * geometry.columnCount + i
            guard source.labels[neighbor] != VolumeMask.background,
                  !isMarked(neighbor, in: visited)
            else { continue }
            try push(neighbor, onto: &stack, marking: &visited)
        }
    }

    private static func componentMinimum(_ current: Vec3?, _ point: Vec3) -> Vec3 {
        guard let current else { return point }
        return Vec3(
            Swift.min(current.x, point.x),
            Swift.min(current.y, point.y),
            Swift.min(current.z, point.z)
        )
    }

    private static func componentMaximum(_ current: Vec3?, _ point: Vec3) -> Vec3 {
        guard let current else { return point }
        return Vec3(
            Swift.max(current.x, point.x),
            Swift.max(current.y, point.y),
            Swift.max(current.z, point.z)
        )
    }

    private static func isMarked(_ index: Int, in bitset: [UInt64]) -> Bool {
        let word = index / 64
        let bit = UInt64(index % 64)
        return bitset[word] & (UInt64(1) << bit) != 0
    }

    private static func push(
        _ index: Int,
        onto stack: inout [Int32],
        marking bitset: inout [UInt64]
    ) throws {
        guard let index32 = Int32(exactly: index) else {
            throw SegmentKitError.maskAllocationFailed
        }
        let word = index / 64
        let bit = UInt64(index % 64)
        bitset[word] |= UInt64(1) << bit
        stack.append(index32)
    }

    private static func isBetter(
        _ first: DiscoveredComponent,
        than second: DiscoveredComponent
    ) -> Bool {
        if first.voxelCount != second.voxelCount { return first.voxelCount > second.voxelCount }
        return first.seedIndex < second.seedIndex
    }

    private static func isWorse(
        _ first: DiscoveredComponent,
        than second: DiscoveredComponent
    ) -> Bool {
        if first.voxelCount != second.voxelCount { return first.voxelCount < second.voxelCount }
        return first.seedIndex > second.seedIndex
    }

    private static func emptyMask(geometry: VolumeGeometry) throws -> VolumeMask {
        guard let mask = VolumeMask(geometry: geometry) else {
            throw SegmentKitError.maskAllocationFailed
        }
        return mask
    }

    /// Min-heap con in radice il candidato peggiore: volume minore, poi seme maggiore.
    private struct ComponentMinHeap {
        let capacity: Int
        private(set) var elements: [DiscoveredComponent]

        init(capacity: Int) {
            self.capacity = capacity
            self.elements = []
            self.elements.reserveCapacity(Swift.min(capacity, 65_536))
        }

        mutating func insert(_ candidate: DiscoveredComponent) {
            guard capacity > 0 else { return }
            if elements.count < capacity {
                elements.append(candidate)
                siftUp(from: elements.count - 1)
            } else if let worst = elements.first, ConnectedComponents.isBetter(candidate, than: worst) {
                elements[0] = candidate
                siftDown(from: 0)
            }
        }

        private mutating func siftUp(from start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard ConnectedComponents.isWorse(elements[child], than: elements[parent]) else {
                    return
                }
                elements.swapAt(child, parent)
                child = parent
            }
        }

        private mutating func siftDown(from start: Int) {
            var parent = start
            while true {
                let left = parent * 2 + 1
                guard left < elements.count else { return }
                let right = left + 1
                var worseChild = left
                if right < elements.count,
                   ConnectedComponents.isWorse(elements[right], than: elements[left]) {
                    worseChild = right
                }
                guard ConnectedComponents.isWorse(elements[worseChild], than: elements[parent]) else {
                    return
                }
                elements.swapAt(parent, worseChild)
                parent = worseChild
            }
        }
    }
}

private struct DiscoveredComponent: Sendable {
    let seedIndex: Int
    let voxelCount: Int
    let volumeMM3: Double
    let centroidMM: Vec3
    let boundsMM: BoxMM
}
