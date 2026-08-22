import Foundation

// Il blocco di uniform del raycaster, **fuori** dalla guardia di Metal.
//
// # Perché sta in un file suo
//
// Perché è l'unico pezzo di `VolumeRaycaster` che si possa verificare senza una GPU, ed è anche
// quello che sbagliato non dà segno di sé. Il layout dev'essere identico byte per byte a
// `RaycastUniforms` in `Shaders/Raycast.metal`: un campo aggiunto senza il riempimento che
// completa il gruppo da sedici byte non produce né un errore né un avviso — produce campi letti
// dal posto sbagliato, cioè un'immagine sbagliata per una ragione che nel codice che disegna non
// si vede.
//
// Dentro `#if canImport(Metal)` una prova non lo raggiungerebbe nemmeno: qui il bersaglio
// dell'applicazione non si compila, e il modulo non espone il tipo. Sono dati puri — `SIMD4` e
// scalari, nessun tipo di Metal — quindi non c'è ragione perché stia sotto la guardia.

/// Uniform del raycaster. Il layout deve corrispondere byte per byte a `RaycastUniforms`
/// in `Shaders/Raycast.metal`.
struct RaycastUniforms {
    var texOrigin: SIMD4<Float>
    var texRightStep: SIMD4<Float>
    var texDownStep: SIMD4<Float>
    var texRayStep: SIMD4<Float>
    var gradientScale: SIMD4<Float>
    var lightDirection: SIMD4<Float>

    var sampleCount: Int32
    var rawScale: Float
    var rawOffset: Float
    var rescaleSlope: Float

    var rescaleIntercept: Float
    var densityMin: Float
    var densityMax: Float
    var ambient: Float

    var diffuse: Float
    var specular: Float
    var shininess: Float
    var gradientStepTex: Float

    var boundarySharpness: Float
    var gradientReference: Float
    /// Allineamento a sedici byte. Il layout deve corrispondere byte per byte a quello Metal, e
    /// un gruppo di tre `float` lascerebbe al compilatore la libertà di aggiungere il
    /// riempimento dove crede — con il risultato che due campi finirebbero letti dal posto
    /// sbagliato, senza un errore e senza un avviso.
    var reserved0: Float
    var reserved1: Float

    var clipRowX: SIMD4<Float>
    var clipRowY: SIMD4<Float>
    var clipRowZ: SIMD4<Float>
}

