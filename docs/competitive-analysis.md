# Cosa fanno i software di riferimento, e cosa ne prendiamo

Analisi di SMOP (Swissmeda), DTX Studio (DEXIS / Nobel Biocare) e coDiagnostiX (Straumann),
verificata sulle fonti di agosto 2026 elencate in fondo. Serve a decidere l'ordine dei lavori, non
a fare un elenco di desideri: ogni riga dice chi ce l'ha, cosa abbiamo noi, e se vale la pena.

Una premessa che vale per tutto il documento. Questi tre sono dispositivi medici certificati, con
alle spalle team di decine di persone e anni di validazione clinica. Copiare le *funzioni* è
possibile e sensato; copiare la *fiducia* che deriva dalla certificazione non lo è. CBCTMac resta
uno strumento personale e di studio, e le funzioni che aggiungiamo non cambiano questo.

---

## 1. Confronto per funzione

Legenda dello stato: ✅ fatto · 🔶 parziale · ❌ mancante

| Funzione | Loro | Noi | Nota |
|---|---|---|---|
| MPR ortogonale, panorex, sezioni d'arcata | tutti | ✅ | |
| Rendering 3D con preset dei tessuti | tutti | ✅ | |
| Zoom/pan/rotazione fluidi | tutti | ✅ | rifatto in questo giro |
| Misure, annotazioni | tutti | ✅ | |
| Densitometria ossea | coDiagnostiX | ✅ | noi in terzi lungo l'impianto |
| Tracciamento **manuale** del canale mandibolare | tutti | ✅ | |
| Tracciamento **automatico** del canale (IA) | DTX (FDA-cleared) | ❌ | vedi § 3 |
| Curva panoramica automatica | DTX | 🔶 | noi solo programmatica, non disegnabile |
| Curva panoramica **disegnata a mano** | tutti | ❌ | **richiesta esplicita**, vedi § 2 |
| Curve separate per arcata superiore e inferiore | tutti | ❌ | conseguenza della precedente |
| Segmentazione dei denti (IA) | DTX | ❌ | vedi § 3 |
| Segmentazione / ritaglio del volume | coDiagnostiX, DTX | ❌ | **richiesta esplicita**, vedi § 2 |
| Fusione CBCT + scansione intraorale, manuale | tutti | ✅ | MeshKit, Horn + ICP |
| Fusione **automatica** | DTX | ❌ | ICP c'è, manca l'allineamento iniziale automatico |
| Libreria impianti dei produttori | tutti | 🔶 | noi catalogo generico: la geometria è IP loro |
| Libreria boccole e frese, incluse endodontiche | coDiagnostiX | 🔶 | parametriche, non da catalogo |
| Pianificazione guidata dalla protesi | coDiagnostiX | ❌ | vedi § 4 |
| Dime a supporto dentale / gengivale / osseo / a pin | coDiagnostiX | 🔶 | noi solo impronta dipinta |
| Dima aperta con finestre d'ispezione e irrigazione | SMOP (sistema «clamp») | ✅ | GuideKit ce l'ha già |
| Validazione della dima prima della stampa | — | ✅ | **nostro vantaggio**, vedi § 5 |
| Riduzione degli artefatti da metallo | tutti, con qualità diversa | ❌ | **richiesta esplicita**, vedi § 6 |
| Collaborazione in cloud, versionamento dei casi | SMOP | ❌ | fuori ambito per uno strumento personale |
| Misure verificate su fantoccio | — | ✅ | **nostro vantaggio**, vedi § 5 |

## 2. Le due richieste che colmano un divario reale

**Segmentazione del volume.** Serve a due cose diverse che conviene non confondere. La prima è
*guardare meno*: ritagliare a una regione d'interesse per non farsi disturbare dal resto, e
liberare memoria. La seconda è *isolare una struttura*: i denti, la mandibola, il metallo. La
seconda è il presupposto della riduzione degli artefatti, e questo fissa l'ordine dei lavori.

**Curva panoramica disegnata a mano, e diversa per arcata.** L'osservazione è corretta e nei
prodotti commerciali è data per scontata: la curva dell'arcata superiore non è quella
dell'inferiore, e una sola curva produce una panoramica giusta su un'arcata e sfocata sull'altra.
DTX Studio propone la curva automaticamente; la strada migliore è **proporla e lasciarla
modificare**, con due curve indipendenti e la possibilità di passare dall'una all'altra. Automatico
quando indovina, manuale quando serve.

## 3. Sull'intelligenza artificiale

DTX Studio traccia il canale mandibolare e segmenta i denti con modelli approvati FDA. È la loro
differenza più visibile, e nel nostro caso è anche la funzione con il rapporto valore/rischio
peggiore se fatta male: un canale tracciato automaticamente e sbagliato di due millimetri è
peggio di nessun tracciamento, perché sposta la fiducia nel posto sbagliato.

La posizione sensata per noi: modelli Core ML on-device, **sempre come proposta modificabile**, mai
come risultato definitivo, e con l'incertezza mostrata invece che nascosta. Resta la Fase 6 e viene
dopo la segmentazione, che è ciò che produce i dati di addestramento.

## 4. Pianificazione guidata dalla protesi

In coDiagnostiX si posiziona prima il dente protesico e poi l'impianto sotto di esso, non
viceversa. È l'ordine clinicamente corretto — l'impianto serve la protesi, non il contrario — e da
noi manca del tutto. Costa poco in termini di codice: una libreria di denti protesici parametrici e
un vincolo che leghi l'asse dell'impianto all'asse del dente, con l'angolo di divergenza mostrato.
Vale la pena e va messo in coda.

## 5. Dove siamo già meglio, e perché non è vanto

Due cose, entrambe conseguenze di scelte fatte all'inizio e non di bravura.

**Le misure sono verificate contro valori esatti.** `Tools/PhantomGenerator` genera una serie DICOM
con un cubo da 20,00 mm e sfere di densità note, e la rilegge con un parser indipendente. Nessuno
dei tre prodotti offre a chi lo usa un modo di verificare che le misure siano giuste: si fidano
della validazione del produttore, che è legittimo per un dispositivo certificato e non è la stessa
cosa. Qui la verifica è un comando.

**La dima si rifiuta di essere esportata se non passa la validazione.** `GuideExport` controlla
tenuta, orientamento e spessore minimo, e su un esito negativo non produce il file. È l'ultima
barriera prima della stampante, e vale più di qualunque funzione in più.

A queste due va aggiunta una terza, che diventerà importante appena tocchiamo gli artefatti: la
**provenienza del volume**. Un volume corretto non è più il dato acquisito, e ogni misura fatta
sopra deve dirlo. Vedi il paragrafo seguente.

## 6. Riduzione degli artefatti da metallo: cosa si può fare davvero

È la richiesta più importante e quella su cui bisogna essere precisi, perché la letteratura dice
una cosa scomoda.

**I metodi che funzionano meglio lavorano sulle proiezioni, non sul volume.** Lo schema di
riferimento è a doppio dominio: si segmenta il metallo sull'immagine ricostruita, si sostituisce la
traccia del metallo nel dominio delle **proiezioni** per interpolazione, si ricostruisce, e si
raffina con una rete convoluzionale fetta per fetta. Le proiezioni grezze noi non le abbiamo: dalla
CBCT esce un volume già ricostruito. Questo è un limite reale e non si aggira con l'ingegneria.

Cosa resta possibile, in ordine di rapporto fra risultato e costo:

**A. Soppressione delle strie in dominio polare.** Individuato il metallo, si trasforma ogni fetta
assiale in coordinate polari centrate sul metallo. Le strie, che in cartesiane sono raggi, in
polari diventano linee quasi orizzontali, e un filtraggio morfologico direzionale le rimuove
lasciando intatte le strutture che non hanno quella forma. È il componente «striking artifact
reduction» descritto in letteratura, costa poco e non richiede alcuna ricostruzione.

**B. Sinogramma virtuale con NMAR.** Si proietta in avanti la fetta per sintetizzare un sinogramma,
si sostituisce la traccia del metallo usando come riferimento un'immagine a priori classificata per
tessuto — aria, tessuto molle, osso — e si ricostruisce per retroproiezione filtrata. È
l'adattamento in dominio immagine del metodo di riferimento: più principiato di A, molto più
costoso, e con un rischio proprio, perché una ricostruzione approssimata introduce artefatti suoi.

**C. Reti neurali.** La letteratura recente usa modelli di diffusione latente e CycleGAN non
supervisionati, con risultati migliori di A e B. Richiedono dati di addestramento che non abbiamo e
producono immagini plausibili, che su un dato clinico è precisamente il pericolo: un'allucinazione
verosimile in una zona che si deve misurare. Non è una strada per noi, almeno non ora.

Si fa **A**, e si valuta **B** dopo averla vista all'opera. E vale in ogni caso una regola che
viene prima dell'algoritmo:

> Un volume corretto va marcato come corretto, la maschera del metallo va conservata, e ogni
> statistica ROI calcolata dentro o vicino alla regione corretta deve dirlo. La correzione cambia i
> valori di grigio: misurare una densità ossea su voxel interpolati e riportarla come un dato
> è il modo più diretto di trasformare un miglioramento in un danno.

---

## 7. Ordine dei lavori, con le dipendenze

```
1. Navigazione                    ✅ fatto in questo giro
2. SegmentKit                     ← sblocca 3, 5 e 6
   ritaglio VOI, soglie, crescita di regione, maschera su GPU
3. Metallo: maschera + soppressione strie in polare   ← dipende da 2
4. Curva d'arcata disegnabile, due arcate             indipendente
5. Dime: supporto dentale/gengivale/osseo/a pin       ← dipende da 2
6. Pianificazione guidata dalla protesi               indipendente
7. Fase 6: Core ML (canale, denti)                    ← dipende da 2
```

Il punto 2 è il collo di bottiglia di metà elenco: senza una maschera non si isola il metallo, non
si scelgono i supporti di una dima, e non c'è nulla con cui addestrare o valutare un modello. Va
prima.

---

## Fonti

- [SMOP — Swissmeda](https://www.mysmop.com/products) e [SMOP su Carestream Dental](https://www.carestreamdental.com/en-us/discover/clinical-software/swissmeda/smop/)
- [DTX Studio Clinic](https://www.dtxstudio.com/en-us/dtx-studio-clinic) e [DTX Studio Implant](https://www.dtxstudio.com/en-us/dtx-studio-implant)
- [DEXIS — ecosistema implantare con IA](https://dexis.com/en-us/news/dexis-drives-dental-imaging-innovation-with-introduction-of-ai-powered-implant-ecosystem)
- [coDiagnostiX](https://codiagnostix.com/) e [istruzioni d'uso, Straumann](https://www.straumann.com/content/dam/media-center/digital/en-us/documents/knowledge-center/codiagnostix/coDiagnostiX-10-IFU-EN-v14.4.pdf)
- [Metal artifact reduction con framework a doppio dominio, PMB 2023](https://ui.adsabs.harvard.edu/abs/2023PMB....68q5016T/abstract)
- [Soppressione degli artefatti da metallo con tecniche di elaborazione d'immagine](https://pmc.ncbi.nlm.nih.gov/articles/PMC5840892/)
- [MAR con modello di diffusione latente condizionale per CBCT dentale](https://pmc.ncbi.nlm.nih.gov/articles/PMC12551599/)
- [MAR non supervisionata con CycleGAN affinata](https://www.mdpi.com/2673-6470/6/2/31)
