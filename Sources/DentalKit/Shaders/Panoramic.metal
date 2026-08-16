#include <metal_stdlib>
using namespace metal;

// Ricostruzione panoramica.
//
// Un kernel dedicato serve per un motivo preciso: nell'MPR tutte le colonne dell'immagine
// giacciono sullo stesso piano, qui **ogni colonna ha il suo**. La colonna x campiona attorno
// al punto della curva a distanza d'arco x, con la propria normale vestibolo-linguale.
//
// La spline non compare in questo file. La CPU la ricampiona in esattamente una voce per
// colonna e passa il risultato in un buffer: lo shader indicizza e basta. Tutta la matematica
// resta in Double dove serve, e il kernel resta una somma.

// MARK: - Dati per colonna

struct PanoramicColumn {
    float4 texTop;        // centro del pixel (x, 0), in coordinate texture
    float4 texSlabStep;   // passo dello slab lungo la normale vestibolo-linguale
};

struct PanoramicUniforms {
    float4 texDownStep;   // passo per un pixel verso il basso, uguale per tutte le colonne

    int   slabSampleCount;
    int   projectionMode; // 0 media, 1 massimo (MIP), 2 minimo (MinIP)
    float rawWindowMin;
    float rawWindowMax;

    float rawScale;
    float rawOffset;
    float invertGrayscale;
    float padding;
};

constant int kProjectionAverage = 0;
constant int kProjectionMaximum = 1;
constant int kProjectionMinimum = 2;

constant sampler volumeSampler(
    coord::normalized,
    filter::linear,
    mip_filter::none,
    address::clamp_to_edge);

inline bool isInsideVolume(float3 c) {
    return all(c >= 0.0f) && all(c <= 1.0f);
}

// MARK: - Kernel

kernel void panoramicSample(
    texture3d<float, access::sample> volume  [[texture(0)]],
    texture2d<float, access::write>  output  [[texture(1)]],
    constant PanoramicUniforms&      u       [[buffer(0)]],
    constant PanoramicColumn*        columns [[buffer(1)]],
    uint2                            gid     [[thread_position_in_grid]])
{
    const uint width  = output.get_width();
    const uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    const PanoramicColumn column = columns[gid.x];

    // Posizione sulla colonna prima di entrare nello slab.
    const float3 base = column.texTop.xyz + u.texDownStep.xyz * float(gid.y);
    const float3 slabStep = column.texSlabStep.xyz;
    const int steps = max(u.slabSampleCount, 1);

    float accumulator = 0.0f;
    float extreme     = 0.0f;
    int   validCount  = 0;

    for (int s = 0; s < steps; ++s) {
        // Slab centrato sulla curva: da -(steps-1)/2 a +(steps-1)/2. Centrarlo conta, perche'
        // altrimenti aumentare lo spessore sposterebbe anche la fetta, e l'immagine
        // scivolerebbe mentre l'utente regola un cursore che dovrebbe solo ispessirla.
        const float offset = float(s) - float(steps - 1) * 0.5f;
        const float3 coord = base + slabStep * offset;

        if (!isInsideVolume(coord)) {
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

    const float span = max(u.rawWindowMax - u.rawWindowMin, 1e-5f);
    float intensity = clamp((value - u.rawWindowMin) / span, 0.0f, 1.0f);

    if (u.invertGrayscale > 0.5f) {
        intensity = 1.0f - intensity;
    }

    output.write(float4(intensity, intensity, intensity, 1.0f), gid);
}
