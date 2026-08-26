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

I moduli condivisi compilano e sono verificati da 921 test. L'applicazione SwiftUI compila su
macOS; l'interfaccia non è ancora stata percorsa a mano.

| Fase | Contenuto | Stato |
|---|---|---|
| 1 | MPR ortogonale, misure, annotazioni, rendering 3D | compila, da provare a mano |
| 1b | Parser DICOM, decoder RLE e JPEG Lossless | **compilata e verificata** |
| 2 | Panorex e sezioni trasversali d'arcata | compila, da provare a mano |
| 3 | Nervo alveolare, pianificazione implantare, allarmi di prossimità | compila, da provare a mano |
| 4 | Import mesh STL/PLY/OBJ e registrazione rigida | **compilata e verificata** |
| 5 | Dime chirurgiche ed endodontiche per stampa 3D | **modulo verificato**, manca la UI |
| 5b | Separazione di denti e arcate, uscita STL/OBJ stampabile | **moduli verificati**, UI collegata e da compilare sul Mac |
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
  MeshKit/      import ed export STL/PLY/OBJ, registrazione con Horn, affinamento ICP,
                referto d'integrità, lisciatura di Taubin, decimazione a quadriche
  SegmentKit/   ritaglio, soglie, crescita di regione e competitiva, morfologia, componenti
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
swift run 3DMED
swift test
```

All'avvio l'applicazione genera un **fantoccio sintetico**: un cubo da 20,00 mm con sfere di
densità note. Serve a verificare le misure contro valori esatti senza toccare dati di pazienti,
e resta utile anche ora che si aprono studi veri.

> **Stato della verifica.** `swift test` copre i moduli condivisi: 921 test in 111 suite,
> tutti verdi — l'ultima esecuzione su Swift 6.1.2 per Linux. Il target dell'applicazione è condizionale a macOS e non entra in quella
> suite, perché importa SwiftUI, AppKit e Metal; le sue chiamate verso i moduli sono però
> verificate da `AppContractTests` e da ventisei controlli statici in `Tools/`.
>
> **Su macOS `swift test` richiede Xcode**, non bastano i Command Line Tools: sette file di test
> importano `XCTest`, che su macOS vive dentro Xcode e non nella toolchain da riga di comando.
> `swift build` e `swift run 3DMED` invece non compilano i test e funzionano anche con i soli
> Command Line Tools.

Il target dell'applicazione non compila fuori da macOS, quindi un errore banale in quel codice si
scopre solo là. Un controllo copre la classe di errore più frequente:

```sh
python3 Tools/check-exhaustive-switches.py
```

Verifica che ogni `switch` sugli enum dell'app li copra per intero. Aggiungere un caso a `Tool` e
dimenticare uno degli `switch` che lo consumano è un errore che il compilatore Swift segnala
subito — dove c'è. Il controllo è sintattico e prudente: legge gli enum di tutti i moduli per non
scambiare un `AnatomicalPlane` per un `ViewportSlot` incompleto, e tace quando un enum è coperto
esattamente.

È uno di ventisei controlli in `Tools/`, tutti eseguibili senza Xcode e senza rete:

```sh
for controllo in Tools/check-*.py; do python3 "$controllo" || break; done
```

Tre riguardano i pannelli, e nascono da un difetto solo — «se apro una cosa, poi non posso più
aprirne altre»: `check-modal-routes.py` pretende che le finestre modali passino da una strada
sola, `check-panel-exits.py` che ogni stato acceso si possa spegnere, `check-inspector-routes.py`
che l'ispettore mostri elenchi invece di catene di `else`, dove il primo ramo vero copre gli
altri. Vedi le *Regole trasversali* in [`docs/architecture.md`](docs/architecture.md).

### Costruire `3DMED.app`

`swift run` avvia un eseguibile nudo: senza identità di bundle le finestre di dialogo dei file si
comportano in modo irregolare, l'applicazione non compare fra le applicazioni e non può dichiarare
i tipi di documento che sa aprire. Per un `.app` vero, **senza bisogno di Xcode**:

```sh
./Tools/make-app-bundle.sh
open 3DMED.app
```

Lo script compila in release, assembla `Contents/`, scrive l'`Info.plist`, genera l'icona e firma
ad-hoc — su Apple Silicon un binario non firmato viene terminato all'avvio. Copia anche i bundle
di risorse di SwiftPM, che contengono gli shader Metal: senza quelli nessun renderer riesce a
nascere.

> **Il nome.** L'applicazione si chiama **3DMED**; il pacchetto, i moduli e questo repository
> restano `CBCTMac`. Sono due nomi con due scopi: uno è ciò che si legge sullo schermo, l'altro è
> ciò che si scrive negli `import`, e tenerli distinti evita di toccare ogni file sorgente per
> cambiare un'etichetta.
>
> Il **prodotto** SwiftPM si chiama `3DMED`, il **target** `CBCTMacApp`: SwiftPM dà al binario il
> nome del prodotto e al modulo quello del target. Serve perché macOS, per un eseguibile senza
> bundle, prende il nome del menu dell'applicazione dal file eseguibile — e finché il prodotto si
> chiamava `CBCTMacApp` chi lanciava `swift run` leggeva «3DMED» sulla finestra e «CBCTMacApp»
> accanto alla mela.
>
> Se il nome che vedi non è 3DMED, stai eseguendo un binario compilato prima di questo
> cambiamento. La barra di stato dice sempre quale dei due modi è in esecuzione.

> **L'icona non è un file.** È disegnata in `Sources/CBCTMacApp/AppIcon.swift` in coordinate
> normalizzate, quindi esce nitida a ogni misura senza che il repository porti un solo PNG.
> L'eseguibile sa esportarsi l'iconset da solo — `3DMED --export-icon <cartella>` — e lo
> script di bundle lo usa per costruire l'`.icns`. La stessa sorgente serve anche il Dock a
> runtime, così l'icona è la stessa nei due posti per costruzione.

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

### Stampare un pezzo dell'esame

Due strade, e la differenza è quale delle due cose si vuole.

**Un dente solo** — pannello «Separa i tessuti», nella colonna di sinistra.

1. Accendi il **riquadro di lettura** e stringilo attorno al dente trascinandone i lati sulle
   viste. È il passo che conta di più: dove radice e osso si toccano alla stessa densità non
   c'è, nei voxel, nessun confine da trovare, e senza un limite esterno il dente si tira dietro
   la mandibola. Il riquadro è l'unico limite che valga per costruzione — ed è anche ciò che
   rende l'operazione immediata invece che lenta.
2. Prendi il marcatore e fai clic **dentro l'osso**, di fianco alla radice e dentro il riquadro.
   Marcalo pure in più punti: più punti tengono indietro il fronte del dente.
3. Cambia il marcatore in **Dente**, scegli il numero FDI e fai clic al centro della corona.
4. **Separa.** I contorni compaiono sulle viste, ciascuno col colore del suo marcatore: è lì che
   si giudica il risultato, prima di esportarlo.
5. Il pallino accanto al nome dice se il solido è **chiuso**. Poi l'icona di salvataggio, **STL**
   o **OBJ**.

**Un'arcata** — menu «Segmentazione per soglia».

1. Stringi il riquadro di lettura attorno alla mandibola o alla mascella. Senza, «tieni il pezzo
   più grande» restituisce mezzo cranio: una soglia da osso comprende colonna, mento e
   otturazioni.
2. Scegli il preset dell'osso e correggilo guardando l'istogramma di *questa* acquisizione — le
   soglie di letteratura sono in unità Hounsfield e su una CBCT non valgono.
3. **Segmenta**, poi **Esporta** in STL o OBJ.

In entrambi i casi la sezione **Finitura per la stampa** governa due cose: la *lisciatura*, che
toglie i gradini dei voxel senza assottigliare il modello, e il *tetto di triangoli*, da alzare
se lo slicer fatica ad aprire il file. Quel che si vede sulle viste è quel che esce nel file.

> Dove una corona metallica ha bruciato il dato, il modello resta incompleto: lì non c'è nulla da
> segmentare, e nessun algoritmo lo inventa.

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
