#include <metal_stdlib>
using namespace metal;

// Campionamento di un piano arbitrario dentro il volume.
//
// Un solo kernel per tutte le viste 2D del programma. Assiale, coronale e sagittale non sono
// tre implementazioni: sono tre configurazioni degli stessi uniform. Lo stesso vale per le
// viste oblique del riorientamento, e in Fase 2 per il panorex e le sezioni trasversali
// d'arcata, che campionano piani ricavati dalla spline invece che dagli assi anatomici.
//
// Il kernel non sa nulla di anatomia né di DICOM: riceve un'origine e tre passi già espressi
// in coordinate di texture, e cammina. Tutta la trigonometria sta a monte, sulla CPU e in
// Double, come vuole il contratto di precisione.

// MARK: - Uniform

// I vettori sono float4 e non packed_float3 di proposito: float3 in Metal è allineato a 16
// byte, e far combaciare a mano un layout packed con quello che genera Swift e' una fonte di
// bug silenziosi che si manifestano come immagini storte. La componente w si ignora.
struct MPRUniforms {
    float4 texOrigin;      // angolo alto-sinistro del piano, in coordinate texture [0,1]
    float4 texRightStep;   // spostamento per un pixel verso destra
    float4 texDownStep;    // spostamento per un pixel verso il basso
    float4 texNormalStep;  // spostamento per un passo di slab lungo la normale

    int slabSampleCount;   // 1 = slice singola
    int projectionMode;    // 0 media, 1 massimo (MIP), 2 minimo (MinIP)
    float rawWindowMin;    // valore grezzo che si mappa a nero
    float rawWindowMax;    // valore grezzo che si mappa a bianco

    float rawScale;        // 65535: da unorm [0,1] a passo intero
    float rawOffset;       // -32768: riporta al dominio Int16 originale
    float invertGrayscale; // 0 o 1, per la resa in negativo
    float padding;

    // Riquadro di lettura, come nel raycaster: tre righe, dentro se tutte e tre stanno fra zero
    // e uno. Senza riquadro valgono "sempre dentro". Vedi `ClipBox`.
    float4 clipRowX;
    float4 clipRowY;
    float4 clipRowZ;
};

inline bool isInsideClip(float3 coord, constant MPRUniforms& u) {
    const float3 n = float3(
        dot(u.clipRowX.xyz, coord) + u.clipRowX.w,
        dot(u.clipRowY.xyz, coord) + u.clipRowY.w,
        dot(u.clipRowZ.xyz, coord) + u.clipRowZ.w);
    return all(n >= 0.0f) && all(n <= 1.0f);
}

constant int kProjectionAverage = 0;
constant int kProjectionMaximum = 1;
constant int kProjectionMinimum = 2;

// MARK: - Campionatore

// clamp_to_edge evita l'avvolgimento ai bordi, ma da solo produrrebbe uno strascico: i voxel
// di bordo verrebbero ripetuti all'infinito fuori dal volume, e su una vista panoramica o
// obliqua si vedrebbero strisce di tessuto che non esistono. Per questo, oltre al clamp, il
// kernel verifica esplicitamente di stare dentro [0,1] e altrimenti scarta il campione.
constant sampler volumeSampler(
    coord::normalized,
    filter::linear,
    mip_filter::none,
    address::clamp_to_edge);

inline bool isInsideVolume(float3 c) {
    return all(c >= 0.0f) && all(c <= 1.0f);
}

// MARK: - Kernel principale

kernel void mprSample(
    texture3d<float, access::sample> volume  [[texture(0)]],
    texture2d<float, access::write>  output  [[texture(1)]],
    constant MPRUniforms&            u       [[buffer(0)]],
    uint2                            gid     [[thread_position_in_grid]])
{
    const uint width  = output.get_width();
    const uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    const float3 origin     = u.texOrigin.xyz;
    const float3 rightStep  = u.texRightStep.xyz;
    const float3 downStep   = u.texDownStep.xyz;
    const float3 normalStep = u.texNormalStep.xyz;

    // Posizione del pixel sul piano, prima di entrare nello slab.
    const float3 base = origin
                      + rightStep * float(gid.x)
                      + downStep  * float(gid.y);

    const int steps = max(u.slabSampleCount, 1);

    float accumulator = 0.0f;
    float extreme     = 0.0f;
    int   validCount  = 0;

    for (int s = 0; s < steps; ++s) {
        // Lo slab e' centrato sul piano: con `steps` campioni si va da -(steps-1)/2 a
        // +(steps-1)/2. Centrarlo conta, perche' altrimenti aumentare lo spessore
        // sposterebbe anche la posizione della fetta, e l'utente vedrebbe l'immagine
        // scivolare mentre regola un cursore che dovrebbe solo ispessirla.
        const float offset = float(s) - float(steps - 1) * 0.5f;
        const float3 coord = base + normalStep * offset;

        if (!isInsideVolume(coord) || !isInsideClip(coord, u)) {
            continue;
        }

        const float sampled = volume.sample(volumeSampler, coord).r;
        const float raw     = sampled * u.rawScale + u.rawOffset;

        if (validCount == 0) {
            extreme = raw;
        } else if (u.projectionMode == kProjectionMaximum) {
            extreme = max(extreme, raw);
        } else if (u.projectionMode == kProjectionMinimum) {
            extreme = min(extreme, raw);
        }

        accumulator += raw;
        validCount  += 1;
    }

    // Fuori dal volume si scrive nero pieno, non l'ultimo valore utile.
    if (validCount == 0) {
        output.write(float4(0.0f, 0.0f, 0.0f, 1.0f), gid);
        return;
    }

    float value;
    if (u.projectionMode == kProjectionMaximum || u.projectionMode == kProjectionMinimum) {
        value = extreme;
    } else {
        value = accumulator / float(validCount);
    }

    // Finestra/livello: rampa lineare fra i due estremi, come nella pratica radiologica.
    const float span = max(u.rawWindowMax - u.rawWindowMin, 1e-5f);
    float intensity = clamp((value - u.rawWindowMin) / span, 0.0f, 1.0f);

    if (u.invertGrayscale > 0.5f) {
        intensity = 1.0f - intensity;
    }

    output.write(float4(intensity, intensity, intensity, 1.0f), gid);
}

// MARK: - Lettura puntuale

// Restituisce il valore grezzo sotto il cursore senza rileggere la texture da CPU.
// Serve alla barra di stato, che mostra il valore del voxel puntato in tempo reale.
//
// Attenzione: questo campiona la texture *filtrata*. Va bene per una lettura al volo, ma
// il Contratto 3 vieta di ricavarne statistiche: quelle si calcolano sugli Int16 di CPU.
kernel void mprProbe(
    texture3d<float, access::sample> volume  [[texture(0)]],
    constant MPRUniforms&            u       [[buffer(0)]],
    constant float2&                 pixel   [[buffer(1)]],
    device float&                    result  [[buffer(2)]],
    uint                             tid     [[thread_position_in_grid]])
{
    if (tid != 0) {
        return;
    }

    const float3 coord = u.texOrigin.xyz
                       + u.texRightStep.xyz * pixel.x
                       + u.texDownStep.xyz  * pixel.y;

    // # Il riquadro di lettura **non** si applica qui, ed e' deliberato
    //
    // Questo kernel non disegna: legge i valori su cui si misura. Il riquadro e' un modo di
    // guardare, e un modo di guardare non deve poter cambiare un numero — una ROI a cavallo del
    // bordo perderebbe in silenzio i campioni dalla parte tagliata, e la media che ne esce
    // sarebbe sbagliata senza che niente lo dica. Chi ritaglia per vedere meglio non si aspetta
    // che la densita' cambi.
    if (!isInsideVolume(coord)) {
        result = NAN;
        return;
    }

    const float sampled = volume.sample(volumeSampler, coord).r;
    result = sampled * u.rawScale + u.rawOffset;
}
