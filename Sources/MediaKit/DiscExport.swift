import DICOMCore
import Foundation

// La cartella da consegnare.
//
// # Che cosa vuol dire «esportare su disco con visualizzatore»
//
// Nei programmi commerciali vuol dire masterizzare un CD con i file DICOM e un eseguibile
// Windows che li apre. La prima metà si può fare e si fa. La seconda no: distribuire un
// eseguibile altrui non è una cosa che questo programma può fare, e scriverne uno da zero
// sarebbe scrivere un secondo visore per farlo girare su un sistema operativo su cui questo
// programma non gira.
//
// Quel che si consegna al suo posto è più utile e più onesto:
//
// - **i file DICOM**, che sono il dato;
// - un **DICOMDIR**, l'indice previsto dallo standard, che è ciò che trasforma una cartella in
//   un supporto: ogni PACS e ogni visore lo cerca per primo;
// - un'**anteprima in HTML**, che si apre in qualunque browser su qualunque sistema, senza
//   installare niente, e che dice a chiaré lettere di non essere un visore diagnostico;
// - un **LEGGIMI**, perché una cartella con dentro cinquecento file e nessuna spiegazione è una
//   cartella che chi la riceve richiude.
//
// # La riga che conta, nel LEGGIMI
//
// Che le immagini dell'anteprima non si misurano. Sono ridotte, in un formato a otto bit, e
// senza scala: chiunque potrebbe provarci lo stesso, e va detto prima che ci provi.

public struct DiscExportResult: Sendable {
    public var directory: URL
    public var dicomFiles: [URL]
    public var previewCount: Int
    public var indexPage: URL
    public var dicomdir: URL
}

public enum DiscExport: Sendable {

    /// Nome della sottocartella delle anteprime.
    public static let previewFolderName = "anteprima"

    /// Scrive l'intera cartella.
    ///
    /// - Parameters:
    ///   - volume: il volume da consegnare.
    ///   - identity: paziente, studio e serie da scrivere nei file.
    ///   - directory: la cartella da creare. Deve non esistere ancora, o essere vuota: vedi
    ///     `DICOMWriter.availableDirectory`.
    ///   - windowCenterGV: centro della finestra usata per le anteprime.
    ///   - windowWidthGV: ampiezza della finestra usata per le anteprime.
    ///   - applicationName: come si chiama chi ha scritto la cartella, per il LEGGIMI.
    @discardableResult
    public static func write(
        volume: Volume,
        identity: DICOMExportIdentity,
        to directory: URL,
        windowCenterGV: Double,
        windowWidthGV: Double,
        applicationName: String = "3DMED"
    ) throws -> DiscExportResult {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        let series = try DICOMWriter.writeSeries(
            volume: volume, identity: identity, to: directory)

        // L'indice si scrive dopo i file, perché rimanda a essi per nome e per UID.
        let entries = zip(series.files, series.sopInstanceUIDs).enumerated().map {
            index, pair in
            DICOMDIRWriter.ImageEntry(
                fileID: pair.0.lastPathComponent,
                sopClassUID: series.sopClassUID,
                sopInstanceUID: pair.1,
                transferSyntaxUID: series.transferSyntaxUID,
                instanceNumber: index + 1)
        }
        let dicomdir = directory.appendingPathComponent("DICOMDIR")
        try DICOMDIRWriter.data(
            identity: identity,
            studyInstanceUID: series.studyInstanceUID,
            seriesInstanceUID: series.seriesInstanceUID,
            images: entries
        ).write(to: dicomdir, options: .atomic)

        let previewDirectory = directory.appendingPathComponent(previewFolderName)
        try FileManager.default.createDirectory(
            at: previewDirectory, withIntermediateDirectories: true)

        let previews = SlicePreviewBuilder.previews(
            of: volume, windowCenterGV: windowCenterGV, windowWidthGV: windowWidthGV)
        var names: [String] = []
        for (index, preview) in previews.enumerated() {
            let name = String(format: "fetta%03d.png", index + 1)
            try preview.pngData.write(
                to: previewDirectory.appendingPathComponent(name), options: .atomic)
            names.append(name)
        }

        let indexPage = previewDirectory.appendingPathComponent("index.html")
        try PreviewPage.html(
            identity: identity, previews: previews, fileNames: names,
            sliceCount: volume.geometry.sliceCount,
            applicationName: applicationName
        ).write(to: indexPage, atomically: true, encoding: .utf8)

        try readme(
            identity: identity, sliceCount: volume.geometry.sliceCount,
            previewCount: previews.count, applicationName: applicationName
        ).write(
            to: directory.appendingPathComponent("LEGGIMI.txt"), atomically: true,
            encoding: .utf8)

        return DiscExportResult(
            directory: directory, dicomFiles: series.files, previewCount: previews.count,
            indexPage: indexPage, dicomdir: dicomdir)
    }

    /// Il testo del LEGGIMI.
    static func readme(
        identity: DICOMExportIdentity, sliceCount: Int, previewCount: Int,
        applicationName: String
    ) -> String {
        let patient = identity.patientName.replacingOccurrences(of: "^", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return """
            \(identity.seriesDescription)
            \(patient.isEmpty ? "Paziente non identificato" : patient)

            CHE COSA C'È IN QUESTA CARTELLA

              DICOMDIR        L'indice del supporto. È il file che un visore o un PACS cerca per
                              primo: aprendo quello si vedono paziente, studio e serie senza
                              dover aprire le immagini una per una.

              IM*.dcm         Le \(sliceCount) immagini della serie, in formato DICOM non
                              compresso. Questi sono i dati: qualunque programma di refertazione
                              li apre, e sono gli unici su cui si può misurare.

              anteprima/      Una sfogliata rapida in HTML. Si apre con un doppio clic su
                              index.html, in qualunque browser, senza installare niente.

            SULLE ANTEPRIME

            Le immagini dentro «anteprima» sono ridotte e a otto bit, e non portano una scala.
            Servono a vedere che cosa c'è, non a misurarlo. Ogni misura va presa sui file DICOM,
            con un programma che li legga come tali.

            COME APRIRE I DATI

            Su qualunque sistema esistono visori DICOM gratuiti. Si apre il file DICOMDIR, oppure
            si indica alla cartella intera: l'ordine delle fette e la loro posizione nello spazio
            sono scritti nei file, quindi il volume si ricostruisce da solo.

            PROVENIENZA

            Cartella prodotta da \(applicationName). La serie ha identificatori nuovi rispetto
            all'esame acquisito: è un volume esportato, non l'originale del sistema che l'ha
            prodotto. Lo studio è rimasto quello, perché lo studio è la visita.

            \(applicationName) non è certificato come dispositivo medico. Non utilizzabile per
            diagnosi o pianificazione di interventi su pazienti.
            """
    }
}
