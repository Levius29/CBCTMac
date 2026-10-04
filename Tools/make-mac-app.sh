#!/usr/bin/env bash
# Costruisce «OpenMRI Dental.app»: OpenMRI, il suo motore e tutto ciò che gli serve, in un'app sola.
#
# # Che cosa c'è dentro
#
# - il guscio, `desktop/`: una finestra Electron, il menu, il pannello del Mac per le cartelle;
# - OpenMRI, `web/`, compilato qui e potato delle dipendenze di sviluppo;
# - Node, con cui gira il motore di OpenMRI;
# - Python con pydicom, dcm2niix, numpy, scipy, SimpleITK e nibabel, per l'importazione e per la
#   ricostruzione dentale.
#
# # Perché tutto dentro
#
# Il primo pacchetto cercava Node e Python sul Mac, e sul Mac di prova non è mai partito. Qui non
# si cerca niente: ogni pezzo arriva in una versione fissata, con la sua impronta SHA-256, e l'app
# funziona uguale su ogni Mac. Il prezzo è il peso — circa un gigabyte — e un primo giro di
# qualche minuto, che scarica circa 400 MB; i giri dopo riusano ciò che è già scaricato.
#
#   Tools/make-mac-app.sh              costruisce l'app nella radice del repository
#   Tools/make-mac-app.sh --install    la costruisce e la copia in /Applications
#
# Su Linux costruisce la stessa app per Linux: non serve a usarla, serve a provarla dove un Mac
# non c'è.

set -euo pipefail

RADICE="$(cd "$(dirname "$0")/.." && pwd)"
NOME="OpenMRI Dental"
INSTALLA=0
[ "${1:-}" = "--install" ] && INSTALLA=1

# Versioni fissate, con le loro impronte: ricostruire oggi o fra un anno dà la stessa app.
ELECTRON=44.5.1
NODE=22.23.3
PYTHON=3.12.15
PYTHON_BUILD=20261003

SISTEMA="$(uname -s)"
case "$SISTEMA-$(uname -m)" in
    Darwin-arm64)
        ELECTRON_FILE="electron-v$ELECTRON-darwin-arm64.zip"
        ELECTRON_SHA=1d75703019bb16461ae65f3081d7e6f5c0b11e901d0ccb5c343bcf7bcdd6435c
        NODE_DIR="node-v$NODE-darwin-arm64"
        NODE_SHA=23b25245dcfb9af7262f8ff142e9e2e0af025368117329e7a7458a51e5922f53
        PYTHON_TARGET=aarch64-apple-darwin
        PYTHON_SHA=ad8d0c637c0a36b967b310e2c07254f4d2ca8cabaa7699e55ed6290aceb481a2
        ;;
    Darwin-x86_64)
        ELECTRON_FILE="electron-v$ELECTRON-darwin-x64.zip"
        ELECTRON_SHA=e567d13833d0e161d7749727355b98643461df3395b537cfa7bdddf8a8bfedff
        NODE_DIR="node-v$NODE-darwin-x64"
        NODE_SHA=8a677b0219178efd6eb0e475457c4afb452b521a92f6e67845a73bd85727f2a8
        PYTHON_TARGET=x86_64-apple-darwin
        PYTHON_SHA=562c30864ece2cb1d3e0ad66a1acd498611a47e5a10ce81b99158bef1ccbd355
        ;;
    Linux-x86_64)
        ELECTRON_FILE="electron-v$ELECTRON-linux-x64.zip"
        ELECTRON_SHA=5bcd217611d6843ececd6c9e9c1fcd1da3ab066c43d8b1a9e4b44689a1fba6f5
        NODE_DIR="node-v$NODE-linux-x64"
        NODE_SHA=1084aa36196bba4c3a5e69a1ee388a6e4ff729dad09445fbcd434b28fe3c24af
        PYTHON_TARGET=x86_64-unknown-linux-gnu
        PYTHON_SHA=731af898886c5f821890dc901eca3c651cca8e51fa7308c159d12a1194aeac91
        ;;
    *)
        echo "Questa app si costruisce su un Mac, Apple Silicon o Intel." >&2
        exit 1
        ;;
esac
PYTHON_FILE="cpython-$PYTHON+$PYTHON_BUILD-$PYTHON_TARGET-install_only_stripped.tar.gz"
PYTHON_URL="https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/cpython-$PYTHON%2B$PYTHON_BUILD-$PYTHON_TARGET-install_only_stripped.tar.gz"

if [ "$SISTEMA" = "Darwin" ]; then
    CACHE="$HOME/Library/Caches/OpenMRI Dental build"
else
    CACHE="${XDG_CACHE_HOME:-$HOME/.cache}/openmri-dental-build"
fi
LAVORO="$CACHE/lavoro"
mkdir -p "$CACHE"

passo() { printf '\n▸ %s\n' "$1"; }

impronta() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d' ' -f1
    else
        sha256sum "$1" | cut -d' ' -f1
    fi
}

# Scarica una volta sola, e solo se l'impronta torna: un file a metà o sostituito non entra.
scarica() {
    local url="$1" file="$CACHE/$2" sha="$3"
    if [ -f "$file" ] && [ "$(impronta "$file")" = "$sha" ]; then
        echo "  già scaricato: $2"
        return
    fi
    echo "  scarico $2"
    curl -fL --retry 3 --progress-bar -o "$file.part" "$url"
    if [ "$(impronta "$file.part")" != "$sha" ]; then
        rm -f "$file.part"
        echo "L'impronta di $2 non torna: il file non è quello atteso. Riprova più tardi." >&2
        exit 1
    fi
    mv "$file.part" "$file"
}

passo "Scarico Node, Python ed Electron"
scarica "https://nodejs.org/dist/v$NODE/$NODE_DIR.tar.gz" "$NODE_DIR.tar.gz" "$NODE_SHA"
scarica "$PYTHON_URL" "$PYTHON_FILE" "$PYTHON_SHA"
scarica "https://github.com/electron/electron/releases/download/v$ELECTRON/$ELECTRON_FILE" \
    "$ELECTRON_FILE" "$ELECTRON_SHA"

rm -rf "$LAVORO"
mkdir -p "$LAVORO"
tar -xzf "$CACHE/$NODE_DIR.tar.gz" -C "$LAVORO"
# Solo il Node appena scaricato: quello del sistema, se c'è, non deve entrare nel giro.
export PATH="$LAVORO/$NODE_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin"

passo "Compilo OpenMRI (la prima volta npm scarica le sue librerie: qualche minuto)"
mkdir -p "$LAVORO/openmri"
# Il programma, senza ciò che è di chi lo usa o di una compilazione precedente: la libreria
# degli esami, l'ambiente Python, le dipendenze già installate, lo studio dimostrativo.
tar -C "$RADICE/web" \
    --exclude ./node_modules --exclude ./.venv --exclude ./.openmri --exclude ./.neurospace \
    --exclude ./dist --exclude ./demo --exclude './*.log' \
    -cf - . | tar -C "$LAVORO/openmri" -xf -
(
    cd "$LAVORO/openmri"
    npm ci --no-audit --no-fund --loglevel=error
    npm run build --silent
    npm prune --omit=dev --no-audit --no-fund --loglevel=error
)

passo "Preparo Python e le librerie dell'importazione"
tar -xzf "$CACHE/$PYTHON_FILE" -C "$LAVORO"
PY="$LAVORO/python/bin/python3"
"$PY" -m pip install --quiet --no-cache-dir --no-warn-script-location --disable-pip-version-check \
    --only-binary=:all: -r "$LAVORO/openmri/scripts/requirements.txt"
# Gli script installati da pip puntano al Python con un percorso assoluto, che dentro l'app
# cambierebbe a ogni spostamento. Si riscrivono perché cerchino il Python accanto a sé.
for script in "$LAVORO/python/bin/"*; do
    [ -f "$script" ] && [ ! -L "$script" ] || continue
    head -c 2 "$script" | grep -q '#!' || continue
    head -n 1 "$script" | grep -q "$LAVORO/python/bin/python" || continue
    {
        printf '#!/bin/sh\n'
        printf "'''exec' \"\$(dirname -- \"\$0\")/python3\" \"\$0\" \"\$@\"\n"
        printf "' '''\n"
        tail -n +2 "$script"
    } >"$script.nuovo"
    chmod +x "$script.nuovo"
    mv "$script.nuovo" "$script"
done
# Le prove delle librerie non servono a chi le usa: sono 60 MB. Nemmeno pip, a installazione fatta.
find "$LAVORO/python/lib" -type d -name tests -prune -exec rm -rf {} +
"$PY" -m pip uninstall --quiet --yes pip >/dev/null 2>&1 || true
# Compilati adesso, i moduli non verranno scritti dentro l'app al primo avvio.
"$PY" -m compileall -q "$LAVORO/python/lib" >/dev/null 2>&1 || true
"$PY" -c "import pydicom, nibabel, numpy, scipy, SimpleITK; print('  librerie Python a posto')"
# dcm2niix stampa il suo nome ed esce con errore anche quando va: si guarda che cosa dice.
VERSIONE_DCM2NIIX="$("$LAVORO/python/bin/dcm2niix" --version 2>&1 || true)"
case "$VERSIONE_DCM2NIIX" in
    *dcm2nii*) echo "  dcm2niix a posto" ;;
    *)
        echo "dcm2niix non risponde: senza, nessun DICOM si importa." >&2
        echo "$VERSIONE_DCM2NIIX" >&2
        exit 1
        ;;
esac

passo "Assemblo l'app"
if [ "$SISTEMA" = "Darwin" ]; then
    ditto -x -k "$CACHE/$ELECTRON_FILE" "$LAVORO/electron"
    APP="$LAVORO/$NOME.app"
    mv "$LAVORO/electron/Electron.app" "$APP"
    RISORSE="$APP/Contents/Resources"
else
    APP="$LAVORO/$NOME-linux"
    unzip -q "$CACHE/$ELECTRON_FILE" -d "$APP"
    RISORSE="$APP/resources"
fi
rm -f "$RISORSE/default_app.asar"
mkdir -p "$RISORSE/app" "$RISORSE/node/bin"
cp "$RADICE/desktop/package.json" "$RADICE/desktop/main.js" "$RADICE/desktop/preload.js" \
    "$RADICE/desktop/loading.html" "$RISORSE/app/"
cp "$LAVORO/$NODE_DIR/bin/node" "$RISORSE/node/bin/node"
cp "$LAVORO/$NODE_DIR/LICENSE" "$RISORSE/node/LICENSE"
mv "$LAVORO/openmri" "$RISORSE/openmri"
mv "$LAVORO/python" "$RISORSE/python"

if [ "$SISTEMA" = "Darwin" ]; then
    PLIST="$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleName \"$NOME\"" "$PLIST"
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string \"$NOME\"" "$PLIST" 2>/dev/null ||
        /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName \"$NOME\"" "$PLIST"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier it.levius29.openmri-dental" "$PLIST"

    # L'icona è un'arcata vista dall'alto, disegnata da Tools/make-app-icon.py.
    ICONSET="$LAVORO/AppIcon.iconset"
    if "$RISORSE/python/bin/python3" "$RADICE/Tools/make-app-icon.py" "$ICONSET" >/dev/null 2>&1 &&
        iconutil -c icns "$ICONSET" -o "$RISORSE/electron.icns" 2>/dev/null; then
        echo "  icona a posto"
    else
        echo "  l'icona non si è fatta: resta quella di Electron"
    fi
    rm -rf "$ICONSET"

    # Su Apple Silicon un'app modificata e non firmata viene chiusa all'avvio, e così ogni
    # programma che lancia. La firma «ad hoc» basta a un'app che resta su questo Mac. `--deep`
    # firma solo ciò che sta dove Apple mette il codice — Frameworks, Helpers — e non Node né le
    # librerie di Python, che stanno fra le risorse: quelle si firmano una per una, prima.
    xattr -cr "$APP"
    find "$RISORSE/node" "$RISORSE/python" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) |
        while IFS= read -r binario; do
            case "$(file -b "$binario")" in
                *Mach-O*) codesign --force --sign - "$binario" 2>/dev/null ;;
            esac
        done
    codesign --force --deep --sign - "$APP" >/dev/null
    codesign --verify --deep "$APP"
    echo "  firmata per questo Mac"
fi

DESTINAZIONE="$RADICE/$(basename "$APP")"
rm -rf "$DESTINAZIONE"
mv "$APP" "$DESTINAZIONE"
rm -rf "$LAVORO"

passo "Fatto: $DESTINAZIONE ($(du -sh "$DESTINAZIONE" | cut -f1))"
if [ "$SISTEMA" = "Darwin" ] && [ "$INSTALLA" = "1" ]; then
    rm -rf "/Applications/$NOME.app"
    ditto "$DESTINAZIONE" "/Applications/$NOME.app"
    echo "  copiata in /Applications: si apre dal Launchpad o dal Finder."
fi
