#!/usr/bin/env bash
# Stampa tutto quello che serve a capire perché qualcosa non parte.
#
# Si lancia e si incolla l'uscita. Non tocca niente e non manda niente da nessuna parte: legge
# soltanto — versione del codice, versioni di Node e Python, se il server risponde, che cosa dice
# il registro. Esiste perché «non funziona» non basta a nessuno dei due, e chiedere una cosa alla
# volta costa un giro di messaggi per ciascuna.

RADICE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RADICE" || exit 1

riga() { printf '\n— %s\n' "$1"; }

riga "codice"
git log --oneline -1 2>/dev/null || echo "non è un repository git"
echo "ramo: $(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
SPORCO="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
echo "file modificati non salvati: $SPORCO"
echo "il ramo è indietro rispetto a origin? $(git fetch -q origin 2>/dev/null; git rev-list --count HEAD..@{u} 2>/dev/null || echo '?') commit"

riga "programmi"
echo "node: $(command -v node >/dev/null && node -v || echo 'NON INSTALLATO')"
echo "npm:  $(command -v npm >/dev/null && npm -v || echo 'NON INSTALLATO')"
if [ -x "$RADICE/web/.venv/bin/python" ]; then
    echo "python del programma: $("$RADICE/web/.venv/bin/python" -V 2>&1)"
    echo "dcm2niix: $([ -x "$RADICE/web/.venv/bin/dcm2niix" ] && echo presente || echo 'MANCA — lancia: cd web && npm run setup')"
else
    echo "python del programma: MANCA — lancia: cd web && npm run setup"
fi

riga "compilazione"
if [ -d "$RADICE/web/dist" ]; then
    echo "compilato da: $(cat "$RADICE/web/dist/.built-from" 2>/dev/null || echo '?')"
    echo "commit attuale: $(git rev-parse HEAD 2>/dev/null)"
else
    echo "mai compilato — lancia: cd web && npm run build"
fi

riga "server"
SALUTE="$(curl -fsS --max-time 3 http://127.0.0.1:4173/api/health 2>/dev/null)"
if [ -n "$SALUTE" ]; then
    echo "risponde: $SALUTE"
    echo "pagina iniziale: $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:4173/)"
    echo "pagina dentale:  $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 http://127.0.0.1:4173/dental)"
    echo "importazione da cartella: $(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST http://127.0.0.1:4173/api/dental/upload -H 'Content-Type: application/json' -d '{"action":"start"}')"
else
    echo "NON RISPONDE su 127.0.0.1:4173 — lancia: cd web && npm run up"
fi

riga "libreria"
if [ -n "$SALUTE" ]; then
    curl -fsS --max-time 5 http://127.0.0.1:4173/api/library 2>/dev/null |
        python3 -c "import json,sys; d=json.load(sys.stdin); print('pazienti:', len(d['patients']), '· studi:', len(d['studies'])); [print('  lavoro', j['status'], '·', j.get('stage',''), '·', (j.get('error') or '')[:120]) for j in d['jobs'][:5]]" 2>/dev/null ||
        echo "non sono riuscito a leggerla"
fi

riga "ultime righe del registro del server"
tail -n 25 "$RADICE/web/.openmri-server.log" 2>/dev/null || echo "nessun registro"

riga "ultimi errori di importazione"
for CARTELLA in "$RADICE"/web/.openmri/jobs/*/; do
    [ -f "$CARTELLA/worker.log" ] || continue
    echo "--- $(basename "$CARTELLA")"
    tail -n 8 "$CARTELLA/worker.log"
done 2>/dev/null | tail -n 40

printf '\n— fine. Incolla tutto quello che c'\''è qui sopra.\n'
