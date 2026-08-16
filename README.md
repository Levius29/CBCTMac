# CBCTMac

Visore e pianificatore per CBCT dentali, nativo macOS.

Tre viste ortogonali, ricostruzione panoramica, rendering 3D a resa dei tessuti variabile,
misurazioni, annotazioni e pianificazione implantare.

> ### ⚠️ Uso non diagnostico
>
> Software **non certificato come dispositivo medico**. Destinato a uso personale, di studio e
> di ricerca. Non va usato per formulare diagnosi né per pianificare interventi su pazienti.

---

## Stato

In sviluppo iniziale. Fase 1 — il visore — in corso.

| Fase | Contenuto | Stato |
|---|---|---|
| 1 | Import DICOM, MPR ortogonale, misure e annotazioni | in corso |
| 2 | Panorex e sezioni trasversali d'arcata | da fare |
| 3 | Tracciamento nervo alveolare, pianificazione implantare, allarmi di prossimità | da fare |
| 4 | Import scansione intraorale e fusione con il volume | da fare |
| 5 | Dime chirurgiche ed endodontiche per stampa 3D | da fare |
| 6 | Segmentazione AI on-device (Core ML) | da fare |

## Requisiti

- macOS 14 o successivo
- Xcode 16 o successivo (Swift 6)
- Mac Apple Silicon consigliato — il rendering sfrutta la memoria unificata

## Struttura

```
Sources/
  DICOMCore/    parsing DICOM, geometria del volume, decoding pixel, fantoccio sintetico
  MeasureKit/   annotazioni, misure, statistiche ROI, documento .cbctplan
  VolumeKit/    Metal: MPR, slab, transfer function (raycasting in arrivo)
  CBCTMacApp/   applicazione SwiftUI
Tools/          generatore e verificatore di fantocci, in Python senza dipendenze
docs/           architettura, specifica grafica, mockup, brief per Codex
```

`DICOMCore` e `MeasureKit` sono Swift puro senza dipendenze di piattaforma: niente `simd`,
niente Metal. Compilano e si testano anche su Linux, quindi `swift test` gira senza Xcode.

## Compilazione ed esecuzione

```sh
swift build
swift run CBCTMacApp
swift test
```

All'avvio l'applicazione genera un **fantoccio sintetico** — un cubo da 20,00 mm con sfere di
densità note — perché il parser DICOM non c'è ancora. Serve ad avere subito qualcosa di reale
da disegnare, e a verificare le misure contro valori esatti senza toccare dati di pazienti.

> **Nota.** Il codice non è ancora mai stato compilato: è stato scritto in un ambiente Linux
> privo di toolchain Swift. Al primo `swift build` sono da attendersi errori da sistemare.

L'eseguibile SPM va bene per lo sviluppo. Per la distribuzione servirà un vero target app in
Xcode, con bundle e `Info.plist`.

### Verificare le misure

```sh
python3 Tools/PhantomGenerator/make_phantom.py --output /tmp/phantom
python3 Tools/PhantomGenerator/verify_phantom.py /tmp/phantom
```

I due script generano e rileggono una serie DICOM equivalente al fantoccio, con parser
indipendenti l'uno dall'altro. Stampano i valori attesi: spigolo del cubo 20,00 mm,
intercapedine fra lastrine 10,00 mm, densità 1200 GV nel cubo e 400 / 2800 / 60 GV nelle sfere.
Se l'applicazione mostra numeri diversi, l'errore è nella catena delle coordinate.

## Documentazione

- [`docs/architecture.md`](docs/architecture.md) — **normativo.** I quattro contratti che
  reggono il progetto: sistemi di coordinate, ordinamento delle slice, doppia rappresentazione
  del volume, terminologia dei valori di densità. Da leggere prima di scrivere qualunque codice.
- [`docs/ui-spec.md`](docs/ui-spec.md) — specifica grafica e prompt per generare anteprime.

## Una nota sui valori di densità

I valori delle CBCT **non sono unità Hounsfield**. La ricostruzione parte da dati di proiezione
incompleti, lo scattering è elevato e il valore dipende dall'apparecchio, dal FOV e dalla
posizione nell'immagine. Questo software li etichetta perciò come **GV** (valore grigio) e non
come HU, che sarebbe un numero apparentemente confrontabile con la letteratura e in realtà no.

## Licenza

MIT — vedi [LICENSE](LICENSE).
