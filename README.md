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

I moduli condivisi compilano e sono verificati da 181 test. L'applicazione SwiftUI compila su
macOS; l'interfaccia non è ancora stata percorsa a mano.

| Fase | Contenuto | Stato |
|---|---|---|
| 1 | MPR ortogonale, misure, annotazioni, rendering 3D | compila, da provare a mano |
| 1b | Parser DICOM, decoder RLE e JPEG Lossless | **compilata e verificata** |
| 2 | Panorex e sezioni trasversali d'arcata | compila, da provare a mano |
| 3 | Nervo alveolare, pianificazione implantare, allarmi di prossimità | compila, da provare a mano |
| 4 | Import mesh STL/PLY/OBJ e registrazione rigida | **compilata e verificata** |
| 5 | Dime chirurgiche ed endodontiche per stampa 3D | **modulo verificato**, manca la UI |
| 6 | Segmentazione AI on-device (Core ML) | da fare |

## Requisiti

- macOS 14 o successivo
- Xcode 16 o successivo (Swift 6)
- Mac Apple Silicon consigliato — il rendering sfrutta la memoria unificata

## Struttura

```
Sources/
  DICOMCore/    parsing DICOM, geometria, decoder pixel (nativi, RLE, JPEG Lossless)
  MeasureKit/   annotazioni, misure, statistiche ROI, documento .cbctplan
  VolumeKit/    Metal: MPR, slab, raycasting 3D, transfer function
  DentalKit/    curva d'arcata, panorex, sezioni trasversali
  ImplantKit/   canale alveolare, impianti, allarmi di prossimità, densità ossea
  MeshKit/      import STL/PLY/OBJ, registrazione con Horn, affinamento ICP
  GuideKit/     campi scalari, marching cubes, dime chirurgiche ed endodontiche
  CBCTMacApp/   applicazione SwiftUI
Tools/          generatore e verificatore di fantocci, in Python senza dipendenze
docs/           architettura, specifica grafica, mockup, brief per Codex
```

`DICOMCore`, `MeasureKit` e `ImplantKit` sono Swift puro senza dipendenze di piattaforma:
niente `simd`, niente Metal. In `DentalKit` e `VolumeKit` solo i file dei renderer sono
protetti da una guardia Metal, mentre la geometria resta portabile. Il risultato è che
`swift test` gira ovunque, anche su Linux, e copre tutta la matematica che conta.

## Compilazione ed esecuzione

```sh
swift build
swift run CBCTMacApp
swift test
```

All'avvio l'applicazione genera un **fantoccio sintetico**: un cubo da 20,00 mm con sfere di
densità note. Serve a verificare le misure contro valori esatti senza toccare dati di pazienti,
e resta utile anche ora che si aprono studi veri.

> **Stato della verifica.** `swift test` copre i moduli condivisi: 181 test in 27 suite, tutti
> verdi su Swift 6.2. Il target dell'applicazione è condizionale a macOS e non entra in quella
> suite, perché importa SwiftUI, AppKit e Metal; le sue chiamate verso i moduli sono però
> verificate da `AppContractTests`.
>
> **Su macOS `swift test` richiede Xcode**, non bastano i Command Line Tools: sette file di test
> importano `XCTest`, che su macOS vive dentro Xcode e non nella toolchain da riga di comando.
> `swift build` e `swift run CBCTMacApp` invece non compilano i test e funzionano anche con i soli
> Command Line Tools.

### Costruire `CBCTMac.app`

`swift run` avvia un eseguibile nudo: senza identità di bundle le finestre di dialogo dei file si
comportano in modo irregolare, l'applicazione non compare fra le applicazioni e non può dichiarare
i tipi di documento che sa aprire. Per un `.app` vero, **senza bisogno di Xcode**:

```sh
./Tools/make-app-bundle.sh
open CBCTMac.app
```

Lo script compila in release, assembla `Contents/`, scrive l'`Info.plist` e firma ad-hoc — su
Apple Silicon un binario non firmato viene terminato all'avvio. Copia anche i bundle di risorse di
SwiftPM, che contengono gli shader Metal: senza quelli nessun renderer riesce a nascere.

Per distribuire l'app ad altri servono un Developer ID e la notarizzazione, e per una vera
distribuzione conviene comunque un target app in Xcode.

> **Nota sugli shader.** SwiftPM **copia** i file `.metal` senza compilarli, quindi il
> `default.metallib` che `makeDefaultLibrary(bundle:)` pretende non esiste. `MetalShaderLibrary`
> prova prima la libreria precompilata e, non trovandola, compila il sorgente all'avvio. Costa
> qualche centinaio di millisecondi una volta sola e rende il pacchetto eseguibile senza la
> toolchain Metal di Xcode.

### Aprire uno studio DICOM

Il pulsante **Apri** chiede una **cartella**, non un file: una serie CBCT è un insieme di file, e
lo scanner li ordina proiettandone la posizione sulla normale del piano — mai per
`InstanceNumber`, che su alcuni apparecchi è semplicemente sbagliato. Sono supportate le sintassi
native (Explicit e Implicit VR, Little e Big Endian), RLE Lossless e JPEG Lossless.

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
