import AppKit
import SwiftUI

// L'icona dell'applicazione, disegnata invece che importata.
//
// # Perché in codice e non un PNG
//
// Un'icona è una **forma**, non un'immagine: serve nitida a 16 punti nel Dock e a 1024 nel
// Finder, e un file raster obbliga a decidere in anticipo quante misure servono e a rigenerarle
// tutte a ogni ritocco. Disegnata in coordinate normalizzate esce esatta a qualunque dimensione,
// non porta binari nel repository, e la stessa sorgente serve sia per il Dock a runtime sia per
// esportare l'`.icns` della distribuzione.
//
// # Perché serve anche a runtime
//
// Perché l'eseguibile SPM non è un bundle: `swift run` avvia un processo senza `Info.plist` e
// senza `.icns`, e il Dock mostra l'icona generica del terminale. Assegnare
// `NSApp.applicationIconImage` all'avvio dà l'icona giusta senza aspettare l'impacchettamento.

enum AppIcon {

    /// Nome mostrato dell'applicazione.
    ///
    /// Il pacchetto e i moduli restano `CBCTMac`: quello è il nome del **codice**, e cambiarlo
    /// tocca ogni `import` senza cambiare nulla di ciò che si vede.
    static let displayName = "3DMED"

    /// Assegna l'icona al Dock. Da chiamare una volta all'avvio.
    static func install() {
        NSApp.applicationIconImage = image(size: 512)
    }

    /// Rende l'icona in un `NSImage` quadrato del lato richiesto.
    @MainActor
    static func image(size: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: AppIconMark().frame(width: size, height: size))
        // Uno a uno: la misura richiesta è già in pixel, e lasciare che sia il display a
        // moltiplicarla darebbe un'icona di lato doppio a chi la esporta su schermo Retina.
        renderer.scale = 1
        return renderer.nsImage
    }

    /// Misure richieste da un `.iconset` di macOS, con il suffisso del nome file.
    ///
    /// Le `@2x` non sono un capriccio: il Finder sceglie il file in base alla densità dello
    /// schermo, e un iconset senza di esse è sfocato su ogni Mac degli ultimi dieci anni.
    static let iconsetSizes: [(pixels: Int, name: String)] = [
        (16, "icon_16x16"), (32, "icon_16x16@2x"),
        (32, "icon_32x32"), (64, "icon_32x32@2x"),
        (128, "icon_128x128"), (256, "icon_128x128@2x"),
        (256, "icon_256x256"), (512, "icon_256x256@2x"),
        (512, "icon_512x512"), (1024, "icon_512x512@2x"),
    ]

    /// Scrive un `.iconset` completo in una cartella. Da lì, `iconutil -c icns` fa il resto.
    ///
    /// - Returns: il numero di file scritti.
    @MainActor
    @discardableResult
    static func exportIconset(to directory: URL) throws -> Int {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        var written = 0
        for entry in iconsetSizes {
            guard
                let image = image(size: CGFloat(entry.pixels)),
                let tiff = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            else { continue }
            try png.write(to: directory.appendingPathComponent("\(entry.name).png"))
            written += 1
        }
        return written
    }
}

// MARK: - Il segno

/// Cranio bianco su nero con il nome in arancione.
///
/// Tutte le coordinate sono frazioni del lato, così la forma non dipende dalla misura. Il
/// dettaglio è calibrato sui **16 punti** del Dock, non sui 1024 del Finder: a quella misura
/// sopravvivono solo la cupola, due orbite scure e la fila dei denti, e sono quelle tre cose a
/// dover essere giuste. Un cranio pieno di suture sarebbe più bello nell'anteprima e una macchia
/// grigia dove lo si guarda davvero.
struct AppIconMark: View {

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let rect = CGRect(x: 0, y: 0, width: side, height: side)

            ZStack {
                // Fondo. L'angolo è quello del superellisse di macOS, 22,37 % del lato: un
                // raggio diverso si nota subito accanto alle altre icone del Dock.
                RoundedRectangle(cornerRadius: side * 0.2237, style: .continuous)
                    .fill(Color(hex: 0x0A0A0B))

                skull(in: rect)

                Text(AppIcon.displayName)
                    .font(.system(size: side * 0.145, weight: .heavy, design: .rounded))
                    .tracking(side * 0.012)
                    .foregroundStyle(Palette.warning)
                    .position(x: side * 0.5, y: side * 0.845)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    /// Il cranio: sagoma piena, poi le cavità ritagliate nel colore del fondo.
    ///
    /// Ritagliate e non disegnate sopra in nero: sono la stessa cosa qui, perché il fondo è
    /// uniforme, ma tenerle come sottrazioni lascia l'icona corretta se un giorno il fondo
    /// diventasse una sfumatura.
    private func skull(in rect: CGRect) -> some View {
        let side = rect.width
        return Canvas { context, _ in
            context.fill(outline(side: side), with: .color(Color(hex: 0xF5F5F7)))
            context.blendMode = .destinationOut
            context.fill(cavities(side: side), with: .color(.black))
        }
        .frame(width: side, height: side)
        // `compositingGroup` è indispensabile: senza, `destinationOut` mangerebbe anche il
        // fondo dell'icona invece del solo cranio.
        .compositingGroup()
    }

    /// Sagoma frontale: cupola, zigomi, mascellare che scende sulla fila dei denti.
    private func outline(side: CGFloat) -> Path {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: side * x, y: side * y)
        }

        var path = Path()
        path.move(to: point(0.220, 0.400))
        // Cupola cranica, in un solo tratto: due controlli larghi danno una calotta piena, che è
        // ciò che rende riconoscibile un cranio prima ancora delle orbite.
        path.addCurve(
            to: point(0.780, 0.400),
            control1: point(0.220, 0.115),
            control2: point(0.780, 0.115))
        // Discesa temporale fino allo zigomo.
        path.addCurve(
            to: point(0.740, 0.520),
            control1: point(0.780, 0.470),
            control2: point(0.768, 0.500))
        // Rientranza sotto lo zigomo verso il mascellare.
        path.addCurve(
            to: point(0.648, 0.596),
            control1: point(0.712, 0.556),
            control2: point(0.686, 0.578))
        // Arcata dentaria: bordo destro, base, bordo sinistro.
        path.addLine(to: point(0.648, 0.688))
        path.addCurve(
            to: point(0.352, 0.688),
            control1: point(0.588, 0.726),
            control2: point(0.412, 0.726))
        path.addLine(to: point(0.352, 0.596))
        path.addCurve(
            to: point(0.260, 0.520),
            control1: point(0.314, 0.578),
            control2: point(0.288, 0.556))
        path.addCurve(
            to: point(0.220, 0.400),
            control1: point(0.232, 0.500),
            control2: point(0.220, 0.470))
        path.closeSubpath()
        return path
    }

    /// Orbite, apertura nasale e interstizi dei denti.
    private func cavities(side: CGFloat) -> Path {
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
            CGRect(x: side * x, y: side * y, width: side * w, height: side * h)
        }

        var path = Path()

        // Orbite. Leggermente più alte che larghe e inclinate verso il naso: due cerchi
        // renderebbero un teschio da cartone animato.
        for centreX in [0.382, 0.618] {
            let orbit = rect(centreX - 0.098, 0.318, 0.196, 0.170)
            path.addPath(
                Path(roundedRect: orbit, cornerSize: CGSize(width: side * 0.055, height: side * 0.06)))
        }

        // Apertura piriforme: due lobi che si toccano in alto, come nel vero.
        var nose = Path()
        nose.move(to: CGPoint(x: side * 0.500, y: side * 0.470))
        nose.addCurve(
            to: CGPoint(x: side * 0.548, y: side * 0.556),
            control1: CGPoint(x: side * 0.528, y: side * 0.498),
            control2: CGPoint(x: side * 0.548, y: side * 0.526))
        nose.addLine(to: CGPoint(x: side * 0.452, y: side * 0.556))
        nose.addCurve(
            to: CGPoint(x: side * 0.500, y: side * 0.470),
            control1: CGPoint(x: side * 0.452, y: side * 0.526),
            control2: CGPoint(x: side * 0.472, y: side * 0.498))
        nose.closeSubpath()
        path.addPath(nose)

        // Solco gengivale e interstizi: cinque tagli verticali sull'arcata. Sotto i 32 punti si
        // fondono in un grigio, ed è il comportamento voluto — a quella misura la fila di denti
        // deve leggersi come una fascia, non come denti singoli sgranati.
        path.addRect(rect(0.352, 0.594, 0.296, 0.012))
        for offset in [0.412, 0.470, 0.528, 0.586] {
            path.addRect(rect(offset - 0.007, 0.606, 0.014, 0.078))
        }

        return path
    }
}
