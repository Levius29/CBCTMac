import DICOMCore
import Testing

@testable import ImplantKit

// Il modello parametrico, senza passare dalla mesh.
//
// Queste prove tengono separati due contratti che altrimenti si confondono facilmente: il
// profilo stabilisce l'ingombro radiale a ogni quota, mentre la base perpendicolare stabilisce
// come quell'ingombro viene orientato nello spazio Patient.

@Suite("Modello geometrico dell'impianto")
struct ImplantTests {

    private func model(profile: [ProfilePoint]) -> ImplantModel {
        ImplantModel(
            manufacturer: "Prova",
            line: "Profilo",
            diameterMM: 8,
            lengthMM: 12,
            platformDiameterMM: 8,
            apexDiameterMM: 2,
            profile: profile)
    }

    @Test("Il raggio interpola linearmente il profilo")
    func radiusInterpolatesProfile() {
        let implant = model(profile: [
            ProfilePoint(zMM: 0, radiusMM: 4),
            ProfilePoint(zMM: 4, radiusMM: 3),
            ProfilePoint(zMM: 12, radiusMM: 1),
        ])

        #expect(implant.radius(atZ: 0) == 4)
        #expect(implant.radius(atZ: 2) == 3.5)
        #expect(implant.radius(atZ: 8) == 2)
        #expect(implant.radius(atZ: 12) == 1)
    }

    @Test("Fuori dal profilo il raggio resta sull'estremo più vicino")
    func radiusClampsToProfileEnds() {
        let implant = model(profile: [
            ProfilePoint(zMM: 2, radiusMM: 3),
            ProfilePoint(zMM: 10, radiusMM: 1),
        ])

        #expect(implant.radius(atZ: -100) == 3)
        #expect(implant.radius(atZ: 100) == 1)
        #expect(model(profile: []).radius(atZ: 6) == 4)
    }

    @Test("La base perpendicolare è ortonormale e orientata con l'asse")
    func perpendicularBasisIsOrthonormal() throws {
        let placement = ImplantPlacement(
            model: model(profile: []),
            platformMM: .zero,
            axis: Vec3(1, -2, 3))
        let basis = try #require(placement.perpendicularBasis())

        #expect(abs(basis.u.length - 1) < 1e-12)
        #expect(abs(basis.v.length - 1) < 1e-12)
        #expect(abs(basis.u.dot(placement.axis)) < 1e-12)
        #expect(abs(basis.v.dot(placement.axis)) < 1e-12)
        #expect(abs(basis.u.dot(basis.v)) < 1e-12)
        #expect(basis.u.cross(basis.v).distance(to: placement.axis) < 1e-12)
    }

    @Test("Una base non viene inventata per un asse nullo")
    func perpendicularBasisRejectsZeroAxis() {
        var placement = ImplantPlacement(platformMM: .zero)
        // L'inizializzatore protegge l'uso normale; la proprietà resta mutabile per la
        // decodifica e può ricevere dati corrotti, che non devono generare versori arbitrari.
        placement.axis = .zero

        #expect(placement.perpendicularBasis()?.u == nil)
    }
}
