import DICOMCore
import Foundation

// La pagina dell'anteprima.
//
// # Perché HTML e non un programma
//
// Perché un browser ce l'hanno tutti e non va installato, gira su ogni sistema, e una pagina si
// può verificare con `swift test` — che è più di quanto si possa dire di un eseguibile
// compilato per un sistema operativo diverso.
//
// # Perché le immagini stanno in file separati
//
// Perché infilarle nella pagina come `data:` le fa crescere di un terzo e produce un unico file
// da decine di megabyte, che qualche browser apre lentamente e qualche programma di posta
// rifiuta. Con file separati la pagina pesa qualche chilobyte e il browser carica solo la fetta
// che si sta guardando.

public enum PreviewPage: Sendable {

    /// Compone la pagina.
    ///
    /// - Parameters:
    ///   - identity: chi e quale esame, per l'intestazione.
    ///   - previews: le anteprime, nell'ordine in cui si sfogliano.
    ///   - fileNames: i nomi dei file PNG, nello stesso ordine.
    ///   - sliceCount: quante fette ha il volume vero, per dire quante se ne stanno saltando.
    public static func html(
        identity: DICOMExportIdentity,
        previews: [SlicePreview],
        fileNames: [String],
        sliceCount: Int,
        applicationName: String = "3DMED"
    ) -> String {
        let patient = escape(
            identity.patientName.replacingOccurrences(of: "^", with: " ")
                .trimmingCharacters(in: .whitespaces))
        let title = escape(identity.seriesDescription)

        // Nomi e quote in due array paralleli, letti dal cursore: è tutto ciò che serve, e
        // tenere i dati fuori dal codice della pagina la rende leggibile a chi la apre.
        let names = zip(previews, fileNames).map { _, name in "\"\(escape(name))\"" }
            .joined(separator: ",")
        let positions = previews.map { String(format: "%.1f", $0.positionMM) }
            .joined(separator: ",")
        let indices = previews.map { String($0.sliceIndex + 1) }.joined(separator: ",")

        let subtitle: String
        if previews.count < sliceCount {
            subtitle =
                "\(previews.count) fette su \(sliceCount), scelte a passo costante. "
                + "Le altre stanno nei file DICOM."
        } else {
            subtitle = "\(previews.count) fette."
        }

        return """
            <!doctype html>
            <html lang="it">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)\(patient.isEmpty ? "" : " — " + patient)</title>
            <style>
            :root { color-scheme: dark; }
            body { margin: 0; background: #111; color: #eee; font: 14px -apple-system,
                   system-ui, sans-serif; display: flex; flex-direction: column;
                   min-height: 100vh; }
            header { padding: 16px 20px 12px; border-bottom: 1px solid #333; }
            h1 { font-size: 17px; margin: 0 0 2px; }
            .meta { color: #999; font-size: 12.5px; }
            .warn { margin: 12px 20px 0; padding: 10px 14px; background: #2a2113;
                    border-left: 3px solid #d97706; color: #e8c88a; font-size: 12.5px; }
            main { flex: 1; display: flex; align-items: center; justify-content: center;
                   padding: 16px; }
            img { max-width: 100%; max-height: 70vh; image-rendering: pixelated;
                  background: #000; }
            footer { padding: 12px 20px 20px; border-top: 1px solid #333; }
            .row { display: flex; align-items: center; gap: 12px; }
            input[type=range] { flex: 1; }
            .num { font-variant-numeric: tabular-nums; color: #bbb; font-size: 12.5px;
                   min-width: 190px; text-align: right; }
            button { background: #2c2c2e; color: #eee; border: 1px solid #444; border-radius: 5px;
                     padding: 4px 10px; font: inherit; cursor: pointer; }
            .hint { color: #777; font-size: 12px; margin-top: 8px; }
            </style>
            </head>
            <body>
            <header>
              <h1>\(title)</h1>
              <div class="meta">\(patient.isEmpty ? "Paziente non identificato" : patient)\
            \(dateSuffix(identity))</div>
            </header>
            <div class="warn">Anteprima ridotta, non un visore diagnostico:
            queste immagini non si misurano.
            I dati sono i file DICOM nella cartella superiore.</div>
            <main><img id="slice" alt="Fetta"></main>
            <footer>
              <div class="row">
                <button id="prev">◀</button>
                <input type="range" id="cursor" min="0" max="\(max(previews.count - 1, 0))"
                       value="0">
                <button id="next">▶</button>
                <span class="num" id="label"></span>
              </div>
              <div class="hint">Frecce ← → per scorrere. \(escape(subtitle))
              Prodotta da \(escape(applicationName)), software non certificato come dispositivo
              medico.</div>
            </footer>
            <script>
            const names = [\(names)];
            const positions = [\(positions)];
            const indices = [\(indices)];
            const image = document.getElementById('slice');
            const cursor = document.getElementById('cursor');
            const label = document.getElementById('label');
            function show(index) {
              if (!names.length) { label.textContent = 'Nessuna fetta'; return; }
              const clamped = Math.max(0, Math.min(names.length - 1, index));
              cursor.value = clamped;
              image.src = names[clamped];
              label.textContent = 'Fetta ' + indices[clamped] + '  ·  '
                + positions[clamped].toFixed(1).replace('.', ',') + ' mm';
            }
            cursor.addEventListener('input', () => show(Number(cursor.value)));
            document.getElementById('prev').addEventListener(
              'click', () => show(Number(cursor.value) - 1));
            document.getElementById('next').addEventListener(
              'click', () => show(Number(cursor.value) + 1));
            document.addEventListener('keydown', (event) => {
              if (event.key === 'ArrowLeft') { show(Number(cursor.value) - 1); }
              if (event.key === 'ArrowRight') { show(Number(cursor.value) + 1); }
            });
            show(Math.floor(names.length / 2));
            </script>
            </body>
            </html>
            """
    }

    private static func dateSuffix(_ identity: DICOMExportIdentity) -> String {
        let digits = identity.studyDate.filter(\.isNumber)
        guard digits.count == 8 else { return "" }
        let year = digits.prefix(4)
        let month = digits.dropFirst(4).prefix(2)
        let day = digits.dropFirst(6).prefix(2)
        return " — \(day)/\(month)/\(year)"
    }

    /// Le cinque sostituzioni che rendono sicuro mettere un testo dentro una pagina.
    ///
    /// Un nome di paziente arriva dai metadati di un file, e un file può contenere qualunque
    /// cosa. Senza questa, un nome con dentro un `<` romperebbe la pagina — e con dentro uno
    /// `</script>` farebbe di peggio.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }
}
