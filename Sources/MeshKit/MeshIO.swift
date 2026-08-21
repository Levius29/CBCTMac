import Foundation
import DICOMCore

/// Formati mesh riconosciuti dal modulo.
public enum MeshFormat: Sendable {
    case stlBinary
    case stlASCII
    case ply
    case obj
}

/// Errori di importazione ed esportazione delle mesh.
public enum MeshIOError: Error, Hashable, Sendable, LocalizedError {
    case unrecognisedFormat(name: String)
    case truncated(name: String, atOffset: Int)
    case malformed(name: String, detail: String)
    case emptyMesh(name: String)
    case tooManyTriangles(name: String, declared: UInt32)

    public var errorDescription: String? {
        switch self {
        case .unrecognisedFormat(let name):
            return "Formato mesh non riconosciuto nel file \(name)."
        case .truncated(let name, let offset):
            return "Il file mesh \(name) è troncato all'offset \(offset)."
        case .malformed(let name, let detail):
            return "Il file mesh \(name) non è valido: \(detail)."
        case .emptyMesh(let name):
            return "Il file mesh \(name) non contiene una superficie triangolare."
        case .tooManyTriangles(let name, let declared):
            return "Il file mesh \(name) dichiara un numero non plausibile di triangoli (\(declared))."
        }
    }
}

/// Importazione ed esportazione dei formati mesh supportati.
public enum MeshIO: Sendable {
    /// Carica una mesh rilevando il formato dal contenuto del file.
    public static func load(url: URL) throws -> Mesh {
        let sourceName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MeshIOError.malformed(
                name: sourceName,
                detail: "lettura di \(url.path) non riuscita: \(error.localizedDescription)"
            )
        }
        return try load(data: data, name: sourceName)
    }

    /// Carica una mesh da byte già disponibili, rilevandone il formato.
    public static func load(data: Data, name: String) throws -> Mesh {
        guard !data.isEmpty else { throw MeshIOError.emptyMesh(name: name) }

        if let declared = stlTriangleCount(in: data) {
            let expectedSize = UInt64(84) + UInt64(50) * UInt64(declared)
            if expectedSize == UInt64(data.count) {
                return try loadBinarySTL(data: data, name: name, declared: declared)
            }
        }

        if hasPLYMagic(data) {
            return try loadPLY(data: data, name: name)
        }

        if let text = String(data: data, encoding: .utf8) {
            let leading = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lowercaseLeading = leading.lowercased()
            if lowercaseLeading.hasPrefix("solid") || lowercaseLeading.hasPrefix("facet") {
                return try loadASCIISTL(text: text, name: name)
            }
            if looksLikeOBJ(text) {
                return try loadOBJ(text: text, name: name)
            }
        }

        // Un STL binario danneggiato non deve essere trasformato in una richiesta di memoria
        // guidata dal conteggio corrotto. Un divario enorme viene segnalato come count bomb;
        // un record mancante in un conteggio realistico è invece un file troncato.
        if data.count >= 84,
           isLikelyDamagedSTL(data: data, name: name),
           let declared = stlTriangleCount(in: data)
        {
            let availableRecords = (data.count - 84) / 50
            if UInt64(declared) > UInt64(availableRecords) {
                if declared > 10_000_000 {
                    throw MeshIOError.tooManyTriangles(name: name, declared: declared)
                }
                throw MeshIOError.truncated(name: name, atOffset: data.count)
            }
        }

        throw MeshIOError.unrecognisedFormat(name: name)
    }

    /// Esporta una mesh come STL binario little-endian.
    public static func exportSTLBinary(_ mesh: Mesh) -> Data {
        let validTriangles = exportableTriangles(in: mesh)
        guard let declared = UInt32(exactly: validTriangles.count) else { return Data() }

        var writer = MeshDataWriter()
        let headerText = Array("CBCTMac MeshKit binary STL".utf8)
        writer.appendBytes(headerText)
        writer.appendZeroes(count: 80 - headerText.count)
        writer.appendUInt32(declared)

        for triangle: Triangle in validTriangles {
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            let normal = mesh.triangleNormal(triangle) ?? .zero
            writer.appendVec3Float32(normal)
            writer.appendVec3Float32(a)
            writer.appendVec3Float32(b)
            writer.appendVec3Float32(c)
            writer.appendUInt16(0)
        }
        return writer.data
    }

    // non-ancora-collegato: alle stampanti si consegna il binario, che è dieci volte più
    // piccolo, e l'ASCII serve a leggere un file con gli occhi quando qualcosa non torna.
    // Offrirlo nel menu accanto al binario inviterebbe a scegliere il formato sbagliato.
    /// Esporta una mesh come STL ASCII.
    public static func exportSTLASCII(_ mesh: Mesh) -> String {
        let validTriangles = exportableTriangles(in: mesh)
        let safeName = mesh.name.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        var lines = [String]()
        lines.reserveCapacity(2 + validTriangles.count * 7)
        lines.append("solid \(safeName)")

        for triangle: Triangle in validTriangles {
            let normal = mesh.triangleNormal(triangle) ?? .zero
            let a = mesh.verticesMM[triangle.a]
            let b = mesh.verticesMM[triangle.b]
            let c = mesh.verticesMM[triangle.c]
            lines.append("  facet normal \(normal.x) \(normal.y) \(normal.z)")
            lines.append("    outer loop")
            lines.append("      vertex \(a.x) \(a.y) \(a.z)")
            lines.append("      vertex \(b.x) \(b.y) \(b.z)")
            lines.append("      vertex \(c.x) \(c.y) \(c.z)")
            lines.append("    endloop")
            lines.append("  endfacet")
        }
        lines.append("endsolid \(safeName)")
        return lines.joined(separator: "\n")
    }

    private static func loadBinarySTL(
        data: Data,
        name: String,
        declared: UInt32
    ) throws -> Mesh {
        guard let triangleCount = Int(exactly: declared) else {
            throw MeshIOError.tooManyTriangles(name: name, declared: declared)
        }
        let capacityResult = triangleCount.multipliedReportingOverflow(by: 3)
        guard !capacityResult.overflow else {
            throw MeshIOError.tooManyTriangles(name: name, declared: declared)
        }

        var cursor = MeshByteCursor(data: data, name: name, offset: 0)
        try cursor.skip(count: 80)
        _ = try cursor.readUInt32(bigEndian: false)

        var vertices = [Vec3]()
        vertices.reserveCapacity(capacityResult.partialValue)
        var triangles = [Triangle]()
        triangles.reserveCapacity(triangleCount)

        var triangleIndex = 0
        while triangleIndex < triangleCount {
            _ = try cursor.readVec3Float32(bigEndian: false)
            let a = try cursor.readVec3Float32(bigEndian: false)
            let b = try cursor.readVec3Float32(bigEndian: false)
            let c = try cursor.readVec3Float32(bigEndian: false)
            try validateFinite(a, name: name, vertexIndex: vertices.count)
            try validateFinite(b, name: name, vertexIndex: vertices.count + 1)
            try validateFinite(c, name: name, vertexIndex: vertices.count + 2)
            _ = try cursor.readUInt16(bigEndian: false)

            let base = vertices.count
            vertices.append(a)
            vertices.append(b)
            vertices.append(c)
            triangles.append(Triangle(a: base, b: base + 1, c: base + 2))
            triangleIndex += 1
        }

        guard !triangles.isEmpty else { throw MeshIOError.emptyMesh(name: name) }
        return Mesh(verticesMM: vertices, triangles: triangles, name: name).welded()
    }

    private static func loadASCIISTL(text: String, name: String) throws -> Mesh {
        let tokens: [Substring] = text.split(
            whereSeparator: { (character: Character) in character.isWhitespace }
        )
        var index = 0
        var vertices = [Vec3]()
        var triangles = [Triangle]()

        while index < tokens.count {
            if tokens[index].lowercased() != "facet" {
                index += 1
                continue
            }

            index += 1
            try requireToken("normal", tokens: tokens, index: &index, name: name)
            _ = try readASCIIDouble(tokens: tokens, index: &index, name: name, context: "normale")
            _ = try readASCIIDouble(tokens: tokens, index: &index, name: name, context: "normale")
            _ = try readASCIIDouble(tokens: tokens, index: &index, name: name, context: "normale")
            try requireToken("outer", tokens: tokens, index: &index, name: name)
            try requireToken("loop", tokens: tokens, index: &index, name: name)

            let base = vertices.count
            var localVertex = 0
            while localVertex < 3 {
                try requireToken("vertex", tokens: tokens, index: &index, name: name)
                let x = try readASCIIDouble(
                    tokens: tokens, index: &index, name: name, context: "vertice"
                )
                let y = try readASCIIDouble(
                    tokens: tokens, index: &index, name: name, context: "vertice"
                )
                let z = try readASCIIDouble(
                    tokens: tokens, index: &index, name: name, context: "vertice"
                )
                let point = Vec3(x, y, z)
                try validateFinite(point, name: name, vertexIndex: vertices.count)
                vertices.append(point)
                localVertex += 1
            }

            try requireToken("endloop", tokens: tokens, index: &index, name: name)
            try requireToken("endfacet", tokens: tokens, index: &index, name: name)
            triangles.append(Triangle(a: base, b: base + 1, c: base + 2))
        }

        guard !triangles.isEmpty else { throw MeshIOError.emptyMesh(name: name) }
        return Mesh(verticesMM: vertices, triangles: triangles, name: name).welded()
    }

    private static func loadPLY(data: Data, name: String) throws -> Mesh {
        let header = try parsePLYHeader(data: data, name: name)
        switch header.encoding {
        case .ascii:
            return try loadASCIIPLY(data: data, name: name, header: header)
        case .binaryLittleEndian:
            return try loadBinaryPLY(data: data, name: name, header: header, bigEndian: false)
        case .binaryBigEndian:
            return try loadBinaryPLY(data: data, name: name, header: header, bigEndian: true)
        }
    }

    private static func loadOBJ(text: String, name: String) throws -> Mesh {
        let lines: [Substring] = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { (character: Character) in character.isNewline }
        )
        var vertices = [Vec3]()
        var triangles = [Triangle]()

        var lineIndex = 0
        while lineIndex < lines.count {
            let line = lines[lineIndex]
            let content: Substring
            if let commentIndex = line.firstIndex(of: "#") {
                content = line[..<commentIndex]
            } else {
                content = line
            }
            let tokens: [Substring] = content.split(
                whereSeparator: { (character: Character) in character.isWhitespace }
            )
            lineIndex += 1
            guard !tokens.isEmpty else { continue }

            let keyword = tokens[0]
            if keyword == "v" {
                guard tokens.count >= 4 else {
                    throw MeshIOError.malformed(
                        name: name,
                        detail: "vertice OBJ incompleto alla riga \(lineIndex)"
                    )
                }
                guard let x = Double(String(tokens[1])),
                      let y = Double(String(tokens[2])),
                      let z = Double(String(tokens[3]))
                else {
                    throw MeshIOError.malformed(
                        name: name,
                        detail: "coordinate OBJ non valide alla riga \(lineIndex)"
                    )
                }
                let point = Vec3(x, y, z)
                try validateFinite(point, name: name, vertexIndex: vertices.count)
                vertices.append(point)
                continue
            }

            if keyword == "f" {
                guard tokens.count >= 4 else {
                    throw MeshIOError.malformed(
                        name: name,
                        detail: "faccia OBJ con meno di tre vertici alla riga \(lineIndex)"
                    )
                }
                var indices = [Int]()
                indices.reserveCapacity(tokens.count - 1)
                var tokenIndex = 1
                while tokenIndex < tokens.count {
                    let index = try resolveOBJVertexIndex(
                        token: tokens[tokenIndex],
                        vertexCount: vertices.count,
                        name: name,
                        line: lineIndex
                    )
                    indices.append(index)
                    tokenIndex += 1
                }

                var fanIndex = 1
                while fanIndex + 1 < indices.count {
                    triangles.append(
                        Triangle(a: indices[0], b: indices[fanIndex], c: indices[fanIndex + 1])
                    )
                    fanIndex += 1
                }
                continue
            }

            // Questi record non cambiano la geometria richiesta. Gli indici di texture e
            // normale vengono comunque tollerati nei token delle facce.
            if keyword == "vt" || keyword == "vn" || keyword == "mtllib"
                || keyword == "usemtl" || keyword == "o" || keyword == "g" || keyword == "s"
            {
                continue
            }
        }

        guard !vertices.isEmpty, !triangles.isEmpty else {
            throw MeshIOError.emptyMesh(name: name)
        }
        return Mesh(verticesMM: vertices, triangles: triangles, name: name)
    }

    private static func resolveOBJVertexIndex(
        token: Substring,
        vertexCount: Int,
        name: String,
        line: Int
    ) throws -> Int {
        let components: [Substring] = token.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard let first = components.first,
              !first.isEmpty,
              let rawIndex = Int(String(first)),
              rawIndex != 0
        else {
            throw MeshIOError.malformed(
                name: name,
                detail: "indice OBJ non valido alla riga \(line)"
            )
        }

        let resolved: Int
        if rawIndex > 0 {
            resolved = rawIndex - 1
        } else {
            let addition = vertexCount.addingReportingOverflow(rawIndex)
            guard !addition.overflow else {
                throw MeshIOError.malformed(
                    name: name,
                    detail: "indice OBJ fuori intervallo alla riga \(line)"
                )
            }
            resolved = addition.partialValue
        }

        guard resolved >= 0, resolved < vertexCount else {
            throw MeshIOError.malformed(
                name: name,
                detail: "indice OBJ fuori intervallo alla riga \(line)"
            )
        }
        return resolved
    }

    private static func looksLikeOBJ(_ text: String) -> Bool {
        let lines: [Substring] = text.split(
            omittingEmptySubsequences: false,
            whereSeparator: { (character: Character) in character.isNewline }
        )
        for line: Substring in lines {
            let content: Substring
            if let commentIndex = line.firstIndex(of: "#") {
                content = line[..<commentIndex]
            } else {
                content = line
            }
            let tokens: [Substring] = content.split(
                whereSeparator: { (character: Character) in character.isWhitespace }
            )
            guard let keyword = tokens.first else { continue }
            if keyword == "v" || keyword == "f" {
                return true
            }
        }
        return false
    }

    private static func parsePLYHeader(data: Data, name: String) throws -> PLYHeader {
        var lines = [String]()
        var lineStart = 0
        var scanOffset = 0
        var bodyOffset: Int?

        while scanOffset < data.count {
            let dataIndex = data.index(data.startIndex, offsetBy: scanOffset)
            if data[dataIndex] == 0x0A {
                let lineData = data.subdata(in: lineStart..<scanOffset)
                guard var line = String(data: lineData, encoding: .utf8) else {
                    throw MeshIOError.malformed(name: name, detail: "header PLY non ASCII")
                }
                if line.last == "\r" {
                    line.removeLast()
                }
                lines.append(line)
                if line.trimmingCharacters(in: .whitespacesAndNewlines) == "end_header" {
                    bodyOffset = scanOffset + 1
                    break
                }
                lineStart = scanOffset + 1
            }
            scanOffset += 1
        }

        if bodyOffset == nil, lineStart < data.count {
            let lineData = data.subdata(in: lineStart..<data.count)
            guard var line = String(data: lineData, encoding: .utf8) else {
                throw MeshIOError.malformed(name: name, detail: "header PLY non ASCII")
            }
            if line.last == "\r" {
                line.removeLast()
            }
            lines.append(line)
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "end_header" {
                bodyOffset = data.count
            }
        }

        guard let resolvedBodyOffset = bodyOffset else {
            throw MeshIOError.malformed(name: name, detail: "manca end_header nel PLY")
        }
        guard !lines.isEmpty,
              lines[0].trimmingCharacters(in: .whitespacesAndNewlines) == "ply"
        else {
            throw MeshIOError.malformed(name: name, detail: "magic PLY non valido")
        }

        var encoding: PLYEncoding?
        var elements = [PLYElement]()
        var lineIndex = 1
        while lineIndex < lines.count {
            let tokens: [Substring] = lines[lineIndex].split(
                whereSeparator: { (character: Character) in character.isWhitespace }
            )
            lineIndex += 1
            guard !tokens.isEmpty else { continue }
            let keyword = tokens[0].lowercased()
            if keyword == "comment" || keyword == "obj_info" || keyword == "end_header" {
                continue
            }
            if keyword == "format" {
                guard tokens.count >= 3 else {
                    throw MeshIOError.malformed(name: name, detail: "riga format PLY incompleta")
                }
                switch tokens[1].lowercased() {
                case "ascii":
                    encoding = .ascii
                case "binary_little_endian":
                    encoding = .binaryLittleEndian
                case "binary_big_endian":
                    encoding = .binaryBigEndian
                default:
                    throw MeshIOError.malformed(
                        name: name,
                        detail: "formato PLY non supportato \(tokens[1])"
                    )
                }
                continue
            }
            if keyword == "element" {
                guard tokens.count >= 3,
                      let count = Int(String(tokens[2])),
                      count >= 0
                else {
                    throw MeshIOError.malformed(name: name, detail: "conteggio elemento PLY non valido")
                }
                elements.append(
                    PLYElement(name: tokens[1].lowercased(), count: count, properties: [])
                )
                continue
            }
            if keyword == "property" {
                guard !elements.isEmpty else {
                    throw MeshIOError.malformed(
                        name: name,
                        detail: "proprietà PLY senza elemento"
                    )
                }
                let elementIndex = elements.count - 1
                if tokens.count >= 2, tokens[1].lowercased() == "list" {
                    guard tokens.count >= 5,
                          let countType = PLYScalarType(name: tokens[2].lowercased()),
                          let valueType = PLYScalarType(name: tokens[3].lowercased()),
                          countType.isInteger
                    else {
                        throw MeshIOError.malformed(
                            name: name,
                            detail: "proprietà lista PLY non valida"
                        )
                    }
                    elements[elementIndex].properties.append(
                        .list(
                            name: tokens[4].lowercased(),
                            countType: countType,
                            valueType: valueType
                        )
                    )
                } else {
                    guard tokens.count >= 3,
                          let type = PLYScalarType(name: tokens[1].lowercased())
                    else {
                        throw MeshIOError.malformed(
                            name: name,
                            detail: "proprietà scalare PLY non valida"
                        )
                    }
                    elements[elementIndex].properties.append(
                        .scalar(name: tokens[2].lowercased(), type: type)
                    )
                }
                continue
            }
            throw MeshIOError.malformed(
                name: name,
                detail: "direttiva PLY sconosciuta \(tokens[0])"
            )
        }

        guard let resolvedEncoding = encoding else {
            throw MeshIOError.malformed(name: name, detail: "manca il formato PLY")
        }
        return PLYHeader(
            encoding: resolvedEncoding,
            elements: elements,
            bodyOffset: resolvedBodyOffset
        )
    }

    private static func loadASCIIPLY(
        data: Data,
        name: String,
        header: PLYHeader
    ) throws -> Mesh {
        guard header.bodyOffset >= 0, header.bodyOffset <= data.count else {
            throw MeshIOError.truncated(name: name, atOffset: header.bodyOffset)
        }
        let bodyData = data.subdata(in: header.bodyOffset..<data.count)
        guard let body = String(data: bodyData, encoding: .utf8) else {
            throw MeshIOError.malformed(name: name, detail: "corpo PLY ASCII non UTF-8")
        }
        let tokens: [Substring] = body.split(
            whereSeparator: { (character: Character) in character.isWhitespace }
        )
        var tokenIndex = 0
        var vertices = [Vec3]()
        var polygonFaces = [[Int]]()

        for element: PLYElement in header.elements {
            let faceIndexPropertyName = try selectedPLYFaceIndexProperty(
                in: element,
                name: name
            )
            var recordIndex = 0
            while recordIndex < element.count {
                var x: Double?
                var y: Double?
                var z: Double?
                var faceIndices: [Int]?

                for property: PLYProperty in element.properties {
                    switch property {
                    case .scalar(let propertyName, let type):
                        let value = try readASCIIPLYScalar(
                            type: type,
                            tokens: tokens,
                            tokenIndex: &tokenIndex,
                            name: name
                        )
                        if element.name == "vertex" {
                            assignPLYCoordinate(
                                propertyName: propertyName,
                                value: value.doubleValue,
                                x: &x,
                                y: &y,
                                z: &z
                            )
                        }
                    case .list(let propertyName, let countType, let valueType):
                        let countValue = try readASCIIPLYScalar(
                            type: countType,
                            tokens: tokens,
                            tokenIndex: &tokenIndex,
                            name: name
                        )
                        let count = try countValue.nonnegativeInt(
                            name: name,
                            detail: "conteggio lista PLY non valido"
                        )
                        guard count <= tokens.count - tokenIndex else {
                            throw MeshIOError.truncated(name: name, atOffset: tokenIndex)
                        }
                        let capture: Bool
                        if let selectedName = faceIndexPropertyName {
                            capture = element.name == "face" && propertyName == selectedName
                        } else {
                            capture = false
                        }
                        var captured = [Int]()
                        if capture {
                            captured.reserveCapacity(count)
                        }
                        var listIndex = 0
                        while listIndex < count {
                            let value = try readASCIIPLYScalar(
                                type: valueType,
                                tokens: tokens,
                                tokenIndex: &tokenIndex,
                                name: name
                            )
                            if capture {
                                captured.append(try value.nonnegativeInt(
                                    name: name,
                                    detail: "indice di faccia PLY non valido"
                                ))
                            }
                            listIndex += 1
                        }
                        if capture {
                            faceIndices = captured
                        }
                    }
                }

                if element.name == "vertex" {
                    guard let pointX = x, let pointY = y, let pointZ = z else {
                        throw MeshIOError.malformed(
                            name: name,
                            detail: "coordinate x/y/z mancanti al vertice \(vertices.count)"
                        )
                    }
                    let point = Vec3(pointX, pointY, pointZ)
                    try validateFinite(point, name: name, vertexIndex: vertices.count)
                    vertices.append(point)
                } else if element.name == "face", let faceIndices {
                    polygonFaces.append(faceIndices)
                }
                recordIndex += 1
            }
        }

        return try makePLYMesh(vertices: vertices, polygonFaces: polygonFaces, name: name)
    }

    private static func loadBinaryPLY(
        data: Data,
        name: String,
        header: PLYHeader,
        bigEndian: Bool
    ) throws -> Mesh {
        var cursor = MeshByteCursor(data: data, name: name, offset: header.bodyOffset)
        var vertices = [Vec3]()
        var polygonFaces = [[Int]]()

        for element: PLYElement in header.elements {
            let faceIndexPropertyName = try selectedPLYFaceIndexProperty(
                in: element,
                name: name
            )
            var recordIndex = 0
            while recordIndex < element.count {
                var x: Double?
                var y: Double?
                var z: Double?
                var faceIndices: [Int]?

                for property: PLYProperty in element.properties {
                    switch property {
                    case .scalar(let propertyName, let type):
                        let value = try readBinaryPLYScalar(
                            type: type,
                            cursor: &cursor,
                            bigEndian: bigEndian
                        )
                        if element.name == "vertex" {
                            assignPLYCoordinate(
                                propertyName: propertyName,
                                value: value.doubleValue,
                                x: &x,
                                y: &y,
                                z: &z
                            )
                        }
                    case .list(let propertyName, let countType, let valueType):
                        let countValue = try readBinaryPLYScalar(
                            type: countType,
                            cursor: &cursor,
                            bigEndian: bigEndian
                        )
                        let count = try countValue.nonnegativeInt(
                            name: name,
                            detail: "conteggio lista PLY non valido"
                        )
                        guard valueType.byteWidth > 0,
                              count <= cursor.remainingCount / valueType.byteWidth
                        else {
                            throw MeshIOError.truncated(name: name, atOffset: cursor.offset)
                        }
                        let capture: Bool
                        if let selectedName = faceIndexPropertyName {
                            capture = element.name == "face" && propertyName == selectedName
                        } else {
                            capture = false
                        }
                        var captured = [Int]()
                        if capture {
                            captured.reserveCapacity(count)
                        }
                        var listIndex = 0
                        while listIndex < count {
                            let value = try readBinaryPLYScalar(
                                type: valueType,
                                cursor: &cursor,
                                bigEndian: bigEndian
                            )
                            if capture {
                                captured.append(try value.nonnegativeInt(
                                    name: name,
                                    detail: "indice di faccia PLY non valido"
                                ))
                            }
                            listIndex += 1
                        }
                        if capture {
                            faceIndices = captured
                        }
                    }
                }

                if element.name == "vertex" {
                    guard let pointX = x, let pointY = y, let pointZ = z else {
                        throw MeshIOError.malformed(
                            name: name,
                            detail: "coordinate x/y/z mancanti al vertice \(vertices.count)"
                        )
                    }
                    let point = Vec3(pointX, pointY, pointZ)
                    try validateFinite(point, name: name, vertexIndex: vertices.count)
                    vertices.append(point)
                } else if element.name == "face", let faceIndices {
                    polygonFaces.append(faceIndices)
                }
                recordIndex += 1
            }
        }

        return try makePLYMesh(vertices: vertices, polygonFaces: polygonFaces, name: name)
    }

    private static func makePLYMesh(
        vertices: [Vec3],
        polygonFaces: [[Int]],
        name: String
    ) throws -> Mesh {
        var triangles = [Triangle]()
        for indices: [Int] in polygonFaces {
            for index: Int in indices {
                guard index >= 0, index < vertices.count else {
                    throw MeshIOError.malformed(
                        name: name,
                        detail: "indice di faccia PLY fuori intervallo: \(index)"
                    )
                }
            }
            guard indices.count >= 3 else { continue }
            var index = 1
            while index + 1 < indices.count {
                triangles.append(Triangle(a: indices[0], b: indices[index], c: indices[index + 1]))
                index += 1
            }
        }
        guard !vertices.isEmpty, !triangles.isEmpty else {
            throw MeshIOError.emptyMesh(name: name)
        }
        return Mesh(verticesMM: vertices, triangles: triangles, name: name)
    }

    private static func readASCIIPLYScalar(
        type: PLYScalarType,
        tokens: [Substring],
        tokenIndex: inout Int,
        name: String
    ) throws -> PLYScalarValue {
        guard tokenIndex >= 0, tokenIndex < tokens.count else {
            throw MeshIOError.truncated(name: name, atOffset: tokenIndex)
        }
        let token = String(tokens[tokenIndex])
        tokenIndex += 1

        switch type {
        case .int8:
            guard let value = Int8(token) else { return try invalidPLYNumber(token, name: name) }
            return .signed(Int64(value))
        case .uint8:
            guard let value = UInt8(token) else { return try invalidPLYNumber(token, name: name) }
            return .unsigned(UInt64(value))
        case .int16:
            guard let value = Int16(token) else { return try invalidPLYNumber(token, name: name) }
            return .signed(Int64(value))
        case .uint16:
            guard let value = UInt16(token) else { return try invalidPLYNumber(token, name: name) }
            return .unsigned(UInt64(value))
        case .int32:
            guard let value = Int32(token) else { return try invalidPLYNumber(token, name: name) }
            return .signed(Int64(value))
        case .uint32:
            guard let value = UInt32(token) else { return try invalidPLYNumber(token, name: name) }
            return .unsigned(UInt64(value))
        case .int64:
            guard let value = Int64(token) else { return try invalidPLYNumber(token, name: name) }
            return .signed(value)
        case .uint64:
            guard let value = UInt64(token) else { return try invalidPLYNumber(token, name: name) }
            return .unsigned(value)
        case .float32:
            guard let value = Float(token) else { return try invalidPLYNumber(token, name: name) }
            return .floating(Double(value))
        case .float64:
            guard let value = Double(token) else { return try invalidPLYNumber(token, name: name) }
            return .floating(value)
        }
    }

    private static func invalidPLYNumber(
        _ token: String,
        name: String
    ) throws -> PLYScalarValue {
        throw MeshIOError.malformed(name: name, detail: "numero PLY non valido: \(token)")
    }

    private static func readBinaryPLYScalar(
        type: PLYScalarType,
        cursor: inout MeshByteCursor,
        bigEndian: Bool
    ) throws -> PLYScalarValue {
        switch type {
        case .int8:
            return .signed(Int64(Int8(bitPattern: try cursor.readUInt8())))
        case .uint8:
            return .unsigned(UInt64(try cursor.readUInt8()))
        case .int16:
            return .signed(Int64(Int16(bitPattern: try cursor.readUInt16(bigEndian: bigEndian))))
        case .uint16:
            return .unsigned(UInt64(try cursor.readUInt16(bigEndian: bigEndian)))
        case .int32:
            return .signed(Int64(Int32(bitPattern: try cursor.readUInt32(bigEndian: bigEndian))))
        case .uint32:
            return .unsigned(UInt64(try cursor.readUInt32(bigEndian: bigEndian)))
        case .int64:
            return .signed(Int64(bitPattern: try cursor.readUInt64(bigEndian: bigEndian)))
        case .uint64:
            return .unsigned(try cursor.readUInt64(bigEndian: bigEndian))
        case .float32:
            return .floating(try cursor.readFloat32(bigEndian: bigEndian))
        case .float64:
            return .floating(try cursor.readFloat64(bigEndian: bigEndian))
        }
    }

    private static func assignPLYCoordinate(
        propertyName: String,
        value: Double,
        x: inout Double?,
        y: inout Double?,
        z: inout Double?
    ) {
        if propertyName == "x" {
            x = value
        } else if propertyName == "y" {
            y = value
        } else if propertyName == "z" {
            z = value
        }
    }

    private static func isPLYVertexIndexName(_ name: String) -> Bool {
        name == "vertex_indices" || name == "vertex_index"
    }

    private static func selectedPLYFaceIndexProperty(
        in element: PLYElement,
        name: String
    ) throws -> String? {
        guard element.name == "face" else { return nil }

        var listProperties = [(name: String, valueType: PLYScalarType)]()
        var standardProperties = [(name: String, valueType: PLYScalarType)]()
        for property: PLYProperty in element.properties {
            if case .list(let propertyName, _, let valueType) = property {
                let entry = (name: propertyName, valueType: valueType)
                listProperties.append(entry)
                if isPLYVertexIndexName(propertyName) {
                    standardProperties.append(entry)
                }
            }
        }

        let selected: (name: String, valueType: PLYScalarType)
        if standardProperties.count == 1 {
            selected = standardProperties[0]
        } else if standardProperties.count > 1 {
            throw MeshIOError.malformed(
                name: name,
                detail: "più liste PLY dichiarano gli indici della faccia"
            )
        } else if listProperties.count == 1 {
            selected = listProperties[0]
        } else if listProperties.isEmpty {
            throw MeshIOError.malformed(
                name: name,
                detail: "elemento face PLY senza lista di indici"
            )
        } else {
            throw MeshIOError.malformed(
                name: name,
                detail: "liste PLY ambigue per gli indici della faccia"
            )
        }

        guard selected.valueType.isInteger else {
            throw MeshIOError.malformed(
                name: name,
                detail: "gli indici della faccia PLY non sono interi"
            )
        }
        return selected.name
    }

    private static func requireToken(
        _ expected: String,
        tokens: [Substring],
        index: inout Int,
        name: String
    ) throws {
        guard index < tokens.count else {
            throw MeshIOError.malformed(name: name, detail: "manca il token \(expected)")
        }
        let actual = tokens[index].lowercased()
        guard actual == expected else {
            throw MeshIOError.malformed(
                name: name,
                detail: "atteso \(expected), trovato \(tokens[index])"
            )
        }
        index += 1
    }

    private static func readASCIIDouble(
        tokens: [Substring],
        index: inout Int,
        name: String,
        context: String
    ) throws -> Double {
        guard index < tokens.count else {
            throw MeshIOError.malformed(name: name, detail: "valore mancante per \(context)")
        }
        let token = tokens[index]
        index += 1
        guard let value = Double(String(token)) else {
            throw MeshIOError.malformed(
                name: name,
                detail: "numero non valido \(token) per \(context)"
            )
        }
        return value
    }

    private static func stlTriangleCount(in data: Data) -> UInt32? {
        guard data.count >= 84 else { return nil }
        return littleEndianUInt32(in: data, at: 80)
    }

    private static func hasPLYMagic(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let first = data.startIndex
        let second = data.index(first, offsetBy: 1)
        let third = data.index(first, offsetBy: 2)
        return data[first] == 0x70 && data[second] == 0x6C && data[third] == 0x79
    }

    private static func isLikelyDamagedSTL(data: Data, name: String) -> Bool {
        if name.lowercased().hasSuffix(".stl") {
            return true
        }
        let prefixLength = Swift.min(80, data.count)
        guard prefixLength > 0 else { return false }
        let prefixData = data.subdata(in: 0..<prefixLength)
        guard let prefix = String(data: prefixData, encoding: .utf8) else { return false }
        return prefix.lowercased().contains("stl")
    }

    private static func exportableTriangles(in mesh: Mesh) -> [Triangle] {
        var result = [Triangle]()
        result.reserveCapacity(mesh.triangles.count)
        for triangle: Triangle in mesh.triangles {
            guard triangle.a >= 0, triangle.a < mesh.verticesMM.count,
                  triangle.b >= 0, triangle.b < mesh.verticesMM.count,
                  triangle.c >= 0, triangle.c < mesh.verticesMM.count
            else { continue }
            guard mesh.verticesMM[triangle.a].isFinite,
                  mesh.verticesMM[triangle.b].isFinite,
                  mesh.verticesMM[triangle.c].isFinite
            else { continue }
            guard isRepresentableAsFiniteFloat(mesh.verticesMM[triangle.a]),
                  isRepresentableAsFiniteFloat(mesh.verticesMM[triangle.b]),
                  isRepresentableAsFiniteFloat(mesh.verticesMM[triangle.c])
            else { continue }
            result.append(triangle)
        }
        return result
    }

    private static func isRepresentableAsFiniteFloat(_ point: Vec3) -> Bool {
        Float(point.x).isFinite && Float(point.y).isFinite && Float(point.z).isFinite
    }
}

private func validateFinite(_ point: Vec3, name: String, vertexIndex: Int) throws {
    guard point.isFinite else {
        throw MeshIOError.malformed(
            name: name,
            detail: "coordinata non finita al vertice \(vertexIndex)"
        )
    }
}

private func littleEndianUInt32(in data: Data, at offset: Int) -> UInt32? {
    guard offset >= 0, offset <= data.count, 4 <= data.count - offset else { return nil }
    let start = data.index(data.startIndex, offsetBy: offset)
    let b0 = UInt32(data[start])
    let b1 = UInt32(data[data.index(start, offsetBy: 1)])
    let b2 = UInt32(data[data.index(start, offsetBy: 2)])
    let b3 = UInt32(data[data.index(start, offsetBy: 3)])
    return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

private struct MeshByteCursor {
    let data: Data
    let name: String
    var offset: Int

    var remainingCount: Int {
        guard offset >= 0, offset <= data.count else { return 0 }
        return data.count - offset
    }

    mutating func skip(count: Int) throws {
        _ = try validatedRange(count: count)
        offset += count
    }

    mutating func readUInt8() throws -> UInt8 {
        let range = try validatedRange(count: 1)
        let dataIndex = data.index(data.startIndex, offsetBy: range.lowerBound)
        offset = range.upperBound
        return data[dataIndex]
    }

    mutating func readUInt16(bigEndian: Bool) throws -> UInt16 {
        let first = UInt16(try readUInt8())
        let second = UInt16(try readUInt8())
        if bigEndian {
            return (first << 8) | second
        }
        return first | (second << 8)
    }

    mutating func readUInt32(bigEndian: Bool) throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8())
        let b2 = UInt32(try readUInt8())
        let b3 = UInt32(try readUInt8())
        if bigEndian {
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }

    mutating func readUInt64(bigEndian: Bool) throws -> UInt64 {
        var value: UInt64 = 0
        if bigEndian {
            var count = 0
            while count < 8 {
                value = (value << 8) | UInt64(try readUInt8())
                count += 1
            }
        } else {
            var shift = 0
            while shift < 64 {
                value |= UInt64(try readUInt8()) << UInt64(shift)
                shift += 8
            }
        }
        return value
    }

    mutating func readFloat32(bigEndian: Bool) throws -> Double {
        let bits = try readUInt32(bigEndian: bigEndian)
        return Double(Float(bitPattern: bits))
    }

    mutating func readFloat64(bigEndian: Bool) throws -> Double {
        let bits = try readUInt64(bigEndian: bigEndian)
        return Double(bitPattern: bits)
    }

    mutating func readVec3Float32(bigEndian: Bool) throws -> Vec3 {
        let x = try readFloat32(bigEndian: bigEndian)
        let y = try readFloat32(bigEndian: bigEndian)
        let z = try readFloat32(bigEndian: bigEndian)
        return Vec3(x, y, z)
    }

    mutating func validatedRange(count: Int) throws -> Range<Int> {
        guard count >= 0, offset >= 0, offset <= data.count,
              count <= data.count - offset
        else { throw MeshIOError.truncated(name: name, atOffset: offset) }
        return offset..<(offset + count)
    }
}

private enum PLYEncoding {
    case ascii
    case binaryLittleEndian
    case binaryBigEndian
}

private enum PLYScalarType {
    case int8
    case uint8
    case int16
    case uint16
    case int32
    case uint32
    case int64
    case uint64
    case float32
    case float64

    init?(name: String) {
        switch name {
        case "char", "int8": self = .int8
        case "uchar", "uint8": self = .uint8
        case "short", "int16": self = .int16
        case "ushort", "uint16": self = .uint16
        case "int", "int32": self = .int32
        case "uint", "uint32": self = .uint32
        case "long", "int64": self = .int64
        case "ulong", "uint64": self = .uint64
        case "float", "float32": self = .float32
        case "double", "float64": self = .float64
        default: return nil
        }
    }

    var isInteger: Bool {
        switch self {
        case .float32, .float64: return false
        default: return true
        }
    }

    var byteWidth: Int {
        switch self {
        case .int8, .uint8: return 1
        case .int16, .uint16: return 2
        case .int32, .uint32, .float32: return 4
        case .int64, .uint64, .float64: return 8
        }
    }
}

private enum PLYProperty {
    case scalar(name: String, type: PLYScalarType)
    case list(name: String, countType: PLYScalarType, valueType: PLYScalarType)
}

private struct PLYElement {
    let name: String
    let count: Int
    var properties: [PLYProperty]
}

private struct PLYHeader {
    let encoding: PLYEncoding
    let elements: [PLYElement]
    let bodyOffset: Int
}

private enum PLYScalarValue {
    case signed(Int64)
    case unsigned(UInt64)
    case floating(Double)

    var doubleValue: Double {
        switch self {
        case .signed(let value): return Double(value)
        case .unsigned(let value): return Double(value)
        case .floating(let value): return value
        }
    }

    func nonnegativeInt(name: String, detail: String) throws -> Int {
        switch self {
        case .signed(let value):
            guard value >= 0, let result = Int(exactly: value) else {
                throw MeshIOError.malformed(name: name, detail: detail)
            }
            return result
        case .unsigned(let value):
            guard let result = Int(exactly: value) else {
                throw MeshIOError.malformed(name: name, detail: detail)
            }
            return result
        case .floating:
            throw MeshIOError.malformed(name: name, detail: detail)
        }
    }
}

private struct MeshDataWriter {
    private var bytes = [UInt8]()

    mutating func appendBytes(_ values: [UInt8]) {
        bytes.append(contentsOf: values)
    }

    mutating func appendZeroes(count: Int) {
        guard count > 0 else { return }
        bytes.append(contentsOf: [UInt8](repeating: 0, count: count))
    }

    mutating func appendUInt16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func appendFloat32(_ value: Double) {
        appendUInt32(Float(value).bitPattern)
    }

    mutating func appendVec3Float32(_ value: Vec3) {
        appendFloat32(value.x)
        appendFloat32(value.y)
        appendFloat32(value.z)
    }

    var data: Data { Data(bytes) }
}
