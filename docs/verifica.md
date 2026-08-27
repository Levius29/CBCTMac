# Come si verifica quello che non si può compilare

## Il vincolo

Le librerie del progetto — `DICOMCore`, `VolumeKit`, `MeasureKit`, `ImplantKit`,
`DentalKit`, `SegmentKit`, `MeshKit` e le altre — sono Swift puro e si compilano
e si provano ovunque, Linux compreso. Il bersaglio **`CBCTMacApp` no**: usa
SwiftUI, AppKit e Metal, e vuole l'SDK di macOS.

Da lì il collo di bottiglia del progetto. Sul codice dell'applicazione l'unico
strumento disponibile fuori da macOS è `swiftc -parse`, che verifica la
**grammatica** e nient'altro. Un nome di membro inesistente è grammatica
corretta. Un'etichetta di argomento sbagliata pure. Passano, e si scoprono
compilando sul Mac — un giro dopo, a carico di chi compila.

## Che cosa funziona

Due mosse, in ordine di resa.

**Primo: la logica non sta nelle viste.** Ogni volta che una formula ha una
risposta giusta e una sbagliata, va in una libreria, dove `swift test` la
raggiunge. Non è purezza architetturale: è l'unico modo di provarla. Ne sono
nati `PlaneProximity`, `RayCompositing`, `ClipBox`, `OrientationCubeGeometry`,
`CompetitiveGrowth`, `GrowthRestriction`, `ImplantManipulation.projectedGrip` —
tutti estratti da dentro una vista dopo che un difetto ci si era nascosto.

**Secondo: controlli mirati su classi di difetto.** In `Tools/` ce ne sono
**ventisei**, ciascuno nato da un difetto vero e verificato rimettendolo al suo
posto. Non cercano «bug» in generale: ciascuno conosce una forma precisa.
`check-call-sites.py` confronta le costruzioni dei 457 tipi del progetto contro
le firme dichiarate; `check-exhaustive-switches.py` elenca i casi da completare
quando si aggiunge una voce a un enum; `check-unreachable-members.py` trova le
capacità scritte, provate e mai collegate a un gesto — che in questo progetto è
la classe più frequente.

I sedici arrivati dopo i primi dieci hanno spostato il bersaglio: non più
soltanto errori che il compilatore del Mac troverebbe un giro dopo, ma difetti
che **compilano benissimo e restano invisibili**. `check-plan-snapshot.py`
sorveglia i quattro posti che devono restare d'accordo sull'istantanea del piano;
`check-project-document.py` trova i campi che il documento salva e non rilegge
mai; `check-undoable-plan.py` le modifiche che «annulla» non riporta indietro;
`check-uniform-layout.py` gli `struct` di uniform la cui sequenza di campi diverge
fra Swift e Metal — dove il disallineamento non dà errori, dà pixel sbagliati.
Nessuno di questi produce un messaggio del compilatore, su nessuna piattaforma.
L'elenco completo, con l'origine di ciascuno, sta in
[`work-plan.md`](work-plan.md#3-ter-i-ventisei-controlli-che-girano-prima-di-ogni-consegna).

Sono euristiche, e coprono per classi invece che per costruzione. In cambio si
scrivono in un'ora e restano leggibili.

## Che cosa non funziona: i moduli finti

L'idea ovvia è dichiarare finti `SwiftUI`, `AppKit` e `Metal` — solo le firme,
nessun corpo — e far girare `swiftc -typecheck` sul bersaglio vero. Sarebbe il
compilatore a controllare, non delle euristiche: copertura totale invece che per
classi.

**È stato provato e non regge.** Il tentativo ha coperto **un file su una
cinquantina**, e non per mancanza di tempo: per un motivo strutturale che vale la
pena scrivere, perché è controintuitivo.

Il codice dell'applicazione è quasi tutto viste SwiftUI, che poggiano su result
builder, property wrapper, `some View` e catene di modificatori generici.
Riprodurre quelle firme abbastanza da far passare il codice giusto è già molto
lavoro; il problema è l'altro lato. **Uno stub troppo permissivo non fallisce
soltanto a prendere gli errori: li silenzia.** Un modificatore dichiarato come
`func qualunque<T>(_: T...) -> Self` accetta qualsiasi cosa, quindi il typecheck
passa su codice sbagliato — e il controllo diventa un placebo che dà una luce
verde priva di significato.

E una luce verde priva di significato è peggio di nessun controllo: la si crede.

Quindi lo stub dev'essere **stretto** per servire a qualcosa, e stretto significa
riprodurre fedelmente una superficie enorme, che poi va mantenuta a ogni API
nuova che si usa. Il costo cresce più che linearmente con la copertura, e il
valore solo linearmente.

La conclusione, per chi ci ripensasse: non è una strada da riprendere a pezzi.
Diventerebbe percorribile solo con un SDK vero, cioè spostando la compilazione su
una macchina macOS — che è un cambiamento di ambiente, non di codice.

## Dove sta il resto della verifica

- `swift test` — 1045 prove sulle librerie: 962 in 118 gruppi con
  `swift-testing`, 83 con `XCTest` in dieci file. L'ultima corsa le ha viste
  tutte verdi in 66 secondi, su macOS con la toolchain di Xcode; quella
  registrata prima si fermava a 921, su Linux, ed era anteriore alle prove
  della crescita confinata, della mesh stampabile e del taglio minimo.
- Le prove nascono con una **mutazione**: si reintroduce il difetto e si
  controlla che cadano. Una prova che non è mai caduta non ha dimostrato niente.
- Il fantoccio sintetico, con i suoi numeri noti — spigolo di 20,000 mm, densità
  esatte — e il suo gemello in Python, scritto in modo indipendente: se i due
  divergono, uno dei due sbaglia.
- E, per il bersaglio dell'applicazione, la compilazione sul Mac. Che resta
  l'ultima parola, e il motivo per cui tutto il resto esiste: farla fallire di
  rado.
