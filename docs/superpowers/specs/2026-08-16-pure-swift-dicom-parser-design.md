# Parser DICOM pure Swift — Design

**Data:** 16 agosto 2026  
**Stato:** approvato da Francesco  
**Branch di base:** `claude/mac-cbct-dental-app-n84glw`  
**Branch di lavoro:** `codex/pure-swift-dicom-parser`

## Fonti normative

Questo design applica senza riduzioni il brief fornito dall'utente e già conservato in
`docs/codex-brief-dicom-parser.md`. Restano inoltre normativi i contratti di
`docs/architecture.md`: geometria in `Double`, nessun ordinamento per `InstanceNumber`, valori
CBCT chiamati grey value e portabilità Linux del modulo `DICOMCore`.

In caso di contrasto, prevale la richiesta più restrittiva. Non si modificano UI, rendering,
volume building o altri componenti dell'applicazione.

## Ambito

Si aggiungono esclusivamente:

- `Sources/DICOMCore/DICOMTag.swift`
- `Sources/DICOMCore/DICOMDataset.swift`
- `Sources/DICOMCore/DICOMParser.swift`
- `Sources/DICOMCore/DICOMScanner.swift`
- test e helper sotto `Tests/DICOMCoreTests/`

Il codice usa solo Foundation, Swift 6 e strict concurrency. Ogni tipo pubblico è `Sendable`.
Non usa `simd`, Metal, AppKit, UIKit, macro, property wrapper, `try!`, `fatalError` o unwrap
forzati su dati letti dal file.

## Architettura

### Tag e VR

`DICOMTag` è un valore ordinabile per gruppo ed elemento e stampa sempre quattro cifre
esadecimali maiuscole. `VR` contiene tutti i VR indicati dal brief, con proprietà esplicite per
header lungo e valori testuali. `DICOMTags` espone tutte le costanti richieste e mantiene una
mappa interna tag→VR usata soltanto per dataset Implicit VR. Un tag sconosciuto in Implicit VR
riceve `.UN`; PixelData riceve sempre `.OW`.

### Dataset ed elementi

`DICOMDataset` conserva contemporaneamente l'array nell'ordine del file e un dizionario per il
lookup. Ogni `DICOMElement` conserva tag, VR e byte grezzi. Conserva inoltre internamente
l'ordine dei byte con cui è stato letto: è necessario perché il file meta è sempre little
endian anche quando il dataset principale è big endian.

Gli accessor testuali rimuovono soltanto NUL e spazi finali; le liste sono separate sulla
barra inversa. Gli accessor numerici scelgono la decodifica dal VR: `DS`/`IS` come testo e
`US`/`SS`/`UL`/`SL`/`FL`/`FD` come binario nell'ordine corretto. Valori incompleti, non finiti o
non rappresentabili restituiscono `nil`, mai un valore plausibile ma sbagliato. `vec3(_:)`
costruisce esclusivamente da almeno tre `Double` validi.

### Lettore binario e parser

Il parser usa un cursore privato su `Data`. Ogni lettura verifica prima che il numero di byte
richiesto sia disponibile, usando sottrazioni protette invece di somme che potrebbero
overfloware. I numeri sono assemblati byte per byte, quindi non esistono assunzioni di
allineamento. Non viene creata una copia `[UInt8]` dell'intero file.

Il flusso è:

1. riconoscimento di preambolo e `DICM` a offset 128;
2. in assenza di magic, validazione del primo header e fallback Implicit VR Little Endian da
   offset zero;
3. parsing del gruppo 0002 sempre Explicit VR Little Endian, rispettando esattamente
   `FileMetaInformationGroupLength` quando presente;
4. costruzione di `TransferSyntax`, con default Implicit VR Little Endian;
5. rifiuto esplicito del dataset deflated;
6. parsing del dataset principale secondo VR ed endianess della transfer syntax;
7. arresto a PixelData in modalità `metadataOnly`.

Il primo tag headerless è plausibile soltanto se l'header Implicit VR è completo, non è un tag
di delimitazione, appartiene all'intervallo dei gruppi dataset ordinari `0008...7FE0` e la
lunghezza dichiarata rientra nei byte disponibili. Un file che non supera questi controlli
produce `notDICOM`.

Gli header Explicit VR distinguono forma corta e lunga dalla proprietà `usesLongLength`. Gli
header Implicit VR usano la mappa dei tag. Ogni range di valore viene validato prima di creare
un `Data` o avanzare il cursore.

### Sequenze

Una sequenza a lunghezza definita viene validata e saltata per il numero esatto di byte. Una
sequenza a lunghezza indefinita viene attraversata con uno stack esplicito di contenitori, non
con ricorsione: item, item delimiter e sequence delimiter devono bilanciarsi anche in presenza
di sequenze annidate. Un tag inatteso o un delimitatore mancante produce un errore con file,
tag e offset. L'elemento `SQ` viene registrato con valore vuoto; il sorgente conterrà il commento
`TODO` richiesto dal brief per un futuro tag inspector.

### PixelData

Per PixelData a lunghezza definita, `pixelDataRange` è il range esatto dei byte del valore. In
`metadataOnly` il parser verifica il range ma non copia i pixel e restituisce immediatamente.
In `includingPixelData` conserva anche i byte grezzi nell'elemento.

Per PixelData indefinito, il parser convalida Basic Offset Table e fragment item fino a
`SequenceDelimitationItem`. Il range parte dal primo item e termina prima del delimitatore;
`isEncapsulatedPixelData` diventa `true` e nessuna decodifica viene tentata.

### Errori

`DICOMParsingError` adotta `Error`, `Hashable`, `Sendable` e `LocalizedError`. Comprende almeno
tutti i casi imposti dal brief e può aggiungere casi strettamente diagnostici per VR o
lunghezze non validi. Ogni descrizione è in italiano e include il nome del file; tag e offset
sono inclusi quando esistono. Anche `parse(url:)` converte gli errori di lettura in un errore
che nomina il percorso.

Gli errori di accesso o enumerazione della directory vengono analogamente convertiti in un
errore dello scanner che include il percorso interessato: nessun errore Foundation privo del
nome del file o della directory attraversa l'API pubblica.

### Scanner

`DICOMScanner` visita ricorsivamente i file regolari e usa sempre `metadataOnly`. Un file che
non è DICOM viene ignorato; un DICOM riconosciuto ma non leggibile viene aggiunto a
`ScanFailure`. Gli errori di enumerazione della directory restano errori della chiamata.

La gerarchia è paziente → studio → serie e conserva l'ordine di prima scoperta. Gli UID di
istanza, serie e studio sono obbligatori perché i corrispondenti campi pubblici non sono
opzionali; la loro assenza produce `missingRequiredTag` per quel file. I metadati opzionali
restano `nil`. Pazienti senza ID vengono raggruppati con nome e data di nascita; se mancano
anche questi, confluiscono nel gruppo anonimo vuoto.

Le firme omesse nel brief sono concretizzate così:

- `ScannedStudy`: `studyInstanceUID`, `date`, `description`, `series`;
- `ScannedPatient`: `patientID`, `name`, `birthDate`, `studies`;
- `ScanFailure`: `url`, `reason`;
- `ScannedSeries.isImageSeries`: falso per le modalità `SR`, `PR` e `KO`.

`instances` non viene mai ordinato, né per `InstanceNumber`, né per nome file, né per posizione.
Posizione e orientamento vengono soltanto trasportati affinché `SliceSorter` possa operare in
un secondo momento.

## Strategia di test

Lo sviluppo segue cicli red–green–refactor. `DICOMByteStreamBuilder` costruisce ogni stream in
memoria con metodi espliciti per endianess, header Explicit/Implicit, sequenze, item e
PixelData. Non vengono aggiunti fixture DICOM al repository. I test dello scanner possono
scrivere questi stessi stream in una directory temporanea creata durante il test e rimossa al
termine: i byte continuano a essere generati in memoria e nessun dato clinico o fixture viene
versionato.

I test coprono almeno:

- round trip Explicit VR Little Endian;
- Implicit VR Little Endian e inferenza `.OW` per PixelData;
- sequenza definita seguita da un elemento normale;
- sequenza indefinita annidata seguita da un elemento normale;
- file troncato con errore, senza crash;
- fallback headerless valido e rifiuto pulito di byte casuali;
- DS multivalore `0.2\\0.2` e US binario;
- `metadataOnly` con range PixelData esatto;
- gruppo file meta con group length;
- binari Explicit VR Big Endian;
- PixelData incapsulato indefinito;
- scanner con raggruppamento, fallimenti per file, serie non-image e ordine delle istanze non
  alterato.

La verifica finale esegue `swift test` in ambiente Linux con Swift 6 e controlla inoltre il
diff per vietare modifiche fuori dall'ambito e occorrenze dei termini `hu` o `hounsfield` nei
nuovi sorgenti.

## Criteri di accettazione

Il lavoro è accettato soltanto se tutti i file richiesti esistono, tutte le API pubbliche sono
`Sendable`, ogni lettura è delimitata, tutti i test passano su Linux e non è stato introdotto
alcun ordinamento delle slice. Il rapporto finale elenca file creati, deviazioni effettive e
qualsiasi dubbio di compilazione; se non esistono deviazioni o dubbi, lo dichiara esplicitamente.
