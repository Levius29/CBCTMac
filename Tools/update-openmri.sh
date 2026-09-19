#!/usr/bin/env bash
# Porta dentro `web/` le novità dell'OpenMRI originale.
#
# # Perché uno script e non `git subtree`
#
# Subtree sarebbe il modo canonico, e trascinerebbe nella nostra storia anche lo studio demo da
# 46 MB, per sempre, in ogni clone. Qui si fa la stessa cosa in due passi espliciti: si calcola
# la differenza fra il commit originale che abbiamo copiato — quello scritto in
# `web/.upstream-commit` — e il loro `main` di adesso, e la si applica a `web/` in tre vie.
#
# Le nostre modifiche locali dentro i loro file non vengono sovrascritte in silenzio: se toccano
# le stesse righe diventano un conflitto marcato, che è esattamente ciò che si vuole vedere.

set -euo pipefail

RADICE="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="$RADICE/.upstream-cache"
ORIGINE="https://github.com/lev1nson/OpenMRI.git"
SEGNO="$RADICE/web/.upstream-commit"

if [ ! -f "$SEGNO" ]; then
    echo "Manca web/.upstream-commit: non so da quale commit siamo partiti." >&2
    exit 1
fi
BASE="$(tr -d '[:space:]' <"$SEGNO")"

if [ -d "$CACHE" ]; then
    git -C "$CACHE" fetch --prune origin '+refs/heads/*:refs/heads/*'
else
    git clone --bare "$ORIGINE" "$CACHE"
fi

NUOVO="$(git -C "$CACHE" rev-parse main)"
if [ "$BASE" = "$NUOVO" ]; then
    echo "Già allineati all'originale ($BASE)."
    exit 0
fi

echo "Novità da $BASE a $NUOVO:"
git -C "$CACHE" log --oneline "$BASE..$NUOVO" | sed 's/^/  /'
echo

DIFFERENZA="$(mktemp)"
trap 'rm -f "$DIFFERENZA"' EXIT
# Lo studio demo resta fuori: non è nel repository e non deve entrarci da qui.
git -C "$CACHE" diff "$BASE" "$NUOVO" -- . ':(exclude)demo/jane-head-mri.zip' >"$DIFFERENZA"

if [ ! -s "$DIFFERENZA" ]; then
    echo "Nessuna modifica ai file che teniamo. Aggiorno il segno e basta."
    echo "$NUOVO" >"$SEGNO"
    exit 0
fi

cd "$RADICE"
if git apply --3way --directory=web --whitespace=nowarn "$DIFFERENZA"; then
    echo "$NUOVO" >"$SEGNO"
    echo
    echo "Applicato. Adesso, prima di dire che funziona:"
    echo "  cd web && npm ci && npm run check"
else
    echo >&2
    echo "Restano conflitti da risolvere a mano. Quando hai finito, scrivi il commit nuovo:" >&2
    echo "  echo $NUOVO > web/.upstream-commit" >&2
    exit 1
fi
