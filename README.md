# OpenMRI Dental

Visore per CBCT dentali che gira nel browser, in locale. Nasce come fork di
[OpenMRI](https://github.com/lev1nson/OpenMRI) di Maksim Khuzin: rendering 3D, tre sezioni
legate fra loro, libreria dei pazienti, confronto fra date diverse. Nessuna immagine esce dal
computer.

> ### ⚠️ Uso non diagnostico
>
> Software **non certificato come dispositivo medico**. Destinato a uso personale, di studio e
> di ricerca. Non va usato per formulare diagnosi né per pianificare interventi su pazienti.

---

## Provarlo, stasera

Serve **macOS o Linux**, [Node.js](https://nodejs.org) 22.13 o successivo, **Python 3.12, 3.13 o
3.14** (`brew install python@3.12`) e un browser con WebGL 2.

```sh
git clone https://github.com/Levius29/CBCTMac.git
cd CBCTMac/web
npm ci             # dipendenze del programma
npm run setup      # ambiente Python: pydicom, nibabel, SimpleITK, dcm2niix — circa 1 GB
npm run build
npm run up         # avvia e apre il browser su 127.0.0.1:4173
```

`npm run down` lo ferma, `npm run status` dice se gira e dove scrive il registro. Il server
ascolta **solo su 127.0.0.1**: non ha login, quindi non va esposto in rete.

### Con le tue CBCT

**Prima di tutto, tre secondi per evitare un'importazione buttata.** L'importatore accetta solo
serie `MR` o `CT`, a un campione per pixel, e sotto un tetto di voxel; quando qualcosa non gli
va bene lo dice alla fine, con un messaggio che non spiega quale serie e perché. Questo lo dice
prima, e senza installare niente:

```sh
python3 Tools/inspect-dicom.py /percorso/della/cartella
python3 Tools/inspect-dicom.py esame.zip        # funziona anche direttamente sullo ZIP
```

Poi:

1. Comprimi la cartella dell'esame in uno **ZIP** — senza password, **un paziente per archivio**,
   fino a 2 GB. Vanno bene anche `.nii` / `.nii.gz`.
2. **Import MRI**, scegli lo ZIP, dai un nome al paziente, **Prepare the study**.
3. La conversione gira in un processo a parte: la finestra si può chiudere.

Se il controllo dice `RIFIUTATA: Modality «OT»` — capita su qualche apparecchio dentale che non
dichiara `CT` — l'esame è buono e l'importatore è severo: apri una segnalazione, si allarga
l'elenco in `web/scripts/import_mri.py` in una riga.

### Lo studio demo

Non è nel repository, perché pesa 46 MB e non cambia mai. Si scarica quando serve:

```sh
Tools/fetch-demo-study.sh
cd web && npm run demo
```

---

## Com'è fatto il repository

```
web/        Il programma. Copia intatta di OpenMRI più ciò che aggiungiamo noi.
Tools/      Utilità (controllo DICOM, scarico del demo) e i ventisei controlli della riserva.
Sources/    La riserva Swift: la matematica dentale, già provata, da portare nel web.
Tests/      Le sue prove.
docs/       Architettura, decisioni, piano di lavoro.
```

**`web/` si tocca il meno possibile.** Restiamo agganciati all'originale per poterne tirare le
correzioni e le funzioni nuove; ogni riga che cambiamo dentro i loro file è un conflitto che
torna al prossimo aggiornamento. Le aggiunte nostre vanno in file nostri. Le modifiche locali —
per ora **una** — sono elencate in [`docs/openmri-dental.md`](docs/openmri-dental.md).

### La riserva Swift

`Sources/` contiene quindici moduli e 1.046 prove: parser DICOM, MPR e raycasting Metal, panorex
e curva d'arcata, canale alveolare e impianti, dime chirurgiche, segmentazione dei denti,
cefalometria, e da oggi la registrazione fra due esami di date diverse. **Non è il programma**: è
il magazzino da cui si porta una funzione per volta, leggendo codice già provato invece di
ripensarlo. Si compila e si verifica come prima —
vedi [`docs/swift-reserve.md`](docs/swift-reserve.md):

```sh
swift test
for controllo in Tools/check-*.py; do python3 "$controllo" || break; done
```

### Che cosa manca, e in che ordine

Il programma web oggi guarda: non misura, non segmenta, non sa niente di denti. La prima cosa che
ci portiamo dalla riserva è **la panoramica e la curva d'arcata**, che è ciò che distingue un
visore CBCT da un visore qualunque. Il calcolo pesante andrà nell'ambiente Python che OpenMRI ha
già, accanto a import e registrazione.

---

## Da dove viene

`web/` è [lev1nson/OpenMRI](https://github.com/lev1nson/OpenMRI) al commit `a881ba7`, licenza
MIT, © 2026 Maksim Khuzin: la sua licenza è conservata in `web/LICENSE` e vale per quel codice.
Il resto del repository è MIT, © 2026 Levius29 — vedi [`LICENSE`](LICENSE).

Grazie a chi ha scritto OpenMRI: la parte difficile — un visore locale che si installa con un
comando e funziona — era già fatta.
