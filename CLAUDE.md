# CBCTMac — istruzioni per chi ci lavora

Visore e pianificatore per CBCT dentali, nativo macOS. Il [`README`](README.md) spiega come si
compila e come si usa; qui c'è soltanto quello che serve a non rompere il progetto lavorandoci
dentro.

## Un solo tronco: `main`

**`main` è il ramo da cui si compila il programma, e deve contenerlo tutto.** Non è un ramo di
pubblicazione né un archivio: è il programma.

Le funzioni si sviluppano su rami separati — è il modo giusto di lavorare — ma un ramo è lavoro
**in transito**, non un posto dove abitare. Il ciclo è questo, e l'ordine conta:

```sh
# 1. si parte SEMPRE da main aggiornato
git checkout main && git pull origin main
git checkout -b nome-del-lavoro

# 2. si sviluppa sul ramo: lavoro, commit, verifica (vedi «Il cancello»)

# 3. si rientra, e i conflitti si risolvono SUL RAMO
git checkout main && git pull origin main
git checkout nome-del-lavoro && git merge main    # eventuali conflitti si sistemano qui
#    ... si rilancia il cancello sull'albero fuso ...
git checkout main && git merge nome-del-lavoro && git push origin main
```

Il passo 3 fonde `main` nel ramo *prima* di fondere il ramo in `main`. Costa un comando in più e
compra la cosa che conta: i conflitti si risolvono e si verificano sul ramo, e `main` avanza in
linea retta senza passare da uno stato rotto.

**Il passo 1 è quello che salta sempre, ed è quello che conta di più.** Un ramo nato da un commit
vecchio si porta dietro conflitti che non esistevano, e più resta fuori più smette di essere un
ramo e diventa un secondo programma.

Non è teoria: il progetto ci è già finito dentro. Cinque rami paralleli, centocinquanta commit
per uno, e `main` con dentro il solo LICENSE. Riunirli è costato poco solo perché nessuno aveva
davvero divergato — la volta dopo non è detto.

Tre corollari, tutti conseguenza della stessa regola:

- **Mai ramificare da un altro ramo di lavoro.** Si ramifica da `main`, sempre.
- **Un ramo fuso è finito**: si cancella, `git push origin --delete <ramo>`. Un ramo che
  sopravvive alla propria fusione è solo un invito a ripartire da lì.
- **Non si tiene fuori una funzione «quasi pronta».** Se una parte regge e una no, si fonde la
  parte che regge e si tiene fuori il resto. Il ramo lungo è il problema, non la soluzione.

## Il cancello: cosa passare prima di fondere in `main`

`main` deve restare compilabile. Prima di fonderci dentro qualcosa:

```sh
for controllo in Tools/check-*.py; do python3 "$controllo" || break; done
swift test
```

I ventisei controlli in `Tools/` girano **ovunque** — senza Xcode, senza rete e persino senza
Swift — e sono l'unica verifica che copra il target dell'applicazione, che fuori da macOS non
compila e quindi non entra in `swift test`. Non sono un extra: sono la parte del cancello che
funziona anche dove il compilatore non arriva.

Se lavori dove Swift non è installato, i controlli restano obbligatori e nel messaggio di commit
va scritto a chiare lettere che `swift test` resta da passare sul Mac. Dichiarare verificato
qualcosa che non si è visto passare è il modo più veloce per rendere `main` inaffidabile, che è
esattamente ciò che questo documento esiste per impedire.

Un conflitto sui numeri nel `README` — quanti test, quanti controlli — si risolve **contando**,
non scegliendo:

```sh
ls Tools/check-*.py | wc -l
```

## Prima di scrivere codice

[`docs/architecture.md`](docs/architecture.md) è **normativo**: cinque contratti su sistemi di
coordinate, ordinamento delle slice, doppia rappresentazione del volume, «GV» e non «HU», e cifre
significative. Vanno letti prima di toccare qualunque cosa, perché violarli non dà errori di
compilazione — dà numeri sbagliati sullo schermo di chi guarda un esame.

La sezione *Regole trasversali* dello stesso documento governa pannelli e finestre modali, ed è
sorvegliata da tre controlli in `Tools/` che falliscono se la si viola.

## Lingua

Commit, commenti e documentazione **in italiano**, come tutto il resto del repository. Gli
identificatori nel codice — tipi, funzioni, file — restano **in inglese**.

I messaggi di commit dicono *cosa cambia per chi usa il programma*, e quando serve *perché*: la
riga di riepilogo è un'affermazione, non un'etichetta.
