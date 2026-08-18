import DICOMCore
import SwiftUI

// Token di design.
//
// Valori da docs/ui-spec.md § 2, allineati ai mockup in docs/mockups. Centralizzati qui perché
// un colore ripetuto a mano in dodici viste diventa dodici colori leggermente diversi alla
// prima modifica.

enum Palette {

    // MARK: Superfici

    /// Fondo dei riquadri immagine. Nero pieno, non grigio scuro: la radiologia si legge su
    /// nero, e qualunque schiarita riduce i livelli di grigio distinguibili.
    static let viewportBackground = Color.black
    static let chrome = Color(hex: 0x1C1C1E)
    static let chromeElevated = Color(hex: 0x2C2C2E)
    static let separator = Color(hex: 0x38383A)

    // MARK: Testo

    static let textPrimary = Color(hex: 0xF2F2F7)
    static let textSecondary = Color(hex: 0x8E8E93)

    // MARK: Accento e stati

    static let accent = Color(hex: 0x32B8C6)
    static let warning = Color(hex: 0xFF9F0A)
    static let danger = Color(hex: 0xFF453A)
    static let caution = Color(hex: 0xFFD60A)
    static let safe = Color(hex: 0x30D158)

    // MARK: Colori dei piani

    // Convenzione 3D Slicer: e' quella che chiunque abbia usato software di imaging riconosce
    // senza doverla imparare.
    static let axial = Color(hex: 0xF1554C)
    static let coronal = Color(hex: 0x4FCB6B)
    static let sagittal = Color(hex: 0xFFD426)
    static let volume3D = Color(hex: 0x32B8C6)

    /// L'unica traduzione da piano anatomico a colore.
    ///
    /// Il colore di un piano compare in almeno quattro posti — il bordo del suo riquadro, le sue
    /// tracce nelle altre due viste, il rettangolo che lo rappresenta nel 3D, l'etichetta nella
    /// barra di stato — e devono essere lo stesso colore. Ripetere lo `switch` in quattro file
    /// significa che alla prima modifica tre di essi restano indietro, e un colore che quasi
    /// coincide è peggio di uno palesemente diverso: sembra intenzionale.
    static func color(for plane: AnatomicalPlane) -> Color {
        switch plane {
        case .axial: return axial
        case .coronal: return coronal
        case .sagittal: return sagittal
        }
    }

    /// Colori per la distanza da una struttura da rispettare, usati in Fase 3 per gli allarmi
    /// di prossimita' implanto-nervo.
    static func proximity(distanceMM: Double) -> Color {
        if distanceMM < 1.0 { return danger }
        if distanceMM < 2.0 { return caution }
        return safe
    }
}

enum Metrics {
    static let toolbarHeight: CGFloat = 52
    static let bannerHeight: CGFloat = 24
    static let statusBarHeight: CGFloat = 28
    static let sidebarWidth: CGFloat = 260
    static let inspectorWidth: CGFloat = 300

    static let viewportGap: CGFloat = 2
    static let viewportBorderWidth: CGFloat = 2
    static let cornerRadius: CGFloat = 6

    /// Griglia interna a multipli di 8.
    static let spacingSmall: CGFloat = 4
    static let spacing: CGFloat = 8
    static let spacingLarge: CGFloat = 16
}

enum Typography {
    static let body = Font.system(size: 13)
    static let label = Font.system(size: 11)
    static let sectionHeader = Font.system(size: 11, weight: .semibold).monospacedDigit()

    /// Numeri sempre in monospaziata con cifre tabellari: un valore che balla mentre l'utente
    /// trascina il mouse e' illeggibile, e le misure si leggono di continuo durante il
    /// trascinamento.
    static let numeric = Font.system(size: 12, design: .monospaced)
    static let numericSmall = Font.system(size: 11, design: .monospaced)

    /// Etichetta del piano nell'angolo del riquadro.
    static let viewportLabel = Font.system(size: 11, weight: .semibold).width(.expanded)
}

extension Color {
    /// Costruisce da un intero esadecimale `0xRRGGBB`.
    init(hex: UInt32, opacity: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: opacity
        )
    }
}
