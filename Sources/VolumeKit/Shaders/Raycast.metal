#include <metal_stdlib>
using namespace metal;

// Rendering volumetrico per raycasting.
//
// Proiezione **ortografica**, non prospettica. In ambito medico e' la scelta corretta: con la
// prospettiva due strutture di uguale dimensione appaiono diverse a seconda della distanza, e
// su un'immagine da cui si prendono misure e' un difetto. Ha anche un vantaggio pratico: la
// direzione del raggio e' la stessa per ogni pixel, quindi la si calcola una volta sulla CPU e
// il kernel non fa altro che sommare, esattamente come il kernel MPR.
//
// Composizione front-to-back con terminazione anticipata: appena l'opacita' accumulata satura,
// il raggio si ferma. Su un preset "osso", dove la superficie diventa opaca subito, questo
// taglia via la maggior parte dei campioni.

// MARK: - Uniform

// float4 e non packed_float3: in Metal float3 occupa comunque 16 byte, e far combaciare a mano
// un layout packed con quello generato da Swift produce disallineamenti silenziosi che si
// manifestano come immagini inclinate senza alcun errore. La componente w si ignora.
struct RaycastUniforms {
    float4 texOrigin;      // origine del raggio del pixel (0,0), in coordinate texture
    float4 texRightStep;   // spostamento per un pixel verso destra
    float4 texDownStep;    // spostamento per un pixel verso il basso
    float4 texRayStep;     // spostamento per un campione lungo il raggio

    float4 gradientScale;  // riporta il gradiente da spazio texture a spazio mondo
    float4 lightDirection; // direzione della luce in spazio mondo, gia' normalizzata

    int   sampleCount;
    float rawScale;        // 65535: da unorm al passo intero
    float rawOffset;       // -32768: riporta al dominio Int16
    float rescaleSlope;

    float rescaleIntercept;
    float densityMin;      // estremi su cui e' distribuita la tabella della transfer function
    float densityMax;
    float ambient;

    float diffuse;
    float specular;
    float shininess;
    float gradientStepTex; // passo per le differenze centrali, in unita' di texture
};

// MARK: - Campionatori

constant sampler volumeSampler(
    coord::normalized,
    filter::linear,
    mip_filter::none,
    address::clamp_to_edge);

constant sampler tableSampler(
    coord::normalized,
    filter::linear,
    address::clamp_to_edge);

// MARK: - Utilita'

inline bool isInsideVolume(float3 c) {
    return all(c >= 0.0f) && all(c <= 1.0f);
}

/// Valore grezzo -> densita' -> posizione normalizzata nella tabella.
inline float tableCoordinate(float sampled, constant RaycastUniforms& u) {
    const float raw = sampled * u.rawScale + u.rawOffset;
    const float density = raw * u.rescaleSlope + u.rescaleIntercept;
    const float span = max(u.densityMax - u.densityMin, 1e-5f);
    return clamp((density - u.densityMin) / span, 0.0f, 1.0f);
}

/// Gradiente per differenze centrali, riportato in spazio mondo.
///
/// Il gradiente in spazio texture e' distorto quando i voxel non sono isotropici: una stessa
/// differenza di valore su un passo di 0,2 mm e su uno di 0,4 mm non descrive la stessa
/// pendenza. `gradientScale` porta le tre componenti in millimetri, cosi' l'illuminazione
/// resta corretta anche su volumi anisotropici — dove altrimenti le superfici apparirebbero
/// inclinate in modo sistematico.
inline float3 volumeGradient(
    texture3d<float, access::sample> volume,
    float3 coord,
    constant RaycastUniforms& u)
{
    const float h = u.gradientStepTex;

    const float dx =
        volume.sample(volumeSampler, coord + float3(h, 0, 0)).r -
        volume.sample(volumeSampler, coord - float3(h, 0, 0)).r;
    const float dy =
        volume.sample(volumeSampler, coord + float3(0, h, 0)).r -
        volume.sample(volumeSampler, coord - float3(0, h, 0)).r;
    const float dz =
        volume.sample(volumeSampler, coord + float3(0, 0, h)).r -
        volume.sample(volumeSampler, coord - float3(0, 0, h)).r;

    return float3(dx, dy, dz) * u.gradientScale.xyz;
}

// MARK: - Kernel

kernel void volumeRaycast(
    texture3d<float, access::sample> volume        [[texture(0)]],
    texture2d<float, access::sample> transferTable [[texture(1)]],
    texture2d<float, access::write>  output        [[texture(2)]],
    constant RaycastUniforms&        u             [[buffer(0)]],
    uint2                            gid           [[thread_position_in_grid]])
{
    const uint width  = output.get_width();
    const uint height = output.get_height();
    if (gid.x >= width || gid.y >= height) {
        return;
    }

    float3 coord = u.texOrigin.xyz
                 + u.texRightStep.xyz * float(gid.x)
                 + u.texDownStep.xyz  * float(gid.y);

    const float3 step = u.texRayStep.xyz;
    const int    steps = max(u.sampleCount, 1);

    // Colore gia' premoltiplicato per l'opacita', come la tabella.
    float3 accumulatedColor = float3(0.0f);
    float  accumulatedAlpha = 0.0f;

    for (int s = 0; s < steps; ++s, coord += step) {

        if (!isInsideVolume(coord)) {
            // Non si interrompe: il raggio entra nel volume, lo attraversa e ne esce, e i
            // campioni fuori sono quelli prima dell'ingresso o dopo l'uscita. Fermarsi al
            // primo campione esterno taglierebbe via tutto quando la camera e' obliqua.
            continue;
        }

        const float sampled = volume.sample(volumeSampler, coord).r;
        const float lookup  = tableCoordinate(sampled, u);
        const float4 mapped = transferTable.sample(tableSampler, float2(lookup, 0.5f));

        const float alpha = mapped.a;
        if (alpha <= 0.001f) {
            // Campione trasparente: niente da comporre, e soprattutto niente gradiente da
            // calcolare. E' il risparmio piu' grosso del kernel, perche' su un preset "osso"
            // la maggior parte del volume e' aria.
            continue;
        }

        float3 color = mapped.rgb;

        // Illuminazione solo dove c'e' una superficie. Un gradiente quasi nullo significa
        // interno omogeneo: applicare Blinn-Phong li' produce chiazze dovute al rumore, non
        // rilievo.
        const float3 gradient = volumeGradient(volume, coord, u);
        const float gradientLength = length(gradient);

        if (gradientLength > 1e-5f) {
            const float3 normal = -gradient / gradientLength;
            const float3 lightDir = u.lightDirection.xyz;
            // Vista ortografica: la direzione di osservazione e' costante, quindi il
            // semivettore si calcola senza conoscere la posizione del pixel.
            const float3 viewDir = -normalize(step);
            const float3 halfway = normalize(lightDir + viewDir);

            const float lambert = max(dot(normal, lightDir), 0.0f);
            const float highlight = pow(max(dot(normal, halfway), 0.0f), u.shininess);

            color = color * (u.ambient + u.diffuse * lambert)
                  + float3(u.specular * highlight * alpha);
        } else {
            color = color * u.ambient;
        }

        // Composizione front-to-back con colori premoltiplicati.
        const float transmittance = 1.0f - accumulatedAlpha;
        accumulatedColor += color * transmittance;
        accumulatedAlpha += alpha * transmittance;

        // Terminazione anticipata: oltre questa soglia il contributo residuo non e' piu'
        // distinguibile, e proseguire costerebbe soltanto.
        if (accumulatedAlpha >= 0.995f) {
            break;
        }
    }

    // Composizione su fondo nero: il colore e' gia' premoltiplicato, quindi si scrive com'e'.
    output.write(float4(accumulatedColor, 1.0f), gid);
}
