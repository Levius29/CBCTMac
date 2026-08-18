import DICOMCore
import Foundation
import ImplantKit
import MeasureKit

// Che cosa non torna in un piano, prima che diventi un oggetto.
//
// # Perché una lista e non un semaforo
//
// Perché i problemi di un piano non sono commensurabili. «L'impianto tocca il canale» e «la dima
// non passa le verifiche» sono entrambi bloccanti e vanno letti tutt'e due; ridurli a un colore
// costringerebbe a scegliere quale mostrare.
//
// # Il controllo che nessuno mette, ed è il più importante
//
// **Impianti pianificati senza aver tracciato alcun canale.** L'analisi di sicurezza gira lo
// stesso e non trova nulla, perché non c'è nulla con cui confrontare: il piano risulta sicuro
// per assenza di verifica, non per verifica superata. È la forma più insidiosa di falso
// rassicurante — nessun messaggio, nessun avviso, tutto verde — e distinguerla dal caso in cui
// il canale è stato tracciato e l'impianto sta lontano è esattamente il lavoro di questa
// funzione.

public enum PlanIssueSeverity: Int, Sendable, Comparable {
    /// Da risolvere prima di produrre qualunque cosa di fisico.
    case blocking = 2
    /// Da guardare: può essere una scelta consapevole.
    case warning = 1
    /// Da sapere, non da correggere.
    case note = 0

    public static func < (a: PlanIssueSeverity, b: PlanIssueSeverity) -> Bool {
        a.rawValue < b.rawValue
    }

    public var localizedName: String {
        switch self {
        case .blocking: return "Bloccante"
        case .warning: return "Da guardare"
        case .note: return "Nota"
        }
    }
}

public struct PlanIssue: Hashable, Sendable, Identifiable {
    public let id: String
    public let severity: PlanIssueSeverity
    public let title: String
    public let detail: String

    public init(id: String, severity: PlanIssueSeverity, title: String, detail: String) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

public enum PlanReview {

    /// Inclinazione oltre la quale una corona ha bisogno di un moncone angolato.
    public static let angulationWarningDegrees: Double = 25

    /// Tutto ciò che non torna, dal più grave.
    public static func issues(in input: PlanReportInput) -> [PlanIssue] {
        var found: [PlanIssue] = []
        found += nerveCoverageIssues(input)
        found += implantIssues(input)
        found += prostheticIssues(input)
        found += measurementIssues(input)
        found += workflowIssues(input)
        // Stabile: a parità di gravità resta l'ordine in cui sono stati raccolti, così la lista
        // non si rimescola fra due aperture della stessa finestra.
        return found.enumerated()
            .sorted {
                $0.element.severity != $1.element.severity
                    ? $0.element.severity > $1.element.severity
                    : $0.offset < $1.offset
            }
            .map(\.element)
    }

    // MARK: Il falso rassicurante

    private static func nerveCoverageIssues(_ input: PlanReportInput) -> [PlanIssue] {
        guard !input.implants.isEmpty else { return [] }

        // Un rapporto senza alcun riscontro può voler dire due cose opposte: che si è verificato
        // e va bene, o che non c'era nulla da verificare. Le si distingue guardando se **qualche**
        // rapporto contiene un riscontro: nessuno significa nessuna struttura tracciata.
        let anyFinding = input.safetyReports.values.contains { !$0.findings.isEmpty }
        guard !anyFinding else { return [] }

        return [
            PlanIssue(
                id: "nerve-not-traced",
                severity: .blocking,
                title: "Nessuna struttura da evitare è stata tracciata",
                detail:
                    "Ci sono \(input.implants.count) impianti e nessun canale tracciato. "
                    + "L'analisi di sicurezza non ha segnalato nulla perché non aveva nulla con "
                    + "cui confrontare: il piano risulta sicuro per **assenza di verifica**, non "
                    + "per verifica superata.")
        ]
    }

    // MARK: Gli impianti

    private static func implantIssues(_ input: PlanReportInput) -> [PlanIssue] {
        var found: [PlanIssue] = []

        for implant in input.implants {
            guard let report = input.safetyReports[implant.id] else { continue }

            for finding in report.findings where finding.level == .danger {
                found.append(
                    PlanIssue(
                        id: "danger-\(implant.id)-\(finding.structureName)",
                        severity: .blocking,
                        title: "\(implant.label): \(finding.structureName) a \(finding.formattedDistance)",
                        detail:
                            "Sotto il margine di sicurezza. Sposta l'impianto, accorcialo, o "
                            + "verifica che il tracciato del canale sia corretto in quel punto."))
            }

            for finding in report.findings where finding.level == .caution {
                found.append(
                    PlanIssue(
                        id: "caution-\(implant.id)-\(finding.structureName)",
                        severity: .warning,
                        title: "\(implant.label): \(finding.structureName) a \(finding.formattedDistance)",
                        detail:
                            "Entro il margine di attenzione. Può essere una scelta, ma va fatta "
                            + "sapendo che l'incertezza del tracciato a mano è dello stesso "
                            + "ordine di questa distanza."))
            }

            if let angulation = implant.angleDegrees(to: Vec3(0, 0, 1)),
                angulation > angulationWarningDegrees
            {
                found.append(
                    PlanIssue(
                        id: "angulation-\(implant.id)",
                        severity: .warning,
                        title: String(
                            format: "%@: inclinato di %.0f°", implant.label, angulation),
                        detail:
                            "Oltre i \(Int(angulationWarningDegrees))° serve un moncone angolato, "
                            + "e il carico sull'osso cambia. Verifica che sia voluto."))
            }
        }

        return found
    }

    // MARK: La protesi

    /// Il gemello protesico del controllo sul canale.
    ///
    /// Vale la stessa logica, e per la stessa ragione: un piano senza denti posati non è un
    /// piano protesicamente corretto — è un piano di cui non si è verificata la correttezza
    /// protesica. La distinzione non è formale. Un impianto messo dove c'era osso comodo, in
    /// assenza di una sagoma che dica dove la protesi lo vuole, può risultare perfetto in ogni
    /// altra verifica e restare inutilizzabile: emerge dove non può esserci una corona.
    private static func prostheticIssues(_ input: PlanReportInput) -> [PlanIssue] {
        guard !input.implants.isEmpty else { return [] }
        var found: [PlanIssue] = []

        if input.prostheticToothCount == 0 {
            found.append(
                PlanIssue(
                    id: "prosthetic-none",
                    severity: .warning,
                    title:
                        "\(input.implants.count) impianti pianificati senza alcun riferimento "
                        + "protesico",
                    detail:
                        "Nessun dente è stato posato, quindi non è stato verificato dove gli "
                        + "impianti emergono. L'assenza di segnalazioni protesiche in questa "
                        + "relazione non significa che il piano sia protesicamente corretto: "
                        + "significa che non è stato controllato."))
            return found
        }

        for implant in input.implants {
            guard let constraint = input.prostheticConstraints[implant.id] else {
                found.append(
                    PlanIssue(
                        id: "prosthetic-orphan-\(implant.id)",
                        severity: .warning,
                        title: "\(implant.label): nessun dente sopra",
                        detail:
                            "Sono stati posati denti protesici, ma nessuno abbastanza vicino a "
                            + "questo impianto. O manca la corona che deve sostenere, o "
                            + "l'impianto sta lontano dal punto in cui la protesi la vuole."))
                continue
            }

            switch constraint.severity {
            case .unacceptable:
                let detail: String
                if constraint.emergenceMM == nil {
                    detail =
                        "L'asse dell'impianto è parallelo al piano occlusale del dente: non "
                        + "esiste un punto di emergenza. È quasi certamente un errore di posa."
                } else if !constraint.emergesWithinCrown {
                    detail =
                        "L'asse esce fuori dal perimetro della corona. Nessun moncone angolato "
                        + "recupera questo: va spostato l'impianto, o va rivisto dove sta il "
                        + "dente."
                } else {
                    detail =
                        "La divergenza fra asse implantare e asse protesico supera la soglia "
                        + "impostata. Verifica che la connessione scelta ammetta un moncone di "
                        + "quell'angolo."
                }
                found.append(
                    PlanIssue(
                        id: "prosthetic-bad-\(implant.id)",
                        severity: .blocking,
                        title: "\(implant.label): \(constraint.summary)",
                        detail: detail))

            case .caution:
                found.append(
                    PlanIssue(
                        id: "prosthetic-caution-\(implant.id)",
                        severity: .warning,
                        title: "\(implant.label): \(constraint.summary)",
                        detail:
                            "Entro il margine di attenzione. Recuperabile con un moncone "
                            + "angolato, purché il sistema implantare lo preveda."))

            case .acceptable:
                break
            }
        }

        return found
    }

    // MARK: Le misure

    private static func measurementIssues(_ input: PlanReportInput) -> [PlanIssue] {
        var found: [PlanIssue] = []
        var projected = 0
        var curved = 0
        var withoutContext = 0

        for annotation in input.annotations {
            guard let context = annotation.metadata.acquisition else {
                withoutContext += 1
                continue
            }
            let quality = MeasurementUncertainty.quality(ofLengthMM: 0, context: context)
            for caveat in quality.caveats {
                switch caveat {
                case .projectedSlab: projected += 1
                case .curvedSurface: curved += 1
                case .derivedVolume: break
                }
            }
        }

        if projected > 0 {
            found.append(
                PlanIssue(
                    id: "measurements-projected",
                    severity: .warning,
                    title: "\(projected) misure prese su una proiezione",
                    detail:
                        "Le due estremità possono stare a profondità diverse: la distanza vera "
                        + "**supera** quella letta. Rifalle su una fetta singola se il numero "
                        + "conta."))
        }

        if curved > 0 {
            found.append(
                PlanIssue(
                    id: "measurements-curved",
                    severity: .warning,
                    title: "\(curved) misure prese sulla panorex",
                    detail:
                        "Sono distanze fra due punti della superficie ricostruita, non fra due "
                        + "strutture anatomiche. Per una distanza vera vale la sezione "
                        + "trasversale."))
        }

        if withoutContext > 0 {
            found.append(
                PlanIssue(
                    id: "measurements-no-context",
                    severity: .note,
                    title: "\(withoutContext) misure senza contesto di acquisizione",
                    detail:
                        "Vengono da un piano salvato prima che il contesto venisse registrato: "
                        + "non portano la propria incertezza."))
        }

        return found
    }

    // MARK: La lavorazione

    private static func workflowIssues(_ input: PlanReportInput) -> [PlanIssue] {
        var found: [PlanIssue] = []

        // Una dima esiste: allora la registrazione è il termine che limita tutto.
        if input.guideVolumeMM3 != nil {
            if input.registrationRMSMM == nil {
                found.append(
                    PlanIssue(
                        id: "guide-without-registration",
                        severity: .blocking,
                        title: "Dima costruita senza scansione registrata",
                        detail:
                            "La dima appoggia sui denti e sa dove sono solo se la scansione è "
                            + "allineata alla CBCT. Così com'è, è riferita a uno spazio che non "
                            + "è quello del paziente."))
            } else if let rms = input.registrationRMSMM, rms > 0.5 {
                found.append(
                    PlanIssue(
                        id: "guide-poor-registration",
                        severity: .blocking,
                        title: String(
                            format: "Dima su una registrazione da %.2f mm", rms
                        ).replacingOccurrences(of: ".", with: ","),
                        detail:
                            "Il disallineamento della scansione è disallineamento della dima, e "
                            + "la dima non lo recupera: è quanto l'impianto sbaglierà."))
            }

            if input.guideIsPrintable == false {
                found.append(
                    PlanIssue(
                        id: "guide-not-printable",
                        severity: .blocking,
                        title: "La dima non supera le verifiche",
                        detail: input.guideWarnings.isEmpty
                            ? "Le verifiche di stampabilità non sono superate."
                            : input.guideWarnings.joined(separator: " · ")))
            }
        }

        return found
    }
}
