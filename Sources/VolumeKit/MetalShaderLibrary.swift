#if canImport(Metal)

import Foundation
import Metal

/// Caricamento della libreria Metal di un modulo.
///
/// Esiste per una ragione precisa. I renderer chiamavano `makeDefaultLibrary(bundle:)`, che
/// pretende un `default.metallib` **già compilato** dentro il bundle delle risorse. Un progetto
/// Xcode lo produce; SwiftPM no: `.process("Shaders")` si limita a **copiare** i file `.metal`
/// nel bundle, come si vede nel log di compilazione (`Copying MPR.metal`). Il risultato era che
/// il pacchetto compilava senza un errore e poi, al primo avvio, nessun renderer riusciva a
/// nascere. Un difetto che nessun test poteva vedere, perché i test non hanno un dispositivo
/// Metal.
///
/// La strategia è quindi doppia, nell'ordine:
///
/// 1. il `.metallib` precompilato, se c'è — è il caso di un vero target Xcode, e non costa nulla
///    a runtime;
/// 2. altrimenti il sorgente `.metal` dal bundle, compilato all'avvio.
///
/// La seconda via costa qualche centinaio di millisecondi una volta per libreria, e in cambio
/// rende il pacchetto SwiftPM eseguibile senza la toolchain Metal di Xcode. Per kernel di questa
/// dimensione è un prezzo che non si percepisce.
public enum MetalShaderLibrary {

    /// Carica la libreria che contiene i kernel del file indicato.
    ///
    /// - Parameters:
    ///   - device: dispositivo su cui compilare.
    ///   - bundle: bundle delle risorse del modulo, di norma `Bundle.module`.
    ///   - sourceName: nome del file `.metal` **senza estensione**. Ogni file dei nostri shader è
    ///     autonomo — include soltanto `metal_stdlib` — quindi compilarne uno alla volta è
    ///     sufficiente e permette a ogni renderer di caricare solo ciò che gli serve.
    public static func load(
        device: MTLDevice,
        bundle: Bundle,
        sourceName: String
    ) throws -> MTLLibrary {
        if let precompiled = try? device.makeDefaultLibrary(bundle: bundle) {
            return precompiled
        }

        guard let url = bundle.url(forResource: sourceName, withExtension: "metal") else {
            throw MetalShaderLibraryError.sourceNotFound(
                name: sourceName, bundlePath: bundle.bundlePath)
        }

        let source: String
        do {
            source = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw MetalShaderLibraryError.sourceUnreadable(
                name: sourceName, underlying: String(describing: error))
        }

        do {
            return try device.makeLibrary(source: source, options: nil)
        } catch {
            // Qui finisce un errore di sintassi negli shader. Compilando a runtime non lo
            // intercetta più il build, quindi il messaggio del compilatore Metal va riportato
            // per intero: è l'unico posto in cui si vede.
            throw MetalShaderLibraryError.compilationFailed(
                name: sourceName, underlying: String(describing: error))
        }
    }
}

public enum MetalShaderLibraryError: Error, LocalizedError {
    case sourceNotFound(name: String, bundlePath: String)
    case sourceUnreadable(name: String, underlying: String)
    case compilationFailed(name: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .sourceNotFound(let name, let path):
            return """
                Shader «\(name).metal» non trovato, e nessuna libreria Metal precompilata nel \
                bundle \(path). Se l'applicazione è stata assemblata a mano, controlla che i \
                bundle di risorse di SwiftPM siano stati copiati in Contents/Resources.
                """
        case .sourceUnreadable(let name, let detail):
            return "Shader «\(name).metal» illeggibile: \(detail)"
        case .compilationFailed(let name, let detail):
            return "Compilazione dello shader «\(name).metal» fallita: \(detail)"
        }
    }
}

#endif
