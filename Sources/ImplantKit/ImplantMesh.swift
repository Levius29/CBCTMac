import DICOMCore
import Foundation
import MeshKit

// L'impianto e il dente come superfici vere.
//
// # Che cosa cambia rispetto al profilo
//
// Il profilo è già una descrizione **vettoriale** dell'impianto: una manciata di punti quota e
// raggio, da cui la sagoma si ricava a qualunque ingrandimento senza perdere nitidezza. Per
// disegnare una silhouette basta quello, e infatti è ciò che i riquadri usano.
//
// Non basta per tutto il resto. Un profilo non si può esportare in STL, non si può sottrarre da
// un corpo dima, non si può intersecare con un piano per ottenere un contorno, e non si può
// ombreggiare nel 3D. Tutte queste cose parlano una lingua sola — triangoli — e questo file è
// la traduzione.
//
// # Perché la traduzione sta qui e non nel disegno
//
// Perché il numero di lati con cui si approssima un cerchio è una decisione geometrica, non
// grafica: ventiquattro lati su un impianto da 4 mm sbagliano il raggio di due centesimi di
// millimetro nei punti peggiori, e chi esporta una dima deve poter sapere quel numero. Deciderlo
// dentro una `Canvas` lo renderebbe invisibile e diverso in ogni vista.

public enum ImplantMesh {

    /// Lati con cui si approssima la circonferenza, se non se ne chiedono altri.
    ///
    /// Trentadue: su un impianto da 6 mm di diametro lo scarto massimo fra poligono e cerchio è
    /// `r · (1 − cos(π/n))`, cioè quattordici micron. È sotto la risoluzione di qualunque
    /// stampante 3D da studio, e sotto l'incertezza di ogni misura che questo programma dichiara.
    public static let defaultSegments = 32

    /// Errore massimo di raggio commesso approssimando il cerchio, in millimetri.
    ///
    /// Pubblico perché chi esporta una dima ha il diritto di sapere di quanto la superficie che
    /// sta per stampare differisce dal cilindro ideale.
    public static func radialErrorMM(radiusMM: Double, segments: Int) -> Double {
        let sides = Swift.max(segments, 3)
        return radiusMM * (1 - Foundation.cos(.pi / Double(sides)))
    }

    /// La superficie dell'impianto, collocata nello spazio Patient.
    ///
    /// Chiusa: il profilo viene tappato in cima e in fondo, così la mesh racchiude un volume ed
    /// è stampabile. Una superficie aperta passa i controlli di forma e produce un pezzo che lo
    /// slicer rifiuta o riempie a caso.
    public static func surface(
        of implant: ImplantPlacement,
        segments: Int = defaultSegments,
        name: String? = nil
    ) -> Mesh {
        let profile = implant.model.profile
        let label = name ?? (implant.label.isEmpty ? "Impianto" : implant.label)
        guard profile.count >= 2, let axis = implant.axis.normalized else {
            return Mesh(verticesMM: [], triangles: [], name: label)
        }

        let sides = Swift.max(segments, 3)
        let (right, up) = perpendicularFrame(to: axis)

        var vertices: [Vec3] = []
        var triangles: [Triangle] = []

        // Un anello per quota. Le quote a raggio nullo — la punta, se il profilo la porta a zero
        // — danno anelli degeneri: si tengono lo stesso, perché toglierli spezzerebbe la
        // corrispondenza fra anelli consecutivi e la fascia di triangoli che li unisce.
        for level in profile {
            let centre = implant.platformMM + axis * level.zMM
            for side in 0..<sides {
                let angle = 2 * Double.pi * Double(side) / Double(sides)
                let offset =
                    right * (Foundation.cos(angle) * level.radiusMM)
                    + up * (Foundation.sin(angle) * level.radiusMM)
                vertices.append(centre + offset)
            }
        }

        for ring in 0..<(profile.count - 1) {
            let lower = ring * sides
            let upper = (ring + 1) * sides
            for side in 0..<sides {
                let next = (side + 1) % sides
                // Il verso è quello che manda le normali **fuori** dal solido, ed è la sola cosa
                // che uno slicer guarda per sapere dove sta il pieno. Invertito produce un pezzo
                // che si stampa al rovescio, cioè cavo.
                //
                // Alla prima stesura era invertito, e il conteggio degli spigoli non se ne
                // accorgeva: gli spigoli restano due, solo percorsi nello stesso verso invece
                // che in versi opposti. L'ha trovato il volume con segno, che risultava
                // negativo. Con la terna destrorsa `(right, up, axis)` il verso giusto è
                // questo, e i due tappi lo avevano già.
                triangles.append(Triangle(a: lower + side, b: upper + next, c: upper + side))
                triangles.append(Triangle(a: lower + side, b: lower + next, c: upper + next))
            }
        }

        // I due tappi, ciascuno a ventaglio attorno al centro dell'anello estremo.
        let platformCentre = vertices.count
        vertices.append(implant.platformMM)
        for side in 0..<sides {
            let next = (side + 1) % sides
            triangles.append(Triangle(a: platformCentre, b: next, c: side))
        }

        let apexRing = (profile.count - 1) * sides
        let apexCentre = vertices.count
        vertices.append(implant.platformMM + axis * (profile.last?.zMM ?? 0))
        for side in 0..<sides {
            let next = (side + 1) % sides
            triangles.append(Triangle(a: apexCentre, b: apexRing + side, c: apexRing + next))
        }

        return Mesh(verticesMM: vertices, triangles: triangles, name: label)
    }

    /// Superficie filettata dettagliata per STL e costruzione della dima.
    ///
    /// La filettatura resta parametrica: nessuna sagoma commerciale entra nella mesh. Sedici
    /// campioni per passo evitano che una scanalatura destinata alla stampa venga ridotta a una
    /// successione di spigoli visibili.
    public static func threadedSurface(
        of implant: ImplantPlacement,
        segments: Int = defaultSegments,
        name: String? = nil
    ) -> Mesh {
        threadedSurface(
            of: implant,
            circumferentialSegments: Swift.min(Swift.max(segments, 3), 512),
            axialSamplesPerPitch: 32,
            maximumAxialIntervals: 16_384,
            name: name
        )
    }

    /// Superficie filettata leggera per il disegno CPU in tempo reale.
    ///
    /// Il passo resta leggibile, ma si riducono entrambe le dimensioni della griglia: è questa
    /// scelta combinata che impedisce ai triangoli di moltiplicarsi a ogni fotogramma.
    public static func threadedScreenSurface(
        of implant: ImplantPlacement,
        segments: Int = defaultSegments,
        name: String? = nil
    ) -> Mesh {
        threadedSurface(
            of: implant,
            circumferentialSegments: Swift.max(Swift.min(Swift.max(segments, 3), 512) / 4, 3),
            axialSamplesPerPitch: 2,
            maximumAxialIntervals: 1_024,
            name: name
        )
    }

    private static func threadedSurface(
        of implant: ImplantPlacement,
        circumferentialSegments sides: Int,
        axialSamplesPerPitch: Int,
        maximumAxialIntervals: Int,
        name: String?
    ) -> Mesh {
        let model = implant.model
        guard model.threadPitchMM.isFinite, model.threadPitchMM > 0,
              model.threadDepthMM.isFinite, model.threadDepthMM > 0
        else {
            return surface(of: implant, segments: sides, name: name)
        }

        let label = name ?? (implant.label.isEmpty ? "Impianto" : implant.label)
        guard model.profile.count >= 2, let axis = implant.axis.normalized else {
            return Mesh(verticesMM: [], triangles: [], name: label)
        }

        let length = model.profile.last?.zMM ?? model.lengthMM
        let turns = length / model.threadPitchMM
        let requestedIntervals = turns * Double(axialSamplesPerPitch)
        // I parametri sono pubblici e possono arrivare da documenti esterni: il tetto evita
        // sia la conversione di infinito a Int sia una mesh capace di esaurire la memoria.
        let sampledIntervals = requestedIntervals.isFinite
            ? Int(Foundation.ceil(Swift.min(requestedIntervals, Double(maximumAxialIntervals))))
            : maximumAxialIntervals
        let intervals = Swift.max(
            Swift.min(model.profile.count - 1, maximumAxialIntervals),
            sampledIntervals
        )
        let (right, up) = perpendicularFrame(to: axis)
        var vertices: [Vec3] = []
        var triangles: [Triangle] = []
        vertices.reserveCapacity((intervals + 1) * sides + 2)
        triangles.reserveCapacity(intervals * sides * 2 + sides * 2)

        for ring in 0...intervals {
            let z = length * Double(ring) / Double(intervals)
            let centre = implant.platformMM + axis * z
            let profileRadius = model.radius(atZ: z)
            for side in 0..<sides {
                let angle = 2 * Double.pi * Double(side) / Double(sides)
                let phase = 2 * Double.pi * z / model.threadPitchMM - angle
                // Una cosinusoide dà cresta e fondo senza discontinuità: le normali restano
                // definite e la differenza cresta-fondo coincide con la profondità richiesta.
                let groove = model.threadDepthMM * (1 + Foundation.cos(phase)) / 2
                let radius = Swift.max(profileRadius - groove, 0)
                let offset =
                    right * (Foundation.cos(angle) * radius)
                    + up * (Foundation.sin(angle) * radius)
                vertices.append(centre + offset)
            }
        }

        for ring in 0..<intervals {
            let lower = ring * sides
            let upper = (ring + 1) * sides
            for side in 0..<sides {
                let next = (side + 1) % sides
                triangles.append(Triangle(a: lower + side, b: upper + next, c: upper + side))
                triangles.append(Triangle(a: lower + side, b: lower + next, c: upper + next))
            }
        }

        let platformCentre = vertices.count
        vertices.append(implant.platformMM)
        for side in 0..<sides {
            let next = (side + 1) % sides
            triangles.append(Triangle(a: platformCentre, b: next, c: side))
        }

        let apexRing = intervals * sides
        let apexCentre = vertices.count
        vertices.append(implant.platformMM + axis * length)
        for side in 0..<sides {
            let next = (side + 1) % sides
            triangles.append(Triangle(a: apexCentre, b: apexRing + side, c: apexRing + next))
        }

        return Mesh(verticesMM: vertices, triangles: triangles, name: label)
    }

    /// La sagoma del dente come scatola chiusa.
    ///
    /// - Parameter mesialDirectionMM: la tangente all'arcata, come per
    ///   `ProstheticTooth.corners(mesialDirectionMM:)`. Senza, l'orientamento attorno all'asse è
    ///   convenzionale.
    public static func surface(
        of tooth: ProstheticTooth,
        mesialDirectionMM: Vec3? = nil,
        name: String? = nil
    ) -> Mesh {
        let corners = tooth.corners(mesialDirectionMM: mesialDirectionMM)
        let label = name ?? (tooth.label.isEmpty ? "Dente \(tooth.toothNumber)" : tooth.label)
        guard corners.count == 8 else {
            return Mesh(verticesMM: [], triangles: [], name: label)
        }

        // `corners` elenca prima la faccia occlusale — indici 0…3 — poi quella apicale, ciascuna
        // percorsa in giro. Le sei facce si scrivono da quella disposizione.
        //
        // L'ordine dentro ogni faccia è quello che manda la normale **fuori**. Anche qui la
        // prima stesura era invertita, e anche qui il conteggio degli spigoli non se ne
        // accorgeva: l'ha trovata il volume con segno, che per una scatola deve valere
        // esattamente il prodotto dei tre lati e valeva l'opposto.
        let faces: [(Int, Int, Int, Int)] = [
            (0, 3, 2, 1),  // occlusale: normale verso l'antagonista, cioè −asse
            (4, 5, 6, 7),  // apicale: normale verso l'apice, cioè +asse
            (0, 1, 5, 4),
            (1, 2, 6, 5),
            (2, 3, 7, 6),
            (3, 0, 4, 7),
        ]

        var triangles: [Triangle] = []
        for face in faces {
            triangles.append(Triangle(a: face.0, b: face.1, c: face.2))
            triangles.append(Triangle(a: face.0, b: face.2, c: face.3))
        }
        return Mesh(verticesMM: corners, triangles: triangles, name: label)
    }

    /// Due versori perpendicolari all'asse e fra loro.
    ///
    /// Per un solido di rotazione la scelta è **libera**: girando attorno all'asse la superficie
    /// è la stessa, e non c'è un verso privilegiato da rispettare. Si prende l'asse coordinato
    /// meno allineato, così la differenza non degenera qualunque sia l'inclinazione.
    private static func perpendicularFrame(to axis: Vec3) -> (right: Vec3, up: Vec3) {
        let candidates = [Vec3(1, 0, 0), Vec3(0, 1, 0), Vec3(0, 0, 1)]
        var chosen = candidates[0]
        var smallest = Double.infinity
        for candidate in candidates {
            let alignment = Swift.abs(candidate.dot(axis))
            if alignment < smallest {
                smallest = alignment
                chosen = candidate
            }
        }
        let right = (chosen - axis * axis.dot(chosen)).normalized ?? Vec3(1, 0, 0)
        let up = axis.cross(right).normalized ?? Vec3(0, 1, 0)
        return (right, up)
    }
}
