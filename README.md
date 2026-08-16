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
  DICOMCore/    parsing DICOM, geometria del volume, decoding pixel
  MeasureKit/   annotazioni, misure, statistiche ROI
  VolumeKit/    Metal: MPR, slab, raycasting, transfer function
  DCMTKBridge/  decoding delle sintassi compresse (rimandato, vedi il suo README)
App/            applicazione SwiftUI
Tools/          generatore di fantocci sintetici per la verifica
docs/           architettura, specifica grafica, requisiti, analisi dei rischi
```

`DICOMCore` e `MeasureKit` sono Swift puro senza dipendenze di piattaforma: compilano e si
testano anche su Linux, quindi `swift test` gira senza Xcode.

## Compilazione

```sh
swift build          # i moduli condivisi
swift test           # test di DICOMCore e MeasureKit
```

L'applicazione richiede Xcode, che apre il package come dipendenza locale.

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
