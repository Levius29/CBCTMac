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
`CompetitiveGrowth`, `ImplantManipulation.projectedGrip` — tutti estratti da
dentro una vista dopo che un difetto ci si era nascosto.

**Secondo: controlli mirati su classi di difetto.** In `Tools/` ce ne sono
ventitré, ciascuno nato da un difetto vero e verificato rimettendolo al suo
posto. Non cercano «bug» in generale: ciascuno conosce una forma precisa.
`check-call-sites.py` confronta 3204 costruzioni contro le firme dichiarate;
`check-exhaustive-switches.py` elenca i casi da completare quando si aggiunge una
voce a un enum; `check-unreachable-members.py` trova le capacità scritte, provate
e mai collegate a un gesto — che in questo progetto è la classe più frequente.

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

- `swift test` — 890 prove sulle librerie, eseguibili ovunque.
- Le prove nascono con una **mutazione**: si reintroduce il difetto e si
  controlla che cadano. Una prova che non è mai caduta non ha dimostrato niente.
- Il fantoccio sintetico, con i suoi numeri noti — spigolo di 20,000 mm, densità
  esatte — e il suo gemello in Python, scritto in modo indipendente: se i due
  divergono, uno dei due sbaglia.
- E, per il bersaglio dell'applicazione, la compilazione sul Mac. Che resta
  l'ultima parola, e il motivo per cui tutto il resto esiste: farla fallire di
  rado.
