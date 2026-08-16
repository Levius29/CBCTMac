import Testing

@testable import DICOMCore

// Test della geometria.
//
// Coprono i Contratti 1 e 2 di docs/architecture.md. Non sono test di completezza: sono test
// dei punti in cui un errore non si vede. Una matrice trasposta, una spaziatura scambiata o un
// ordinamento sbagliato producono immagini perfettamente plausibili e misure false, e nessuno
// se ne accorge guardando lo schermo.

@Suite("Vec3 e Transform3D")
struct GeometryPrimitiveTests {

    @Test("Il prodotto vettoriale segue la regola della mano destra")
    func crossProduct() {
        let x = Vec3(1, 0, 0)
        let y = Vec3(0, 1, 0)
        #expect(x.cross(y).isApproximatelyEqual(to: Vec3(0, 0, 1)))
        #expect(y.cross(x).isApproximatelyEqual(to: Vec3(0, 0, -1)))
    }

    @Test("Il versore del vettore nullo è nil, non NaN")
    func normalizeZero() {
        #expect(Vec3.zero.normalized == nil)
    }

    @Test("L'angolo fra vettori quasi paralleli non produce NaN")
    func angleClamping() {
        // Senza il clamp dell'argomento di acos, l'arrotondamento porta il coseno oltre 1
        // e l'angolo diventa NaN. È il tipo di guasto che si manifesta solo su certi dati.
        let a = Vec3(1, 0, 0)
        let b = Vec3(1, 1e-17, 0)
        let angle = a.angle(to: b)
        #expect(angle != nil)
        #expect(angle!.isFinite)
    }

    @Test("L'inversa riporta il punto di partenza")
    func inverseRoundTrip() throws {
        let transform = Transform3D(
            columnX: Vec3(0.3, 0.1, 0),
            columnY: Vec3(-0.1, 0.4, 0.05),
            columnZ: Vec3(0, 0.02, 0.5),
            origin: Vec3(-12.5, 33.25, 7))
        let inverse = try #require(transform.inverse)

        let point = Vec3(3.75, -8.5, 22.125)
        let there = transform.apply(toPoint: point)
        let back = inverse.apply(toPoint: there)
        #expect(back.isApproximatelyEqual(to: point, tolerance: 1e-9))
    }

    @Test("Una trasformazione singolare non ha inversa")
    func singularHasNoInverse() {
        // Terza colonna complanare alle prime due: il volume è degenere.
        let degenerate = Transform3D(
            columnX: Vec3(1, 0, 0),
            columnY: Vec3(0, 1, 0),
            columnZ: Vec3(1, 1, 0),
            origin: .zero)
        #expect(degenerate.inverse == nil)
    }

    @Test("I vettori non subiscono la traslazione, i punti sì")
    func vectorsIgnoreTranslation() {
        // È la distinzione che, se sbagliata, sposta ogni misura di una costante.
        let transform = Transform3D.translation(Vec3(100, 200, 300))
        let direction = Vec3(1, 0, 0)
        #expect(transform.apply(toVector: direction).isApproximatelyEqual(to: direction))
        #expect(
            transform.apply(toPoint: direction).isApproximatelyEqual(to: Vec3(101, 200, 300)))
    }
}

@Suite("VolumeGeometry")
struct VolumeGeometryTests {

    /// Geometria anisotropica: le tre spaziature sono diverse fra loro di proposito.
    /// Su voxel isotropici uno scambio fra righe e colonne non dà alcun sintomo, ed è
    /// esattamente per questo che il test non li usa.
    private func makeAnisotropic() throws -> VolumeGeometry {
        try VolumeGeometry(
            columnCount: 10,
            rowCount: 20,
            sliceCount: 30,
            columnSpacingMM: 0.4,
            rowSpacingMM: 0.5,
            sliceSpacingMM: 0.8,
            orientation: .standardAxial,
            originMM: Vec3(-2, -5, -12))
    }

    @Test("Voxel → Patient → voxel torna al punto di partenza")
    func roundTrip() throws {
        let geometry = try makeAnisotropic()
        let voxel = Vec3(3.25, 11.5, 7.75)
        let patient = geometry.patientPoint(fromVoxel: voxel)
        let back = geometry.voxelPoint(fromPatient: patient)
        #expect(back.isApproximatelyEqual(to: voxel, tolerance: 1e-9))
    }

    @Test("Un passo di colonna usa la spaziatura delle colonne, non quella delle righe")
    func columnSpacingNotSwapped() throws {
        // Il tag PixelSpacing è [righe, colonne] e l'accoppiamento incrociato con gli assi
        // è la trappola più insidiosa del formato. Questo test è la sua rete.
        let geometry = try makeAnisotropic()
        let origin = geometry.patientPoint(i: 0, j: 0, k: 0)

        let oneColumn = geometry.patientPoint(i: 1, j: 0, k: 0)
        #expect(abs(oneColumn.distance(to: origin) - 0.4) < 1e-12)

        let oneRow = geometry.patientPoint(i: 0, j: 1, k: 0)
        #expect(abs(oneRow.distance(to: origin) - 0.5) < 1e-12)

        let oneSlice = geometry.patientPoint(i: 0, j: 0, k: 1)
        #expect(abs(oneSlice.distance(to: origin) - 0.8) < 1e-12)
    }

    @Test("La dimensione fisica tiene conto delle tre spaziature")
    func physicalSize() throws {
        let geometry = try makeAnisotropic()
        let size = geometry.physicalSizeMM
        #expect(abs(size.x - 10 * 0.4) < 1e-12)
        #expect(abs(size.y - 20 * 0.5) < 1e-12)
        #expect(abs(size.z - 30 * 0.8) < 1e-12)
    }

    @Test("Spaziature non valide vengono rifiutate")
    func rejectsInvalidSpacing() {
        #expect(throws: VolumeGeometryError.self) {
            _ = try VolumeGeometry(
                columnCount: 4, rowCount: 4, sliceCount: 4,
                columnSpacingMM: 0, rowSpacingMM: 0.5, sliceSpacingMM: 0.5,
                orientation: .standardAxial, originMM: .zero)
        }
    }

    @Test("I piani anatomici seguono la convenzione radiologica")
    func radiologicalConvention() {
        // Assiale: destra dello schermo verso sinistra del paziente (+L), basso verso
        // posteriore (+P). È ciò che mette la destra del paziente a sinistra dello schermo.
        #expect(AnatomicalPlane.axial.screenRightMM.isApproximatelyEqual(to: Vec3(1, 0, 0)))
        #expect(AnatomicalPlane.axial.screenDownMM.isApproximatelyEqual(to: Vec3(0, 1, 0)))
        // Coronale e sagittale hanno il basso verso i piedi.
        #expect(AnatomicalPlane.coronal.screenDownMM.isApproximatelyEqual(to: Vec3(0, 0, -1)))
        #expect(AnatomicalPlane.sagittal.screenDownMM.isApproximatelyEqual(to: Vec3(0, 0, -1)))
    }
}

@Suite("SliceSorter")
struct SliceSorterTests {

    /// Slice assiali equidistanti, in ordine sparso e **senza InstanceNumber**: il tipo
    /// `SliceDescriptor` non lo prevede nemmeno, perché non deve servire.
    private func descriptors(positions: [Double]) -> [SliceDescriptor] {
        positions.enumerated().map { index, z in
            SliceDescriptor(
                positionMM: Vec3(-10, -10, z),
                orientation: .standardAxial,
                sourceIndex: index)
        }
    }

    @Test("Riordina slice mescolate usando solo la posizione")
    func sortsShuffled() throws {
        // Ordine d'ingresso volutamente casuale: se il codice si appoggiasse all'ordine dei
        // file o a un numero di istanza, qui fallirebbe.
        let input = descriptors(positions: [4.0, 0.0, 2.0, 6.0])
        let result = try SliceSorter.sort(
            slices: input, columnCount: 8, rowCount: 8,
            pixelSpacingMM: (row: 0.5, column: 0.5))

        #expect(result.order == [1, 2, 0, 3])
        #expect(abs(result.geometry.sliceSpacingMM - 2.0) < 1e-12)
        // L'origine è la prima slice **dopo** l'ordinamento, non la prima dell'array.
        #expect(abs(result.geometry.originMM.z - 0.0) < 1e-12)
        #expect(result.issues.isEmpty)
    }

    @Test("Segnala la spaziatura non uniforme invece di ignorarla")
    func detectsNonUniformSpacing() throws {
        // Salto anomalo fra la terza e la quarta: sull'immagine non si vedrebbe nulla, ma
        // ogni misura lungo l'asse delle slice sarebbe sbagliata.
        let input = descriptors(positions: [0.0, 2.0, 4.0, 9.0])
        let result = try SliceSorter.sort(
            slices: input, columnCount: 8, rowCount: 8,
            pixelSpacingMM: (row: 0.5, column: 0.5))

        let hasWarning = result.issues.contains { issue in
            if case .nonUniformSpacing = issue { return true }
            return false
        }
        #expect(hasWarning)
    }

    @Test("Scarta le slice duplicate")
    func discardsDuplicates() throws {
        let input = descriptors(positions: [0.0, 2.0, 2.0, 4.0])
        let result = try SliceSorter.sort(
            slices: input, columnCount: 8, rowCount: 8,
            pixelSpacingMM: (row: 0.5, column: 0.5))

        #expect(result.order.count == 3)
        let discarded = result.issues.contains { issue in
            if case .duplicatePositions = issue { return true }
            return false
        }
        #expect(discarded)
    }

    @Test("Orientamenti incoerenti sono un errore, non un avviso")
    func rejectsMixedOrientation() {
        let tilted = SliceOrientation(
            columnDirection: Vec3(1, 0, 0), rowDirection: Vec3(0, 0.7071, 0.7071))!
        let input = [
            SliceDescriptor(positionMM: Vec3(0, 0, 0), orientation: .standardAxial, sourceIndex: 0),
            SliceDescriptor(positionMM: Vec3(0, 0, 1), orientation: tilted, sourceIndex: 1),
        ]
        #expect(throws: VolumeGeometryError.self) {
            _ = try SliceSorter.sort(
                slices: input, columnCount: 8, rowCount: 8,
                pixelSpacingMM: (row: 0.5, column: 0.5))
        }
    }

    @Test("Una serie vuota è un errore")
    func rejectsEmpty() {
        #expect(throws: VolumeGeometryError.self) {
            _ = try SliceSorter.sort(
                slices: [], columnCount: 8, rowCount: 8,
                pixelSpacingMM: (row: 0.5, column: 0.5))
        }
    }
}
