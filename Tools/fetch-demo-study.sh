#!/usr/bin/env bash
# Scarica lo studio demo di OpenMRI, che nel repository non c'è.
#
# Pesa 46 MB e non cambia mai: versionarlo avrebbe appesantito ogni clone per sempre, anche di
# chi importa subito i propri esami. Sta dove l'ha messo l'originale, e questo script lo porta
# dove `npm run demo` se lo aspetta.
#
#   Tools/fetch-demo-study.sh        scarica se manca
#   Tools/fetch-demo-study.sh --force  riscarica comunque

set -euo pipefail

DESTINAZIONE="$(cd "$(dirname "$0")/.." && pwd)/web/demo/jane-head-mri.zip"
SORGENTE="https://raw.githubusercontent.com/lev1nson/OpenMRI/main/demo/jane-head-mri.zip"

if [ -f "$DESTINAZIONE" ] && [ "${1:-}" != "--force" ]; then
    echo "Lo studio demo c'è già: $DESTINAZIONE"
    exit 0
fi

mkdir -p "$(dirname "$DESTINAZIONE")"
echo "Scarico lo studio demo (46 MB) da lev1nson/OpenMRI…"
curl -fL --progress-bar -o "$DESTINAZIONE.parziale" "$SORGENTE"
mv "$DESTINAZIONE.parziale" "$DESTINAZIONE"

# Una ZIP troncata darebbe un errore d'importazione che sembra un difetto del programma.
if ! unzip -tq "$DESTINAZIONE" >/dev/null 2>&1; then
    echo "L'archivio scaricato non è leggibile: rilancia con --force." >&2
    rm -f "$DESTINAZIONE"
    exit 1
fi

echo "Fatto: $DESTINAZIONE"
echo "Ora: cd web && npm run demo"
