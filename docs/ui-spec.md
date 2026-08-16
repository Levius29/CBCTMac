# CBCTMac — Specifica grafica e prompt per generazione anteprime

Questo file ha due usi:

1. **Per lo sviluppo** — è la specifica di design che guida l'implementazione SwiftUI:
   token di colore, misure, gerarchia, comportamento dei componenti.
2. **Per la generazione di anteprime** — il capitolo 6 contiene prompt pronti da incollare in
   GPT Image 2 (o altro modello immagine) per ottenere mockup visivi da commentare insieme.

> **Nota onesta sui mockup generati.** Un modello immagine produce un'illustrazione
> *suggestiva*, non un rendering fedele: sbaglierà quasi certamente parte del testo delle
> etichette, e le «radiografie» che disegna sono anatomia inventata, non ricostruzioni reali.
> Servono a decidere disposizione, densità visiva e tono — non a validare dettagli.
> Le proporzioni del capitolo 3 restano la fonte di verità.

---

## 1. Principi

**Scura, sempre.** La radiologia si legge su fondo nero: l'occhio distingue più livelli di
grigio e non viene abbagliato. Nessun tema chiaro per i viewport. La cornice dell'app segue
l'aspetto scuro di macOS.

**L'immagine domina.** L'anatomia occupa più dell'80% dei pixel. Ogni elemento di interfaccia
che non serve in quel momento sparisce. Le barre laterali si comprimono.

**Nativa, non «app medicale generica».** Toolbar unificata macOS, `SF Symbols`, `SF Pro`,
materiali traslucidi nelle barre, angoli e spaziature di sistema. Deve sembrare Anteprima o
Xcode, non un software Windows del 2009 portato a forza.

**Il numero è sacro.** Misure e valori di densità si leggono in tabellare monospaziata, con
unità sempre esplicita e mai troncata.

---

## 2. Token di design

### Colori

| Token | Valore | Uso |
|---|---|---|
| `viewport.bg` | `#000000` | Fondo dei riquadri immagine |
| `chrome.bg` | `#1C1C1E` | Barre, sidebar, ispettore |
| `chrome.elevated` | `#2C2C2E` | Campi, celle selezionabili |
| `separator` | `#38383A` | Linee di divisione, bordi riquadri |
| `text.primary` | `#F2F2F7` | Testo principale |
| `text.secondary` | `#8E8E93` | Etichette, unità, valori inattivi |
| `accent` | `#32B8C6` | Selezione, controlli attivi (ciano medicale) |
| `warning` | `#FF9F0A` | Banner uso non diagnostico, spacing irregolare |
| `danger` | `#FF453A` | Allarme prossimità critico (<1 mm) |
| `caution` | `#FFD60A` | Allarme prossimità (1–2 mm) |
| `safe` | `#30D158` | Distanza sicura (>2 mm) |

### Colori dei piani

Convenzione 3D Slicer, la più riconoscibile a colpo d'occhio:

| Piano | Colore | Hex |
|---|---|---|
| Assiale | rosso | `#F1554C` |
| Coronale | verde | `#4FCB6B` |
| Sagittale | giallo | `#FFD426` |
| 3D | ciano | `#32B8C6` |

Il bordo superiore di ogni riquadro porta il colore del suo piano, spesso 2 pt. Le linee del
mirino disegnate dentro un riquadro assumono il colore *del piano che rappresentano*: nella
vista assiale si vedono una linea verde (coronale) e una gialla (sagittale).

### Misure e tipografia

- Testo UI: `SF Pro Text` 13 pt · etichette 11 pt · sovraimpressioni nei viewport 11 pt
- Numeri: `SF Mono` 12 pt, cifre tabellari
- Sidebar sinistra 260 pt (comprimibile) · ispettore destro 300 pt (comprimibile)
- Toolbar 52 pt · barra di stato 28 pt · banner 24 pt
- Spaziatura fra riquadri 2 pt · raggio angoli 6 pt · griglia interna a multipli di 8 pt

---

## 3. Struttura della finestra principale

```
┌──────────────────────────────────────────────────────────────────────────────────────┐
│ ● ● ●   CBCTMac — Paziente ANONIMO_0142                                              │  barra titolo
├──────────────────────────────────────────────────────────────────────────────────────┤
│ ⌸ Apri   ⊞ Layout │ ↖ ▭ ∠ ○ ✎  │ ◐ Osso ▾  ▤ Slab 1.0mm ▾ │ ⟲ Riorienta │ ⤓ Esporta  │  toolbar
├──────────────────────────────────────────────────────────────────────────────────────┤
│ ⚠  USO NON DIAGNOSTICO — software non certificato come dispositivo medico            │  banner ambra
├──────────────┬───────────────────────────────────────────────────┬───────────────────┤
│ STUDI        │ ┌───────────────────────┬───────────────────────┐ │ VISUALIZZAZIONE   │
│              │ │▔▔▔▔▔▔ rosso ▔▔▔▔▔▔▔▔▔ │▔▔▔▔▔▔ verde ▔▔▔▔▔▔▔▔▔ │ │  Finestra   2400  │
│ ▾ ANON_0142  │ │ ASSIALE               │ CORONALE              │ │  Livello     600  │
│   2026-03-14 │ │                       │                       │ │  ▬▬▬▬●▬▬▬▬▬▬▬▬▬▬  │
│   ▸ CBCT     │ │      ·····╬·····      │       ····╬····       │ │                   │
│     512 img  │ │      (anatomia)       │      (anatomia)       │ │  Preset  Osso  ▾  │
│     0.20 mm  │ │                       │                       │ │  Spessore 1.0mm   │
│              │ │ 142/512   ├──10mm──┤  │ 268/512  ├──10mm──┤   │ │  Proiez.  MIP  ▾  │
│ ▾ SERIE      │ ├───────────────────────┼───────────────────────┤ │                   │
│   ▪ CBCT 3D  │ │▔▔▔▔▔▔ giallo ▔▔▔▔▔▔▔▔ │▔▔▔▔▔▔ ciano ▔▔▔▔▔▔▔▔▔ │ ├───────────────────┤
│   ▪ Scout    │ │ SAGITTALE             │ 3D                    │ │ MISURE            │
│              │ │                       │                       │ │                   │
│              │ │      ····╬····        │     ⬤ (cranio 3D)     │ │ ▭ 11,42 mm        │
│              │ │      (anatomia)       │                       │ │ ∠ 87,3°           │
│              │ │                       │  Osso ▾  ▨▨▨▨▨ TF     │ │ ○ 412 GV ±88      │
│              │ │ 301/512  ├──10mm──┤   │                       │ │                   │
│              │ └───────────────────────┴───────────────────────┘ │ ⤓ Esporta CSV     │
├──────────────┴───────────────────────────────────────────────────┴───────────────────┤
│ L 12,4  P −38,1  S 64,7 mm     ·     712 GV     ·     0,20 mm iso     ·     Zoom 180% │  stato
└──────────────────────────────────────────────────────────────────────────────────────┘
```

### Comportamento dei riquadri

Ogni riquadro mostra, in sovraimpressione sull'immagine e senza sfondi opachi:
- **in alto a sinistra** il nome del piano, in maiuscoletto spaziato, colore del piano;
- **in alto a destra** finestra/livello correnti;
- **in basso a sinistra** indice slice e posizione in mm;
- **in basso a destra** barra di scala metrica — sempre presente, è ciò che rende leggibile
  uno screenshot fuori dall'app;
- **al centro** il mirino, con un piccolo spazio vuoto all'incrocio per non nascondere il voxel
  puntato.

Doppio clic su un riquadro lo porta a piena finestra; di nuovo per tornare.

### Layout alternativi

`1×1` · `2×2` (predefinito) · `1+3` (uno grande e tre piccoli in colonna) ·
`3×2 sezioni trasversali` (Fase 2) · `panorex + sezioni` (Fase 2).

---

## 4. Componenti caratterizzanti

**Editor di transfer function (riquadro 3D).** Una striscia alta 64 pt sotto il rendering:
istogramma dei valori in grigio sullo sfondo, curva di opacità sopra con punti di controllo
trascinabili, gradiente del colore risultante in una fascia bassa. Preset a pillole sopra la
striscia: `Osso` `Denti` `Tessuti molli` `Pelle` `Vie aeree`. È il controllo che realizza il
«rendering dei tessuti variabile»: deve stare in vista, non in una finestra separata.

**Banner di uso non diagnostico.** Striscia ambra, altezza 24 pt, non comprimibile e non
chiudibile, testo a sinistra con icona triangolare. Presente anche negli screenshot esportati.

**Lettura di densità.** Nella barra di stato e nelle ROI l'unità è sempre **GV**, con tooltip:
«Valore grigio CBCT — non equivalente alle unità Hounsfield della TC». Mai la sigla HU.

**Elenco misure.** Righe con icona del tipo, valore in monospaziata, piano di appartenenza a
pallino colorato. Selezionando una riga la vista salta al piano corrispondente.

---

## 5. Schermate future da prevedere

- **Panorex + sezioni trasversali** (Fase 2): fascia panoramica larga in alto, griglia di
  sezioni numerate sotto, spline dell'arcata modificabile sull'assiale.
- **Pianificazione implantare** (Fase 3): impianto in sovraimpressione nei quattro riquadri,
  pannello con diametro/lunghezza/angolazione, e **semaforo di prossimità** a nervo, seno e
  radici adiacenti nei colori `safe`/`caution`/`danger`.
- **Fusione scansione intraorale** (Fase 4): mesh in ciano semitrasparente sul volume, con
  l'errore residuo RMS di registrazione mostrato in modo prominente.

---

## 6. Prompt pronti per GPT Image 2

Da incollare così come sono. In inglese perché i modelli immagine rendono meglio;
le etichette dell'interfaccia restano in italiano. Formato consigliato **16:9, 2560×1440**.

### Prompt A — Schermata principale (la più importante)

```
A photorealistic UI mockup screenshot of a professional macOS dental CBCT imaging
application in dark mode, displayed on a Retina display, 16:9.

Window chrome: native macOS dark window with traffic-light buttons top-left, unified
toolbar with SF Symbols style monochrome icons and small Italian labels
("Apri", "Layout", "Riorienta", "Esporta"). Toolbar background #1C1C1E.

Directly under the toolbar: a thin amber warning strip (#FF9F0A background, dark text,
24px tall) with a triangle warning icon reading
"USO NON DIAGNOSTICO — software non certificato come dispositivo medico".

Left sidebar (260px, #1C1C1E): a study browser tree with a patient row "ANON_0142",
a date "2026-03-14", and series entries "CBCT 3D — 512 img — 0.20 mm".

Center: a 2x2 grid of four pure black medical image viewports separated by 2px gaps.
Each viewport has a 2px colored top border and a small uppercase label in its corner:
top-left RED border labeled "ASSIALE" showing a grayscale axial cross-section of a human
jaw with the dental arch and teeth visible as bright white roots in darker bone;
top-right GREEN border labeled "CORONALE" showing a grayscale coronal slice of the
skull with maxillary sinuses and tooth roots;
bottom-left YELLOW border labeled "SAGITTALE" showing a grayscale sagittal slice with
mandible profile and cervical spine;
bottom-right CYAN border labeled "3D" showing a realistic 3D volume-rendered skull and
mandible in warm bone-white tones on black, with visible teeth, lit from upper left.

Thin crosshair lines cross each 2D viewport in the colors of the other planes, with a
small gap at the intersection. Each viewport has small overlay text in the corners:
slice counter like "142 / 512", window/level values, and a small white metric scale bar
labeled "10 mm".

Under the 3D viewport: a horizontal transfer-function editor strip showing a gray
histogram, an opacity curve with round draggable control points, a colored gradient bar,
and small pill-shaped preset buttons labeled "Osso", "Denti", "Tessuti molli".

Right inspector panel (300px): section "VISUALIZZAZIONE" with sliders for
"Finestra 2400" and "Livello 600", dropdowns "Preset: Osso" and "Proiezione: MIP";
below, a section "MISURE" listing measurement rows in monospaced type:
"11,42 mm", "87,3°", "412 GV ±88".

Bottom status bar (28px): monospaced readout
"L 12,4   P −38,1   S 64,7 mm     712 GV     0,20 mm iso     Zoom 180%".

Style: crisp, high fidelity, accurate Apple Human Interface Guidelines dark aesthetic,
teal accent color #32B8C6, no glow effects, no fictional branding, no stock-photo people.
```

### Prompt B — Panorex e sezioni trasversali (Fase 2)

```
Same macOS dark dental CBCT application as before, but the central area now shows a
panoramic dental reconstruction workspace:

Top half: one wide horizontal grayscale panoramic radiograph (panorex) of a full dental
arch, both jaws, all teeth visible, reconstructed from CBCT — slightly softer and
grainier than a real panoramic X-ray.

Bottom half: a grid of 8 narrow vertical grayscale cross-section slices in a row, each
showing a bucco-lingual section of the alveolar ridge with the mandibular canal visible
as a small dark circle, each labeled with a number and "1,0 mm".

Left of these, a small axial viewport with a bright cyan spline curve drawn along the
dental arch, with round draggable control points on it.

Same dark chrome, amber non-diagnostic banner, left study sidebar, right inspector with
"Curva arcata", "Spessore 1,0 mm", "Intervallo 1,0 mm". 16:9, photorealistic UI mockup.
```

### Prompt C — Pianificazione implantare (Fase 3)

```
Same macOS dark dental CBCT application. A 2x2 viewport grid where a virtual dental
implant is overlaid on the grayscale scans: a metallic gray threaded screw shape shown
in correct anatomical position in the bone in the cross-section and sagittal views, and
as a solid 3D metallic implant in the 3D bone-rendered viewport.

A bright red-orange tube runs through the mandible representing the traced inferior
alveolar nerve canal, clearly visible in the 3D view and as a colored circle in the
cross-sections.

Right inspector shows an implant panel: "Diametro 4,1 mm", "Lunghezza 10,0 mm",
"Angolazione 7,4°", and a prominent safety readout with colored status dots —
a green dot "Nervo 3,2 mm", a yellow dot "Seno 1,6 mm", a green dot "Radice 2,8 mm".

Same dark chrome, amber non-diagnostic banner, teal accent. 16:9, photorealistic UI mockup.
```

### Come usarli

Genera A per primo: è quello che fissa il linguaggio visivo. Se il risultato convince,
riusalo come immagine di riferimento per B e C così restano coerenti. Mandami le immagini e
adatto la specifica prima di scrivere le viste — è molto più rapido correggere un mockup che
rifare del SwiftUI.
